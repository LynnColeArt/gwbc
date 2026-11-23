const std = @import("std");
const Writer = std.Io.Writer;

const Cursor = struct {
    data: []const u8,
    offset: usize = 1,

    fn remaining(self: Cursor) []const u8 {
        return self.data[self.offset..];
    }

    fn take(self: *Cursor, count: usize) ![]const u8 {
        if (count > self.remaining().len) return error.TruncatedTokenizedProgram;
        const start = self.offset;
        self.offset += count;
        return self.data[start..self.offset];
    }

    fn byte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn word(self: *Cursor) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn consume(self: *Cursor, marker: []const u8) bool {
        if (!std.mem.startsWith(u8, self.remaining(), marker)) return false;
        self.offset += marker.len;
        return true;
    }
};

// IBMRES.ASM assigns these token values in its statement, operator, and
// function tables. Decode only the vocabulary understood by the compiler.
fn keyword(token: u8) ?[]const u8 {
    return switch (token) {
        0x81 => "END",
        0x82 => "FOR",
        0x83 => "NEXT",
        0x85 => "INPUT",
        0x86 => "DIM",
        0x87 => "READ",
        0x88 => "LET",
        0x89 => "GOTO",
        0x8b => "IF",
        0x8c => "RESTORE",
        0x8d => "GOSUB",
        0x8e => "RETURN",
        0x91 => "PRINT",
        0xa1 => "ELSE",
        0xba => "OPEN",
        0xbb => "CLOSE",
        0xcc => "TO",
        0xcd => "THEN",
        0xcf => "STEP",
        0xee => "AND",
        0xef => "OR",
        0xf3 => "MOD",
        else => null,
    };
}

fn extended(page: u8, token: u8) ?[]const u8 {
    return switch (page) {
        0xfe => if (token == 0x83) "SYSTEM" else null,
        0xff => switch (token) {
            0x82 => "RIGHT$",
            0x83 => "MID$",
            0x92 => "LEN",
            0x94 => "VAL",
            else => null,
        },
        else => null,
    };
}

fn readSingle(cursor: *Cursor) !f32 {
    const encoded = try cursor.take(4);
    const exponent = encoded[3];
    if (exponent == 0) return 0;
    const significand = @as(u32, encoded[0]) |
        (@as(u32, encoded[1]) << 8) |
        (@as(u32, encoded[2] | 0x80) << 16);
    // MBF stores the sign above the fraction and uses a bias of 129.
    // The reconstructed significand has 23 fractional bits.
    const magnitude = std.math.ldexp(@as(f64, @floatFromInt(significand)), @as(i32, exponent) - 152);
    const single: f32 = @floatCast(magnitude);
    if (@as(f64, single) != magnitude) return error.UnsupportedMbfSingle;
    return if (encoded[2] & 0x80 != 0) -single else single;
}

fn writeWord(out: *Writer, word: []const u8) !void {
    try out.print(" {s} ", .{word});
}

fn decodeLine(cursor: *Cursor, out: *Writer) !void {
    var quoted = false;
    var literal_rest = false;
    while (true) {
        const token = try cursor.byte();
        if (token == 0) return;
        if (quoted or literal_rest) {
            if (token < ' ' or token > '~') return error.NonAsciiTokenizedText;
            try out.writeByte(token);
            if (!literal_rest and token == '"') quoted = false;
            continue;
        }
        // The tokenizer prefixes both ELSE and apostrophe comments with a
        // hidden statement separator. Preserve any real separators.
        if (token == ':' and
            (std.mem.startsWith(u8, cursor.remaining(), "\xa1") or
                std.mem.startsWith(u8, cursor.remaining(), "\x8f\xd9"))) continue;
        switch (token) {
            '"' => {
                quoted = true;
                try out.writeByte(token);
            },
            0x20...0x21, 0x23...0x7e => try out.writeByte(token),
            0x8f => {
                literal_rest = true;
                if (cursor.consume("\xd9")) {
                    try out.writeByte('\'');
                } else {
                    try writeWord(out, "REM");
                }
            },
            0x84 => {
                // GW-BASIC leaves DATA fields in their original text form.
                try writeWord(out, "DATA");
                literal_rest = true;
            },
            0x0b, 0x0c, 0x1c => try out.print("{d}", .{@as(i16, @bitCast(try cursor.word()))}),
            0x0e => try out.print("{d}", .{try cursor.word()}),
            0x0f => try out.print("{d}", .{try cursor.byte()}),
            0x11...0x1b => try out.print("{d}", .{token - 0x11}),
            0x1d => try out.print("{e}!", .{try readSingle(cursor)}),
            0x1f => {
                _ = try cursor.take(8);
                return error.UnsupportedTokenizedDouble;
            },
            0xe6 => try out.writeByte('>'),
            0xe7 => try out.writeByte('='),
            0xe8 => try out.writeByte('<'),
            0xe9 => try out.writeByte('+'),
            0xea => try out.writeByte('-'),
            0xeb => try out.writeByte('*'),
            0xec => try out.writeByte('/'),
            0xf4 => try out.writeByte('\\'),
            0xfd...0xff => {
                const subtoken = try cursor.byte();
                try writeWord(out, extended(token, subtoken) orelse return error.UnsupportedProgramToken);
            },
            else => try writeWord(out, keyword(token) orelse return error.UnsupportedProgramToken),
        }
    }
}

pub fn sourceText(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Writer) ![]const u8 {
    if (source.len == 0) return source;
    switch (source[0]) {
        0xfe => return error.ProtectedBasicProgram,
        0xff => {},
        else => return source,
    }

    var cursor: Cursor = .{ .data = source };
    var output: Writer.Allocating = .init(allocator);
    var origin: ?u16 = null;
    var previous_line: ?u16 = null;
    while (true) {
        const link = try cursor.word();
        if (link == 0) {
            // DOS can append a Ctrl-Z followed by sector padding containing
            // stale bytes. The bytes after Ctrl-Z are outside the program.
            const tail = cursor.remaining();
            if (tail.len != 0 and tail[0] != 0x1a) return error.InvalidTokenizedEnd;
            return output.written();
        }
        const line = try cursor.word();
        if (line > 65529 or (previous_line != null and line <= previous_line.?))
            return error.InvalidTokenizedLineNumber;
        previous_line = line;
        try output.writer.print("{d} ", .{line});
        decodeLine(&cursor, &output.writer) catch |err| {
            try diagnostic.print("tokenized BASIC line {d}, near file offset {d}: {s}\n", .{
                line, cursor.offset, @errorName(err),
            });
            return err;
        };
        try output.writer.writeByte('\n');

        // Links are addresses from DOS memory and their base differs across
        // interpreters. Read sequentially and require a consistent base.
        const next = std.math.cast(u16, cursor.offset) orelse return error.InvalidTokenizedLink;
        const base = link -% next;
        if (origin) |expected| {
            if (base != expected) return error.InvalidTokenizedLink;
        } else {
            origin = base;
        }
    }
}

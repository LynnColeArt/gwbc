const std = @import("std");

comptime {
    if (!std.debug.runtime_safety) @compileError("GW-BASIC programs require Debug or ReleaseSafe");
}

fn integerRemainder(numerator: i16, denominator: i16) !i16 {
    // BASIC gives the remainder the sign of the dividend even for a
    // negative divisor. Widen before taking the divisor's absolute value.
    const magnitude: i32 = @intCast(@abs(@as(i32, denominator)));
    return @intCast(try std.math.rem(i32, numerator, magnitude));
}

const BasicString = struct {
    buffer: [255]u8 = @splat(0),
    size: u8 = 0,

    fn fromBytes(source: []const u8) !BasicString {
        if (source.len > 255) return error.StringTooLong;
        var value: BasicString = .{};
        @memcpy(value.buffer[0..source.len], source);
        value.size = @intCast(source.len);
        return value;
    }

    fn bytes(self: *const BasicString) []const u8 {
        return self.buffer[0..self.size];
    }

    fn concat(left: BasicString, tail: BasicString) !BasicString {
        var result = left;
        result.size = try std.math.add(u8, left.size, tail.size);
        @memcpy(result.buffer[left.size..result.size], tail.bytes());
        return result;
    }

    fn compare(left: BasicString, other: BasicString) i16 {
        return switch (std.mem.order(u8, left.bytes(), other.bytes())) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    fn length(value: BasicString) i16 {
        return value.size;
    }

    fn mid(value: BasicString, position: i16, count: i16) !BasicString {
        if (position < 1 or position > 255 or count < 0 or count > 255)
            return error.IllegalFunctionCall;
        const start = @min(@as(usize, @intCast(position - 1)), value.size);
        const end = @min(start + @as(usize, @intCast(count)), value.size);
        return fromBytes(value.bytes()[start..end]);
    }

    fn right(value: BasicString, count: i16) !BasicString {
        if (count < 0 or count > 255) return error.IllegalFunctionCall;
        const size = @min(@as(usize, @intCast(count)), value.size);
        return fromBytes(value.bytes()[value.size - size ..]);
    }

    fn val(value: BasicString) !i16 {
        var compact: [255]u8 = undefined;
        var length_used: usize = 0;
        for (value.bytes()) |byte| {
            if (byte == ' ') continue;
            compact[length_used] = byte;
            length_used += 1;
        }
        const text = compact[0..length_used];
        if (text.len == 0) return 0;
        var end: usize = if (text[0] == '+' or text[0] == '-') 1 else 0;
        const start = end;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        if (end < text.len and
            (text[end] == '.' or text[end] == '&' or
                (end != start and std.mem.indexOfScalar(u8, "EeDd", text[end]) != null)))
            return error.UnsupportedValNumber;
        if (end == start) return 0;
        return std.fmt.parseInt(i16, text[0..end], 10);
    }
};

fn ProgramRuntime(comptime numeric_count: usize, comptime string_count: usize) type {
    return struct {
        const Self = @This();
        const Loop = struct {
            line: u16,
            limit: i16,
            step: i16,

            fn includes(self: Loop, value: i16) bool {
                if (self.step == 0) return true;
                return if (self.step > 0) value <= self.limit else value >= self.limit;
            }
        };

        const Subroutine = struct {
            continuation: u16,
            caller_loops: [numeric_count]?Loop,
        };

        io: std.Io,
        allocator: std.mem.Allocator,
        stdin: std.Io.File.Reader,
        variables: [numeric_count]i16 = @splat(0),
        strings: [string_count]BasicString = @splat(.{}),
        loops: [numeric_count]?Loop = @splat(null),
        subroutines: std.ArrayList(Subroutine) = .empty,
        file: ?std.Io.File = null,
        record: [128]u8 = @splat(0),
        used: usize = 0,

        fn open(self: *Self) !void {
            if (self.file != null) return error.FileAlreadyOpen;
            self.file = try std.Io.Dir.cwd().createFile(self.io, "OUT.TXT", .{});
            self.record = @splat(0);
            self.used = 0;
        }

        fn release(self: *Self) void {
            if (self.file) |file| file.close(self.io);
            self.file = null;
        }

        fn output(self: *Self, to_file: bool, bytes: []const u8) !void {
            if (!to_file) return std.Io.File.stdout().writeStreamingAll(self.io, bytes);
            const file = self.file orelse return error.FileNotOpen;
            for (bytes) |byte| {
                self.record[self.used] = byte;
                self.used += 1;
                if (self.used == self.record.len) {
                    try file.writeStreamingAll(self.io, &self.record);
                    self.used = 0;
                }
            }
        }

        fn newline(self: *Self, to_file: bool) !void {
            try self.output(to_file, if (to_file) "\r\n" else "\n");
        }

        fn number(self: *Self, to_file: bool, value: i16) !void {
            var buffer: [12]u8 = undefined;
            if (value >= 0) try self.output(to_file, " ");
            try self.output(to_file, try std.fmt.bufPrint(&buffer, "{d} ", .{value}));
        }

        fn answer(self: *Self, prompt: []const u8, question: bool) ![]const u8 {
            // The terminal supplies its own input echo. Reproduce it for pipes/files.
            const echo = !try std.Io.File.stdin().isTty(self.io);
            try self.output(false, prompt);
            if (question) try self.output(false, "? ");
            const line = try self.stdin.interface.takeDelimiter('\n') orelse return error.EndOfInput;
            const response = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
            if (echo) {
                try self.output(false, response);
                try self.newline(false);
            }
            return response;
        }

        fn input(self: *Self, prompt: []const u8, question: bool) !i16 {
            while (true) {
                const trimmed = std.mem.trim(u8, try self.answer(prompt, question), " ");
                if (trimmed.len == 0) return 0;
                const digits = if (trimmed[0] == '+' or trimmed[0] == '-') trimmed[1..] else trimmed;
                if (digits.len != 0 and std.mem.findNone(u8, digits, "0123456789") == null) {
                    return std.fmt.parseInt(i16, trimmed, 10);
                }
                try self.output(false, "?Redo from start\n");
            }
        }

        fn stringInput(self: *Self, prompt: []const u8, question: bool) !BasicString {
            while (true) {
                const text = std.mem.trim(u8, try self.answer(prompt, question), " ");
                if (text.len != 0 and text[0] == '"') {
                    if (std.mem.indexOfScalarPos(u8, text, 1, '"')) |end| {
                        if (end + 1 == text.len) return BasicString.fromBytes(text[1..end]);
                    }
                } else if (std.mem.indexOfScalar(u8, text, ',') == null) {
                    return BasicString.fromBytes(text);
                }
                try self.output(false, "?Redo from start\n");
            }
        }

        fn printString(self: *Self, to_file: bool, value: BasicString) !void {
            try self.output(to_file, value.bytes());
        }

        fn beginLoop(self: *Self, index: usize, line: u16, start: i16, limit: i16, step: i16) bool {
            const loop = Loop{ .line = line, .limit = limit, .step = step };
            self.variables[index] = start;
            const enters = loop.includes(start);
            self.loops[index] = if (enters) loop else null;
            return enters;
        }

        fn nextLoop(self: *Self, index: usize, line: u16) !bool {
            const loop = self.loops[index] orelse return error.NextWithoutFor;
            if (loop.line != line) return error.NextWithoutFor;
            const value = try std.math.add(i16, self.variables[index], loop.step);
            self.variables[index] = value;
            if (loop.includes(value)) return true;
            self.loops[index] = null;
            return false;
        }

        fn beginSubroutine(self: *Self, continuation: u16) !void {
            try self.subroutines.append(self.allocator, .{ .continuation = continuation, .caller_loops = self.loops });
            self.loops = @splat(null);
        }

        fn endSubroutine(self: *Self) !u16 {
            const frame = self.subroutines.pop() orelse return error.ReturnWithoutGosub;
            // A RETURN discards loops opened in the subroutine. BASIC variables
            // themselves are shared between the caller and the subroutine.
            self.loops = frame.caller_loops;
            return frame.continuation;
        }

        fn close(self: *Self) !void {
            const file = self.file orelse return error.FileNotOpen;
            defer self.release();
            try self.output(true, "\x1a");
            // GW-BASIC reuses the last record as the buffer for the next one.
            if (self.used != 0) try file.writeStreamingAll(self.io, &self.record);
        }
    };
}

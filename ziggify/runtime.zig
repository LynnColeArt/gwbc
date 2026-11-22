comptime {
    if (!std.debug.runtime_safety) @compileError("GW-BASIC programs require Debug or ReleaseSafe");
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

    fn length(value: BasicString) Number {
        return .{ .integer = value.size };
    }

    fn mid(value: BasicString, position_arg: Number, count_arg: Number) !BasicString {
        const position = try position_arg.asInteger();
        const count = try count_arg.asInteger();
        if (position < 1 or position > 255 or count < 0 or count > 255)
            return error.IllegalFunctionCall;
        const start = @min(@as(usize, @intCast(position - 1)), value.size);
        const end = @min(start + @as(usize, @intCast(count)), value.size);
        return fromBytes(value.bytes()[start..end]);
    }

    fn right(value: BasicString, count_arg: Number) !BasicString {
        const count = try count_arg.asInteger();
        if (count < 0 or count > 255) return error.IllegalFunctionCall;
        const size = @min(@as(usize, @intCast(count)), value.size);
        return fromBytes(value.bytes()[value.size - size ..]);
    }

    fn val(value: BasicString) !Number {
        var compact: [255]u8 = undefined;
        var length_used: usize = 0;
        for (value.bytes()) |byte| {
            if (byte == ' ') continue;
            compact[length_used] = byte;
            length_used += 1;
        }
        const text = compact[0..length_used];
        const end = Number.scan(text);
        if (end == 0) return .{ .integer = 0 };
        return Number.parse(text[0..end]);
    }
};

fn ProgramRuntime(comptime numeric_count: usize, comptime string_count: usize) type {
    return struct {
        const Self = @This();
        const Loop = struct {
            line: u16,
            limit: Number,
            step: Number,
            integer: bool,

            fn includes(self: Loop, value: Number) bool {
                const step = self.step.asSingle();
                const limit = self.limit.asSingle();
                return step == 0 or if (step > 0) value.asSingle() <= limit else value.asSingle() >= limit;
            }
        };

        const Subroutine = struct {
            continuation: u16,
            caller_loops: [numeric_count]?Loop,
        };

        io: std.Io,
        allocator: std.mem.Allocator,
        stdin: std.Io.File.Reader,
        variables: [numeric_count]Number = @splat(.{ .integer = 0 }),
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

        fn readNumber(self: *Self, index: usize, integer: bool) Number {
            const value = self.variables[index];
            return if (integer) value else .{ .single = value.asSingle() };
        }

        fn number(self: *Self, to_file: bool, value: Number) !void {
            var buffer: [24]u8 = undefined;
            if (value.asSingle() >= 0) try self.output(to_file, " ");
            try self.output(to_file, try value.display(&buffer));
            try self.output(to_file, " ");
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

        fn input(self: *Self, prompt: []const u8, question: bool, integer: bool) !Number {
            while (true) {
                const trimmed = std.mem.trim(u8, try self.answer(prompt, question), " ");
                if (trimmed.len == 0) return (Number{ .integer = 0 }).convert(integer);
                if (Number.parse(trimmed)) |value| {
                    return value.convert(integer);
                } else |err| switch (err) {
                    error.InvalidNumber => try self.output(false, "?Redo from start\n"),
                    error.Overflow => return err,
                }
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

        fn beginLoop(self: *Self, index: usize, line: u16, integer: bool, start: Number, limit: Number, step: Number) !bool {
            const loop = Loop{
                .line = line,
                .limit = try limit.convert(integer),
                .step = try step.convert(integer),
                .integer = integer,
            };
            self.variables[index] = try start.convert(integer);
            const enters = loop.includes(self.variables[index]);
            self.loops[index] = if (enters) loop else null;
            return enters;
        }

        fn nextLoop(self: *Self, index: usize, line: u16) !bool {
            const loop = self.loops[index] orelse return error.NextWithoutFor;
            if (loop.line != line) return error.NextWithoutFor;
            const value = try (try Number.binary(.add, self.variables[index], loop.step)).convert(loop.integer);
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

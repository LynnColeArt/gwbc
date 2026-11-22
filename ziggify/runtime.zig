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

const Runtime = struct {
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
        caller_loops: [26]?Loop,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    stdin: std.Io.File.Reader,
    variables: [26]i16 = @splat(0),
    loops: [26]?Loop = @splat(null),
    subroutines: std.ArrayList(Subroutine) = .empty,
    file: ?std.Io.File = null,
    record: [128]u8 = @splat(0),
    used: usize = 0,

    fn open(self: *Runtime) !void {
        if (self.file != null) return error.FileAlreadyOpen;
        self.file = try std.Io.Dir.cwd().createFile(self.io, "OUT.TXT", .{});
        self.record = @splat(0);
        self.used = 0;
    }

    fn release(self: *Runtime) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    fn output(self: *Runtime, to_file: bool, bytes: []const u8) !void {
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

    fn newline(self: *Runtime, to_file: bool) !void {
        try self.output(to_file, if (to_file) "\r\n" else "\n");
    }

    fn number(self: *Runtime, to_file: bool, value: i16) !void {
        var buffer: [12]u8 = undefined;
        if (value >= 0) try self.output(to_file, " ");
        try self.output(to_file, try std.fmt.bufPrint(&buffer, "{d} ", .{value}));
    }

    fn input(self: *Runtime, prompt: []const u8, question: bool) !i16 {
        // The terminal supplies its own input echo. Reproduce it for pipes/files.
        const echo = !try std.Io.File.stdin().isTty(self.io);
        while (true) {
            try self.output(false, prompt);
            if (question) try self.output(false, "? ");
            const line = try self.stdin.interface.takeDelimiter('\n') orelse return error.EndOfInput;
            const response = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
            if (echo) {
                try self.output(false, response);
                try self.newline(false);
            }
            const trimmed = std.mem.trim(u8, response, " ");
            if (trimmed.len == 0) return 0;
            const digits = if (trimmed[0] == '+' or trimmed[0] == '-') trimmed[1..] else trimmed;
            if (digits.len != 0 and std.mem.findNone(u8, digits, "0123456789") == null) {
                return std.fmt.parseInt(i16, trimmed, 10);
            }
            try self.output(false, "?Redo from start\n");
        }
    }

    fn beginLoop(self: *Runtime, index: u8, line: u16, start: i16, limit: i16, step: i16) bool {
        const loop = Loop{ .line = line, .limit = limit, .step = step };
        self.variables[index] = start;
        const enters = loop.includes(start);
        self.loops[index] = if (enters) loop else null;
        return enters;
    }

    fn nextLoop(self: *Runtime, index: u8, line: u16) !bool {
        const loop = self.loops[index] orelse return error.NextWithoutFor;
        if (loop.line != line) return error.NextWithoutFor;
        const value = try std.math.add(i16, self.variables[index], loop.step);
        self.variables[index] = value;
        if (loop.includes(value)) return true;
        self.loops[index] = null;
        return false;
    }

    fn beginSubroutine(self: *Runtime, continuation: u16) !void {
        try self.subroutines.append(self.allocator, .{ .continuation = continuation, .caller_loops = self.loops });
        self.loops = @splat(null);
    }

    fn endSubroutine(self: *Runtime) !u16 {
        const frame = self.subroutines.pop() orelse return error.ReturnWithoutGosub;
        // A RETURN discards loops opened in the subroutine. BASIC variables
        // themselves are shared between the caller and the subroutine.
        self.loops = frame.caller_loops;
        return frame.continuation;
    }

    fn close(self: *Runtime) !void {
        const file = self.file orelse return error.FileNotOpen;
        defer self.release();
        try self.output(true, "\x1a");
        // GW-BASIC reuses the last record as the buffer for the next one.
        if (self.used != 0) try file.writeStreamingAll(self.io, &self.record);
    }
};

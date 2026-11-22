const std = @import("std");

comptime {
    if (!std.debug.runtime_safety) @compileError("GW-BASIC programs require Debug or ReleaseSafe");
}

const Runtime = struct {
    io: std.Io,
    variables: [26]i16 = @splat(0),
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

    fn write(self: *Runtime, bytes: []const u8) !void {
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

    fn text(self: *Runtime, value: []const u8) !void {
        try self.write(value);
        try self.write("\r\n");
    }

    fn number(self: *Runtime, value: i16) !void {
        var buffer: [12]u8 = undefined;
        if (value >= 0) try self.write(" ");
        try self.write(try std.fmt.bufPrint(&buffer, "{d} \r\n", .{value}));
    }

    fn close(self: *Runtime) !void {
        const file = self.file orelse return error.FileNotOpen;
        defer self.release();
        try self.write("\x1a");
        // GW-BASIC reuses the last record as the buffer for the next one.
        if (self.used != 0) try file.writeStreamingAll(self.io, &self.record);
    }
};

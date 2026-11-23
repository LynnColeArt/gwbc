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

const DataItem = struct { text: []const u8, quoted: bool };

fn BasicArray(comptime T: type) type {
    return struct {
        const Self = @This();
        elements: ?[]T = null,

        fn dimension(self: *Self, allocator: std.mem.Allocator, upper_bound: i16, initial: T) !void {
            if (self.elements != null) return error.RedimensionedArray;
            if (upper_bound < 0) return error.SubscriptOutOfRange;
            const elements = try allocator.alloc(T, @as(usize, @intCast(upper_bound)) + 1);
            @memset(elements, initial);
            self.elements = elements;
        }

        fn element(self: *Self, allocator: std.mem.Allocator, subscript: Number, initial: T) !*T {
            const index = try subscript.asInteger();
            if (index < 0 or (self.elements == null and index > 10)) return error.SubscriptOutOfRange;
            if (self.elements == null) try self.dimension(allocator, 10, initial);
            const elements = self.elements.?;
            const offset: usize = @intCast(index);
            if (offset >= elements.len) return error.SubscriptOutOfRange;
            return &elements[offset];
        }
    };
}

const FileMode = enum { input, output, append };
const InputKind = enum { text, integer, single };
const InputValue = union { text: BasicString, number: Number };

fn inputValue(kind: InputKind, field: []const u8, quoted: bool) !InputValue {
    if (kind == .text) return .{ .text = try BasicString.fromBytes(field) };
    if (quoted) return error.InvalidNumber;
    const value: Number = if (field.len == 0) .{ .integer = 0 } else try Number.parse(field);
    return .{ .number = try value.convert(kind == .integer) };
}

const SequentialFile = struct {
    file: std.Io.File,
    mode: FileMode,
    record: [128]u8 = @splat(0),
    offset: u64 = 0,
    used: usize = 0,
    available: usize = 0,

    fn seekAppend(self: *SequentialFile, io: std.Io) !void {
        while (true) {
            const count = try self.file.readPositionalAll(io, &self.record, self.offset);
            if (std.mem.indexOfScalar(u8, self.record[0..count], 0x1a)) |end| {
                self.used = end;
                return;
            }
            if (count < self.record.len) {
                self.used = count;
                return;
            }
            self.offset += count;
        }
    }

    fn peek(self: *SequentialFile, io: std.Io) !?u8 {
        if (self.used == self.available) {
            self.offset += self.available;
            self.available = try self.file.readPositionalAll(io, &self.record, self.offset);
            self.used = 0;
            if (self.available == 0) return null;
        }
        const byte = self.record[self.used];
        return if (byte == 0x1a) null else byte;
    }

    fn consumeLineBreak(self: *SequentialFile, io: std.Io, byte: u8) !void {
        self.used += 1;
        if (byte == '\r' and try self.peek(io) == '\n') self.used += 1;
    }

    fn readLine(self: *SequentialFile, io: std.Io) !BasicString {
        if (try self.peek(io) == null) return error.InputPastEnd;
        var text: [255]u8 = undefined;
        var length: usize = 0;
        while (length < text.len) {
            const byte = try self.peek(io) orelse break;
            if (byte == '\r' or byte == '\n') {
                try self.consumeLineBreak(io, byte);
                break;
            }
            text[length] = byte;
            length += 1;
            self.used += 1;
        }
        return BasicString.fromBytes(text[0..length]);
    }

    fn readField(self: *SequentialFile, io: std.Io, kind: InputKind) !InputValue {
        if (try self.peek(io) == null) return error.InputPastEnd;
        while (try self.peek(io) == ' ') self.used += 1;
        const quoted = try self.peek(io) == '"';
        if (quoted) self.used += 1;
        var text: [255]u8 = undefined;
        var length: usize = 0;
        while (try self.peek(io)) |byte| {
            if (quoted and byte == '"') {
                self.used += 1;
                break;
            }
            if (!quoted and (byte == ',' or byte == '\r' or byte == '\n' or
                (kind != .text and byte == ' '))) break;
            if (length == text.len) return error.StringTooLong;
            text[length] = byte;
            length += 1;
            self.used += 1;
        }
        if (quoted or kind != .text) {
            while (try self.peek(io) == ' ') self.used += 1;
        }
        if (try self.peek(io)) |byte| {
            switch (byte) {
                ',' => self.used += 1,
                '\r', '\n' => try self.consumeLineBreak(io, byte),
                else => if (quoted or kind == .text) return error.InvalidFileField,
            }
        }
        const field = text[0..length];
        return inputValue(kind, if (quoted) field else std.mem.trimEnd(u8, field, " "), quoted);
    }

    fn write(self: *SequentialFile, io: std.Io, bytes: []const u8) !void {
        for (bytes) |byte| {
            self.record[self.used] = byte;
            self.used += 1;
            if (self.used == self.record.len) {
                try self.file.writePositionalAll(io, &self.record, self.offset);
                self.offset += self.record.len;
                self.used = 0;
            }
        }
    }
};

fn consoleFields(response: []const u8, kinds: []const InputKind, values: []InputValue) !void {
    var rest = std.mem.trimStart(u8, response, " ");
    for (kinds, values, 0..) |kind, *value, index| {
        const quoted = std.mem.startsWith(u8, rest, "\"");
        const text = if (quoted) blk: {
            const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.InvalidField;
            const field = rest[1..end];
            rest = std.mem.trimStart(u8, rest[end + 1 ..], " ");
            break :blk field;
        } else blk: {
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            const field = std.mem.trimEnd(u8, rest[0..end], " ");
            rest = rest[end..];
            break :blk field;
        };
        value.* = try inputValue(kind, text, quoted);
        if (index + 1 == kinds.len) {
            if (rest.len != 0) return error.InvalidField;
        } else {
            if (!std.mem.startsWith(u8, rest, ",")) return error.InvalidField;
            rest = std.mem.trimStart(u8, rest[1..], " ");
        }
    }
}

fn ProgramRuntime(
    comptime numeric_count: usize,
    comptime string_count: usize,
    comptime numeric_arrays: usize,
    comptime string_arrays: usize,
) type {
    return struct {
        const Self = @This();
        const Loop = struct {
            line: usize,
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
            continuation: usize,
            caller_loops: [numeric_count]?Loop,
        };

        io: std.Io,
        allocator: std.mem.Allocator,
        stdin: std.Io.File.Reader,
        variables: [numeric_count]Number = @splat(.{ .integer = 0 }),
        strings: [string_count]BasicString = @splat(.{}),
        number_arrays: [numeric_arrays]BasicArray(Number) = @splat(.{}),
        text_arrays: [string_arrays]BasicArray(BasicString) = @splat(.{}),
        data: []const DataItem,
        data_index: usize = 0,
        loops: [numeric_count]?Loop = @splat(null),
        subroutines: std.ArrayList(Subroutine) = .empty,
        files: [256]?SequentialFile = @splat(null),
        console_column: usize = 0,

        fn dimensionNumber(self: *Self, slot: usize, bound: Number, integer: bool) !void {
            const initial: Number = if (integer) .{ .integer = 0 } else .{ .single = 0 };
            try self.number_arrays[slot].dimension(self.allocator, try bound.asInteger(), initial);
        }

        fn dimensionString(self: *Self, slot: usize, bound: Number) !void {
            try self.text_arrays[slot].dimension(self.allocator, try bound.asInteger(), .{});
        }

        fn numberElement(self: *Self, slot: usize, subscript: Number, integer: bool) !*Number {
            const initial: Number = if (integer) .{ .integer = 0 } else .{ .single = 0 };
            return self.number_arrays[slot].element(self.allocator, subscript, initial);
        }

        fn stringElement(self: *Self, slot: usize, subscript: Number) !*BasicString {
            return self.text_arrays[slot].element(self.allocator, subscript, .{});
        }

        fn readData(self: *Self) !DataItem {
            if (self.data_index == self.data.len) return error.OutOfData;
            const item = self.data[self.data_index];
            self.data_index += 1;
            return item;
        }

        fn readDataNumber(self: *Self, integer: bool) !Number {
            const item = try self.readData();
            if (item.quoted) return error.TypeMismatch;
            if (item.text.len == 0) return (Number{ .integer = 0 }).convert(integer);
            const value = Number.parse(item.text) catch |err| switch (err) {
                error.InvalidNumber => return error.TypeMismatch,
                else => return err,
            };
            return value.convert(integer);
        }

        fn readDataString(self: *Self) !BasicString {
            return BasicString.fromBytes((try self.readData()).text);
        }

        fn open(self: *Self, channel: u8, mode: FileMode, name: BasicString) !void {
            if (self.files[channel] != null) return error.FileAlreadyOpen;
            const cwd = std.Io.Dir.cwd();
            const name_bytes = name.bytes();
            var folded: [255]u8 = undefined;
            // Bare BASIC filenames follow DOS casing. Explicit host paths
            // retain their spelling so native utilities can use host files.
            const path = if (std.mem.indexOfAny(u8, name_bytes, "/\\:") == null)
                std.ascii.upperString(folded[0..name_bytes.len], name_bytes)
            else
                name_bytes;
            const file = switch (mode) {
                .input => try cwd.openFile(self.io, path, .{}),
                .output => try cwd.createFile(self.io, path, .{}),
                .append => try cwd.createFile(self.io, path, .{ .read = true, .truncate = false }),
            };
            errdefer file.close(self.io);
            var sequential: SequentialFile = .{ .file = file, .mode = mode };
            if (mode == .append) try sequential.seekAppend(self.io);
            self.files[channel] = sequential;
        }

        fn release(self: *Self) void {
            for (&self.files) |*slot| {
                if (slot.*) |file| file.file.close(self.io);
                slot.* = null;
            }
        }

        fn fileForInput(self: *Self, channel: u8) !*SequentialFile {
            const file = if (self.files[channel]) |*file| file else return error.FileNotOpen;
            if (file.mode != .input) return error.BadFileMode;
            return file;
        }

        fn eof(self: *Self, number_value: Number) !Number {
            const channel = std.math.cast(u8, try number_value.asInteger()) orelse return error.InvalidFileChannel;
            const file = try self.fileForInput(channel);
            return .{ .integer = if (try file.peek(self.io) == null) -1 else 0 };
        }

        fn output(self: *Self, channel: u8, bytes: []const u8) !void {
            if (channel == 0) {
                try std.Io.File.stdout().writeStreamingAll(self.io, bytes);
                if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |last| {
                    self.console_column = bytes.len - last - 1;
                } else {
                    self.console_column += bytes.len;
                }
                return;
            }
            const file = if (self.files[channel]) |*file| file else return error.FileNotOpen;
            if (file.mode == .input) return error.BadFileMode;
            try file.write(self.io, bytes);
        }

        fn newline(self: *Self, channel: u8) !void {
            try self.output(channel, if (channel != 0) "\r\n" else "\n");
        }

        fn printZone(self: *Self) !void {
            const padding = 14 - self.console_column % 14;
            // The DOS console uses five full zones on an 80-column screen.
            if (self.console_column + padding >= 5 * 14) return self.newline(0);
            try self.output(0, "              "[0..padding]);
        }

        fn readNumber(self: *Self, index: usize, integer: bool) Number {
            const value = self.variables[index];
            return if (integer) value else .{ .single = value.asSingle() };
        }

        fn number(self: *Self, channel: u8, value: Number) !void {
            var buffer: [24]u8 = undefined;
            if (value.asSingle() >= 0) try self.output(channel, " ");
            try self.output(channel, try value.display(&buffer));
            try self.output(channel, " ");
        }

        fn answer(self: *Self, prompt: []const u8, question: bool) ![]const u8 {
            // The terminal supplies its own input echo. Reproduce it for pipes/files.
            const echo = !try std.Io.File.stdin().isTty(self.io);
            try self.output(0, prompt);
            if (question) try self.output(0, "? ");
            const line = try self.stdin.interface.takeDelimiter('\n') orelse return error.EndOfInput;
            const response = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
            if (echo) {
                try self.output(0, response);
                try self.newline(0);
            } else {
                self.console_column = 0;
            }
            return response;
        }

        fn input(
            self: *Self,
            channel: u8,
            prompt: []const u8,
            question: bool,
            comptime whole_line: bool,
            comptime kinds: []const InputKind,
        ) ![kinds.len]InputValue {
            var values: [kinds.len]InputValue = undefined;
            if (channel != 0) {
                const file = try self.fileForInput(channel);
                if (whole_line) {
                    values[0] = .{ .text = try file.readLine(self.io) };
                } else {
                    for (kinds, &values) |kind, *value| value.* = try file.readField(self.io, kind);
                }
                return values;
            }
            while (true) {
                const response = try self.answer(prompt, question);
                if (whole_line) {
                    values[0] = .{ .text = try BasicString.fromBytes(response) };
                    return values;
                }
                consoleFields(response, kinds, &values) catch |err| switch (err) {
                    error.InvalidField, error.InvalidNumber => {
                        try self.output(0, "?Redo from start\n");
                        continue;
                    },
                    else => return err,
                };
                return values;
            }
        }

        fn printString(self: *Self, channel: u8, value: BasicString) !void {
            try self.output(channel, value.bytes());
        }

        fn beginLoop(self: *Self, index: usize, line: usize, integer: bool, start: Number, limit: Number, step: Number) !bool {
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

        fn nextLoop(self: *Self, index: usize, line: usize) !bool {
            const loop = self.loops[index] orelse return error.NextWithoutFor;
            if (loop.line != line) return error.NextWithoutFor;
            const value = try (try Number.binary(.add, self.variables[index], loop.step)).convert(loop.integer);
            self.variables[index] = value;
            if (loop.includes(value)) return true;
            self.loops[index] = null;
            return false;
        }

        fn beginSubroutine(self: *Self, continuation: usize) !void {
            try self.subroutines.append(self.allocator, .{ .continuation = continuation, .caller_loops = self.loops });
            self.loops = @splat(null);
        }

        fn endSubroutine(self: *Self) !usize {
            const frame = self.subroutines.pop() orelse return error.ReturnWithoutGosub;
            // A RETURN discards loops opened in the subroutine. BASIC variables
            // themselves are shared between the caller and the subroutine.
            self.loops = frame.caller_loops;
            return frame.continuation;
        }

        fn close(self: *Self, channel: u8) !void {
            const file = if (self.files[channel]) |*file| file else return;
            defer {
                file.file.close(self.io);
                self.files[channel] = null;
            }
            if (file.mode == .input) return;
            try file.write(self.io, "\x1a");
            // GW-BASIC reuses the last record as the buffer for the next one.
            if (file.used != 0) try file.file.writePositionalAll(self.io, &file.record, file.offset);
            try file.file.setLength(self.io, file.offset + if (file.used != 0) file.record.len else 0);
        }

        fn closeAll(self: *Self) !void {
            for (1..self.files.len) |channel| try self.close(@intCast(channel));
        }
    };
}

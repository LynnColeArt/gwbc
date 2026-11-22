const std = @import("std");

pub const Number = union(enum) {
    integer: i16,
    single: f32,

    pub const Operation = enum {
        add,
        sub,
        mul,
        divide,
        div_trunc,
        remainder,
        bit_and,
        bit_or,
    };

    // Scan a decimal literal without consuming a keyword or trailing expression.
    pub fn scan(text: []const u8) usize {
        if (text.len == 0) return 0;
        var index: usize = if (text[0] == '+' or text[0] == '-') 1 else 0;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        var digits = index - start;
        if (index < text.len and text[index] == '.') {
            index += 1;
            const fraction = index;
            while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
            digits += index - fraction;
        }
        if (digits == 0) return 0;
        if (index < text.len and std.ascii.toUpper(text[index]) == 'E') {
            var exponent = index + 1;
            if (exponent < text.len and (text[exponent] == '+' or text[exponent] == '-')) exponent += 1;
            const first_digit = exponent;
            while (exponent < text.len and std.ascii.isDigit(text[exponent])) : (exponent += 1) {}
            if (exponent != first_digit) index = exponent;
        }
        if (index < text.len and text[index] == '!') index += 1;
        return index;
    }

    pub fn parse(text: []const u8) error{ InvalidNumber, Overflow }!Number {
        if (text.len == 0 or scan(text) != text.len) return error.InvalidNumber;
        const force_single = text[text.len - 1] == '!';
        if (!force_single) {
            if (std.fmt.parseInt(i16, text, 10)) |value| return .{ .integer = value } else |_| {}
        }
        const decimal = if (force_single) text[0 .. text.len - 1] else text;
        const value = std.fmt.parseFloat(f32, decimal) catch return error.InvalidNumber;
        return checkedSingle(value);
    }

    pub fn literal(text: []const u8) error{ InvalidNumber, Overflow, UnsupportedDouble }!Number {
        if (text.len != 0 and text[text.len - 1] != '!') {
            var significant: usize = 0;
            for (text) |byte| {
                if (std.ascii.toUpper(byte) == 'E') break;
                if (std.ascii.isDigit(byte) and (byte != '0' or significant != 0)) significant += 1;
            }
            if (significant > 7) return error.UnsupportedDouble;
        }
        return parse(text);
    }

    fn checkedSingle(value: f32) error{Overflow}!Number {
        const magnitude = @abs(value);
        if (!std.math.isFinite(value) or magnitude >= 0x1p127) return error.Overflow;
        return .{ .single = if (magnitude < 0x1p-128) 0 else value };
    }

    pub fn asSingle(self: Number) f32 {
        return switch (self) {
            .integer => |value| @floatFromInt(value),
            .single => |value| value,
        };
    }

    pub fn asInteger(self: Number) error{Overflow}!i16 {
        return switch (self) {
            .integer => |value| value,
            .single => |value| blk: {
                const rounded = @round(value);
                if (rounded < -32768 or rounded > 32767) return error.Overflow;
                break :blk @intFromFloat(rounded);
            },
        };
    }

    pub fn convert(self: Number, integer: bool) !Number {
        return if (integer) .{ .integer = try self.asInteger() } else .{ .single = self.asSingle() };
    }

    pub fn negate(self: Number) !Number {
        return binary(.sub, .{ .integer = 0 }, self);
    }

    pub fn binary(operation: Operation, left: Number, right: Number) !Number {
        switch (operation) {
            .add, .sub, .mul => {
                if (left == .integer and right == .integer) {
                    const a: i32 = left.integer;
                    const b: i32 = right.integer;
                    const wide = switch (operation) {
                        .add => a + b,
                        .sub => a - b,
                        .mul => a * b,
                        else => unreachable,
                    };
                    if (std.math.cast(i16, wide)) |small| return .{ .integer = small };
                }
                const a = left.asSingle();
                const b = right.asSingle();
                return checkedSingle(switch (operation) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    else => unreachable,
                });
            },
            .divide => {
                const divisor = right.asSingle();
                if (divisor == 0) return error.DivisionByZero;
                return checkedSingle(left.asSingle() / divisor);
            },
            .div_trunc, .remainder, .bit_and, .bit_or => {
                const a = try left.asInteger();
                const b = try right.asInteger();
                return .{ .integer = switch (operation) {
                    .div_trunc => try std.math.divTrunc(i16, a, b),
                    .remainder => @intCast(try std.math.rem(i32, a, @intCast(@abs(@as(i32, b))))),
                    .bit_and => a & b,
                    .bit_or => a | b,
                    else => unreachable,
                } };
            },
        }
    }

    pub fn display(self: Number, buffer: []u8) ![]const u8 {
        return switch (self) {
            .integer => |value| std.fmt.bufPrint(buffer, "{d}", .{value}),
            .single => |value| formatSingle(value, buffer),
        };
    }

    fn formatSingle(value: f32, buffer: []u8) ![]const u8 {
        if (value == 0) return std.fmt.bufPrint(buffer, "0", .{});
        const magnitude: f64 = @abs(value);
        var exponent: i32 = @intFromFloat(@floor(@log10(magnitude)));
        const power = std.math.pow(f64, 10, @floatFromInt(6 - exponent));
        // BASIC rounds the scaled significand to single precision before
        // rounding decimal digits. This affects results such as 1 / 7.
        const scaled: f32 = @floatCast(magnitude * power);
        var significant: u32 = @intFromFloat(@floor(@as(f64, scaled) + 0.5));
        if (significant >= 10_000_000) {
            significant /= 10;
            exponent += 1;
        }
        var digits_buffer: [7]u8 = undefined;
        const digits = std.mem.trimEnd(u8, try std.fmt.bufPrint(&digits_buffer, "{d}", .{significant}), "0");
        var output: std.Io.Writer = .fixed(buffer);
        if (value < 0) try output.writeByte('-');

        const point = exponent + 1;
        if (point > 7 or (point <= 0 and @as(i32, @intCast(digits.len)) - point > 7)) {
            try output.writeAll(digits[0..1]);
            if (digits.len > 1) {
                try output.writeByte('.');
                try output.writeAll(digits[1..]);
            }
            try output.print("E{c}{d:0>2}", .{ @as(u8, if (exponent < 0) '-' else '+'), @abs(exponent) });
        } else if (point <= 0) {
            try output.writeByte('.');
            try output.splatByteAll('0', @intCast(-point));
            try output.writeAll(digits);
        } else {
            const split: usize = @intCast(point);
            if (split >= digits.len) {
                try output.writeAll(digits);
                try output.splatByteAll('0', split - digits.len);
            } else {
                try output.writeAll(digits[0..split]);
                try output.writeByte('.');
                try output.writeAll(digits[split..]);
            }
        }
        return output.buffered();
    }
};

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Number = @import("numeric.zig").Number;
const tokenized = @import("tokenized.zig");

const ValueKind = enum { number, string };
const Variable = struct {
    kind: ValueKind,
    slot: usize,
    integer: bool,

    fn field(self: Variable) []const u8 {
        return if (self.kind == .number) "variables" else "strings";
    }
};

const Names = struct {
    const Key = [41]u8;
    numbers: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    strings: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    number_arrays: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    string_arrays: std.AutoHashMapUnmanaged(Key, usize) = .empty,

    fn intern(self: *Names, allocator: Allocator, key: Key, array: bool) !Variable {
        const kind: ValueKind = if (key[0] == '$') .string else .number;
        const table = switch (kind) {
            .number => if (array) &self.number_arrays else &self.numbers,
            .string => if (array) &self.string_arrays else &self.strings,
        };
        const count = table.count();
        const entry = try table.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = count;
        return .{ .kind = kind, .slot = entry.value_ptr.*, .integer = key[0] == '%' };
    }
};

const Reference = struct {
    variable: Variable,
    subscript: ?*const Expression = null,

    fn emit(self: Reference, out: *Writer, writable: bool) Writer.Error!void {
        const variable = self.variable;
        if (self.subscript) |index| {
            const method = if (variable.kind == .number) "numberElement" else "stringElement";
            try out.print("(try runtime.{s}({d}, ", .{ method, variable.slot });
            try index.emit(out);
            if (variable.kind == .number) try out.print(", {}", .{variable.integer});
            try out.writeAll(")).*");
        } else if (variable.kind == .number and !writable) {
            try out.print("runtime.readNumber({d}, {})", .{ variable.slot, variable.integer });
        } else {
            try out.print("runtime.{s}[{d}]", .{ variable.field(), variable.slot });
        }
    }
};

const Operation = enum {
    add,
    sub,
    mul,
    divide,
    div_trunc,
    remainder,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    bit_and,
    bit_or,

    fn comparisonToken(self: Operation) ?[]const u8 {
        return switch (self) {
            .equal => "==",
            .not_equal => "!=",
            .less => "<",
            .greater => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            else => null,
        };
    }
};

const Builtin = enum {
    length,
    mid,
    right,
    val,

    fn arity(self: Builtin) usize {
        return switch (self) {
            .length, .val => 1,
            .right => 2,
            .mid => 3,
        };
    }

    fn kind(self: Builtin) ValueKind {
        return switch (self) {
            .length, .val => .number,
            .mid, .right => .string,
        };
    }
};

const Expression = union(enum) {
    literal: Number,
    text: []const u8,
    variable: Reference,
    builtin: struct { function: Builtin, args: [3]*const Expression },
    negate: *const Expression,
    eof: *const Expression,
    bit_not: *const Expression,
    binary: struct { operation: Operation, left: *const Expression, right: *const Expression },

    fn kind(self: Expression) ValueKind {
        return switch (self) {
            .text => .string,
            .variable => |reference| reference.variable.kind,
            .builtin => |builtin| builtin.function.kind(),
            .binary => |binary| if (binary.operation == .add) binary.left.kind() else .number,
            .literal, .negate, .eof, .bit_not => .number,
        };
    }

    fn emit(self: Expression, out: *Writer) Writer.Error!void {
        switch (self) {
            .literal => |value| switch (value) {
                .integer => |integer| try out.print("(Number{{ .integer = {d} }})", .{integer}),
                .single => |single| try out.print("(Number{{ .single = @bitCast(@as(u32, {d})) }})", .{@as(u32, @bitCast(single))}),
            },
            .text => |value| try out.print("(try BasicString.fromBytes(\"{f}\"))", .{std.zig.fmtString(value)}),
            .variable => |reference| try reference.emit(out, false),
            .builtin => |builtin| {
                const can_fail = builtin.function != .length;
                try out.print("{s}BasicString.{s}(", .{ if (can_fail) "(try " else "", @tagName(builtin.function) });
                for (builtin.args[0..builtin.function.arity()], 0..) |argument, index| {
                    if (index != 0) try out.writeAll(", ");
                    try argument.emit(out);
                }
                try out.writeAll(if (can_fail) "))" else ")");
            },
            .bit_not => |operand| {
                try out.writeAll("(Number{ .integer = ~(try ");
                try operand.emit(out);
                try out.writeAll(".asInteger()) })");
            },
            .eof => |channel| {
                try out.writeAll("(try runtime.eof(");
                try channel.emit(out);
                try out.writeAll("))");
            },
            .negate => |operand| {
                try out.writeAll("(try Number.negate(");
                try operand.emit(out);
                try out.writeAll("))");
            },
            .binary => |binary| {
                if (binary.operation.comparisonToken()) |token| {
                    try out.writeAll("(Number{ .integer = if (");
                    if (binary.left.kind() == .string) {
                        try out.writeAll("BasicString.compare(");
                        try binary.left.emit(out);
                        try out.writeAll(", ");
                        try binary.right.emit(out);
                        try out.print(") {s} 0", .{token});
                    } else {
                        try binary.left.emit(out);
                        try out.print(".asSingle() {s} ", .{token});
                        try binary.right.emit(out);
                        try out.writeAll(".asSingle()");
                    }
                    try out.writeAll(") -1 else 0 })");
                } else {
                    if (binary.left.kind() == .string) {
                        try out.writeAll("(try BasicString.concat(");
                    } else {
                        try out.print("(try Number.binary(.{s}, ", .{@tagName(binary.operation)});
                    }
                    try binary.left.emit(out);
                    try out.writeAll(", ");
                    try binary.right.emit(out);
                    try out.writeAll("))");
                }
            },
        }
    }
};

const FileMode = enum { input, output, append };
const Print = struct {
    const Item = struct { value: *const Expression, comma_after: bool };
    channel: u8,
    values: []const Item,
};

const Assignment = struct { target: Reference, value: *const Expression };
const DataItem = struct { text: []const u8, quoted: bool };
const Statement = union(enum) {
    remark,
    open: struct { mode: FileMode, name: *const Expression, channel: u8 },
    print: Print,
    input: struct { targets: []const Reference, prompt: []const u8 = "", question: bool = false, whole_line: bool, channel: u8 = 0 },
    data: []const DataItem,
    read: []const Reference,
    dim: []const Reference,
    restore: ?u16,
    for_loop: struct { variable: Variable, start: *const Expression, limit: *const Expression, step: *const Expression },
    next_loop: ?usize,
    assign: Assignment,
    jump: u16,
    gosub: u16,
    return_from_subroutine: ?u16,
    branch: struct { condition: *const Expression, false_target: usize },
    skip: usize,
    while_loop: *const Expression,
    wend,
    close: []const u8,
    system,
};

const Instruction = struct {
    number: u16,
    statement: Statement,
    loop_partner: ?usize = null,
    restore_index: usize = 0,
};

const Line = struct {
    number: u16,
    statements: []Statement,

    fn lessThan(_: void, left: Line, right: Line) bool {
        return left.number < right.number;
    }
};

const Parser = struct {
    const ExpressionError = error{ OutOfMemory, InvalidSyntax, ExpectedVariable, TypeMismatch, Overflow, InvalidNumber, UnsupportedDouble };
    const Operator = struct { token: []const u8, operation: Operation, precedence: u8 };
    const operators = [_]Operator{
        .{ .token = "OR", .operation = .bit_or, .precedence = 1 },
        .{ .token = "AND", .operation = .bit_and, .precedence = 2 },
        .{ .token = "<=", .operation = .less_equal, .precedence = 3 },
        .{ .token = "=<", .operation = .less_equal, .precedence = 3 },
        .{ .token = ">=", .operation = .greater_equal, .precedence = 3 },
        .{ .token = "=>", .operation = .greater_equal, .precedence = 3 },
        .{ .token = "<>", .operation = .not_equal, .precedence = 3 },
        .{ .token = "><", .operation = .not_equal, .precedence = 3 },
        .{ .token = "=", .operation = .equal, .precedence = 3 },
        .{ .token = "<", .operation = .less, .precedence = 3 },
        .{ .token = ">", .operation = .greater, .precedence = 3 },
        .{ .token = "+", .operation = .add, .precedence = 4 },
        .{ .token = "-", .operation = .sub, .precedence = 4 },
        .{ .token = "MOD", .operation = .remainder, .precedence = 5 },
        .{ .token = "\\", .operation = .div_trunc, .precedence = 6 },
        .{ .token = "*", .operation = .mul, .precedence = 7 },
        .{ .token = "/", .operation = .divide, .precedence = 7 },
    };

    allocator: Allocator,
    names: *Names,
    rest: []const u8,

    fn space(self: *Parser) void {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
    }

    fn take(self: *Parser, prefix: []const u8) bool {
        self.space();
        if (!std.ascii.startsWithIgnoreCase(self.rest, prefix)) return false;
        self.rest = self.rest[prefix.len..];
        return true;
    }

    fn require(self: *Parser, prefix: []const u8) !void {
        if (!self.take(prefix)) return error.InvalidSyntax;
    }

    fn digits(self: *Parser) []const u8 {
        const end = std.mem.findNone(u8, self.rest, "0123456789") orelse self.rest.len;
        const result = self.rest[0..end];
        self.rest = self.rest[end..];
        return result;
    }

    fn lineNumber(self: *Parser) !u16 {
        self.space();
        const number = try std.fmt.parseInt(u16, self.digits(), 10);
        if (number > 65529) return error.InvalidLineNumber;
        return number;
    }

    fn variableName(self: *Parser) ExpressionError!Names.Key {
        self.space();
        if (self.rest.len == 0 or !std.ascii.isAlphabetic(self.rest[0])) return error.ExpectedVariable;
        var end: usize = 1;
        while (end < self.rest.len and (std.ascii.isAlphanumeric(self.rest[end]) or self.rest[end] == '.')) : (end += 1) {}
        const suffix = if (end < self.rest.len and (self.rest[end] == '%' or self.rest[end] == '$' or self.rest[end] == '!')) self.rest[end] else 0;
        var key: Names.Key = @splat(0);
        key[0] = if (suffix == '!') 0 else suffix;
        for (self.rest[0..@min(end, 40)], key[1..][0..@min(end, 40)]) |byte, *canonical| {
            canonical.* = std.ascii.toUpper(byte);
        }
        self.rest = self.rest[end + @intFromBool(suffix != 0) ..];
        return key;
    }

    fn reference(self: *Parser) ExpressionError!Reference {
        const key = try self.variableName();
        if (!self.take("("))
            return .{ .variable = try self.names.intern(self.allocator, key, false) };
        const subscript = try self.numericExpression();
        try self.require(")");
        return .{ .variable = try self.names.intern(self.allocator, key, true), .subscript = subscript };
    }

    fn numericVariable(self: *Parser) ExpressionError!Variable {
        const result = try self.names.intern(self.allocator, try self.variableName(), false);
        if (result.kind != .number) return error.TypeMismatch;
        return result;
    }

    fn node(self: *Parser, value: Expression) !*const Expression {
        const result = try self.allocator.create(Expression);
        result.* = value;
        return result;
    }

    fn primary(self: *Parser) ExpressionError!*const Expression {
        if (self.take("(")) {
            const value = try self.expression(1);
            try self.require(")");
            return value;
        }
        if (self.take("\"")) return self.node(.{ .text = try self.string() });
        const before_eof = self.rest;
        if (self.take("EOF") and self.take("(")) {
            const channel = try self.numericExpression();
            try self.require(")");
            return self.node(.{ .eof = channel });
        }
        self.rest = before_eof;
        const functions = .{ .{ "LEN", Builtin.length }, .{ "MID$", Builtin.mid }, .{ "RIGHT$", Builtin.right }, .{ "VAL", Builtin.val } };
        inline for (functions) |function| {
            const previous = self.rest;
            if (self.take(function[0]) and self.take("(")) return self.builtinCall(function[1]);
            self.rest = previous;
        }
        if (self.rest.len != 0 and std.ascii.isAlphabetic(self.rest[0]))
            return self.node(.{ .variable = try self.reference() });
        return error.InvalidNumber;
    }

    fn builtinCall(self: *Parser, function: Builtin) ExpressionError!*const Expression {
        var args: [3]*const Expression = undefined;
        for (args[0..function.arity()], 0..) |*argument, index| {
            if (index != 0) try self.require(",");
            const value = try self.expression(1);
            const expected: ValueKind = if (index == 0) .string else .number;
            if (value.kind() != expected) return error.TypeMismatch;
            argument.* = value;
        }
        try self.require(")");
        return self.node(.{ .builtin = .{ .function = function, .args = args } });
    }

    fn prefixExpression(self: *Parser) ExpressionError!*const Expression {
        self.space();
        if (self.take("NOT")) {
            const operand = try self.expression(3);
            if (operand.kind() != .number) return error.TypeMismatch;
            return self.node(.{ .bit_not = operand });
        }
        // Scan signed literals together so -32768 keeps its integer type.
        const length = Number.scan(self.rest);
        if (length != 0) {
            const value = try Number.literal(self.rest[0..length]);
            self.rest = self.rest[length..];
            return self.node(.{ .literal = value });
        }
        if (self.take("-")) {
            const operand = try self.prefixExpression();
            if (operand.kind() != .number) return error.TypeMismatch;
            return self.node(.{ .negate = operand });
        }
        if (self.take("+")) {
            const operand = try self.prefixExpression();
            if (operand.kind() != .number) return error.TypeMismatch;
            return operand;
        }
        return self.primary();
    }

    fn binaryOperator(self: *Parser) ?Operator {
        self.space();
        for (operators) |operator| {
            if (std.ascii.startsWithIgnoreCase(self.rest, operator.token)) return operator;
        }
        return null;
    }

    fn expression(self: *Parser, minimum_precedence: u8) ExpressionError!*const Expression {
        var left = try self.prefixExpression();
        while (self.binaryOperator()) |operator| {
            if (operator.precedence < minimum_precedence) break;
            self.rest = self.rest[operator.token.len..];
            // A higher minimum for the right operand makes equal precedence
            // bind from left to right.
            const right = try self.expression(operator.precedence + 1);
            if (left.kind() != right.kind() or
                (left.kind() == .string and operator.operation != .add and operator.operation.comparisonToken() == null))
                return error.TypeMismatch;
            left = try self.node(.{ .binary = .{ .operation = operator.operation, .left = left, .right = right } });
        }
        return left;
    }

    fn numericExpression(self: *Parser) ExpressionError!*const Expression {
        const value = try self.expression(1);
        if (value.kind() != .number) return error.TypeMismatch;
        return value;
    }

    // The opening quote has already been consumed.
    fn string(self: *Parser) ![]const u8 {
        const end = std.mem.indexOfScalar(u8, self.rest, '"') orelse return error.InvalidSyntax;
        const value = self.rest[0..end];
        self.rest = self.rest[end + 1 ..];
        return value;
    }

    fn atElse(self: *Parser) bool {
        const rest = self.rest;
        if (!std.ascii.startsWithIgnoreCase(rest, "ELSE")) return false;
        return rest.len == 4 or !std.ascii.isAlphabetic(rest[4]);
    }

    fn atStatementEnd(self: *Parser) bool {
        self.space();
        return self.rest.len == 0 or self.rest[0] == ':' or self.rest[0] == '\'' or self.atElse();
    }

    fn printStatement(self: *Parser) !Print {
        const channel = if (self.take("#")) try self.fileChannel() else 0;
        if (channel != 0) try self.require(",");
        self.space();
        var values: std.ArrayList(Print.Item) = .empty;
        while (!self.atStatementEnd()) {
            const value = try self.expression(1);
            const comma = self.take(",");
            if (channel != 0 and comma) return error.UnsupportedFilePrintZone;
            try values.append(self.allocator, .{ .value = value, .comma_after = comma });
            if (!comma and !self.take(";")) break;
            if (self.atStatementEnd()) return error.UnsupportedTrailingPrintSeparator;
        }
        return .{ .channel = channel, .values = values.items };
    }

    fn assignment(self: *Parser, target: Reference) !Assignment {
        const value = try self.expression(1);
        if (value.kind() != target.variable.kind) return error.TypeMismatch;
        return .{ .target = target, .value = value };
    }

    fn references(self: *Parser, require_subscript: bool) ![]const Reference {
        var values: std.ArrayList(Reference) = .empty;
        while (true) {
            const target = try self.reference();
            if (require_subscript and target.subscript == null) return error.ExpectedArrayBound;
            try values.append(self.allocator, target);
            if (!self.take(",")) return values.items;
        }
    }

    fn dataItems(self: *Parser) ![]const DataItem {
        var items: std.ArrayList(DataItem) = .empty;
        while (true) {
            const quoted = self.take("\"");
            const text = if (quoted) try self.string() else blk: {
                const end = std.mem.indexOfAny(u8, self.rest, ",:") orelse self.rest.len;
                const value = self.rest[0..end];
                self.rest = self.rest[end..];
                break :blk std.mem.trim(u8, value, " ");
            };
            try items.append(self.allocator, .{ .text = text, .quoted = quoted });
            if (!self.take(",")) return items.items;
        }
    }

    // A branch owns the remainder of its physical line. Nested IFs consume
    // their own ELSE first, so an ELSE binds to the nearest unmatched IF.
    fn sequence(self: *Parser, statements: *std.ArrayList(Statement), allow_else: bool, line_target: bool) anyerror!void {
        self.space();
        if (line_target and self.rest.len != 0 and std.ascii.isDigit(self.rest[0])) {
            try statements.append(self.allocator, .{ .jump = try self.lineNumber() });
        } else if (self.take("IF")) {
            const condition = try self.numericExpression();
            try self.require("THEN");
            const branch_index = statements.items.len;
            try statements.append(self.allocator, .{ .branch = .{ .condition = condition, .false_target = undefined } });
            try self.sequence(statements, true, true);
            if (self.atElse()) {
                self.rest = self.rest[4..];
                const skip = statements.items.len;
                try statements.append(self.allocator, .{ .skip = undefined });
                statements.items[branch_index].branch.false_target = skip + 1;
                try self.sequence(statements, allow_else, true);
                statements.items[skip].skip = statements.items.len;
            } else {
                statements.items[branch_index].branch.false_target = statements.items.len;
            }
            return;
        } else if (!self.atStatementEnd() or (self.rest.len != 0 and self.rest[0] == '\'')) {
            try statements.append(self.allocator, try self.statement());
        }
        if (self.take(":")) return self.sequence(statements, allow_else, false);
        if (self.rest.len != 0 and self.rest[0] == '\'') {
            try statements.append(self.allocator, try self.statement());
        }
        if (self.rest.len != 0 and !(allow_else and self.atElse())) return error.TrailingInput;
    }

    fn fileChannel(self: *Parser) !u8 {
        self.space();
        const channel = try std.fmt.parseInt(u8, self.digits(), 10);
        if (channel == 0) return error.InvalidFileChannel;
        return channel;
    }

    fn openFile(self: *Parser) !Statement {
        var name = try self.expression(1);
        if (name.kind() != .string) return error.TypeMismatch;
        var mode: FileMode = undefined;
        var channel: u8 = undefined;
        if (self.take(",")) {
            if (name.* != .text) return error.UnsupportedFileMode;
            const text = name.text;
            if (text.len != 1) return error.UnsupportedFileMode;
            mode = switch (std.ascii.toUpper(text[0])) {
                'I' => .input,
                'O' => .output,
                'A' => .append,
                else => return error.UnsupportedFileMode,
            };
            _ = self.take("#");
            channel = try self.fileChannel();
            try self.require(",");
            name = try self.expression(1);
            if (name.kind() != .string) return error.TypeMismatch;
        } else {
            try self.require("FOR");
            mode = if (self.take("INPUT")) .input else if (self.take("OUTPUT")) .output else if (self.take("APPEND")) .append else return error.UnsupportedFileMode;
            try self.require("AS");
            _ = self.take("#");
            channel = try self.fileChannel();
        }
        return .{ .open = .{ .mode = mode, .name = name, .channel = channel } };
    }

    fn inputStatement(self: *Parser, whole_line: bool) !Statement {
        var result: Statement = .{ .input = .{ .targets = undefined, .whole_line = whole_line } };
        const input = &result.input;
        if (self.take("#")) {
            input.channel = try self.fileChannel();
            try self.require(",");
        } else {
            input.question = !whole_line;
            if (self.take("\"")) {
                input.prompt = try self.string();
                if (whole_line) {
                    try self.require(";");
                } else {
                    input.question = self.take(";");
                    if (!input.question) try self.require(",");
                }
            }
        }
        input.targets = try self.references(false);
        if (whole_line and (input.targets.len != 1 or input.targets[0].variable.kind != .string))
            return error.TypeMismatch;
        return result;
    }

    fn statement(self: *Parser) !Statement {
        if (self.take("REM") or self.take("'")) {
            self.rest = "";
            return .remark;
        }
        if (self.take("OPEN")) return self.openFile();
        if (self.take("PRINT") or self.take("?")) return .{ .print = try self.printStatement() };
        if (self.take("DATA")) return .{ .data = try self.dataItems() };
        if (self.take("READ")) return .{ .read = try self.references(false) };
        if (self.take("DIM")) return .{ .dim = try self.references(true) };
        if (self.take("RESTORE")) {
            self.space();
            return .{ .restore = if (self.atStatementEnd()) null else try self.lineNumber() };
        }
        if (self.take("INPUT")) return self.inputStatement(false);
        const before_line = self.rest;
        if (self.take("LINE") and self.take("INPUT")) return self.inputStatement(true);
        self.rest = before_line;
        if (self.take("FOR")) {
            const index = try self.numericVariable();
            try self.require("=");
            const start = try self.numericExpression();
            try self.require("TO");
            const limit = try self.numericExpression();
            const step = if (self.take("STEP")) try self.numericExpression() else &Expression{ .literal = .{ .integer = 1 } };
            return .{ .for_loop = .{ .variable = index, .start = start, .limit = limit, .step = step } };
        }
        if (self.take("NEXT")) {
            self.space();
            return .{ .next_loop = if (self.atStatementEnd()) null else (try self.numericVariable()).slot };
        }
        if (self.take("LET")) {
            const variable_value = try self.reference();
            try self.require("=");
            return .{ .assign = try self.assignment(variable_value) };
        }
        if (self.take("GOTO")) return .{ .jump = try self.lineNumber() };
        if (self.take("GOSUB")) return .{ .gosub = try self.lineNumber() };
        if (self.take("RETURN")) {
            self.space();
            return .{ .return_from_subroutine = if (self.atStatementEnd()) null else try self.lineNumber() };
        }
        if (self.take("WHILE")) return .{ .while_loop = try self.numericExpression() };
        if (self.take("WEND")) return .wend;
        if (self.take("CLOSE")) {
            var channels: std.ArrayList(u8) = .empty;
            if (!self.atStatementEnd()) {
                while (true) {
                    _ = self.take("#");
                    try channels.append(self.allocator, try self.fileChannel());
                    if (!self.take(",")) break;
                }
            }
            return .{ .close = channels.items };
        }
        if (self.take("SYSTEM") or self.take("END")) return .system;
        const variable_value = self.reference() catch |err| switch (err) {
            error.ExpectedVariable => return error.UnsupportedStatement,
            else => |other| return other,
        };
        if (!self.take("=")) return error.UnsupportedStatement;
        return .{ .assign = try self.assignment(variable_value) };
    }
};

fn parseLine(allocator: Allocator, names: *Names, source: []const u8) !Line {
    if (source.len > 255) return error.LineTooLong;
    for (source) |byte| if (byte != '\t' and (byte < ' ' or byte > '~')) return error.ExpectedPrintableAscii;
    var parser: Parser = .{ .allocator = allocator, .names = names, .rest = source };
    const number = try parser.lineNumber();
    var statements: std.ArrayList(Statement) = .empty;
    try parser.sequence(&statements, false, false);
    if (statements.items.len == 0) try statements.append(allocator, .remark);
    return .{ .number = number, .statements = statements.items };
}

fn pairLoops(allocator: Allocator, lines: []Instruction, numeric_count: usize, diagnostic: *Writer) !void {
    const stack = try allocator.alloc(usize, numeric_count);
    var whiles: std.ArrayList(usize) = .empty;
    var depth: usize = 0;
    for (lines, 0..) |*line, index| {
        switch (line.statement) {
            .for_loop => |loop| {
                for (stack[0..depth]) |outer| {
                    if (lines[outer].statement.for_loop.variable.slot == loop.variable.slot) {
                        try diagnostic.print("BASIC line {d} reuses an enclosing FOR variable\n", .{line.number});
                        return error.ReusedForVariable;
                    }
                }
                stack[depth] = index;
                depth += 1;
            },
            .next_loop => |variable| {
                if (depth == 0) {
                    try diagnostic.print("BASIC line {d} has NEXT without FOR\n", .{line.number});
                    return error.NextWithoutFor;
                }
                depth -= 1;
                const start = stack[depth];
                if (variable != null and variable.? != lines[start].statement.for_loop.variable.slot) {
                    try diagnostic.print("BASIC line {d} does not match FOR on line {d}\n", .{ line.number, lines[start].number });
                    return error.MismatchedNext;
                }
                line.loop_partner = start;
                lines[start].loop_partner = index;
            },
            .while_loop => try whiles.append(allocator, index),
            .wend => {
                const start = whiles.pop() orelse {
                    try diagnostic.print("BASIC line {d} has WEND without WHILE\n", .{line.number});
                    return error.WendWithoutWhile;
                };
                line.loop_partner = start;
                lines[start].loop_partner = index;
            },
            else => {},
        }
    }
    if (depth != 0) {
        try diagnostic.print("BASIC line {d} has FOR without NEXT\n", .{lines[stack[depth - 1]].number});
        return error.ForWithoutNext;
    }
    if (whiles.getLastOrNull()) |start| {
        try diagnostic.print("BASIC line {d} has WHILE without WEND\n", .{lines[start].number});
        return error.WhileWithoutWend;
    }
}

fn emitPrint(out: *Writer, print: Print, indent: []const u8) !void {
    for (print.values) |item| {
        const method = if (item.value.kind() == .number) "number" else "printString";
        try out.print("{s}try runtime.{s}({d}, ", .{ indent, method, print.channel });
        try item.value.emit(out);
        try out.writeAll(");\n");
        if (item.comma_after) try out.print("{s}try runtime.printZone();\n", .{indent});
    }
    try out.print("{s}try runtime.newline({d});\n", .{ indent, print.channel });
}

fn emitAssignment(out: *Writer, assign: Assignment, indent: []const u8) !void {
    const variable = assign.target.variable;
    try out.writeAll(indent);
    try assign.target.emit(out, true);
    try out.writeAll(if (variable.kind == .number) " = try " else " = ");
    try assign.value.emit(out);
    if (variable.kind == .number) try out.print(".convert({})", .{variable.integer});
    try out.writeAll(";\n");
}

fn emitInstruction(out: *Writer, lines: []const Instruction, index: usize, line_targets: std.AutoHashMap(u16, usize)) !void {
    const line = lines[index];
    const next = index + 1;
    try out.print("        {d} => {{\n", .{index});
    switch (line.statement) {
        .remark, .data => {},
        .open => |open| {
            try out.print("            try runtime.open({d}, .{s}, ", .{ open.channel, @tagName(open.mode) });
            try open.name.emit(out);
            try out.writeAll(");\n");
        },
        .print => |print| try emitPrint(out, print, "            "),
        .input => |input| {
            try out.print("            const values = try runtime.input({d}, \"{f}\", {}, {}, &.{{", .{
                input.channel, std.zig.fmtString(input.prompt), input.question, input.whole_line,
            });
            for (input.targets) |target| {
                const variable = target.variable;
                try out.print(".{s}, ", .{if (variable.kind == .string) "text" else if (variable.integer) "integer" else "single"});
            }
            try out.writeAll("});\n");
            for (input.targets, 0..) |target, slot| {
                try out.writeAll("            ");
                try target.emit(out, true);
                try out.print(" = values[{d}].{s};\n", .{ slot, if (target.variable.kind == .string) "text" else "number" });
            }
        },
        .read => |targets| {
            for (targets) |target| {
                try out.writeAll("            ");
                try target.emit(out, true);
                if (target.variable.kind == .number) {
                    try out.print(" = try runtime.readDataNumber({});\n", .{target.variable.integer});
                } else {
                    try out.writeAll(" = try runtime.readDataString();\n");
                }
            }
        },
        .dim => |targets| {
            for (targets) |target| {
                const variable = target.variable;
                const method = if (variable.kind == .number) "dimensionNumber" else "dimensionString";
                try out.print("            try runtime.{s}({d}, ", .{ method, variable.slot });
                try target.subscript.?.emit(out);
                if (variable.kind == .number) try out.print(", {}", .{variable.integer});
                try out.writeAll(");\n");
            }
        },
        .restore => try out.print("            runtime.data_index = {d};\n", .{line.restore_index}),
        .for_loop => |loop| {
            const after = line.loop_partner.? + 1;
            try out.print("            if (!try runtime.beginLoop({d}, {d}, {}, ", .{ loop.variable.slot, index, loop.variable.integer });
            try loop.start.emit(out);
            try out.writeAll(", ");
            try loop.limit.emit(out);
            try out.writeAll(", ");
            try loop.step.emit(out);
            try out.print(")) continue :dispatch {d};\n", .{after});
        },
        .next_loop => {
            const start = line.loop_partner.?;
            try out.print("            if (try runtime.nextLoop({d}, {d})) continue :dispatch {d};\n", .{
                lines[start].statement.for_loop.variable.slot, start, start + 1,
            });
        },
        .assign => |assign| try emitAssignment(out, assign, "            "),
        .jump => |target| {
            try out.print("            continue :dispatch {d};\n        }},\n", .{line_targets.get(target).?});
            return;
        },
        .gosub => |target| {
            try out.print("            try runtime.beginSubroutine({d});\n            continue :dispatch {d};\n        }},\n", .{ next, line_targets.get(target).? });
            return;
        },
        .return_from_subroutine => |target| {
            if (target) |destination| {
                try out.print("            _ = try runtime.endSubroutine();\n            continue :dispatch {d};\n        }},\n", .{line_targets.get(destination).?});
            } else {
                try out.writeAll("            continue :dispatch try runtime.endSubroutine();\n        },\n");
            }
            return;
        },
        .branch => |branch| {
            try out.writeAll("            if (");
            try branch.condition.emit(out);
            try out.print(".asSingle() == 0) continue :dispatch {d};\n", .{branch.false_target});
        },
        .skip, .wend => {
            const destination = if (line.statement == .skip) line.statement.skip else line.loop_partner.?;
            try out.print("            continue :dispatch {d};\n        }},\n", .{destination});
            return;
        },
        .while_loop => |condition| {
            try out.writeAll("            if (");
            try condition.emit(out);
            try out.print(".asSingle() == 0) continue :dispatch {d};\n", .{line.loop_partner.? + 1});
        },
        .close => |channels| {
            if (channels.len == 0) try out.writeAll("            try runtime.closeAll();\n");
            for (channels) |channel| try out.print("            try runtime.close({d});\n", .{channel});
        },
        .system => {
            try out.writeAll("            try runtime.closeAll();\n            return;\n        },\n");
            return;
        },
    }
    try out.print("            continue :dispatch {d};\n        }},\n", .{next});
}

fn compile(allocator: Allocator, source: []const u8, out: *Writer, diagnostic: *Writer) !void {
    const end = std.mem.indexOfScalar(u8, source, 0x1a) orelse source.len;
    var rows = std.mem.splitScalar(u8, source[0..end], '\n');
    var rows_parsed: std.ArrayList(Line) = .empty;
    var numbers = std.AutoHashMap(u16, usize).init(allocator);
    var names: Names = .{};
    var physical_line: usize = 0;
    while (rows.next()) |row| {
        physical_line += 1;
        const source_line = if (std.mem.endsWith(u8, row, "\r")) row[0 .. row.len - 1] else row;
        if (std.mem.trim(u8, source_line, " \t").len == 0) continue;
        const line = parseLine(allocator, &names, source_line) catch |err| {
            try diagnostic.print("source row {d}: {s}\n", .{ physical_line, @errorName(err) });
            return err;
        };
        if ((try numbers.getOrPut(line.number)).found_existing) {
            try diagnostic.print("duplicate BASIC line {d}\n", .{line.number});
            return error.DuplicateLine;
        }
        try rows_parsed.append(allocator, line);
    }
    std.mem.sort(Line, rows_parsed.items, {}, Line.lessThan);
    if (rows_parsed.items.len == 0) return error.EmptyProgram;
    var lines: std.ArrayList(Instruction) = .empty;
    var data_indices = std.AutoHashMap(u16, usize).init(allocator);
    var data_count: usize = 0;
    for (rows_parsed.items) |row| {
        const base = lines.items.len;
        numbers.getPtr(row.number).?.* = base;
        try data_indices.put(row.number, data_count);
        for (row.statements) |*statement| {
            switch (statement.*) {
                .branch => |*branch| branch.false_target += base,
                .skip => |*target| target.* += base,
                .data => |items| data_count += items.len,
                else => {},
            }
            try lines.append(allocator, .{ .number = row.number, .statement = statement.* });
        }
    }
    try pairLoops(allocator, lines.items, names.numbers.count(), diagnostic);
    for (lines.items) |*line| {
        if (line.statement == .restore) {
            if (line.statement.restore) |target| {
                line.restore_index = data_indices.get(target) orelse {
                    try diagnostic.print("BASIC line {d} restores from missing line {d}\n", .{ line.number, target });
                    return error.UndefinedLine;
                };
            }
        }
        const target = switch (line.statement) {
            .jump, .gosub => |target| target,
            .return_from_subroutine => |target| target orelse continue,
            else => continue,
        };
        if (!numbers.contains(target)) {
            try diagnostic.print("BASIC line {d} jumps to missing line {d}\n", .{ line.number, target });
            return error.UndefinedLine;
        }
    }
    try out.writeAll(@embedFile("numeric.zig"));
    try out.writeAll(@embedFile("runtime.zig"));
    try out.writeAll("\nconst program_data = [_]DataItem{\n");
    for (lines.items) |line| {
        if (line.statement != .data) continue;
        for (line.statement.data) |item| {
            try out.print("    .{{ .text = \"{f}\", .quoted = {} }},\n", .{ std.zig.fmtString(item.text), item.quoted });
        }
    }
    try out.writeAll("};\n");
    try out.print(
        \\
        \\pub fn main(init: std.process.Init) !void {{
        \\    var input_buffer: [512]u8 = undefined;
        \\    var runtime: ProgramRuntime({d}, {d}, {d}, {d}) = .{{
        \\        .io = init.io,
        \\        .allocator = init.arena.allocator(),
        \\        .stdin = std.Io.File.stdin().readerStreaming(init.io, &input_buffer),
        \\        .data = &program_data,
        \\    }};
        \\    defer runtime.release();
        \\    dispatch: switch (@as(usize, 0)) {{
        \\
    , .{
        names.numbers.count(),       names.strings.count(),
        names.number_arrays.count(), names.string_arrays.count(),
    });
    for (0..lines.items.len) |index| {
        try emitInstruction(out, lines.items, index, numbers);
    }
    try out.print(
        "        {d} => {{\n            try runtime.closeAll();\n            return;\n        }},\n        else => unreachable,\n    }}\n}}\n",
        .{lines.items.len},
    );
}

fn buildExecutable(init: std.process.Init, generated: []const u8, output: []const u8) !void {
    const allocator = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const parent = std.fs.path.dirname(output) orelse ".";
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const directory = try std.fmt.allocPrint(allocator, "{s}/.gwbc-{s}", .{ parent, std.fmt.bytesToHex(random, .lower) });
    try cwd.createDir(init.io, directory, .fromMode(0o700));
    defer cwd.deleteTree(init.io, directory) catch {};
    const source_path = try std.fs.path.join(allocator, &.{ directory, "program.zig" });
    const binary_path = try std.fs.path.join(allocator, &.{ directory, "program" });
    try cwd.writeFile(init.io, .{ .sub_path = source_path, .data = generated });
    const emit_path = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{binary_path});
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "zig", "build-exe", source_path, "-O", "ReleaseSafe", emit_path },
    });
    switch (try child.wait(init.io)) {
        .exited => |code| if (code != 0) return error.BackendFailed,
        else => return error.BackendFailed,
    }
    try cwd.rename(binary_path, cwd, output, init.io);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var error_buffer: [256]u8 = undefined;
    var diagnostic = std.Io.File.stderr().writer(init.io, &error_buffer);
    const emit_zig = args.len == 3 and std.mem.eql(u8, args[1], "--emit-zig");
    const native = args.len == 4 and std.mem.eql(u8, args[2], "-o");
    if (!emit_zig and !native) {
        try diagnostic.interface.writeAll("usage: gwbc INPUT.BAS -o EXECUTABLE\n       gwbc --emit-zig INPUT.BAS\n");
        try diagnostic.interface.flush();
        std.process.exit(64);
    }
    const input = if (emit_zig) args[2] else args[1];
    if (native) {
        const input_path = try std.fs.path.resolve(allocator, &.{input});
        const output_path = try std.fs.path.resolve(allocator, &.{args[3]});
        if (std.mem.eql(u8, input_path, output_path)) return error.OutputIsInput;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input, allocator, .limited(1024 * 1024));
    const source = tokenized.sourceText(allocator, bytes, &diagnostic.interface) catch |err| {
        try diagnostic.interface.print("gwbc: {s}\n", .{@errorName(err)});
        try diagnostic.interface.flush();
        std.process.exit(1);
    };
    var generated: Writer.Allocating = .init(allocator);
    compile(allocator, source, &generated.writer, &diagnostic.interface) catch |err| {
        try diagnostic.interface.print("gwbc: {s}\n", .{@errorName(err)});
        try diagnostic.interface.flush();
        std.process.exit(1);
    };
    if (emit_zig) {
        try std.Io.File.stdout().writeStreamingAll(init.io, generated.written());
    } else {
        try buildExecutable(init, generated.written(), args[3]);
    }
}

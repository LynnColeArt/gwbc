const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const ValueKind = enum { number, string };
const Variable = struct {
    kind: ValueKind,
    slot: usize,

    fn field(self: Variable) []const u8 {
        return if (self.kind == .number) "variables" else "strings";
    }
};

const Names = struct {
    const Key = [41]u8;
    numbers: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    strings: std.AutoHashMapUnmanaged(Key, usize) = .empty,

    fn intern(self: *Names, allocator: Allocator, key: Key, kind: ValueKind) !Variable {
        const table = if (kind == .number) &self.numbers else &self.strings;
        const count = table.count();
        const entry = try table.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = count;
        return .{ .kind = kind, .slot = entry.value_ptr.* };
    }
};

const Operation = enum {
    add,
    sub,
    mul,
    divTrunc,
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
    literal: i16,
    text: []const u8,
    variable: Variable,
    builtin: struct { function: Builtin, args: [3]*const Expression },
    negate: *const Expression,
    binary: struct { operation: Operation, left: *const Expression, right: *const Expression },

    fn kind(self: Expression) ValueKind {
        return switch (self) {
            .text => .string,
            .variable => |variable| variable.kind,
            .builtin => |builtin| builtin.function.kind(),
            .binary => |binary| if (binary.operation == .add) binary.left.kind() else .number,
            .literal, .negate => .number,
        };
    }

    fn emit(self: Expression, out: *Writer) Writer.Error!void {
        switch (self) {
            .literal => |value| try out.print("@as(i16, {d})", .{value}),
            .text => |value| try out.print("(try BasicString.fromBytes(\"{f}\"))", .{std.zig.fmtString(value)}),
            .variable => |variable| try out.print("runtime.{s}[{d}]", .{ variable.field(), variable.slot }),
            .builtin => |builtin| {
                const can_fail = builtin.function != .length;
                try out.print("{s}BasicString.{s}(", .{ if (can_fail) "(try " else "", @tagName(builtin.function) });
                for (builtin.args[0..builtin.function.arity()], 0..) |argument, index| {
                    if (index != 0) try out.writeAll(", ");
                    try argument.emit(out);
                }
                try out.writeAll(if (can_fail) "))" else ")");
            },
            .negate => |operand| {
                try out.writeAll("(try std.math.negate(");
                try operand.emit(out);
                try out.writeAll("))");
            },
            .binary => |binary| {
                if (binary.operation.comparisonToken()) |token| {
                    try out.writeAll("@as(i16, if (");
                    if (binary.left.kind() == .string) {
                        try out.writeAll("BasicString.compare(");
                        try binary.left.emit(out);
                        try out.writeAll(", ");
                        try binary.right.emit(out);
                        try out.print(") {s} 0", .{token});
                    } else {
                        try binary.left.emit(out);
                        try out.print(" {s} ", .{token});
                        try binary.right.emit(out);
                    }
                    try out.writeAll(") -1 else 0)");
                } else if (binary.operation == .bit_and or binary.operation == .bit_or) {
                    try out.writeAll("(");
                    try binary.left.emit(out);
                    try out.writeAll(if (binary.operation == .bit_and) " & " else " | ");
                    try binary.right.emit(out);
                    try out.writeAll(")");
                } else {
                    if (binary.left.kind() == .string) {
                        try out.writeAll("(try BasicString.concat(");
                    } else if (binary.operation == .remainder) {
                        try out.writeAll("(try integerRemainder(");
                    } else {
                        try out.print("(try std.math.{s}(i16, ", .{@tagName(binary.operation)});
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

const Print = struct {
    file: bool,
    values: []const *const Expression,
};

const Assignment = struct { variable: Variable, value: *const Expression };
const BranchAction = union(enum) {
    jump: u16,
    assign: Assignment,
    print: Print,

    fn target(self: BranchAction) ?u16 {
        return if (self == .jump) self.jump else null;
    }
};

const Statement = union(enum) {
    remark,
    open,
    print: Print,
    input: struct { variable: Variable, prompt: []const u8, question: bool },
    for_loop: struct { variable: usize, start: *const Expression, limit: *const Expression, step: *const Expression },
    next_loop: ?usize,
    assign: Assignment,
    jump: u16,
    gosub: u16,
    return_from_subroutine: ?u16,
    branch: struct { condition: *const Expression, then: BranchAction, otherwise: ?BranchAction },
    close,
    system,
};

const Line = struct {
    number: u16,
    statement: Statement,
    loop_partner: ?usize = null,

    fn lessThan(_: void, left: Line, right: Line) bool {
        return left.number < right.number;
    }
};

const Parser = struct {
    const ExpressionError = error{ OutOfMemory, InvalidSyntax, ExpectedVariable, TypeMismatch, Overflow, InvalidCharacter };
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
        .{ .token = "\\", .operation = .divTrunc, .precedence = 6 },
        .{ .token = "*", .operation = .mul, .precedence = 7 },
    };

    allocator: Allocator,
    names: *Names,
    rest: []const u8,

    fn space(self: *Parser) void {
        self.rest = std.mem.trimStart(u8, self.rest, " ");
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

    fn variable(self: *Parser) ExpressionError!Variable {
        self.space();
        if (self.rest.len == 0 or !std.ascii.isAlphabetic(self.rest[0])) return error.ExpectedVariable;
        var end: usize = 1;
        while (end < self.rest.len and (std.ascii.isAlphanumeric(self.rest[end]) or self.rest[end] == '.')) : (end += 1) {}
        const suffix = if (end < self.rest.len and (self.rest[end] == '%' or self.rest[end] == '$')) self.rest[end] else 0;
        var key: Names.Key = @splat(0);
        key[0] = suffix;
        for (self.rest[0..@min(end, 40)], key[1..][0..@min(end, 40)]) |byte, *canonical| {
            canonical.* = std.ascii.toUpper(byte);
        }
        self.rest = self.rest[end + @intFromBool(suffix != 0) ..];
        return self.names.intern(self.allocator, key, if (suffix == '$') .string else .number);
    }

    fn numericVariable(self: *Parser) ExpressionError!usize {
        const result = try self.variable();
        if (result.kind != .number) return error.TypeMismatch;
        return result.slot;
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
        const functions = .{ .{ "LEN", Builtin.length }, .{ "MID$", Builtin.mid }, .{ "RIGHT$", Builtin.right }, .{ "VAL", Builtin.val } };
        inline for (functions) |function| {
            const previous = self.rest;
            if (self.take(function[0]) and self.take("(")) return self.builtinCall(function[1]);
            self.rest = previous;
        }
        if (self.rest.len != 0 and std.ascii.isAlphabetic(self.rest[0]))
            return self.node(.{ .variable = try self.variable() });
        return self.node(.{ .literal = try std.fmt.parseInt(i16, self.digits(), 10) });
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
        if (self.take("-")) {
            self.space();
            // The magnitude of the smallest i16 does not itself fit in i16.
            if (self.rest.len != 0 and std.ascii.isDigit(self.rest[0])) {
                const magnitude = try std.fmt.parseInt(i32, self.digits(), 10);
                return self.node(.{ .literal = std.math.cast(i16, -magnitude) orelse return error.Overflow });
            }
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
        return rest.len == 4 or !std.ascii.isAlphanumeric(rest[4]);
    }

    fn printStatement(self: *Parser, inline_branch: bool) !Print {
        const file = self.take("#1");
        if (file) try self.require(",");
        self.space();
        var values: std.ArrayList(*const Expression) = .empty;
        while (self.rest.len != 0 and !(inline_branch and self.atElse())) {
            try values.append(self.allocator, try self.expression(1));
            if (!self.take(";")) break;
            if (self.rest.len == 0 or (inline_branch and self.atElse())) return error.UnsupportedTrailingSemicolon;
        }
        return .{ .file = file, .values = values.items };
    }

    fn assignment(self: *Parser, variable_value: Variable) !Assignment {
        const value = try self.expression(1);
        if (value.kind() != variable_value.kind) return error.TypeMismatch;
        return .{ .variable = variable_value, .value = value };
    }

    fn branchAction(self: *Parser) !BranchAction {
        self.space();
        if (self.rest.len != 0 and std.ascii.isDigit(self.rest[0]))
            return .{ .jump = try self.lineNumber() };
        if (self.take("PRINT")) return .{ .print = try self.printStatement(true) };
        _ = self.take("LET");
        const variable_value = try self.variable();
        try self.require("=");
        return .{ .assign = try self.assignment(variable_value) };
    }

    fn statement(self: *Parser) !Statement {
        if (self.take("REM") or self.take("'")) {
            self.rest = "";
            return .remark;
        }
        if (self.take("OPEN")) {
            try self.require("\"OUT.TXT\"");
            try self.require("FOR");
            try self.require("OUTPUT");
            try self.require("AS");
            try self.require("#1");
            return .open;
        }
        if (self.take("PRINT")) return .{ .print = try self.printStatement(false) };
        if (self.take("INPUT")) {
            var prompt: []const u8 = "";
            var question = true;
            if (self.take("\"")) {
                prompt = try self.string();
                question = self.take(";");
                if (!question) try self.require(",");
            }
            return .{ .input = .{ .variable = try self.variable(), .prompt = prompt, .question = question } };
        }
        if (self.take("FOR")) {
            const index = try self.numericVariable();
            try self.require("=");
            const start = try self.numericExpression();
            try self.require("TO");
            const limit = try self.numericExpression();
            const step = if (self.take("STEP")) try self.numericExpression() else &Expression{ .literal = 1 };
            return .{ .for_loop = .{ .variable = index, .start = start, .limit = limit, .step = step } };
        }
        if (self.take("NEXT")) {
            self.space();
            return .{ .next_loop = if (self.rest.len == 0) null else try self.numericVariable() };
        }
        if (self.take("LET")) {
            const variable_value = try self.variable();
            try self.require("=");
            return .{ .assign = try self.assignment(variable_value) };
        }
        if (self.take("GOTO")) return .{ .jump = try self.lineNumber() };
        if (self.take("GOSUB")) return .{ .gosub = try self.lineNumber() };
        if (self.take("RETURN")) {
            self.space();
            return .{ .return_from_subroutine = if (self.rest.len == 0) null else try self.lineNumber() };
        }
        if (self.take("IF")) {
            const condition = try self.numericExpression();
            try self.require("THEN");
            const then = try self.branchAction();
            const otherwise = if (self.take("ELSE")) try self.branchAction() else null;
            return .{ .branch = .{ .condition = condition, .then = then, .otherwise = otherwise } };
        }
        if (self.take("CLOSE")) {
            try self.require("#1");
            return .close;
        }
        if (self.take("SYSTEM") or self.take("END")) return .system;
        const variable_value = self.variable() catch |err| switch (err) {
            error.ExpectedVariable => return error.UnsupportedStatement,
            else => |other| return other,
        };
        if (!self.take("=")) return error.UnsupportedStatement;
        return .{ .assign = try self.assignment(variable_value) };
    }
};

fn parseLine(allocator: Allocator, names: *Names, source: []const u8) !Line {
    if (source.len > 255) return error.LineTooLong;
    for (source) |byte| if (byte < ' ' or byte > '~') return error.ExpectedPrintableAscii;
    var parser: Parser = .{ .allocator = allocator, .names = names, .rest = source };
    const number = try parser.lineNumber();
    const statement = try parser.statement();
    parser.space();
    if (parser.rest.len != 0) return error.TrailingInput;
    return .{ .number = number, .statement = statement };
}

fn pairLoops(allocator: Allocator, lines: []Line, numeric_count: usize, diagnostic: *Writer) !void {
    const stack = try allocator.alloc(usize, numeric_count);
    var depth: usize = 0;
    for (lines, 0..) |*line, index| {
        switch (line.statement) {
            .for_loop => |loop| {
                for (stack[0..depth]) |outer| {
                    if (lines[outer].statement.for_loop.variable == loop.variable) {
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
                if (variable != null and variable.? != lines[start].statement.for_loop.variable) {
                    try diagnostic.print("BASIC line {d} does not match FOR on line {d}\n", .{ line.number, lines[start].number });
                    return error.MismatchedNext;
                }
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
}

const end_of_program: u16 = 65535;

fn following(lines: []const Line, index: usize) u16 {
    return if (index + 1 < lines.len) lines[index + 1].number else end_of_program;
}

fn emitPrint(out: *Writer, print: Print, indent: []const u8) !void {
    for (print.values) |value| {
        const method = if (value.kind() == .number) "number" else "printString";
        try out.print("{s}try runtime.{s}({}, ", .{ indent, method, print.file });
        try value.emit(out);
        try out.writeAll(");\n");
    }
    try out.print("{s}try runtime.newline({});\n", .{ indent, print.file });
}

fn emitAssignment(out: *Writer, assign: Assignment, indent: []const u8) !void {
    try out.print("{s}runtime.{s}[{d}] = ", .{ indent, assign.variable.field(), assign.variable.slot });
    try assign.value.emit(out);
    try out.writeAll(";\n");
}

fn emitBranchAction(out: *Writer, action: BranchAction) !void {
    const indent = "                ";
    switch (action) {
        .jump => |target| try out.print("{s}continue :dispatch {d};\n", .{ indent, target }),
        .assign => |assign| try emitAssignment(out, assign, indent),
        .print => |print| try emitPrint(out, print, indent),
    }
}

fn emitLine(out: *Writer, lines: []const Line, index: usize) !void {
    const line = lines[index];
    const next = following(lines, index);
    try out.print("        {d} => {{\n", .{line.number});
    switch (line.statement) {
        .remark => {},
        .open => try out.writeAll("            try runtime.open();\n"),
        .print => |print| try emitPrint(out, print, "            "),
        .input => |input| {
            try out.print("            runtime.{s}[{d}] = try runtime.{s}(\"{f}\", {});\n", .{
                input.variable.field(),                                         input.variable.slot,
                if (input.variable.kind == .number) "input" else "stringInput", std.zig.fmtString(input.prompt),
                input.question,
            });
        },
        .for_loop => |loop| {
            const after = following(lines, line.loop_partner.?);
            try out.print("            if (!runtime.beginLoop({d}, {d}, ", .{ loop.variable, line.number });
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
                lines[start].statement.for_loop.variable, lines[start].number, lines[start + 1].number,
            });
        },
        .assign => |assign| try emitAssignment(out, assign, "            "),
        .jump => |target| {
            try out.print("            continue :dispatch {d};\n        }},\n", .{target});
            return;
        },
        .gosub => |target| {
            try out.print("            try runtime.beginSubroutine({d});\n            continue :dispatch {d};\n        }},\n", .{ next, target });
            return;
        },
        .return_from_subroutine => |target| {
            if (target) |destination| {
                try out.print("            _ = try runtime.endSubroutine();\n            continue :dispatch {d};\n        }},\n", .{destination});
            } else {
                try out.writeAll("            continue :dispatch try runtime.endSubroutine();\n        },\n");
            }
            return;
        },
        .branch => |branch| {
            try out.writeAll("            if (");
            try branch.condition.emit(out);
            try out.writeAll(" != 0) {\n");
            try emitBranchAction(out, branch.then);
            if (branch.otherwise) |otherwise| {
                try out.writeAll("            } else {\n");
                try emitBranchAction(out, otherwise);
            }
            try out.writeAll("            }\n");
            if (branch.then.target() != null and branch.otherwise != null and branch.otherwise.?.target() != null) {
                try out.writeAll("        },\n");
                return;
            }
        },
        .close => try out.writeAll("            try runtime.close();\n"),
        .system => {
            try out.writeAll("            if (runtime.file != null) return error.FileStillOpen;\n            return;\n        },\n");
            return;
        },
    }
    try out.print("            continue :dispatch {d};\n        }},\n", .{next});
}

fn compile(allocator: Allocator, source: []const u8, out: *Writer, diagnostic: *Writer) !void {
    var rows = std.mem.splitScalar(u8, source, '\n');
    var lines: std.ArrayList(Line) = .empty;
    var numbers = std.AutoHashMap(u16, void).init(allocator);
    var names: Names = .{};
    var physical_line: usize = 0;
    while (rows.next()) |row| {
        physical_line += 1;
        const source_line = if (std.mem.endsWith(u8, row, "\r")) row[0 .. row.len - 1] else row;
        if (std.mem.trim(u8, source_line, " ").len == 0) continue;
        const line = parseLine(allocator, &names, source_line) catch |err| {
            try diagnostic.print("source row {d}: {s}\n", .{ physical_line, @errorName(err) });
            return err;
        };
        if ((try numbers.getOrPut(line.number)).found_existing) {
            try diagnostic.print("duplicate BASIC line {d}\n", .{line.number});
            return error.DuplicateLine;
        }
        try lines.append(allocator, line);
    }
    std.mem.sort(Line, lines.items, {}, Line.lessThan);
    if (lines.items.len == 0) return error.EmptyProgram;
    try pairLoops(allocator, lines.items, names.numbers.count(), diagnostic);
    for (lines.items) |line| {
        const targets: [2]?u16 = switch (line.statement) {
            .jump, .gosub => |target| .{ target, null },
            .return_from_subroutine => |target| .{ target, null },
            .branch => |branch| .{ branch.then.target(), if (branch.otherwise) |otherwise| otherwise.target() else null },
            else => continue,
        };
        for (targets) |maybe_target| {
            const target = maybe_target orelse continue;
            if (!numbers.contains(target)) {
                try diagnostic.print("BASIC line {d} jumps to missing line {d}\n", .{ line.number, target });
                return error.UndefinedLine;
            }
        }
    }
    try out.writeAll(@embedFile("runtime.zig"));
    try out.print(
        \\
        \\pub fn main(init: std.process.Init) !void {{
        \\    var input_buffer: [256]u8 = undefined;
        \\    var runtime: ProgramRuntime({d}, {d}) = .{{
        \\        .io = init.io,
        \\        .allocator = init.arena.allocator(),
        \\        .stdin = std.Io.File.stdin().readerStreaming(init.io, &input_buffer),
        \\    }};
        \\    defer runtime.release();
        \\    dispatch: switch (@as(u16, {d})) {{
        \\
    , .{ names.numbers.count(), names.strings.count(), lines.items[0].number });
    for (0..lines.items.len) |index| {
        try emitLine(out, lines.items, index);
    }
    try out.print(
        "        {d} => {{\n            if (runtime.file != null) return error.FileStillOpen;\n            return;\n        }},\n        else => unreachable,\n    }}\n}}\n",
        .{end_of_program},
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
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, input, allocator, .limited(1024 * 1024));
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

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

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

const Expression = union(enum) {
    literal: i16,
    variable: u8,
    negate: *const Expression,
    binary: struct { operation: Operation, left: *const Expression, right: *const Expression },

    fn emit(self: Expression, out: *Writer) Writer.Error!void {
        switch (self) {
            .literal => |value| try out.print("@as(i16, {d})", .{value}),
            .variable => |index| try out.print("runtime.variables[{d}]", .{index}),
            .negate => |operand| {
                try out.writeAll("(try std.math.negate(");
                try operand.emit(out);
                try out.writeAll("))");
            },
            .binary => |binary| {
                if (binary.operation.comparisonToken()) |token| {
                    try out.writeAll("@as(i16, if (");
                    try binary.left.emit(out);
                    try out.print(" {s} ", .{token});
                    try binary.right.emit(out);
                    try out.writeAll(") -1 else 0)");
                } else {
                    if (binary.operation == .remainder) {
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

const PrintValue = union(enum) {
    text: []const u8,
    number: *const Expression,
};

const Print = struct {
    file: bool,
    values: []const PrintValue,
};

const Statement = union(enum) {
    remark,
    open,
    print: Print,
    input: struct { variable: u8, prompt: []const u8, question: bool },
    for_loop: struct { variable: u8, start: *const Expression, limit: *const Expression, step: *const Expression },
    next_loop: ?u8,
    assign: struct { variable: u8, value: *const Expression },
    jump: u16,
    branch: struct { condition: *const Expression, target: u16, otherwise: ?u16 },
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
    const ExpressionError = error{ OutOfMemory, InvalidSyntax, ExpectedIntegerVariable, Overflow, InvalidCharacter };
    const Operator = struct { token: []const u8, operation: Operation, precedence: u8 };
    const operators = [_]Operator{
        .{ .token = "<=", .operation = .less_equal, .precedence = 1 },
        .{ .token = "=<", .operation = .less_equal, .precedence = 1 },
        .{ .token = ">=", .operation = .greater_equal, .precedence = 1 },
        .{ .token = "=>", .operation = .greater_equal, .precedence = 1 },
        .{ .token = "<>", .operation = .not_equal, .precedence = 1 },
        .{ .token = "><", .operation = .not_equal, .precedence = 1 },
        .{ .token = "=", .operation = .equal, .precedence = 1 },
        .{ .token = "<", .operation = .less, .precedence = 1 },
        .{ .token = ">", .operation = .greater, .precedence = 1 },
        .{ .token = "+", .operation = .add, .precedence = 2 },
        .{ .token = "-", .operation = .sub, .precedence = 2 },
        .{ .token = "MOD", .operation = .remainder, .precedence = 3 },
        .{ .token = "\\", .operation = .divTrunc, .precedence = 4 },
        .{ .token = "*", .operation = .mul, .precedence = 5 },
    };

    allocator: Allocator,
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

    fn variable(self: *Parser) !u8 {
        self.space();
        if (self.rest.len < 2 or !std.ascii.isAlphabetic(self.rest[0]) or self.rest[1] != '%')
            return error.ExpectedIntegerVariable;
        const index = std.ascii.toUpper(self.rest[0]) - 'A';
        self.rest = self.rest[2..];
        return index;
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
        if (self.rest.len != 0 and std.ascii.isAlphabetic(self.rest[0]))
            return self.node(.{ .variable = try self.variable() });
        return self.node(.{ .literal = try std.fmt.parseInt(i16, self.digits(), 10) });
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
            return self.node(.{ .negate = try self.prefixExpression() });
        }
        if (self.take("+")) return self.prefixExpression();
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
            left = try self.node(.{ .binary = .{ .operation = operator.operation, .left = left, .right = right } });
        }
        return left;
    }

    // The opening quote has already been consumed.
    fn string(self: *Parser) ![]const u8 {
        const end = std.mem.indexOfScalar(u8, self.rest, '"') orelse return error.InvalidSyntax;
        const value = self.rest[0..end];
        self.rest = self.rest[end + 1 ..];
        return value;
    }

    fn printStatement(self: *Parser) !Print {
        const file = self.take("#1");
        if (file) try self.require(",");
        self.space();
        var values: std.ArrayList(PrintValue) = .empty;
        while (self.rest.len != 0) {
            const value: PrintValue = if (self.take("\""))
                .{ .text = try self.string() }
            else
                .{ .number = try self.expression(1) };
            try values.append(self.allocator, value);
            if (!self.take(";")) break;
            if (self.rest.len == 0) return error.UnsupportedTrailingSemicolon;
        }
        return .{ .file = file, .values = values.items };
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
        if (self.take("PRINT")) return .{ .print = try self.printStatement() };
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
            const index = try self.variable();
            try self.require("=");
            const start = try self.expression(1);
            try self.require("TO");
            const limit = try self.expression(1);
            const step = if (self.take("STEP")) try self.expression(1) else &Expression{ .literal = 1 };
            return .{ .for_loop = .{ .variable = index, .start = start, .limit = limit, .step = step } };
        }
        if (self.take("NEXT")) {
            self.space();
            return .{ .next_loop = if (self.rest.len == 0) null else try self.variable() };
        }
        if (self.take("LET")) {
            const index = try self.variable();
            try self.require("=");
            return .{ .assign = .{ .variable = index, .value = try self.expression(1) } };
        }
        if (self.take("GOTO")) return .{ .jump = try self.lineNumber() };
        if (self.take("IF")) {
            const condition = try self.expression(1);
            try self.require("THEN");
            const target = try self.lineNumber();
            const otherwise = if (self.take("ELSE")) try self.lineNumber() else null;
            return .{ .branch = .{ .condition = condition, .target = target, .otherwise = otherwise } };
        }
        if (self.take("CLOSE")) {
            try self.require("#1");
            return .close;
        }
        if (self.take("SYSTEM")) return .system;
        return error.UnsupportedStatement;
    }
};

fn parseLine(allocator: Allocator, source: []const u8) !Line {
    if (source.len > 255) return error.LineTooLong;
    for (source) |byte| if (byte < ' ' or byte > '~') return error.ExpectedPrintableAscii;
    var parser: Parser = .{ .allocator = allocator, .rest = source };
    const number = try parser.lineNumber();
    const statement = try parser.statement();
    parser.space();
    if (parser.rest.len != 0) return error.TrailingInput;
    return .{ .number = number, .statement = statement };
}

fn pairLoops(lines: []Line, diagnostic: *Writer) !void {
    var stack: [26]usize = undefined;
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

fn emitLine(out: *Writer, lines: []const Line, index: usize) !void {
    const line = lines[index];
    const next = if (index + 1 < lines.len) lines[index + 1].number else 0;
    try out.print("        {d} => {{\n", .{line.number});
    switch (line.statement) {
        .remark => {},
        .open => try out.writeAll("            try runtime.open();\n"),
        .print => |print| {
            for (print.values) |value| switch (value) {
                .text => |text| try out.print("            try runtime.output({}, \"{f}\");\n", .{ print.file, std.zig.fmtString(text) }),
                .number => |number| {
                    try out.print("            try runtime.number({}, ", .{print.file});
                    try number.emit(out);
                    try out.writeAll(");\n");
                },
            };
            try out.print("            try runtime.newline({});\n", .{print.file});
        },
        .input => |input| {
            try out.print("            runtime.variables[{d}] = try runtime.input(\"{f}\", {});\n", .{
                input.variable, std.zig.fmtString(input.prompt), input.question,
            });
        },
        .for_loop => |loop| {
            const after = lines[line.loop_partner.? + 1].number;
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
        .assign => |assign| {
            try out.print("            runtime.variables[{d}] = ", .{assign.variable});
            try assign.value.emit(out);
            try out.writeAll(";\n");
        },
        .jump => |target| {
            try out.print("            continue :dispatch {d};\n        }},\n", .{target});
            return;
        },
        .branch => |branch| {
            try out.writeAll("            if (");
            try branch.condition.emit(out);
            try out.print(" != 0) continue :dispatch {d};\n", .{branch.target});
            if (branch.otherwise) |target| {
                try out.print("            continue :dispatch {d};\n        }},\n", .{target});
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
    var physical_line: usize = 0;
    while (rows.next()) |row| {
        physical_line += 1;
        const source_line = if (std.mem.endsWith(u8, row, "\r")) row[0 .. row.len - 1] else row;
        if (std.mem.trim(u8, source_line, " ").len == 0) continue;
        const line = parseLine(allocator, source_line) catch |err| {
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
    const last = lines.getLastOrNull() orelse return error.EmptyProgram;
    if (last.statement != .system) return error.ExpectedFinalSystem;
    try pairLoops(lines.items, diagnostic);
    for (lines.items) |line| {
        const targets: [2]?u16 = switch (line.statement) {
            .jump => |target| .{ target, null },
            .branch => |branch| .{ branch.target, branch.otherwise },
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
        \\    var runtime: Runtime = .{{
        \\        .io = init.io,
        \\        .stdin = std.Io.File.stdin().readerStreaming(init.io, &input_buffer),
        \\    }};
        \\    defer runtime.release();
        \\    dispatch: switch (@as(u16, {d})) {{
        \\
    , .{lines.items[0].number});
    for (0..lines.items.len) |index| {
        try emitLine(out, lines.items, index);
    }
    try out.writeAll("        else => unreachable,\n    }\n}\n");
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

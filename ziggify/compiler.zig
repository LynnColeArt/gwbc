const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const Atom = union(enum) {
    literal: i16,
    variable: u8,

    fn emit(self: Atom, out: *Writer) !void {
        switch (self) {
            .literal => |value| try out.print("@as(i16, {d})", .{value}),
            .variable => |index| try out.print("runtime.variables[{d}]", .{index}),
        }
    }
};

const PrintValue = union(enum) {
    text: []const u8,
    number: Atom,
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
    for_loop: struct { variable: u8, start: Atom, limit: Atom, step: Atom },
    next_loop: ?u8,
    assign: struct { variable: u8, value: Atom, add: ?Atom },
    jump: u16,
    branch: struct { left: Atom, right: Atom, target: u16 },
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

    fn atom(self: *Parser) !Atom {
        self.space();
        if (self.rest.len != 0 and std.ascii.isAlphabetic(self.rest[0]))
            return .{ .variable = try self.variable() };
        const start = self.rest;
        if (self.rest.len != 0 and self.rest[0] == '-') self.rest = self.rest[1..];
        _ = self.digits();
        return .{ .literal = try std.fmt.parseInt(i16, start[0 .. start.len - self.rest.len], 10) };
    }

    // The opening quote has already been consumed.
    fn string(self: *Parser) ![]const u8 {
        const end = std.mem.indexOfScalar(u8, self.rest, '"') orelse return error.InvalidSyntax;
        const value = self.rest[0..end];
        self.rest = self.rest[end + 1 ..];
        return value;
    }

    fn printStatement(self: *Parser, allocator: Allocator) !Print {
        const file = self.take("#1");
        if (file) try self.require(",");
        self.space();
        var values: std.ArrayList(PrintValue) = .empty;
        while (self.rest.len != 0) {
            const value: PrintValue = if (self.take("\""))
                .{ .text = try self.string() }
            else
                .{ .number = try self.atom() };
            try values.append(allocator, value);
            if (!self.take(";")) break;
            if (self.rest.len == 0) return error.UnsupportedTrailingSemicolon;
        }
        return .{ .file = file, .values = values.items };
    }

    fn statement(self: *Parser, allocator: Allocator) !Statement {
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
        if (self.take("PRINT")) return .{ .print = try self.printStatement(allocator) };
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
            const start = try self.atom();
            try self.require("TO");
            const limit = try self.atom();
            const step = if (self.take("STEP")) try self.atom() else Atom{ .literal = 1 };
            return .{ .for_loop = .{ .variable = index, .start = start, .limit = limit, .step = step } };
        }
        if (self.take("NEXT")) {
            self.space();
            return .{ .next_loop = if (self.rest.len == 0) null else try self.variable() };
        }
        if (self.take("LET")) {
            const index = try self.variable();
            try self.require("=");
            const value = try self.atom();
            return .{ .assign = .{ .variable = index, .value = value, .add = if (self.take("+")) try self.atom() else null } };
        }
        if (self.take("GOTO")) return .{ .jump = try self.lineNumber() };
        if (self.take("IF")) {
            const left = try self.atom();
            try self.require("<");
            const right = try self.atom();
            try self.require("THEN");
            return .{ .branch = .{ .left = left, .right = right, .target = try self.lineNumber() } };
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
    var parser: Parser = .{ .rest = source };
    const number = try parser.lineNumber();
    const statement = try parser.statement(allocator);
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
            if (assign.add) |add| {
                try out.writeAll("try std.math.add(i16, ");
                try assign.value.emit(out);
                try out.writeAll(", ");
                try add.emit(out);
                try out.writeAll(")");
            } else try assign.value.emit(out);
            try out.writeAll(";\n");
        },
        .jump => |target| {
            try out.print("            continue :dispatch {d};\n        }},\n", .{target});
            return;
        },
        .branch => |branch| {
            try out.writeAll("            if (");
            try branch.left.emit(out);
            try out.writeAll(" < ");
            try branch.right.emit(out);
            try out.print(") continue :dispatch {d};\n", .{branch.target});
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
        const target = switch (line.statement) {
            .jump => |target| target,
            .branch => |branch| branch.target,
            else => continue,
        };
        if (!numbers.contains(target)) {
            try diagnostic.print("BASIC line {d} jumps to missing line {d}\n", .{ line.number, target });
            return error.UndefinedLine;
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

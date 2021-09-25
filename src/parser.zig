const std = @import("std");
const mem = std.mem;
const activeTag = std.meta.activeTag;

const lexer = @import("lexer.zig");
const codegen = @import("codegen.zig");

const Program = @import("common.zig").Program;
const Node = @import("common.zig").Node;
const ValueList = @import("common.zig").ValueList;
const NodeList = @import("common.zig").NodeList;

pub const Parser = struct {
    alloc: *mem.Allocator,
    program: *Program,

    const ParserError = error{
        StrayToken,
        EmptyList,
        ExpectedKeyword,
        ExpectedItems,
        ExpectedNode,
        UnexpectedItems,
        ExpectedValue,
        ExpectedStatement,
        UnknownKeyword,
        UnexpectedLabelDefinition,
    } || mem.Allocator.Error;

    pub fn init(program: *Program, alloc: *mem.Allocator) Parser {
        return .{
            .program = program,
            .alloc = alloc,
        };
    }

    fn validateListLength(ast: []const lexer.Node, require: usize) ParserError!void {
        if (ast.len < require) return error.ExpectedItems;
        if (ast.len > require) return error.UnexpectedItems;
    }

    fn expectNode(comptime nodetype: @TagType(lexer.Node.NodeType), node: *const lexer.Node) b: {
        break :b ParserError!@TypeOf(@field(node.node, @tagName(nodetype)));
    } {
        if (activeTag(node.node) != nodetype) {
            return error.ExpectedNode;
        }
        return @field(node.node, @tagName(nodetype));
    }

    fn parseValue(self: *Parser, node: *const lexer.Node) ParserError!Node.Value {
        return switch (node.node) {
            .Byte => |b| .{ .Byte = b },
            .Word => |w| .{ .Word = w },
            .Register => |r| .{ .Register = .{ .VRegister = r } },
            .Index => .{ .Register = .Index },
            .DelayTimer => .{ .Register = .DelayTimer },
            .Identifier => |i| .{ .Identifier = i },
            else => error.ExpectedValue,
        };
    }

    fn parseStatement(self: *Parser, node: *const lexer.Node) ParserError!Node {
        return switch (node.node) {
            .List => |l| try self.parseList(l.items),
            .Identifier => |i| Node{
                .node = .{ .UnresolvedIdentifier = i },
                .srcloc = node.location,
            },
            else => error.ExpectedStatement,
        };
    }

    fn parseList(self: *Parser, ast: []const lexer.Node) ParserError!Node {
        if (ast.len == 0)
            return error.EmptyList;

        return switch (ast[0].node) {
            .Keyword => |k| b: {
                if (mem.eql(u8, k, "def")) {
                    try validateListLength(ast, 3);
                    const name = try expectNode(.Identifier, &ast[1]);

                    const raw_body = try expectNode(.List, &ast[2]);
                    const body = try self.parseList(raw_body.items);

                    const heap_body = try self.alloc.create(Node);
                    heap_body.* = body;

                    break :b Node{
                        .node = .{ .Label = .{ .name = name, .body = heap_body } },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "data")) {
                    var res = ValueList.init(self.alloc);
                    for (ast[1..]) |node| {
                        try res.append(try self.parseValue(&node));
                    }

                    break :b Node{
                        .node = .{ .Data = res },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "do")) {
                    var res = NodeList.init(self.alloc);
                    for (ast[1..]) |node|
                        try res.append(try self.parseStatement(&node));

                    break :b Node{
                        .node = .{ .Proc = res },
                        .srcloc = ast[0].location,
                    };
                } else if (mem.eql(u8, k, "loop")) {
                    try validateListLength(ast, 2);

                    const body = try self.parseStatement(&ast[1]);
                    const heap_body = try self.alloc.create(Node);
                    heap_body.* = body;

                    break :b Node{
                        .node = .{ .Loop = heap_body },
                        .srcloc = ast[0].location,
                    };
                } else {
                    for (&codegen.BUILTINS) |*b| if (mem.eql(u8, b.name, k)) {
                        if (b.arg_num) |arg_count|
                            try validateListLength(ast, arg_count + 1);

                        var body = ValueList.init(self.alloc);
                        if (ast.len > 1) {
                            for (ast[1..]) |node|
                                try body.append(try self.parseValue(&node));
                        }

                        break :b Node{
                            .node = .{ .BuiltinCall = .{ .builtin = b, .node = body } },
                            .srcloc = ast[0].location,
                        };
                    };

                    break :b error.UnknownKeyword;
                }
            },
            .List => |l| try self.parseList(l.items),
            else => error.StrayToken,
        };
    }

    pub fn parse(self: *Parser, ast: *const lexer.NodeList) ParserError!void {
        for (ast.items) |*node| switch (node.node) {
            .List => |l| try self.program.body.append(try self.parseList(l.items)),
            else => return error.StrayToken,
        };
    }
};

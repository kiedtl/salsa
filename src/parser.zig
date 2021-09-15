const std = @import("std");
const mem = std.mem;
const activeTag = std.meta.activeTag;

const lexer = @import("lexer.zig");

const Program = @import("common.zig").Program;
const Node = @import("common.zig").Node;
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
    } || mem.Allocator.Error;

    pub fn init(program: *Program, alloc: *mem.Allocator) Parser {
        return .{
            .program = program,
            .alloc = alloc,
        };
    }

    fn validateListLength(ast: *const lexer.NodeList, require: usize) ParserError!void {
        if (ast.items.len < require) return error.ExpectedItems;
        if (ast.items.len > require) return error.UnexpectedItems;
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

    fn parseList(self: *Parser, ast: *const lexer.NodeList, is_child: bool) ParserError!Node {
        if (ast.items.len == 0)
            return error.EmptyList;

        return switch (ast.items[0].node) {
            .Keyword => |k| b: {
                if (mem.eql(u8, k, "def")) {
                    try validateListLength(ast, 3);
                    const name = try expectNode(.Identifier, &ast.items[1]);

                    const raw_body = try expectNode(.List, &ast.items[2]);
                    const body = try self.parseList(&raw_body, true);

                    const heap_body = try self.alloc.create(Node);
                    heap_body.* = body;

                    break :b Node{
                        .node = .{ .Label = .{ .name = name, .body = heap_body } },
                        .location = ast.items[0].location,
                        .is_child = is_child,
                    };
                } else if (mem.eql(u8, k, "data")) {
                    var res = std.ArrayList(Node.Value).init(self.alloc);
                    for (ast.items[1..]) |node| {
                        try res.append(try self.parseValue(&node));
                    }

                    break :b Node{
                        .node = .{ .Data = res },
                        .location = ast.items[0].location,
                        .is_child = is_child,
                    };
                } else {
                    break :b error.ExpectedValue; // temporary
                }
            },
            .List => |l| try self.parseList(&l, true),
            else => error.StrayToken,
        };
    }

    pub fn parse(self: *Parser, ast: *const lexer.NodeList) ParserError!void {
        for (ast.items) |*node| switch (node.node) {
            .List => |l| try self.program.body.append(try self.parseList(&l, false)),
            else => return error.StrayToken,
        };
    }
};

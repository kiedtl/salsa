const std = @import("std");
const mem = std.mem;
const activeTag = std.meta.activeTag;
const assert = std.debug.assert;

pub const NodeList = std.ArrayList(Node);

pub const Node = struct {
    node: NodeType,
    location: usize,

    pub const NodeType = union(enum) {
        Integer: usize,
        Register: u4,
        Index: void,
        DelayTimer: void,
        Identifier: []const u8,
        Keyword: []const u8,
        List: NodeList,
        Metadata: []const u8,
    };

    pub fn deinit(self: *Node, alloc: *mem.Allocator) void {
        switch (self.node) {
            .Identifier => |data| alloc.free(data),
            .Keyword => |data| alloc.free(data),
            .Metadata => |data| alloc.free(data),
            .List => |list| {
                for (list.items) |li| li.deinit(alloc);
                list.deinit();
            },
        }
    }
};

pub const Lexer = struct {
    input: []const u8,
    alloc: *mem.Allocator,
    stack: usize = 0,
    index: usize = 0,

    const Self = @This();

    const LexerError = error{
        NoMatchingParen,
        UnexpectedClosingParen,
        InvalidCharLiteral,
        InvalidReg,
        InvalidUtf8,
    } || std.fmt.ParseIntError || std.mem.Allocator.Error;

    pub fn init(input: []const u8, alloc: *mem.Allocator) Self {
        return .{ .input = input, .alloc = alloc };
    }

    pub fn lexValue(self: *Self, vtype: u21) LexerError!Node.NodeType {
        if (vtype != 'k' and vtype != 'i' and vtype != '#')
            self.index += 1;
        const oldi = self.index;

        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                0x09...0x0d, 0x20, '(', ')' => break,
                else => {},
            }
        }

        const word = self.input[oldi..self.index];
        assert(word.len > 0);

        // lex() expects index to point to last non-word char, so move index back
        self.index -= 1;

        return switch (vtype) {
            'k', 'i', ':' => blk: {
                const s = try self.alloc.alloc(u8, word.len);
                mem.copy(u8, s, word);
                break :blk switch (vtype) {
                    'k' => Node.NodeType{ .Keyword = s },
                    'i' => Node.NodeType{ .Identifier = s },
                    ':' => Node.NodeType{ .Metadata = s },
                    else => unreachable,
                };
            },
            '#' => blk: {
                var base: u8 = 10;
                var offset: usize = 0;

                if (mem.startsWith(u8, word, "0x")) {
                    base = 16;
                    offset = 2;
                } else if (mem.startsWith(u8, word, "0b")) {
                    base = 2;
                    offset = 2;
                } else if (mem.startsWith(u8, word, "0o")) {
                    base = 2;
                    offset = 2;
                }

                break :blk Node.NodeType{
                    .Integer = try std.fmt.parseInt(usize, word[offset..], base),
                };
            },
            '\'' => blk: {
                var utf8 = (std.unicode.Utf8View.init(word) catch |_| return error.InvalidUtf8).iterator();
                const encoded_codepoint = utf8.nextCodepointSlice() orelse return error.InvalidCharLiteral;
                if (utf8.nextCodepointSlice()) |_| return error.InvalidCharLiteral;
                const codepoint = std.unicode.utf8Decode(encoded_codepoint) catch |_| return error.InvalidUtf8;
                break :blk Node.NodeType{ .Integer = @intCast(usize, codepoint) };
            },
            '%' => blk: {
                if (mem.eql(u8, word, "timer")) {
                    break :blk Node.NodeType{ .DelayTimer = {} };
                } else if (mem.eql(u8, word, "index")) {
                    break :blk Node.NodeType{ .Index = {} };
                } else if (word[0] == 'v' and word.len == 2) {
                    const reg = std.fmt.parseInt(usize, word[1..], 16) catch |_| return error.InvalidReg;
                    if (reg > 15) return error.InvalidReg;
                    break :blk Node.NodeType{ .Register = @intCast(u4, reg) };
                } else return error.InvalidReg;
            },
            else => @panic("what were you trying to do anyway"),
        };
    }

    pub fn lex(self: *Self) LexerError!NodeList {
        self.stack += 1;
        var res = NodeList.init(self.alloc);

        // Move past the first ( if we're parsing a list
        if (self.stack > 1) {
            assert(self.input[self.index] == '(');
            self.index += 1;
        }

        while (self.index < self.input.len) : (self.index += 1) {
            const ch = self.input[self.index];

            var vch = self.index;
            var v: Node.NodeType = switch (ch) {
                0x09...0x0d, 0x20 => continue,
                '0'...'9' => try self.lexValue('#'),
                ':', '\'', '%' => try self.lexValue(ch),
                '(' => Node.NodeType{ .List = try self.lex() },
                ')' => {
                    if (self.stack <= 1) {
                        return error.UnexpectedClosingParen;
                    }

                    self.stack -= 1;
                    return res;
                },
                else => blk: {
                    if (self.stack > 1 and res.items.len == 0) {
                        break :blk try self.lexValue('k');
                    } else {
                        break :blk try self.lexValue('i');
                    }
                },
            };

            res.append(Node{
                .node = v,
                .location = vch,
            }) catch |_| return error.OutOfMemory;
        }

        return res;
    }
};

const testing = std.testing;

test "basic lexing" {
    var membuf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(membuf[0..]);

    const input = "0xfe 0xf1 0xf0 fum (test :foo bar 0xBEEF) (12 ('ë %v2) %index %timer)";
    var lexer = Lexer.init(input, &fba.allocator);
    var result = try lexer.lex();
    defer (result.deinit());

    testing.expectEqual(@as(usize, 6), result.items.len);

    testing.expectEqual(activeTag(result.items[0].node), .Integer);
    testing.expectEqual(@as(usize, 0xfe), result.items[0].node.Integer);

    testing.expectEqual(activeTag(result.items[1].node), .Integer);
    testing.expectEqual(@as(usize, 0xf1), result.items[1].node.Integer);

    testing.expectEqual(activeTag(result.items[2].node), .Integer);
    testing.expectEqual(@as(usize, 0xf0), result.items[2].node.Integer);

    testing.expectEqual(activeTag(result.items[3].node), .Identifier);
    testing.expectEqualSlices(u8, "fum", result.items[3].node.Identifier);

    testing.expectEqual(activeTag(result.items[4].node), .List);
    {
        const list = result.items[4].node.List.items;

        testing.expectEqual(activeTag(list[0].node), .Keyword);
        testing.expectEqualSlices(u8, "test", list[0].node.Keyword);

        testing.expectEqual(activeTag(list[1].node), .Metadata);
        testing.expectEqualSlices(u8, "foo", list[1].node.Metadata);

        testing.expectEqual(activeTag(list[2].node), .Identifier);
        testing.expectEqualSlices(u8, "bar", list[2].node.Identifier);

        testing.expectEqual(activeTag(list[3].node), .Integer);
        testing.expectEqual(@as(usize, 0xBEEF), list[3].node.Integer);
    }

    testing.expectEqual(activeTag(result.items[5].node), .List);
    {
        const list = result.items[5].node.List.items;

        testing.expectEqual(activeTag(list[0].node), .Integer);
        testing.expectEqual(@as(usize, 12), list[0].node.Integer);

        testing.expectEqual(activeTag(list[1].node), .List);
        {
            const list2 = list[1].node.List.items;

            testing.expectEqual(activeTag(list2[0].node), .Integer);
            testing.expectEqual(@as(usize, 'ë'), list2[0].node.Integer);

            testing.expectEqual(activeTag(list2[1].node), .Register);
            testing.expectEqual(@as(u4, 2), list2[1].node.Register);
        }

        testing.expectEqual(activeTag(list[2].node), .Index);

        testing.expectEqual(activeTag(list[3].node), .DelayTimer);
    }
}

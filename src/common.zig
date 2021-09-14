const std = @import("std");
const mem = std.mem;

// Manage the memory layout of the ROM
pub const ROM_Allocator = struct {
    labels: std.ArrayList(Block),
    data: std.ArrayList(Block),

    pub const Block = struct {
        size: usize,
        name: []const u8,
        node: ?*Node,
    };

    pub fn init(alloc: *mem.Allocator) ROM_Allocator {
        return .{
            .labels = std.ArrayList(Block).init(alloc),
            .data = std.ArrayList(Block).init(alloc),
        };
    }

    pub fn addLabel(self: *ROM_Allocator, name: []const u8, node: *Node) !usize {
        try self.labels.append(.{ .size = undefined, .name = name, .node = node });
        return self.labels.items.len - 1;
    }
};

pub const NodeList = std.ArrayList(Node);

pub const Node = struct {
    node: NodeType,
    location: usize,
    is_child: bool,

    pub const NodeType = union(enum) {
        Assignment: Assignment,
        Label: Label,
        Loop: *Node,
        Proc: NodeList,
        Data: std.ArrayList(Value),
    };

    pub const Register = union(enum) {
        VRegister: u4,
        Index,
        DelayTimer,
    };

    pub const Value = union(enum) {
        Identifier: []const u8,
        Register: Register,
        Literal: usize,
    };

    pub const Label = struct {
        name: []const u8,
        ra_id: ?usize = null,
        body: *Node,
    };

    pub const Assignment = struct {
        source: Value,
        dest: Register,
    };
};

pub const Program = struct {
    ra_alloc: ROM_Allocator,
    body: NodeList,

    pub fn init(alloc: *mem.Allocator) Program {
        return .{
            .ra_alloc = ROM_Allocator.init(alloc),
            .body = NodeList.init(alloc),
        };
    }
};

const std = @import("std");
const mem = std.mem;

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
        body: *Node,
    };

    pub const Assignment = struct {
        source: Value,
        dest: Register,
    };
};

pub const Program = struct {
    // Nodes must *not* be added to this list after parsing is complete, period.
    // Doing so may cause a reallocation, invalidating all existing pointers.
    body: NodeList,

    labels: std.ArrayList(Label),

    pub const Label = struct {
        name: []const u8,
        node: *Node,
    };

    pub fn init(alloc: *mem.Allocator) Program {
        return .{
            .body = NodeList.init(alloc),
            .labels = std.ArrayList(Label).init(alloc),
        };
    }
};

const std = @import("std");
const mem = std.mem;

const StackBuffer = @import("buffer.zig").StackBuffer;
const StackBufferError = @import("buffer.zig").StackBufferError;

pub const ROMBuf = StackBuffer(u8, 65535);
pub const NodeList = std.ArrayList(Node);

pub const Node = struct {
    node: NodeType,
    location: usize,
    is_child: bool,

    pub const NodeType = union(enum) {
        Data: std.ArrayList(Value),
        Assignment: Assignment,
        Label: Label,
        Loop: *Node,
        Proc: NodeList,
    };

    pub const Register = union(enum) {
        VRegister: u4,
        Index,
        DelayTimer,
    };

    pub const Value = union(enum) {
        Identifier: []const u8,
        Register: Register,
        Byte: u8,
        Word: u16,
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
        location: usize = 0,
    };

    pub fn init(alloc: *mem.Allocator) Program {
        return .{
            .body = NodeList.init(alloc),
            .labels = std.ArrayList(Label).init(alloc),
        };
    }
};

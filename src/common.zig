const std = @import("std");
const mem = std.mem;

const StackBuffer = @import("buffer.zig").StackBuffer;
const StackBufferError = @import("buffer.zig").StackBufferError;
const Builtin = @import("builtin.zig").Builtin;

pub const ROMBuf = StackBuffer(u8, 65535);
pub const NodeList = std.ArrayList(Node);
pub const ValueList = std.ArrayList(Node.Value);

pub const Node = struct {
    node: NodeType,
    location: usize,
    is_child: bool,

    pub const NodeTag = @TagType(Node.NodeType);

    pub const NodeType = union(enum) {
        Label: Label, // Label declaration
        BuiltinCall: BuiltinCall,
        Loop: *Node,
        Data: ValueList, // Data block
        Proc: NodeList, // Function block
        UnresolvedIdentifier: []const u8,
    };

    pub const BuiltinCall = struct {
        builtin: *const Builtin,
        node: ValueList,
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

const std = @import("std");
const mem = std.mem;

const LinkedList = @import("list.zig").LinkedList;
const StackBuffer = @import("buffer.zig").StackBuffer;
const StackBufferError = @import("buffer.zig").StackBufferError;
const Builtin = @import("codegen.zig").Builtin;

pub const ROMBuf = StackBuffer(u8, 65535);
pub const ValueList = std.ArrayList(Node.Value);
pub const NodeList = LinkedList(Node);
pub const NodePtrArrayList = std.ArrayList(*Node);

pub const Node = struct {
    __prev: ?*Node = null,
    __next: ?*Node = null,

    node: NodeType,
    srcloc: usize,
    romloc: usize = 0,

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
        Integer: usize,
    };

    pub const Label = struct {
        name: []const u8,
        body: *Node,
    };
};

pub const Program = struct {
    body: NodeList,
    scope: Scope,

    pub const Scope = struct {
        parent: ?*Scope,
        children: ArrayList,
        node: ?*Node,
        labels: NodePtrArrayList,

        pub const ArrayList = std.ArrayList(*Scope);
    };

    pub fn init(alloc: *mem.Allocator) Program {
        return .{
            .body = NodeList.init(alloc),
            .scope = .{
                .parent = null,
                .children = Scope.ArrayList.init(alloc),
                .node = null,
                .labels = NodePtrArrayList.init(alloc),
            },
        };
    }
};

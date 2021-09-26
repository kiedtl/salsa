// All UI_* functions are utility methods to construct CHIP-8 instructions.

const std = @import("std");
const mem = std.mem;
const activeTag = std.meta.activeTag;
const assert = std.debug.assert;

const StackBufferError = @import("buffer.zig").StackBufferError;
const ROMBuf = @import("common.zig").ROMBuf;
const Program = @import("common.zig").Program;
const Node = @import("common.zig").Node;
const Value = @import("common.zig").Node.Value;
const ValueList = @import("common.zig").ValueList;
const NodeList = @import("common.zig").NodeList;
const NodePtrArrayList = @import("common.zig").NodePtrArrayList;

const ROM_START = 0x200;

const CodegenError = error{
    DuplicateLabel,
    RegisterFoundInDataBlock,
    ShortAddrFoundInDataROM,
    LabelFoundAsChild,
    UnknownIdentifier,
    ExpectedRegister,
    InvalidArgument,
    IntegerTooLarge,
} || mem.Allocator.Error || StackBufferError;

// UA: Unresolved Address
//
// As we walk through the AST generating bytecode, we store references to
// identifiers in a UAList and insert a dummy null value into the ROM; later on,
// we iterate through the UAList, replacing the dummy values with the real
// references.
//
// The reason for this is that although we know what each identifiers are
// (they were extracted earlier), we don't know where they'll be in the ROM
// until *after* the codegen process.
//
// The UAType determines how the ual-resolver should insert the address:
//      - Data:      insert as a raw byte.
//      - Call:      insert and mask with 0x2000.
//      - Jump:      insert and mask with 0x1000.
//      - IndexLoad: insert and mask with 0xA000.
//
const UAList = std.ArrayList(UA);
const UAType = enum { Data, Call, Jump, IndexLoad };
const UA = struct {
    romloc: usize,
    identifier: []const u8,
    type: UAType,
    node: *Node,
    scope: *Program.Scope,
};

pub const BuiltinFunc = fn (*Program.Scope, *Node, []const Value, buf: *ROMBuf, *UAList) CodegenError!void;

pub const Builtin = struct {
    name: []const u8,
    arg_num: ?usize, // null for unchecked
    func: BuiltinFunc,
};

// zig fmt: off
pub const BUILTINS = [_]Builtin{
    .{ .name =    "=", .arg_num = 2, .func = _b_assign },
    .{ .name =    "+", .arg_num = 2, .func = _b_addassign },
    .{ .name = "draw", .arg_num = 3, .func = _b_draw },
};
// zig fmt: on

//
//
// -----------------------------------------------------------------------------
//
//

fn checkIntSize(comptime T: type, i: usize) CodegenError!T {
    const max = std.math.maxInt(T);
    if (i > max) return error.IntegerTooLarge;
    return @intCast(T, i);
}

// 1NNN: JMP: Jump to NNN
fn UI_jump(address: u12) u16 {
    return 0x1000 | @as(u16, ROM_START + address);
}

fn emit(buf: *ROMBuf, data: anytype) CodegenError!void {
    const T = @TypeOf(data);

    if (T == u8) {
        try buf.append(data);
    } else if (T == u16) {
        try buf.append(@intCast(u8, (data >> 8) & 0xFF));
        try buf.append(@intCast(u8, (data >> 0) & 0xFF));
    } else if (T == usize) {
        @compileError("Type usize is ambigious");
    } else {
        @compileError("Expected u8 or u16, got '" ++ @typeName(T) ++ "'");
    }
}

fn emitUA(
    buf: *ROMBuf,
    scope: *Program.Scope,
    ual: *UAList,
    uatype: UAType,
    ident: []const u8,
    node: *Node,
) CodegenError!void {
    // FIXME: we just assume that we're dealing with a 16-bit address/word/data here,
    // but if uatype == .Data it could be a u8 as well. We should automatically infer
    // that here (we *should* know all identifiers by now, just not the addresses)
    try ual.append(.{
        .romloc = buf.len,
        .identifier = ident,
        .scope = scope,
        .type = uatype,
        .node = node,
    });
    try emit(buf, @as(u16, 0x0000));
}

fn genNodeBytecode(
    program: *Program,
    scope: *Program.Scope,
    node: *Node,
    buf: *ROMBuf,
    ual: *UAList,
    alloc: *mem.Allocator,
) CodegenError!void {
    switch (node.node) {
        .Label => |l| {
            // Create a new scope
            const newscope = try alloc.create(Program.Scope);
            newscope.* = .{
                .parent = scope,
                .children = Program.Scope.ArrayList.init(alloc),
                .node = node,
                .labels = NodePtrArrayList.init(alloc),
            };
            try scope.children.append(newscope);
            try scope.labels.append(node);

            node.romloc = buf.len;
            try genNodeBytecode(program, newscope, l.body, buf, ual, alloc);
        },
        .BuiltinCall => |b| try (b.builtin.func)(scope, node, b.node.items, buf, ual),
        .Loop => |l| {
            const loop_start = buf.len - 2;
            if ((ROM_START + loop_start) >= 0xFFF) {
                return error.ShortAddrFoundInDataROM;
            }

            // TODO: create new scope
            try genNodeBytecode(program, scope, l, buf, ual, alloc);
            try emit(buf, UI_jump(@intCast(u12, loop_start)));
        },
        .Data => |d| for (d.items) |value| switch (value) {
            .Register => |_| return error.RegisterFoundInDataBlock,
            .Identifier => |i| try emitUA(buf, scope, ual, .Data, i, node),
            .Integer => |i| {
                if (i > 0xFF) return error.IntegerTooLarge;
                try emit(buf, @intCast(u8, i));
            },
        },
        .Proc => |p| {
            var iter = p.iterator();
            while (iter.next()) |pn|
                try genNodeBytecode(program, scope, pn, buf, ual, alloc);
        },
        .UnresolvedIdentifier => |i| try emitUA(buf, scope, ual, .Call, i, node),
    }
}

pub fn generateBinary(program: *Program, buf: *ROMBuf, alloc: *mem.Allocator) CodegenError!void {
    var ual = UAList.init(alloc);

    var bodyiter = program.body.iterator();
    while (bodyiter.next()) |node| {
        try genNodeBytecode(program, &program.scope, node, buf, &ual, alloc);
    }

    ual_search: for (ual.items) |ua| {
        var _scope: ?*Program.Scope = &program.scope;
        while (_scope) |scope| : (_scope = _scope.?.parent) {
            for (scope.labels.items) |labelnode| {
                const label = labelnode.node.Label;

                if (mem.eql(u8, label.name, ua.identifier)) {
                    const val: u16 = switch (ua.type) {
                        .Data => @intCast(u16, ROM_START + labelnode.romloc),
                        .Call, .Jump, .IndexLoad => b: {
                            if (labelnode.romloc >= 0xFFF) {
                                return error.ShortAddrFoundInDataROM;
                            }

                            const mask: u16 = switch (ua.type) {
                                .Call => 0x1000,
                                .Jump => 0x2000,
                                .IndexLoad => 0xA000,
                                else => unreachable,
                            };

                            break :b @intCast(u16, mask | (ROM_START + labelnode.romloc));
                        },
                    };
                    buf.data[ua.romloc + 0] = @intCast(u8, (val >> 8) & 0xFF);
                    buf.data[ua.romloc + 1] = @intCast(u8, (val >> 0) & 0xFF);

                    continue :ual_search;
                }
            }
        }

        // If we haven't matched a UA with a label by now, it's an invalid
        // identifier
        return error.UnknownIdentifier;
    }
}

// zig fmt: off
//
// -----------------------------------------------------------------------------
//
// zig fmt: on

fn _b_assign(scope: *Program.Scope, node: *Node, args: []const Value, buf: *ROMBuf, ual: *UAList) CodegenError!void {
    assert(args.len == 2);

    if (activeTag(args[0]) != .Register)
        return error.ExpectedRegister;

    switch (args[0].Register) {
        .VRegister => |dest| switch (args[1]) {
            .Integer => |i| try emit(buf, @as(u16, 0x6000 | (@as(u16, dest) << 8) | (try checkIntSize(u8, i)))),
            .Register => |r| switch (r) {
                .VRegister => |src| try emit(buf, @as(u16, 0x8000 | (@as(u16, dest) << 8) | (@as(u16, src) << 4))),
                .DelayTimer => try emit(buf, @as(u16, 0xF000 | (@as(u16, dest) << 8) | 0x07)),
                else => return error.InvalidArgument,
            },
            else => return error.InvalidArgument,
        },
        .Index => switch (args[1]) {
            .Integer => |i| if ((ROM_START + i) <= 0xFFF) {
                try emit(buf, @as(u16, 0xA000 | @as(u16, try checkIntSize(u12, i))));
            } else {
                try emit(buf, @as(u16, 0xF000));
                try emit(buf, @as(u16, ROM_START + (try checkIntSize(u16, i))));
            },
            .Identifier => |i| {
                //try emit(buf, @as(u16, 0xF000));
                //try emitUA(buf, ual, .Data, i, node);
                try emitUA(buf, scope, ual, .IndexLoad, i, node);
            },
            else => return error.InvalidArgument,
        },
        .DelayTimer => switch (args[1]) {
            .Register => |r| switch (r) {
                .VRegister => |src| try emit(buf, @as(u16, 0xF000 | (@as(u16, src) << 8))),
                else => return error.InvalidArgument,
            },
            else => return error.InvalidArgument,
        },
    }
}

fn _b_addassign(scope: *Program.Scope, node: *Node, args: []const Value, buf: *ROMBuf, ual: *UAList) CodegenError!void {
    assert(args.len == 2);

    if (activeTag(args[0]) != .Register)
        return error.ExpectedRegister;

    switch (args[0].Register) {
        .VRegister => |dest| switch (args[1]) {
            .Integer => |i| try emit(buf, @as(u16, 0x7000 | (@as(u16, dest) << 8) | (try checkIntSize(u8, i)))),
            .Register => |r| switch (r) {
                .VRegister => |src| try emit(buf, @as(u16, 0x8000 | (@as(u16, dest) << 8) | (@as(u16, src) << 4) | 0x4)),
                else => return error.InvalidArgument,
            },
            else => return error.InvalidArgument,
        },
        else => return error.InvalidArgument,
    }
}

fn _b_draw(scope: *Program.Scope, node: *Node, args: []const Value, buf: *ROMBuf, ual: *UAList) CodegenError!void {
    assert(args.len == 3);

    if (activeTag(args[0]) != .Register and activeTag(args[0].Register) != .VRegister)
        return error.InvalidArgument;
    if (activeTag(args[1]) != .Register and activeTag(args[1].Register) != .VRegister)
        return error.InvalidArgument;
    if (activeTag(args[2]) != .Integer)
        return error.InvalidArgument;

    const vx = @as(u16, args[0].Register.VRegister);
    const vy = @as(u16, args[1].Register.VRegister);
    const sz = try checkIntSize(u3, args[2].Integer);

    try emit(buf, @as(u16, 0xD000 | (vx << 8) | (vy << 4) | sz));
}

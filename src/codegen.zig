// All UI_* functions are utility methods to construct CHIP-8 instructions.

const std = @import("std");
const mem = std.mem;
const activeTag = std.meta.activeTag;
const assert = std.debug.assert;

const StackBufferError = @import("buffer.zig").StackBufferError;
const ROMBuf = @import("common.zig").ROMBuf;
const Program = @import("common.zig").Program;
const Node = @import("common.zig").Node;
const NodeList = @import("common.zig").NodeList;

const CodegenError = error{
    DuplicateLabel,
    NoMainLabel,
    RegisterFoundInDataBlock,
    JumpFoundInDataROM,
    LabelFoundAsChild,
    UnknownIdentifier,
    ExpectedRegister,
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
const UAList = std.ArrayList(UA);
const UAType = enum { Data, Call };
const UA = struct {
    romloc: usize,
    identifier: []const u8,
    type: UAType,
    node: *Node,
};

pub const BuiltinFunc = fn (*const ValueList, buf: *ROMBuf) BuiltinError!void;

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

// 2NNN: JMP: Jump to NNN
fn UI_jump(address: u12) u16 {
    return 0x2000 | @as(u16, address);
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

fn emitUA(buf: *ROMBuf, ual: *UAList, uatype: UAType, ident: []const u8, node: *Node) CodegenError!void {
    // FIXME: we just assume that we're dealing with a 16-bit address/word/data here,
    // but if uatype == .Data it could be a u8 as well. We should automatically infer
    // that here (we *should* know all identifiers by now, just not the addresses)
    try ual.append(.{
        .romloc = buf.len,
        .identifier = ident,
        .type = uatype,
        .node = node,
    });
    try emit(buf, @as(u16, 0x0000));
}

fn genNodeBytecode(node: *Node, buf: *ROMBuf, ual: *UAList) CodegenError!void {
    switch (node.node) {
        .Label => |l| return error.LabelFoundAsChild,
        .BuiltinCall => |b| try (b.builtin.func)(b.node.items, buf),
        .Loop => |l| {
            const loop_start = buf.len;
            if (loop_start >= 0xFFF) {
                return error.JumpFoundInDataROM;
            }

            try genNodeBytecode(l, buf, ual);
            try emit(buf, UI_jump(@intCast(u12, loop_start)));
        },
        .Data => |d| for (d.items) |value| switch (value) {
            .Register => |_| return error.RegisterFoundInDataBlock,
            .Identifier => |i| try emitUA(buf, ual, .Data, i, node),
            .Byte => |b| try buf.append(b),
            .Word => |w| try emit(buf, w),
        },
        .Proc => |p| for (p.items) |*pn| try genNodeBytecode(pn, buf, ual),
        .UnresolvedIdentifier => |i| try emitUA(buf, ual, .Call, i, node),
    }
}

pub fn generateBinary(program: *Program, buf: *ROMBuf, alloc: *mem.Allocator) CodegenError!void {
    var ual = UAList.init(alloc);

    for (program.labels.items) |*label| {
        label.location = buf.len;
        try genNodeBytecode(label.node.node.Label.body, buf, &ual);
    }

    for (ual.items) |ua| {
        for (program.labels.items) |label| if (mem.eql(u8, label.name, ua.identifier)) {
            const val: u16 = switch (ua.type) {
                .Data => @intCast(u16, label.location),
                .Call => b: {
                    if (label.location >= 0xFFF) {
                        return error.JumpFoundInDataROM;
                    }
                    break :b @intCast(u16, 0x2000 | label.location);
                },
            };
            buf.data[ua.romloc + 0] = @intCast(u8, (val >> 8) & 0xFF);
            buf.data[ua.romloc + 1] = @intCast(u8, (val >> 0) & 0xFF);
        };

        // If we haven't matched a UA with a label by now, it's an invalid
        // identifier
        return error.UnknownIdentifier;
    }
}

// - Extract labels into program.labels, deduplicating them in the process.
// - The first label is always the starting one.
//
pub fn extractLabels(program: *Program) CodegenError!void {
    for (program.body.items) |*node| switch (node.node) {
        .Label => |l| {
            // Check if the label is already defined.
            for (program.labels.items) |e_l| if (mem.eql(u8, e_l.name, l.name))
                return error.DuplicateLabel;

            const label = Program.Label{ .name = l.name, .node = node };

            if (mem.eql(u8, l.name, "main")) {
                try program.labels.insert(0, label);
            } else {
                try program.labels.append(label);
            }
        },
        else => {},
    };

    if (program.labels.items.len == 0 or
        !mem.eql(u8, "main", program.labels.items[0].name))
    {
        return error.NoMainLabel;
    }
}

// zig fmt: off
//
// -----------------------------------------------------------------------------
//
// zig fmt: on

fn _b_assign(args: []const Value, buf: *ROMBuf) CodegenError!void {
    assert(args.len == 2);

    if (activeTag(args[0]) != .Register)
        return error.ExpectedRegister;
}

fn _b_addassign(args: []const Value, buf: *ROMBuf) CodegenError!void {
    // TODO
}

fn _b_draw(args: []const Value, buf: *ROMBuf) CodegenError!void {
    // TODO
}

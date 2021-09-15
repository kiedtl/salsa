const std = @import("std");
const mem = std.mem;

const StackBufferError = @import("buffer.zig").StackBufferError;
const ROMBuf = @import("common.zig").ROMBuf;
const Program = @import("common.zig").Program;
const Node = @import("common.zig").Node;
const NodeList = @import("common.zig").NodeList;

const CodegenError = error{
    DuplicateLabel,
    NoMainLabel,
    RegisterFoundInDataBlock,
} || mem.Allocator.Error || StackBufferError;

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

fn generateBinaryForNode(node: *Node, buf: *ROMBuf) CodegenError!void {
    switch (node.node) {
        .Data => |d| for (d.items) |value| switch (value) {
            .Register => |_| return error.RegisterFoundInDataBlock,
            .Identifier => |_| @panic("TODO"),
            .Byte => |b| try buf.append(b),
            .Word => |w| {
                try buf.append(@intCast(u8, (w >> 8) & 0xFF));
                try buf.append(@intCast(u8, (w >> 0) & 0xFF));
            },
        },
        else => @panic("TODO"),
    }
}

pub fn generateBinary(program: *Program, buf: *ROMBuf) CodegenError!void {
    for (program.labels.items) |*label| {
        label.location = buf.len;
        try generateBinaryForNode(label.node.node.Label.body, buf);
    }
}

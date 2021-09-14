const std = @import("std");
const mem = std.mem;

const Program = @import("common.zig").Program;
const Node = @import("common.zig").Node;
const NodeList = @import("common.zig").NodeList;

const CodegenError = error{
    DuplicateLabel,
    NoMainLabel,
} || mem.Allocator.Error;

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

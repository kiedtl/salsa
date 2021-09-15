const std = @import("std");
const mem = std.mem;

const lexerm = @import("lexer.zig");
const parserm = @import("parser.zig");
const codegen = @import("codegen.zig");

const Program = @import("common.zig").Program;
const ROMBuf = @import("common.zig").ROMBuf;

pub var gpa = std.heap.GeneralPurposeAllocator(.{
    // Probably should enable this later on to track memory usage, if
    // allocations become too much
    .enable_memory_limit = false,

    .safety = true,

    // Probably would enable this later?
    .thread_safe = false,

    .never_unmap = false,
}){};

pub fn main() anyerror!void {
    var program = Program.init(&gpa.allocator);
    var emitted = ROMBuf.init(null);

    const file = try std.fs.cwd().openFile("code.sls", .{});
    defer file.close();

    const size = try file.getEndPos();
    const buf = try gpa.allocator.alloc(u8, size);
    defer gpa.allocator.free(buf);
    _ = try file.readAll(buf);

    var lexer = lexerm.Lexer.init(buf, &gpa.allocator);
    const lexed = try lexer.lex();

    var parser = parserm.Parser.init(&program, &gpa.allocator);
    try parser.parse(&lexed);

    try codegen.extractLabels(&program);
    try codegen.generateBinary(&program, &emitted);

    const outf = try std.fs.cwd().createFile("code.ch8", .{ .truncate = true });
    try outf.writeAll(emitted.constSlice());
}

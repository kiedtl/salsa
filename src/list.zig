const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

// Basic node that can be used for scalar data.
pub fn ScalarNode(comptime T: type) type {
    return struct {
        const Self = @This();

        __prev: ?*Self = null,
        __next: ?*Self = null,
        data: T,
    };
}

pub fn LinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Iterator = struct {
            current: ?*T,

            pub fn next(iter: *Iterator) ?*T {
                const current = iter.current;
                var result: ?*T = undefined;

                if (current) |c| {
                    iter.current = c.__next;
                    return c;
                } else {
                    return null;
                }
            }
        };

        head: ?*T,
        tail: ?*T,
        allocator: *mem.Allocator,

        pub fn init(allocator: *mem.Allocator) Self {
            return Self{
                .head = null,
                .tail = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.head == null) {
                return;
            }

            var current = self.head.?;
            while (current.__next) |next| {
                self.allocator.destroy(current);
                current = next;
            }

            self.allocator.destroy(current);
        }

        // Make a copy of data and allocate it on the heap, then append to the
        // list.
        pub fn append(self: *Self, data: T) !void {
            var node = try self.allocator.create(T);
            node.* = data;

            if (self.tail) |tail| {
                assert(tail.__next == null);

                node.__prev = tail;
                node.__next = null;
                tail.__next = node;
                self.tail = node;
            } else {
                node.__prev = null;
                node.__next = null;
                self.head = node;
                self.tail = node;
            }
        }

        pub fn remove(self: *Self, node: *T) void {
            if (node.__prev) |prevn| prevn.__next = node.__next;
            if (node.__next) |nextn| nextn.__prev = node.__prev;

            if (self.head == node) self.head = node.__next;
            if (self.tail == node) self.tail = node.__prev;

            self.allocator.destroy(node);
        }

        pub fn nth(self: *Self, n: usize) ?*T {
            var i: usize = 0;
            var iter = self.iterator();
            while (iter.next()) |item| : (i += 1) {
                if (i == n) {
                    return item;
                }
            }
            return null;
        }

        pub fn first(self: *Self) ?*T {
            return if (self.head) |head| head else null;
        }

        pub fn last(self: *Self) ?*T {
            return if (self.tail) |tail| tail else null;
        }

        // TODO: allow const iteration
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .current = self.head };
        }
    };
}

// Use a GPA for tests as then we get an error when there's a memory leak
const GPA = std.heap.GeneralPurposeAllocator(.{});

test "basic LinkedList test" {
    const Node = ScalarNode(usize);
    const List = LinkedList(Node);

    var gpa = GPA{};
    defer testing.expect(!gpa.deinit());

    var list = List.init(&gpa.allocator);
    defer list.deinit();

    const datas = [_]usize{ 5, 22, 623, 1, 36 };
    for (datas) |data| {
        try list.append(Node{ .data = data });
        testing.expectEqual(data, list.last().?.data);
    }

    testing.expectEqual(datas[0], list.first().?.data);
    testing.expectEqual(datas[4], list.last().?.data);

    // TODO: separate iterator test into its own test
    var index: usize = 0;
    var iter = list.iterator();
    while (iter.next()) |node| : (index += 1) {
        testing.expectEqual(datas[index], node.data);
    }

    iter = list.iterator();
    while (iter.next()) |node| {
        if (node.data % 2 == 0)
            list.remove(node);
    }

    testing.expectEqual(list.nth(0).?.data, 5);
    testing.expectEqual(list.nth(1).?.data, 623);
    testing.expectEqual(list.nth(2).?.data, 1);
}

test "basic nth() usage" {
    const Node = ScalarNode(usize);
    const List = LinkedList(Node);

    var gpa = GPA{};
    defer testing.expect(!gpa.deinit());

    var list = List.init(&gpa.allocator);
    defer list.deinit();

    try list.append(Node{ .data = 23 });
    try list.append(Node{ .data = 0 });
    try list.append(Node{ .data = 98 });
    try list.append(Node{ .data = 11 });
    try list.append(Node{ .data = 12 });
    try list.append(Node{ .data = 72 });

    testing.expectEqual(list.nth(0).?.data, 23);
    testing.expectEqual(list.nth(1).?.data, 0);
    testing.expectEqual(list.nth(2).?.data, 98);
    testing.expectEqual(list.nth(3).?.data, 11);
    testing.expectEqual(list.nth(4).?.data, 12);
    testing.expectEqual(list.nth(5).?.data, 72);
}

const std = @import("std");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

pub const Incoming = struct {
    input: Input.Input,
    receipt: ?[]const u8 = null,
};

pub const Delivery = struct {
    pub const Payload = union(enum) {
        input: Input.Input,
        assignment: Input.Assignment,
        report: Input.Report,
    };

    arena: std.heap.ArenaAllocator,
    input: Payload,
    receipt: ?[]const u8,
    supplied: bool = false,

    /// Payload and consumption state belong to the delivery arena.
    pub fn create(allocator: Allocator, input: Payload, receipt: ?[]const u8) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{
            .arena = .init(allocator),
            .input = undefined,
            .receipt = null,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const Data = struct { input: Payload, receipt: ?[]const u8 };
        const bytes = try std.json.Stringify.valueAlloc(allocator, Data{ .input = input, .receipt = receipt }, .{});
        defer allocator.free(bytes);
        const data = try std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always });
        self.input = data.input;
        self.receipt = data.receipt;
        return self;
    }

    pub fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

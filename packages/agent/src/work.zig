const std = @import("std");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

pub const Delivery = struct {
    arena: std.heap.ArenaAllocator,
    event: Input.Event,
    receipts: []const []const u8,

    /// Event and consumption state belong to the delivery arena.
    pub fn create(allocator: Allocator, event: Input.Event, receipts: []const []const u8) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{
            .arena = .init(allocator),
            .event = undefined,
            .receipts = &.{},
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const Data = struct { event: Input.Event, receipts: []const []const u8 };
        const bytes = try std.json.Stringify.valueAlloc(allocator, Data{ .event = event, .receipts = receipts }, .{});
        defer allocator.free(bytes);
        const data = try std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always });
        self.event = data.event;
        self.receipts = data.receipts;
        return self;
    }

    pub fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const Activation = struct {
    deliveries: std.ArrayList(*Delivery),

    /// Success takes ownership of the deliveries, copying only their pointers.
    pub fn create(allocator: Allocator, deliveries: []const *Delivery) !*Activation {
        const self = try allocator.create(Activation);
        errdefer allocator.destroy(self);
        self.* = .{ .deliveries = .empty };
        errdefer self.deliveries.deinit(allocator);
        try self.deliveries.appendSlice(allocator, deliveries);
        return self;
    }

    pub fn destroy(self: *Activation, allocator: Allocator) void {
        for (self.deliveries.items) |delivery| delivery.destroy(allocator);
        self.deliveries.deinit(allocator);
        allocator.destroy(self);
    }
};

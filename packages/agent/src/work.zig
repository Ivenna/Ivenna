const std = @import("std");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

pub const Delivery = struct {
    arena: std.heap.ArenaAllocator,
    event: Input.Event,
    receipt: ?[]const u8,
    /// Delivery routing remains internal; the event carries its semantic reference.
    callback_id: ?u64 = null,

    /// Copy the event and optional transport receipt into the delivery arena.
    pub fn create(allocator: Allocator, event: Input.Event, receipt: ?[]const u8) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{
            .arena = .init(allocator),
            .event = undefined,
            .receipt = null,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.event = try Input.cloneEvent(a, event);
        self.receipt = if (receipt) |value| try a.dupe(u8, value) else null;
        return self;
    }

    pub fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const Activation = struct {
    deliveries: std.ArrayList(*Delivery),
    admitted: bool = false,
    /// An observation requesting attention arrived after the last collection.
    new_arrival: bool = false,

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

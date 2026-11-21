const std = @import("std");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const Inbox = contracts.Inbox;

/// Exposes two transports behind one Inbox contract.
///
/// The primary keeps its exact budget and ordering. The secondary receives the
/// message budget left over and no callbacks, so enabling it can never reduce
/// what the primary already delivers. Secondary receipts are prefixed so that
/// acknowledgement can be routed back to the transport that issued them.
pub const Composite = struct {
    primary: Inbox,
    secondary: Inbox,

    pub const secondary_prefix = "spool:";

    pub fn inbox(self: *Composite) Inbox {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Inbox.VTable = .{ .poll = poll, .acknowledge = acknowledge };

    fn fromContext(context: *anyopaque) *Composite {
        return @ptrCast(@alignCast(context));
    }

    fn poll(context: *anyopaque, a: Allocator, request: Inbox.Poll) ![]const Inbox.Incoming {
        const self = fromContext(context);
        const primary: []const Inbox.Incoming = if (request.messages == 0 and request.callbacks == 0)
            &.{}
        else
            try self.primary.poll(a, request);
        const remaining = request.messages - @min(request.messages, primary.len);
        const secondary: []const Inbox.Incoming = if (remaining == 0)
            &.{}
        else
            try self.secondary.poll(a, .{ .messages = remaining, .callbacks = 0 });
        if (secondary.len == 0) return primary;
        const merged = try a.alloc(Inbox.Incoming, primary.len + secondary.len);
        @memcpy(merged[0..primary.len], primary);
        for (secondary, merged[primary.len..]) |item, *slot| {
            slot.* = .{
                .content = item.content,
                .receipt = if (item.receipt) |receipt|
                    try std.fmt.allocPrint(a, secondary_prefix ++ "{s}", .{receipt})
                else
                    null,
            };
        }
        return merged;
    }

    fn acknowledge(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        const self = fromContext(context);
        if (std.mem.startsWith(u8, receipt, secondary_prefix))
            return self.secondary.acknowledge(a, receipt[secondary_prefix.len..]);
        return self.primary.acknowledge(a, receipt);
    }
};

const Stub = struct {
    messages: []const []const u8,
    seen_budget: *usize,
    acknowledged: *std.ArrayList([]const u8),
    allocator: Allocator,

    fn inbox(self: *Stub) Inbox {
        return .{ .context = self, .vtable = &.{ .poll = poll, .acknowledge = acknowledge } };
    }

    fn fromContext(context: *anyopaque) *Stub {
        return @ptrCast(@alignCast(context));
    }

    fn poll(context: *anyopaque, a: Allocator, request: Inbox.Poll) ![]const Inbox.Incoming {
        const self = fromContext(context);
        self.seen_budget.* = request.messages;
        const count = @min(self.messages.len, request.messages);
        const out = try a.alloc(Inbox.Incoming, count);
        for (self.messages[0..count], out, 0..) |text, *slot, index| slot.* = .{
            .content = .{ .message = .{
                .from = &.{"stub"},
                .text = text,
                .observed_at_unix_ms = @intCast(index),
            } },
            .receipt = try std.fmt.allocPrint(a, "id-{s}", .{text}),
        };
        return out;
    }

    fn acknowledge(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        const self = fromContext(context);
        try self.acknowledged.append(self.allocator, try self.allocator.dupe(u8, receipt));
        _ = a;
    }
};

test "primary keeps its budget and secondary receives the remainder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var primary_budget: usize = 0;
    var secondary_budget: usize = 0;
    var primary_acked: std.ArrayList([]const u8) = .empty;
    var secondary_acked: std.ArrayList([]const u8) = .empty;
    var primary = Stub{ .messages = &.{ "m1", "m2" }, .seen_budget = &primary_budget, .acknowledged = &primary_acked, .allocator = a };
    var secondary = Stub{ .messages = &.{ "s1", "s2" }, .seen_budget = &secondary_budget, .acknowledged = &secondary_acked, .allocator = a };
    var composite: Composite = .{ .primary = primary.inbox(), .secondary = secondary.inbox() };

    const items = try composite.inbox().poll(a, .{ .messages = 3, .callbacks = 0 });
    try std.testing.expectEqual(@as(usize, 3), primary_budget);
    try std.testing.expectEqual(@as(usize, 1), secondary_budget);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("m2", items[1].content.message.text);
    try std.testing.expectEqualStrings("spool:id-s1", items[2].receipt.?);

    try composite.inbox().acknowledge(a, items[2].receipt.?);
    try composite.inbox().acknowledge(a, items[0].receipt.?);
    try std.testing.expectEqual(@as(usize, 1), secondary_acked.items.len);
    try std.testing.expectEqualStrings("id-s1", secondary_acked.items[0]);
    try std.testing.expectEqual(@as(usize, 1), primary_acked.items.len);
    try std.testing.expectEqualStrings("id-m1", primary_acked.items[0]);
}

test "no secondary budget when primary fills the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var primary_budget: usize = 0;
    var secondary_budget: usize = 99;
    var primary_acked: std.ArrayList([]const u8) = .empty;
    var secondary_acked: std.ArrayList([]const u8) = .empty;
    var primary = Stub{ .messages = &.{ "m1", "m2" }, .seen_budget = &primary_budget, .acknowledged = &primary_acked, .allocator = a };
    var secondary = Stub{ .messages = &.{"s1"}, .seen_budget = &secondary_budget, .acknowledged = &secondary_acked, .allocator = a };
    var composite: Composite = .{ .primary = primary.inbox(), .secondary = secondary.inbox() };

    const items = try composite.inbox().poll(a, .{ .messages = 2, .callbacks = 1 });
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(usize, 99), secondary_budget);
}

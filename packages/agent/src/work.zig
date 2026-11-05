const std = @import("std");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

pub const ReplyTarget = struct {
    receipt: []const u8,
    audience: []const []const u8,
};

/// The input producer controls source acknowledgement, withdrawal, and optional
/// routing or continuity independently of the destination of a model result.
pub const SourceControl = struct {
    receipt: []const u8,
    input_key: []const u8,
    route: ?[]const u8 = null,
    state_key: ?[]const u8 = null,
};

pub const Incoming = struct {
    input: Input.Input,
    reply: ?ReplyTarget = null,
    source_control: ?SourceControl = null,
    priority: bool = false,
};

pub const Delivery = struct {
    pub const Payload = union(enum) {
        input: Input.Input,
        assignment: Input.Assignment,
    };

    arena: std.heap.ArenaAllocator,
    input: Payload,
    reply: ?ReplyTarget,
    source_control: ?SourceControl,
    priority: bool,
    supplied: bool = false,
    completion: union(enum) {
        pending,
        ready: struct { text: ?[]const u8, submitted: bool = false },
    } = .pending,

    /// Payload, result destination, and source control are independently copied
    /// into the delivery arena and do not borrow producer-owned storage.
    pub fn create(allocator: Allocator, input: Payload, reply: ?ReplyTarget, source_control: ?SourceControl, priority: bool) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{
            .arena = .init(allocator),
            .input = undefined,
            .reply = null,
            .source_control = null,
            .priority = priority,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const Data = struct { input: Payload, reply: ?ReplyTarget, source_control: ?SourceControl };
        const bytes = try std.json.Stringify.valueAlloc(a, Data{ .input = input, .reply = reply, .source_control = source_control }, .{});
        const data = try std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always });
        self.input = data.input;
        self.reply = data.reply;
        self.source_control = data.source_control;
        return self;
    }

    pub fn fromIncoming(allocator: Allocator, incoming: Incoming) !*Delivery {
        return create(allocator, .{ .input = incoming.input }, incoming.reply, incoming.source_control, incoming.priority);
    }

    pub fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn recordResult(self: *Delivery, text: ?[]const u8) !void {
        self.completion = .{ .ready = .{ .text = if (text) |value| try self.arena.allocator().dupe(u8, value) else null } };
    }
};

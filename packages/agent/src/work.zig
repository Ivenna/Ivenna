const std = @import("std");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

pub const ReplyTarget = struct {
    receipt: []const u8,
    audience: []const []const u8,
};

/// Program-owned consumption and continuity bindings, independent of provenance
/// in model input and the destination of a model result.
pub const SourceState = struct {
    receipt: []const u8,
    input_key: []const u8,
    route: ?[]const u8 = null,
    state_key: ?[]const u8 = null,
};

pub const Incoming = struct {
    input: Input.Input,
    reply: ?ReplyTarget = null,
    source_state: ?SourceState = null,
};

pub const Delivery = struct {
    pub const Payload = union(enum) {
        input: Input.Input,
        assignment: Input.Assignment,
    };

    arena: std.heap.ArenaAllocator,
    input: Payload,
    reply: ?ReplyTarget,
    source_state: ?SourceState,
    supplied: bool = false,

    /// Payload, result destination, and source state are independently copied
    /// into the delivery arena and do not borrow producer-owned storage.
    pub fn create(allocator: Allocator, input: Payload, reply: ?ReplyTarget, source_state: ?SourceState) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{
            .arena = .init(allocator),
            .input = undefined,
            .reply = null,
            .source_state = null,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const Data = struct { input: Payload, reply: ?ReplyTarget, source_state: ?SourceState };
        const bytes = try std.json.Stringify.valueAlloc(a, Data{ .input = input, .reply = reply, .source_state = source_state }, .{});
        const data = try std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always });
        self.input = data.input;
        self.reply = data.reply;
        self.source_state = data.source_state;
        return self;
    }

    pub fn fromIncoming(allocator: Allocator, incoming: Incoming) !*Delivery {
        return create(allocator, .{ .input = incoming.input }, incoming.reply, incoming.source_state);
    }

    pub fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

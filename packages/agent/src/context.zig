const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Owned model history for a core or branch session. Inputs and complete
/// model/tool batches outlive request arenas. Registry synchronizes access;
/// Kernel checks the complete provider request budget before inference.
pub const Context = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    messages: []Value,
    batch_starts: []usize,

    pub fn init(allocator: Allocator, system_text: []const u8) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Value, 1);
        messages[0] = try message(a, "system", system_text);
        return .{
            .allocator = allocator,
            .arena = arena,
            .messages = messages,
            .batch_starts = &.{},
        };
    }

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Borrowed until the next mutation or deinit. Fork when the view must
    /// outlive synchronized access to this context.
    pub fn history(self: *const Context) []const Value {
        return self.messages;
    }

    /// Copies the last complete view; no request or in-flight tool state is
    /// part of Context. Subsequent changes to either branch are independent.
    pub fn fork(self: *const Context, allocator: Allocator) !Context {
        return self.copy(allocator, 0, 0);
    }

    pub fn appendInput(self: *Context, rendered_mail: []const u8) !void {
        var next = try self.copy(self.allocator, 1, 0);
        errdefer next.deinit();
        next.messages[self.messages.len] = try message(next.arena.allocator(), "user", rendered_mail);
        self.replace(next);
    }

    /// Commit the full model output and exactly one result for every tool call.
    /// All borrowed values are copied before the request arena can be released.
    /// On an allocation or validation failure the previous view is unchanged.
    pub fn appendBatch(self: *Context, output: []const Value, replies: []const Value) !void {
        try validateBatch(output, replies);
        if (output.len == 0) return;
        var next = try self.copy(self.allocator, output.len + replies.len, 1);
        errdefer next.deinit();
        const a = next.arena.allocator();
        const start = self.messages.len;
        for (output, 0..) |item, i| next.messages[start + i] = try cloneValue(a, item);
        for (replies, 0..) |item, i| next.messages[start + output.len + i] = try cloneValue(a, item);
        next.batch_starts[self.batch_starts.len] = start;
        self.replace(next);
    }

    /// Size of the serialized input view, without provider tools and envelope.
    /// The provider must account for those too when enforcing its input budget.
    pub fn serializedBytes(self: *const Context) !u64 {
        var buffer: [4096]u8 = undefined;
        var counter = std.Io.Writer.Discarding.init(&buffer);
        try std.json.Stringify.value(self.messages, .{}, &counter.writer);
        return counter.fullCount();
    }

    /// Prepare a bounded replacement candidate. The caller validates the full
    /// provider request, sends the handover mail, and only then installs it.
    /// The handover text contains its mail references and retained commitments;
    /// it is a user message, so remembered mail cannot become system authority.
    /// Keeping zero batches replaces the entire earlier working view. Keeping
    /// a tail preserves complete model outputs together with all their results.
    pub fn withHandover(self: *const Context, allocator: Allocator, rendered_handover_mail: []const u8, keep_recent_batches: usize) !Context {
        if (std.mem.trim(u8, rendered_handover_mail, " \t\r\n").len == 0) return error.EmptyHandover;
        const retained_count = @min(keep_recent_batches, self.batch_starts.len);
        const first_batch = self.batch_starts.len - retained_count;
        const tail_start = if (retained_count == 0) self.messages.len else self.batch_starts[first_batch];
        const tail = self.messages[tail_start..];
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Value, 2 + tail.len);
        messages[0] = try cloneValue(a, self.messages[0]);
        messages[1] = try message(a, "user", rendered_handover_mail);
        for (tail, 0..) |item, i| messages[2 + i] = try cloneValue(a, item);
        const batch_starts = try a.alloc(usize, retained_count);
        for (self.batch_starts[first_batch..], 0..) |start, i| batch_starts[i] = 2 + start - tail_start;
        return .{
            .allocator = allocator,
            .arena = arena,
            .messages = messages,
            .batch_starts = batch_starts,
        };
    }

    pub fn replaceWithHandover(self: *Context, rendered_handover_mail: []const u8, keep_recent_batches: usize) !void {
        self.replace(try self.withHandover(self.allocator, rendered_handover_mail, keep_recent_batches));
    }

    fn copy(self: *const Context, allocator: Allocator, extra_messages: usize, extra_batches: usize) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Value, self.messages.len + extra_messages);
        for (self.messages, 0..) |item, i| messages[i] = try cloneValue(a, item);
        const batch_starts = try a.alloc(usize, self.batch_starts.len + extra_batches);
        @memcpy(batch_starts[0..self.batch_starts.len], self.batch_starts);
        return .{
            .allocator = allocator,
            .arena = arena,
            .messages = messages,
            .batch_starts = batch_starts,
        };
    }

    fn replace(self: *Context, next: Context) void {
        self.arena.deinit();
        self.* = next;
    }
};

fn message(a: Allocator, role: []const u8, text: []const u8) !Value {
    var fields: std.json.ObjectMap = .empty;
    try fields.put(a, "role", .{ .string = role });
    try fields.put(a, "content", .{ .string = try a.dupe(u8, text) });
    return .{ .object = fields };
}

fn cloneValue(a: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .string => |text| .{ .string = try a.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try a.dupe(u8, text) },
        .array => |items| blk: {
            var copied: std.array_list.Managed(Value) = .init(a);
            try copied.ensureTotalCapacity(items.items.len);
            for (items.items) |item| copied.appendAssumeCapacity(try cloneValue(a, item));
            break :blk .{ .array = copied };
        },
        .object => |fields| blk: {
            var copied: std.json.ObjectMap = .empty;
            for (fields.keys(), fields.values()) |key, item|
                try copied.put(a, try a.dupe(u8, key), try cloneValue(a, item));
            break :blk .{ .object = copied };
        },
        else => value,
    };
}

fn validateBatch(output: []const Value, replies: []const Value) !void {
    var call_count: usize = 0;
    for (output, 0..) |item, index| {
        const kind = try textField(item, "type");
        if (std.mem.eql(u8, kind, "function_call_output")) return error.InvalidToolBatch;
        if (!std.mem.eql(u8, kind, "function_call")) continue;
        call_count += 1;
        const call_id = try textField(item, "call_id");
        for (output[0..index]) |previous| {
            if (std.mem.eql(u8, try textField(previous, "type"), "function_call") and
                std.mem.eql(u8, try textField(previous, "call_id"), call_id)) return error.InvalidToolBatch;
        }
        var matching: usize = 0;
        for (replies) |reply| {
            if (!std.mem.eql(u8, try textField(reply, "type"), "function_call_output")) return error.InvalidToolBatch;
            if (std.mem.eql(u8, try textField(reply, "call_id"), call_id)) matching += 1;
        }
        if (matching != 1) return error.InvalidToolBatch;
    }
    if (call_count != replies.len) return error.InvalidToolBatch;
}

fn textField(value: Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidToolBatch;
    const found = value.object.get(name) orelse return error.InvalidToolBatch;
    if (found != .string) return error.InvalidToolBatch;
    return found.string;
}

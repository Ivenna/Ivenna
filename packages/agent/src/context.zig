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
        return self.copy(allocator, 0);
    }

    pub fn appendInput(self: *Context, rendered_input: []const u8) !void {
        var next = try self.copy(self.allocator, 1);
        errdefer next.deinit();
        next.messages[self.messages.len] = try message(next.arena.allocator(), "user", rendered_input);
        self.replace(next);
    }

    /// Engine supplies the full model output and one result per tool call.
    /// Copy borrowed values before the request arena can be released.
    pub fn appendBatch(self: *Context, output: []const Value, replies: []const Value) !void {
        if (output.len == 0) return;
        var next = try self.copy(self.allocator, output.len + replies.len);
        errdefer next.deinit();
        const a = next.arena.allocator();
        const start = self.messages.len;
        for (output, 0..) |item, i| next.messages[start + i] = try cloneValue(a, item);
        for (replies, 0..) |item, i| next.messages[start + output.len + i] = try cloneValue(a, item);
        self.replace(next);
    }

    /// Prepare a bounded replacement candidate. The caller validates the full
    /// provider request and, when a state key exists, persists the handover
    /// before installing it. The handover is a user observation, keeping
    /// recalled material separate from system instructions.
    /// The handover replaces the entire earlier working view.
    pub fn withHandover(self: *const Context, allocator: Allocator, rendered_handover: []const u8) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Value, 2);
        messages[0] = try cloneValue(a, self.messages[0]);
        messages[1] = try message(a, "user", rendered_handover);
        return .{
            .allocator = allocator,
            .arena = arena,
            .messages = messages,
        };
    }

    fn copy(self: *const Context, allocator: Allocator, extra_messages: usize) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Value, self.messages.len + extra_messages);
        for (self.messages, 0..) |item, i| messages[i] = try cloneValue(a, item);
        return .{
            .allocator = allocator,
            .arena = arena,
            .messages = messages,
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

const std = @import("std");
const Input = @import("input.zig");
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
        messages[0] = try message(a, "system", try a.dupe(u8, system_text));
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

    pub fn appendRecord(self: *Context, record: Input.Record) !void {
        var next = try self.copy(self.allocator, 1);
        errdefer next.deinit();
        const a = next.arena.allocator();
        next.messages[self.messages.len] = try message(a, "user", try Input.renderRecord(a, record));
        self.replace(next);
    }

    /// History is borrowed until mutation or deinit; the temporary user message
    /// and the returned slice belong to a. No request state enters history.
    pub fn request(self: *const Context, a: Allocator, current: Input.Request) ![]const Value {
        const messages = try a.alloc(Value, self.messages.len + 1);
        @memcpy(messages[0..self.messages.len], self.messages);
        messages[self.messages.len] = try message(a, "user", try Input.renderRequest(a, current));
        return messages;
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

    /// Replace the entire earlier working view with system instructions and a
    /// handover record. The caller validates the complete request budget and
    /// owns the handover's storage policy.
    pub fn withHandover(self: *const Context, allocator: Allocator, session_id: u64, handover: Input.Handover) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Value, 2);
        messages[0] = try cloneValue(a, self.messages[0]);
        messages[1] = try message(a, "user", try Input.renderRecord(a, .{
            .session_id = session_id,
            .context = &.{.{ .handover = handover }},
        }));
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
    try fields.put(a, "content", .{ .string = text });
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

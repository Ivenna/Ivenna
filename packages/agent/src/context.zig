const std = @import("std");
const Input = @import("input.zig");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// Owned model history for a core or branch session. Inputs and complete
/// model/tool batches outlive request arenas. Registry synchronizes access;
/// Kernel checks the complete provider request budget before inference.
pub const Context = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    messages: []Model.Item,

    pub fn init(allocator: Allocator, system_text: []const u8) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Model.Item, 1);
        messages[0] = .{ .message = .{ .role = .system, .text = try a.dupe(u8, system_text) } };
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
    pub fn history(self: *const Context) []const Model.Item {
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
        next.messages[self.messages.len] = .{ .message = .{ .role = .user, .text = try Input.renderRecord(a, record) } };
        self.replace(next);
    }

    /// History is borrowed until mutation or deinit; the temporary user message
    /// and the returned slice belong to a. No request state enters history.
    pub fn request(self: *const Context, a: Allocator, current: Input.Request) ![]const Model.Item {
        const messages = try a.alloc(Model.Item, self.messages.len + 1);
        @memcpy(messages[0..self.messages.len], self.messages);
        messages[self.messages.len] = .{ .message = .{ .role = .user, .text = try Input.renderRequest(a, current) } };
        return messages;
    }

    /// Engine supplies the full model output and one result per tool call.
    /// Copy borrowed values before the request arena can be released.
    pub fn appendBatch(self: *Context, output: []const Model.Item, replies: []const Model.Item) !void {
        if (output.len == 0) return;
        var next = try self.copy(self.allocator, output.len + replies.len);
        errdefer next.deinit();
        const a = next.arena.allocator();
        const start = self.messages.len;
        for (output, 0..) |item, i| next.messages[start + i] = try cloneItem(a, item);
        for (replies, 0..) |item, i| next.messages[start + output.len + i] = try cloneItem(a, item);
        self.replace(next);
    }

    /// Replace the entire earlier working view with system instructions and a
    /// handover record. The caller validates the complete request budget and
    /// owns the handover's storage policy.
    pub fn withHandover(self: *const Context, allocator: Allocator, session_id: u64, handover: contracts.Handover) !Context {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const messages = try a.alloc(Model.Item, 2);
        messages[0] = try cloneItem(a, self.messages[0]);
        messages[1] = .{ .message = .{ .role = .user, .text = try Input.renderRecord(a, .{
            .session_id = session_id,
            .context = &.{.{ .handover = handover }},
        }) } };
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
        const messages = try a.alloc(Model.Item, self.messages.len + extra_messages);
        for (self.messages, 0..) |item, i| messages[i] = try cloneItem(a, item);
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

fn cloneItem(a: Allocator, item: Model.Item) Allocator.Error!Model.Item {
    return switch (item) {
        .message => |message| .{ .message = .{ .role = message.role, .text = try a.dupe(u8, message.text) } },
        .continuation => |bytes| .{ .continuation = try a.dupe(u8, bytes) },
        .tool_result => |result| blk: {
            const parts = try a.alloc(Content.Part, result.content.parts.len);
            for (result.content.parts, parts) |part, *copy| copy.* = switch (part) {
                .text => |text| .{ .text = try a.dupe(u8, text) },
                .image => |image| .{ .image = switch (image) {
                    .url => |url| .{ .url = try a.dupe(u8, url) },
                    .data => |data| .{ .data = .{ .format = data.format, .bytes = try a.dupe(u8, data.bytes) } },
                } },
            };
            break :blk .{ .tool_result = .{ .call_id = try a.dupe(u8, result.call_id), .content = .{ .parts = parts } } };
        },
    };
}

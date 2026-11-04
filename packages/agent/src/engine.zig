const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Memory = @import("memory.zig").Memory;
const Host = @import("host.zig").Host;
const Content = @import("content.zig").Content;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One model request and its complete tool batch. Kernel owns attention,
/// context lifetime, correspondence routing, and when another round starts.
pub const Engine = struct {
    io: std.Io,
    provider: Provider,
    memory: Memory,
    host: Host,

    pub const Round = struct {
        output: []const Value,
        replies: []const Value,
        text: ?[]const u8,
    };

    /// Returned data belongs to a, including model output and tool replies.
    pub fn turn(self: *Engine, a: Allocator, session_id: u64, history: []const Value) !Round {
        try self.io.checkCancel();
        const response = try self.provider.next(a, history);
        var messages: std.ArrayList(Value) = .empty;
        try messages.appendSlice(a, history);
        try messages.appendSlice(a, response.output);
        const reply_start = messages.items.len;
        for (response.calls) |call| {
            const content = self.invoke(a, session_id, call.name, call.arguments) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                error.InvalidToolArguments, error.UnknownTool => Content{
                    .text = try std.json.Stringify.valueAlloc(a, .{
                        .@"error" = .{
                            .code = if (err == error.UnknownTool) "unknown_tool" else "invalid_arguments",
                            .message = if (err == error.UnknownTool) "This tool is not available." else "The arguments do not match the tool parameters.",
                        },
                    }, .{}),
                },
                else => return err,
            };
            try messages.append(a, try self.provider.toolReply(a, call.call_id, content, messages.items));
        }
        try self.provider.limitToolReplies(a, messages.items, reply_start);
        return .{
            .output = response.output,
            .replies = messages.items[reply_start..],
            .text = try responseText(a, response.output),
        };
    }

    fn invoke(self: *Engine, a: Allocator, session_id: u64, name: []const u8, arguments: []const u8) !Content {
        if (try Memory.Request.parse(a, name, arguments)) |request|
            return self.memory.invoke(a, request);
        if (try Host.Request.parse(a, name, arguments)) |request|
            return self.host.invoke(a, .{ .session_id = session_id }, request);
        return error.UnknownTool;
    }
};

pub fn responseText(a: Allocator, output: []const Value) !?[]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (output) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "message")) continue;
        const parts = item.object.get("content") orelse continue;
        if (parts != .array) continue;
        for (parts.array.items) |part| {
            if (part != .object) continue;
            const part_type = part.object.get("type") orelse continue;
            if (part_type != .string or !std.mem.eql(u8, part_type.string, "output_text")) continue;
            const value = part.object.get("text") orelse continue;
            if (value != .string or value.string.len == 0) continue;
            if (text.written().len != 0) try text.writer.writeAll("\n\n");
            try text.writer.writeAll(value.string);
        }
    }
    return if (text.written().len == 0) null else try text.toOwnedSlice();
}

const std = @import("std");
const storage = @import("store.zig");
const input = @import("input.zig");
pub const Store = storage.Store;
pub const Session = storage.Session;
pub const Provider = @import("provider.zig").Provider;
pub const Memory = @import("memory.zig").Memory;
pub const Host = @import("host.zig").Host;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Engine = struct {
    allocator: Allocator,
    io: std.Io,
    store: *Store,
    memory: Memory,
    host: Host,
    provider: Provider,

    pub fn createSession(self: *Engine, a: Allocator, user_fields: Value) !i64 {
        const messages = [_]struct { role: []const u8, content: []const u8 }{
            .{ .role = "system", .content = "Je pense, donc je suis." },
        };
        return self.store.createSession(
            try std.json.Stringify.valueAlloc(a, user_fields, .{}),
            try std.json.Stringify.valueAlloc(a, messages, .{}),
        );
    }

    pub fn submitInput(self: *Engine, a: Allocator, id: i64, fields: Value) !void {
        const user_fields = try std.json.parseFromSliceLeaky(Value, a, try self.store.userFields(a, id), .{});
        const message = .{ .role = "user", .content = try input.serialize(a, id, user_fields, fields) };
        try self.store.submitInput(id, try std.json.Stringify.valueAlloc(a, message, .{}));
    }

    /// The service owns this task; an HTTP connection only submits durable input.
    pub fn execute(self: *Engine, id: i64) !void {
        try self.store.claimSession(id);
        self.loop(id) catch |err| {
            // Cancellation leaves the last saved checkpoint for startup recovery.
            if (err == error.Canceled) return err;
            self.store.failSession(id, @errorName(err)) catch |persist_err| {
                if (persist_err == error.Canceled) return persist_err;
                std.log.err("could not persist failure for session {d}: {s}", .{ id, @errorName(persist_err) });
            };
            return err;
        };
    }

    fn loop(self: *Engine, id: i64) !void {
        while (true) {
            try self.io.checkCancel();
            // A long-lived session must not retain copies of every earlier
            // request and checkpoint. Each round owns only its current history.
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const messages_json = try self.store.history(a, id);
            const history = try std.json.parseFromSliceLeaky([]Value, a, messages_json, .{});
            var messages = std.array_list.Managed(Value).fromOwnedSlice(a, history);
            const response = try self.provider.next(a, messages.items);
            // Replay complete output, including reasoning items, in the next
            // model request so the tool loop retains its context.
            try messages.appendSlice(response.output);
            var pause_requested = response.calls.len == 0;
            for (response.calls) |call| {
                const outcome = self.invoke(a, id, call.name, call.arguments) catch |err| switch (err) {
                    error.InvalidToolArguments, error.UnknownTool => Outcome{
                        .reply = try std.json.Stringify.valueAlloc(a, .{
                            .@"error" = .{
                                .code = if (err == error.InvalidToolArguments) "invalid_arguments" else "unknown_tool",
                                .message = if (err == error.InvalidToolArguments)
                                    "The arguments do not match this tool's parameters. Check the required fields and allowed values."
                                else
                                    "This tool is not available. Choose one of the provided tools.",
                            },
                        }, .{}),
                    },
                    else => return err,
                };
                const content = switch (outcome) {
                    .reply => |content| content,
                    .wait_for_input => blk: {
                        pause_requested = true;
                        break :blk "{\"result\":\"waiting_for_input\"}";
                    },
                };
                var reply: std.json.ObjectMap = .empty;
                try reply.put(a, "type", .{ .string = "function_call_output" });
                try reply.put(a, "call_id", .{ .string = call.call_id });
                try reply.put(a, "output", .{ .string = content });
                try messages.append(.{ .object = reply });
            }
            // Persist model output together with its tool replies. A crash
            // before this checkpoint can cause tool effects to be repeated.
            const next_checkpoint = try std.json.Stringify.valueAlloc(a, messages.items, .{});
            if (try self.store.checkpoint(id, next_checkpoint, pause_requested)) return;
        }
    }

    const Outcome = union(enum) { reply: []const u8, wait_for_input };

    fn invoke(self: *Engine, a: Allocator, session_id: i64, name: []const u8, arguments: []const u8) !Outcome {
        if (try Memory.Request.parse(a, name, arguments)) |request| {
            return .{ .reply = try self.memory.invoke(a, request) };
        }
        if (try Host.Request.parse(a, name, arguments)) |request| {
            return .{ .reply = try self.host.invoke(a, .{ .session_id = session_id }, request) };
        }
        if (std.mem.eql(u8, name, "wait_for_input")) {
            _ = try parseArgs(struct {}, a, arguments);
            return .wait_for_input;
        }
        return error.UnknownTool;
    }
};

fn parseArgs(comptime T: type, a: Allocator, text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidToolArguments,
    };
}

const std = @import("std");
const model = @import("provider.zig");
const storage = @import("store.zig");
const input = @import("input.zig");
pub const Store = storage.Store;
pub const Session = storage.Session;
pub const Provider = model.Provider;
pub const Memory = @import("memory.zig").Memory;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Engine = struct {
    allocator: Allocator,
    io: std.Io,
    store: *Store,
    memory: Memory,
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
            // Cancellation must stay cancellable, including when PostgreSQL is
            // unavailable. Startup recovery resumes unfinished sessions.
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
            const session = try self.store.getSession(a, id) orelse return error.SessionNotFound;
            const history = try std.json.parseFromSliceLeaky([]Value, a, session.messages_json, .{});
            var messages = std.array_list.Managed(Value).fromOwnedSlice(a, history);
            const output = try self.provider.next(a, messages.items);
            // Replay complete output, including reasoning items, in the next
            // model request so the tool loop retains its context.
            try messages.appendSlice(output);
            var action: RoundAction = .no_tools;
            for (output) |item| {
                if (!std.mem.eql(u8, try model.textField(item, "type"), "function_call")) continue;
                if (action == .no_tools) action = .continue_session;
                const name = try model.textField(item, "name");
                const args = try model.textField(item, "arguments");
                const outcome = self.invoke(a, name, args) catch |err| switch (err) {
                    error.InvalidToolArguments, error.UnknownTool => Outcome{
                        .reply = try std.json.Stringify.valueAlloc(a, Memory.Reply{
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
                        action = .wait_requested;
                        break :blk "{\"result\":\"waiting_for_input\"}";
                    },
                };
                var reply: std.json.ObjectMap = .empty;
                try reply.put(a, "type", .{ .string = "function_call_output" });
                try reply.put(a, "call_id", .{ .string = try model.textField(item, "call_id") });
                try reply.put(a, "output", .{ .string = content });
                try messages.append(.{ .object = reply });
            }
            // Persist model output together with its tool replies. A crash
            // before this checkpoint can cause tool effects to be repeated.
            const next_checkpoint = try std.json.Stringify.valueAlloc(a, messages.items, .{});
            if (try self.store.checkpoint(id, next_checkpoint, action != .continue_session)) return;
        }
    }

    const RoundAction = enum { no_tools, continue_session, wait_requested };
    const Outcome = union(enum) { reply: []const u8, wait_for_input };

    fn invoke(self: *Engine, a: Allocator, name: []const u8, arguments: []const u8) !Outcome {
        if (try Memory.Request.parse(a, name, arguments)) |request| {
            return .{ .reply = try self.memory.invoke(a, request) };
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

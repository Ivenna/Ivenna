//! Encode and decode the checkpoint that selects each session's history.

const std = @import("std");
const Input = @import("../input.zig");
const Stream = @import("../work.zig").Stream;
const Reports = @import("../reports.zig");
const Codec = @import("../record_codec.zig");
const Key = @import("agent_contracts").HistoryStore.Key;
const Allocator = std.mem.Allocator;

pub const Checkpoint = struct {
    subscription_catalog: [32]u8,
    usage_scope: ?[32]u8 = null,
    next_session_id: u64,
    next_callback_id: u64,
    next_runtime_reference_id: u64,
    sessions: []const Session,
    callbacks: []const CallbackRegistration,
    channels: []const Channel = &.{},
    activity_reports: ?Reports.Checkpoint,

    pub const CallbackRegistration = struct {
        id: u64,
        reference: []const u8,
        session_id: u64,
        command_id: []const u8,
    };

    pub const Progress = struct {
        /// Input token count from the last committed ordinary round in this
        /// epoch, including a round with tool calls. A missing count clears it.
        last_input_tokens: ?u64 = null,
        /// Starting stream for the next admission batch, after any startup observation.
        first_stream: Stream = .ordinary,
    };

    pub const Channel = struct {
        id: []const u8,
        opened_by: []const u8,
        opened_at_unix_ms: i64,
        description: ?[]const u8 = null,
    };

    pub const Session = struct {
        session_id: u64,
        focus_id: []const u8,
        role: Input.Role,
        was_running: bool,
        subscription_through: u64,
        epoch: u64,
        progress: Progress = .{},
        group: []const u8,
        head: ?Key,
        count: usize,
        observations: ?Key,
    };

    pub fn decode(a: Allocator, document: []const u8) !Checkpoint {
        const stored = try Codec.decode(Stored, a, document);
        var callbacks: std.ArrayList(CallbackRegistration) = .empty;
        errdefer callbacks.deinit(a);
        for (stored.callbacks) |callback| switch (callback.source) {
            // A previously published wakeup can still arrive. Keep the
            // next-ID counter so inbox intake recognizes it as consumed.
            .wakeup => {},
            .host => |host| try callbacks.append(a, .{
                .id = callback.id,
                .reference = callback.reference,
                .session_id = callback.session_id,
                .command_id = host.command_id,
            }),
        };
        return .{
            .subscription_catalog = stored.subscription_catalog,
            .usage_scope = stored.usage_scope,
            .next_session_id = stored.next_session_id,
            .next_callback_id = stored.next_callback_id,
            .next_runtime_reference_id = stored.next_command_id,
            .sessions = stored.sessions,
            .callbacks = callbacks.items,
            .channels = stored.channels,
            .activity_reports = stored.activity_reports,
        };
    }

    pub fn encode(self: Checkpoint, a: Allocator) ![]const u8 {
        const callbacks = try a.alloc(Stored.Callback, self.callbacks.len);
        defer a.free(callbacks);
        for (self.callbacks, callbacks) |callback, *stored| stored.* = .{
            .id = callback.id,
            .reference = callback.reference,
            .session_id = callback.session_id,
            .source = .{ .host = .{ .command_id = callback.command_id } },
        };
        return Codec.encode(a, Stored{
            .subscription_catalog = self.subscription_catalog,
            .usage_scope = self.usage_scope,
            .next_session_id = self.next_session_id,
            .next_callback_id = self.next_callback_id,
            .next_command_id = self.next_runtime_reference_id,
            .sessions = self.sessions,
            .callbacks = callbacks,
            .channels = self.channels,
            .activity_reports = self.activity_reports,
        });
    }

    const Stored = struct {
        subscription_catalog: [32]u8,
        usage_scope: ?[32]u8 = null,
        next_session_id: u64,
        next_callback_id: u64,
        // Retain the field name used by saved checkpoints.
        next_command_id: u64,
        sessions: []const Session,
        wakeups: ?[]const struct { id: u64, at_unix_ms: i64, text: ?[]const u8 } = null,
        callbacks: []const Callback,
        channels: []const Channel = &.{},
        activity_reports: ?Reports.Checkpoint,

        const Callback = struct {
            id: u64,
            reference: []const u8,
            session_id: u64,
            source: Input.CallbackSource,
        };
    };
};

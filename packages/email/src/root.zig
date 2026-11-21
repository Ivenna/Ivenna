const std = @import("std");
const contracts = @import("agent_contracts");
const Jmap = @import("jmap.zig").Jmap;
const Mailbox = @import("mail.zig").Mailbox;
const Addressing = @import("addressing.zig").Addressing;
const EmailTransport = @import("email_transport.zig").EmailTransport;
const History = @import("history.zig").History;
const Allocator = std.mem.Allocator;

test {
    _ = @import("addressing.zig");
    _ = @import("email_transport.zig");
    _ = @import("history.zig");
    _ = @import("mail.zig");
    _ = @import("jmap.zig");
}

pub const Config = struct {
    session_url: []const u8,
    authorization: []const u8,
    address: []const u8,
};

/// Own correspondence and persistent history behind the runtime's contracts.
/// Native mail records remain private to the integration.
pub const Integration = struct {
    discovery: std.heap.ArenaAllocator,
    jmap: Jmap,
    mailbox: Mailbox,
    transport: EmailTransport,
    history_adapter: History,
    correspondence_mutex: std.Io.Mutex,

    /// Initialize in the final storage location: components borrow each other.
    /// The configuration strings must outlive self.
    pub fn init(self: *Integration, allocator: Allocator, io: std.Io, config: Config) !void {
        self.discovery = .init(allocator);
        errdefer self.discovery.deinit();
        self.correspondence_mutex = .init;
        self.jmap = .init(allocator, io, config.authorization);
        errdefer self.jmap.deinit();
        self.mailbox = .{
            .jmap = &self.jmap,
            .session_url = config.session_url,
            .address = config.address,
            .addressing = try Addressing.init(config.address),
        };
        try self.mailbox.discover(self.discovery.allocator());
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try self.mailbox.maintainCorrespondence(arena.allocator());
        self.transport = EmailTransport.init(&self.mailbox);
        self.history_adapter = History.init(allocator, &self.mailbox);
    }

    pub fn deinit(self: *Integration) void {
        self.history_adapter.deinit();
        self.jmap.deinit();
        self.discovery.deinit();
        self.* = undefined;
    }

    pub fn inbox(self: *Integration) contracts.Inbox {
        return .{ .context = self, .vtable = &inbox_vtable };
    }

    pub fn sender(self: *Integration) contracts.Communication.Sender {
        return .{ .context = self, .submit = submit };
    }

    pub fn callbackPublisher(self: *Integration) contracts.Callback.Publisher {
        return .{ .context = self, .publish = publishCallback };
    }

    pub fn history(self: *Integration) contracts.HistoryStore {
        return self.history_adapter.port();
    }

    const inbox_vtable: contracts.Inbox.VTable = .{
        .poll = poll,
        .acknowledge = acknowledge,
    };

    fn fromContext(context: *anyopaque) *Integration {
        return @ptrCast(@alignCast(context));
    }

    fn poll(context: *anyopaque, a: Allocator, request: contracts.Inbox.Poll) ![]const contracts.Inbox.Incoming {
        const self = fromContext(context);
        try self.correspondence_mutex.lock(self.jmap.io());
        defer self.correspondence_mutex.unlock(self.jmap.io());
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try self.mailbox.maintainCorrespondence(arena.allocator());
        const pending = try self.mailbox.pending(a, request);
        const incoming = try a.alloc(contracts.Inbox.Incoming, pending.len);
        for (pending, incoming) |candidate, *item| item.* = .{
            .content = switch (candidate.content) {
                .message => |letter| .{ .message = try self.transport.receive(a, letter) },
                .callback => |callback| .{ .callback = .{
                    .id = callback.id,
                    .text = callback.text,
                    .observed_at_unix_ms = std.Io.Clock.real.now(self.jmap.io()).toMilliseconds(),
                } },
            },
            .receipt = candidate.id,
        };
        return incoming;
    }

    fn acknowledge(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        const self = fromContext(context);
        try self.correspondence_mutex.lock(self.jmap.io());
        defer self.correspondence_mutex.unlock(self.jmap.io());
        return self.mailbox.acknowledge(a, receipt);
    }

    fn submit(context: *anyopaque, a: Allocator, message: contracts.Communication.Message) !contracts.Communication.SendResult {
        const self = fromContext(context);
        try self.correspondence_mutex.lock(self.jmap.io());
        defer self.correspondence_mutex.unlock(self.jmap.io());
        return self.transport.send(a, message);
    }

    fn publishCallback(context: *anyopaque, a: Allocator, message: contracts.Callback.Message) !void {
        const self = fromContext(context);
        try self.correspondence_mutex.lock(self.jmap.io());
        defer self.correspondence_mutex.unlock(self.jmap.io());
        try self.mailbox.publishCallback(a, message);
    }
};

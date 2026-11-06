const std = @import("std");
const contracts = @import("agent_contracts");
const Mailbox = @import("mail.zig").Mailbox;
const Addressing = @import("addressing.zig").Addressing;
const EmailTransport = @import("email_transport.zig").EmailTransport;
const History = @import("history.zig").History;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    session_url: []const u8,
    authorization: []const u8,
    address: []const u8,
};

/// Own correspondence and persistent history behind the runtime's contracts.
/// Native mail records remain private to the integration.
pub const Integration = struct {
    discovery: std.heap.ArenaAllocator,
    mailbox: Mailbox,
    transport: EmailTransport,
    history_adapter: History,

    /// Initialize in the final storage location: components borrow each other.
    /// The client and configuration strings must outlive self.
    pub fn init(self: *Integration, allocator: Allocator, client: *std.http.Client, config: Config) !void {
        self.discovery = .init(allocator);
        errdefer self.discovery.deinit();
        self.mailbox = .{
            .client = client,
            .session_url = config.session_url,
            .authorization = config.authorization,
            .address = config.address,
            .addressing = try Addressing.init(config.address),
        };
        try self.mailbox.discover(self.discovery.allocator());
        self.transport = EmailTransport.init(&self.mailbox);
        self.history_adapter = History.init(allocator, &self.mailbox);
    }

    pub fn deinit(self: *Integration) void {
        self.history_adapter.deinit();
        self.discovery.deinit();
        self.* = undefined;
    }

    pub fn inbox(self: *Integration) contracts.Inbox {
        return .{ .context = self, .vtable = &inbox_vtable };
    }

    pub fn sender(self: *Integration) contracts.Communication.Sender {
        return .{ .context = self, .submit = submit };
    }

    pub fn history(self: *Integration) contracts.HistoryStore {
        return self.history_adapter.port();
    }

    const inbox_vtable: contracts.Inbox.VTable = .{
        .poll = poll,
        .complete = complete,
    };

    fn fromContext(context: *anyopaque) *Integration {
        return @ptrCast(@alignCast(context));
    }

    fn poll(context: *anyopaque, a: Allocator, limit: usize) ![]const contracts.Inbox.Incoming {
        const self = fromContext(context);
        const pending = try self.mailbox.pending(a, limit);
        const incoming = try a.alloc(contracts.Inbox.Incoming, pending.len);
        for (pending, incoming) |candidate, *item| item.* = .{
            .input = try self.transport.receive(a, candidate),
            .receipt = candidate.id,
        };
        return incoming;
    }

    fn complete(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        return fromContext(context).mailbox.markHandled(a, receipt);
    }

    fn submit(context: *anyopaque, a: Allocator, message: contracts.Communication.Message) !contracts.Communication.Submission {
        return fromContext(context).transport.send(a, message);
    }
};

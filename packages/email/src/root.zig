const std = @import("std");
const contracts = @import("agent_contracts");
const Mailbox = @import("mail.zig").Mailbox;
const Addressing = @import("addressing.zig").Addressing;
const EmailTransport = @import("email_transport.zig").EmailTransport;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    session_url: []const u8,
    authorization: []const u8,
    address: []const u8,
};

/// Own the mail integration behind the runtime's observation, submission, and
/// handover contracts. Native mail records remain private to the integration.
pub const Integration = struct {
    discovery: std.heap.ArenaAllocator,
    mailbox: Mailbox,
    transport: EmailTransport,

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
    }

    pub fn deinit(self: *Integration) void {
        self.discovery.deinit();
        self.* = undefined;
    }

    pub fn inbox(self: *Integration) contracts.Inbox {
        return .{ .context = self, .vtable = &inbox_vtable };
    }

    pub fn sender(self: *Integration) contracts.Communication.Sender {
        return .{ .context = self, .submit = submit };
    }

    pub fn handovers(self: *Integration) contracts.HandoverStore {
        return .{ .context = self, .vtable = &handover_vtable };
    }

    const inbox_vtable: contracts.Inbox.VTable = .{
        .poll = poll,
        .recent = recent,
        .complete = complete,
    };

    const handover_vtable: contracts.HandoverStore.VTable = .{
        .load = loadHandover,
        .save = saveHandover,
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

    fn recent(context: *anyopaque, a: Allocator, limit: usize) ![]const contracts.Communication.HistoryItem {
        return fromContext(context).transport.recent(a, limit);
    }

    fn complete(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        return fromContext(context).mailbox.markHandled(a, receipt);
    }

    fn submit(context: *anyopaque, a: Allocator, message: contracts.Communication.Message) !contracts.Communication.Submission {
        return fromContext(context).transport.send(a, message);
    }

    fn loadHandover(context: *anyopaque, a: Allocator, key: []const u8) !?contracts.Handover {
        const letter = try fromContext(context).mailbox.latestState(a, key) orelse return null;
        return .{ .summary = letter.body };
    }

    fn saveHandover(context: *anyopaque, a: Allocator, key: []const u8, summary: []const u8) !void {
        return fromContext(context).mailbox.saveState(a, key, summary);
    }
};

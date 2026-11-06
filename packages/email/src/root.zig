const std = @import("std");
const agent = @import("agent");
const Mailbox = @import("mail.zig").Mailbox;
const MailSources = @import("mail_sources.zig").MailSources;
const EmailTransport = @import("email_transport.zig").EmailTransport;
const MailState = @import("mail_state.zig").MailState;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    session_url: []const u8,
    authorization: []const u8,
    address: []const u8,
};

/// Own the mail integration behind the runtime's observation, submission, and
/// handover contracts. Native mail records and receipt caches remain private.
pub const Integration = struct {
    discovery: std.heap.ArenaAllocator,
    mailbox: Mailbox,
    sources: MailSources,
    transport: EmailTransport,
    state: MailState,

    /// Initialize in the final storage location: components borrow each other.
    /// The client, configuration strings, and data directory must outlive self.
    pub fn init(self: *Integration, allocator: Allocator, io: std.Io, client: *std.http.Client, config: Config, data_directory: []const u8) !void {
        self.discovery = .init(allocator);
        errdefer self.discovery.deinit();
        self.mailbox = .{
            .client = client,
            .session_url = config.session_url,
            .authorization = config.authorization,
            .address = config.address,
        };
        try self.mailbox.discover(self.discovery.allocator());
        self.sources = MailSources.init(allocator, io, &self.mailbox, data_directory);
        self.transport = EmailTransport.init(io, &self.mailbox, &self.sources);
        self.state = MailState.init(&self.mailbox, &self.sources);
    }

    pub fn deinit(self: *Integration) void {
        self.sources.deinit();
        self.discovery.deinit();
        self.* = undefined;
    }

    pub fn inbox(self: *Integration) agent.Inbox {
        return .{ .context = self, .vtable = &inbox_vtable };
    }

    pub fn sender(self: *Integration) agent.Communication.Sender {
        return .{ .context = self, .submit = submit };
    }

    pub fn handovers(self: *Integration) agent.HandoverStore {
        return .{ .context = self, .vtable = &handover_vtable };
    }

    const inbox_vtable: agent.Inbox.VTable = .{
        .poll = poll,
        .recent = recent,
        .complete = complete,
        .releaseUnused = releaseUnused,
    };

    const handover_vtable: agent.HandoverStore.VTable = .{
        .load = loadHandover,
        .save = saveHandover,
    };

    fn fromContext(context: *anyopaque) *Integration {
        return @ptrCast(@alignCast(context));
    }

    fn poll(context: *anyopaque, a: Allocator, limit: usize, excerpt_bytes: usize) ![]const agent.Inbox.Incoming {
        const self = fromContext(context);
        const pending = try self.state.pending(a, limit);
        const incoming = try a.alloc(agent.Inbox.Incoming, pending.len);
        for (pending, incoming) |candidate, *item| item.* = .{
            .input = try self.transport.receive(a, candidate.receipt, excerpt_bytes),
            .receipt = candidate.receipt,
        };
        return incoming;
    }

    fn recent(context: *anyopaque, a: Allocator, limit: usize) ![]const agent.Input.Material {
        return fromContext(context).transport.recent(a, limit);
    }

    fn complete(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        return fromContext(context).state.complete(a, receipt);
    }

    fn releaseUnused(context: *anyopaque, retained: []const []const u8) !void {
        return fromContext(context).sources.sweep(retained);
    }

    fn submit(context: *anyopaque, a: Allocator, message: agent.Communication.Message) !agent.Communication.Submission {
        return fromContext(context).transport.send(a, message);
    }

    fn loadHandover(context: *anyopaque, a: Allocator, key: []const u8, limit: usize) !?agent.Input.Handover {
        return fromContext(context).state.loadHandover(a, key, limit);
    }

    fn saveHandover(context: *anyopaque, a: Allocator, key: []const u8, summary: []const u8) !void {
        return fromContext(context).state.saveHandover(a, key, summary);
    }
};

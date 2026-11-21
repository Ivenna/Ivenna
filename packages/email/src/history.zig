const std = @import("std");
const contracts = @import("agent_contracts");
const Mailbox = @import("mail.zig").Mailbox;
const StateRecord = @import("mail.zig").StateRecord;
const Allocator = std.mem.Allocator;

/// Store grouped immutable records and publish the retained-session checkpoint.
/// The agent owns record encodings and identity; native locators stay in memory.
pub const History = struct {
    allocator: Allocator,
    mailbox: *Mailbox,
    revision: u64 = 0,
    loaded: bool = false,

    pub fn init(allocator: Allocator, mailbox: *Mailbox) History {
        return .{ .allocator = allocator, .mailbox = mailbox };
    }

    pub fn deinit(self: *History) void {
        self.* = undefined;
    }

    pub fn port(self: *History) contracts.HistoryStore {
        return .{ .context = self, .vtable = &.{ .load = load, .allocateGroup = allocateGroup, .query = query, .read = read, .create = create, .save = save, .maintain = maintain } };
    }

    fn load(context: *anyopaque, a: Allocator) !?[]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        self.loaded = false;
        const records = try self.mailbox.historyHeads(a);
        var latest: ?StateRecord = null;
        for (records) |record| {
            if (latest == null or record.revision > latest.?.revision) {
                latest = record;
            }
        }
        if (latest) |selected| for (records) |record| {
            if (record.revision == selected.revision and !std.mem.eql(u8, record.id, selected.id))
                return error.AmbiguousHistoryRevision;
        };
        const data = if (latest) |record| try self.mailbox.historyCheckpoint(a, record.id) else null;
        self.revision = if (latest) |record| record.revision else 0;
        self.loaded = true;
        return data;
    }

    fn allocateGroup(context: *anyopaque, a: Allocator) ![]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.allocateHistoryGroup(a);
    }

    fn query(context: *anyopaque, a: Allocator, groups: []const []const u8) ![]const contracts.HistoryStore.Reference {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.queryHistory(a, groups);
    }

    fn read(context: *anyopaque, a: Allocator, references: []const contracts.HistoryStore.Reference) ![]const []const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.readHistory(a, references);
    }

    fn create(context: *anyopaque, a: Allocator, records: []const contracts.HistoryStore.Record) !void {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.createHistoryRecords(a, records);
    }

    fn maintain(context: *anyopaque, a: Allocator, retention: contracts.HistoryStore.Retention) !void {
        const self: *History = @ptrCast(@alignCast(context));
        if (!self.loaded) return error.HistoryNotLoaded;
        return self.mailbox.maintainHistory(a, retention, self.revision);
    }

    fn save(context: *anyopaque, checkpoint: []const u8) !void {
        const self: *History = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (!self.loaded) _ = try load(context, a);
        const revision = std.math.add(u64, self.revision, 1) catch return error.HistoryRevisionExhausted;
        // An unconfirmed create may already exist. Refresh checkpoint selection
        // before allocating another revision after an uncertain publication.
        self.loaded = false;
        _ = try self.mailbox.createCheckpoint(a, checkpoint, revision);
        self.revision = revision;
        self.loaded = true;
    }
};

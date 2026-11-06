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
    heads: std.ArrayList([]const u8) = .empty,
    loaded: bool = false,

    pub fn init(allocator: Allocator, mailbox: *Mailbox) History {
        return .{ .allocator = allocator, .mailbox = mailbox };
    }

    pub fn deinit(self: *History) void {
        for (self.heads.items) |id| self.allocator.free(id);
        self.heads.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *History) contracts.HistoryStore {
        return .{ .context = self, .vtable = &.{ .load = load, .allocateGroup = allocateGroup, .query = query, .read = read, .create = create, .save = save } };
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
        var heads: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (heads.items) |id| self.allocator.free(id);
            heads.deinit(self.allocator);
        }
        for (records) |record| {
            const id = try self.allocator.dupe(u8, record.id);
            errdefer self.allocator.free(id);
            try heads.append(self.allocator, id);
        }
        for (self.heads.items) |id| self.allocator.free(id);
        self.heads.deinit(self.allocator);
        self.heads = heads;
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

    fn save(context: *anyopaque, checkpoint: []const u8) !void {
        const self: *History = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (!self.loaded) _ = try load(context, a);
        const revision = std.math.add(u64, self.revision, 1) catch return error.HistoryRevisionExhausted;
        try self.heads.ensureUnusedCapacity(self.allocator, 1);
        // An unconfirmed create may already exist. A retry must refresh heads
        // before allocating another revision instead of trusting this cache.
        self.loaded = false;
        const created = try self.mailbox.createCheckpoint(a, checkpoint, revision);
        self.revision = revision;
        const id = try self.allocator.dupe(u8, created);
        self.heads.appendAssumeCapacity(id);
        self.loaded = true;
        // Publication is confirmed before older heads are demoted. If cleanup
        // fails, retain the confirmed revision and refresh native head state
        // before a retry; its response may not describe what took effect.
        var cleared: usize = 0;
        defer {
            for (self.heads.items[0..cleared]) |previous| self.allocator.free(previous);
            const remaining = self.heads.items[cleared..];
            std.mem.copyForwards([]const u8, self.heads.items[0..remaining.len], remaining);
            self.heads.items.len = remaining.len;
        }
        while (cleared + 1 < self.heads.items.len) : (cleared += 1) {
            const previous = self.heads.items[cleared];
            self.mailbox.clearHistoryHead(a, previous) catch |err| {
                self.loaded = false;
                return err;
            };
        }
    }
};

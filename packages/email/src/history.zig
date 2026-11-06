const std = @import("std");
const contracts = @import("agent_contracts");
const Mailbox = @import("mail.zig").Mailbox;
const StateRecord = @import("mail.zig").StateRecord;
const Allocator = std.mem.Allocator;

/// Store immutable source records and publish the manifest of retained sessions.
/// The agent owns their encodings and record keys.
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
        return .{ .context = self, .vtable = &.{ .load = load, .read = read, .put = put, .save = save } };
    }

    fn load(context: *anyopaque, a: Allocator) !?[]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        self.loaded = false;
        const records = try self.mailbox.stateRecords(a, "history", true);
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
        const data = if (latest) |record| try self.mailbox.stateData(a, record.id) else null;
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

    fn read(context: *anyopaque, a: Allocator, key: []const u8) ![]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        const native_key = try std.fmt.allocPrint(a, "record:{s}", .{key});
        const records = try self.mailbox.stateRecords(a, native_key, false);
        if (records.len == 0) return error.HistoryRecordNotFound;
        var data: ?[]const u8 = null;
        for (records) |record| {
            const candidate = try self.mailbox.stateData(a, record.id);
            if (data) |existing| {
                if (!std.mem.eql(u8, existing, candidate)) return error.InvalidHistory;
            } else data = candidate;
        }
        return data.?;
    }

    fn put(context: *anyopaque, key: []const u8, data: []const u8) !void {
        const self: *History = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const existing = read(context, a, key) catch |err| switch (err) {
            error.HistoryRecordNotFound => null,
            else => return err,
        };
        if (existing) |stored| {
            if (!std.mem.eql(u8, stored, data)) return error.InvalidHistory;
            return;
        }
        _ = try self.mailbox.createState(a, try std.fmt.allocPrint(a, "record:{s}", .{key}), data, null);
    }

    fn save(context: *anyopaque, manifest: []const u8) !void {
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
        const created = try self.mailbox.createState(a, "history", manifest, revision);
        self.revision = revision;
        const id = try self.allocator.dupe(u8, created);
        self.heads.appendAssumeCapacity(id);
        self.loaded = true;
        // Publication is confirmed before older heads are demoted. If cleanup
        // fails, retain the confirmed revision and refresh native head state
        // before a retry; its response may not describe what took effect.
        while (self.heads.items.len > 1) {
            const previous = self.heads.items[0];
            self.mailbox.clearHistoryHead(a, previous) catch |err| {
                self.loaded = false;
                return err;
            };
            self.allocator.free(previous);
            _ = self.heads.orderedRemove(0);
        }
    }
};

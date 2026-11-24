const std = @import("std");
const contracts = @import("agent_contracts");
const Codec = @import("record_codec.zig");
const Allocator = std.mem.Allocator;
const Store = contracts.HistoryStore;
const Key = Store.Key;

/// Selects the unread suffix of one immutable activity-report journal.
/// A drained journal has no checkpoint; its next append uses a fresh group.
pub const Checkpoint = struct {
    group: []const u8,
    head: Key,
    count: usize,
    endings: usize,

    pub fn validate(self: Checkpoint) !void {
        if (self.group.len == 0 or self.count == 0 or self.endings > self.count or !Codec.validKey(self.head)) return error.InvalidHistory;
    }
};

/// One collected assistant text or session ending, before model-input grouping.
pub const Entry = struct {
    from_focus: []const u8,
    observed_at_unix_ms: i64,
    content: union(enum) {
        assistant: []const u8,
        ended,
    },
};

const Record = struct { previous: ?Key, value: Entry };
const Metadata = struct { key: Key, previous: ?Key };
const Index = std.AutoHashMapUnmanaged(Key, Store.Reference);

/// Retains unread record metadata and loads only the requested pages' bodies.
/// The registry serializes operations and publishes its complete checkpoint
/// after append or consume, together with the affected working histories.
pub const Outbox = struct {
    allocator: Allocator,
    store: Store,
    group: ?[]const u8 = null,
    records: std.ArrayList(Metadata) = .empty,
    endings: usize = 0,

    /// Restore the unread chain selected by the validated history checkpoint.
    pub fn init(allocator: Allocator, store: Store, saved: ?Checkpoint) !Outbox {
        var self: Outbox = .{ .allocator = allocator, .store = store };
        errdefer self.deinit();
        const header = saved orelse return self;
        self.group = try allocator.dupe(u8, header.group);
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var index = try self.query(scratch.allocator());
        if (header.count > index.count()) return error.InvalidHistory;
        try self.records.resize(allocator, header.count);
        var next: ?Key = header.head;
        var remaining = header.count;
        while (remaining > 0) {
            remaining -= 1;
            const key = next orelse return error.InvalidHistory;
            // Removing selected keys rejects revisiting one within this selection.
            const selected = index.fetchRemove(key) orelse return error.InvalidHistory;
            self.records.items[remaining] = .{ .key = key, .previous = selected.value.previous };
            next = selected.value.previous;
        }
        // The first unread predecessor may already have been consumed and
        // retired. The saved count, rather than a null predecessor, bounds it.
        self.endings = header.endings;
        return self;
    }

    pub fn deinit(self: *Outbox) void {
        if (self.group) |group| self.allocator.free(group);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Outbox, reports: []const Entry) !void {
        if (reports.len == 0) return;
        try self.records.ensureUnusedCapacity(self.allocator, reports.len);
        const group = self.group orelse try self.store.allocateGroup(self.allocator);
        errdefer if (self.group == null) self.allocator.free(group);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const records = try a.alloc(Store.Record, reports.len);
        var previous: ?Key = if (self.records.getLastOrNull()) |last| last.key else null;
        for (reports, records) |report, *record| {
            const body = try Codec.encode(a, Record{ .previous = previous, .value = report });
            record.* = .{ .group = group, .key = Codec.digest(body), .previous = previous, .body = body };
            previous = record.key;
        }
        try self.store.create(a, records);
        self.group = group;
        for (records, reports) |record, report| {
            self.records.appendAssumeCapacity(.{ .key = record.key, .previous = record.previous });
            self.endings += @intFromBool(report.content == .ended);
        }
    }

    /// Returned entries belong to a. Reading or measuring does not consume them.
    /// start indexes the unread suffix and may equal its length for an empty page.
    pub fn peek(self: *Outbox, a: Allocator, start: usize, limit: usize) ![]const Entry {
        if (start > self.records.items.len) return error.InvalidHistory;
        const count = @min(limit, self.records.items.len - start);
        const reports = try a.alloc(Entry, count);
        if (count == 0) return reports;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const index = try self.query(temporary);
        const selected = self.records.items[start..][0..count];
        const references = try temporary.alloc(Store.Reference, count);
        for (selected, references) |record, *reference| {
            reference.* = index.get(record.key) orelse return error.InvalidHistory;
            if (!equalPrevious(reference.previous, record.previous)) return error.InvalidHistory;
        }
        const bodies = try self.store.read(temporary, references);
        var endings: usize = 0;
        for (references, bodies, reports) |reference, body, *report| {
            if (!equalKey(Codec.digest(body), reference.key)) return error.InvalidHistory;
            const record = try Codec.decode(Record, a, body, .{});
            if (!equalPrevious(record.previous, reference.previous)) return error.InvalidHistory;
            const source_id = contracts.Reference.sequence(record.value.from_focus) orelse return error.InvalidHistory;
            if (source_id <= 1) return error.InvalidHistory;
            report.* = record.value;
            endings += @intFromBool(report.content == .ended);
        }
        if (endings > self.endings or (start == 0 and count == self.records.items.len and endings != self.endings)) return error.InvalidHistory;
        return reports;
    }

    /// Consume the admitted raw prefix; later entries remain unread.
    pub fn consume(self: *Outbox, count: usize, endings: usize) !void {
        if (count > self.records.items.len or endings > count or endings > self.endings) return error.InvalidHistory;
        if (count == self.records.items.len and endings != self.endings) return error.InvalidHistory;
        if (count == 0) return;
        const remaining = self.records.items.len - count;
        std.mem.copyForwards(Metadata, self.records.items[0..remaining], self.records.items[count..]);
        self.records.items.len = remaining;
        self.endings -= endings;
        if (remaining == 0) {
            self.allocator.free(self.group.?);
            self.group = null;
            self.records.deinit(self.allocator);
            self.records = .empty;
        }
    }

    pub fn checkpoint(self: *const Outbox) ?Checkpoint {
        if (self.records.items.len == 0) return null;
        return .{
            .group = self.group.?,
            .head = self.records.items[self.records.items.len - 1].key,
            .count = self.records.items.len,
            .endings = self.endings,
        };
    }

    pub fn retained(self: *const Outbox, a: Allocator) ![]const Store.RecordId {
        const records = try a.alloc(Store.RecordId, self.records.items.len);
        if (records.len == 0) return records;
        const group = try a.dupe(u8, self.group.?);
        for (self.records.items, records) |record, *retained_record|
            retained_record.* = .{ .group = group, .key = record.key };
        return records;
    }

    pub fn pendingEndings(self: *const Outbox) usize {
        return self.endings;
    }

    fn query(self: *const Outbox, a: Allocator) !Index {
        const group = self.group orelse return error.InvalidHistory;
        var index: Index = .empty;
        for (try self.store.query(a, &.{group})) |reference| {
            const entry = try index.getOrPut(a, reference.key);
            if (entry.found_existing) {
                if (!equalPrevious(entry.value_ptr.previous, reference.previous)) return error.InvalidHistory;
            } else entry.value_ptr.* = reference;
        }
        return index;
    }
};

fn equalKey(left: Key, right: Key) bool {
    return std.mem.eql(u8, &left, &right);
}

fn equalPrevious(left: ?Key, right: ?Key) bool {
    if (left) |key| return if (right) |other| equalKey(key, other) else false;
    return right == null;
}

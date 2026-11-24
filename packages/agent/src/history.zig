const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Codec = @import("record_codec.zig");
const Reports = @import("reports.zig");
const Allocator = std.mem.Allocator;
const Store = contracts.HistoryStore;
const Key = Store.Key;
const source_batch_count = 32;
const source_batch_bytes = 1024 * 1024;

/// Identifies one session's append-only segment. Compaction advances its epoch.
pub const Scope = struct { session_id: u64, epoch: u64 };

pub const Entry = union(enum) {
    record: Input.Record,
    exchange: []const contracts.Model.Item,
};

const Source = union(enum) {
    entry: struct { previous: ?Key, value: Entry },
    observations: []const Input.Event,
};

pub const History = struct {
    pub const Wakeup = struct { id: u64, at_unix_ms: i64, text: []const u8 };
    pub const CallbackRegistration = struct { id: u64, reference: []const u8, session_id: u64, source: contracts.Callback.Source };

    subscription_catalog: [32]u8,
    next_session_id: u64,
    next_callback_id: u64,
    next_runtime_reference_id: u64,
    sessions: []const Session,
    wakeups: []const Wakeup,
    callbacks: []const CallbackRegistration,
    /// Channels open at the last checkpoint. The channel registry owns the
    /// live set; these records only let a restart restore the same IDs.
    channels: []const Channel,
    activity_reports: ?Reports.Checkpoint,

    pub const Session = struct {
        session_id: u64,
        focus_id: []const u8,
        role: Input.Role,
        /// When true, an activity receives startup on restore even with no
        /// pending observations. The core always receives startup.
        was_running: bool,
        subscription_through: u64,
        epoch: u64,
        /// Within an epoch, Context only appends. Null when unloaded; the
        /// confirmed checkpoint retains its selection.
        entries: ?[]const Entry,
        observations: []const Input.Event,
    };

    pub const Channel = struct {
        id: []const u8,
        opened_by: []const u8,
        opened_at_unix_ms: i64,
    };

    fn validate(self: History, a: Allocator) !void {
        if (self.sessions.len == 0 or self.next_callback_id == 0 or self.next_runtime_reference_id == 0) return error.InvalidHistory;
        var identities: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer identities.deinit(a);
        var cores: usize = 0;
        for (self.sessions) |session| {
            if (session.session_id == 0 or session.session_id >= self.next_session_id or
                (try identities.getOrPut(a, session.session_id)).found_existing) return error.InvalidHistory;
            if (contracts.Reference.sequence(session.focus_id) != session.session_id) return error.InvalidHistory;
            switch (session.role) {
                .core => {
                    if (session.session_id != 1 or !std.mem.eql(u8, session.focus_id, "core-1")) return error.InvalidHistory;
                    cores += 1;
                },
                .activity => if (session.session_id == 1) return error.InvalidHistory,
            }
            for (session.observations) |event| switch (event) {
                .assignment, .focus_message => {},
                .focus_interrupted => if (session.role != .core) return error.InvalidHistory,
                else => return error.InvalidHistory,
            };
            try validateEntries(session.focus_id, session.entries orelse &.{});
        }
        if (cores != 1) return error.InvalidHistory;
        if (self.activity_reports) |reports| try reports.validate();
        var callbacks: std.AutoHashMapUnmanaged(u64, contracts.Callback.Source) = .empty;
        defer callbacks.deinit(a);
        for (self.callbacks) |callback| {
            if (callback.id == 0 or callback.id >= self.next_callback_id or !identities.contains(callback.session_id)) return error.InvalidHistory;
            if (contracts.Reference.sequence(callback.reference) != callback.id) return error.InvalidHistory;
            if (callback.source == .host and contracts.Reference.sequence(callback.source.host.command_id) == null) return error.InvalidHistory;
            const entry = try callbacks.getOrPut(a, callback.id);
            if (entry.found_existing) return error.InvalidHistory;
            entry.value_ptr.* = callback.source;
        }
        var channel_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer channel_ids.deinit(a);
        for (self.channels) |channel| {
            if (channel.id.len == 0 or channel.opened_by.len == 0) return error.InvalidHistory;
            if ((try channel_ids.getOrPut(a, channel.id)).found_existing) return error.InvalidHistory;
        }
        var wakeup_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer wakeup_ids.deinit(a);
        for (self.wakeups) |wakeup| {
            const source = callbacks.get(wakeup.id) orelse return error.InvalidHistory;
            if (source != .wakeup or (try wakeup_ids.getOrPut(a, wakeup.id)).found_existing) return error.InvalidHistory;
        }
    }
};

/// Each session selects the committed prefix of its current epoch's group.
const Checkpoint = struct {
    subscription_catalog: [32]u8,
    next_session_id: u64,
    next_callback_id: u64,
    /// The stored field name for the next command or channel reference.
    next_command_id: u64,
    sessions: []const Session,
    wakeups: []const History.Wakeup,
    callbacks: []const History.CallbackRegistration,
    /// Absent from checkpoints written before a restart restored channels.
    channels: []const History.Channel = &.{},
    activity_reports: ?Reports.Checkpoint,

    const Session = struct {
        session_id: u64,
        focus_id: []const u8,
        role: Input.Role,
        was_running: bool,
        subscription_through: u64,
        epoch: u64,
        group: []const u8,
        head: ?Key,
        count: usize,
        observations: ?Key,
    };
};

const CachedSession = struct {
    checkpoint: Checkpoint.Session,
    keys: std.ArrayList(Key) = .empty,
};

/// Owns confirmed checkpoint metadata and record keys, including selections
/// for unloaded sessions.
const Cache = struct {
    arena: std.heap.ArenaAllocator,
    sessions: std.AutoHashMapUnmanaged(u64, CachedSession) = .empty,

    fn init(a: Allocator) Cache {
        return .{ .arena = .init(a) };
    }

    fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn add(self: *Cache, session: Checkpoint.Session) !*CachedSession {
        const a = self.arena.allocator();
        const result = try self.sessions.getOrPut(a, session.session_id);
        if (result.found_existing) return error.InvalidHistory;
        var owned = session;
        owned.group = try a.dupe(u8, session.group);
        owned.focus_id = try a.dupe(u8, session.focus_id);
        result.value_ptr.* = .{ .checkpoint = owned };
        return result.value_ptr;
    }
};

pub const Persistence = struct {
    allocator: Allocator,
    store: Store,
    cache: Cache,
    published_checkpoint_digest: ?Key = null,

    pub fn init(allocator: Allocator, store: Store) Persistence {
        return .{ .allocator = allocator, .store = store, .cache = .init(allocator) };
    }

    pub fn deinit(self: *Persistence) void {
        self.cache.deinit();
        self.* = undefined;
    }

    pub fn load(self: *Persistence, a: Allocator, max_sessions: usize) !?History {
        const document = try self.store.load(a) orelse {
            self.cache.deinit();
            self.cache = .init(self.allocator);
            self.published_checkpoint_digest = null;
            return null;
        };
        const checkpoint = try Codec.decode(Checkpoint, a, document, .{});
        if (checkpoint.sessions.len > max_sessions) return error.SessionCapacityUnavailable;
        const sessions = try a.alloc(History.Session, checkpoint.sessions.len);
        var candidate: Cache = .init(self.allocator);
        defer candidate.deinit();
        var owners: std.StringHashMapUnmanaged(u64) = .empty;
        defer owners.deinit(a);
        for (checkpoint.sessions, sessions) |session, *restored| {
            if (session.group.len == 0 or (session.head == null) != (session.count == 0)) return error.InvalidHistory;
            if (session.head) |key| if (!Codec.validKey(key)) return error.InvalidHistory;
            if (session.observations) |key| if (!Codec.validKey(key)) return error.InvalidHistory;
            const owner = try owners.getOrPut(a, session.group);
            if (owner.found_existing) return error.InvalidHistory;
            owner.value_ptr.* = session.session_id;
            _ = try candidate.add(session);
            restored.* = .{
                .session_id = session.session_id,
                .focus_id = session.focus_id,
                .role = session.role,
                .was_running = session.was_running,
                .subscription_through = session.subscription_through,
                .epoch = session.epoch,
                .entries = try a.alloc(Entry, session.count),
                .observations = &.{},
            };
        }
        var selections: std.ArrayList(Selection) = .empty;
        defer selections.deinit(a);
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var offset: usize = 0;
        while (offset < sessions.len) {
            const count = @min(source_batch_count, sessions.len - offset);
            const stored = checkpoint.sessions[offset..][0..count];
            var groups: [source_batch_count][]const u8 = undefined;
            for (stored, groups[0..count]) |session, *group| group.* = session.group;
            const temporary = scratch.allocator();
            const references = try self.store.query(temporary, groups[0..count]);
            var metadata: std.AutoHashMapUnmanaged(u64, Metadata) = .empty;
            for (stored) |session| try metadata.put(temporary, session.session_id, .empty);
            for (references) |reference| {
                const owner = owners.get(reference.group).?;
                try addMetadata(temporary, metadata.getPtr(owner).?, reference);
            }
            for (stored, sessions[offset..][0..count]) |session, *restored| {
                const records = metadata.getPtr(session.session_id).?;
                if (session.count > records.count()) return error.InvalidHistory;
                const cached = candidate.sessions.getPtr(session.session_id).?;
                try cached.keys.resize(candidate.arena.allocator(), session.count);
                var next = session.head;
                var index = session.count;
                while (index > 0) {
                    index -= 1;
                    const key = next orelse return error.InvalidHistory;
                    const reference = records.get(key) orelse return error.InvalidHistory;
                    cached.keys.items[index] = key;
                    next = reference.previous;
                    try select(a, &selections, reference, .{ .entry = &@constCast(restored.entries.?)[index] });
                }
                if (next != null) return error.InvalidHistory;
                if (session.observations) |key| {
                    const reference = records.get(key) orelse return error.InvalidHistory;
                    if (reference.previous != null) return error.InvalidHistory;
                    try select(a, &selections, reference, .{ .observations = &restored.observations });
                }
            }
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
        try self.readSelections(a, selections.items);
        const history: History = .{
            .subscription_catalog = checkpoint.subscription_catalog,
            .next_session_id = checkpoint.next_session_id,
            .next_callback_id = checkpoint.next_callback_id,
            .next_runtime_reference_id = checkpoint.next_command_id,
            .sessions = sessions,
            .wakeups = checkpoint.wakeups,
            .callbacks = checkpoint.callbacks,
            .channels = checkpoint.channels,
            .activity_reports = checkpoint.activity_reports,
        };
        try history.validate(a);
        std.mem.swap(Cache, &self.cache, &candidate);
        self.published_checkpoint_digest = Codec.digest(document);
        return history;
    }

    /// Materialize one confirmed segment without replacing the checkpoint or
    /// loading other sessions' working contexts.
    pub fn restoreEntries(self: *Persistence, a: Allocator, session_id: u64) ![]const Entry {
        const cached = self.cache.sessions.get(session_id) orelse return error.InvalidHistory;
        const entries = try a.alloc(Entry, cached.keys.items.len);
        if (entries.len == 0) return entries;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const references = try self.store.query(temporary, &.{cached.checkpoint.group});
        var metadata: Metadata = .empty;
        for (references) |reference| try addMetadata(temporary, &metadata, reference);
        var selections: std.ArrayList(Selection) = .empty;
        defer selections.deinit(a);
        for (cached.keys.items, entries, 0..) |key, *entry, index| {
            const reference = metadata.get(key) orelse return error.InvalidHistory;
            const previous = if (index == 0) null else cached.keys.items[index - 1];
            if (!equalPrevious(reference.previous, previous)) return error.InvalidHistory;
            try select(a, &selections, reference, .{ .entry = entry });
        }
        try self.readSelections(a, selections.items);
        try validateEntries(cached.checkpoint.focus_id, entries);
        return entries;
    }

    fn readSelections(self: *Persistence, a: Allocator, selections: []const Selection) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var offset: usize = 0;
        while (offset < selections.len) {
            const count = @min(source_batch_count, selections.len - offset);
            const batch = selections[offset..][0..count];
            var references: [source_batch_count]Store.Reference = undefined;
            for (batch, references[0..count]) |selected, *reference| reference.* = selected.reference;
            const bodies = try self.store.read(scratch.allocator(), references[0..count]);
            for (batch, bodies) |selected, body| {
                if (!equalKey(Codec.digest(body), selected.reference.key)) return error.InvalidHistory;
                const source = try Codec.decode(Source, a, body, .{
                    // Historical entries can contain retired handover fields.
                    .ignore_unknown_fields = selected.destination == .entry,
                });
                switch (source) {
                    .entry => |entry| {
                        if (!equalPrevious(entry.previous, selected.reference.previous)) return error.InvalidHistory;
                        switch (selected.destination) {
                            .entry => |destination| destination.* = entry.value,
                            else => return error.InvalidHistory,
                        }
                    },
                    .observations => |events| {
                        if (events.len == 0 or selected.reference.previous != null) return error.InvalidHistory;
                        switch (selected.destination) {
                            .observations => |destination| destination.* = events,
                            else => return error.InvalidHistory,
                        }
                    },
                }
            }
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
    }

    pub fn save(self: *Persistence, a: Allocator, history: History) !void {
        try history.validate(a);
        var candidate: Cache = .init(self.allocator);
        defer candidate.deinit();
        var builder: Builder = .init(self);
        defer builder.deinit();
        const ordered = try a.dupe(History.Session, history.sessions);
        std.mem.sort(History.Session, ordered, {}, struct {
            fn lessThan(_: void, lhs: History.Session, rhs: History.Session) bool {
                return lhs.session_id < rhs.session_id;
            }
        }.lessThan);
        const sessions = try a.alloc(Checkpoint.Session, ordered.len);
        for (ordered, sessions) |session, *saved| {
            const stored = self.cache.sessions.get(session.session_id);
            if (stored) |known| if (session.epoch < known.checkpoint.epoch or !std.mem.eql(u8, session.focus_id, known.checkpoint.focus_id)) return error.InvalidHistory;
            const current = if (stored) |known| if (known.checkpoint.epoch == session.epoch) known else null else null;
            saved.* = .{
                .session_id = session.session_id,
                .focus_id = session.focus_id,
                .role = session.role,
                .was_running = session.was_running,
                .subscription_through = session.subscription_through,
                .epoch = session.epoch,
                .group = if (current) |known| known.checkpoint.group else try self.store.allocateGroup(a),
                .head = null,
                .count = 0,
                .observations = null,
            };
            const cached = try candidate.add(saved.*);
            saved.group = cached.checkpoint.group;
            saved.focus_id = cached.checkpoint.focus_id;
            if (current) |known| try cached.keys.appendSlice(candidate.arena.allocator(), known.keys.items);
            if (session.entries) |entries| {
                const confirmed = cached.keys.items.len;
                if (entries.len < confirmed) return error.InvalidHistory;
                for (entries[confirmed..]) |entry| {
                    const key = try builder.entry(saved.group, cached.keys.getLastOrNull(), entry);
                    try cached.keys.append(candidate.arena.allocator(), key);
                }
            } else if (current == null) return error.InvalidHistory;
            saved.count = cached.keys.items.len;
            saved.head = if (saved.count == 0) null else cached.keys.items[saved.count - 1];
            if (session.observations.len != 0) saved.observations = try builder.observations(
                saved.group,
                session.observations,
                if (current) |known| known.checkpoint.observations else null,
            );
            cached.checkpoint = saved.*;
        }
        try builder.flush();
        const document = try Codec.encode(a, Checkpoint{
            .subscription_catalog = history.subscription_catalog,
            .next_session_id = history.next_session_id,
            .next_callback_id = history.next_callback_id,
            .next_command_id = history.next_runtime_reference_id,
            .sessions = sessions,
            .wakeups = history.wakeups,
            .callbacks = history.callbacks,
            .channels = history.channels,
            .activity_reports = history.activity_reports,
        });
        const candidate_digest = Codec.digest(document);
        if (self.published_checkpoint_digest) |published| {
            if (equalKey(published, candidate_digest)) return;
        }
        // A failed publication may still have changed the stored checkpoint.
        self.published_checkpoint_digest = null;
        try self.store.save(document);
        std.mem.swap(Cache, &self.cache, &candidate);
        self.published_checkpoint_digest = candidate_digest;
    }

    /// Retain confirmed session records together with the caller's unread reports.
    pub fn maintain(self: *Persistence, a: Allocator, extra: []const Store.RecordId) !void {
        std.debug.assert(self.published_checkpoint_digest != null);
        var records: std.ArrayList(Store.RecordId) = .empty;
        defer records.deinit(a);
        var sessions = self.cache.sessions.valueIterator();
        while (sessions.next()) |session| {
            const group = session.checkpoint.group;
            for (session.keys.items) |key| try records.append(a, .{ .group = group, .key = key });
            if (session.checkpoint.observations) |key| try records.append(a, .{ .group = group, .key = key });
        }
        try records.appendSlice(a, extra);
        try self.store.maintain(a, .{ .records = records.items });
    }
};

fn validateEntries(focus_id: []const u8, entries: []const Entry) !void {
    for (entries) |entry| {
        switch (entry) {
            .record => |record| {
                const owner = switch (record) {
                    .events => |events| events.focus_id,
                    .handover => |handover| handover.focus_id,
                };
                // Only the core can fork. Its records retain their original
                // attribution inside an activity's independently stored history.
                if (!std.mem.eql(u8, owner, focus_id) and !std.mem.eql(u8, owner, "core-1")) return error.InvalidHistory;
            },
            .exchange => {},
        }
    }
}

const Metadata = std.AutoHashMapUnmanaged(Key, Store.Reference);

fn addMetadata(a: Allocator, metadata: *Metadata, reference: Store.Reference) !void {
    const result = try metadata.getOrPut(a, reference.key);
    if (result.found_existing) {
        if (!equalPrevious(result.value_ptr.previous, reference.previous)) return error.InvalidHistory;
    } else result.value_ptr.* = reference;
}

const Selection = struct {
    reference: Store.Reference,
    destination: Destination,

    const Destination = union(enum) { entry: *Entry, observations: *[]const Input.Event };
};

fn select(a: Allocator, selections: *std.ArrayList(Selection), reference: Store.Reference, destination: Selection.Destination) !void {
    try selections.append(a, .{
        .reference = .{
            .group = try a.dupe(u8, reference.group),
            .key = reference.key,
            .previous = reference.previous,
            .locator = try a.dupe(u8, reference.locator),
        },
        .destination = destination,
    });
}

/// Encode whole entries and keep only a bounded batch of new bodies.
const Builder = struct {
    persistence: *Persistence,
    encoding: std.heap.ArenaAllocator,
    batch: std.heap.ArenaAllocator,
    records: [source_batch_count]Store.Record = undefined,
    count: usize = 0,
    bytes: usize = 0,

    fn init(persistence: *Persistence) Builder {
        return .{
            .persistence = persistence,
            .encoding = .init(persistence.allocator),
            .batch = .init(persistence.allocator),
        };
    }

    fn deinit(self: *Builder) void {
        self.encoding.deinit();
        self.batch.deinit();
    }

    fn entry(self: *Builder, group: []const u8, previous: ?Key, value: Entry) !Key {
        defer _ = self.encoding.reset(.retain_capacity);
        const body = try Codec.encode(self.encoding.allocator(), Source{ .entry = .{ .previous = previous, .value = value } });
        const key = Codec.digest(body);
        try self.add(group, key, previous, body);
        return key;
    }

    fn observations(self: *Builder, group: []const u8, events: []const Input.Event, confirmed: ?Key) !Key {
        defer _ = self.encoding.reset(.retain_capacity);
        const body = try Codec.encode(self.encoding.allocator(), Source{ .observations = events });
        const key = Codec.digest(body);
        if (confirmed) |known| if (equalKey(known, key)) return key;
        try self.add(group, key, null, body);
        return key;
    }

    fn add(self: *Builder, group: []const u8, key: Key, previous: ?Key, body: []const u8) !void {
        if (self.count > 0 and (self.count == source_batch_count or body.len > source_batch_bytes - self.bytes))
            try self.flush();
        self.records[self.count] = .{
            .group = group,
            .key = key,
            .previous = previous,
            .body = try self.batch.allocator().dupe(u8, body),
        };
        self.count += 1;
        self.bytes += body.len;
        if (self.bytes >= source_batch_bytes) try self.flush();
    }

    fn flush(self: *Builder) !void {
        if (self.count == 0) return;
        try self.persistence.store.create(self.batch.allocator(), self.records[0..self.count]);
        self.count = 0;
        self.bytes = 0;
        _ = self.batch.reset(.retain_capacity);
    }
};

fn equalKey(left: Key, right: Key) bool {
    return std.mem.eql(u8, &left, &right);
}

fn equalPrevious(left: ?Key, right: ?Key) bool {
    if (left) |key| return if (right) |other| equalKey(key, other) else false;
    return right == null;
}

test "working history can append after a handover with a retired sampled field" {
    const t = std.testing;
    const TestStore = @import("test_history.zig").TestStore;
    var store: TestStore = .{};
    defer store.arena.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var persistence = Persistence.init(t.allocator, store.port());
    defer persistence.deinit();
    const body = ".{.entry=.{.previous=null,.value=.{.record=.{.handover=.{" ++
        ".focus_id=\"core-1\",.observed_at_unix_ms=0,.summary=\"Keep investigating.\"," ++
        ".state=.{.activities=.{},.callbacks=.{},.subscriptions=.{\"watch-1\"},.feeds=.{\"old-1\"},.correspondents=null}" ++
        "}}}}}";
    const group = try persistence.store.allocateGroup(a);
    const key = Codec.digest(body);
    try persistence.store.create(a, &.{.{ .group = group, .key = key, .previous = null, .body = body }});
    try persistence.store.save(try Codec.encode(a, Checkpoint{
        .subscription_catalog = @splat(0),
        .next_session_id = 2,
        .next_callback_id = 1,
        .next_command_id = 7,
        .sessions = &.{.{
            .session_id = 1,
            .focus_id = "core-1",
            .role = .core,
            .was_running = true,
            .subscription_through = 0,
            .epoch = 1,
            .group = group,
            .head = key,
            .count = 1,
            .observations = null,
        }},
        .wakeups = &.{},
        .callbacks = &.{},
        .activity_reports = null,
    }));

    var history = (try persistence.load(a, 1)).?;
    try t.expectEqual(7, history.next_runtime_reference_id);
    var core = history.sessions[0];
    const handover = core.entries.?[0].record.handover;
    try t.expectEqualStrings("Keep investigating.", handover.summary);
    try t.expectEqualStrings("watch-1", handover.state.subscriptions[0]);
    core.entries = &.{ core.entries.?[0], .{ .exchange = &.{.{ .continuation = "Continuing." }} } };
    history.sessions = &.{core};
    try persistence.save(a, history);

    try t.expectEqual(2, store.records.items.len);
    try t.expectEqual(key, store.records.items[1].previous.?);
    const continued = (try persistence.load(a, 1)).?.sessions[0].entries.?;
    try t.expectEqualStrings("Keep investigating.", continued[0].record.handover.summary);
    try t.expectEqualStrings("Continuing.", continued[1].exchange[0].continuation);
}

test "a checkpoint written before a restart restored channels still loads" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const BeforeChannels = struct {
        subscription_catalog: [32]u8,
        next_session_id: u64,
        next_callback_id: u64,
        next_command_id: u64,
        sessions: []const Checkpoint.Session,
        wakeups: []const History.Wakeup,
        callbacks: []const History.CallbackRegistration,
        activity_reports: ?Reports.Checkpoint,
    };
    const document = try Codec.encode(a, BeforeChannels{
        .subscription_catalog = @splat(0),
        .next_session_id = 2,
        .next_callback_id = 1,
        .next_command_id = 3,
        .sessions = &.{},
        .wakeups = &.{},
        .callbacks = &.{},
        .activity_reports = null,
    });
    try t.expect(std.mem.indexOf(u8, document, "channel") == null);
    const checkpoint = try Codec.decode(Checkpoint, a, document, .{});
    try t.expectEqual(0, checkpoint.channels.len);
}

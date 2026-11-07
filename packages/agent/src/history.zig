const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;
const Store = contracts.HistoryStore;
const Key = Store.Key;
const source_batch_count = 32;
const source_batch_bytes = 1024 * 1024;

/// One session's append-only history segment. Compaction advances its epoch.
pub const Scope = struct { session_id: u64, epoch: u64 };

pub const Payload = union(enum) {
    record: Input.Record,
    exchange: []const contracts.Model.Item,
};

/// Forks preserve the original scopes of inherited entries.
pub const Entry = struct { scope: Scope, value: Payload };

const Source = union(enum) {
    entry: struct { previous: ?Key, value: Entry },
    observations: []const Input.Event,
};

pub const History = struct {
    pub const Wakeup = struct { id: u64, at_unix_ms: i64, text: []const u8 };

    next_session_id: u64,
    next_callback_id: u64,
    sessions: []const Session,
    wakeups: []const Wakeup,
    callbacks: []const Input.PendingCallback,

    pub const Session = struct {
        session_id: u64,
        role: Input.Role,
        last_active_unix_ms: i64,
        was_running: bool,
        epoch: u64,
        /// A cold context keeps the spans from its confirmed checkpoint.
        entries: ?[]const Entry,
        observations: []const Input.Event,
    };

    fn validate(self: History, a: Allocator) !void {
        if (self.sessions.len == 0 or self.next_callback_id == 0) return error.InvalidHistory;
        var epochs: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer epochs.deinit(a);
        for (self.sessions) |session| {
            if (session.session_id == 0 or session.session_id >= self.next_session_id) return error.InvalidHistory;
            const result = try epochs.getOrPut(a, session.session_id);
            if (result.found_existing) return error.InvalidHistory;
            result.value_ptr.* = session.epoch;
        }
        var cores: usize = 0;
        for (self.sessions) |session| {
            for (session.observations) |event| switch (event) {
                .assignment, .report, .session_message, .session_created => {},
                else => return error.InvalidHistory,
            };
            for (session.entries orelse &.{}) |entry| {
                const owner_epoch = epochs.get(entry.scope.session_id) orelse return error.InvalidHistory;
                if (entry.scope.epoch > owner_epoch) return error.InvalidHistory;
            }
            switch (session.role) {
                .core => {
                    if (session.session_id != 1) return error.InvalidHistory;
                    cores += 1;
                },
                .branch => |branch| {
                    if (branch.parent_session_id >= session.session_id or !epochs.contains(branch.parent_session_id)) return error.InvalidHistory;
                },
            }
        }
        if (cores != 1) return error.InvalidHistory;
        var callbacks: std.AutoHashMapUnmanaged(u64, Input.PendingCallback) = .empty;
        defer callbacks.deinit(a);
        for (self.callbacks) |callback| {
            if (callback.id == 0 or callback.id >= self.next_callback_id or !epochs.contains(callback.session_id)) return error.InvalidHistory;
            const entry = try callbacks.getOrPut(a, callback.id);
            if (entry.found_existing) return error.InvalidHistory;
            entry.value_ptr.* = callback;
        }
        var wakeup_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer wakeup_ids.deinit(a);
        for (self.wakeups) |wakeup| {
            const callback = callbacks.get(wakeup.id) orelse return error.InvalidHistory;
            if (callback.source != .wakeup or (try wakeup_ids.getOrPut(a, wakeup.id)).found_existing) return error.InvalidHistory;
        }
    }
};

const Span = struct { scope: Scope, group: []const u8, head: Key, count: usize };

/// Each span selects a scope's committed prefix and names its storage group,
/// so all required groups are known before record discovery.
const Checkpoint = struct {
    next_session_id: u64,
    next_callback_id: u64,
    sessions: []const Session,
    wakeups: []const History.Wakeup,
    callbacks: []const Input.PendingCallback,

    const Session = struct {
        session_id: u64,
        role: Input.Role,
        last_active_unix_ms: i64,
        was_running: bool,
        epoch: u64,
        group: []const u8,
        history: []const Span,
        observations: ?Key,
    };
};

const CachedScope = struct {
    group: []const u8,
    keys: std.ArrayList(Key) = .empty,
    active: bool = false,
};
const CachedObservation = struct { scope: Scope, key: Key };

/// Session metadata, groups, and keys from the last confirmed checkpoint.
/// The arena owns the complete cache, including cold contexts' spans.
const Cache = struct {
    arena: std.heap.ArenaAllocator,
    scopes: std.AutoHashMapUnmanaged(Scope, CachedScope) = .empty,
    observations: std.AutoHashMapUnmanaged(u64, CachedObservation) = .empty,
    sessions: std.AutoHashMapUnmanaged(u64, Checkpoint.Session) = .empty,

    fn init(a: Allocator) Cache {
        return .{ .arena = .init(a) };
    }

    fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.* = undefined;
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
        const checkpoint = try decode(Checkpoint, a, document);
        if (checkpoint.sessions.len > max_sessions) return error.SessionCapacityUnavailable;
        var candidate: Cache = .init(self.allocator);
        defer candidate.deinit();
        var owners: std.StringHashMapUnmanaged(Scope) = .empty;
        defer owners.deinit(a);
        for (checkpoint.sessions) |session| {
            try registerScope(&candidate, &owners, a, .{ .session_id = session.session_id, .epoch = session.epoch }, session.group);
            candidate.scopes.getPtr(.{ .session_id = session.session_id, .epoch = session.epoch }).?.active = true;
            var seen: std.AutoHashMapUnmanaged(Scope, void) = .empty;
            defer seen.deinit(a);
            for (session.history) |span| {
                if (span.count == 0 or !validKey(span.head)) return error.InvalidHistory;
                if ((try seen.getOrPut(a, span.scope)).found_existing) return error.InvalidHistory;
                try registerScope(&candidate, &owners, a, span.scope, span.group);
            }
            if (session.observations) |key| {
                if (!validKey(key)) return error.InvalidHistory;
                try candidate.observations.put(candidate.arena.allocator(), session.session_id, .{
                    .scope = .{ .session_id = session.session_id, .epoch = session.epoch },
                    .key = key,
                });
            }
        }
        var selections: Selections = .{ .allocator = a };
        defer selections.deinit();
        const groups = try a.alloc([]const u8, owners.count());
        var group_iterator = owners.keyIterator();
        for (groups) |*group| group.* = group_iterator.next().?.*;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var offset: usize = 0;
        while (offset < groups.len) {
            const count = @min(source_batch_count, groups.len - offset);
            const batch = groups[offset..][0..count];
            const temporary = scratch.allocator();
            const references = try self.store.query(temporary, batch);
            const Metadata = std.AutoHashMapUnmanaged(Key, Store.Reference);
            var metadata: std.AutoHashMapUnmanaged(Scope, Metadata) = .empty;
            for (batch) |group| try metadata.put(temporary, owners.get(group).?, .empty);
            for (references) |reference| {
                const scope = owners.get(reference.group).?;
                const records = metadata.getPtr(scope).?;
                const result = try records.getOrPut(temporary, reference.key);
                if (result.found_existing) {
                    if (!equalPrevious(result.value_ptr.previous, reference.previous)) return error.InvalidHistory;
                } else result.value_ptr.* = reference;
            }
            for (checkpoint.sessions) |session| {
                for (session.history) |span| {
                    const records = metadata.getPtr(span.scope) orelse continue;
                    if (span.count > records.count()) return error.InvalidHistory;
                    const keys = try temporary.alloc(Key, span.count);
                    var next: ?Key = span.head;
                    var index = span.count;
                    while (index > 0) {
                        index -= 1;
                        const key = next orelse return error.InvalidHistory;
                        const reference = records.get(key) orelse return error.InvalidHistory;
                        keys[index] = key;
                        next = reference.previous;
                        try selections.add(span.scope, reference, .entry);
                    }
                    if (next != null) return error.InvalidHistory;
                    const cached = candidate.scopes.getPtr(span.scope).?;
                    const common = @min(cached.keys.items.len, keys.len);
                    for (cached.keys.items[0..common], keys[0..common]) |left, right| {
                        if (!equalKey(left, right)) return error.InvalidHistory;
                    }
                    if (keys.len > cached.keys.items.len)
                        try cached.keys.appendSlice(candidate.arena.allocator(), keys[cached.keys.items.len..]);
                }
                if (session.observations) |key| {
                    const scope: Scope = .{ .session_id = session.session_id, .epoch = session.epoch };
                    const records = metadata.getPtr(scope) orelse continue;
                    const reference = records.get(key) orelse return error.InvalidHistory;
                    if (reference.previous != null) return error.InvalidHistory;
                    try selections.add(scope, reference, .observations);
                }
            }
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
        try self.readSelections(a, &selections);
        const sessions = try a.alloc(History.Session, checkpoint.sessions.len);
        for (checkpoint.sessions, sessions) |session, *restored| {
            var entry_count: usize = 0;
            for (session.history) |span| entry_count = std.math.add(usize, entry_count, span.count) catch return error.InvalidHistory;
            const entries = try a.alloc(Entry, entry_count);
            var position: usize = 0;
            for (session.history) |span| {
                const cached = candidate.scopes.get(span.scope).?;
                for (cached.keys.items[0..span.count]) |key| {
                    entries[position] = selections.source(span.scope, key).entry.value;
                    position += 1;
                }
            }
            const scope: Scope = .{ .session_id = session.session_id, .epoch = session.epoch };
            restored.* = .{
                .session_id = session.session_id,
                .role = session.role,
                .last_active_unix_ms = session.last_active_unix_ms,
                .was_running = session.was_running,
                .epoch = session.epoch,
                .entries = entries,
                .observations = if (session.observations) |key| selections.source(scope, key).observations else &.{},
            };
            try cacheSession(&candidate, session);
        }
        const history: History = .{
            .next_session_id = checkpoint.next_session_id,
            .next_callback_id = checkpoint.next_callback_id,
            .sessions = sessions,
            .wakeups = checkpoint.wakeups,
            .callbacks = checkpoint.callbacks,
        };
        try history.validate(a);
        std.mem.swap(Cache, &self.cache, &candidate);
        self.published_checkpoint_digest = digest(document);
        return history;
    }

    /// Restore only this session's selected history without replacing the
    /// confirmed checkpoint or materializing any other working context.
    pub fn restoreEntries(self: *Persistence, a: Allocator, session_id: u64) ![]const Entry {
        const session = self.cache.sessions.get(session_id) orelse return error.InvalidHistory;
        var selections: Selections = .{ .allocator = a };
        defer selections.deinit();
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var offset: usize = 0;
        while (offset < session.history.len) {
            const count = @min(source_batch_count, session.history.len - offset);
            const spans = session.history[offset..][0..count];
            var groups: [source_batch_count][]const u8 = undefined;
            var owners: std.StringHashMapUnmanaged(Scope) = .empty;
            const temporary = scratch.allocator();
            for (spans, groups[0..count]) |span, *group| {
                group.* = span.group;
                try owners.put(temporary, span.group, span.scope);
            }
            const references = try self.store.query(temporary, groups[0..count]);
            const Metadata = std.AutoHashMapUnmanaged(Key, Store.Reference);
            var metadata: std.AutoHashMapUnmanaged(Scope, Metadata) = .empty;
            for (spans) |span| try metadata.put(temporary, span.scope, .empty);
            for (references) |reference| {
                const scope = owners.get(reference.group).?;
                const records = metadata.getPtr(scope).?;
                const result = try records.getOrPut(temporary, reference.key);
                if (result.found_existing) {
                    if (!equalPrevious(result.value_ptr.previous, reference.previous)) return error.InvalidHistory;
                } else result.value_ptr.* = reference;
            }
            for (spans) |span| {
                const cached = self.cache.scopes.get(span.scope).?;
                const records = metadata.getPtr(span.scope).?;
                for (cached.keys.items[0..span.count], 0..) |key, index| {
                    const reference = records.get(key) orelse return error.InvalidHistory;
                    const previous = if (index == 0) null else cached.keys.items[index - 1];
                    if (!equalPrevious(reference.previous, previous)) return error.InvalidHistory;
                    try selections.add(span.scope, reference, .entry);
                }
            }
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
        try self.readSelections(a, &selections);
        var entry_count: usize = 0;
        for (session.history) |span| entry_count = std.math.add(usize, entry_count, span.count) catch return error.InvalidHistory;
        const entries = try a.alloc(Entry, entry_count);
        var position: usize = 0;
        for (session.history) |span| {
            const cached = self.cache.scopes.get(span.scope).?;
            for (cached.keys.items[0..span.count]) |key| {
                entries[position] = selections.source(span.scope, key).entry.value;
                position += 1;
            }
        }
        return entries;
    }

    fn readSelections(self: *Persistence, a: Allocator, selections: *Selections) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var offset: usize = 0;
        while (offset < selections.items.items.len) {
            const count = @min(source_batch_count, selections.items.items.len - offset);
            const batch = selections.items.items[offset..][0..count];
            var references: [source_batch_count]Store.Reference = undefined;
            for (batch, references[0..count]) |selected, *reference| reference.* = selected.reference;
            const bodies = try self.store.read(scratch.allocator(), references[0..count]);
            for (batch, bodies) |*selected, body| {
                if (!equalKey(digest(body), selected.reference.key)) return error.InvalidHistory;
                const source = try decode(Source, a, body);
                switch (source) {
                    .entry => |entry| {
                        if (selected.kind != .entry or !equalScope(entry.value.scope, selected.scope) or
                            !equalPrevious(entry.previous, selected.reference.previous)) return error.InvalidHistory;
                    },
                    .observations => |events| {
                        if (selected.kind != .observations or events.len == 0) return error.InvalidHistory;
                    },
                }
                selected.source = source;
            }
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
    }

    pub fn save(self: *Persistence, a: Allocator, history: History) !void {
        try history.validate(a);
        var candidate: Cache = .init(self.allocator);
        defer candidate.deinit();
        var builder: Builder = .init(self, &candidate, a);
        defer builder.deinit();
        const ordered = try a.dupe(History.Session, history.sessions);
        std.mem.sort(History.Session, ordered, {}, struct {
            fn lessThan(_: void, lhs: History.Session, rhs: History.Session) bool {
                return lhs.session_id < rhs.session_id;
            }
        }.lessThan);
        const sessions = try a.alloc(Checkpoint.Session, ordered.len);
        for (ordered, sessions) |session, *saved| {
            const current: Scope = .{ .session_id = session.session_id, .epoch = session.epoch };
            const group = try builder.group(current);
            candidate.scopes.getPtr(current).?.active = true;
            var spans: std.ArrayList(Span) = .empty;
            if (session.entries) |entries| {
                var seen: std.AutoHashMapUnmanaged(Scope, void) = .empty;
                defer seen.deinit(a);
                var offset: usize = 0;
                while (offset < entries.len) {
                    const scope = entries[offset].scope;
                    if ((try seen.getOrPut(a, scope)).found_existing) return error.InvalidHistory;
                    const source_group = try builder.group(scope);
                    var count: usize = 0;
                    var head: Key = undefined;
                    while (offset < entries.len and equalScope(entries[offset].scope, scope)) {
                        head = try builder.entry(entries[offset], count);
                        count += 1;
                        offset += 1;
                    }
                    try spans.append(a, .{ .scope = scope, .group = source_group, .head = head, .count = count });
                }
            } else {
                const stored = self.cache.sessions.get(session.session_id) orelse return error.InvalidHistory;
                if (stored.epoch != session.epoch) return error.InvalidHistory;
                for (stored.history) |span| try builder.retainSpan(span);
                try spans.appendSlice(a, stored.history);
            }
            const observations = if (session.observations.len == 0) null else try builder.observations(current, session.observations);
            saved.* = .{
                .session_id = session.session_id,
                .role = session.role,
                .last_active_unix_ms = session.last_active_unix_ms,
                .was_running = session.was_running,
                .epoch = session.epoch,
                .group = group,
                .history = spans.items,
                .observations = observations,
            };
            try cacheSession(&candidate, saved.*);
        }
        try builder.flush();
        const document = try encode(a, Checkpoint{
            .next_session_id = history.next_session_id,
            .next_callback_id = history.next_callback_id,
            .sessions = sessions,
            .wakeups = history.wakeups,
            .callbacks = history.callbacks,
        });
        const candidate_digest = digest(document);
        if (self.published_checkpoint_digest) |published| {
            if (equalKey(published, candidate_digest)) return;
        }
        // A failed publication may still have changed the stored checkpoint.
        self.published_checkpoint_digest = null;
        try self.store.save(document);
        std.mem.swap(Cache, &self.cache, &candidate);
        self.published_checkpoint_digest = candidate_digest;
    }

    /// Pass the confirmed checkpoint's selected records and current writable
    /// groups to storage.
    pub fn maintain(self: *Persistence, a: Allocator) !void {
        std.debug.assert(self.published_checkpoint_digest != null);
        var active_groups: std.ArrayList([]const u8) = .empty;
        defer active_groups.deinit(a);
        var records: std.ArrayList(Store.RecordId) = .empty;
        defer records.deinit(a);
        var scopes = self.cache.scopes.iterator();
        while (scopes.next()) |entry| {
            const scope = entry.value_ptr;
            if (scope.active) try active_groups.append(a, scope.group);
            for (scope.keys.items) |key| try records.append(a, .{ .group = scope.group, .key = key });
        }
        var observations = self.cache.observations.valueIterator();
        while (observations.next()) |observation| {
            const scope = self.cache.scopes.get(observation.scope).?;
            try records.append(a, .{ .group = scope.group, .key = observation.key });
        }
        try self.store.maintain(a, .{ .active_groups = active_groups.items, .records = records.items });
    }
};

fn cacheSession(cache: *Cache, session: Checkpoint.Session) !void {
    const a = cache.arena.allocator();
    const spans = try a.alloc(Span, session.history.len);
    for (session.history, spans) |span, *owned| {
        owned.* = span;
        owned.group = cache.scopes.get(span.scope).?.group;
    }
    var owned = session;
    owned.group = cache.scopes.get(.{ .session_id = session.session_id, .epoch = session.epoch }).?.group;
    owned.history = spans;
    try cache.sessions.put(a, session.session_id, owned);
}

fn registerScope(cache: *Cache, owners: *std.StringHashMapUnmanaged(Scope), a: Allocator, scope: Scope, group: []const u8) !void {
    if (scope.session_id == 0 or group.len == 0) return error.InvalidHistory;
    if (cache.scopes.get(scope)) |known| {
        if (!std.mem.eql(u8, known.group, group)) return error.InvalidHistory;
        return;
    }
    if (owners.contains(group)) return error.InvalidHistory;
    const owned = try cache.arena.allocator().dupe(u8, group);
    try cache.scopes.put(cache.arena.allocator(), scope, .{ .group = owned });
    try owners.put(a, owned, scope);
}

const SelectionId = struct { scope: Scope, key: Key };
const SelectionKind = enum { entry, observations };
const Selection = struct {
    scope: Scope,
    reference: Store.Reference,
    kind: SelectionKind,
    source: ?Source = null,
};
const Selections = struct {
    allocator: Allocator,
    indexes: std.AutoHashMapUnmanaged(SelectionId, usize) = .empty,
    items: std.ArrayList(Selection) = .empty,

    fn deinit(self: *Selections) void {
        self.indexes.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    fn add(self: *Selections, scope: Scope, reference: Store.Reference, kind: SelectionKind) !void {
        const result = try self.indexes.getOrPut(self.allocator, .{ .scope = scope, .key = reference.key });
        if (result.found_existing) {
            const previous = self.items.items[result.value_ptr.*];
            if (previous.kind != kind or !equalPrevious(previous.reference.previous, reference.previous)) return error.InvalidHistory;
            return;
        }
        result.value_ptr.* = self.items.items.len;
        try self.items.append(self.allocator, .{
            .scope = scope,
            .reference = .{
                .group = try self.allocator.dupe(u8, reference.group),
                .key = reference.key,
                .previous = reference.previous,
                .locator = try self.allocator.dupe(u8, reference.locator),
            },
            .kind = kind,
        });
    }

    fn source(self: *const Selections, scope: Scope, key: Key) Source {
        return self.items.items[self.indexes.get(.{ .scope = scope, .key = key }).?].source.?;
    }
};

/// Encode every occurrence to compare exact prefixes; retain only a bounded
/// batch of new bodies. Confirmed prefixes need no new stored records.
const Builder = struct {
    persistence: *Persistence,
    cache: *Cache,
    allocator: Allocator,
    owners: std.StringHashMapUnmanaged(Scope) = .empty,
    encoding: std.heap.ArenaAllocator,
    batch: std.heap.ArenaAllocator,
    records: [source_batch_count]Store.Record = undefined,
    count: usize = 0,
    bytes: usize = 0,

    fn init(persistence: *Persistence, cache: *Cache, a: Allocator) Builder {
        return .{
            .persistence = persistence,
            .cache = cache,
            .allocator = a,
            .encoding = .init(persistence.allocator),
            .batch = .init(persistence.allocator),
        };
    }

    fn deinit(self: *Builder) void {
        self.owners.deinit(self.allocator);
        self.encoding.deinit();
        self.batch.deinit();
    }

    fn group(self: *Builder, scope: Scope) ![]const u8 {
        if (self.cache.scopes.get(scope)) |cached| return cached.group;
        const stored = if (self.persistence.cache.scopes.get(scope)) |cached|
            cached.group
        else
            try self.persistence.store.allocateGroup(self.allocator);
        try registerScope(self.cache, &self.owners, self.allocator, scope, stored);
        return self.cache.scopes.get(scope).?.group;
    }

    fn entry(self: *Builder, value: Entry, index: usize) !Key {
        defer _ = self.encoding.reset(.retain_capacity);
        const cached = self.cache.scopes.getPtr(value.scope).?;
        const previous = if (index == 0) null else cached.keys.items[index - 1];
        const body = try encode(self.encoding.allocator(), Source{ .entry = .{ .previous = previous, .value = value } });
        const key = digest(body);
        if (index < cached.keys.items.len) {
            if (!equalKey(cached.keys.items[index], key)) return error.InvalidHistory;
            return key;
        }
        var known = false;
        if (self.persistence.cache.scopes.get(value.scope)) |stored| {
            if (index < stored.keys.items.len) {
                if (!equalKey(stored.keys.items[index], key)) return error.InvalidHistory;
                known = true;
            }
        }
        try cached.keys.append(self.cache.arena.allocator(), key);
        if (!known) try self.add(cached.group, key, previous, body);
        return key;
    }

    fn retainSpan(self: *Builder, span: Span) !void {
        _ = try self.group(span.scope);
        const stored = self.persistence.cache.scopes.get(span.scope).?;
        const cached = self.cache.scopes.getPtr(span.scope).?;
        const keys = stored.keys.items[0..span.count];
        const common = @min(cached.keys.items.len, keys.len);
        for (cached.keys.items[0..common], keys[0..common]) |left, right| {
            if (!equalKey(left, right)) return error.InvalidHistory;
        }
        if (keys.len > cached.keys.items.len)
            try cached.keys.appendSlice(self.cache.arena.allocator(), keys[cached.keys.items.len..]);
    }

    fn observations(self: *Builder, scope: Scope, events: []const Input.Event) !Key {
        defer _ = self.encoding.reset(.retain_capacity);
        const body = try encode(self.encoding.allocator(), Source{ .observations = events });
        const key = digest(body);
        try self.cache.observations.put(self.cache.arena.allocator(), scope.session_id, .{ .scope = scope, .key = key });
        if (self.persistence.cache.observations.get(scope.session_id)) |stored| {
            if (equalScope(stored.scope, scope) and equalKey(stored.key, key)) return key;
        }
        try self.add(self.cache.scopes.get(scope).?.group, key, null, body);
        return key;
    }

    fn add(self: *Builder, group_id: []const u8, key: Key, previous: ?Key, body: []const u8) !void {
        if (self.count > 0 and (self.count == source_batch_count or body.len > source_batch_bytes - self.bytes))
            try self.flush();
        self.records[self.count] = .{
            .group = group_id,
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

fn validKey(key: Key) bool {
    for (key) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn equalKey(left: Key, right: Key) bool {
    return std.mem.eql(u8, &left, &right);
}

fn equalPrevious(left: ?Key, right: ?Key) bool {
    if (left) |key| return if (right) |other| equalKey(key, other) else false;
    return right == null;
}

fn equalScope(left: Scope, right: Scope) bool {
    return left.session_id == right.session_id and left.epoch == right.epoch;
}

fn digest(data: []const u8) Key {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn encode(a: Allocator, value: anytype) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    try std.zon.stringify.serialize(value, .{ .whitespace = false }, &writer.writer);
    return writer.toOwnedSlice();
}

fn decode(comptime T: type, a: Allocator, data: []const u8) !T {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = a,
        .arena = a,
        .source = try a.dupeSentinel(u8, data, 0),
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.ParseZon => error.InvalidHistory,
        else => err,
    };
}

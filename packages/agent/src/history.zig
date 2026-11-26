const std = @import("std");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Input = @import("input.zig");
const Stream = @import("work.zig").Stream;
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
    exchange: []const Model.Item,
};

const Source = union(enum) {
    entry: struct { previous: ?Key, value: StoredEntry },
    observations: []const Input.Event,
};

const StoredEntry = union(enum) {
    record: Input.Record,
    exchange: []const Item,

    const Item = union(enum) {
        message: @FieldType(Model.Item, "message"),
        continuation: []const u8,
        tool_result: struct { call_id: []const u8, content: struct { parts: []const StoredPart } },
    };
};

const InlineImage = @FieldType(@FieldType(Model.Content.Part, "image"), "data");
const Base64Image = struct {
    format: @FieldType(InlineImage, "format"),
    encoded: []const u8,
};

const StoredPart = union(enum) {
    text: []const u8,
    image: union(enum) { url: []const u8, base64: Base64Image, data: InlineImage },
    file_reference: []const u8,
    // Earlier records stored both a file's original bytes and its upload ID.
    file: struct { bytes: []const u8, reference: []const u8 },

    fn restore(self: StoredPart, a: Allocator) !Model.Content.Part {
        return switch (self) {
            .text => |value| .{ .text = try a.dupe(u8, value) },
            .image => |image| .{ .image = switch (image) {
                .url => |url| .{ .url = try a.dupe(u8, url) },
                .data => |data| .{ .data = .{ .format = data.format, .bytes = try a.dupe(u8, data.bytes) } },
                .base64 => |data| blk: {
                    const decoder = std.base64.standard.Decoder;
                    const length = decoder.calcSizeForSlice(data.encoded) catch return error.InvalidHistory;
                    const bytes = try a.alloc(u8, length);
                    decoder.decode(bytes, data.encoded) catch return error.InvalidHistory;
                    break :blk .{ .data = .{ .format = data.format, .bytes = bytes } };
                },
            } },
            .file => |old| .{ .file_reference = try a.dupe(u8, old.reference) },
            .file_reference => |id| .{ .file_reference = try a.dupe(u8, id) },
        };
    }
};

fn storeEntry(a: Allocator, entry: Entry) !StoredEntry {
    if (entry == .record) return .{ .record = entry.record };
    const items = try a.alloc(StoredEntry.Item, entry.exchange.len);
    for (entry.exchange, items) |item, *stored| stored.* = switch (item) {
        .tool_result => |result| blk: {
            const parts = try a.alloc(StoredPart, result.content.parts.len);
            for (result.content.parts, parts) |part, *stored_part| stored_part.* = switch (part) {
                .text => |value| .{ .text = value },
                .image => |image| .{ .image = switch (image) {
                    .url => |url| .{ .url = url },
                    .data => |data| image: {
                        const encoder = std.base64.standard.Encoder;
                        const encoded = try a.alloc(u8, encoder.calcSize(data.bytes.len));
                        break :image .{ .base64 = .{ .format = data.format, .encoded = encoder.encode(encoded, data.bytes) } };
                    },
                } },
                .file_reference => |id| .{ .file_reference = id },
            };
            break :blk .{ .tool_result = .{ .call_id = result.call_id, .content = .{ .parts = parts } } };
        },
        inline else => |value, tag| @unionInit(StoredEntry.Item, @tagName(tag), value),
    };
    return .{ .exchange = items };
}

fn restoreEntry(a: Allocator, temporary: Allocator, value: StoredEntry) !Entry {
    if (value == .record) {
        var record = value.record;
        if (record == .handover) try record.handover.state.restoreLegacyFields(temporary);
        return .{ .record = try Input.cloneRecord(a, record) };
    }
    const items = try a.alloc(Model.Item, value.exchange.len);
    for (value.exchange, items) |stored, *item| item.* = switch (stored) {
        .message => |message| .{ .message = .{ .role = message.role, .text = try a.dupe(u8, message.text) } },
        .continuation => |value_bytes| .{ .continuation = try a.dupe(u8, value_bytes) },
        .tool_result => |result| blk: {
            const parts = try a.alloc(Model.Content.Part, result.content.parts.len);
            for (result.content.parts, parts) |part, *restored| restored.* = try part.restore(a);
            break :blk .{ .tool_result = .{ .call_id = try a.dupe(u8, result.call_id), .content = .{ .parts = parts } } };
        },
    };
    return .{ .exchange = items };
}

pub const History = struct {
    pub const Wakeup = struct {
        id: u64,
        at_unix_ms: i64,
        /// Null after publication. The original time stays until admission.
        text: ?[]const u8,
    };
    pub const CallbackRegistration = struct { id: u64, reference: []const u8, session_id: u64, source: contracts.Callback.Source };

    subscription_catalog: [32]u8,
    usage_scope: ?[32]u8 = null,
    next_session_id: u64,
    next_callback_id: u64,
    next_runtime_reference_id: u64,
    sessions: []const Session,
    wakeups: []const Wakeup,
    callbacks: []const CallbackRegistration,
    /// Open channel registrations. The opening focus may have ended.
    channels: []const Channel,
    activity_reports: ?Reports.Checkpoint,

    /// Admission order and inference usage saved with the session's history.
    pub const Progress = struct {
        /// Input token count from the last committed ordinary round in this
        /// epoch, including a round with tool calls. A missing count clears it.
        last_input_tokens: ?u64 = null,
        /// Starting stream for the next admission batch, after any startup observation.
        first_stream: Stream = .ordinary,
    };

    pub const Session = struct {
        session_id: u64,
        focus_id: []const u8,
        role: Input.Role,
        /// When true, an activity receives startup on restore even with no
        /// pending observations. The core always receives startup.
        was_running: bool,
        subscription_through: u64,
        epoch: u64,
        progress: Progress = .{},
        /// Within an epoch, Context only appends. Null when unloaded; the
        /// confirmed checkpoint retains its selection.
        entries: ?[]const Entry,
        observations: []const Input.Event,
    };

    pub const Channel = struct {
        id: []const u8,
        opened_by: []const u8,
        opened_at_unix_ms: i64,
        description: ?[]const u8 = null,
    };

    fn validate(self: History, a: Allocator) !void {
        if (self.sessions.len == 0 or self.next_callback_id == 0 or self.next_runtime_reference_id == 0) return error.InvalidHistory;
        var identities: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
        defer identities.deinit(a);
        var cores: usize = 0;
        for (self.sessions) |session| {
            if (session.session_id == 0 or session.session_id >= self.next_session_id or
                contracts.Reference.sequence(session.focus_id) != session.session_id) return error.InvalidHistory;
            const identity = try identities.getOrPut(a, session.session_id);
            if (identity.found_existing) return error.InvalidHistory;
            identity.value_ptr.* = session.focus_id;
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
        var callbacks: std.AutoHashMapUnmanaged(u64, std.meta.Tag(contracts.Callback.Source)) = .empty;
        defer callbacks.deinit(a);
        for (self.callbacks) |callback| {
            if (callback.id == 0 or callback.id >= self.next_callback_id or !identities.contains(callback.session_id)) return error.InvalidHistory;
            if (contracts.Reference.sequence(callback.reference) != callback.id) return error.InvalidHistory;
            if (callback.source == .host and contracts.Reference.sequence(callback.source.host.command_id) == null) return error.InvalidHistory;
            const entry = try callbacks.getOrPut(a, callback.id);
            if (entry.found_existing) return error.InvalidHistory;
            entry.value_ptr.* = std.meta.activeTag(callback.source);
        }
        for (self.wakeups) |wakeup| {
            const registration = callbacks.fetchRemove(wakeup.id) orelse return error.InvalidHistory;
            if (registration.value != .wakeup) return error.InvalidHistory;
        }
        var channel_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer channel_ids.deinit(a);
        for (self.channels) |channel| {
            const sequence = contracts.Reference.sequence(channel.id) orelse return error.InvalidHistory;
            const opener = contracts.Reference.sequence(channel.opened_by) orelse return error.InvalidHistory;
            // The opening focus can have ended; the registration outlives it.
            if (sequence >= self.next_runtime_reference_id or opener >= self.next_session_id) return error.InvalidHistory;
            if (identities.get(opener)) |owner| {
                if (!std.mem.eql(u8, owner, channel.opened_by)) return error.InvalidHistory;
            }
            if ((try channel_ids.getOrPut(a, sequence)).found_existing) return error.InvalidHistory;
        }
    }
};

/// Each session selects the committed prefix of its current epoch's group.
const Checkpoint = struct {
    subscription_catalog: [32]u8,
    usage_scope: ?[32]u8 = null,
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
        progress: History.Progress = .{},
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
        const checkpoint = try Codec.decode(Checkpoint, a, document);
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
                .progress = session.progress,
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
            .usage_scope = checkpoint.usage_scope,
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
        // Startup must publish the restored checkpoint even if the document is
        // unchanged. A delayed retirement can still target the restored copy.
        self.published_checkpoint_digest = null;
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
            const count = readBatchCount(selections[offset..]);
            const batch = selections[offset..][0..count];
            var references: [source_batch_count]Store.Reference = undefined;
            for (batch, references[0..count]) |selected, *reference| reference.* = selected.reference;
            const temporary = scratch.allocator();
            const bodies = try self.store.read(temporary, references[0..count]);
            for (batch, bodies) |selected, body| {
                if (!equalKey(Codec.digest(body), selected.reference.key)) return error.InvalidHistory;
                const source = try Codec.decode(Source, temporary, body);
                switch (source) {
                    .entry => |entry| {
                        if (!equalPrevious(entry.previous, selected.reference.previous)) return error.InvalidHistory;
                        switch (selected.destination) {
                            .entry => |destination| destination.* = try restoreEntry(a, temporary, entry.value),
                            else => return error.InvalidHistory,
                        }
                    },
                    .observations => |events| {
                        if (events.len == 0 or selected.reference.previous != null) return error.InvalidHistory;
                        switch (selected.destination) {
                            .observations => |destination| destination.* = try Input.cloneEvents(a, events),
                            else => return error.InvalidHistory,
                        }
                    },
                }
            }
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
    }

    /// Write new records before publishing the checkpoint that selects them.
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
                .progress = session.progress,
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
            .usage_scope = history.usage_scope,
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
        try self.store.save(document);
        std.mem.swap(Cache, &self.cache, &candidate);
        self.published_checkpoint_digest = candidate_digest;
    }

    /// Retain confirmed session records together with the caller's unread reports.
    pub fn maintain(self: *Persistence, a: Allocator, extra: []const Store.RecordId) !void {
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

/// Give one record its full size, then group further records while their
/// estimated sizes keep temporary decoding work bounded.
fn readBatchCount(selections: []const Selection) usize {
    var count: usize = 1;
    var bytes = selections[0].reference.stored_bytes;
    while (count < @min(source_batch_count, selections.len) and bytes < source_batch_bytes) : (count += 1) {
        const size = selections[count].reference.stored_bytes;
        if (size > source_batch_bytes - bytes) break;
        bytes += size;
    }
    return count;
}

fn select(a: Allocator, selections: *std.ArrayList(Selection), reference: Store.Reference, destination: Selection.Destination) !void {
    try selections.append(a, .{
        .reference = .{
            .group = try a.dupe(u8, reference.group),
            .key = reference.key,
            .previous = reference.previous,
            .locator = try a.dupe(u8, reference.locator),
            .stored_bytes = reference.stored_bytes,
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
        const a = self.encoding.allocator();
        const body = try Codec.encode(a, Source{ .entry = .{ .previous = previous, .value = try storeEntry(a, value) } });
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

test "history reads group small records and fetch large records alone" {
    const small: Selection = .{
        .reference = .{ .group = "group", .key = @splat(0), .previous = null, .locator = "record", .stored_bytes = source_batch_bytes / 2 },
        .destination = undefined,
    };
    var large = small;
    large.reference.stored_bytes = source_batch_bytes + 1;
    try std.testing.expectEqual(2, readBatchCount(&.{ small, small, large }));
    try std.testing.expectEqual(1, readBatchCount(&.{ small, large }));
    try std.testing.expectEqual(1, readBatchCount(&.{ large, small }));
}

test "forking history rewrites legacy files and raw images" {
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
    const exchange = try std.mem.concat(a, u8, &.{
        ".{.entry=.{.previous=", try Codec.encode(a, key),
        \\, .value = .{ .exchange = .{
        \\    .{ .tool_result = .{ .call_id = "read-file", .content = .{ .parts = .{
        \\        .{ .text = "file:///source.pdf" },
        \\        .{ .file = .{ .bytes = "Original PDF bytes\x00\xff", .reference = "file-123" } },
        \\        .{ .image = .{ .data = .{ .format = .png, .bytes = "\x00\xff\x89\"\\\n" } } },
        \\        .{ .image = .{ .url = "https://example.test/image.png" } },
        \\    } } } }
        \\} } } }
        ,
    });
    const exchange_key = Codec.digest(exchange);
    try persistence.store.create(a, &.{
        .{ .group = group, .key = key, .previous = null, .body = body },
        .{ .group = group, .key = exchange_key, .previous = key, .body = exchange },
    });
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
            .head = exchange_key,
            .count = 2,
            .observations = null,
        }},
        .wakeups = &.{},
        .callbacks = &.{},
        .activity_reports = null,
    }));

    var history = (try persistence.load(a, 1)).?;
    try t.expectEqual(7, history.next_runtime_reference_id);
    try t.expectEqual(0, history.channels.len);
    try t.expectEqual(null, history.usage_scope);
    var core = history.sessions[0];
    try t.expectEqualDeep(History.Progress{}, core.progress);
    const handover = core.entries.?[0].record.handover;
    try t.expectEqualStrings("Keep investigating.", handover.summary);
    try t.expectEqualStrings("watch-1", handover.state.subscription_registrations[0].subscription_id);
    try t.expectEqual(null, handover.state.subscription_registrations[0].listener);
    const parts = core.entries.?[1].exchange[0].tool_result.content.parts;
    try t.expectEqualStrings("file:///source.pdf", parts[0].text);
    try t.expectEqualStrings("file-123", parts[1].file_reference);
    try t.expectEqual(.png, parts[2].image.data.format);
    try t.expectEqualSlices(u8, &.{ 0, 0xff, 0x89, '"', '\\', '\n' }, parts[2].image.data.bytes);
    try t.expectEqualStrings("https://example.test/image.png", parts[3].image.url);
    const fork: History.Session = .{
        .session_id = 2,
        .focus_id = "review-2",
        .role = .activity,
        .was_running = false,
        .subscription_through = 0,
        .epoch = 0,
        .entries = core.entries,
        .observations = &.{},
    };
    const next: Entry = .{ .exchange = &.{.{ .continuation = "Continuing." }} };
    core.entries = try std.mem.concat(a, Entry, &.{ core.entries.?, &.{next} });
    history.next_session_id = 3;
    history.sessions = &.{ core, fork };
    const confirmed = store.records.items.len;
    try persistence.save(a, history);

    // The fork writes new records using the current format.
    const added = store.records.items[confirmed..];
    try t.expectEqual(fork.entries.?.len + 1, added.len);
    for (added) |record| {
        if (std.mem.eql(u8, group, record.group)) try t.expectEqual(exchange_key, record.previous.?);
        try t.expect(std.mem.indexOf(u8, record.body, "Original PDF bytes") == null);
    }
    const fork_exchange = try Codec.decode(Source, a, added[2].body);
    const stored_parts = fork_exchange.entry.value.exchange[0].tool_result.content.parts;
    try t.expectEqualStrings("AP+JIlwK", stored_parts[2].image.base64.encoded);
    const continued = (try persistence.load(a, 2)).?.sessions;
    try t.expectEqualDeep(core.entries.?, continued[0].entries.?);
    try t.expectEqualDeep(fork.entries.?, continued[1].entries.?);
}

test "earlier channel registrations can omit descriptions" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const registration = try Codec.decode(History.Channel, a, ".{.id=\"imports-2\",.opened_by=\"core-1\",.opened_at_unix_ms=0}");
    try t.expectEqual(null, registration.description);
}

test "channel opener validation allows ended focuses and checks retained identities" {
    const t = std.testing;
    var channels = [_]History.Channel{.{
        .id = "imports-1",
        .opened_by = "core-1",
        .opened_at_unix_ms = 0,
    }};
    const history: History = .{
        .subscription_catalog = @splat(0),
        .next_session_id = 3,
        .next_callback_id = 1,
        .next_runtime_reference_id = 2,
        .sessions = &.{.{
            .session_id = 1,
            .focus_id = "core-1",
            .role = .core,
            .was_running = false,
            .subscription_through = 0,
            .epoch = 0,
            .entries = &.{},
            .observations = &.{},
        }},
        .wakeups = &.{},
        .callbacks = &.{},
        .channels = &channels,
        .activity_reports = null,
    };
    try history.validate(t.allocator);
    channels[0].opened_by = "other-1";
    try t.expectError(error.InvalidHistory, history.validate(t.allocator));
    channels[0].opened_by = "finished-2";
    try history.validate(t.allocator);
    channels[0].opened_by = "unissued-3";
    try t.expectError(error.InvalidHistory, history.validate(t.allocator));
}

const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;
const Locations = std.StringHashMapUnmanaged([]const u8);
const source_batch_count = 32;
const source_batch_bytes = 1024 * 1024;

/// Retained context entries from which Context builds its model-message sequence.
pub const Entry = union(enum) {
    record: Input.Record,
    exchange: []const contracts.Model.Item,
};

/// Immutable payloads. Event grouping and session membership live in the
/// manifest, so a queued event keeps its identity when admitted or inherited.
const Source = union(enum) {
    event: Input.Event,
    exchange: []const contracts.Model.Item,
    handover: Input.Handover,
};

pub const History = struct {
    next_session_id: u64,
    sessions: []const Session,

    pub const Session = struct {
        session_id: u64,
        parent_session_id: ?u64,
        parent_generation: ?u64,
        generation: u64,
        entries: []const Entry,
        observations: []const Input.Event,
    };

    fn validate(self: History, a: Allocator) !void {
        if (self.sessions.len == 0) return error.InvalidHistory;
        var generations: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer generations.deinit(a);
        for (self.sessions) |session| {
            if (session.session_id == 0 or session.session_id >= self.next_session_id) return error.InvalidHistory;
            const result = try generations.getOrPut(a, session.session_id);
            if (result.found_existing) return error.InvalidHistory;
            result.value_ptr.* = session.generation;
        }
        var cores: usize = 0;
        for (self.sessions) |session| {
            for (session.observations) |event| switch (event) {
                .assignment, .report => {},
                else => return error.InvalidHistory,
            };
            if (session.parent_session_id) |parent_id| {
                if (parent_id >= session.session_id or session.parent_generation == null) return error.InvalidHistory;
                const generation = generations.get(parent_id) orelse return error.InvalidHistory;
                if (session.parent_generation.? > generation) return error.InvalidHistory;
            } else {
                if (session.session_id != 1 or session.parent_generation != null) return error.InvalidHistory;
                cores += 1;
            }
        }
        if (cores != 1) return error.InvalidHistory;
    }
};

const Reference = union(enum) {
    record: struct {
        session_id: u64,
        events: []const usize,
        handover: ?usize,
    },
    exchange: usize,
};

const SourceReference = struct {
    key: []const u8,
    locator: []const u8,
};

/// References for retained histories, unread internal events, and session relationships.
const Manifest = struct {
    next_session_id: u64,
    sources: []const SourceReference,
    sessions: []const Session,

    const Session = struct {
        session_id: u64,
        parent_session_id: ?u64,
        parent_generation: ?u64,
        generation: u64,
        history: []const Reference,
        observations: []const usize,
    };
};

pub const Persistence = struct {
    allocator: Allocator,
    store: contracts.HistoryStore,
    /// Only sources in the last published active manifest; no all-time RAM index.
    known: Locations = .empty,

    pub fn init(allocator: Allocator, store: contracts.HistoryStore) Persistence {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn deinit(self: *Persistence) void {
        self.freeLocations(&self.known);
        self.* = undefined;
    }

    pub fn load(self: *Persistence, a: Allocator, max_contexts: usize) !?History {
        const data = try self.store.load(a) orelse {
            self.freeLocations(&self.known);
            self.known = .empty;
            return null;
        };
        const manifest = try decode(Manifest, a, data);
        if (manifest.sessions.len > max_contexts) return error.AttentionCapacityUnavailable;
        var unique: std.StringHashMapUnmanaged(void) = .empty;
        defer unique.deinit(a);
        for (manifest.sources) |reference| {
            if (reference.key.len != 64 or reference.locator.len == 0) return error.InvalidHistory;
            for (reference.key) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidHistory;
            const result = try unique.getOrPut(a, reference.key);
            if (result.found_existing) return error.InvalidHistory;
        }
        const sources = try a.alloc(Source, manifest.sources.len);
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        var offset: usize = 0;
        while (offset < manifest.sources.len) {
            const count = @min(source_batch_count, manifest.sources.len - offset);
            const references = manifest.sources[offset..][0..count];
            var locators: [source_batch_count][]const u8 = undefined;
            for (references, locators[0..count]) |reference, *locator| locator.* = reference.locator;
            const bodies = try self.store.read(scratch.allocator(), locators[0..count]);
            if (bodies.len != count) return error.InvalidHistory;
            for (references, bodies) |reference, body| {
                const actual = digest(body);
                if (!std.mem.eql(u8, reference.key, &actual)) return error.InvalidHistory;
            }
            for (bodies, sources[offset..][0..count]) |body, *source| source.* = try decode(Source, a, body);
            _ = scratch.reset(.retain_capacity);
            offset += count;
        }
        const sessions = try a.alloc(History.Session, manifest.sessions.len);
        for (manifest.sessions, sessions) |session, *restored| {
            const entries = try a.alloc(Entry, session.history.len);
            for (session.history, entries) |reference, *entry| entry.* = switch (reference) {
                .record => |record| blk: {
                    const events = try a.alloc(Input.Event, record.events.len);
                    for (record.events, events) |index, *event| {
                        const source = try sourceAt(sources, index);
                        if (source != .event) return error.InvalidHistory;
                        event.* = source.event;
                    }
                    const handover: ?Input.Handover = if (record.handover) |index| handover: {
                        const source = try sourceAt(sources, index);
                        if (source != .handover) return error.InvalidHistory;
                        break :handover source.handover;
                    } else null;
                    break :blk .{ .record = .{ .session_id = record.session_id, .events = events, .handover = handover } };
                },
                .exchange => |index| blk: {
                    const source = try sourceAt(sources, index);
                    if (source != .exchange) return error.InvalidHistory;
                    break :blk .{ .exchange = source.exchange };
                },
            };
            const observations = try a.alloc(Input.Event, session.observations.len);
            for (session.observations, observations) |index, *event| {
                const source = try sourceAt(sources, index);
                if (source != .event) return error.InvalidHistory;
                event.* = source.event;
            }
            restored.* = .{
                .session_id = session.session_id,
                .parent_session_id = session.parent_session_id,
                .parent_generation = session.parent_generation,
                .generation = session.generation,
                .entries = entries,
                .observations = observations,
            };
        }
        const history: History = .{ .next_session_id = manifest.next_session_id, .sessions = sessions };
        try history.validate(a);
        var current = try self.copyLocations(manifest.sources);
        errdefer self.freeLocations(&current);
        self.freeLocations(&self.known);
        self.known = current;
        return history;
    }

    pub fn save(self: *Persistence, a: Allocator, history: History) !void {
        var builder: SourceBuilder = .init(self, a);
        defer builder.deinit();
        const sessions = try a.alloc(Manifest.Session, history.sessions.len);
        for (history.sessions, sessions) |session, *saved| {
            const references = try a.alloc(Reference, session.entries.len);
            for (session.entries, references) |entry, *reference| reference.* = switch (entry) {
                .record => |record| blk: {
                    const events = try a.alloc(usize, record.events.len);
                    for (record.events, events) |event, *index| index.* = try builder.add(.{ .event = event });
                    break :blk .{ .record = .{
                        .session_id = record.session_id,
                        .events = events,
                        .handover = if (record.handover) |handover| try builder.add(.{ .handover = handover }) else null,
                    } };
                },
                .exchange => |items| .{ .exchange = try builder.add(.{ .exchange = items }) },
            };
            const observations = try a.alloc(usize, session.observations.len);
            for (session.observations, observations) |event, *index| index.* = try builder.add(.{ .event = event });
            saved.* = .{
                .session_id = session.session_id,
                .parent_session_id = session.parent_session_id,
                .parent_generation = session.parent_generation,
                .generation = session.generation,
                .history = references,
                .observations = observations,
            };
        }
        try builder.flush();
        var current = try self.copyLocations(builder.sources.items);
        errdefer self.freeLocations(&current);
        // Every referenced source has been confirmed before this publication.
        try self.store.save(try encode(a, Manifest{ .next_session_id = history.next_session_id, .sources = builder.sources.items, .sessions = sessions }));
        self.freeLocations(&self.known);
        self.known = current;
    }

    fn copyLocations(self: *Persistence, sources: []const SourceReference) !Locations {
        var locations: Locations = .empty;
        errdefer self.freeLocations(&locations);
        for (sources) |source| {
            const key = try self.allocator.dupe(u8, source.key);
            errdefer self.allocator.free(key);
            const locator = try self.allocator.dupe(u8, source.locator);
            errdefer self.allocator.free(locator);
            try locations.put(self.allocator, key, locator);
        }
        return locations;
    }

    fn freeLocations(self: *Persistence, locations: *Locations) void {
        var iterator = locations.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        locations.deinit(self.allocator);
    }
};

/// Builds one manifest source table while retaining only a bounded batch of new
/// bodies. Encoding known or repeated sources uses separate per-source scratch.
const SourceBuilder = struct {
    persistence: *Persistence,
    allocator: Allocator,
    indices: std.StringHashMapUnmanaged(usize) = .empty,
    sources: std.ArrayList(SourceReference) = .empty,
    encoding: std.heap.ArenaAllocator,
    batch: std.heap.ArenaAllocator,
    bodies: [source_batch_count][]const u8 = undefined,
    pending_indices: [source_batch_count]usize = undefined,
    count: usize = 0,
    bytes: usize = 0,

    fn init(persistence: *Persistence, a: Allocator) SourceBuilder {
        return .{
            .persistence = persistence,
            .allocator = a,
            .encoding = .init(persistence.allocator),
            .batch = .init(persistence.allocator),
        };
    }

    fn deinit(self: *SourceBuilder) void {
        self.indices.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.encoding.deinit();
        self.batch.deinit();
    }

    fn add(self: *SourceBuilder, source: Source) !usize {
        defer _ = self.encoding.reset(.retain_capacity);
        const data = try encode(self.encoding.allocator(), source);
        const key = digest(data);
        if (self.indices.get(&key)) |index| return index;
        const known = self.persistence.known.get(&key);
        if (known == null and self.count > 0 and
            (self.count == source_batch_count or data.len > source_batch_bytes - self.bytes))
            try self.flush();
        const index = self.sources.items.len;
        const owned_key = try self.allocator.dupe(u8, &key);
        const locator = if (known) |stored| try self.allocator.dupe(u8, stored) else "";
        try self.sources.append(self.allocator, .{ .key = owned_key, .locator = locator });
        try self.indices.put(self.allocator, owned_key, index);
        if (known == null) {
            self.bodies[self.count] = try self.batch.allocator().dupe(u8, data);
            self.pending_indices[self.count] = index;
            self.count += 1;
            self.bytes += data.len;
            // A single source can exceed the target batch size. Storage owns
            // whether its native protocol can represent that complete source.
            if (self.bytes >= source_batch_bytes) try self.flush();
        }
        return index;
    }

    fn flush(self: *SourceBuilder) !void {
        if (self.count == 0) return;
        const locators = try self.persistence.store.create(self.batch.allocator(), self.bodies[0..self.count]);
        if (locators.len != self.count) return error.InvalidHistory;
        for (self.pending_indices[0..self.count], locators) |index, locator| {
            if (locator.len == 0) return error.InvalidHistory;
            self.sources.items[index].locator = try self.allocator.dupe(u8, locator);
        }
        self.count = 0;
        self.bytes = 0;
        _ = self.batch.reset(.retain_capacity);
    }
};

fn sourceAt(sources: []const Source, index: usize) !Source {
    if (index >= sources.len) return error.InvalidHistory;
    return sources[index];
}

fn digest(data: []const u8) [64]u8 {
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

const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;
const Keys = std.StringHashMapUnmanaged(void);

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

    fn validate(self: History) !void {
        if (self.sessions.len == 0) return error.InvalidHistory;
        var cores: usize = 0;
        for (self.sessions, 0..) |session, i| {
            if (session.session_id == 0 or session.session_id >= self.next_session_id) return error.InvalidHistory;
            for (self.sessions[0..i]) |earlier| if (earlier.session_id == session.session_id) return error.InvalidHistory;
            for (session.observations) |event| switch (event) {
                .assignment, .report => {},
                else => return error.InvalidHistory,
            };
            if (session.parent_session_id) |parent_id| {
                if (parent_id >= session.session_id or session.parent_generation == null) return error.InvalidHistory;
                const parent = for (self.sessions) |candidate| {
                    if (candidate.session_id == parent_id) break candidate;
                } else return error.InvalidHistory;
                if (session.parent_generation.? > parent.generation) return error.InvalidHistory;
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
        events: []const []const u8,
        handover: ?[]const u8,
    },
    exchange: []const u8,
};

/// References for retained histories, unread internal events, and session relationships.
const Manifest = struct {
    next_session_id: u64,
    sessions: []const Session,

    const Session = struct {
        session_id: u64,
        parent_session_id: ?u64,
        parent_generation: ?u64,
        generation: u64,
        history: []const Reference,
        observations: []const []const u8,
    };
};

pub const Persistence = struct {
    allocator: Allocator,
    store: contracts.HistoryStore,
    /// Only keys in the last published active manifest; no all-time RAM index.
    known: Keys = .empty,

    pub fn init(allocator: Allocator, store: contracts.HistoryStore) Persistence {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn deinit(self: *Persistence) void {
        self.freeKeys(&self.known);
        self.* = undefined;
    }

    pub fn load(self: *Persistence, a: Allocator, max_contexts: usize) !?History {
        const data = try self.store.load(a) orelse return null;
        const manifest = try decode(Manifest, a, data);
        if (manifest.sessions.len > max_contexts) return error.AttentionCapacityUnavailable;
        var cache: std.StringHashMapUnmanaged(Source) = .empty;
        const sessions = try a.alloc(History.Session, manifest.sessions.len);
        for (manifest.sessions, sessions) |session, *restored| {
            const entries = try a.alloc(Entry, session.history.len);
            for (session.history, entries) |reference, *entry| entry.* = switch (reference) {
                .record => |record| blk: {
                    const events = try a.alloc(Input.Event, record.events.len);
                    for (record.events, events) |key, *event| {
                        const source = try self.read(a, &cache, key);
                        if (source != .event) return error.InvalidHistory;
                        event.* = source.event;
                    }
                    const handover: ?Input.Handover = if (record.handover) |key| handover: {
                        const source = try self.read(a, &cache, key);
                        if (source != .handover) return error.InvalidHistory;
                        break :handover source.handover;
                    } else null;
                    break :blk .{ .record = .{ .session_id = record.session_id, .events = events, .handover = handover } };
                },
                .exchange => |key| blk: {
                    const source = try self.read(a, &cache, key);
                    if (source != .exchange) return error.InvalidHistory;
                    break :blk .{ .exchange = source.exchange };
                },
            };
            const observations = try a.alloc(Input.Event, session.observations.len);
            for (session.observations, observations) |key, *event| {
                const source = try self.read(a, &cache, key);
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
        try history.validate();
        return history;
    }

    pub fn save(self: *Persistence, a: Allocator, history: History) !void {
        var current: Keys = .empty;
        errdefer self.freeKeys(&current);
        const sessions = try a.alloc(Manifest.Session, history.sessions.len);
        for (history.sessions, sessions) |session, *saved| {
            const references = try a.alloc(Reference, session.entries.len);
            for (session.entries, references) |entry, *reference| reference.* = switch (entry) {
                .record => |record| blk: {
                    const events = try a.alloc([]const u8, record.events.len);
                    for (record.events, events) |event, *key| key.* = try self.put(a, &current, .{ .event = event });
                    break :blk .{ .record = .{
                        .session_id = record.session_id,
                        .events = events,
                        .handover = if (record.handover) |handover| try self.put(a, &current, .{ .handover = handover }) else null,
                    } };
                },
                .exchange => |items| .{ .exchange = try self.put(a, &current, .{ .exchange = items }) },
            };
            const observations = try a.alloc([]const u8, session.observations.len);
            for (session.observations, observations) |event, *key| key.* = try self.put(a, &current, .{ .event = event });
            saved.* = .{
                .session_id = session.session_id,
                .parent_session_id = session.parent_session_id,
                .parent_generation = session.parent_generation,
                .generation = session.generation,
                .history = references,
                .observations = observations,
            };
        }
        // Every referenced source has been confirmed before this publication.
        try self.store.save(try encode(a, Manifest{ .next_session_id = history.next_session_id, .sessions = sessions }));
        self.freeKeys(&self.known);
        self.known = current;
    }

    fn read(self: *Persistence, a: Allocator, cache: *std.StringHashMapUnmanaged(Source), key: []const u8) !Source {
        if (cache.get(key)) |source| return source;
        if (key.len != 64) return error.InvalidHistory;
        for (key) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidHistory;
        const data = try self.store.read(a, key);
        const actual = digest(data);
        if (!std.mem.eql(u8, key, &actual)) return error.InvalidHistory;
        const source = try decode(Source, a, data);
        try cache.put(a, key, source);
        try self.remember(&self.known, key);
        return source;
    }

    fn put(self: *Persistence, a: Allocator, current: *Keys, source: Source) ![]const u8 {
        const data = try encode(a, source);
        const key = try a.dupe(u8, &digest(data));
        if (!self.known.contains(key) and !current.contains(key)) try self.store.put(key, data);
        try self.remember(current, key);
        return key;
    }

    fn remember(self: *Persistence, keys: *Keys, key: []const u8) !void {
        if (keys.contains(key)) return;
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try keys.put(self.allocator, owned, {});
    }

    fn freeKeys(self: *Persistence, keys: *Keys) void {
        var iterator = keys.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        keys.deinit(self.allocator);
    }
};

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

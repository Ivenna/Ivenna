//! Encode session records and decode them into the current working history types.

const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("../input.zig");
const Codec = @import("../record_codec.zig");
const Allocator = std.mem.Allocator;
const Model = contracts.Model;
const Key = contracts.HistoryStore.Key;

pub const Entry = union(enum) {
    record: Input.Record,
    exchange: []const Model.Item,
};

const Source = union(enum) {
    entry: struct { previous: ?Key, value: StoredEntry },
    observations: []const Input.Event,
};

pub fn decodeEntry(a: Allocator, temporary: Allocator, previous: ?Key, body: []const u8) !Entry {
    const source = try Codec.decode(Source, temporary, body);
    if (source != .entry or !std.meta.eql(source.entry.previous, previous)) return error.InvalidHistory;
    return restoreEntry(a, temporary, source.entry.value);
}

pub fn decodeObservations(a: Allocator, temporary: Allocator, body: []const u8) ![]const Input.Event {
    const source = try Codec.decode(Source, temporary, body);
    if (source != .observations or source.observations.len == 0) return error.InvalidHistory;
    return Input.cloneEvents(a, source.observations);
}

pub fn encodeEntry(a: Allocator, previous: ?Key, entry: Entry) ![]const u8 {
    return Codec.encode(a, Source{ .entry = .{ .previous = previous, .value = try storeEntry(a, entry) } });
}

pub fn encodeObservations(a: Allocator, events: []const Input.Event) ![]const u8 {
    return Codec.encode(a, Source{ .observations = events });
}

const StoredEntry = union(enum) {
    record: StoredRecord,
    exchange: []const Item,

    const Item = union(enum) {
        message: @FieldType(Model.Item, "message"),
        continuation: []const u8,
        tool_result: struct { call_id: []const u8, content: struct { parts: []const StoredPart } },
    };
};

const StoredRecord = union(enum) {
    events: Input.EventGroup,
    continuity: Input.Continuity,
    handover: struct {
        focus_id: []const u8,
        observed_at_unix_ms: i64,
        summary: []const u8,
        state: LegacyState,
    },
};

const LegacyState = struct {
    activities: []const []const u8,
    callbacks: []const Input.PendingCallback,
    subscription_registrations: []const Input.SampledSubscription = &.{},
    channel_registrations: []const Input.SampledChannel = &.{},
    correspondents: ?[]const []const u8 = null,
    subscriptions: []const []const u8 = &.{},
    channels: []const []const u8 = &.{},
    feeds: []const []const u8 = &.{},

    fn restore(self: LegacyState, a: Allocator) !Input.State {
        var state: Input.State = .{
            .activities = self.activities,
            .callbacks = self.callbacks,
            .subscription_registrations = self.subscription_registrations,
            .channel_registrations = self.channel_registrations,
            .correspondents = self.correspondents,
        };
        if (state.subscription_registrations.len == 0 and self.subscriptions.len != 0) {
            const registrations = try a.alloc(Input.SampledSubscription, self.subscriptions.len);
            for (self.subscriptions, registrations) |id, *registration| registration.* = .{ .subscription_id = id };
            state.subscription_registrations = registrations;
        }
        if (state.channel_registrations.len == 0 and self.channels.len != 0) {
            const registrations = try a.alloc(Input.SampledChannel, self.channels.len);
            for (self.channels, registrations) |id, *registration| registration.* = .{ .channel_id = id };
            state.channel_registrations = registrations;
        }
        return state;
    }
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
    if (entry == .record) return .{ .record = switch (entry.record) {
        .events => |events| .{ .events = events },
        .continuity => |continuity| .{ .continuity = continuity },
    } };
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
        const record: Input.Record = switch (value.record) {
            .events => |events| .{ .events = events },
            .continuity => |continuity| .{ .continuity = continuity },
            .handover => |legacy| .{ .continuity = .{
                .focus_id = legacy.focus_id,
                .observed_at_unix_ms = legacy.observed_at_unix_ms,
                .text = legacy.summary,
                .state = try legacy.state.restore(temporary),
            } },
        };
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

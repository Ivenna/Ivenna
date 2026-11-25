const std = @import("std");
const Jmap = @import("jmap.zig").Jmap;
const HistoryStore = @import("agent_contracts").HistoryStore;
const Callback = @import("agent_contracts").Callback;
const Inbox = @import("agent_contracts").Inbox;
const Addressing = @import("addressing.zig").Addressing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Address = struct {
    email: []const u8,
};

/// All returned text and arrays belong to the operation's allocator.
pub const Letter = struct {
    id: []const u8,
    from: []const Address,
    subject: []const u8,
    body: []const u8,
};

/// The mail boundary distinguishes private callback records from correspondence
/// before either reaches execution. Receipts remain native to this adapter.
pub const Arrival = struct {
    id: []const u8,
    content: union(enum) {
        message: Letter,
        callback: Callback.Message,
    },
};

pub const Outgoing = struct {
    recipient: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub const Checkpoint = struct {
    pub const State = enum { legacy, prepared, published };

    id: []const u8,
    revision: u64,
    state: State,
};

const handled_keyword = "ivenna-handled";
const outbound_keyword = "ivenna-outbound";
const state_keyword = "ivenna-state";
const current_keyword = "ivenna-current";
const prepared_keyword = "ivenna-prepared";
const callback_keyword = "ivenna-callback";
const callback_keyword_prefix = "ivenna-callback-";
const group_keyword_prefix = "ivenna-history-";
const history_mailbox_name = "Ivenna History";
const callback_mailbox_name = "Ivenna Callbacks";
const callback_property = "header:X-Ivenna-Callback-Id:asText";
const kind_property = "header:X-Ivenna-History-Kind:asText";
const revision_property = "header:X-Ivenna-History-Revision:asText";
const key_property = "header:X-Ivenna-History-Key:asText";
const previous_property = "header:X-Ivenna-History-Previous:asText";
const history_query_limit = 512;
const history_query_groups = 32;
const state_properties: []const []const u8 = &.{
    "id", "mailboxIds", "keywords", "from", "to", kind_property, revision_property, key_property, previous_property,
};
const state_data_properties: []const []const u8 = &.{
    "id", "mailboxIds", "keywords", "from", "to", kind_property, revision_property, key_property, previous_property, "textBody", "bodyValues",
};
const message_properties: []const []const u8 = &.{
    "id", "mailboxIds", "keywords", "receivedAt", "from", "to", "subject", callback_property, "textBody", "htmlBody", "bodyValues",
};
const correspondence_properties: []const []const u8 = &.{ "id", "mailboxIds", "from", "to", "keywords", callback_property };

const HistoryKind = enum { record, checkpoint };
const Retirement = struct {
    id: []const u8,
    marker: enum { none, clear_draft, handled } = .none,
};

/// JMAP access for communication records, submissions, and working history.
/// Discover once using an allocator that outlives every operation and worker.
pub const Mailbox = struct {
    jmap: *Jmap,
    session_url: []const u8,
    address: []const u8,
    addressing: Addressing,
    account_id: []const u8 = "",
    identity_id: []const u8 = "",
    drafts_id: []const u8 = "",
    history_id: []const u8 = "",
    callback_id: []const u8 = "",
    trash_id: []const u8 = "",
    junk_id: []const u8 = "",
    max_get: usize = 32,
    max_set: usize = 32,

    pub fn discover(self: *Mailbox, a: Allocator) !void {
        const session = try self.jmap.session(a, self.session_url);
        self.jmap.api_url = try textField(session, "apiUrl");
        self.account_id = try textField(try field(session, "primaryAccounts"), Jmap.mail_capability);
        const capabilities = try field(session, "capabilities");
        if (capabilities != .object or !capabilities.object.contains(Jmap.mail_capability) or
            !capabilities.object.contains(Jmap.submission_capability))
            return error.MailCapabilityUnavailable;
        const core = try field(capabilities, Jmap.core_capability);
        self.max_get = @min(try objectLimit(core, "maxObjectsInGet"), 32);
        self.max_set = @min(try objectLimit(core, "maxObjectsInSet"), 32);
        self.jmap.max_request = try objectLimit(core, "maxSizeRequest");
        const identities = try self.jmap.call(a, .@"Identity/get", .{ .accountId = self.account_id });
        for (try arrayField(identities, "list")) |identity| {
            if (self.addressing.isSelf(try textField(identity, "email"))) {
                self.identity_id = try textField(identity, "id");
                break;
            }
        }
        if (self.identity_id.len == 0) return error.MailIdentityNotFound;

        const list = try self.listFolders(a);
        self.drafts_id = try folderId(list, .{ .role = "drafts" }) orelse return error.MailFoldersNotFound;
        self.junk_id = try folderId(list, .{ .role = "junk" }) orelse "";
        self.history_id = try self.ensureFolder(a, list, history_mailbox_name, null);
        self.callback_id = try self.ensureFolder(a, list, callback_mailbox_name, null);
        self.trash_id = try self.ensureFolder(a, list, "Trash", "trash");
    }

    fn listFolders(self: Mailbox, a: Allocator) ![]const Value {
        const reply = try self.jmap.call(a, .@"Mailbox/get", .{
            .accountId = self.account_id,
            .properties = &[_][]const u8{ "id", "name", "parentId", "role" },
        });
        return arrayField(reply, "list");
    }

    const FolderSelector = union(enum) { role: []const u8, top_level_name: []const u8 };

    fn folderId(list: []const Value, selector: FolderSelector) !?[]const u8 {
        for (list) |item| {
            const role = optionalText(item, "role");
            const matches = switch (selector) {
                .role => |wanted| std.mem.eql(u8, role orelse continue, wanted),
                .top_level_name => |name| role == null and optionalText(item, "parentId") == null and
                    std.mem.eql(u8, try textField(item, "name"), name),
            };
            if (matches) return try textField(item, "id");
        }
        return null;
    }

    fn ensureFolder(self: Mailbox, a: Allocator, list: []const Value, name: []const u8, role: ?[]const u8) ![]const u8 {
        const selector: FolderSelector = if (role) |r| .{ .role = r } else .{ .top_level_name = name };
        if (try folderId(list, selector)) |id| return id;
        return self.createFolder(a, name, role) catch |err| switch (err) {
            error.MailMutationUnconfirmed => try folderId(try self.listFolders(a), selector) orelse err,
            else => err,
        };
    }

    fn createFolder(self: Mailbox, a: Allocator, name: []const u8, role: ?[]const u8) ![]const u8 {
        const reply = try self.jmap.call(a, .@"Mailbox/set", .{
            .accountId = self.account_id,
            .create = .{ .folder = .{ .name = name, .parentId = null, .role = role } },
        });
        return createdId(reply, "folder");
    }

    const IntakeKind = enum { message, callback };

    const OrderedArrival = struct {
        arrival: Arrival,
        received_at: []const u8,

        fn lessThan(_: void, left: OrderedArrival, right: OrderedArrival) bool {
            return std.mem.lessThan(u8, left.received_at, right.received_at);
        }
    };

    /// Each stream contributes its own eligible prefix. Merge the selected
    /// records by native reception time without discarding either allocation.
    pub fn pending(self: Mailbox, a: Allocator, request: Inbox.Poll) ![]const Arrival {
        var selected: std.ArrayList(OrderedArrival) = .empty;
        defer selected.deinit(a);
        try self.collectPending(a, .message, request.messages, &selected);
        try self.collectPending(a, .callback, request.callbacks, &selected);
        std.mem.sort(OrderedArrival, selected.items, {}, OrderedArrival.lessThan);
        const arrivals = try a.alloc(Arrival, selected.items.len);
        for (selected.items, arrivals) |item, *arrival| arrival.* = item.arrival;
        return arrivals;
    }

    fn collectPending(self: Mailbox, a: Allocator, kind: IntakeKind, limit: usize, arrivals: *std.ArrayList(OrderedArrival)) !void {
        if (limit == 0) return;
        const filter = try self.pendingFilter(a, kind);
        var accepted: usize = 0;
        var position: usize = 0;
        while (accepted < limit) {
            const ids = try self.queryIds(a, filter, true, position, limit - accepted);
            if (ids.len == 0) break;
            for (try self.getRecords(a, ids, true)) |record| {
                const arrival = try self.decodePending(a, kind, record) orelse continue;
                try arrivals.append(a, .{
                    .arrival = arrival,
                    .received_at = try receptionKey(record),
                });
                accepted += 1;
            }
            position += ids.len;
        }
    }

    fn decodePending(self: Mailbox, a: Allocator, kind: IntakeKind, record: Value) !?Arrival {
        return switch (kind) {
            .callback => blk: {
                const callback = self.decodeCallback(a, record) catch |err| switch (err) {
                    error.InvalidCallback => {
                        std.log.warn("mail {s} has no valid complete callback", .{try textField(record, "id")});
                        return null;
                    },
                    else => return err,
                };
                break :blk .{ .id = try textField(record, "id"), .content = .{ .callback = callback } };
            },
            .message => blk: {
                const keywords = try field(record, "keywords");
                const folders = try field(record, "mailboxIds");
                if (boolean(keywords, callback_keyword) or boolean(folders, self.callback_id)) return null;
                const letter = decode(a, record) catch |err| switch (err) {
                    error.MailBodyUnavailable => {
                        std.log.warn("mail {s} has no complete supported body", .{try textField(record, "id")});
                        return null;
                    },
                    else => return err,
                };
                if (!self.isCorrespondence(letter)) return null;
                break :blk .{ .id = letter.id, .content = .{ .message = letter } };
            },
        };
    }

    /// Publish a private delivery record through JMAP, without SMTP submission.
    /// The caller serializes lookup and creation. A retry preserves the first
    /// stored result, including a copy already acknowledged into Trash. Body
    /// availability cannot justify replacing a result that already exists.
    pub fn publishCallback(self: Mailbox, a: Allocator, message: Callback.Message) !void {
        if (message.id == 0) return error.InvalidCallback;
        const index_keyword = try callbackKeyword(a, message.id);
        if (try self.hasCallback(a, message.id, index_keyword)) return;
        self.createCallback(a, message, index_keyword) catch |err| switch (err) {
            error.MailMutationUnconfirmed => {
                if (!try self.hasCallback(a, message.id, index_keyword)) return err;
            },
            else => return err,
        };
    }

    fn hasCallback(self: Mailbox, a: Allocator, id: u64, index_keyword: []const u8) !bool {
        const filter = try value(a, .{
            .operator = "AND",
            .conditions = .{
                .{ .hasKeyword = callback_keyword },
                .{ .hasKeyword = index_keyword },
            },
        });
        var position: usize = 0;
        while (true) {
            const ids = try self.queryIds(a, filter, true, position, self.max_get);
            if (ids.len == 0) break;
            for (try self.getRecords(a, ids, false)) |record| {
                const previous = self.callbackId(a, record) catch |err| switch (err) {
                    error.InvalidCallback => continue,
                    else => return err,
                };
                // The keyword locates candidates; the native header and its
                // matching index establish callback identity.
                if (previous == id) return true;
            }
            position += ids.len;
        }
        return false;
    }

    fn createCallback(self: Mailbox, a: Allocator, message: Callback.Message, index_keyword: []const u8) !void {
        const id_text = try std.fmt.allocPrint(a, "{d}", .{message.id});
        var folders: std.json.ObjectMap = .empty;
        try folders.put(a, self.callback_id, .{ .bool = true });
        var keywords: std.json.ObjectMap = .empty;
        try keywords.put(a, callback_keyword, .{ .bool = true });
        try keywords.put(a, index_keyword, .{ .bool = true });
        var record = try value(a, .{
            .mailboxIds = Value{ .object = folders },
            .keywords = Value{ .object = keywords },
            .from = &[_]Address{.{ .email = self.address }},
            .to = &[_]Address{.{ .email = self.address }},
            .subject = "Ivenna callback",
            .textBody = &.{.{ .partId = "text", .type = "text/plain" }},
            .bodyValues = .{ .text = .{ .value = message.text } },
        });
        try record.object.put(a, callback_property, .{ .string = id_text });
        const created = try self.jmap.call(a, .@"Email/set", .{
            .accountId = self.account_id,
            .create = .{ .callback = record },
        });
        _ = try createdId(created, "callback");
    }

    /// The caller has durably admitted this input into working history.
    pub fn acknowledge(self: Mailbox, a: Allocator, id: []const u8) !void {
        try self.retireEmails(a, &.{.{ .id = id, .marker = .handled }});
    }

    /// Retire acknowledged input and released outbound copies. The caller
    /// serializes this pass with submission so live drafts cannot be selected.
    pub fn maintainCorrespondence(self: Mailbox, a: Allocator) !void {
        var conditions: std.ArrayList(Value) = .empty;
        try conditions.append(a, try value(a, .{ .notKeyword = state_keyword }));
        try conditions.append(a, try value(a, .{
            .operator = "OR",
            .conditions = .{ .{ .hasKeyword = handled_keyword }, .{ .hasKeyword = outbound_keyword } },
        }));
        for ([_][]const u8{ self.history_id, self.trash_id, self.junk_id }) |id| {
            if (id.len == 0) continue;
            try conditions.append(a, try value(a, .{ .operator = "NOT", .conditions = &.{.{ .inMailbox = id }} }));
        }
        const filter = try value(a, .{ .operator = "AND", .conditions = conditions.items });
        var position: usize = 0;
        while (true) {
            var scratch = std.heap.ArenaAllocator.init(self.jmap.allocator());
            defer scratch.deinit();
            const temporary = scratch.allocator();
            const ids = try self.queryIds(temporary, filter, true, position, self.max_get);
            if (ids.len == 0) break;
            var retired: std.ArrayList(Retirement) = .empty;
            for (try self.getRecords(temporary, ids, false)) |record| {
                const keywords = try field(record, "keywords");
                if (!boolean(keywords, handled_keyword)) {
                    // An unfinished callback is a pending input, even if a
                    // malformed record also carries the outgoing marker.
                    const folders = try field(record, "mailboxIds");
                    if (boolean(keywords, callback_keyword) or boolean(folders, self.callback_id)) continue;
                    const from = try addresses(temporary, record, "from");
                    if (from.len != 1 or !self.addressing.isSelf(from[0].email)) continue;
                }
                try retired.append(temporary, .{ .id = try textField(record, "id"), .marker = .clear_draft });
            }
            try self.retireEmails(temporary, retired.items);
            position += ids.len - retired.items.len;
        }
    }

    fn trashPatch(self: Mailbox, a: Allocator, retirement: Retirement) !Value {
        var folders: std.json.ObjectMap = .empty;
        try folders.put(a, self.trash_id, .{ .bool = true });
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "mailboxIds", .{ .object = folders });
        if (retirement.marker != .none) try patch.put(a, "keywords/$draft", .null);
        switch (retirement.marker) {
            .none, .clear_draft => {},
            .handled => try patch.put(a, "keywords/" ++ handled_keyword, .{ .bool = true }),
        }
        return .{ .object = patch };
    }

    /// A prepared checkpoint keeps its marker after publication, so a delayed
    /// publication does not change which messages this query finds.
    pub fn historyCheckpoints(self: Mailbox, a: Allocator) ![]const Checkpoint {
        const filter = try value(a, .{
            .operator = "AND",
            .conditions = .{
                try self.historyFolderFilter(a),
                try value(a, .{ .hasKeyword = state_keyword }),
                try value(a, .{
                    .operator = "OR",
                    .conditions = .{ .{ .hasKeyword = prepared_keyword }, .{ .hasKeyword = current_keyword } },
                }),
            },
        });
        var records: std.ArrayList(Checkpoint) = .empty;
        var anchor: ?[]const u8 = null;
        defer if (anchor) |id| a.free(id);
        while (true) {
            var scratch: std.heap.ArenaAllocator = .init(self.jmap.allocator());
            defer scratch.deinit();
            const temporary = scratch.allocator();
            // A late Trash move can shift positions without changing the order
            // of the remaining candidates. Continue after the last ID seen.
            const result = try self.jmap.call(temporary, .@"Email/query", .{
                .accountId = self.account_id,
                .filter = filter,
                .anchor = anchor,
                .anchorOffset = 1,
                .limit = history_query_limit,
            });
            const ids = try strings(temporary, try field(result, "ids"));
            if (ids.len == 0) break;
            var offset: usize = 0;
            while (offset < ids.len) {
                const count = try self.historyGetCount(ids[offset..], false);
                for (try self.getHistoryRecords(temporary, ids[offset..][0..count], false)) |record| {
                    if (!try self.validateHistoryRecord(temporary, record, .checkpoint)) continue;
                    const keywords = try field(record, "keywords");
                    if (!boolean(keywords, prepared_keyword) and !boolean(keywords, current_keyword)) continue;
                    try records.append(a, .{
                        .id = try a.dupe(u8, try textField(record, "id")),
                        .revision = try checkpointRevision(record),
                        .state = checkpointState(keywords),
                    });
                }
                offset += count;
            }
            const next = try a.dupe(u8, ids[ids.len - 1]);
            if (anchor) |id| a.free(id);
            anchor = next;
        }
        return records.toOwnedSlice(a);
    }

    pub fn historyCheckpoint(self: Mailbox, a: Allocator, id: []const u8) ![]const u8 {
        var scratch: std.heap.ArenaAllocator = .init(self.jmap.allocator());
        defer scratch.deinit();
        const record = (try self.checkpointMessage(scratch.allocator(), id, true)) orelse return error.InvalidHistory;
        if (!boolean(try field(record, "keywords"), current_keyword)) return error.InvalidHistory;
        return a.dupe(u8, try historyBody(record));
    }

    fn checkpointMessage(self: Mailbox, a: Allocator, id: []const u8, body: bool) !?Value {
        const response = try self.jmap.call(a, .@"Email/get", self.historyGet(&.{id}, body));
        const records = try arrayField(response, "list");
        if (records.len == 0) return null;
        if (records.len != 1 or !std.mem.eql(u8, try textField(records[0], "id"), id)) return error.InvalidMailReply;
        const record = records[0];
        if (!try self.validateHistoryRecord(a, record, .checkpoint)) return null;
        return record;
    }

    pub fn allocateHistoryGroup(self: Mailbox, a: Allocator) ![]const u8 {
        var random: [16]u8 = undefined;
        try self.jmap.io().randomSecure(&random);
        const token = std.fmt.bytesToHex(random, .lower);
        return a.dupe(u8, &token);
    }

    /// Query native group membership without fetching historical bodies. Group
    /// filters and ID pages have their own bounds, independent of Email/get.
    pub fn queryHistory(self: Mailbox, a: Allocator, groups: []const []const u8) ![]const HistoryStore.Reference {
        var unique: std.StringHashMapUnmanaged(void) = .empty;
        defer unique.deinit(a);
        var requested: std.ArrayList([]const u8) = .empty;
        defer requested.deinit(a);
        for (groups) |group| {
            if (group.len != 32 or !isLowerHex(group)) return error.InvalidHistory;
            if (!(try unique.getOrPut(a, group)).found_existing) try requested.append(a, group);
        }
        var references: std.ArrayList(HistoryStore.Reference) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        var group_offset: usize = 0;
        while (group_offset < requested.items.len) {
            var query_arena: std.heap.ArenaAllocator = .init(self.jmap.allocator());
            defer query_arena.deinit();
            const query_allocator = query_arena.allocator();
            var count: usize = 0;
            var selected: Value = undefined;
            while (count < @min(history_query_groups, requested.items.len - group_offset)) {
                const candidate = try self.historyGroupFilter(query_allocator, requested.items[group_offset..][0 .. count + 1]);
                if (try Jmap.requestSize(.@"Email/query", self.historyQuery(candidate, std.math.maxInt(usize))) > self.jmap.max_request) break;
                selected = candidate;
                count += 1;
            }
            if (count == 0) return error.MailRequestTooLarge;
            const selected_groups = requested.items[group_offset..][0..count];
            var position: usize = 0;
            while (true) {
                var scratch: std.heap.ArenaAllocator = .init(self.jmap.allocator());
                defer scratch.deinit();
                const temporary = scratch.allocator();
                const ids = try self.historyQueryIds(temporary, selected, position);
                if (ids.len == 0) break;
                var offset: usize = 0;
                while (offset < ids.len) {
                    const batch_count = try self.historyGetCount(ids[offset..], false);
                    for (try self.getHistoryRecords(temporary, ids[offset..][0..batch_count], false)) |record| {
                        const reference = try self.historyReference(a, record);
                        const requested_group = for (selected_groups) |group| {
                            if (std.mem.eql(u8, group, reference.group)) break true;
                        } else false;
                        if (!requested_group or (try seen.getOrPut(a, reference.locator)).found_existing) return error.InvalidHistory;
                        try references.append(a, reference);
                    }
                    offset += batch_count;
                }
                position += ids.len;
            }
            group_offset += count;
        }
        return references.toOwnedSlice(a);
    }

    /// Fetch one complete body per reference in input order, including repeats.
    /// Recheck ownership, group, key, and predecessor after discovery.
    pub fn readHistory(self: Mailbox, a: Allocator, references: []const HistoryStore.Reference) ![]const []const u8 {
        const ids = try a.alloc([]const u8, references.len);
        for (references, ids) |reference, *id| {
            id.* = reference.locator;
        }
        const data = try a.alloc([]const u8, references.len);
        var offset: usize = 0;
        while (offset < ids.len) {
            var scratch: std.heap.ArenaAllocator = .init(self.jmap.allocator());
            defer scratch.deinit();
            const temporary = scratch.allocator();
            const count = try self.historyGetCount(ids[offset..], true);
            const fetched = try self.getHistoryRecords(temporary, ids[offset..][0..count], true);
            for (fetched, references[offset..][0..count], data[offset..][0..count]) |record, expected, *body| {
                const actual = try self.historyReference(temporary, record);
                if (!std.mem.eql(u8, actual.group, expected.group) or
                    !std.mem.eql(u8, &actual.key, &expected.key) or
                    !std.meta.eql(actual.previous, expected.previous)) return error.InvalidHistory;
                body.* = try a.dupe(u8, try historyBody(record));
            }
            offset += count;
        }
        return data;
    }

    const HistoryInventoryItem = struct {
        id: []const u8,
        contents: union(HistoryKind) { record: HistoryStore.RecordId, checkpoint: Checkpoint.State },
    };

    /// Inventory owned objects in History and check that the complete
    /// retention selection is present before moving any objects. The mail service
    /// owns expiry after unselected material enters Trash.
    pub fn maintainHistory(self: Mailbox, a: Allocator, retention: HistoryStore.Retention, confirmed_id: []const u8) !void {
        var retained: std.StringHashMapUnmanaged(bool) = .empty;
        defer retained.deinit(a);
        for (retention.records) |record|
            try retained.put(a, try historyRecordIdentity(a, record), false);
        const inventory = try self.historyInventory(a);
        var confirmed = false;
        var updates: std.ArrayList(Retirement) = .empty;
        for (inventory) |item| switch (item.contents) {
            .record => |record| {
                if (retained.getPtr(try historyRecordIdentity(a, record))) |found| {
                    found.* = true;
                } else {
                    try updates.append(a, .{ .id = item.id });
                }
            },
            .checkpoint => |state| {
                if (std.mem.eql(u8, item.id, confirmed_id)) {
                    if (state != .published) return error.InvalidHistory;
                    confirmed = true;
                } else {
                    try updates.append(a, .{ .id = item.id });
                }
            },
        };
        if (!confirmed) return error.InvalidHistory;
        var found_records = retained.valueIterator();
        while (found_records.next()) |found| if (!found.*) return error.InvalidHistory;

        try self.retireEmails(a, updates.items);
    }

    fn historyInventory(self: Mailbox, a: Allocator) ![]const HistoryInventoryItem {
        const filter = try value(a, .{
            .operator = "AND",
            .conditions = .{ try self.historyFolderFilter(a), try value(a, .{ .hasKeyword = state_keyword }) },
        });
        var inventory: std.ArrayList(HistoryInventoryItem) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        var position: usize = 0;
        while (true) {
            var scratch: std.heap.ArenaAllocator = .init(self.jmap.allocator());
            defer scratch.deinit();
            const temporary = scratch.allocator();
            const ids = try self.historyQueryIds(temporary, filter, position);
            if (ids.len == 0) break;
            var offset: usize = 0;
            while (offset < ids.len) {
                const count = try self.historyGetCount(ids[offset..], false);
                for (try self.getHistoryRecords(temporary, ids[offset..][0..count], false)) |record| {
                    if (!try self.ownsHistoryRecord(temporary, record)) continue;
                    const id = try a.dupe(u8, try textField(record, "id"));
                    if ((try seen.getOrPut(a, id)).found_existing) return error.InvalidHistory;
                    const folders = try field(record, "mailboxIds");
                    if (folders.object.count() != 1) return error.InvalidHistory;
                    const keywords = try field(record, "keywords");
                    const kind = std.meta.stringToEnum(HistoryKind, optionalText(record, kind_property) orelse return error.InvalidHistory) orelse return error.InvalidHistory;
                    const contents: @FieldType(HistoryInventoryItem, "contents") = switch (kind) {
                        .record => blk: {
                            if (boolean(keywords, current_keyword) or boolean(keywords, prepared_keyword) or
                                optionalField(record, revision_property) != null) return error.InvalidHistory;
                            const reference = try historyRecordReference(a, record);
                            break :blk .{ .record = .{ .group = reference.group, .key = reference.key } };
                        },
                        .checkpoint => .{ .checkpoint = checkpointState(keywords) },
                    };
                    try inventory.append(a, .{
                        .id = id,
                        .contents = contents,
                    });
                }
                offset += count;
            }
            position += ids.len;
        }
        return inventory.toOwnedSlice(a);
    }

    fn retireEmails(self: Mailbox, a: Allocator, updates: []const Retirement) !void {
        var offset: usize = 0;
        while (offset < updates.len) {
            var batch: std.json.ObjectMap = .empty;
            var count: usize = 0;
            while (count < @min(self.max_set, updates.len - offset)) {
                const update = updates[offset + count];
                try batch.put(a, update.id, try self.trashPatch(a, update));
                if (try Jmap.requestSize(.assign_email_properties, .{ .accountId = self.account_id, .update = Value{ .object = batch } }) > self.jmap.max_request) {
                    _ = batch.swapRemove(update.id);
                    break;
                }
                count += 1;
            }
            if (count == 0) return error.MailRequestTooLarge;
            try self.updateEmails(a, batch);
            offset += count;
        }
    }

    const HistoryWrite = union(enum) {
        record: HistoryStore.Record,
        checkpoint: struct { body: []const u8, revision: u64 },
    };

    pub fn createHistoryRecords(self: Mailbox, a: Allocator, records: []const HistoryStore.Record) !void {
        var offset: usize = 0;
        while (offset < records.len) {
            var scratch: std.heap.ArenaAllocator = .init(a);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            var creates: std.json.ObjectMap = .empty;
            var count: usize = 0;
            while (count < @min(self.max_set, records.len - offset)) {
                const creation_id = try std.fmt.allocPrint(temporary, "record-{d}", .{count});
                try creates.put(temporary, creation_id, try self.historyMessage(temporary, .{ .record = records[offset + count] }));
                if (try Jmap.requestSize(.@"Email/set", .{ .accountId = self.account_id, .create = Value{ .object = creates } }) > self.jmap.max_request) {
                    _ = creates.swapRemove(creation_id);
                    if (count == 0) return error.HistoryRecordTooLarge;
                    break;
                }
                count += 1;
            }
            self.createHistoryBatch(temporary, creates) catch |err| switch (err) {
                error.MailMutationUnconfirmed => try self.confirmHistoryRecords(temporary, records[offset..][0..count]),
                else => return err,
            };
            offset += count;
        }
    }

    pub fn prepareCheckpoint(self: Mailbox, a: Allocator, body: []const u8, revision: u64) ![]const u8 {
        var creates: std.json.ObjectMap = .empty;
        try creates.put(a, "checkpoint", try self.historyMessage(a, .{ .checkpoint = .{ .body = body, .revision = revision } }));
        const response = self.jmap.call(a, .@"Email/set", .{ .accountId = self.account_id, .create = Value{ .object = creates } }) catch |err| switch (err) {
            error.MailRequestTooLarge => return error.HistoryCheckpointTooLarge,
            else => return err,
        };
        return createdId(response, "checkpoint");
    }

    /// Patch only the publication keyword. Even a delayed request targeting a
    /// retired candidate cannot put it back into History.
    pub fn publishCheckpoint(self: Mailbox, a: Allocator, id: []const u8) !void {
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "keywords/" ++ current_keyword, .{ .bool = true });
        var update: std.json.ObjectMap = .empty;
        try update.put(a, id, .{ .object = patch });
        self.updateEmails(a, update) catch |err| {
            if (err != error.MailMutationUnconfirmed) return err;
            const record = (try self.checkpointMessage(a, id, false)) orelse return err;
            if (checkpointState(try field(record, "keywords")) != .published) return err;
        };
    }

    fn updateEmails(self: Mailbox, a: Allocator, updates: std.json.ObjectMap) !void {
        const reply = try self.jmap.call(a, .assign_email_properties, .{ .accountId = self.account_id, .update = Value{ .object = updates } });
        const updated = optionalField(reply, "updated") orelse return error.MailMutationUnconfirmed;
        if (updated != .object) return error.MailMutationUnconfirmed;
        for (updates.keys()) |id| if (!updated.object.contains(id)) return error.MailMutationUnconfirmed;
    }

    fn createHistoryBatch(self: Mailbox, a: Allocator, creates: std.json.ObjectMap) !void {
        const response = try self.jmap.call(a, .@"Email/set", .{ .accountId = self.account_id, .create = Value{ .object = creates } });
        for (creates.keys()) |creation_id| _ = try createdId(response, creation_id);
    }

    /// Each create stores the content key and predecessor with the immutable
    /// body, so their presence in the group can confirm the write for that record.
    fn confirmHistoryRecords(self: Mailbox, a: Allocator, records: []const HistoryStore.Record) !void {
        const groups = try a.alloc([]const u8, records.len);
        for (records, groups) |record, *group| group.* = record.group;
        const candidates = try self.queryHistory(a, groups);
        for (records) |record| {
            var found = false;
            for (candidates) |candidate| {
                if (!std.mem.eql(u8, candidate.group, record.group) or !std.mem.eql(u8, &candidate.key, &record.key)) continue;
                if (!std.meta.eql(candidate.previous, record.previous)) return error.InvalidHistory;
                found = true;
            }
            if (!found) return error.MailMutationUnconfirmed;
        }
    }

    fn historyMessage(self: Mailbox, a: Allocator, write: HistoryWrite) !Value {
        var folders: std.json.ObjectMap = .empty;
        try folders.put(a, self.history_id, .{ .bool = true });
        var keywords: std.json.ObjectMap = .empty;
        try keywords.put(a, "$seen", .{ .bool = true });
        try keywords.put(a, state_keyword, .{ .bool = true });
        switch (write) {
            .record => |record| try keywords.put(a, try historyGroupKeyword(a, record.group), .{ .bool = true }),
            .checkpoint => try keywords.put(a, prepared_keyword, .{ .bool = true }),
        }
        const body = switch (write) {
            .record => |record| record.body,
            .checkpoint => |checkpoint| checkpoint.body,
        };
        var message = try value(a, .{
            .mailboxIds = Value{ .object = folders },
            .keywords = Value{ .object = keywords },
            .from = &[_]Address{.{ .email = self.address }},
            .to = &[_]Address{.{ .email = self.address }},
            .subject = if (write == .checkpoint) "Ivenna history checkpoint" else "Ivenna history record",
            .textBody = &.{.{ .partId = "text", .type = "text/plain" }},
            .bodyValues = .{ .text = .{ .value = body } },
        });
        switch (write) {
            .record => |record| {
                try message.object.put(a, kind_property, .{ .string = "record" });
                try message.object.put(a, key_property, .{ .string = try a.dupe(u8, &record.key) });
                if (record.previous) |previous| {
                    try message.object.put(a, previous_property, .{ .string = try a.dupe(u8, &previous) });
                }
            },
            .checkpoint => |checkpoint| {
                try message.object.put(a, kind_property, .{ .string = "checkpoint" });
                try message.object.put(a, revision_property, .{ .string = try std.fmt.allocPrint(a, "{d}", .{checkpoint.revision}) });
            },
        }
        return message;
    }

    fn historyGroupFilter(self: Mailbox, a: Allocator, groups: []const []const u8) !Value {
        const alternatives = try a.alloc(Value, groups.len);
        for (groups, alternatives) |group, *alternative| alternative.* = try value(a, .{ .hasKeyword = try historyGroupKeyword(a, group) });
        return value(a, .{
            .operator = "AND",
            .conditions = .{
                try self.historyFolderFilter(a),
                try value(a, .{ .hasKeyword = state_keyword }),
                try value(a, .{ .operator = "OR", .conditions = alternatives }),
            },
        });
    }

    fn historyFolderFilter(self: Mailbox, a: Allocator) !Value {
        return value(a, .{
            .operator = "AND",
            .conditions = .{
                try value(a, .{ .inMailbox = self.history_id }),
                try value(a, .{ .operator = "NOT", .conditions = &.{.{ .inMailbox = self.trash_id }} }),
            },
        });
    }

    const HistoryQuery = struct {
        accountId: []const u8,
        filter: Value,
        position: usize,
        limit: usize = history_query_limit,
        collapseThreads: bool = false,
    };

    fn historyQuery(self: Mailbox, filter: Value, position: usize) HistoryQuery {
        return .{ .accountId = self.account_id, .filter = filter, .position = position };
    }

    fn historyQueryIds(self: Mailbox, a: Allocator, filter: Value, position: usize) ![]const []const u8 {
        const result = try self.jmap.call(a, .@"Email/query", self.historyQuery(filter, position));
        return strings(a, try field(result, "ids"));
    }

    fn historyReference(self: Mailbox, a: Allocator, record: Value) !HistoryStore.Reference {
        if (!try self.validateHistoryRecord(a, record, .record)) return error.InvalidHistory;
        return historyRecordReference(a, record);
    }

    fn historyRecordReference(a: Allocator, record: Value) !HistoryStore.Reference {
        const keywords = try field(record, "keywords");
        var group: ?[]const u8 = null;
        for (keywords.object.keys(), keywords.object.values()) |keyword, enabled| {
            if (!std.mem.startsWith(u8, keyword, group_keyword_prefix)) continue;
            if (group != null or enabled != .bool or !enabled.bool) return error.InvalidHistory;
            const token = keyword[group_keyword_prefix.len..];
            if (token.len != 32 or !isLowerHex(token)) return error.InvalidHistory;
            group = token;
        }
        const previous: ?HistoryStore.Key = if (optionalField(record, previous_property)) |item| blk: {
            if (item != .string) return error.InvalidHistory;
            break :blk try historyKey(item.string);
        } else null;
        return .{
            .group = try a.dupe(u8, group orelse return error.InvalidHistory),
            .key = try historyKey(optionalText(record, key_property) orelse return error.InvalidHistory),
            .previous = previous,
            .locator = try a.dupe(u8, try textField(record, "id")),
        };
    }

    const HistoryGet = struct {
        accountId: []const u8,
        ids: []const []const u8,
        properties: []const []const u8,
        bodyProperties: []const []const u8 = &.{ "partId", "type" },
        fetchTextBodyValues: bool,
        maxBodyValueBytes: usize = 0,
    };

    fn historyGet(self: Mailbox, ids: []const []const u8, body: bool) HistoryGet {
        return .{
            .accountId = self.account_id,
            .ids = ids,
            .properties = if (body) state_data_properties else state_properties,
            .fetchTextBodyValues = body,
        };
    }

    fn historyGetCount(self: Mailbox, ids: []const []const u8, body: bool) !usize {
        var count: usize = 0;
        while (count < @min(ids.len, self.max_get)) {
            if (try Jmap.requestSize(.@"Email/get", self.historyGet(ids[0 .. count + 1], body)) > self.jmap.max_request) break;
            count += 1;
        }
        if (count == 0) return error.MailRequestTooLarge;
        return count;
    }

    /// Return one record per requested ID, preserving input order and repeats,
    /// or fail if any requested record is missing.
    fn getHistoryRecords(self: Mailbox, a: Allocator, ids: []const []const u8, body: bool) ![]const Value {
        const response = try self.jmap.call(a, .@"Email/get", self.historyGet(ids, body));
        var records: std.StringHashMapUnmanaged(Value) = .empty;
        defer records.deinit(a);
        for (try arrayField(response, "list")) |record|
            try records.put(a, try textField(record, "id"), record);
        const ordered = try a.alloc(Value, ids.len);
        for (ids, ordered) |id, *record| {
            record.* = records.get(id) orelse return error.InvalidHistory;
        }
        return ordered;
    }

    /// Ignore records outside our ownership and require owned candidates to
    /// carry the expected native history discriminator.
    fn validateHistoryRecord(self: Mailbox, a: Allocator, record: Value, kind: HistoryKind) !bool {
        if (!try self.ownsHistoryRecord(a, record)) return false;
        const kind_name = optionalText(record, kind_property) orelse return error.InvalidHistory;
        if (!std.mem.eql(u8, kind_name, @tagName(kind))) return error.InvalidHistory;
        return true;
    }

    fn ownsHistoryRecord(self: Mailbox, a: Allocator, record: Value) !bool {
        const folders = try field(record, "mailboxIds");
        const keywords = try field(record, "keywords");
        if (folders != .object or keywords != .object) return error.InvalidMailReply;
        if (!boolean(keywords, state_keyword)) return false;
        if (boolean(folders, self.trash_id)) return false;
        if (!boolean(folders, self.history_id)) return false;
        const from = try addresses(a, record, "from");
        if (from.len != 1 or !self.addressing.isSelf(from[0].email)) return false;
        const addressed_to_self = for (try addresses(a, record, "to")) |recipient| {
            if (self.addressing.isSelf(recipient.email)) break true;
        } else false;
        if (!addressed_to_self) return false;
        return true;
    }

    /// A matching submission confirms acceptance. A false result leaves it unknown.
    pub fn submissionConfirmed(self: Mailbox, a: Allocator, id: []const u8) !bool {
        const query = self.jmap.call(a, .@"EmailSubmission/query", .{
            .accountId = self.account_id,
            .filter = .{ .emailIds = &.{id}, .identityIds = &.{self.identity_id} },
            .limit = 1,
        }) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return false,
        };
        const matches = arrayField(query, "ids") catch return false;
        return matches.len == 1 and matches[0] == .string and matches[0].string.len != 0;
    }

    pub fn submitDraft(self: Mailbox, a: Allocator, id: []const u8) !void {
        const result = self.jmap.call(a, .@"EmailSubmission/set", .{
            .accountId = self.account_id,
            .create = .{ .submission = .{ .identityId = self.identity_id, .emailId = id } },
        }) catch |err| switch (err) {
            // Stalwart can queue delivery before storing the EmailSubmission.
            error.MailMethodUnavailable => return error.MailMutationUnconfirmed,
            else => return err,
        };
        _ = try createdId(result, "submission");
    }

    pub fn createDraft(self: Mailbox, a: Allocator, outgoing: Outgoing) ![]const u8 {
        var folders: std.json.ObjectMap = .empty;
        try folders.put(a, self.drafts_id, .{ .bool = true });
        var keywords: std.json.ObjectMap = .empty;
        try keywords.put(a, "$draft", .{ .bool = true });
        try keywords.put(a, outbound_keyword, .{ .bool = true });
        try keywords.put(a, "$seen", .{ .bool = true });
        const message = try value(a, .{
            .mailboxIds = Value{ .object = folders },
            .keywords = Value{ .object = keywords },
            .from = &[_]Address{.{ .email = self.address }},
            .to = &[_]Address{.{ .email = outgoing.recipient }},
            .subject = outgoing.subject,
            .textBody = &.{.{ .partId = "text", .type = "text/plain" }},
            .bodyValues = .{ .text = .{ .value = outgoing.body } },
        });
        const result = try self.jmap.call(a, .@"Email/set", .{
            .accountId = self.account_id,
            .create = .{ .letter = message },
        });
        return createdId(result, "letter");
    }

    fn queryIds(self: Mailbox, a: Allocator, filter: Value, oldest_first: bool, position: usize, limit: usize) ![]const []const u8 {
        const sort = try value(a, .{.{ .property = "receivedAt", .isAscending = oldest_first }});
        const query = try self.jmap.call(a, .@"Email/query", .{
            .accountId = self.account_id,
            .filter = filter,
            .sort = sort,
            .position = position,
            .limit = @min(self.max_get, limit),
            .collapseThreads = false,
        });
        return strings(a, try field(query, "ids"));
    }

    fn pendingFilter(self: Mailbox, a: Allocator, kind: IntakeKind) !Value {
        var conditions: std.ArrayList(Value) = .empty;
        try conditions.append(a, try value(a, .{ .notKeyword = "$draft" }));
        try conditions.append(a, try value(a, .{ .notKeyword = handled_keyword }));
        try conditions.append(a, try value(a, .{ .notKeyword = outbound_keyword }));
        try conditions.append(a, try value(a, .{ .notKeyword = state_keyword }));
        switch (kind) {
            .callback => {
                try conditions.append(a, try value(a, .{ .hasKeyword = callback_keyword }));
                try conditions.append(a, try value(a, .{ .inMailbox = self.callback_id }));
            },
            .message => {
                try conditions.append(a, try value(a, .{ .notKeyword = callback_keyword }));
                try conditions.append(a, try value(a, .{ .operator = "NOT", .conditions = &.{.{ .inMailbox = self.callback_id }} }));
            },
        }
        for ([_][]const u8{ self.drafts_id, self.junk_id, self.trash_id, self.history_id }) |id| {
            if (id.len == 0) continue;
            try conditions.append(a, try value(a, .{
                .operator = "NOT",
                .conditions = &.{.{ .inMailbox = id }},
            }));
        }
        return value(a, .{ .operator = "AND", .conditions = conditions.items });
    }

    /// Preserve the requested order: Email/get need not return query order.
    fn getRecords(self: Mailbox, a: Allocator, ids: []const []const u8, body: bool) ![]const Value {
        var records: std.StringHashMapUnmanaged(Value) = .empty;
        defer records.deinit(a);
        var offset: usize = 0;
        while (offset < ids.len) {
            var count: usize = 0;
            while (count < @min(self.max_get, ids.len - offset)) {
                if (try Jmap.requestSize(.@"Email/get", self.correspondenceGet(ids[offset .. offset + count + 1], body)) > self.jmap.max_request) break;
                count += 1;
            }
            if (count == 0) return error.MailRequestTooLarge;
            const result = try self.jmap.call(a, .@"Email/get", self.correspondenceGet(ids[offset..][0..count], body));
            for (try arrayField(result, "list")) |record|
                try records.put(a, try textField(record, "id"), record);
            offset += count;
        }
        var ordered: std.ArrayList(Value) = .empty;
        for (ids) |id| {
            if (records.get(id)) |record| try ordered.append(a, record);
        }
        return ordered.toOwnedSlice(a);
    }

    const CorrespondenceGet = struct {
        accountId: []const u8,
        ids: []const []const u8,
        properties: []const []const u8,
        fetchTextBodyValues: bool,
        fetchHTMLBodyValues: bool,
    };

    fn correspondenceGet(self: Mailbox, ids: []const []const u8, body: bool) CorrespondenceGet {
        return .{
            .accountId = self.account_id,
            .ids = ids,
            .properties = if (body) message_properties else correspondence_properties,
            .fetchTextBodyValues = body,
            .fetchHTMLBodyValues = body,
        };
    }

    fn decode(a: Allocator, record: Value) !Letter {
        return .{
            .id = try textField(record, "id"),
            .from = try addresses(a, record, "from"),
            .subject = optionalText(record, "subject") orelse "",
            .body = try bodyText(a, record),
        };
    }

    fn decodeCallback(self: Mailbox, a: Allocator, record: Value) !Callback.Message {
        if (!boolean(try field(record, "mailboxIds"), self.callback_id)) return error.InvalidCallback;
        const id = try self.callbackId(a, record);
        // Private deliveries use the same complete plain-text storage format as
        // history records; an HTML fallback or malformed body flags cannot turn
        // an incomplete delivery into an accepted callback.
        return .{ .id = id, .text = historyBody(record) catch return error.InvalidCallback };
    }

    fn callbackId(self: Mailbox, a: Allocator, record: Value) !u64 {
        const keywords = try field(record, "keywords");
        if (!boolean(keywords, callback_keyword) or boolean(keywords, state_keyword) or
            boolean(keywords, outbound_keyword) or boolean(keywords, "$draft"))
            return error.InvalidCallback;
        const from = addresses(a, record, "from") catch |err| switch (err) {
            error.InvalidMailReply => return error.InvalidCallback,
            else => return err,
        };
        if (from.len != 1 or !self.addressing.isSelf(from[0].email)) return error.InvalidCallback;
        const to = addresses(a, record, "to") catch |err| switch (err) {
            error.InvalidMailReply => return error.InvalidCallback,
            else => return err,
        };
        if (to.len != 1 or !self.addressing.isSelf(to[0].email)) return error.InvalidCallback;
        const id_text = optionalText(record, callback_property) orelse return error.InvalidCallback;
        const id = std.fmt.parseInt(u64, id_text, 10) catch return error.InvalidCallback;
        if (id == 0) return error.InvalidCallback;
        const index_keyword = try callbackKeyword(a, id);
        var indexed = false;
        for (keywords.object.keys(), keywords.object.values()) |keyword, enabled| {
            if (!std.mem.startsWith(u8, keyword, callback_keyword_prefix)) continue;
            if (indexed or enabled != .bool or !enabled.bool or !std.mem.eql(u8, keyword, index_keyword))
                return error.InvalidCallback;
            indexed = true;
        }
        if (!indexed) return error.InvalidCallback;
        return id;
    }

    fn isCorrespondence(self: Mailbox, letter: Letter) bool {
        if (letter.from.len == 0) return false;
        for (letter.from) |address|
            if (self.addressing.id(address.email) == null) return false;
        return true;
    }
};

fn objectLimit(record: Value, name: []const u8) !usize {
    const item = try field(record, name);
    if (item != .integer or item.integer <= 0) return error.InvalidMailReply;
    return std.math.cast(usize, item.integer) orelse error.InvalidMailReply;
}

fn checkpointRevision(record: Value) !u64 {
    const keywords = try field(record, "keywords");
    for (keywords.object.keys()) |keyword|
        if (std.mem.startsWith(u8, keyword, group_keyword_prefix)) return error.InvalidHistory;
    if (optionalField(record, key_property) != null or optionalField(record, previous_property) != null)
        return error.InvalidHistory;
    const text = optionalText(record, revision_property) orelse return error.InvalidHistory;
    const revision = std.fmt.parseInt(u64, text, 10) catch return error.InvalidHistory;
    if (revision == 0) return error.InvalidHistory;
    return revision;
}

fn checkpointState(keywords: Value) Checkpoint.State {
    if (boolean(keywords, prepared_keyword)) return if (boolean(keywords, current_keyword)) .published else .prepared;
    return .legacy;
}

fn isLowerHex(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn historyGroupKeyword(a: Allocator, group: []const u8) ![]const u8 {
    if (group.len != 32 or !isLowerHex(group)) return error.InvalidHistory;
    return std.fmt.allocPrint(a, group_keyword_prefix ++ "{s}", .{group});
}

fn callbackKeyword(a: Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, callback_keyword_prefix ++ "{d}", .{id});
}

/// UTCDate has a fixed UTC prefix and optional decimal seconds. Removing Z
/// keeps whole seconds before fractional values in a lexical comparison.
fn receptionKey(record: Value) ![]const u8 {
    const timestamp = try textField(record, "receivedAt");
    if (timestamp.len < 20 or timestamp[timestamp.len - 1] != 'Z') return error.InvalidMailReply;
    const key = timestamp[0 .. timestamp.len - 1];
    for (key[0..19], 0..) |byte, index| {
        const valid = switch (index) {
            4, 7 => byte == '-',
            10 => byte == 'T',
            13, 16 => byte == ':',
            else => std.ascii.isDigit(byte),
        };
        if (!valid) return error.InvalidMailReply;
    }
    if (key.len > 19) {
        if (key[19] != '.' or key.len == 20) return error.InvalidMailReply;
        for (key[20..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidMailReply;
    }
    return key;
}

fn historyKey(text: []const u8) !HistoryStore.Key {
    if (text.len != 64 or !isLowerHex(text)) return error.InvalidHistory;
    return text[0..64].*;
}

fn historyRecordIdentity(a: Allocator, record: HistoryStore.RecordId) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ record.group, record.key });
}

fn historyBody(record: Value) ![]const u8 {
    const parts = try arrayField(record, "textBody");
    if (parts.len != 1 or !std.ascii.eqlIgnoreCase(try textField(parts[0], "type"), "text/plain")) return error.InvalidHistory;
    const part = try field(try field(record, "bodyValues"), try textField(parts[0], "partId"));
    for ([_][]const u8{ "isEncodingProblem", "isTruncated" }) |name| {
        if (part != .object) return error.InvalidHistory;
        const flag = part.object.get(name) orelse continue;
        if (flag != .bool or flag.bool) return error.InvalidHistory;
    }
    return textField(part, "value");
}

fn bodyText(a: Allocator, record: Value) ![]const u8 {
    var parts = optionalField(record, "textBody");
    if (parts == null or (parts.? == .array and parts.?.array.items.len == 0))
        parts = optionalField(record, "htmlBody");
    const selected = parts orelse return error.MailBodyUnavailable;
    if (selected != .array or selected.array.items.len == 0) return error.MailBodyUnavailable;
    const values = optionalField(record, "bodyValues") orelse return error.MailBodyUnavailable;
    if (values != .object) return error.MailBodyUnavailable;
    var text = std.Io.Writer.Allocating.init(a);
    defer text.deinit();
    for (selected.array.items, 0..) |part, index| {
        const part_id = optionalText(part, "partId") orelse return error.MailBodyUnavailable;
        const body = values.object.get(part_id) orelse return error.MailBodyUnavailable;
        if (boolean(body, "isEncodingProblem") or boolean(body, "isTruncated"))
            return error.MailBodyUnavailable;
        if (index != 0) try text.writer.writeByte('\n');
        try text.writer.writeAll(optionalText(body, "value") orelse return error.MailBodyUnavailable);
    }
    return text.toOwnedSlice();
}

fn addresses(a: Allocator, record: Value, name: []const u8) ![]const Address {
    const items = optionalField(record, name) orelse return &.{};
    if (items != .array) return error.InvalidMailReply;
    const result = try a.alloc(Address, items.array.items.len);
    for (items.array.items, result) |item, *address| {
        address.* = .{
            .email = try textField(item, "email"),
        };
    }
    return result;
}

fn strings(a: Allocator, items: Value) ![]const []const u8 {
    if (items != .array) return error.InvalidMailReply;
    const result = try a.alloc([]const u8, items.array.items.len);
    for (items.array.items, result) |item, *text| {
        if (item != .string) return error.InvalidMailReply;
        text.* = item.string;
    }
    return result;
}

fn createdId(result: Value, key: []const u8) ![]const u8 {
    const created = optionalField(result, "created") orelse return error.MailMutationUnconfirmed;
    const object = optionalField(created, key) orelse return error.MailMutationUnconfirmed;
    const id = optionalText(object, "id") orelse return error.MailMutationUnconfirmed;
    if (id.len == 0) return error.MailMutationUnconfirmed;
    return id;
}

fn boolean(record: Value, name: []const u8) bool {
    const item = optionalField(record, name) orelse return false;
    return item == .bool and item.bool;
}

fn optionalField(record: Value, name: []const u8) ?Value {
    if (record != .object) return null;
    const item = record.object.get(name) orelse return null;
    return if (item == .null) null else item;
}

fn optionalText(record: Value, name: []const u8) ?[]const u8 {
    const item = optionalField(record, name) orelse return null;
    return if (item == .string) item.string else null;
}

fn field(record: Value, name: []const u8) !Value {
    if (record != .object) return error.InvalidMailReply;
    return record.object.get(name) orelse error.InvalidMailReply;
}

fn textField(record: Value, name: []const u8) ![]const u8 {
    const item = try field(record, name);
    if (item != .string) return error.InvalidMailReply;
    return item.string;
}

fn arrayField(record: Value, name: []const u8) ![]const Value {
    const item = try field(record, name);
    if (item != .array) return error.InvalidMailReply;
    return item.array.items;
}

fn value(a: Allocator, item: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, item, .{}), .{});
}

test "an unconfirmed folder create discovers the intended top-level folder" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Mailbox/set", .result = null },
        .{ .method = "Mailbox/get", .result =
        \\{"list":[{"id":"nested","name":"Ivenna History","parentId":"other","role":null},
        \\{"id":"owned","name":"Ivenna History","parentId":null,"role":null}]}
        },
    });
    defer fixture.deinit();
    const mailbox = try fixture.start();
    const id = try mailbox.ensureFolder(fixture.arena.allocator(), &.{}, history_mailbox_name, null);
    try std.testing.expectEqualStrings("owned", id);
    try fixture.finish();
}

test "acknowledgement retries a lost response and reports a rejected update" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const update: []const @import("test_jmap.zig").Property = &.{
        .{ .path = &.{ "update", "received", "mailboxIds", "trash" }, .json = "true" },
        .{ .path = &.{ "update", "received", "keywords/ivenna-handled" }, .json = "true" },
    };
    {
        var fixture = try Fixture.init(&.{
            .{ .method = "Email/set", .properties = update, .result = null },
            .{ .method = "Email/set", .properties = update, .result = "{\"updated\":{\"received\":null}}" },
        });
        defer fixture.deinit();
        const mailbox = try fixture.start();
        try mailbox.acknowledge(fixture.arena.allocator(), "received");
        try fixture.finish();
    }
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/set", .properties = update, .result = "{\"notUpdated\":{\"received\":{\"type\":\"forbidden\"}}}" },
    });
    defer fixture.deinit();
    const mailbox = try fixture.start();
    try std.testing.expectError(error.MailObjectFailed, mailbox.acknowledge(fixture.arena.allocator(), "received"));
    try fixture.finish();
}

test "callback publication finds the stored callback in Trash after a lost response" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const stored =
        \\{"list":[{"id":"saved","mailboxIds":{"trash":true},"keywords":{"ivenna-callback":true,"ivenna-callback-7":true},
        \\"from":[{"email":"ivenna@example.com"}],"to":[{"email":"ivenna@example.com"}],"header:X-Ivenna-Callback-Id:asText":"7"}]}
    ;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        .{ .method = "Email/set", .result = null },
        .{ .method = "Email/query", .result = "{\"ids\":[\"saved\"]}" },
        .{ .method = "Email/get", .result = stored },
    });
    defer fixture.deinit();
    const mailbox = try fixture.start();
    try mailbox.publishCallback(fixture.arena.allocator(), .{ .id = 7, .text = "command completed" });
    try fixture.finish();
}

test "history maintenance retires only unselected checkpoints and records" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const group = "11111111111111111111111111111111";
    const kept_key = "a7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e";
    const discarded_key = "16367aacb67a4a017c8da8ab95682ccb390863780f7114dda0a0e0c55644c7c4";
    const owner =
        \\"mailboxIds":{"history":true},"from":[{"email":"ivenna@example.com"}],"to":[{"email":"ivenna@example.com"}],
    ;
    const checkpoint = owner ++ "\"header:X-Ivenna-History-Kind:asText\":\"checkpoint\",\"header:X-Ivenna-History-Revision:asText\":";
    const record = owner ++ "\"keywords\":{\"ivenna-state\":true,\"ivenna-history-" ++ group ++ "\":true}," ++
        "\"header:X-Ivenna-History-Kind:asText\":\"record\",\"header:X-Ivenna-History-Key:asText\":";
    const reply = "{\"list\":[" ++
        "{\"id\":\"confirmed\",\"keywords\":{\"ivenna-state\":true,\"ivenna-prepared\":true,\"ivenna-current\":true}," ++ checkpoint ++ "\"3\"}," ++
        "{\"id\":\"late\",\"keywords\":{\"ivenna-state\":true,\"ivenna-prepared\":true}," ++ checkpoint ++ "\"2\"}," ++
        "{\"id\":\"legacy\",\"keywords\":{\"ivenna-state\":true,\"ivenna-current\":true}," ++ checkpoint ++ "\"99\"}," ++
        "{\"id\":\"discarded\"," ++ record ++ "\"" ++ discarded_key ++ "\"}," ++
        "{\"id\":\"kept\"," ++ record ++ "\"" ++ kept_key ++ "\"}]}";
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[\"confirmed\",\"late\",\"legacy\",\"discarded\",\"kept\"]}" },
        .{ .method = "Email/get", .result = reply },
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        .{
            .method = "Email/set",
            .result = "{\"updated\":{\"late\":null,\"legacy\":null,\"discarded\":null}}",
            .properties = &.{.{ .path = &.{"update"}, .json = "{\"late\":{\"mailboxIds\":{\"trash\":true}},\"legacy\":{\"mailboxIds\":{\"trash\":true}},\"discarded\":{\"mailboxIds\":{\"trash\":true}}}" }},
        },
    });
    defer fixture.deinit();
    const mailbox = try fixture.start();
    const retention: HistoryStore.Retention = .{ .records = &.{.{ .group = group, .key = kept_key.* }} };
    try mailbox.maintainHistory(fixture.arena.allocator(), retention, "confirmed");
    try fixture.finish();
}

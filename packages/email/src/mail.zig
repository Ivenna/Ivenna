const std = @import("std");
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

pub const Outgoing = struct {
    to: []const Address,
    subject: []const u8,
    body: []const u8,
};

pub const Submission = struct {
    mail_id: []const u8,
    sent_copy: enum { updated, unconfirmed },
};

pub const StateRecord = struct {
    id: []const u8,
    revision: u64,
};

const core_capability = "urn:ietf:params:jmap:core";
const mail_capability = "urn:ietf:params:jmap:mail";
const submission_capability = "urn:ietf:params:jmap:submission";
const handled_keyword = "ivenna-handled";
const outbound_keyword = "ivenna-outbound";
const state_keyword = "ivenna-state";
const current_keyword = "ivenna-current";
const history_mailbox_name = "Ivenna History";
const kind_property = "header:X-Ivenna-History-Kind:asText";
const revision_property = "header:X-Ivenna-History-Revision:asText";
const state_properties: []const []const u8 = &.{
    "id", "mailboxIds", "keywords", "from", "to", kind_property, revision_property,
};
const state_data_properties: []const []const u8 = &.{
    "id", "mailboxIds", "keywords", "from", "to", kind_property, revision_property, "textBody", "bodyValues",
};
const message_properties: []const []const u8 = &.{
    "id", "from", "subject", "textBody", "htmlBody", "bodyValues",
};

const HistoryKind = enum { source, manifest };

/// JMAP access for communication records, submissions, and working history.
/// Discover once using an allocator that outlives every operation and worker.
pub const Mailbox = struct {
    client: *std.http.Client,
    session_url: []const u8,
    authorization: []const u8,
    address: []const u8,
    addressing: Addressing,
    api_url: []const u8 = "",
    account_id: []const u8 = "",
    identity_id: []const u8 = "",
    sent_id: []const u8 = "",
    drafts_id: []const u8 = "",
    history_id: []const u8 = "",
    excluded_ids: []const []const u8 = &.{},
    max_get: usize = 32,
    max_set: usize = 32,
    max_request: usize = 0,

    pub fn discover(self: *Mailbox, a: Allocator) !void {
        const session = try self.http(a, .GET, self.session_url, null);
        self.api_url = try textField(session, "apiUrl");
        self.account_id = try textField(try field(session, "primaryAccounts"), mail_capability);
        const capabilities = try field(session, "capabilities");
        if (capabilities != .object or !capabilities.object.contains(mail_capability) or
            !capabilities.object.contains(submission_capability))
            return error.MailCapabilityUnavailable;
        const core = try field(capabilities, core_capability);
        self.max_get = @min(try objectLimit(core, "maxObjectsInGet"), 32);
        self.max_set = @min(try objectLimit(core, "maxObjectsInSet"), 32);
        self.max_request = try objectLimit(core, "maxSizeRequest");
        const identities = try self.call(a, "Identity/get", .{ .accountId = self.account_id });
        for (try arrayField(identities, "list")) |identity| {
            if (std.ascii.eqlIgnoreCase(try textField(identity, "email"), self.address)) {
                self.identity_id = try textField(identity, "id");
                break;
            }
        }
        if (self.identity_id.len == 0) return error.MailIdentityNotFound;

        var excluded: std.ArrayList([]const u8) = .empty;
        const folders = try self.call(a, "Mailbox/get", .{
            .accountId = self.account_id,
            .properties = &[_][]const u8{ "id", "name", "parentId", "role" },
        });
        for (try arrayField(folders, "list")) |folder| {
            const id = try textField(folder, "id");
            const role = optionalText(folder, "role") orelse {
                if (optionalText(folder, "parentId") == null and
                    std.mem.eql(u8, try textField(folder, "name"), history_mailbox_name))
                    self.history_id = id;
                continue;
            };
            if (std.mem.eql(u8, role, "sent")) self.sent_id = id;
            if (std.mem.eql(u8, role, "drafts")) self.drafts_id = id;
            if (std.mem.eql(u8, role, "drafts") or std.mem.eql(u8, role, "trash") or std.mem.eql(u8, role, "junk"))
                try excluded.append(a, id);
        }
        if (self.sent_id.len == 0 or self.drafts_id.len == 0)
            return error.MailFoldersNotFound;
        if (self.history_id.len == 0) {
            const created = try self.call(a, "Mailbox/set", .{
                .accountId = self.account_id,
                .create = .{ .history = .{ .name = history_mailbox_name, .parentId = null, .role = null } },
            });
            self.history_id = try createdId(created, "history");
        }
        try excluded.append(a, self.history_id);
        self.excluded_ids = try excluded.toOwnedSlice(a);
    }

    /// Intake excludes history storage and uses private processing markers,
    /// independently of read status, stars, or archiving.
    pub fn pending(self: Mailbox, a: Allocator, limit: usize) ![]const Letter {
        const filter = try self.pendingFilter(a);
        var letters: std.ArrayList(Letter) = .empty;
        var position: usize = 0;
        while (letters.items.len < limit) {
            const ids = try self.queryIds(a, filter, true, position, limit - letters.items.len);
            if (ids.len == 0) break;
            for (try self.getRecords(a, ids)) |record| {
                const letter = decode(a, record) catch |err| switch (err) {
                    error.MailBodyUnavailable => {
                        std.log.warn("mail {s} has no complete supported body", .{try textField(record, "id")});
                        continue;
                    },
                    else => return err,
                };
                if (!self.isCorrespondence(letter)) continue;
                try letters.append(a, letter);
            }
            position += ids.len;
        }
        return letters.toOwnedSlice(a);
    }

    pub fn markHandled(self: Mailbox, a: Allocator, id: []const u8) !void {
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "keywords/" ++ handled_keyword, .{ .bool = true });
        var updates: std.json.ObjectMap = .empty;
        try updates.put(a, id, .{ .object = patch });
        const result = try self.call(a, "Email/set", .{
            .accountId = self.account_id,
            .update = Value{ .object = updates },
        });
        if (!hasKey(result, "updated", id)) return error.InvalidMailReply;
    }

    /// Only current manifests are discovered. Sources are read by native ID.
    pub fn historyHeads(self: Mailbox, a: Allocator) ![]const StateRecord {
        const filter = try value(a, .{
            .operator = "AND",
            .conditions = .{
                .{ .inMailbox = self.history_id },
                .{ .hasKeyword = state_keyword },
                .{ .hasKeyword = current_keyword },
            },
        });
        var records: std.ArrayList(StateRecord) = .empty;
        var position: usize = 0;
        while (true) {
            var scratch: std.heap.ArenaAllocator = .init(self.client.allocator);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            const ids = try self.queryIds(temporary, filter, false, position, self.max_get);
            if (ids.len == 0) break;
            var offset: usize = 0;
            while (offset < ids.len) {
                const count = try self.historyGetCount(ids[offset..], false);
                for (try self.getHistoryRecords(temporary, ids[offset..][0..count], false)) |record| {
                    if (!try self.validateHistoryRecord(temporary, record, .manifest)) continue;
                    try records.append(a, .{
                        .id = try a.dupe(u8, try textField(record, "id")),
                        .revision = try historyRevision(record),
                    });
                }
                offset += count;
            }
            position += ids.len;
        }
        return records.toOwnedSlice(a);
    }

    /// Fetch each complete body with the metadata that establishes its origin.
    /// Results follow the requested IDs and belong to a; response JSON is
    /// released after each native batch.
    pub fn historyData(self: Mailbox, a: Allocator, ids: []const []const u8, kind: HistoryKind) ![]const []const u8 {
        var unique: std.StringHashMapUnmanaged(void) = .empty;
        defer unique.deinit(self.client.allocator);
        for (ids) |id| {
            if (id.len == 0) return error.InvalidHistory;
            if ((try unique.getOrPut(self.client.allocator, id)).found_existing) return error.InvalidHistory;
        }
        const data = try a.alloc([]const u8, ids.len);
        var offset: usize = 0;
        while (offset < ids.len) {
            var scratch: std.heap.ArenaAllocator = .init(self.client.allocator);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            const count = try self.historyGetCount(ids[offset..], true);
            const fetched = try self.getHistoryRecords(temporary, ids[offset..][0..count], true);
            for (fetched, data[offset..][0..count]) |record, *body| {
                if (!try self.validateHistoryRecord(temporary, record, kind)) return error.InvalidHistory;
                if (kind == .manifest) _ = try historyRevision(record);
                body.* = try a.dupe(u8, try historyBody(record));
            }
            offset += count;
        }
        return data;
    }

    pub fn createSources(self: Mailbox, a: Allocator, data: []const []const u8) ![]const []const u8 {
        return self.createHistory(a, data, null);
    }

    pub fn createManifest(self: Mailbox, a: Allocator, data: []const u8, revision: u64) ![]const u8 {
        return (try self.createHistory(a, &.{data}, revision))[0];
    }

    /// Native creation IDs correlate every result. A failed batch may leave
    /// sources stored, but its caller cannot publish a manifest using them.
    fn createHistory(self: Mailbox, a: Allocator, data: []const []const u8, revision: ?u64) ![]const []const u8 {
        const ids = try a.alloc([]const u8, data.len);
        var unique: std.StringHashMapUnmanaged(void) = .empty;
        defer unique.deinit(self.client.allocator);
        var offset: usize = 0;
        while (offset < data.len) {
            var scratch: std.heap.ArenaAllocator = .init(self.client.allocator);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            var creates: std.json.ObjectMap = .empty;
            var count: usize = 0;
            while (count < @min(self.max_set, data.len - offset)) {
                const creation_id = try std.fmt.allocPrint(temporary, "record-{d}", .{count});
                try creates.put(temporary, creation_id, try self.historyMessage(temporary, data[offset + count], revision));
                const size = try requestSize("Email/set", .{ .accountId = self.account_id, .create = Value{ .object = creates } });
                if (size > self.max_request) {
                    _ = creates.swapRemove(creation_id);
                    if (count == 0) return error.HistoryRecordTooLarge;
                    break;
                }
                count += 1;
            }
            const response = try self.call(temporary, "Email/set", .{ .accountId = self.account_id, .create = Value{ .object = creates } });
            const created = try field(response, "created");
            if (created != .object or created.object.count() != count) return error.InvalidMailReply;
            for (creates.keys(), ids[offset..][0..count]) |creation_id, *id| {
                const native = try createdId(response, creation_id);
                if (native.len == 0) return error.InvalidMailReply;
                const owned = try a.dupe(u8, native);
                if ((try unique.getOrPut(self.client.allocator, owned)).found_existing) return error.InvalidMailReply;
                id.* = owned;
            }
            offset += count;
        }
        return ids;
    }

    /// Only manifests carry a revision and the current-manifest marker.
    fn historyMessage(self: Mailbox, a: Allocator, data: []const u8, revision: ?u64) !Value {
        var folders: std.json.ObjectMap = .empty;
        try folders.put(a, self.history_id, .{ .bool = true });
        var keywords: std.json.ObjectMap = .empty;
        try keywords.put(a, "$seen", .{ .bool = true });
        try keywords.put(a, state_keyword, .{ .bool = true });
        if (revision != null) try keywords.put(a, current_keyword, .{ .bool = true });
        var message = try value(a, .{
            .mailboxIds = Value{ .object = folders },
            .keywords = Value{ .object = keywords },
            .from = &[_]Address{.{ .email = self.address }},
            .to = &[_]Address{.{ .email = self.address }},
            .subject = if (revision != null) "Ivenna history manifest" else "Ivenna history source",
            .textBody = &.{.{ .partId = "text", .type = "text/plain" }},
            .bodyValues = .{ .text = .{ .value = data } },
        });
        try message.object.put(a, kind_property, .{ .string = if (revision != null) "manifest" else "source" });
        if (revision) |number| try message.object.put(a, revision_property, .{ .string = try std.fmt.allocPrint(a, "{d}", .{number}) });
        return message;
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
            if (try requestSize("Email/get", self.historyGet(ids[0 .. count + 1], body)) > self.max_request) break;
            count += 1;
        }
        if (count == 0) return error.MailRequestTooLarge;
        return count;
    }

    /// History cannot silently lose, repeat, or substitute a requested record.
    fn getHistoryRecords(self: Mailbox, a: Allocator, ids: []const []const u8, body: bool) ![]const Value {
        const response = try self.call(a, "Email/get", self.historyGet(ids, body));
        if ((try arrayField(response, "notFound")).len != 0) return error.InvalidHistory;
        const records = try arrayField(response, "list");
        if (records.len != ids.len) return error.InvalidHistory;
        var expected: std.StringHashMapUnmanaged(usize) = .empty;
        defer expected.deinit(a);
        for (ids, 0..) |id, index| {
            const entry = try expected.getOrPut(a, id);
            if (entry.found_existing) return error.InvalidHistory;
            entry.value_ptr.* = index;
        }
        const ordered = try a.alloc(Value, ids.len);
        for (records) |record| {
            const entry = expected.getPtr(try textField(record, "id")) orelse return error.InvalidHistory;
            if (entry.* == ids.len) return error.InvalidHistory;
            ordered[entry.*] = record;
            entry.* = ids.len;
        }
        return ordered;
    }

    /// Ignore records outside our ownership or current selection, but require
    /// owned candidates to carry the expected native history discriminator.
    fn validateHistoryRecord(self: Mailbox, a: Allocator, record: Value, kind: HistoryKind) !bool {
        const folders = try field(record, "mailboxIds");
        const keywords = try field(record, "keywords");
        if (folders != .object or keywords != .object) return error.InvalidMailReply;
        if (!boolean(folders, self.history_id) or !boolean(keywords, state_keyword)) return false;
        if (kind == .manifest and !boolean(keywords, current_keyword)) return false;
        const from = try addresses(a, record, "from");
        if (from.len != 1 or !std.ascii.eqlIgnoreCase(from[0].email, self.address)) return false;
        const addressed_to_self = for (try addresses(a, record, "to")) |recipient| {
            if (std.ascii.eqlIgnoreCase(recipient.email, self.address)) break true;
        } else false;
        if (!addressed_to_self) return false;
        const kind_name = optionalText(record, kind_property) orelse return error.InvalidHistory;
        if (!std.mem.eql(u8, kind_name, @tagName(kind))) return error.InvalidHistory;
        return true;
    }

    pub fn clearHistoryHead(self: Mailbox, a: Allocator, id: []const u8) !void {
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "keywords/" ++ current_keyword, .null);
        var updates: std.json.ObjectMap = .empty;
        try updates.put(a, id, .{ .object = patch });
        const response = try self.call(a, "Email/set", .{ .accountId = self.account_id, .update = Value{ .object = updates } });
        if (!hasKey(response, "updated", id)) return error.InvalidMailReply;
    }

    /// Submission acceptance does not establish final recipient delivery.
    pub fn send(self: Mailbox, a: Allocator, outgoing: Outgoing) !Submission {
        const id = try self.create(a, outgoing);
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "keywords/$draft", .null);
        try patch.put(a, try std.fmt.allocPrint(a, "mailboxIds/{s}", .{self.drafts_id}), .null);
        try patch.put(a, try std.fmt.allocPrint(a, "mailboxIds/{s}", .{self.sent_id}), .{ .bool = true });
        const submitted = try self.invoke(a, "EmailSubmission/set", .{
            .accountId = self.account_id,
            .create = .{ .submission = .{ .identityId = self.identity_id, .emailId = id } },
            .onSuccessUpdateEmail = .{ .@"#submission" = Value{ .object = patch } },
        });
        _ = try createdId(submitted.result, "submission");
        const updated = if (submitted.email_update) |update| hasKey(update, "updated", id) else false;
        return .{ .mail_id = id, .sent_copy = if (updated) .updated else .unconfirmed };
    }

    fn create(self: Mailbox, a: Allocator, outgoing: Outgoing) ![]const u8 {
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
            .to = outgoing.to,
            .subject = outgoing.subject,
            .textBody = &.{.{ .partId = "text", .type = "text/plain" }},
            .bodyValues = .{ .text = .{ .value = outgoing.body } },
        });
        const result = try self.call(a, "Email/set", .{
            .accountId = self.account_id,
            .create = .{ .letter = message },
        });
        return createdId(result, "letter");
    }

    fn queryIds(self: Mailbox, a: Allocator, filter: Value, oldest_first: bool, position: usize, limit: usize) ![]const []const u8 {
        const sort = try value(a, .{.{ .property = "receivedAt", .isAscending = oldest_first }});
        const query = try self.call(a, "Email/query", .{
            .accountId = self.account_id,
            .filter = filter,
            .sort = sort,
            .position = position,
            .limit = @min(self.max_get, limit),
            .collapseThreads = false,
        });
        return strings(a, try field(query, "ids"));
    }

    fn pendingFilter(self: Mailbox, a: Allocator) !Value {
        var conditions: std.ArrayList(Value) = .empty;
        try conditions.append(a, try value(a, .{ .notKeyword = "$draft" }));
        try conditions.append(a, try value(a, .{ .notKeyword = handled_keyword }));
        try conditions.append(a, try value(a, .{ .notKeyword = outbound_keyword }));
        try conditions.append(a, try value(a, .{ .notKeyword = state_keyword }));
        for (self.excluded_ids) |id| {
            try conditions.append(a, try value(a, .{
                .operator = "NOT",
                .conditions = &.{.{ .inMailbox = id }},
            }));
        }
        return value(a, .{ .operator = "AND", .conditions = conditions.items });
    }

    /// Preserve the requested order: Email/get need not return query order.
    fn getRecords(self: Mailbox, a: Allocator, ids: []const []const u8) ![]const Value {
        const result = try self.call(a, "Email/get", .{
            .accountId = self.account_id,
            .ids = ids,
            .properties = message_properties,
            .fetchTextBodyValues = true,
            .fetchHTMLBodyValues = true,
        });
        var records = try indexRecords(a, try arrayField(result, "list"));
        defer records.deinit(a);
        var ordered: std.ArrayList(Value) = .empty;
        for (ids) |id| {
            if (records.get(id)) |record| try ordered.append(a, record);
        }
        return ordered.toOwnedSlice(a);
    }

    fn decode(a: Allocator, record: Value) !Letter {
        return .{
            .id = try textField(record, "id"),
            .from = try addresses(a, record, "from"),
            .subject = optionalText(record, "subject") orelse "",
            .body = try bodyText(a, record),
        };
    }

    fn isCorrespondence(self: Mailbox, letter: Letter) bool {
        if (letter.from.len == 0) return false;
        for (letter.from) |address|
            if (self.addressing.id(address.email) == null) return false;
        return true;
    }

    /// Submission acceptance is independent of its implicit sent-copy update.
    const Invocation = struct { result: Value, email_update: ?Value };

    fn call(self: Mailbox, a: Allocator, method: []const u8, arguments: anytype) !Value {
        return (try self.invoke(a, method, arguments)).result;
    }

    fn invoke(self: Mailbox, a: Allocator, method: []const u8, arguments: anytype) !Invocation {
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        try writeRequest(method, arguments, &output.writer);
        const payload = output.written();
        if (payload.len > self.max_request) return error.MailRequestTooLarge;
        const reply = try self.http(a, .POST, self.api_url, payload);
        var matched: ?Value = null;
        var email_update: ?Value = null;
        for (try arrayField(reply, "methodResponses")) |invocation| {
            if (invocation != .array or invocation.array.items.len != 3) return error.InvalidMailReply;
            const parts = invocation.array.items;
            if (parts[0] != .string or parts[2] != .string or !std.mem.eql(u8, parts[2].string, "0"))
                return error.InvalidMailReply;
            if (std.mem.eql(u8, parts[0].string, "error")) {
                if (std.mem.eql(u8, method, "EmailSubmission/set") and matched != null and email_update == null) {
                    email_update = parts[1];
                    continue;
                }
                return error.MailMethodFailed;
            }
            if (std.mem.eql(u8, parts[0].string, method)) {
                if (matched != null) return error.InvalidMailReply;
                try checkObjectErrors(parts[1]);
                matched = parts[1];
            } else if (std.mem.eql(u8, method, "EmailSubmission/set") and
                std.mem.eql(u8, parts[0].string, "Email/set"))
            {
                if (email_update != null) return error.InvalidMailReply;
                email_update = parts[1];
            } else return error.InvalidMailReply;
        }
        return .{ .result = matched orelse return error.InvalidMailReply, .email_update = email_update };
    }

    fn http(self: Mailbox, a: Allocator, method: std.http.Method, url: []const u8, payload: ?[]u8) !Value {
        try self.client.io.checkCancel();
        var output = std.Io.Writer.Allocating.init(a);
        defer output.deinit();
        var request = try self.client.request(method, try std.Uri.parse(url), .{
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .content_type = if (payload != null) .{ .override = "application/json" } else .omit,
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = if (method == .GET) .init(3) else .unhandled,
        });
        defer request.deinit();
        if (payload) |bytes| {
            request.sendBodyComplete(bytes) catch |err| return transportError(&request, err);
        } else {
            request.sendBodiless() catch |err| return transportError(&request, err);
        }
        var redirect_buffer: [8192]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| return transportError(&request, err);
        if (response.head.status != .ok) {
            std.log.err("mail endpoint returned HTTP {d}", .{@backingInt(response.head.status)});
            return error.MailHttpFailure;
        }
        if (response.head.content_encoding != .identity) return error.UnsupportedMailEncoding;
        _ = response.reader(&.{}).streamRemaining(&output.writer) catch |err| return transportError(&request, err);
        return std.json.parseFromSliceLeaky(Value, a, output.written(), .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMailReply,
        };
    }
};

fn indexRecords(a: Allocator, records: []const Value) !std.StringHashMapUnmanaged(Value) {
    var index: std.StringHashMapUnmanaged(Value) = .empty;
    errdefer index.deinit(a);
    for (records) |record| {
        const entry = try index.getOrPut(a, try textField(record, "id"));
        if (!entry.found_existing) entry.value_ptr.* = record;
    }
    return index;
}

fn objectLimit(record: Value, name: []const u8) !usize {
    const item = try field(record, name);
    if (item != .integer or item.integer <= 0) return error.InvalidMailReply;
    return std.math.cast(usize, item.integer) orelse error.InvalidMailReply;
}

fn writeRequest(method: []const u8, arguments: anytype, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(.{
        .using = &[_][]const u8{ core_capability, mail_capability, submission_capability },
        .methodCalls = .{.{ method, arguments, "0" }},
    }, .{}, writer);
}

fn requestSize(method: []const u8, arguments: anytype) !u64 {
    var buffer: [256]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&buffer);
    try writeRequest(method, arguments, &output.writer);
    return output.fullCount();
}

fn historyRevision(record: Value) !u64 {
    const text = optionalText(record, revision_property) orelse return error.InvalidHistory;
    const revision = std.fmt.parseInt(u64, text, 10) catch return error.InvalidHistory;
    if (revision == 0) return error.InvalidHistory;
    return revision;
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
    return textField(try field(try field(result, "created"), key), "id");
}

fn hasKey(record: Value, name: []const u8, key: []const u8) bool {
    const container = optionalField(record, name) orelse return false;
    return container == .object and container.object.contains(key);
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

fn checkObjectErrors(record: Value) !void {
    for ([_][]const u8{ "notCreated", "notUpdated", "notDestroyed" }) |name| {
        const failures = optionalField(record, name) orelse continue;
        if (failures != .object) return error.InvalidMailReply;
        if (failures.object.count() == 0) continue;
        for (failures.object.values()) |failure| {
            if (optionalText(failure, "type")) |kind|
                if (std.mem.eql(u8, kind, "notFound")) return error.MailNotFound;
        }
        return error.MailObjectFailed;
    }
}

fn transportError(request: *std.http.Client.Request, err: anyerror) anyerror {
    if (request.connection) |connection| {
        if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return cause;
        if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return cause;
    }
    return err;
}

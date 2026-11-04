const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Purpose = enum { correspondence, report, handover, core_handover };
pub const Destination = enum { inbox, archive };

pub const Address = struct {
    name: ?[]const u8 = null,
    email: []const u8,
};

/// All returned text and arrays belong to the operation's allocator.
pub const Letter = struct {
    id: []const u8,
    thread_id: []const u8,
    message_id: ?[]const u8,
    in_reply_to: ?[]const u8,
    references: []const []const u8,
    from: []const Address,
    to: []const Address,
    subject: []const u8,
    body: []const u8,
    purpose: ?Purpose,
    flagged: bool = false,
    in_inbox: bool = true,
    in_archive: bool = false,
};

pub const Outgoing = struct {
    to: []const Address,
    subject: []const u8,
    body: []const u8,
    in_reply_to: ?[]const u8 = null,
    references: []const []const u8 = &.{},
    purpose: ?Purpose = null,
};

pub const Thread = struct {
    id: []const u8,
    letters: []const Letter,
    handover: ?Letter,
    archived: bool,
    has_archived_history: bool,
};

const core_capability = "urn:ietf:params:jmap:core";
const mail_capability = "urn:ietf:params:jmap:mail";
const submission_capability = "urn:ietf:params:jmap:submission";
const purpose_property = "header:X-Ivenna-Purpose:asText";
const metadata_properties: []const []const u8 = &.{
    "id",             "threadId",   "mailboxIds", "keywords", "messageId",
    "inReplyTo",      "references", "from",       "to",       "subject",
    purpose_property,
};
const body_properties = metadata_properties ++ &[_][]const u8{
    "textBody", "htmlBody", "bodyValues",
};

/// A JMAP Mail adapter for kernel operations. Stalwart decodes MIME and structured
/// headers; this component owns JSON protocol decoding and typed mail results.
/// Discover once using an allocator that outlives every operation and worker.
pub const Mailbox = struct {
    client: *std.http.Client,
    session_url: []const u8,
    authorization: []const u8,
    address: []const u8,
    api_url: []const u8 = "",
    account_id: []const u8 = "",
    identity_id: []const u8 = "",
    inbox_id: []const u8 = "",
    sent_id: []const u8 = "",
    drafts_id: []const u8 = "",
    archive_id: []const u8 = "",
    excluded_ids: []const []const u8 = &.{},
    max_get: usize = 32,
    max_set: usize = 32,

    pub fn discover(self: *Mailbox, a: Allocator) !void {
        const session = try self.http(a, .GET, self.session_url, null);
        self.api_url = try textField(session, "apiUrl");
        self.account_id = try textField(try field(session, "primaryAccounts"), mail_capability);
        const capabilities = try field(session, "capabilities");
        if (capabilities != .object or !capabilities.object.contains(mail_capability) or
            !capabilities.object.contains(submission_capability))
            return error.MailCapabilityUnavailable;
        if (capabilities.object.get(core_capability)) |core| {
            self.max_get = try objectLimit(core, "maxObjectsInGet");
            self.max_set = try objectLimit(core, "maxObjectsInSet");
        }
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
            .properties = &[_][]const u8{ "id", "role" },
        });
        for (try arrayField(folders, "list")) |folder| {
            const role = optionalText(folder, "role") orelse continue;
            const id = try textField(folder, "id");
            if (std.mem.eql(u8, role, "inbox")) self.inbox_id = id;
            if (std.mem.eql(u8, role, "sent")) self.sent_id = id;
            if (std.mem.eql(u8, role, "drafts")) self.drafts_id = id;
            if (std.mem.eql(u8, role, "archive")) self.archive_id = id;
            if (std.mem.eql(u8, role, "trash") or std.mem.eql(u8, role, "junk"))
                try excluded.append(a, id);
        }
        self.excluded_ids = try excluded.toOwnedSlice(a);
        if (self.inbox_id.len == 0 or self.sent_id.len == 0 or self.drafts_id.len == 0)
            return error.MailFoldersNotFound;
        if (self.archive_id.len == 0) {
            const created = try self.call(a, "Mailbox/set", .{
                .accountId = self.account_id,
                .create = .{ .archive = .{ .name = "Archive", .role = "archive" } },
            });
            self.archive_id = try createdId(created, "archive");
        }
    }

    pub fn unread(self: Mailbox, a: Allocator, limit: usize) ![]const Letter {
        return self.queryLetters(a, try value(a, .{
            .inMailbox = self.inbox_id,
            .notKeyword = "$seen",
        }), true, limit);
    }

    pub fn read(self: Mailbox, a: Allocator, id: []const u8) !Letter {
        const records = try self.getRecords(a, &.{id}, true);
        if (records.len == 0) return error.MailNotFound;
        return self.decode(a, records[0], true);
    }

    pub fn markRead(self: Mailbox, a: Allocator, id: []const u8) !void {
        try self.mark(a, id, false);
    }

    pub fn markAnswered(self: Mailbox, a: Allocator, id: []const u8) !void {
        try self.mark(a, id, true);
    }

    fn mark(self: Mailbox, a: Allocator, id: []const u8, answered: bool) !void {
        var patch: std.json.ObjectMap = .empty;
        try patch.put(a, "keywords/$seen", .{ .bool = true });
        if (answered) try patch.put(a, "keywords/$answered", .{ .bool = true });
        var updates: std.json.ObjectMap = .empty;
        try updates.put(a, id, .{ .object = patch });
        const result = try self.call(a, "Email/set", .{
            .accountId = self.account_id,
            .update = Value{ .object = updates },
        });
        if (!hasKey(result, "updated", id)) return error.InvalidMailReply;
    }

    /// Submission acceptance does not establish final recipient delivery.
    pub fn send(self: Mailbox, a: Allocator, outgoing: Outgoing) ![]const u8 {
        const id = try self.create(a, outgoing, self.drafts_id, true);
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
        if (!hasKey(submitted.email_update orelse return error.InvalidMailReply, "updated", id))
            return error.InvalidMailReply;
        return id;
    }

    /// Save one ordinary self letter directly. It has no SMTP delivery copy.
    pub fn saveInternal(self: Mailbox, a: Allocator, outgoing: Outgoing, destination: Destination) !Letter {
        if (outgoing.to.len == 0) return error.MailRecipientRequired;
        for (outgoing.to) |recipient| {
            if (!std.ascii.eqlIgnoreCase(recipient.email, self.address))
                return error.InternalMailMustBeSelfAddressed;
        }
        const folder = switch (destination) {
            .inbox => self.inbox_id,
            .archive => self.archive_id,
        };
        const id = try self.create(a, outgoing, folder, false);
        return self.read(a, id);
    }

    fn create(self: Mailbox, a: Allocator, outgoing: Outgoing, folder: []const u8, draft: bool) ![]const u8 {
        if (outgoing.to.len == 0) return error.MailRecipientRequired;
        var folders: std.json.ObjectMap = .empty;
        try folders.put(a, folder, .{ .bool = true });
        var keywords: std.json.ObjectMap = .empty;
        if (draft) try keywords.put(a, "$draft", .{ .bool = true });
        if (draft or std.mem.eql(u8, folder, self.archive_id))
            try keywords.put(a, "$seen", .{ .bool = true });
        var message = try value(a, .{
            .mailboxIds = Value{ .object = folders },
            .keywords = Value{ .object = keywords },
            .from = &[_]Address{.{ .email = self.address }},
            .to = outgoing.to,
            .subject = outgoing.subject,
            .textBody = &.{.{ .partId = "text", .type = "text/plain" }},
            .bodyValues = .{ .text = .{ .value = outgoing.body } },
        });
        if (outgoing.in_reply_to) |id|
            try message.object.put(a, "inReplyTo", try value(a, &[_][]const u8{id}));
        if (outgoing.references.len != 0)
            try message.object.put(a, "references", try value(a, outgoing.references));
        if (outgoing.purpose) |purpose|
            try message.object.put(a, purpose_property, .{ .string = @tagName(purpose) });
        const result = try self.call(a, "Email/set", .{
            .accountId = self.account_id,
            .create = .{ .letter = message },
        });
        return createdId(result, "letter");
    }

    /// Move only the caller's processed letters that still belong to Inbox.
    /// Other folder membership, including Sent, is preserved.
    pub fn archive(self: Mailbox, a: Allocator, ids: []const []const u8) !void {
        var offset: usize = 0;
        const batch_size = @min(self.max_get, self.max_set);
        while (offset < ids.len) {
            const end = offset + @min(batch_size, ids.len - offset);
            var updates: std.json.ObjectMap = .empty;
            for (try self.getRecords(a, ids[offset..end], false)) |record| {
                const folders = try field(record, "mailboxIds");
                if (folders != .object) return error.InvalidMailReply;
                if (!folders.object.contains(self.inbox_id)) continue;
                var patch: std.json.ObjectMap = .empty;
                try patch.put(a, try std.fmt.allocPrint(a, "mailboxIds/{s}", .{self.inbox_id}), .null);
                try patch.put(a, try std.fmt.allocPrint(a, "mailboxIds/{s}", .{self.archive_id}), .{ .bool = true });
                try updates.put(a, try textField(record, "id"), .{ .object = patch });
            }
            if (updates.count() != 0) {
                const result = try self.call(a, "Email/set", .{
                    .accountId = self.account_id,
                    .update = Value{ .object = updates },
                });
                for (updates.keys()) |id| {
                    if (!hasKey(result, "updated", id)) return error.InvalidMailReply;
                }
            }
            offset = end;
        }
    }

    /// Deletion policy and destructive lifecycle are deliberately unimplemented.
    pub fn deleteArchived(self: Mailbox, thread_id: []const u8) !void {
        _ = self;
        _ = thread_id;
        return error.ArchiveDeletionUnavailable;
    }

    /// Thread/get supplies chronological IDs. Inspect all metadata to find its
    /// latest handover, then fetch bodies only for the bounded recent tail.
    pub fn thread(self: Mailbox, a: Allocator, thread_id: []const u8, limit: usize) !Thread {
        const result = try self.call(a, "Thread/get", .{
            .accountId = self.account_id,
            .ids = &[_][]const u8{thread_id},
        });
        const threads = try arrayField(result, "list");
        if (threads.len == 0) return error.MailNotFound;
        const ids = try strings(a, try field(threads[0], "emailIds"));
        var recent_ids: std.ArrayList([]const u8) = .empty;
        var handover_id: ?[]const u8 = null;
        var has_inbox = false;
        var has_archive = false;
        var offset: usize = 0;
        while (offset < ids.len) {
            const end = offset + @min(self.max_get, ids.len - offset);
            for (try self.getRecords(a, ids[offset..end], false)) |record| {
                const letter = try self.decode(a, record, false);
                has_inbox = has_inbox or letter.in_inbox;
                has_archive = has_archive or letter.in_archive;
                if (isHandover(letter) and self.isSelf(letter)) {
                    handover_id = letter.id;
                } else if (limit != 0) {
                    if (recent_ids.items.len == limit) _ = recent_ids.orderedRemove(0);
                    try recent_ids.append(a, letter.id);
                }
            }
            offset = end;
        }
        var letters: std.ArrayList(Letter) = .empty;
        offset = 0;
        while (offset < recent_ids.items.len) {
            const end = offset + @min(self.max_get, recent_ids.items.len - offset);
            try self.appendAvailable(a, &letters, recent_ids.items[offset..end]);
            offset = end;
        }
        const handover = if (handover_id) |id| self.read(a, id) catch |err| switch (err) {
            error.MailNotFound, error.MailBodyUnavailable => null,
            else => return err,
        } else null;
        return .{
            .id = try a.dupe(u8, thread_id),
            .letters = try letters.toOwnedSlice(a),
            .handover = handover,
            .archived = has_archive and !has_inbox,
            .has_archived_history = has_archive,
        };
    }

    pub fn latestHandover(self: Mailbox, a: Allocator) !?Letter {
        var position: usize = 0;
        const filter = try self.recentFilter(a);
        while (true) {
            const ids = try self.queryIds(a, filter, false, position, self.max_get);
            if (ids.len == 0) return null;
            for (try self.getRecords(a, ids, false)) |record| {
                const letter = try self.decode(a, record, false);
                if (letter.purpose != .core_handover or !self.isSelf(letter)) continue;
                return self.read(a, letter.id) catch |err| switch (err) {
                    error.MailNotFound, error.MailBodyUnavailable => continue,
                    else => return err,
                };
            }
            position += ids.len;
        }
    }

    pub fn recent(self: Mailbox, a: Allocator, limit: usize) ![]const Letter {
        return self.queryLetters(a, try self.recentFilter(a), false, limit);
    }

    fn queryLetters(self: Mailbox, a: Allocator, filter: Value, unread_only: bool, limit: usize) ![]const Letter {
        var letters: std.ArrayList(Letter) = .empty;
        var position: usize = 0;
        while (letters.items.len < limit) {
            const ids = try self.queryIds(a, filter, unread_only, position, limit - letters.items.len);
            if (ids.len == 0) break;
            var available: std.ArrayList(Letter) = .empty;
            try self.appendAvailable(a, &available, ids);
            for (available.items) |letter| {
                if (isHandover(letter) and self.isSelf(letter)) continue;
                try letters.append(a, letter);
                if (letters.items.len == limit) break;
            }
            position += ids.len;
        }
        return letters.toOwnedSlice(a);
    }

    fn queryIds(self: Mailbox, a: Allocator, filter: Value, unread_only: bool, position: usize, limit: usize) ![]const []const u8 {
        const sort = if (unread_only) try value(a, .{
            .{ .property = "hasKeyword", .keyword = "$flagged", .isAscending = false },
            .{ .property = "receivedAt", .isAscending = true },
        }) else try value(a, .{.{ .property = "receivedAt", .isAscending = false }});
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

    fn recentFilter(self: Mailbox, a: Allocator) !Value {
        var conditions: std.ArrayList(Value) = .empty;
        try conditions.append(a, try value(a, .{ .notKeyword = "$draft" }));
        for (self.excluded_ids) |id| {
            try conditions.append(a, try value(a, .{
                .operator = "NOT",
                .conditions = &.{.{ .inMailbox = id }},
            }));
        }
        return value(a, .{ .operator = "AND", .conditions = conditions.items });
    }

    fn appendAvailable(self: Mailbox, a: Allocator, letters: *std.ArrayList(Letter), ids: []const []const u8) !void {
        for (try self.getRecords(a, ids, true)) |record| {
            const letter = self.decode(a, record, true) catch |err| switch (err) {
                error.MailBodyUnavailable => {
                    std.log.warn("mail {s} has no complete supported body", .{try textField(record, "id")});
                    continue;
                },
                else => return err,
            };
            try letters.append(a, letter);
        }
    }

    /// Preserve the requested order: Email/get need not return query order.
    fn getRecords(self: Mailbox, a: Allocator, ids: []const []const u8, body: bool) ![]const Value {
        const result = try self.call(a, "Email/get", .{
            .accountId = self.account_id,
            .ids = ids,
            .properties = if (body) body_properties else metadata_properties,
            .fetchTextBodyValues = body,
            .fetchHTMLBodyValues = body,
        });
        const records = try arrayField(result, "list");
        var ordered: std.ArrayList(Value) = .empty;
        for (ids) |id| {
            for (records) |record| {
                if (std.mem.eql(u8, id, try textField(record, "id"))) {
                    try ordered.append(a, record);
                    break;
                }
            }
        }
        return ordered.toOwnedSlice(a);
    }

    fn decode(self: Mailbox, a: Allocator, record: Value, body: bool) !Letter {
        const folders = try field(record, "mailboxIds");
        const keywords = try field(record, "keywords");
        if (folders != .object or keywords != .object) return error.InvalidMailReply;
        var purpose: ?Purpose = null;
        if (optionalText(record, purpose_property)) |text|
            purpose = std.meta.stringToEnum(Purpose, std.mem.trim(u8, text, " \t\r\n"));
        return .{
            .id = try textField(record, "id"),
            .thread_id = try textField(record, "threadId"),
            .message_id = try firstString(a, record, "messageId"),
            .in_reply_to = try firstString(a, record, "inReplyTo"),
            .references = if (optionalField(record, "references")) |refs| try strings(a, refs) else &.{},
            .from = try addresses(a, record, "from"),
            .to = try addresses(a, record, "to"),
            .subject = optionalText(record, "subject") orelse "",
            .body = if (body) try bodyText(a, record) else "",
            .purpose = purpose,
            .flagged = keywords.object.contains("$flagged"),
            .in_inbox = folders.object.contains(self.inbox_id),
            .in_archive = folders.object.contains(self.archive_id),
        };
    }

    fn isSelf(self: Mailbox, letter: Letter) bool {
        if (letter.from.len != 1 or !std.ascii.eqlIgnoreCase(letter.from[0].email, self.address)) return false;
        for (letter.to) |recipient|
            if (std.ascii.eqlIgnoreCase(recipient.email, self.address)) return true;
        return false;
    }

    /// Each call uses one invocation. Submission may additionally return an
    /// implicit Email/set result; method and object errors in every result
    /// must be checked before any success is returned.
    const Invocation = struct { result: Value, email_update: ?Value };

    fn call(self: Mailbox, a: Allocator, method: []const u8, arguments: anytype) !Value {
        return (try self.invoke(a, method, arguments)).result;
    }

    fn invoke(self: Mailbox, a: Allocator, method: []const u8, arguments: anytype) !Invocation {
        if (self.api_url.len == 0) return error.MailboxNotDiscovered;
        const payload = try std.json.Stringify.valueAlloc(a, .{
            .using = &[_][]const u8{ core_capability, mail_capability, submission_capability },
            .methodCalls = .{.{ method, arguments, "0" }},
        }, .{});
        const reply = try self.http(a, .POST, self.api_url, payload);
        var matched: ?Value = null;
        var email_update: ?Value = null;
        for (try arrayField(reply, "methodResponses")) |invocation| {
            if (invocation != .array or invocation.array.items.len != 3) return error.InvalidMailReply;
            const parts = invocation.array.items;
            if (parts[0] != .string or parts[2] != .string or !std.mem.eql(u8, parts[2].string, "0"))
                return error.InvalidMailReply;
            if (std.mem.eql(u8, parts[0].string, "error")) return error.MailMethodFailed;
            try checkObjectErrors(parts[1]);
            if (std.mem.eql(u8, parts[0].string, method)) {
                if (matched != null) return error.InvalidMailReply;
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

fn objectLimit(record: Value, name: []const u8) !usize {
    const item = optionalField(record, name) orelse return 32;
    if (item != .integer or item.integer <= 0) return error.InvalidMailReply;
    return @intCast(@min(item.integer, 32));
}

fn isHandover(letter: Letter) bool {
    return letter.purpose == .handover or letter.purpose == .core_handover;
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
            .name = optionalText(item, "name"),
            .email = try textField(item, "email"),
        };
    }
    return result;
}

fn firstString(a: Allocator, record: Value, name: []const u8) !?[]const u8 {
    const item = optionalField(record, name) orelse return null;
    const list = try strings(a, item);
    return if (list.len == 0) null else list[0];
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

const std = @import("std");
const Mail = @import("mail.zig");
const Allocator = std.mem.Allocator;

pub const Artifact = struct {
    file: []const u8,
    byte_length: usize,
};

pub const Artifacts = struct {
    body: Artifact,
    details: Artifact,
};

/// Receipt cache and source snapshots shared by the email and state adapters.
/// Work retains live receipts; captured files outlive the cache entries.
pub const MailSources = struct {
    allocator: Allocator,
    io: std.Io,
    mailbox: *Mail.Mailbox,
    data_directory: []const u8,
    mutex: std.Io.Mutex = .init,
    receipts: std.StringHashMapUnmanaged(*Receipt) = .empty,

    const Receipt = struct {
        arena: std.heap.ArenaAllocator,
        id: []const u8,
        letter: Mail.Letter,

        fn destroy(self: *Receipt, allocator: Allocator) void {
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    pub fn init(allocator: Allocator, io: std.Io, mailbox: *Mail.Mailbox, data_directory: []const u8) MailSources {
        return .{ .allocator = allocator, .io = io, .mailbox = mailbox, .data_directory = data_directory };
    }

    pub fn deinit(self: *MailSources) void {
        var receipts = self.receipts.valueIterator();
        while (receipts.next()) |receipt| receipt.*.destroy(self.allocator);
        self.receipts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn receiptId(self: *MailSources, a: Allocator, native_id: []const u8) ![]const u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("receipt");
        for ([_][]const u8{ self.mailbox.session_url, self.mailbox.account_id, native_id }) |component| {
            hash.update(&.{0});
            hash.update(component);
        }
        const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
        return std.fmt.allocPrint(a, "receipt-{s}", .{digest});
    }

    pub fn retain(self: *MailSources, id: []const u8, letter: Mail.Letter) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.receipts.contains(id)) return;
        const receipt = try self.allocator.create(Receipt);
        errdefer self.allocator.destroy(receipt);
        receipt.* = .{ .arena = .init(self.allocator), .id = undefined, .letter = undefined };
        errdefer receipt.arena.deinit();
        const a = receipt.arena.allocator();
        receipt.id = try a.dupe(u8, id);
        receipt.letter = try copyLetter(a, letter);
        try self.receipts.put(self.allocator, receipt.id, receipt);
    }

    /// Copy under the cache lock; callers own the result before doing any I/O.
    pub fn lookup(self: *MailSources, a: Allocator, id: []const u8) !Mail.Letter {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const receipt = self.receipts.get(id) orelse return error.DeliveryReceiptUnavailable;
        return copyLetter(a, receipt.letter);
    }

    /// Call after admissions with a registry-owned snapshot of live receipts.
    /// Source files persist independently of these in-memory execution handles.
    pub fn sweep(self: *MailSources, retained: []const []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var keys = self.receipts.keyIterator();
        while (keys.next()) |key| {
            const live = for (retained) |id| {
                if (std.mem.eql(u8, key.*, id)) break true;
            } else false;
            if (!live) try stale.append(self.allocator, key.*);
        }
        for (stale.items) |id| {
            const receipt = self.receipts.fetchRemove(id).?.value;
            receipt.destroy(self.allocator);
        }
    }

    /// Content is the adapter's complete text projection. The JSON file keeps
    /// the first snapshot of the decoded letter independently of its presentation.
    /// Historical captures do not retain a live receipt.
    pub fn capture(self: *MailSources, a: Allocator, letter: Mail.Letter, content: []const u8) !Artifacts {
        const id = try self.receiptId(a, letter.id);
        const directory = try std.fs.path.join(a, &.{ self.data_directory, "sources" });
        _ = try std.Io.Dir.cwd().createDirPathStatus(self.io, directory, .fromMode(0o700));
        var content_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
        const content_hash = std.fmt.bytesToHex(content_digest, .lower);
        const body_path = try std.fmt.allocPrint(a, "{s}/{s}-{s}.txt", .{ directory, id, content_hash });
        const details_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ directory, id });
        const details = try std.json.Stringify.valueAlloc(a, letter, .{ .whitespace = .indent_2 });
        const body_bytes = try self.writeArtifact(body_path, content);
        const details_bytes = try self.writeArtifact(details_path, details);
        return .{
            .body = .{ .file = body_path, .byte_length = body_bytes },
            .details = .{ .file = details_path, .byte_length = details_bytes },
        };
    }

    fn writeArtifact(self: *MailSources, path: []const u8, bytes: []const u8) !usize {
        const existing = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |stat| return std.math.cast(usize, stat.size) orelse error.SourceTooLarge;
        var file = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .permissions = .fromMode(0o600) });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, bytes);
        file.link(self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{});
                return std.math.cast(usize, stat.size) orelse error.SourceTooLarge;
            },
            else => return err,
        };
        return bytes.len;
    }
};

fn copyLetter(a: Allocator, letter: Mail.Letter) !Mail.Letter {
    return std.json.parseFromSliceLeaky(Mail.Letter, a, try std.json.Stringify.valueAlloc(a, letter, .{}), .{ .allocate = .alloc_always });
}

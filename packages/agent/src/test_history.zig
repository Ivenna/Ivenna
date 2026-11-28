const std = @import("std");
const Store = @import("agent_contracts").HistoryStore;
const Allocator = std.mem.Allocator;

/// In-memory history store with configurable checkpoint outcomes.
pub const TestStore = struct {
    pub const SaveFailure = enum { none, before_commit, after_commit };
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    groups: usize = 0,
    records: std.ArrayList(Store.Record) = .empty,
    checkpoint: ?[]const u8 = null,
    loads: usize = 0,
    saves: usize = 0,
    fail_save: SaveFailure = .none,

    pub fn port(self: *TestStore) Store {
        return .{ .context = self, .vtable = &.{
            .load = load,
            .allocateGroup = allocateGroup,
            .query = query,
            .read = read,
            .create = create,
            .save = save,
            .maintain = maintain,
        } };
    }

    fn load(context: *anyopaque, a: Allocator) anyerror!?[]const u8 {
        const self: *TestStore = @ptrCast(@alignCast(context));
        self.loads += 1;
        return if (self.checkpoint) |body| try a.dupe(u8, body) else null;
    }

    fn allocateGroup(context: *anyopaque, a: Allocator) anyerror![]const u8 {
        const self: *TestStore = @ptrCast(@alignCast(context));
        self.groups += 1;
        return std.fmt.allocPrint(a, "group-{d}", .{self.groups});
    }

    fn query(context: *anyopaque, a: Allocator, groups: []const []const u8) anyerror![]const Store.Reference {
        const self: *TestStore = @ptrCast(@alignCast(context));
        var references: std.ArrayList(Store.Reference) = .empty;
        for (self.records.items) |record| {
            for (groups) |group| {
                if (!std.mem.eql(u8, group, record.group)) continue;
                try references.append(a, .{
                    .group = try a.dupe(u8, record.group),
                    .key = record.key,
                    .previous = record.previous,
                    .locator = "",
                    .stored_bytes = record.body.len,
                });
                break;
            }
        }
        return references.toOwnedSlice(a);
    }

    fn read(context: *anyopaque, a: Allocator, references: []const Store.Reference) anyerror![]const []const u8 {
        const self: *TestStore = @ptrCast(@alignCast(context));
        const bodies = try a.alloc([]const u8, references.len);
        for (references, bodies) |reference, *body| {
            for (self.records.items) |record| {
                if (std.mem.eql(u8, record.group, reference.group) and std.mem.eql(u8, &record.key, &reference.key)) {
                    body.* = try a.dupe(u8, record.body);
                    break;
                }
            } else return error.MissingTestRecord;
        }
        return bodies;
    }

    fn create(context: *anyopaque, _: Allocator, records: []const Store.Record) anyerror!void {
        const self: *TestStore = @ptrCast(@alignCast(context));
        const a = self.arena.allocator();
        for (records) |record| {
            var owned = record;
            owned.group = try a.dupe(u8, record.group);
            owned.body = try a.dupe(u8, record.body);
            try self.records.append(a, owned);
        }
    }

    fn save(context: *anyopaque, body: []const u8) anyerror!void {
        const self: *TestStore = @ptrCast(@alignCast(context));
        self.saves += 1;
        if (self.fail_save == .before_commit) return error.MailMutationUnconfirmed;
        self.checkpoint = try self.arena.allocator().dupe(u8, body);
        if (self.fail_save == .after_commit) return error.MailMutationUnconfirmed;
    }

    fn maintain(_: *anyopaque, _: Allocator, _: Store.Retention) anyerror!void {}
};

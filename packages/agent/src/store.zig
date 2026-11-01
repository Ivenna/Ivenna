const std = @import("std");
const pg = @import("pg");

const Allocator = std.mem.Allocator;

/// Strings belong to the allocator supplied to getSession.
pub const Session = struct {
    id: i64,
    user_fields_json: []const u8,
    status: []const u8,
    messages_json: []const u8,
    pending_inputs_json: []const u8,
    error_message: ?[]const u8,
};

pub const Store = struct {
    pool: *pg.Pool,

    pub fn init(io: std.Io, allocator: Allocator, database_url: []const u8) !Store {
        return .{ .pool = try pg.Pool.initUri(io, allocator, try std.Uri.parse(database_url), .{ .size = 4 }) };
    }

    /// Call only after every task using the store has been joined.
    pub fn deinit(self: *Store) void {
        self.pool.deinit();
    }

    pub fn initializeSchema(self: *Store) !void {
        _ = try self.pool.exec(@embedFile("schema.sql"), .{});
    }

    /// Startup recovery assumes this is the only service process using the
    /// session store. Resume previously running sessions from their last checkpoint.
    pub fn recoverInterrupted(self: *Store) !void {
        _ = try self.pool.exec(
            "UPDATE agent_sessions SET status = 'pending', updated_at = now() WHERE status = 'running'",
            .{},
        );
    }

    pub fn createSession(self: *Store, user_fields_json: []const u8, messages_json: []const u8) !i64 {
        var row = (try self.pool.row(
            "INSERT INTO agent_sessions (user_fields, messages_json) VALUES ($1::jsonb, $2::jsonb) RETURNING id",
            .{ user_fields_json, messages_json },
        )) orelse return error.SessionNotCreated;
        defer row.result.deinit();
        const id = try row.get(i64, 0);
        try row.result.drain();
        return id;
    }

    pub fn getSession(self: *Store, allocator: Allocator, id: i64) !?Session {
        var row = (try self.pool.row(
            "SELECT id, user_fields, status, messages_json, pending_inputs, error_message FROM agent_sessions WHERE id = $1",
            .{id},
        )) orelse return null;
        defer row.result.deinit();
        const session = try copySession(allocator, &row);
        errdefer freeSession(allocator, session);
        try row.result.drain();
        return session;
    }

    pub fn userFields(self: *Store, allocator: Allocator, id: i64) ![]const u8 {
        var row = (try self.pool.row(
            "SELECT user_fields FROM agent_sessions WHERE id = $1",
            .{id},
        )) orelse return error.SessionNotFound;
        defer row.result.deinit();
        const fields = try allocator.dupe(u8, try row.get([]const u8, 0));
        errdefer allocator.free(fields);
        try row.result.drain();
        return fields;
    }

    pub fn pendingSessionIds(self: *Store, allocator: Allocator) ![]const i64 {
        var result = try self.pool.query("SELECT id FROM agent_sessions WHERE status = 'pending' ORDER BY id", .{});
        defer result.deinit();
        var ids: std.array_list.Managed(i64) = .init(allocator);
        errdefer ids.deinit();
        while (try result.next()) |row| try ids.append(try row.get(i64, 0));
        return ids.toOwnedSlice();
    }

    pub fn submitInput(self: *Store, id: i64, message_json: []const u8) !void {
        const affected = try self.pool.exec(
            \\ UPDATE agent_sessions
            \\ SET pending_inputs = pending_inputs || jsonb_build_array($2::jsonb),
            \\     status = CASE WHEN status = 'running' THEN 'running' ELSE 'pending' END,
            \\     error_message = NULL, updated_at = now()
            \\ WHERE id = $1
        , .{ id, message_json });
        if ((affected orelse 0) != 1) return error.SessionNotFound;
    }

    pub fn resumeSession(self: *Store, id: i64) !void {
        const affected = try self.pool.exec(
            \\ UPDATE agent_sessions SET status = 'pending', error_message = NULL, updated_at = now()
            \\ WHERE id = $1 AND status IN ('waiting', 'failed', 'pending')
        , .{id});
        if ((affected orelse 0) != 1) return error.SessionNotAvailable;
    }

    pub fn claimSession(self: *Store, id: i64) !void {
        const affected = try self.pool.exec(
            \\ UPDATE agent_sessions
            \\ SET status = 'running', messages_json = messages_json || pending_inputs,
            \\     pending_inputs = '[]', error_message = NULL, updated_at = now()
            \\ WHERE id = $1 AND status = 'pending'
        , .{id});
        if ((affected orelse 0) != 1) return error.SessionNotAvailable;
    }

    pub fn checkpoint(
        self: *Store,
        id: i64,
        messages_json: []const u8,
        waiting: bool,
    ) !bool {
        // Appending the inbox and deciding whether to sleep are one update.
        // Input arriving during a model request cannot be overwritten or left
        // waiting for a worker that has already gone to sleep.
        var row = (try self.pool.row(
            \\ UPDATE agent_sessions
            \\ SET messages_json = $2::jsonb || pending_inputs, pending_inputs = '[]',
            \\     status = CASE WHEN $3 AND jsonb_array_length(pending_inputs) = 0
            \\                   THEN 'waiting' ELSE 'running' END,
            \\     updated_at = now()
            \\ WHERE id = $1 AND status = 'running'
            \\ RETURNING status = 'waiting'
        , .{ id, messages_json, waiting })) orelse return error.SessionNotAvailable;
        defer row.result.deinit();
        const paused = try row.get(bool, 0);
        try row.result.drain();
        return paused;
    }

    pub fn failSession(self: *Store, id: i64, error_message: []const u8) !void {
        _ = try self.pool.exec(
            \\ UPDATE agent_sessions SET status = 'failed', error_message = $2, updated_at = now()
            \\ WHERE id = $1 AND status = 'running'
        , .{ id, error_message });
    }
};

fn copySession(allocator: Allocator, row: *pg.QueryRow) !Session {
    const user_fields_json = try allocator.dupe(u8, try row.get([]const u8, 1));
    errdefer allocator.free(user_fields_json);
    const status = try allocator.dupe(u8, try row.get([]const u8, 2));
    errdefer allocator.free(status);
    const messages_json = try allocator.dupe(u8, try row.get([]const u8, 3));
    errdefer allocator.free(messages_json);
    const pending_inputs_json = try allocator.dupe(u8, try row.get([]const u8, 4));
    errdefer allocator.free(pending_inputs_json);
    const error_message = if (try row.get(?[]const u8, 5)) |value| try allocator.dupe(u8, value) else null;
    errdefer if (error_message) |value| allocator.free(value);
    return .{
        .id = try row.get(i64, 0),
        .user_fields_json = user_fields_json,
        .status = status,
        .messages_json = messages_json,
        .pending_inputs_json = pending_inputs_json,
        .error_message = error_message,
    };
}

fn freeSession(allocator: Allocator, session: Session) void {
    allocator.free(session.user_fields_json);
    allocator.free(session.status);
    allocator.free(session.messages_json);
    allocator.free(session.pending_inputs_json);
    if (session.error_message) |value| allocator.free(value);
}

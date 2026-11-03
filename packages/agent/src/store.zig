const std = @import("std");
const c = @import("sqlite");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const State = union(enum) {
    waiting,
    pending,
    running,
    failed: []const u8,
};

/// Strings belong to the allocator supplied to getSession.
pub const Session = struct {
    id: i64,
    user_fields_json: []const u8,
    state: State,
    messages_json: []const u8,
    pending_inputs_json: []const u8,
};

pub const Store = struct {
    io: std.Io,
    allocator: Allocator,
    database: *c.sqlite3,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, allocator: Allocator, database_path: [:0]const u8) !Store {
        var database: ?*c.sqlite3 = null;
        const result = c.sqlite3_open_v2(database_path.ptr, &database, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null);
        const handle = database orelse {
            std.log.err("could not open SQLite database ({d}): {s}", .{ result, c.sqlite3_errstr(result) });
            return if (result == c.SQLITE_NOMEM) error.OutOfMemory else error.DatabaseOpenFailed;
        };
        var self: Store = .{ .io = io, .allocator = allocator, .database = handle };
        errdefer self.deinit();
        try self.check(result, "open database");
        try self.check(c.sqlite3_extended_result_codes(handle, 1), "enable extended error codes");
        return self;
    }

    /// Call only after every task using the store has been joined.
    pub fn deinit(self: *Store) void {
        const result = c.sqlite3_close(self.database);
        if (result != c.SQLITE_OK) {
            std.log.err("could not close SQLite database ({d}): {s}", .{ result, c.sqlite3_errmsg(self.database) });
        }
    }

    pub fn initializeSchema(self: *Store) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        try self.execute(@embedFile("schema.sql"));
    }

    /// Startup recovery assumes this is the only service process using the
    /// session store. Resume unfinished sessions from their last checkpoint.
    pub fn recoverInterrupted(self: *Store) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        try self.execute("UPDATE agent_sessions SET status = 'pending', updated_at = CURRENT_TIMESTAMP WHERE status = 'running'");
    }

    pub fn createSession(self: *Store, user_fields_json: []const u8, messages_json: []const u8) !i64 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare("INSERT INTO agent_sessions (user_fields, messages_json) VALUES (?1, ?2)");
        defer statement.deinit();
        try statement.bindText(1, user_fields_json);
        try statement.bindText(2, messages_json);
        try statement.execute();
        return c.sqlite3_last_insert_rowid(self.database);
    }

    pub fn getSession(self: *Store, allocator: Allocator, id: i64) !?Session {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare("SELECT id, user_fields, status, messages_json, pending_inputs, error_message FROM agent_sessions WHERE id = ?1");
        defer statement.deinit();
        try statement.bindInt(1, id);
        if (!try statement.step()) return null;
        return try copySession(allocator, statement);
    }

    pub fn history(self: *Store, allocator: Allocator, id: i64) ![]const u8 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare("SELECT messages_json FROM agent_sessions WHERE id = ?1");
        defer statement.deinit();
        try statement.bindInt(1, id);
        if (!try statement.step()) return error.SessionNotFound;
        return allocator.dupe(u8, try statement.text(0));
    }

    pub fn userFields(self: *Store, allocator: Allocator, id: i64) ![]const u8 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare("SELECT user_fields FROM agent_sessions WHERE id = ?1");
        defer statement.deinit();
        try statement.bindInt(1, id);
        if (!try statement.step()) return error.SessionNotFound;
        return allocator.dupe(u8, try statement.text(0));
    }

    pub fn pendingSessionIds(self: *Store, allocator: Allocator) ![]const i64 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare("SELECT id FROM agent_sessions WHERE status = 'pending' ORDER BY id");
        defer statement.deinit();
        var ids: std.array_list.Managed(i64) = .init(allocator);
        errdefer ids.deinit();
        while (try statement.step()) try ids.append(c.sqlite3_column_int64(statement.handle, 0));
        return ids.toOwnedSlice();
    }

    pub fn submitInput(self: *Store, id: i64, message_json: []const u8) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare(
            \\ UPDATE agent_sessions
            \\ SET pending_inputs = json_insert(pending_inputs, '$[#]', json(?2)),
            \\     status = CASE WHEN status = 'running' THEN 'running' ELSE 'pending' END,
            \\     error_message = NULL, updated_at = CURRENT_TIMESTAMP
            \\ WHERE id = ?1
        );
        defer statement.deinit();
        try statement.bindInt(1, id);
        try statement.bindText(2, message_json);
        try statement.execute();
        if (c.sqlite3_changes64(self.database) != 1) return error.SessionNotFound;
    }

    pub fn resumeSession(self: *Store, id: i64) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare(
            \\ UPDATE agent_sessions SET status = 'pending', error_message = NULL, updated_at = CURRENT_TIMESTAMP
            \\ WHERE id = ?1 AND status IN ('waiting', 'failed', 'pending')
        );
        defer statement.deinit();
        try statement.bindInt(1, id);
        try statement.execute();
        if (c.sqlite3_changes64(self.database) != 1) return error.SessionNotAvailable;
    }

    pub fn claimSession(self: *Store, id: i64) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const merged = blk: {
            const statement = try self.prepare("SELECT messages_json, pending_inputs FROM agent_sessions WHERE id = ?1 AND status = 'pending'");
            defer statement.deinit();
            try statement.bindInt(1, id);
            if (!try statement.step()) return error.SessionNotAvailable;
            break :blk try appendInputs(a, try statement.text(0), try statement.text(1));
        };
        const statement = try self.prepare(
            \\ UPDATE agent_sessions
            \\ SET status = 'running', messages_json = ?2, pending_inputs = '[]',
            \\     error_message = NULL, updated_at = CURRENT_TIMESTAMP
            \\ WHERE id = ?1 AND status = 'pending'
        );
        defer statement.deinit();
        try statement.bindInt(1, id);
        try statement.bindText(2, merged.json);
        try statement.execute();
        if (c.sqlite3_changes64(self.database) != 1) return error.SessionNotAvailable;
        try self.execute("COMMIT");
    }

    pub fn checkpoint(self: *Store, id: i64, messages_json: []const u8, waiting: bool) !bool {
        try self.lock();
        defer self.mutex.unlock(self.io);
        // Merging queued input and deciding whether to pause share a transaction.
        // No model or tool work runs while this transaction is open.
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const merged = blk: {
            const statement = try self.prepare("SELECT pending_inputs FROM agent_sessions WHERE id = ?1 AND status = 'running'");
            defer statement.deinit();
            try statement.bindInt(1, id);
            if (!try statement.step()) return error.SessionNotAvailable;
            break :blk try appendInputs(a, messages_json, try statement.text(0));
        };
        const paused = waiting and merged.input_count == 0;
        const statement = try self.prepare(
            \\ UPDATE agent_sessions
            \\ SET messages_json = ?2, pending_inputs = '[]', status = ?3,
            \\     updated_at = CURRENT_TIMESTAMP
            \\ WHERE id = ?1 AND status = 'running'
        );
        defer statement.deinit();
        try statement.bindInt(1, id);
        try statement.bindText(2, merged.json);
        try statement.bindText(3, if (paused) "waiting" else "running");
        try statement.execute();
        if (c.sqlite3_changes64(self.database) != 1) return error.SessionNotAvailable;
        try self.execute("COMMIT");
        return paused;
    }

    pub fn failSession(self: *Store, id: i64, error_message: []const u8) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const statement = try self.prepare(
            \\ UPDATE agent_sessions SET status = 'failed', error_message = ?2, updated_at = CURRENT_TIMESTAMP
            \\ WHERE id = ?1 AND status = 'running'
        );
        defer statement.deinit();
        try statement.bindInt(1, id);
        try statement.bindText(2, error_message);
        try statement.execute();
        if (c.sqlite3_changes64(self.database) != 1) return error.SessionNotAvailable;
    }

    fn lock(self: *Store) !void {
        try self.io.checkCancel();
        try self.mutex.lock(self.io);
    }

    fn execute(self: *Store, sql: [:0]const u8) !void {
        try self.check(c.sqlite3_exec(self.database, sql.ptr, null, null, null), "execute SQL");
    }

    fn rollback(self: *Store) void {
        self.execute("ROLLBACK") catch |err| {
            std.log.err("could not roll back the session transaction: {s}", .{@errorName(err)});
        };
    }

    fn prepare(self: *Store, sql: [:0]const u8) !Statement {
        var handle: ?*c.sqlite3_stmt = null;
        try self.check(c.sqlite3_prepare_v2(self.database, sql.ptr, -1, &handle, null), "prepare statement");
        return .{ .store = self, .handle = handle.? };
    }

    fn check(self: *Store, result: c_int, operation: []const u8) !void {
        if (result == c.SQLITE_OK) return;
        return self.failure(result, operation);
    }

    fn failure(self: *Store, result: c_int, operation: []const u8) anyerror {
        std.log.err("SQLite {s} failed ({d}): {s}", .{ operation, result, c.sqlite3_errmsg(self.database) });
        return switch (result & 0xff) {
            c.SQLITE_NOMEM => error.OutOfMemory,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
            c.SQLITE_CANTOPEN => error.DatabaseOpenFailed,
            c.SQLITE_READONLY => error.DatabaseReadOnly,
            c.SQLITE_IOERR => error.DatabaseIoFailure,
            c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.InvalidDatabase,
            c.SQLITE_FULL => error.DatabaseFull,
            c.SQLITE_CONSTRAINT => error.DatabaseConstraint,
            else => error.DatabaseFailure,
        };
    }
};

const Statement = struct {
    store: *Store,
    handle: *c.sqlite3_stmt,

    fn deinit(self: Statement) void {
        const result = c.sqlite3_finalize(self.handle);
        if (result != c.SQLITE_OK) {
            std.log.err("could not finalize SQLite statement ({d}): {s}", .{ result, c.sqlite3_errmsg(self.store.database) });
        }
    }

    fn bindInt(self: Statement, index: c_int, value: i64) !void {
        try self.store.check(c.sqlite3_bind_int64(self.handle, index, value), "bind integer");
    }

    fn bindText(self: Statement, index: c_int, value: []const u8) !void {
        // The caller's text remains alive until this statement is finalized.
        try self.store.check(c.sqlite3_bind_text64(self.handle, index, value.ptr, value.len, null, c.SQLITE_UTF8), "bind text");
    }

    fn step(self: Statement) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| self.store.failure(result, "step statement"),
        };
    }

    fn execute(self: Statement) !void {
        if (try self.step()) {
            std.log.err("SQLite statement returned an unexpected row", .{});
            return error.UnexpectedDatabaseResult;
        }
    }

    fn text(self: Statement, column: c_int) ![]const u8 {
        if (c.sqlite3_column_type(self.handle, column) == c.SQLITE_NULL) {
            std.log.err("SQLite session row has unexpected NULL at column {d}", .{column});
            return error.InvalidDatabaseState;
        }
        const value = c.sqlite3_column_text(self.handle, column);
        if (value == null) return self.store.failure(c.SQLITE_NOMEM, "read text");
        return value[0..@intCast(c.sqlite3_column_bytes(self.handle, column))];
    }
};

const JoinedHistory = struct { json: []const u8, input_count: usize };

fn appendInputs(allocator: Allocator, messages_json: []const u8, inputs_json: []const u8) !JoinedHistory {
    const inputs = try std.json.parseFromSliceLeaky([]Value, allocator, inputs_json, .{});
    if (inputs.len == 0) return .{ .json = try allocator.dupe(u8, messages_json), .input_count = 0 };
    const messages = try std.json.parseFromSliceLeaky([]Value, allocator, messages_json, .{});
    const combined = try allocator.alloc(Value, messages.len + inputs.len);
    @memcpy(combined[0..messages.len], messages);
    @memcpy(combined[messages.len..], inputs);
    return .{ .json = try std.json.Stringify.valueAlloc(allocator, combined, .{}), .input_count = inputs.len };
}

fn copySession(allocator: Allocator, statement: Statement) !Session {
    const user_fields_json = try allocator.dupe(u8, try statement.text(1));
    errdefer allocator.free(user_fields_json);
    const status = std.meta.stringToEnum(std.meta.Tag(State), try statement.text(2)) orelse return error.InvalidDatabaseState;
    const state: State = switch (status) {
        .waiting => .waiting,
        .pending => .pending,
        .running => .running,
        .failed => .{ .failed = try allocator.dupe(u8, try statement.text(5)) },
    };
    errdefer switch (state) {
        .failed => |message| allocator.free(message),
        else => {},
    };
    const messages_json = try allocator.dupe(u8, try statement.text(3));
    errdefer allocator.free(messages_json);
    const pending_inputs_json = try allocator.dupe(u8, try statement.text(4));
    return .{
        .id = c.sqlite3_column_int64(statement.handle, 0),
        .user_fields_json = user_fields_json,
        .state = state,
        .messages_json = messages_json,
        .pending_inputs_json = pending_inputs_json,
    };
}

const std = @import("std");
const Shell = @import("shell.zig").Shell;
const Content = @import("content").Content;

const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const Tools = contracts.Tools;
const Model = contracts.Model;
const Callback = contracts.Callback;

/// Owns shell execution, including activities that outlive their tool calls.
pub const Host = struct {
    allocator: Allocator,
    shell: Shell,
    publisher: Callback.Publisher,
    max_background_commands: usize,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    tasks: std.Io.Group = .init,
    active: usize = 0,
    stopping: bool = false,
    failure: ?anyerror = null,

    pub const Context = Tools.Invocation;

    pub fn init(allocator: Allocator, io: std.Io, directory: []const u8, data_directory: []const u8, environ: *const std.process.Environ.Map, publisher: Callback.Publisher, max_background_commands: usize) Host {
        return .{
            .allocator = allocator,
            .shell = .{ .io = io, .directory = directory, .data_directory = data_directory, .environ = environ },
            .publisher = publisher,
            .max_background_commands = max_background_commands,
        };
    }

    pub fn deinit(self: *Host) void {
        self.stop();
        self.* = undefined;
    }

    /// The application supervises this scope alongside the kernel. Canceling
    /// it stops and joins all commands before host dependencies are released.
    pub fn run(self: *Host) !void {
        defer self.stop();
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        while (self.failure == null) try self.changed.wait(self.shell.io, &self.mutex);
        return self.failure.?;
    }

    /// Declarations belong to a and must outlive their registration with Engine.
    pub fn tools(self: *Host, a: Allocator) !Tools {
        return .{
            .context = self,
            .invoke = invokeTool,
            .declarations = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{}),
        };
    }

    fn invokeTool(context: *anyopaque, a: Allocator, invocation: Tools.Invocation, name: []const u8, arguments: []const u8) anyerror!?Content {
        const self: *Host = @ptrCast(@alignCast(context));
        const request = try Request.parse(a, name, arguments) orelse return null;
        return try self.invoke(a, invocation, request);
    }

    pub const Request = union(enum) {
        get_host_shell: struct {},
        run_host_shell: Shell.Command,

        pub fn parse(a: Allocator, name: []const u8, arguments: []const u8) !?Request {
            const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
            const request: Request = switch (tag) {
                inline else => |active| @unionInit(Request, @tagName(active), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(active)), a, arguments, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidToolArguments,
                }),
            };
            switch (request) {
                .get_host_shell => {},
                .run_host_shell => |args| {
                    if (!validText(args.command)) return error.InvalidToolArguments;
                    if (args.cwd) |cwd| if (!validText(cwd)) return error.InvalidToolArguments;
                    if (args.timeout_ms == 0) return error.InvalidToolArguments;
                },
            }
            return request;
        }
    };

    pub fn invoke(self: *Host, a: Allocator, context: Context, request: Request) !Content {
        if (request == .run_host_shell and request.run_host_shell.background)
            return self.startBackground(a, context, request.run_host_shell);
        return self.respond(a, context, request) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => Content.fromText(a, try failure(a, "host_unavailable", switch (request) {
                .run_host_shell => try std.fmt.allocPrint(a, "Could not return the command result: {s}. The host may have changed.", .{@errorName(err)}),
                .get_host_shell => try std.fmt.allocPrint(a, "Could not describe the host shell: {s}.", .{@errorName(err)}),
            })),
        };
    }

    fn respond(self: *Host, a: Allocator, context: Context, request: Request) !Content {
        return switch (request) {
            .get_host_shell => Content.fromText(a, try success(a, self.shell.describe())),
            .run_host_shell => |args| blk: {
                const result = try self.shell.run(a, .{ .session_id = context.session_id }, args);
                const description = try success(a, result.describe());
                switch (result.stdout.content) {
                    .image => |image| break :blk Content.fromParts(a, &.{
                        .{ .text = description },
                        .{ .image = image },
                    }),
                    .text, .unavailable => {},
                }
                break :blk Content.fromText(a, description);
            },
        };
    }

    const Activity = struct {
        arena: std.heap.ArenaAllocator,
        session_id: u64,
        callback_id: u64,
        command: Shell.Command,

        fn destroy(self: *Activity, allocator: Allocator) void {
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    fn startBackground(self: *Host, a: Allocator, context: Context, args: Shell.Command) !Content {
        const registrar = context.callback orelse return Content.fromText(a, try failure(a, "background_unavailable", "This invocation has no callback destination."));
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        if (self.stopping) return error.Canceled;
        if (self.active >= self.max_background_commands)
            return Content.fromText(a, try failure(a, "background_unavailable", "The background command limit has been reached."));

        const activity = try self.allocator.create(Activity);
        activity.* = .{
            .arena = .init(self.allocator),
            .session_id = context.session_id,
            .callback_id = undefined,
            .command = args,
        };
        var launched = false;
        defer if (!launched) activity.destroy(self.allocator);
        const owned = activity.arena.allocator();
        activity.command.command = try owned.dupe(u8, args.command);
        activity.command.cwd = if (args.cwd) |cwd| try owned.dupe(u8, cwd) else null;
        // The registrar belongs to this invocation. Retain only its assigned
        // callback identity; its destination cannot be changed by the command.
        activity.callback_id = registrar.open() catch |err| switch (err) {
            error.CallbackCapacityUnavailable => return Content.fromText(a, try failure(a, "background_unavailable", "The session's callback source limit has been reached.")),
            else => return err,
        };
        const accepted = try Content.fromText(a, try success(a, .{ .running = .{ .activity_id = activity.callback_id } }));
        self.active += 1;
        errdefer self.active -= 1;
        try self.tasks.concurrent(self.shell.io, runBackground, .{ self, activity });
        launched = true;
        return accepted;
    }

    fn runBackground(self: *Host, activity: *Activity) std.Io.Cancelable!void {
        defer activity.destroy(self.allocator);
        defer {
            self.mutex.lockUncancelable(self.shell.io);
            self.active -= 1;
            self.mutex.unlock(self.shell.io);
        }
        self.completeBackground(activity) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.mutex.lockUncancelable(self.shell.io);
            defer self.mutex.unlock(self.shell.io);
            self.failLocked(err);
        };
    }

    fn completeBackground(self: *Host, activity: *Activity) !void {
        const a = activity.arena.allocator();
        const result = self.shell.run(a, .{ .session_id = activity.session_id }, activity.command) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => {
                try self.publisher.send(a, .{
                    .id = activity.callback_id,
                    .text = try failure(a, "host_unavailable", try std.fmt.allocPrint(a, "Could not return the command result: {s}. The host may have changed.", .{@errorName(err)})),
                });
                return;
            },
        };
        const text = try std.json.Stringify.valueAlloc(a, .{
            .result = result.describe(),
            .media_omission = if (result.stdout.content == .image) @as(?[]const u8, "asynchronous_media_unavailable") else null,
        }, .{ .emit_null_optional_fields = false });
        try self.publisher.send(a, .{ .id = activity.callback_id, .text = text });
    }

    fn failLocked(self: *Host, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        self.changed.signal(self.shell.io);
    }

    fn stop(self: *Host) void {
        self.mutex.lockUncancelable(self.shell.io);
        self.stopping = true;
        self.mutex.unlock(self.shell.io);
        self.tasks.cancel(self.shell.io);
    }
};

const ToolError = struct { code: []const u8, message: []const u8 };

fn Reply(comptime T: type) type {
    return union(enum) { result: T, @"error": ToolError };
}

fn success(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, Reply(@TypeOf(value)){ .result = value }, .{});
}

fn failure(a: Allocator, code: []const u8, message: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, Reply(void){ .@"error" = .{ .code = code, .message = message } }, .{});
}

fn validText(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null;
}

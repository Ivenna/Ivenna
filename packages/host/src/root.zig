const std = @import("std");
const Shell = @import("shell.zig").Shell;
const Content = @import("content").Content;

const Allocator = std.mem.Allocator;
const Tools = @import("agent").Tools;
const Model = @import("agent").Model;

/// Routes host operations and returns content owned by the current turn.
pub const Host = struct {
    shell: Shell,

    pub const Context = Shell.Context;

    pub fn init(io: std.Io, directory: []const u8, data_directory: []const u8, environ: *const std.process.Environ.Map) Host {
        return .{
            .shell = .{ .io = io, .directory = directory, .data_directory = data_directory, .environ = environ },
        };
    }

    /// Declarations belong to a and must outlive their registration with Engine.
    pub fn tools(self: *Host, a: Allocator) !Tools {
        return .{
            .context = self,
            .invoke = invokeTool,
            .declarations = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{}),
        };
    }

    fn invokeTool(context: *anyopaque, a: Allocator, session_id: u64, name: []const u8, arguments: []const u8) anyerror!?Content {
        const self: *Host = @ptrCast(@alignCast(context));
        const request = try Request.parse(a, name, arguments) orelse return null;
        return try self.invoke(a, .{ .session_id = session_id }, request);
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
                const result = try self.shell.run(a, context, args);
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

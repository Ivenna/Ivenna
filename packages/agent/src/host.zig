const std = @import("std");
const Shell = @import("host/shell.zig").Shell;
const Content = @import("content.zig").Content;

const Allocator = std.mem.Allocator;

/// Routes host operations and returns content owned by the current turn.
pub const Host = struct {
    shell: Shell,

    pub const Context = Shell.Context;

    pub fn init(io: std.Io, directory: []const u8, data_directory: []const u8, environ: *const std.process.Environ.Map) Host {
        return .{
            .shell = .{ .io = io, .directory = directory, .data_directory = data_directory, .environ = environ },
        };
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
            else => .{ .text = try failure(a, "host_unavailable", switch (request) {
                .run_host_shell => try std.fmt.allocPrint(a, "Could not return the command result: {s}. The host may have changed.", .{@errorName(err)}),
                .get_host_shell => try std.fmt.allocPrint(a, "Could not describe the host shell: {s}.", .{@errorName(err)}),
            }) },
        };
    }

    fn respond(self: *Host, a: Allocator, context: Context, request: Request) !Content {
        return switch (request) {
            .get_host_shell => .{ .text = try success(a, self.shell.describe()) },
            .run_host_shell => |args| blk: {
                const result = try self.shell.run(a, context, args);
                const succeeded = switch (result.outcome) {
                    .completed => |term| term == .exited and term.exited == 0,
                    .timed_out => false,
                };
                if (succeeded) {
                    switch (result.stdout.content) {
                        .image => |image| break :blk .{ .image = image },
                        .text, .unavailable => {},
                    }
                }
                break :blk .{ .text = try success(a, result.describe()) };
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

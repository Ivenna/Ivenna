const std = @import("std");
const Shell = @import("host/shell.zig").Shell;

const Allocator = std.mem.Allocator;

/// Routes LLM host requests and serializes their replies. Engine supplies the
/// conversation identity; Shell owns execution and control.
pub const Host = struct {
    shell: Shell,

    pub const Context = Shell.Context;

    pub fn init(io: std.Io, directory: []const u8, environ: *const std.process.Environ.Map) Host {
        return .{
            .shell = .{ .io = io, .directory = directory, .environ = environ },
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

    pub fn invoke(self: *Host, allocator: Allocator, context: Context, request: Request) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const response = self.respond(a, context, request) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => try failure(a, "host_unavailable", try std.fmt.allocPrint(a, "Could not return the command result: {s}. The host may have changed; inspect it before retrying.", .{@errorName(err)})),
        };
        return allocator.dupe(u8, response);
    }

    fn respond(self: *Host, a: Allocator, context: Context, request: Request) ![]const u8 {
        return switch (request) {
            .get_host_shell => success(a, self.shell.describe()),
            .run_host_shell => |args| success(a, try self.shell.run(a, context, args)),
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

const std = @import("std");
const Shell = @import("host/shell.zig").Shell;
const RecommendedTools = @import("host/recommended_tools.zig").RecommendedTools;

const Allocator = std.mem.Allocator;

/// Routes LLM host requests and serializes their replies. Engine supplies the
/// conversation identity; Shell and RecommendedTools own execution and discovery.
pub const Host = struct {
    shell: Shell,
    recommended_tools: RecommendedTools,

    pub const Context = Shell.Context;

    pub fn init(io: std.Io, directory: []const u8, environ: *const std.process.Environ.Map) Host {
        return .{
            .shell = .{ .io = io, .directory = directory, .environ = environ },
            .recommended_tools = .{ .io = io, .directory = directory },
        };
    }

    pub const Request = union(enum) {
        get_host_shell: struct {},
        run_host_shell: Shell.Command,
        get_recommended_tools: struct {},

        pub fn parse(a: Allocator, name: []const u8, arguments: []const u8) !?Request {
            const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
            const request: Request = switch (tag) {
                inline else => |active| @unionInit(Request, @tagName(active), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(active)), a, arguments, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidToolArguments,
                }),
            };
            switch (request) {
                .get_host_shell, .get_recommended_tools => {},
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
            error.EnvironmentUnavailable => try failure(a, "shell_unavailable", "The host shell environment is unavailable. Ask the service operator to check its configuration."),
            else => try failure(a, "host_unavailable", try std.fmt.allocPrint(a, "Could not return the command result: {s}. The host may have changed; inspect it before retrying.", .{@errorName(err)})),
        };
        return allocator.dupe(u8, response);
    }

    fn respond(self: *Host, a: Allocator, context: Context, request: Request) ![]const u8 {
        return switch (request) {
            .get_host_shell => success(a, self.shell.describe()),
            .run_host_shell => |args| success(a, try self.shell.run(a, context, args)),
            .get_recommended_tools => switch (try self.recommended_tools.read(a)) {
                .catalog => |catalog| success(a, catalog),
                .unavailable => failure(a, "recommendations_unavailable", "The recommended tools are unavailable. Ask the service operator to check the tool catalog configuration."),
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

const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Time = @import("time.zig");
const Allocator = std.mem.Allocator;

/// Agent-owned actions share one definition for recognition, arguments, and role
/// selection. Kernel owns their effects within the calling model/tool round.
pub const Request = union(enum) {
    send: struct { channel_id: []const u8, text: []const u8 },
    create_channel: struct { name: []const u8, description: []const u8 },
    close_channel: struct { channel_id: []const u8 },
    open_focus: struct { name: []const u8, task: []const u8 },
    schedule_attention: struct { name: []const u8, at: Time.Instant, text: []const u8 },
    subscribe: struct { name: []const u8, listener: []const u8 },
    withdraw_subscription: struct { subscription_id: []const u8 },

    /// Unknown names belong to other capabilities. A recognized action that is
    /// unavailable to this role must not fall through to another implementation.
    pub fn parse(a: Allocator, role: Input.Role, name: []const u8, arguments: []const u8) !?Request {
        const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
        if (!available(tag, role)) return error.UnknownTool;
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, arguments, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidToolArguments,
        };
        const request: Request = switch (tag) {
            inline else => |active| @unionInit(Request, @tagName(active), try parseArguments(@FieldType(Request, @tagName(active)), value)),
        };
        switch (request) {
            .send => |args| if (args.text.len == 0) return error.InvalidToolArguments,
            .create_channel, .close_channel, .subscribe => {},
            .open_focus => |args| if (!contracts.Reference.validName(args.name) or args.task.len == 0) return error.InvalidToolArguments,
            .schedule_attention => |args| if (!contracts.Reference.validName(args.name) or args.text.len == 0) return error.InvalidToolArguments,
            .withdraw_subscription => |args| if (args.subscription_id.len == 0) return error.InvalidToolArguments,
        }
        return request;
    }
};

fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidToolArguments;
}

// Tool references and text are JSON strings. Decoding directly into a Zig
// byte slice would also accept an array of integers as the same reference.
fn parseArguments(comptime T: type, value: std.json.Value) !T {
    const fields = @typeInfo(T).@"struct";
    if (value != .object or value.object.count() != fields.field_names.len) return error.InvalidToolArguments;
    var result: T = undefined;
    inline for (fields.field_names, fields.field_types) |name, Field| {
        const present = value.object.get(name) orelse return error.InvalidToolArguments;
        @field(result, name) = switch (Field) {
            []const u8 => try string(present),
            Time.Instant => Time.parse(try string(present)) catch return error.InvalidToolArguments,
            else => @compileError("unsupported tool argument type: " ++ @typeName(Field)),
        };
    }
    return result;
}

fn available(tag: std.meta.Tag(Request), role: Input.Role) bool {
    return switch (tag) {
        .send, .create_channel, .close_channel, .subscribe, .withdraw_subscription => true,
        .open_focus, .schedule_attention => role == .core,
    };
}

/// Returned declarations belong to a and use the same role selection as parse.
pub fn declarations(a: Allocator, role: Input.Role) ![]const contracts.Model.Tool {
    const all = try std.json.parseFromSliceLeaky([]const contracts.Model.Tool, a, @embedFile("tools.json"), .{});
    var selected: std.ArrayList(contracts.Model.Tool) = .empty;
    for (all) |tool| {
        const tag = std.meta.stringToEnum(std.meta.Tag(Request), tool.name) orelse return error.InvalidToolDeclaration;
        if (available(tag, role)) try selected.append(a, tool);
    }
    return selected.toOwnedSlice(a);
}

test "a subscription reference must be supplied as a JSON string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidToolArguments, Request.parse(arena.allocator(), .core, "withdraw_subscription",
        \\{"subscription_id":[102,101,101,100,45,49]}
    ));
}

test "a new feed requires a description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidToolArguments, Request.parse(arena.allocator(), .core, "create_channel",
        \\{"name":"release"}
    ));
}

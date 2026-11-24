const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Time = @import("time.zig");
const Allocator = std.mem.Allocator;

pub const Destination = union(enum) {
    correspondent_id: []const u8,
    focus_id: []const u8,
    channel_id: []const u8,

    fn parse(value: std.json.Value) !Destination {
        if (value != .object or value.object.count() != 1) return error.InvalidToolArguments;
        const tag = std.meta.stringToEnum(std.meta.Tag(Destination), value.object.keys()[0]) orelse return error.InvalidToolArguments;
        const id = try string(value.object.values()[0]);
        return switch (tag) {
            inline else => |active| @unionInit(Destination, @tagName(active), id),
        };
    }
};

/// Agent-owned actions share one definition for recognition, arguments, and role
/// selection. Kernel owns their effects within the calling model/tool round.
pub const Request = union(enum) {
    send: struct { to: Destination, text: []const u8 },
    open_channel: struct { name: []const u8, description: []const u8 },
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
            .open_channel => |args| if (!contracts.Reference.validName(args.name) or args.description.len == 0) return error.InvalidToolArguments,
            .close_channel => |args| if (args.channel_id.len == 0) return error.InvalidToolArguments,
            .subscribe => {},
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
            Destination => try Destination.parse(present),
            Time.Instant => Time.parse(try string(present)) catch return error.InvalidToolArguments,
            else => @compileError("unsupported tool argument type: " ++ @typeName(Field)),
        };
    }
    return result;
}

fn available(tag: std.meta.Tag(Request), role: Input.Role) bool {
    return switch (tag) {
        .send, .open_channel, .close_channel, .subscribe, .withdraw_subscription => true,
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

test "send rejects a call that selects two destinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidToolArguments, Request.parse(arena.allocator(), .core, "send",
        \\{"to":{"focus_id":"core-1","channel_id":"core-1"},"text":"Hello"}
    ));
}

test "opening a channel requires a nonempty description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidToolArguments, Request.parse(arena.allocator(), .core, "open_channel",
        \\{"name":"task-input","description":""}
    ));
}

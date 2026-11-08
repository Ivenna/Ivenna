const std = @import("std");
const contracts = @import("agent_contracts");
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

/// Agent-owned actions share one definition for recognition, arguments, and role
/// selection. Kernel owns their effects within the calling model/tool round.
pub const Request = union(enum) {
    send_message: contracts.Communication.Message,
    open_focus: struct { task: []const u8 },
    send_focus_message: struct { session_id: u64, text: []const u8 },
    schedule_attention: struct { at_unix_ms: i64, text: []const u8 },

    /// Unknown names belong to other capabilities. A recognized action that is
    /// unavailable to this role must not fall through to another implementation.
    pub fn parse(a: Allocator, role: Input.Role, name: []const u8, arguments: []const u8) !?Request {
        const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
        if (!available(tag, role)) return error.UnknownTool;
        const request: Request = switch (tag) {
            inline else => |active| @unionInit(Request, @tagName(active), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(active)), a, arguments, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidToolArguments,
            }),
        };
        switch (request) {
            .send_message => |args| if (args.recipients.len == 0 or args.text.len == 0) return error.InvalidToolArguments,
            .open_focus => |args| if (args.task.len == 0) return error.InvalidToolArguments,
            .send_focus_message => |args| if (args.session_id == 0 or args.text.len == 0) return error.InvalidToolArguments,
            .schedule_attention => |args| if (args.text.len == 0) return error.InvalidToolArguments,
        }
        return request;
    }
};

fn available(tag: std.meta.Tag(Request), role: Input.Role) bool {
    return switch (tag) {
        .send_message => true,
        .open_focus, .send_focus_message, .schedule_attention => role == .core,
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

const std = @import("std");
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// Retained history has native messages and tool results. Continuation bytes
/// are private to the model adapter that produced them, including reasoning;
/// execution retains and copies them without interpreting their wire format.
pub const Item = union(enum) {
    message: struct { role: enum { system, user }, text: []const u8 },
    continuation: []const u8,
    tool_result: struct { call_id: []const u8, content: Content },
};

pub const Call = struct {
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Complete output batch with decoded calls and assistant text.
pub const Response = struct {
    output: []const Item,
    calls: []const Call,
    text: ?[]const u8,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

/// History and selected tool declarations borrowed for one model operation.
pub const Request = struct {
    history: []const Item,
    tools: []const Tool,
};

/// The application keeps the implementation alive until every model request
/// has been joined. Each operation borrows its request data for the call.
pub const Port = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (*anyopaque, Allocator, Request) anyerror!Response,
        requestBytes: *const fn (*anyopaque, Allocator, Request) anyerror!u64,
        limitToolReplies: *const fn (*anyopaque, Allocator, Request, []Item) anyerror!void,
    };

    /// Returned output, calls, and text belong to a.
    pub fn next(self: Port, a: Allocator, request: Request) !Response {
        return self.vtable.next(self.context, a, request);
    }

    /// Measure the complete request using the same encoding as next.
    pub fn requestBytes(self: Port, a: Allocator, request: Request) !u64 {
        return self.vtable.requestBytes(self.context, a, request);
    }

    /// Apply model content limits to a complete tool batch. replies aliases
    /// the mutable tail of request.history; newly allocated content uses a.
    pub fn limitToolReplies(self: Port, a: Allocator, request: Request, replies: []Item) !void {
        return self.vtable.limitToolReplies(self.context, a, request, replies);
    }
};

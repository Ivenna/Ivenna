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
    /// Null when output contains no assistant text items; otherwise their
    /// combined text, which may be empty.
    text: ?[]const u8,
};

/// Outcome of one inference attempt. Only a complete response exposes calls.
/// The caller owns scheduling and the lifetime of the affected focus.
pub const Outcome = union(enum) {
    response: Response,
    unavailable: struct { retry_after_ms: ?i64 = null },
    rejected: Rejection,
};

pub const Rejection = enum { request_rejected, invalid_response, incomplete_response };

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const ReasoningEffort = enum { none, minimal, low, medium, high, xhigh, max };

/// History, tools, and reasoning effort selected for one model operation.
pub const Request = struct {
    history: []const Item,
    tools: []const Tool,
    reasoning_effort: ReasoningEffort,
};

/// The application keeps the implementation alive until every model request
/// has been joined. Each operation borrows its request data for the call.
pub const Port = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The adapter's serialization ceiling: the largest encoded request this
    /// adapter can send. This is a capability, not a policy budget; budgeting
    /// and content omission belong to the caller.
    request_ceiling_bytes: u64,

    pub const VTable = struct {
        next: *const fn (*anyopaque, Allocator, Request) anyerror!Outcome,
        requestBytes: *const fn (*anyopaque, Allocator, Request) anyerror!u64,
        limitToolReplies: *const fn (*anyopaque, Allocator, Request, []Item, u64) anyerror!void,
    };

    /// Returned output, calls, and text belong to a.
    pub fn next(self: Port, a: Allocator, request: Request) !Outcome {
        return self.vtable.next(self.context, a, request);
    }

    /// Measure the complete request using the same encoding as next.
    pub fn requestBytes(self: Port, a: Allocator, request: Request) !u64 {
        return self.vtable.requestBytes(self.context, a, request);
    }

    /// Prepare the newly appended tool_result items for the next inference.
    /// replies is their mutable slice at the end of request.history.
    /// ceiling_bytes is the adapter's serialization ceiling, never a policy
    /// budget: budgeting and content omission belong to the caller.
    pub fn limitToolReplies(self: Port, a: Allocator, request: Request, replies: []Item, ceiling_bytes: u64) !void {
        return self.vtable.limitToolReplies(self.context, a, request, replies, ceiling_bytes);
    }
};

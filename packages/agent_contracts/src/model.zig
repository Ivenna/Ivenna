const std = @import("std");
const tool_content = @import("content");
const Allocator = std.mem.Allocator;

/// Tool content ready for retention and inference. Uploaded files are addressed
/// by the service reference returned by the adapter.
pub const Content = struct {
    parts: []const Part,

    pub const Part = union(enum) {
        text: []const u8,
        image: tool_content.ImageContent,
        file_reference: []const u8,
    };
};

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
    /// Total input tokens reported for this request, including cached input.
    input_tokens: ?u64 = null,
};

/// Outcome of one inference attempt. Only a complete response exposes calls.
/// The caller owns scheduling and the lifetime of the affected focus.
pub const Outcome = union(enum) {
    response: Response,
    unavailable: struct { retry_after_ms: ?i64 = null },
    rejected: Rejection,
};

pub const Rejection = union(enum) {
    request_rejected,
    context_window,
    limit: Limit,
    invalid_response,
    incomplete_response,
};

pub const Limit = struct {
    kind: enum { request_bytes, images, files },
    actual: u64,
    maximum: u64,
};

/// Size of the encoded request and the first known adapter limit it violates.
/// The model service can apply additional limits after decoding the payload.
pub const Measurement = struct {
    bytes: u64,
    violation: ?Limit = null,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

/// History, tools, and reasoning effort selected for one model operation.
pub const Request = struct {
    history: []const Item,
    tools: []const Tool,
    reasoning_effort: []const u8,
};

/// The application keeps the implementation alive until every model request
/// has been joined. Each operation borrows its request data for the call.
pub const Port = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// Adapter-defined identity for reusing saved input token counts across runs.
    /// A null identity disables reuse on restart.
    usage_scope: ?[32]u8 = null,

    pub const VTable = struct {
        next: *const fn (*anyopaque, Allocator, Request) anyerror!Outcome,
        measure: *const fn (*anyopaque, Allocator, Request) anyerror!Measurement,
        prepareToolResult: *const fn (*anyopaque, Allocator, tool_content.Content) anyerror!Content,
    };

    /// Returned output, calls, and text belong to a.
    pub fn next(self: Port, a: Allocator, request: Request) !Outcome {
        return self.vtable.next(self.context, a, request);
    }

    /// Measure the complete request using the encoding and limits of next.
    pub fn measure(self: Port, a: Allocator, request: Request) !Measurement {
        return self.vtable.measure(self.context, a, request);
    }

    /// Prepare one tool result for retention and inference. Parts can borrow
    /// from the tool result until the caller copies them into its context.
    pub fn prepareToolResult(self: Port, a: Allocator, result: tool_content.Content) !Content {
        return self.vtable.prepareToolResult(self.context, a, result);
    }
};

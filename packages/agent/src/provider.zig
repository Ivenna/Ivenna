const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Every request uses the worker's Io, so canceling it also cancels its HTTP I/O.
pub const Provider = struct {
    pub const default_base_url = "https://api.deepseek.com";
    pub const default_model = "deepseek-flash";

    client: *std.http.Client,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    model: []const u8 = default_model,

    pub const FunctionCall = struct {
        call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };

    /// Output and call fields belong to the allocator supplied to next.
    pub const Response = struct {
        output: []const Value,
        calls: []const FunctionCall,
    };

    pub fn next(self: Provider, arena: Allocator, input: []const Value) !Response {
        try self.client.io.checkCancel();

        const tools = try std.json.parseFromSliceLeaky(Value, arena, @embedFile("tools.json"), .{});
        const payload = try std.json.Stringify.valueAlloc(arena, .{
            .model = self.model,
            .input = input,
            .tools = tools,
            .stream = false,
        }, .{});
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});
        var output = std.Io.Writer.Allocating.init(arena);
        defer output.deinit();
        var request = try self.client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        request.sendBodyComplete(payload) catch |err| return transportError(&request, err);
        var response = request.receiveHead(&.{}) catch |err| return transportError(&request, err);
        if (response.head.status != .ok) {
            std.log.err("model endpoint returned HTTP {d}", .{@backingInt(response.head.status)});
            _ = response.reader(&.{}).streamRemaining(&output.writer) catch |err| return transportError(&request, err);
            const failure = std.json.parseFromSliceLeaky(struct {
                @"error": struct { message: []const u8 },
            }, arena, output.written(), .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.ModelHttpFailure,
            };
            const detail = failure.@"error".message;
            const message = if (self.api_key.len == 0) detail else try std.mem.replaceOwned(u8, arena, detail, self.api_key, "[redacted]");
            std.log.err("model endpoint: {s}", .{message});
            return error.ModelHttpFailure;
        }
        if (response.head.content_encoding != .identity) return error.UnsupportedModelEncoding;
        const reader = response.reader(&.{});
        _ = reader.streamRemaining(&output.writer) catch |err| return transportError(&request, err);
        const decoded = std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            output: []const Value,
        }, arena, output.written(), .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidModelResponse,
        };
        if (!std.mem.eql(u8, decoded.status, "completed")) return error.ModelResponseNotCompleted;
        var calls: std.ArrayList(FunctionCall) = .empty;
        defer calls.deinit(arena);
        // Validate the complete batch before Engine can execute any tool.
        for (decoded.output) |item| {
            if (!std.mem.eql(u8, try textField(item, "type"), "function_call")) continue;
            try calls.append(arena, .{
                .call_id = try textField(item, "call_id"),
                .name = try textField(item, "name"),
                .arguments = try textField(item, "arguments"),
            });
        }
        return .{ .output = decoded.output, .calls = try calls.toOwnedSlice(arena) };
    }
};

fn transportError(request: *std.http.Client.Request, err: anyerror) anyerror {
    // std.http reader/writer adapters erase Canceled to ReadFailed/WriteFailed.
    // Cancellation is delivered once, so checkCancel cannot recover it later.
    if (request.connection) |connection| {
        if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return cause;
        if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return cause;
    }
    return err;
}

fn field(value: Value, name: []const u8) error{InvalidModelResponse}!Value {
    if (value != .object) return error.InvalidModelResponse;
    return value.object.get(name) orelse error.InvalidModelResponse;
}

fn textField(value: Value, name: []const u8) error{InvalidModelResponse}![]const u8 {
    const found = try field(value, name);
    if (found != .string) return error.InvalidModelResponse;
    return found.string;
}

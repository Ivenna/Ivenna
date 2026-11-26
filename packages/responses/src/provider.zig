const std = @import("std");
const zdt = @import("zdt");
const Model = @import("agent_contracts").Model;
const JsonString = @import("agent_contracts").JsonString;
const Content = @import("content").Content;
const File = @import("content").File;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Responses wire encoding and HTTP transport. Tool selection and execution
/// belong to the agent; HTTP exchanges use the client's cancelable Io.
pub const Provider = struct {
    pub const default_base_url = "https://api.deepseek.com";
    pub const default_model = "deepseek-flash";
    pub const default_max_output_tokens: u32 = 65536;
    pub const default_request_timeout_ms: u32 = 600000;
    /// The default ceiling uses DeepSeek's published request body limit for vision.
    pub const default_ceiling_bytes: u64 = 48 * 1024 * 1024;
    const max_images: u64 = 600;
    const max_files: u64 = 20;

    client: *std.http.Client,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    model: []const u8 = default_model,
    max_output_tokens: u32 = default_max_output_tokens,
    /// Deadline in milliseconds for one inference attempt or one file upload.
    request_timeout_ms: u32 = default_request_timeout_ms,
    request_ceiling_bytes: u64 = default_ceiling_bytes,

    pub fn port(self: *Provider) Model.Port {
        var scope = std.crypto.hash.sha2.Sha256.init(.{});
        scope.update("responses");
        for ([_][]const u8{ std.mem.trimEnd(u8, self.base_url, "/"), self.model }) |part| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, part.len, .little);
            scope.update(&length);
            scope.update(part);
        }
        return .{
            .context = self,
            .vtable = &.{
                .next = next,
                .measure = measure,
                .prepareToolReplies = prepareToolReplies,
            },
            .usage_scope = scope.finalResult(),
        };
    }

    fn next(context: *anyopaque, arena: Allocator, request: Model.Request) anyerror!Model.Outcome {
        const self: *Provider = @ptrCast(@alignCast(context));
        return self.send(arena, request);
    }

    fn measure(context: *anyopaque, a: Allocator, request: Model.Request) anyerror!Model.Measurement {
        const self: *Provider = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const encoded = try self.encodeRequest(scratch.allocator(), request);
        var buffer: [4096]u8 = undefined;
        var counter = std.Io.Writer.Discarding.init(&buffer);
        try std.json.Stringify.value(encoded.payload, .{}, &counter.writer);
        const bytes = counter.fullCount();
        return .{ .bytes = bytes, .violation = self.requestLimit(bytes, encoded) };
    }

    fn requestLimit(self: Provider, bytes: u64, request: EncodedRequest) ?Model.Limit {
        if (bytes > self.request_ceiling_bytes)
            return .{ .kind = .request_bytes, .actual = bytes, .maximum = self.request_ceiling_bytes };
        if (request.images > max_images) return .{ .kind = .images, .actual = request.images, .maximum = max_images };
        if (request.files > max_files) return .{ .kind = .files, .actual = request.files, .maximum = max_files };
        return null;
    }

    fn prepareToolReplies(context: *anyopaque, arena: Allocator, replies: []Model.Item) anyerror!void {
        const self: *Provider = @ptrCast(@alignCast(context));
        for (replies) |*reply| {
            const parts = try arena.dupe(Content.Part, reply.tool_result.content.parts);
            reply.tool_result.content.parts = parts;
            for (parts) |*part| switch (part.*) {
                .text, .image => {},
                .file => |*file| {
                    if (file.reference != null) continue;
                    switch (try self.uploadFile(arena, file.*)) {
                        .reference => |reference| file.reference = reference,
                        .failure => |failure| part.* = try failure.part(arena, file.*),
                    }
                },
            };
        }
    }

    const WireTool = struct {
        type: []const u8 = "function",
        name: []const u8,
        description: []const u8,
        parameters: Value,
    };

    const Payload = struct {
        model: []const u8,
        input: []const Value,
        tools: []const WireTool,
        tool_choice: []const u8,
        max_output_tokens: u32,
        reasoning: struct { effort: []const u8 },
        stream: bool = false,
    };

    const EncodedRequest = struct {
        payload: Payload,
        images: u64,
        files: u64,
    };

    fn encodeRequest(self: Provider, arena: Allocator, request: Model.Request) !EncodedRequest {
        var image_count: u64 = 0;
        var file_count: u64 = 0;
        var input: std.ArrayList(Value) = .empty;
        defer input.deinit(arena);
        var attachments: std.ArrayList(Value) = .empty;
        defer attachments.deinit(arena);
        for (request.history) |item| {
            if (item != .tool_result) {
                try input.appendSlice(arena, attachments.items);
                attachments.clearRetainingCapacity();
            }
            try input.append(arena, try encodeItem(arena, item, &image_count));
            if (item != .tool_result) continue;
            var files: std.ArrayList(Value) = .empty;
            defer files.deinit(arena);
            for (item.tool_result.content.parts) |part| {
                if (part != .file) continue;
                if (files.items.len == 0) {
                    try files.append(arena, try encodeContentPart(arena, .{
                        .text = try std.json.Stringify.valueAlloc(arena, .{ .source = .{ .tool_call_id = item.tool_result.call_id } }, .{}),
                    }));
                }
                var fields: std.json.ObjectMap = .empty;
                try fields.put(arena, "type", .{ .string = "input_file" });
                try fields.put(arena, "file_id", .{ .string = part.file.reference orelse return error.UnpreparedModelFile });
                try files.append(arena, .{ .object = fields });
                file_count += 1;
            }
            if (files.items.len != 0) {
                var fields: std.json.ObjectMap = .empty;
                try fields.put(arena, "role", .{ .string = "user" });
                try fields.put(arena, "content", .{ .array = std.array_list.Managed(Value).fromOwnedSlice(arena, try files.toOwnedSlice(arena)) });
                try attachments.append(arena, .{ .object = fields });
            }
        }
        try input.appendSlice(arena, attachments.items);
        const tools = try arena.alloc(WireTool, request.tools.len);
        for (request.tools, tools) |tool, *encoded| encoded.* = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = tool.parameters,
        };
        return .{
            .payload = .{
                .model = self.model,
                .input = try input.toOwnedSlice(arena),
                .tools = tools,
                .tool_choice = if (tools.len == 0) "none" else "auto",
                .max_output_tokens = self.max_output_tokens,
                .reasoning = .{ .effort = request.reasoning_effort },
            },
            .images = image_count,
            .files = file_count,
        };
    }

    const Upload = union(enum) { reference: []const u8, failure: UploadFailure };

    const UploadFailure = union(enum) {
        rejected: std.http.Status,
        not_sent,
        uncertain,

        fn part(self: UploadFailure, arena: Allocator, file: File) !Content.Part {
            return .{ .text = try std.json.Stringify.valueAlloc(arena, .{
                .file = .{ .byte_length = file.bytes.len },
                .@"error" = .{
                    .code = if (self == .uncertain) "file_upload_uncertain" else "file_upload_failed",
                    .message = switch (self) {
                        .not_sent => "The upload attempt ended before sending the file.",
                        .rejected => |status| switch (status) {
                            .payload_too_large => "The file exceeds the upload service's size limit.",
                            .too_many_requests => "The file service is limiting uploads. Try again later.",
                            else => "The file service rejected the upload.",
                        },
                        .uncertain => "No file reference was confirmed. The service may have stored the file.",
                    },
                },
            }, .{}) };
        }
    };

    fn uploadFile(self: Provider, arena: Allocator, file: File) !Upload {
        const io = self.client.io;
        try io.checkCancel();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromMilliseconds(self.request_timeout_ms),
            .clock = .awake,
        });
        // A lost response may follow successful, billable parsing and storage.
        var failure: UploadFailure = .not_sent;
        const upload = runUntil(Upload, io, deadline, uploadFileNegotiated, .{ self, arena, file, &failure }) catch |err| {
            if (!retryableTransport(err) and !invalidEnvelope(err)) return err;
            return .{ .failure = failure };
        };
        return upload orelse .{ .failure = failure };
    }

    fn uploadFileNegotiated(self: Provider, arena: Allocator, file: File, failure: *UploadFailure) !Upload {
        const result = try self.uploadFileOnce(arena, file, "rich_layout_recognition", failure);
        // The service rejects some formats for one purpose and accepts them
        // for the other. A definite 400 is a failed upload, which the service
        // does not store or bill; it need not identify the rejection's cause.
        if (result == .failure and result.failure == .rejected and result.failure.rejected == .bad_request)
            return self.uploadFileOnce(arena, file, "user_data", failure);
        return result;
    }

    fn uploadFileOnce(self: Provider, arena: Allocator, file: File, purpose: []const u8, failure: *UploadFailure) !Upload {
        failure.* = .not_sent;
        var scratch = std.heap.ArenaAllocator.init(self.client.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var random: [16]u8 = undefined;
        self.client.io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const boundary = try std.fmt.allocPrint(temporary, "ivenna-{s}", .{hex});
        const prefix = try std.fmt.allocPrint(temporary, "--{s}\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\n{s}\r\n" ++
            "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"document.bin\"\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n", .{ boundary, purpose, boundary });
        const suffix = try std.fmt.allocPrint(temporary, "\r\n--{s}--\r\n", .{boundary});
        var payload = [_][]const u8{ prefix, file.bytes, suffix };
        const base_url = std.mem.trimEnd(u8, self.base_url, "/");
        const url = try std.fmt.allocPrint(temporary, "{s}/files", .{base_url});
        const authorization = try std.fmt.allocPrint(temporary, "Bearer {s}", .{self.api_key});
        const content_type = try std.fmt.allocPrint(temporary, "multipart/form-data; boundary={s}", .{boundary});
        var request = self.client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{
                .content_type = .{ .override = content_type },
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.UnknownHostName, error.NoAddressReturned, error.TlsInitializationFailed => return .{ .failure = .not_sent },
            else => return err,
        };
        defer request.deinit();
        errdefer if (request.connection) |connection| {
            connection.closing = true;
        };
        failure.* = .uncertain;
        sendPayload(&request, &payload) catch |err| return transportError(&request, err);
        var response = request.receiveHead(&.{}) catch |err| return transportError(&request, err);
        if (!completeRepresentation(response.head)) {
            request.connection.?.closing = true;
            const status = response.head.status;
            std.log.info("model file endpoint returned HTTP {d} (request_id={s})", .{
                @backingInt(status),
                responseRequestId(response.head) orelse "unavailable",
            });
            if (status.class() == .client_error or status == .not_implemented or status == .http_version_not_supported)
                failure.* = .{ .rejected = status };
            return .{ .failure = failure.* };
        }
        var buffer: [4096]u8 = undefined;
        var json = std.json.Reader.init(temporary, response.reader(&buffer));
        defer json.deinit();
        const uploaded = std.json.parseFromTokenSourceLeaky(struct { id: JsonString }, temporary, &json, .{ .ignore_unknown_fields = true }) catch |err| {
            request.connection.?.closing = true;
            return switch (err) {
                error.OutOfMemory => err,
                error.ReadFailed => transportError(&request, err),
                else => .{ .failure = .uncertain },
            };
        };
        // A complete JSON object may still precede a premature connection close.
        if (request.reader.state == .body_remaining_content_length or uploaded.id.bytes.len == 0) {
            request.connection.?.closing = true;
            return .{ .failure = .uncertain };
        }
        return .{ .reference = try arena.dupe(u8, uploaded.id.bytes) };
    }

    fn send(self: Provider, arena: Allocator, request: Model.Request) !Model.Outcome {
        const io = self.client.io;
        try io.checkCancel();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromMilliseconds(self.request_timeout_ms),
            .clock = .awake,
        });
        var scratch = std.heap.ArenaAllocator.init(self.client.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const encoded = try self.encodeRequest(temporary, request);
        const payload = try std.json.Stringify.valueAlloc(temporary, encoded.payload, .{});
        if (self.requestLimit(payload.len, encoded)) |limit| return .{ .rejected = .{ .limit = limit } };
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});

        // A 429 can supply a retry delay before its optional diagnostic stalls.
        var on_timeout: Model.Outcome = .{ .unavailable = .{} };
        const attempt = runUntil(Model.Outcome, io, deadline, sendAttempt, .{ self, arena, payload, url, authorization, &on_timeout }) catch |err| {
            if (invalidEnvelope(err)) return .{ .rejected = .invalid_response };
            if (!retryableTransport(err)) return err;
            std.log.warn("model connection failed ({s})", .{@errorName(err)});
            return .{ .unavailable = .{} };
        };
        if (attempt) |outcome| return outcome;
        std.log.warn("model request timed out after {d} ms", .{self.request_timeout_ms});
        return on_timeout;
    }

    fn sendAttempt(self: Provider, arena: Allocator, payload: []const u8, url: []const u8, authorization: []const u8, on_timeout: *Model.Outcome) !Model.Outcome {
        // Response bytes are temporary; decoded output belongs to the caller.
        var scratch = std.heap.ArenaAllocator.init(self.client.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var request = try self.client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        // Closing skips Request.deinit's unread-body drain, which could block
        // again after cancellation has already been delivered.
        errdefer if (request.connection) |connection| {
            connection.closing = true;
        };
        var parts = [_][]const u8{payload};
        sendPayload(&request, &parts) catch |err| return transportError(&request, err);
        var response = request.receiveHead(&.{}) catch |err| return transportError(&request, err);
        if (!completeRepresentation(response.head)) {
            request.connection.?.closing = true;
            const status = response.head.status;
            // Reading the body invalidates the borrowed header values.
            const request_id = if (responseRequestId(response.head)) |id| try temporary.dupe(u8, id) else null;
            var code: ?[]const u8 = null;
            defer std.log.warn("model inference endpoint returned HTTP {d} (request_id={s}, code={s})", .{
                @backingInt(status),
                request_id orelse "unavailable",
                code orelse "unavailable",
            });
            switch (status) {
                .payment_required => return error.ModelQuotaExhausted,
                .unauthorized, .proxy_auth_required, .method_not_allowed, .not_implemented, .http_version_not_supported => return error.ModelHttpFailure,
                .bad_request => {
                    on_timeout.* = .{ .rejected = .request_rejected };
                    const diagnostic = try serviceDiagnostic(temporary, &response) orelse return on_timeout.*;
                    code = diagnostic.logCode();
                    return .{ .rejected = if (diagnostic.matches("context_length_exceeded")) .context_window else .request_rejected };
                },
                .request_timeout, .too_many_requests => {},
                else => switch (status.class()) {
                    .success, .informational => return .{ .rejected = .invalid_response },
                    .client_error => return .{ .rejected = .request_rejected },
                    .redirect => return error.ModelHttpFailure,
                    .server_error => {},
                },
            }
            const disposition = retryDisposition(response.head, self.client.io);
            if (status == .too_many_requests) {
                on_timeout.* = disposition;
                if (try serviceDiagnostic(temporary, &response)) |diagnostic| {
                    code = diagnostic.logCode();
                    if (diagnostic.matches("insufficient_quota")) return error.ModelQuotaExhausted;
                }
            }
            return disposition;
        }
        const content_length = if (response.head.transfer_encoding == .none) response.head.content_length else null;
        const reader = response.reader(&.{});
        var output = std.Io.Writer.Allocating.init(temporary);
        defer output.deinit();
        if (content_length) |length| {
            reader.streamExact64(&output.writer, length) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return transportError(&request, err);
            };
        } else {
            _ = reader.streamRemaining(&output.writer) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return transportError(&request, err);
            };
        }
        return .{ .response = decodeResponse(arena, output.written()) catch |err| switch (err) {
            error.InvalidModelResponse => return .{ .rejected = .invalid_response },
            error.ModelResponseNotCompleted => return .{ .rejected = .incomplete_response },
            else => return err,
        } };
    }

    /// Decode every output item before returning calls for execution. Check
    /// fields needed for text and call extraction; retain each complete item
    /// as adapter-private continuation, including uninterpreted fields.
    fn decodeResponse(arena: Allocator, bytes: []const u8) !Model.Response {
        const decoded = std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            output: []const Value,
            usage: Value = .null,
        }, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidModelResponse,
        };
        if (!std.mem.eql(u8, decoded.status, "completed")) return error.ModelResponseNotCompleted;
        var calls: std.ArrayList(Model.Call) = .empty;
        defer calls.deinit(arena);
        var text = std.Io.Writer.Allocating.init(arena);
        defer text.deinit();
        var has_text = false;
        for (decoded.output) |item| {
            const kind = try textField(item, "type");
            if (std.mem.eql(u8, kind, "reasoning")) continue;
            if (std.mem.eql(u8, kind, "message")) {
                const parts = try field(item, "content");
                if (parts != .array) return error.InvalidModelResponse;
                for (parts.array.items) |part| {
                    if (!std.mem.eql(u8, try textField(part, "type"), "output_text")) return error.InvalidModelResponse;
                    const value = try textField(part, "text");
                    has_text = true;
                    if (value.len == 0) continue;
                    if (text.written().len != 0) try text.writer.writeAll("\n\n");
                    try text.writer.writeAll(value);
                }
                continue;
            }
            if (!std.mem.eql(u8, kind, "function_call")) return error.InvalidModelResponse;
            const call_id = try textField(item, "call_id");
            if (call_id.len == 0) return error.InvalidModelResponse;
            for (calls.items) |previous| {
                if (std.mem.eql(u8, previous.call_id, call_id)) return error.InvalidModelResponse;
            }
            try calls.append(arena, .{
                .call_id = call_id,
                .name = try textField(item, "name"),
                .arguments = try textField(item, "arguments"),
            });
        }
        const output = try arena.alloc(Model.Item, decoded.output.len);
        for (decoded.output, output) |item, *retained|
            retained.* = .{ .continuation = try std.json.Stringify.valueAlloc(arena, item, .{}) };
        return .{
            .output = output,
            .calls = try calls.toOwnedSlice(arena),
            .text = if (has_text) try text.toOwnedSlice() else null,
            .input_tokens = inputTokens(decoded.usage),
        };
    }
};

fn encodeItem(arena: Allocator, item: Model.Item, image_count: *u64) !Value {
    switch (item) {
        .continuation => |bytes| return std.json.parseFromSliceLeaky(Value, arena, bytes, .{}),
        .message => |message| {
            var fields: std.json.ObjectMap = .empty;
            try fields.put(arena, "role", .{ .string = @tagName(message.role) });
            try fields.put(arena, "content", .{ .string = message.text });
            return .{ .object = fields };
        },
        .tool_result => |result| {
            const parts = try arena.alloc(Value, result.content.parts.len);
            for (result.content.parts, parts) |part, *encoded| {
                const request_part = try projectToolPart(arena, part);
                if (request_part == .image) image_count.* += 1;
                encoded.* = try encodeContentPart(arena, request_part);
            }
            var fields: std.json.ObjectMap = .empty;
            try fields.put(arena, "type", .{ .string = "function_call_output" });
            try fields.put(arena, "call_id", .{ .string = result.call_id });
            try fields.put(arena, "output", .{ .array = std.array_list.Managed(Value).fromOwnedSlice(arena, parts) });
            return .{ .object = fields };
        },
    }
}

fn encodeContentPart(arena: Allocator, part: Content.Part) !Value {
    var encoded: std.json.ObjectMap = .empty;
    switch (part) {
        .text => |text| {
            try encoded.put(arena, "type", .{ .string = "input_text" });
            try encoded.put(arena, "text", .{ .string = text });
        },
        .image => |source| {
            const url = switch (source) {
                .url => |url| url,
                .data => |image| blk: {
                    const encoder = std.base64.standard.Encoder;
                    const mime = image.mimeType();
                    const prefix_length = "data:".len + mime.len + ";base64,".len;
                    const url = try arena.alloc(u8, prefix_length + encoder.calcSize(image.bytes.len));
                    _ = try std.fmt.bufPrint(url[0..prefix_length], "data:{s};base64,", .{mime});
                    _ = encoder.encode(url[prefix_length..], image.bytes);
                    break :blk url;
                },
            };
            try encoded.put(arena, "type", .{ .string = "input_image" });
            try encoded.put(arena, "image_url", .{ .string = url });
        },
        .file => {
            try encoded.put(arena, "type", .{ .string = "input_text" });
            try encoded.put(arena, "text", .{ .string = "File attached." });
        },
    }
    return .{ .object = encoded };
}

fn projectToolPart(arena: Allocator, part: Content.Part) !Content.Part {
    const maximum = 8192;
    if (part != .image or part.image != .url) return part;
    const url = part.image.url;
    if (!std.ascii.startsWithIgnoreCase(url, "http://") and !std.ascii.startsWithIgnoreCase(url, "https://"))
        return part;
    const actual = try std.unicode.utf8CountCodepoints(url);
    if (actual <= maximum) return part;
    return .{ .text = try std.json.Stringify.valueAlloc(arena, .{
        .@"error" = .{
            .code = "content_limit",
            .message = "The image was omitted from this request because its HTTP(S) URL exceeds the model service's length limit.",
            .omitted_images = 1,
            .unit = "unicode_code_points",
            .actual = actual,
            .maximum = maximum,
        },
    }, .{}) };
}

fn transportError(request: *std.http.Client.Request, err: anyerror) anyerror {
    // std.http reader/writer adapters erase Canceled to ReadFailed/WriteFailed.
    // Cancellation is delivered once, so checkCancel cannot recover it later.
    if (request.connection) |connection| {
        if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return cause;
        if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return cause;
        if (err == error.ReadFailed) {
            if (request.reader.body_err) |cause| return cause;
            return connection.getReadError() orelse err;
        }
        if (err == error.WriteFailed) {
            if (connection.stream_writer.err) |cause| return cause;
        }
    }
    return err;
}

fn sendPayload(request: *std.http.Client.Request, parts: [][]const u8) std.Io.Writer.Error!void {
    // sendBodyComplete uses its input as a mutable buffer and can shift it
    // after partial writes. writeVecAll only updates and restores slice
    // headers, preserving the serialized request and borrowed file bytes.
    var length: usize = 0;
    for (parts) |part| length += part.len;
    request.transfer_encoding = .{ .content_length = length };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeVecAll(parts);
    try body.endUnflushed();
    // HTTPS also buffers encrypted records in the underlying socket writer.
    try request.connection.?.flush();
}

/// Null means the deadline elapsed. Join the exchange before its caller
/// inspects any partial result or releases the borrowed buffers.
fn runUntil(comptime T: type, io: std.Io, deadline: std.Io.Clock.Timestamp, comptime operation: anytype, args: std.meta.ArgsTuple(@TypeOf(operation))) !?T {
    const Result = union(enum) { exchange: anyerror!T, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.Clock.Timestamp.wait, .{ deadline, io });
    try select.concurrent(.exchange, operation, args);
    switch (try select.await()) {
        .exchange => |result| return try result,
        .timeout => |result| {
            try result;
            return null;
        },
    }
}

fn completeRepresentation(head: std.http.Client.Response.Head) bool {
    return head.status.class() == .success and head.status != .no_content and head.status != .reset_content and
        head.status != .partial_content and head.content_encoding == .identity;
}

const ServiceDiagnostic = struct {
    code: ?[]const u8 = null,
    type: ?[]const u8 = null,

    fn matches(self: ServiceDiagnostic, code: []const u8) bool {
        return std.mem.eql(u8, self.code orelse "", code) or std.mem.eql(u8, self.type orelse "", code);
    }

    fn logCode(self: ServiceDiagnostic) ?[]const u8 {
        return diagnosticToken(self.code) orelse diagnosticToken(self.type);
    }
};

fn responseRequestId(head: std.http.Client.Response.Head) ?[]const u8 {
    var deepseek_id: ?[]const u8 = null;
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-request-id")) {
            if (diagnosticToken(header.value)) |id| return id;
        } else if (deepseek_id == null and std.ascii.eqlIgnoreCase(header.name, "x-deepseek-request-id")) {
            deepseek_id = diagnosticToken(header.value);
        }
    }
    return deepseek_id;
}

fn diagnosticToken(value: ?[]const u8) ?[]const u8 {
    const token = value orelse return null;
    if (token.len == 0 or token.len > 96) return null;
    for (token) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return null;
    }
    return token;
}

/// An incomplete or oversized optional diagnostic leaves the status and retry headers in force.
fn serviceDiagnostic(arena: Allocator, response: *std.http.Client.Response) !?ServiceDiagnostic {
    const limit = 16 * 1024;
    if (response.head.content_encoding != .identity) return null;
    const length = if (response.head.transfer_encoding == .none) response.head.content_length else null;
    if (length) |len| if (len > limit) return null;
    const bytes = response.reader(&.{}).allocRemaining(arena, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => return null,
        error.ReadFailed => {
            const cause = transportError(response.request, err);
            if (cause == error.Canceled) return cause;
            return null;
        },
    };
    if (length) |len| if (bytes.len != len) return null;
    const Diagnostic = struct { @"error": ServiceDiagnostic };
    const diagnostic = std.json.parseFromSliceLeaky(Diagnostic, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    return diagnostic.@"error";
}

fn invalidEnvelope(err: anyerror) bool {
    return switch (err) {
        error.HttpHeadersInvalid, error.HttpHeadersOversize, error.HttpChunkInvalid, error.HttpContentEncodingUnsupported => true,
        else => false,
    };
}

fn retryableTransport(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.BrokenPipe,
        error.SocketUnconnected,
        error.NetworkDown,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.Timeout,
        error.ConnectionTimedOut,
        error.NameServerFailure,
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.EndOfStream,
        error.HttpChunkTruncated,
        error.TlsConnectionTruncated,
        => true,
        else => false,
    };
}

fn retryDisposition(head: std.http.Client.Response.Head, io: std.Io) Model.Outcome {
    var after_ms: ?i64 = null;
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-should-retry") and std.ascii.eqlIgnoreCase(header.value, "false"))
            return .{ .rejected = .request_rejected };
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after"))
            after_ms = retryAfterMilliseconds(header.value, std.Io.Clock.real.now(io).toMilliseconds());
    }
    return .{ .unavailable = .{ .retry_after_ms = after_ms } };
}

fn retryAfterMilliseconds(raw: []const u8, now_ms: i64) ?i64 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;
    if (for (value) |byte| {
        if (!std.ascii.isDigit(byte)) break false;
    } else true) {
        const seconds = std.fmt.parseInt(i64, value, 10) catch return null;
        return std.math.mul(i64, seconds, 1000) catch null;
    }

    // IMF-fixdate uses English names and UTC.
    if (value.len != 29 or !std.mem.eql(u8, value[3..5], ", ") or value[7] != ' ' or
        value[11] != ' ' or value[16] != ' ' or value[19] != ':' or value[22] != ':' or
        !std.mem.eql(u8, value[25..], " GMT")) return null;
    _ = zdt.Datetime.Weekday.nameShortToInt(value[0..3]) catch return null;
    const date = zdt.Datetime.fromFields(.{
        .year = std.fmt.parseUnsigned(i16, value[12..16], 10) catch return null,
        .month = zdt.Datetime.Month.nameShortToInt(value[8..11]) catch return null,
        .day = std.fmt.parseUnsigned(u8, value[5..7], 10) catch return null,
        .hour = std.fmt.parseUnsigned(u8, value[17..19], 10) catch return null,
        .minute = std.fmt.parseUnsigned(u8, value[20..22], 10) catch return null,
        .second = std.fmt.parseUnsigned(u8, value[23..25], 10) catch return null,
        .tz_options = .{ .tz = &zdt.Timezone.UTC },
    }) catch return null;
    const timestamp_ms: i64 = @intCast(date.toUnix(.millisecond));
    return @max(0, timestamp_ms -| now_ms);
}

test "Retry-After preserves server timing and ignores invalid dates" {
    const testing = std.testing;
    try testing.expectEqual(@as(?i64, 2000), retryAfterMilliseconds(" 2 ", 0));
    try testing.expectEqual(@as(?i64, 0), retryAfterMilliseconds("0", 0));
    try testing.expectEqual(@as(?i64, 1500), retryAfterMilliseconds("Thu, 01 Jan 1970 00:00:02 GMT", 500));
    try testing.expectEqual(@as(?i64, 0), retryAfterMilliseconds("Thu, 01 Jan 1970 00:00:02 GMT", 3000));
    try testing.expectEqual(@as(?i64, 500), retryAfterMilliseconds("Wed, 21 Oct 2015 07:28:00 GMT", 1445412479500));
    try testing.expectEqual(null, retryAfterMilliseconds("999999999999999999999999", 0));
    try testing.expectEqual(null, retryAfterMilliseconds("9223372036854776", 0));
    try testing.expectEqual(null, retryAfterMilliseconds("-1", 0));
    try testing.expectEqual(null, retryAfterMilliseconds("tomorrow", 0));
    try testing.expectEqual(null, retryAfterMilliseconds("Fri, 30 Feb 2024 00:00:00 GMT", 0));
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

fn inputTokens(usage: Value) ?u64 {
    const count = field(usage, "input_tokens") catch return null;
    return if (count == .integer) std.math.cast(u64, count.integer) else null;
}

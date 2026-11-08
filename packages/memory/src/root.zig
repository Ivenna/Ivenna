const std = @import("std");
const content = @import("content");

const Allocator = std.mem.Allocator;
const Tools = @import("agent_contracts").Tools;
const Model = @import("agent_contracts").Model;
const Value = std.json.Value;
const Content = content.Content;
const Interpretation = content.Interpretation;

const entry_size_limit = 32 * 1024 * 1024;
const text_page_limit = 8192;
const reply_size_limit = 32 * 1024;

pub const Memory = struct {
    io: std.Io,
    ssh_target: []const u8,
    ssh_config: ?[]const u8 = null,

    /// Declarations belong to a and must outlive their registration with Engine.
    pub fn tools(self: *Memory, a: Allocator) !Tools {
        return .{
            .context = self,
            .invoke = invokeTool,
            .declarations = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{}),
        };
    }

    fn invokeTool(context: *anyopaque, a: Allocator, _: Tools.Invocation, name: []const u8, arguments: []const u8) anyerror!?Content {
        const self: *Memory = @ptrCast(@alignCast(context));
        const request = try Request.parse(a, name, arguments) orelse return null;
        return try self.invoke(a, request);
    }

    const MatchMode = enum { literal, regex };

    pub const Request = union(enum) {
        inspect_memory_space: struct {},
        visit_memory_room: struct {
            address: []const u8 = ".",
            recursive_size: bool = false,
            offset: u32 = 0,
            max_results: u16 = 100,
        },
        find_memory: struct {
            query: []const u8,
            room: ?[]const u8 = null,
            match_mode: ?enum { literal, glob, regex } = null,
            case_sensitive: ?bool = null,
            offset: u32 = 0,
            max_results: u16 = 100,
        },
        recall_memory: struct {
            clue: []const u8,
            room: ?[]const u8 = null,
            match_mode: ?MatchMode = null,
            case_sensitive: ?bool = null,
            offset: u32 = 0,
            max_results: u16 = 100,
        },
        read_memory: struct {
            address: []const u8,
            interpretation: ?Interpretation = null,
            offset: u64 = 0,
            max_bytes: u32 = text_page_limit,
        },
        remember: struct {
            address: []const u8,
            content: union(enum) {
                text: []const u8,
                file: struct { path: []const u8 },
            },
            mode: ?enum { create, append, replace } = null,
        },
        revise_memory: struct {
            address: []const u8,
            old_text: []const u8,
            new_text: []const u8,
            replace_all: ?bool = null,
            match_mode: ?MatchMode = null,
        },
        create_memory_room: struct { address: []const u8 },
        move_memory: struct {
            address: []const u8,
            destination: []const u8,
        },
        forget_memory: struct {
            address: []const u8,
            recursive: ?bool = null,
        },

        pub fn parse(allocator: Allocator, name: []const u8, arguments: []const u8) !?Request {
            const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
            const request: Request = switch (tag) {
                inline else => |active| @unionInit(Request, @tagName(active), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(active)), allocator, arguments, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidToolArguments,
                }),
            };
            if (request == .remember and request.remember.content == .file) {
                const path = request.remember.content.file.path;
                if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
                    return error.InvalidToolArguments;
            }
            switch (request) {
                .visit_memory_room => |args| if (args.max_results == 0 or args.max_results > 1000) {
                    return error.InvalidToolArguments;
                },
                .find_memory => |args| if (args.max_results == 0 or args.max_results > 1000) {
                    return error.InvalidToolArguments;
                },
                .recall_memory => |args| if (args.max_results == 0 or args.max_results > 1000) {
                    return error.InvalidToolArguments;
                },
                .read_memory => |args| if (args.max_bytes < 4 or args.max_bytes > text_page_limit or args.offset > std.math.maxInt(i64) or (args.interpretation != null and args.offset != 0)) {
                    return error.InvalidToolArguments;
                },
                else => {},
            }
            return request;
        }
    };

    pub const Reply = union(enum) {
        result: Value,
        @"error": struct { code: []const u8, message: []const u8 },
    };

    /// Returned content and image bytes belong to allocator, independently of
    /// the temporary SSH request and response buffers.
    pub fn invoke(self: Memory, allocator: Allocator, request: Request) !Content {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var remote_request = request;
        if (remote_request == .read_memory and remote_request.read_memory.interpretation != null)
            remote_request.read_memory.max_bytes = content.reference_size_limit;
        var reply = try self.exchange(scratch, remote_request);
        if (request == .read_memory and reply == .result) {
            var read = try Read.parse(scratch, reply.result, remote_request.read_memory);
            if (content.detectFormat(read.header) != null and read.byte_length <= entry_size_limit and read.offset == 0 and read.bytes.len < read.byte_length) {
                // Only images need a whole-entry transfer. The second request
                // owns its own snapshot; classify and bound that result again
                // in case another session replaced the source in between.
                remote_request.read_memory.max_bytes = entry_size_limit;
                reply = try self.exchange(scratch, remote_request);
                if (reply == .result) read = try Read.parse(scratch, reply.result, remote_request.read_memory);
            }
            if (reply == .result) return read.render(allocator, request.read_memory);
        }
        return Content.fromText(allocator, try std.json.Stringify.valueAlloc(allocator, reply, .{}));
    }

    /// Startup uses the same read-only operation as the model-facing space
    /// inspection. Memory must be available before the kernel starts.
    pub fn checkAvailable(self: Memory, allocator: Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const reply = try self.exchange(scratch, .{ .inspect_memory_space = .{} });
        switch (reply) {
            .@"error" => |failure| {
                std.log.err("memory startup check: {s}: {s}", .{ failure.code, failure.message });
                return error.MemoryUnavailable;
            },
            .result => |result| {
                const Space = struct { used_bytes: u64, capacity_bytes: u64, remaining_bytes: u64, used_ratio: f64 };
                _ = try std.json.parseFromValueLeaky(Space, scratch, result, .{});
            },
        }
    }

    fn exchange(self: Memory, scratch: Allocator, request: Request) !Reply {
        // File sources belong to Ivenna's host; the remote handler receives
        // bytes rather than a host path. Missing modes retain remote defaults.
        const payload = switch (request) {
            .remember => |args| blk: {
                const bytes = switch (args.content) {
                    .text => |text| text,
                    .file => |source| readSourceFile(self.io, scratch, source.path) catch |err| switch (err) {
                        error.Canceled, error.OutOfMemory => return err,
                        error.StreamTooLong => return .{ .@"error" = .{ .code = "entry_too_large", .message = "A memory write can transfer at most 33554432 bytes (32 MiB). No write was sent." } },
                        else => return .{ .@"error" = .{
                            .code = "source_unavailable",
                            .message = try std.fmt.allocPrint(scratch, "Could not read host file '{s}': {s}. This write was not sent to memory.", .{ source.path, @errorName(err) }),
                        } },
                    },
                };
                if (bytes.len > entry_size_limit)
                    return .{ .@"error" = .{ .code = "entry_too_large", .message = "A memory write can transfer at most 33554432 bytes (32 MiB). No write was sent." } };
                const encoder = std.base64.standard.Encoder;
                const data = try scratch.alloc(u8, encoder.calcSize(bytes.len));
                _ = encoder.encode(data, bytes);
                break :blk try std.json.Stringify.valueAlloc(scratch, .{ .remember = .{
                    .address = args.address,
                    .data = data,
                    .mode = args.mode,
                } }, .{ .emit_null_optional_fields = false });
            },
            else => try std.json.Stringify.valueAlloc(scratch, request, .{ .emit_null_optional_fields = false }),
        };

        var argv: std.array_list.Managed([]const u8) = .init(scratch);
        try argv.appendSlice(&.{
            "ssh", "-T",
            "-o",  "BatchMode=yes",
            "-o",  "ConnectTimeout=10",
            "-o",  "ServerAliveInterval=15",
            "-o",  "ServerAliveCountMax=2",
        });
        if (self.ssh_config) |config| try argv.appendSlice(&.{ "-F", config });
        try argv.appendSlice(&.{
            "--", self.ssh_target, "/usr/local/bin/memory-shell",
        });

        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        const process_id = child.id.?;
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromSeconds(60), .clock = .awake });
        const Result = union(enum) { reply: anyerror!Reply, timeout: std.Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &buffer);
        defer {
            // Stop SSH before joining transport work, including a protected
            // wait and a writer blocked on a pipe. No failed write is retried.
            if (child.id != null) std.posix.kill(process_id, .KILL) catch {};
            select.cancelDiscard();
            child.kill(self.io);
        }
        try select.concurrent(.reply, exchangeChild, .{ self, scratch, request, &child, payload });
        try select.concurrent(.timeout, waitForDeadline, .{ self.io, deadline });
        return switch (try select.await()) {
            .reply => |reply| try reply,
            .timeout => |result| blk: {
                try result;
                std.log.err("memory request {s}: SSH exchange exceeded 60 seconds; effects may be unknown", .{@tagName(request)});
                break :blk error.MemoryRequestTimedOut;
            },
        };
    }

    fn exchangeChild(self: Memory, scratch: Allocator, request: Request, child: *std.process.Child, payload: []const u8) !Reply {
        // The writer must progress while both output pipes are drained. An
        // async call may run inline, so request actual concurrency here.
        var input = try self.io.concurrent(writeRequest, .{ self.io, child.stdin.?, payload });
        child.stdin = null; // The writer owns this pipe and closes it at EOF.
        defer input.cancel(self.io) catch {};

        var reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(scratch, self.io, reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();

        while (reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try reader.checkAnyError();

        try input.await(self.io);
        const term = try waitForChild(child, self.io);
        const stdout = try reader.toOwnedSlice(0);
        const stderr = try reader.toOwnedSlice(1);
        if (term != .exited or (term.exited != 0 and term.exited != 1)) {
            std.log.err("memory room request {s}: SSH {f}; {s}", .{ @tagName(request), term, stderr });
            return error.MemoryConnectionFailed;
        }
        const reply = try std.json.parseFromSliceLeaky(Reply, scratch, stdout, .{});
        const expected_exit: u8 = switch (reply) {
            .result => 0,
            .@"error" => 1,
        };
        if (term.exited != expected_exit) return error.InvalidMemoryReply;
        return reply;
    }
};

const Read = struct {
    address: []const u8,
    bytes: []const u8,
    header: []const u8,
    byte_length: u64,
    offset: u64,

    fn parse(a: Allocator, value: Value, args: @FieldType(Memory.Request, "read_memory")) !Read {
        const Encoded = struct { address: []const u8, data: []const u8, header: []const u8, byte_length: u64, offset: u64 };
        const encoded = std.json.parseFromValueLeaky(Encoded, a, value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMemoryReply,
        };
        const bytes = try decode(a, encoded.data);
        const header = try decode(a, encoded.header);
        if (encoded.offset != args.offset or encoded.offset > encoded.byte_length) return error.InvalidMemoryReply;
        const expected = @min(args.max_bytes, encoded.byte_length - encoded.offset);
        if (bytes.len != expected or header.len != @min(32, encoded.byte_length)) return error.InvalidMemoryReply;
        if (encoded.offset == 0 and !std.mem.eql(u8, bytes[0..@min(header.len, bytes.len)], header[0..@min(header.len, bytes.len)]))
            return error.InvalidMemoryReply;
        return .{ .address = encoded.address, .bytes = bytes, .header = header, .byte_length = encoded.byte_length, .offset = encoded.offset };
    }

    fn decode(a: Allocator, data: []const u8) ![]const u8 {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(data) catch return error.InvalidMemoryReply;
        if (size > entry_size_limit) return error.InvalidMemoryReply;
        const bytes = try a.alloc(u8, size);
        decoder.decode(bytes, data) catch return error.InvalidMemoryReply;
        return bytes;
    }

    fn render(self: Read, a: Allocator, args: @FieldType(Memory.Request, "read_memory")) !Content {
        if (content.detectFormat(self.header) != null) {
            if (self.offset != 0)
                return toolError(a, "invalid_range", "Image entries are read as complete images; use offset 0.");
            if (self.byte_length > content.image_size_limit)
                return self.unavailable(a, .image_too_large);
            if (self.bytes.len != self.byte_length) return error.InvalidMemoryReply;
            return self.classified(a, content.classify(self.bytes));
        }
        if (args.interpretation != null) {
            if (self.byte_length > content.reference_size_limit)
                return self.unavailable(a, .reference_too_large);
            if (self.bytes.len != self.byte_length) return error.InvalidMemoryReply;
            return self.classified(a, content.interpret(self.bytes, args.interpretation));
        }
        if (self.offset != 0 and self.bytes.len > 0 and self.bytes[0] & 0xc0 == 0x80)
            return toolError(a, "invalid_range", "The byte offset is inside a UTF-8 character. Resume with a next_offset returned by read_memory.");
        const maximum = @min(self.bytes.len, args.max_bytes);
        var end = content.textPrefixLength(self.bytes[0..maximum], self.offset + maximum < self.byte_length) orelse
            return self.unavailable(a, .unsupported_binary);
        while (true) {
            const next = self.offset + end;
            const json = try std.json.Stringify.valueAlloc(a, .{ .result = .{
                .address = self.address,
                .content = self.bytes[0..end],
                .byte_length = self.byte_length,
                .offset = self.offset,
                .next_offset = if (next < self.byte_length) @as(?u64, next) else null,
            } }, .{});
            if (json.len <= reply_size_limit) return Content.fromText(a, json);
            a.free(json);
            if (end == 0) return toolError(a, "result_too_large", "This entry's address exceeds the result size limit.");
            end /= 2;
            while (end > 0 and self.bytes[end] & 0xc0 == 0x80) end -= 1;
        }
    }

    fn unavailable(self: Read, a: Allocator, reason: @FieldType(content.Unavailable, "reason")) !Content {
        return self.classified(a, .{ .unavailable = .{ .byte_length = self.byte_length, .reason = reason } });
    }

    fn classified(self: Read, a: Allocator, value: content.Classified) !Content {
        return switch (value) {
            .text => |text| Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = .{ .address = self.address, .content = text, .byte_length = self.byte_length, .offset = self.offset, .next_offset = @as(?u64, null) } }, .{})),
            .image => |raw_image| blk: {
                const image: content.ImageContent = switch (raw_image) {
                    .data => |data| .{ .data = .{ .format = data.format, .bytes = try a.dupe(u8, data.bytes) } },
                    .url => |url| .{ .url = try a.dupe(u8, url) },
                };
                break :blk Content.fromParts(a, &.{
                    .{ .text = try std.json.Stringify.valueAlloc(a, .{ .result = .{ .address = self.address, .content = .{ .image = image.describe() }, .byte_length = self.byte_length } }, .{}) },
                    .{ .image = image },
                });
            },
            .unavailable => |diagnostic| Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = .{ .address = self.address, .content = .{ .unavailable = diagnostic } } }, .{})),
        };
    }
};

fn toolError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}

fn readSourceFile(io: std.Io, a: Allocator, path: []const u8) ![]const u8 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > entry_size_limit) return error.StreamTooLong;
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(entry_size_limit + 1));
}

fn waitForChild(child: *std.process.Child, io: std.Io) std.process.Child.WaitError!std.process.Child.Term {
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    return child.wait(io);
}

fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    try deadline.wait(io);
}

fn writeRequest(io: std.Io, file: std.Io.File, payload: []const u8) std.Io.File.Writer.Error!void {
    defer file.close(io);
    try file.writeStreamingAll(io, payload);
}

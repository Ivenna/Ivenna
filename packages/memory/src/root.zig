const std = @import("std");
const content = @import("content");

const Allocator = std.mem.Allocator;
const Tools = @import("agent_contracts").Tools;
const Model = @import("agent_contracts").Model;
const Value = std.json.Value;
const Content = content.Content;
const Interpretation = content.Interpretation;

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

    fn invokeTool(context: *anyopaque, a: Allocator, _: u64, name: []const u8, arguments: []const u8) anyerror!?Content {
        const self: *Memory = @ptrCast(@alignCast(context));
        const request = try Request.parse(a, name, arguments) orelse return null;
        return try self.invoke(a, request);
    }

    const MatchMode = enum { literal, regex };

    pub const Request = union(enum) {
        inspect_memory_space: struct {},
        browse_memory: struct {
            address: []const u8 = ".",
            entry_only: bool = false,
            recursive_size: bool = false,
        },
        find_memory: struct {
            query: []const u8,
            room: ?[]const u8 = null,
            match_mode: ?enum { literal, glob, regex } = null,
            case_sensitive: ?bool = null,
        },
        recall_memory: struct {
            clue: []const u8,
            room: ?[]const u8 = null,
            match_mode: ?MatchMode = null,
            case_sensitive: ?bool = null,
        },
        read_memory: struct {
            address: []const u8,
            interpretation: ?Interpretation = null,
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
        const reply = try self.exchange(scratch, request);
        if (request == .read_memory and reply == .result)
            return readReply(allocator, reply.result, request.read_memory.interpretation);
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
                    .file => |source| std.Io.Dir.cwd().readFileAlloc(self.io, source.path, scratch, .unlimited) catch |err| switch (err) {
                        error.Canceled, error.OutOfMemory => return err,
                        else => return .{ .@"error" = .{
                            .code = "source_unavailable",
                            .message = try std.fmt.allocPrint(scratch, "Could not read host file '{s}': {s}. This write was not sent to memory.", .{ source.path, @errorName(err) }),
                        } },
                    },
                };
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
        errdefer child.kill(self.io);

        // The writer must progress while both output pipes are drained. An
        // async call may run inline, so request actual concurrency here.
        var input = try self.io.concurrent(writeRequest, .{ self.io, child.stdin.?, payload });
        child.stdin = null; // The writer owns this pipe and closes it at EOF.
        defer {
            child.kill(self.io);
            input.cancel(self.io) catch {};
        }

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
        const term = try child.wait(self.io);
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

fn readReply(allocator: Allocator, value: Value, interpretation: ?Interpretation) !Content {
    if (value != .object) return error.InvalidMemoryReply;
    const address = value.object.get("address") orelse return error.InvalidMemoryReply;
    const data = value.object.get("data") orelse return error.InvalidMemoryReply;
    if (address != .string or data != .string) return error.InvalidMemoryReply;

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(data.string) catch return error.InvalidMemoryReply;
    const bytes = try allocator.alloc(u8, size);
    var retain_bytes = false;
    defer if (!retain_bytes) allocator.free(bytes);
    decoder.decode(bytes, data.string) catch return error.InvalidMemoryReply;

    return switch (content.interpret(bytes, interpretation)) {
        .text => |text| Content.fromText(allocator, try std.json.Stringify.valueAlloc(allocator, .{
            .result = .{ .address = address.string, .content = text },
        }, .{})),
        .image => |image| blk: {
            const result = try Content.fromParts(allocator, &.{
                .{ .text = try std.json.Stringify.valueAlloc(allocator, .{
                    .result = .{ .address = address.string, .content = .{ .image = image.describe() } },
                }, .{}) },
                .{ .image = image },
            });
            retain_bytes = true;
            break :blk result;
        },
        .unavailable => |unavailable| Content.fromText(allocator, try std.json.Stringify.valueAlloc(allocator, .{
            .result = .{ .address = address.string, .content = .{ .unavailable = unavailable } },
        }, .{})),
    };
}

fn writeRequest(io: std.Io, file: std.Io.File, payload: []const u8) std.Io.File.Writer.Error!void {
    defer file.close(io);
    try file.writeStreamingAll(io, payload);
}

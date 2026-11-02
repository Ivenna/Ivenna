const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Memory = struct {
    io: std.Io,
    ssh_target: []const u8,
    ssh_config: ?[]const u8 = null,

    const MatchMode = enum { literal, regex };

    pub const Request = union(enum) {
        browse_memory_room: struct { room: ?[]const u8 = null },
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
        read_memory: struct { address: []const u8 },
        remember: struct {
            address: []const u8,
            content: []const u8,
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
            return switch (tag) {
                inline else => |active| @unionInit(Request, @tagName(active), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(active)), allocator, arguments, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidToolArguments,
                }),
            };
        }

        fn changesMemory(request: Request) bool {
            return switch (request) {
                .remember, .revise_memory, .create_memory_room, .move_memory, .forget_memory => true,
                else => false,
            };
        }
    };

    pub const Reply = union(enum) {
        result: Value,
        @"error": struct { code: []const u8, message: []const u8 },
    };

    pub fn invoke(self: Memory, allocator: Allocator, request: Request) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        // Missing overrides remain missing; the execution boundary owns defaults.
        const payload = try std.json.Stringify.valueAlloc(scratch, request, .{ .emit_null_optional_fields = false });

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

        // A disconnected write may already have changed memory. Expose that
        // uncertainty in memory terms while keeping SSH diagnostics in logs.
        const input_error: ?[]const u8 = if (input.await(self.io)) |_| null else |err| switch (err) {
            error.Canceled => return err,
            else => @errorName(err),
        };
        const term = try child.wait(self.io);
        const stdout = try reader.toOwnedSlice(0);
        const stderr = try reader.toOwnedSlice(1);
        const reply: ?Reply = std.json.parseFromSliceLeaky(Reply, scratch, stdout, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };

        if (input_error == null and term == .exited) {
            if (reply) |response| {
                const expected_exit: u8 = switch (response) {
                    .result => 0,
                    .@"error" => 1,
                };
                if (term.exited == expected_exit) return allocator.dupe(u8, stdout);
            }
        }

        std.log.warn("memory room request {s}: SSH {f}; input error: {s}; {s}", .{
            @tagName(request), term, input_error orelse "none", stderr,
        });
        const failure: Reply = .{ .@"error" = if (request.changesMemory()) .{
            .code = "memory_change_uncertain",
            .message = "The memory room did not return a complete response. Memory may have changed; inspect it before retrying the change.",
        } else .{
            .code = "memory_unavailable",
            .message = "The memory room did not return a complete response. Check the connection before trying again.",
        } };
        return std.json.Stringify.valueAlloc(allocator, failure, .{});
    }
};

fn writeRequest(io: std.Io, file: std.Io.File, payload: []const u8) std.Io.File.Writer.Error!void {
    defer file.close(io);
    try file.writeStreamingAll(io, payload);
}

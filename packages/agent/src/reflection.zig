const std = @import("std");
const Model = @import("agent_contracts").Model;
const Engine = @import("engine.zig").Engine;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

pub const Rejection = union(enum) {
    empty_reflection,
    unexpected_tool_call,
    too_large: Model.Limit,

    fn feedback(self: Rejection) []const u8 {
        return switch (self) {
            .empty_reflection => "Leave a brief reflection in your own words.",
            .unexpected_tool_call => "Write your reflection directly.",
            .too_large => "Leave yourself a shorter note.",
        };
    }

    pub fn interruption(self: Rejection, focus_id: []const u8) []const u8 {
        return switch (self) {
            .empty_reflection => "The quiet reflection returned no text.",
            .unexpected_tool_call => "The quiet reflection returned a tool call.",
            .too_large => |limit| Engine.reportRequestLimit(focus_id, "request with the proposed continuity record", limit),
        };
    }
};

pub const Result = union(enum) {
    continuity: Input.Continuity,
    rejected: Rejection,
    interrupted: []const u8,
};

/// Ask the focus to reflect on the selected history. Kernel measures the
/// continuation and decides whether to request a revised account.
pub fn reflect(engine: *Engine, arena: Allocator, context: *const Context, snapshot: Input.Snapshot, scope: Context.CompactionScope, previous: ?Rejection, retry: Engine.Retry) !Result {
    const task = comptime std.mem.trimEnd(u8, @embedFile("quiet_reflection.md"), "\r\n");
    const instructions = if (previous) |reason|
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ task, reason.feedback() })
    else
        task;
    const history = try context.reflectionRequest(arena, snapshot, instructions, scope);
    const request: Model.Request = .{
        .history = history,
        .tools = &.{},
        .reasoning_effort = engine.reasoning.compaction,
    };
    while ((try engine.model.measure(arena, request)).violation) |limit| {
        if (!try Context.replaceReflectionMedia(arena, history, limit.kind))
            return .{ .interrupted = Engine.reportRequestLimit(context.focus_id, "quiet reflection request", limit) };
    }
    var inference = switch (try engine.infer(context.focus_id, request, retry)) {
        .ready => |result| result,
        .interrupted => |reason| return .{ .interrupted = reason },
    };
    defer inference.deinit();
    const response = inference.response;
    if (response.calls.len != 0) return .{ .rejected = .unexpected_tool_call };
    const text = response.text orelse "";
    if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) return .{ .rejected = .empty_reflection };
    return .{ .continuity = .{
        .focus_id = context.focus_id,
        .observed_at_unix_ms = snapshot.current.observed_at_unix_ms,
        .text = try arena.dupe(u8, text),
        .state = snapshot.state,
    } };
}

test "a reflection that cannot shed media interrupts with the request limit" {
    const testing = std.testing;
    const Stub = struct {
        fn measure(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Measurement {
            return .{ .bytes = 10, .violation = .{ .kind = .request_bytes, .actual = 10, .maximum = 1 } };
        }

        fn next(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Outcome {
            return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "unused" } };
        }
    };
    var stub: Stub = .{};
    var engine: Engine = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .model = .{ .context = &stub, .vtable = &.{ .next = Stub.next, .measure = Stub.measure, .prepareToolResult = undefined } },
        .shared_tools = &.{},
        .activity_tools = &.{},
    };
    var context = try Context.init(testing.allocator, .{ .session_id = 1, .epoch = 0 }, "core-1");
    defer context.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snapshot: Input.Snapshot = .{
        .current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 100 },
        .state = .{ .activities = &.{}, .callbacks = &.{} },
    };
    const result = try reflect(&engine, arena.allocator(), &context, snapshot, .keep_latest_tool_round, null, .single_attempt);
    try testing.expect(result == .interrupted);
    try testing.expectEqualStrings("The context was too large to continue.", result.interrupted);
    try testing.expectEqual(@as(usize, 0), context.records().len);
}

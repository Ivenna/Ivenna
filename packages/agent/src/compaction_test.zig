const std = @import("std");
const Model = @import("agent_contracts").Model;
const Engine = @import("engine.zig").Engine;
const Context = @import("context.zig").Context;
const Input = @import("input.zig");
const Compaction = @import("compaction.zig");
const Allocator = std.mem.Allocator;

const summary = "Handover summary.";

const Fixture = struct {
    effort: ?Model.ReasoningEffort = null,
    attempts: usize = 0,

    fn next(context: *anyopaque, arena: Allocator, request: Model.Request) anyerror!Model.Outcome {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.attempts += 1;
        self.effort = request.reasoning_effort;
        return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = try arena.dupe(u8, summary) } };
    }

    fn measure(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Measurement {
        return .{ .bytes = 0 };
    }

    fn prepareToolReplies(_: *anyopaque, _: Allocator, _: []Model.Item) anyerror!void {}
};

test "default compaction effort stays high" {
    const reasoning: Engine.Reasoning = .{};
    try std.testing.expectEqual(Model.ReasoningEffort.high, reasoning.compaction);
}

test "a handover request carries the configured compaction effort" {
    for ([_]Model.ReasoningEffort{ .high, .low, .max }) |effort| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var fixture: Fixture = .{};
        var engine: Engine = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .model = .{ .context = &fixture, .vtable = &.{
                .next = Fixture.next,
                .measure = Fixture.measure,
                .prepareToolReplies = Fixture.prepareToolReplies,
            } },
            .shared_tools = &.{},
            .activity_tools = &.{},
            .reasoning = .{ .compaction = effort },
        };
        var context = try Context.init(std.testing.allocator, .{ .session_id = 1, .epoch = 1 }, "core-1");
        defer context.deinit();
        const snapshot: Input.Snapshot = .{
            .current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 0 },
            .state = .{ .activities = &.{}, .callbacks = &.{} },
        };
        const result = try Compaction.summarize(&engine, a, &context, snapshot, .keep_latest_tool_round, null, .single_attempt);
        const handover = switch (result) {
            .handover => |handover| handover,
            .rejected => return error.UnexpectedRejection,
            .interrupted => return error.UnexpectedInterruption,
        };
        try std.testing.expectEqualStrings(summary, handover.summary);
        try std.testing.expectEqual(effort, fixture.effort.?);
        try std.testing.expectEqual(1, fixture.attempts);
    }
}

const std = @import("std");
const Model = @import("agent_contracts").Model;
const Engine = @import("engine.zig").Engine;
const Allocator = std.mem.Allocator;

const request: Model.Request = .{
    .history = &.{.{ .message = .{ .role = .user, .text = "Continue from the observation." } }},
    .tools = &.{.{ .name = "inspect", .description = "Inspect an entry.", .parameters = .{ .object = .empty } }},
    .reasoning_effort = .high,
};
const retry_after_ms = 600_000;

const Fixture = struct {
    cancel_wait: bool,
    attempts: usize = 0,
    waited_ms: i64 = 0,

    fn next(context: *anyopaque, arena: Allocator, received: Model.Request) anyerror!Model.Outcome {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try std.testing.expectEqualDeep(request, received);
        self.attempts += 1;
        return switch (self.attempts) {
            1 => .{ .unavailable = .{ .retry_after_ms = retry_after_ms } },
            2 => .{ .response = .{ .output = &.{}, .calls = &.{}, .text = try arena.dupe(u8, "Resumed.") } },
            else => error.UnexpectedInference,
        };
    }

    fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {}

    fn measure(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Measurement {
        return error.UnexpectedMeasurement;
    }

    fn prepareToolReplies(_: *anyopaque, _: Allocator, _: []Model.Item) anyerror!void {
        return error.UnexpectedToolBatch;
    }

    fn sleep(context: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.waited_ms += timeout.duration.raw.toMilliseconds();
        if (self.cancel_wait) return error.Canceled;
    }
};

test "inference honors the model's recovery delay and resumes the original request unless canceled" {
    var io_vtable = std.Io.failing.vtable.*;
    io_vtable.checkCancel = Fixture.checkCancel;
    io_vtable.sleep = Fixture.sleep;
    for ([_]bool{ false, true }) |cancel_wait| {
        var fixture: Fixture = .{ .cancel_wait = cancel_wait };
        var engine: Engine = .{
            .allocator = std.testing.allocator,
            .io = .{ .userdata = &fixture, .vtable = &io_vtable },
            .model = .{ .context = &fixture, .vtable = &.{
                .next = Fixture.next,
                .measure = Fixture.measure,
                .prepareToolReplies = Fixture.prepareToolReplies,
            } },
            .shared_tools = &.{},
            .activity_tools = &.{},
        };
        if (cancel_wait) {
            try std.testing.expectError(error.Canceled, engine.infer("activity-2", request, .wait_for_service));
            try std.testing.expectEqual(1, fixture.attempts);
        } else {
            var inference = (try engine.infer("activity-2", request, .wait_for_service)).ready;
            defer inference.deinit();
            try std.testing.expectEqualStrings("Resumed.", inference.response.text.?);
            try std.testing.expectEqual(2, fixture.attempts);
        }
        try std.testing.expectEqual(retry_after_ms, fixture.waited_ms);
    }
}

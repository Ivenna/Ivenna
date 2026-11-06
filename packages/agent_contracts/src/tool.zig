const std = @import("std");
const Content = @import("content").Content;
const Model = @import("model.zig");

/// A body capability supplies a result when it recognizes the tool name.
/// Null delegates to another capability; invocation failures propagate.
/// Declarations and the implementation outlive their registration with Engine.
/// Invocation argument bytes are borrowed for the duration of the call.
/// Results belong to the supplied allocator and outlive temporary I/O buffers.
pub const Tools = struct {
    context: *anyopaque,
    declarations: []const Model.Tool,
    invoke: *const fn (*anyopaque, std.mem.Allocator, u64, []const u8, []const u8) anyerror!?Content,
};

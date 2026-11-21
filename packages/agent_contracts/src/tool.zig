const std = @import("std");
const Content = @import("content").Content;
const Model = @import("model.zig");
const Callback = @import("callback.zig");
const Reference = @import("reference.zig");

/// A body capability supplies a result when it recognizes the tool name.
/// Null delegates to another capability; invocation failures propagate.
/// Declarations and the implementation outlive their registration with Engine.
/// Invocation argument bytes are borrowed for the duration of the call.
/// Results belong to the supplied allocator and outlive temporary I/O buffers.
pub const Tools = struct {
    /// Internal execution identity and its complete model-facing focus reference.
    /// The focus reference, callback registrar, and command reference issuer
    /// are borrowed for this invocation.
    pub const Invocation = struct {
        session_id: u64,
        focus_id: []const u8,
        callback: ?Callback.Registrar = null,
        command_reference: ?Reference.Issuer = null,
    };

    context: *anyopaque,
    declarations: []const Model.Tool,
    invoke: *const fn (*anyopaque, std.mem.Allocator, Invocation, []const u8, []const u8) anyerror!?Content,
};

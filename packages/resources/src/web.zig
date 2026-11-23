const std = @import("std");

pub const Page = struct { title: []const u8, markdown: []const u8 };

pub const Outcome = union(enum) {
    page: Page,
    failure: struct { code: Code, message: []const u8 },

    const Code = enum { invalid_uri, not_readable, web_unavailable, rate_limited, read_timeout, page_too_large };

    pub fn failed(code: Code, message: []const u8) Outcome {
        return .{ .failure = .{ .code = code, .message = message } };
    }
};

pub const Reader = struct {
    context: *const anyopaque,
    /// The destination of a source URL and any cost of opening it.
    disclosure: []const u8,
    /// Returns one page in the supplied arena, or an explanation the focus can use.
    fetch: *const fn (*const anyopaque, std.mem.Allocator, []const u8) error{ Canceled, OutOfMemory }!Outcome,
};

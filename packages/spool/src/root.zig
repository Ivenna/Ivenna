const std = @import("std");

pub const Spool = @import("inbox.zig").Spool;
pub const Composite = @import("composite.zig").Composite;

test {
    _ = @import("inbox.zig");
    _ = @import("composite.zig");
}

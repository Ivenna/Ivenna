//! Durable state kept in the instance's local data directory.

const database = @import("database.zig");

pub const filename = database.filename;
pub const subscriptions = @import("subscriptions.zig");

test {
    _ = @import("migrations.zig");
    _ = subscriptions;
}

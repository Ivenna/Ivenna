//! Durable state kept in the instance's local data directory.

const database = @import("database.zig");

pub const filename = database.filename;
pub const initialize = database.initialize;
pub const subscriptions = @import("subscriptions.zig");

test {
    _ = database;
    _ = subscriptions;
}

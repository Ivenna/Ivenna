/// Tool discovery data independent of deployment configuration and storage.
pub const Tool = struct {
    name: []const u8,
    command: []const u8,
    description: []const u8,
    help: []const u8,
};

pub const Catalog = struct { tools: []const Tool };

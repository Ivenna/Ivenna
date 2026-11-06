const Communication = @import("communication.zig");

/// File reference and recorded byte length for material kept outside the payload.
pub const Resource = struct {
    file: []const u8,
    byte_length: usize,
};

/// Complete inline text or an excerpt with a reference to the complete material.
pub const MaterialContent = union(enum) {
    text: []const u8,
    excerpt: struct {
        text: []const u8,
        full: Resource,
    },
};

/// Material provenance, independent of the contacts available for communication.
pub const Source = struct {
    reference: []const u8,
    description: ?[]const u8 = null,
    observed_at_unix_ms: ?i64 = null,
    details: ?Resource = null,
};

/// Content, contacts, and optional provenance for an arrival or supporting evidence.
pub const Material = struct {
    content: MaterialContent,
    contacts: []const Communication.Contact = &.{},
    source: ?Source = null,
};

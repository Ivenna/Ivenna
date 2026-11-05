pub const Contact = struct {
    reference: []const u8,
    description: ?[]const u8 = null,
};

pub const Message = struct {
    recipients: []const []const u8,
    text: []const u8,
};

pub const Submission = struct {
    reference: []const u8,
};

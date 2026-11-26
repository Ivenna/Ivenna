const std = @import("std");
const agent = @import("agent");
const responses = @import("responses");

pub const Config = struct {
    service_address: std.Io.net.IpAddress,
    data_dir: []const u8,
    memory_ssh_target: []const u8,
    memory_ssh_config: ?[]const u8,
    mail_session_url: []const u8,
    mail_address: []const u8,
    mail_correspondents: []const []const u8,
    mail_authentication: union(enum) {
        authorization: []const u8,
        credentials: struct { username: []const u8, password: []const u8 },
    },
    mail_poll_interval_ms: u32,
    max_sessions: usize,
    max_pending_events: usize,
    max_host_commands: usize,
    deepseek_api_key: ?[]const u8,
    context_limits: agent.Kernel.Limits,
    llm_base_url: []const u8,
    llm_api_key: []const u8,
    llm_model: []const u8,
    llm_max_output_tokens: u32,
    llm_request_timeout_ms: u32,
    llm_reasoning: agent.Engine.Reasoning,

    /// The address list belongs to a. All strings borrow the process environment.
    pub fn load(a: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
        const mail_auth = env.get("MAIL_AUTHORIZATION");
        const fetch_key = env.get("DEEPSEEK_API_KEY") orelse "";
        const default_reasoning: agent.Engine.Reasoning = .{};
        const default_limits: agent.Kernel.Limits = .{};
        const correspondents = try mailCorrespondents(a, env);
        errdefer a.free(correspondents);
        const config: Config = .{
            .service_address = try serviceAddress(env),
            .data_dir = try nonempty(env, "DATA_DIR", ""),
            .memory_ssh_target = try nonempty(env, "MEMORY_SSH_TARGET", "ivenna-memory"),
            .memory_ssh_config = env.get("MEMORY_SSH_CONFIG"),
            .mail_session_url = try nonempty(env, "MAIL_SESSION_URL", "http://127.0.0.1:8088/jmap/session"),
            .mail_address = try nonempty(env, "MAIL_ADDRESS", ""),
            .mail_correspondents = correspondents,
            .mail_authentication = if (mail_auth) |value| blk: {
                if (value.len == 0) return error.MissingMailCredentials;
                break :blk .{ .authorization = value };
            } else blk: {
                const username = env.get("MAIL_USERNAME") orelse return error.MissingMailCredentials;
                const password = env.get("MAIL_PASSWORD") orelse return error.MissingMailCredentials;
                if (username.len == 0 or password.len == 0) return error.MissingMailCredentials;
                break :blk .{ .credentials = .{ .username = username, .password = password } };
            },
            .mail_poll_interval_ms = try number(u32, env, "MAIL_POLL_INTERVAL_MS", 2000),
            .max_sessions = try number(usize, env, "MAX_SESSIONS", 128),
            .max_pending_events = try number(usize, env, "MAX_PENDING_EVENTS", 64),
            .max_host_commands = try number(usize, env, "MAX_HOST_COMMANDS", 8),
            .deepseek_api_key = if (fetch_key.len > 0) fetch_key else null,
            .context_limits = .{
                .compact_at_tokens = try number(u64, env, "CONTEXT_COMPACT_AT_TOKENS", default_limits.compact_at_tokens),
                .compact_at_bytes = try number(u64, env, "CONTEXT_COMPACT_AT_BYTES", default_limits.compact_at_bytes),
                .observation_batch_bytes = try number(u64, env, "CONTEXT_OBSERVATION_BATCH_BYTES", default_limits.observation_batch_bytes),
                .history_inline_image_bytes = try numberAllowingZero(u64, env, "HISTORY_INLINE_IMAGE_BYTES", default_limits.history_inline_image_bytes),
            },
            .llm_base_url = try nonempty(env, "LLM_BASE_URL", responses.Provider.default_base_url),
            .llm_api_key = try nonempty(env, "LLM_API_KEY", ""),
            .llm_model = try nonempty(env, "LLM_MODEL", responses.Provider.default_model),
            .llm_max_output_tokens = try number(u32, env, "LLM_MAX_OUTPUT_TOKENS", responses.Provider.default_max_output_tokens),
            .llm_request_timeout_ms = try number(u32, env, "LLM_REQUEST_TIMEOUT_MS", responses.Provider.default_request_timeout_ms),
            .llm_reasoning = .{
                .core = try nonempty(env, "LLM_CORE_REASONING_EFFORT", default_reasoning.core),
                .activity = try nonempty(env, "LLM_ACTIVITY_REASONING_EFFORT", default_reasoning.activity),
                .compaction = try nonempty(env, "LLM_COMPACTION_REASONING_EFFORT", default_reasoning.compaction),
            },
        };
        if (config.memory_ssh_config) |path| if (path.len == 0) return error.MissingMemorySshConfig;
        return config;
    }

    pub fn authorization(self: Config, a: std.mem.Allocator) ![]const u8 {
        const account = switch (self.mail_authentication) {
            .authorization => |value| return value,
            .credentials => |value| value,
        };
        const credentials = try std.fmt.allocPrint(a, "{s}:{s}", .{ account.username, account.password });
        defer a.free(credentials);
        const encoder = std.base64.standard.Encoder;
        const value = try a.alloc(u8, "Basic ".len + encoder.calcSize(credentials.len));
        @memcpy(value[0.."Basic ".len], "Basic ");
        _ = encoder.encode(value["Basic ".len..], credentials);
        return value;
    }
};

fn serviceAddress(env: *const std.process.Environ.Map) !std.Io.net.IpAddress {
    const value = try nonempty(env, "SERVICE_ADDRESS", "0.0.0.0:8090");
    const address = std.Io.net.IpAddress.parseLiteral(value) catch return error.InvalidServiceAddress;
    if (address.getPort() == 0) return error.InvalidServiceAddress;
    return address;
}

fn nonempty(env: *const std.process.Environ.Map, key: []const u8, default: []const u8) ![]const u8 {
    const value = env.get(key) orelse default;
    if (value.len == 0) return error.MissingConfiguration;
    return value;
}

fn mailCorrespondents(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const []const u8 {
    const text = std.mem.trim(u8, env.get("MAIL_CORRESPONDENTS") orelse "", " \t");
    if (text.len == 0) return &.{};
    const addresses = try a.alloc([]const u8, std.mem.count(u8, text, ",") + 1);
    var items = std.mem.splitScalar(u8, text, ',');
    for (addresses) |*address| address.* = std.mem.trim(u8, items.next().?, " \t");
    return addresses;
}

fn number(comptime T: type, env: *const std.process.Environ.Map, key: []const u8, default: T) !T {
    const value = try numberAllowingZero(T, env, key, default);
    if (value == 0) return error.InvalidConfiguration;
    return value;
}

/// Zero can be meaningful for a limit: for example, it disables inline images
/// in working history while still allowing text and file references.
fn numberAllowingZero(comptime T: type, env: *const std.process.Environ.Map, key: []const u8, default: T) !T {
    const text = env.get(key) orelse return default;
    return std.fmt.parseInt(T, text, 10) catch return error.InvalidConfiguration;
}

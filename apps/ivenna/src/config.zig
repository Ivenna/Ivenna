const std = @import("std");
const agent = @import("agent");
const Model = @import("agent_contracts").Model;
const responses = @import("responses");

pub const Config = struct {
    service_address: std.Io.net.IpAddress,
    data_dir: []const u8,
    memory_ssh_target: []const u8,
    memory_ssh_config: ?[]const u8,
    mail_session_url: []const u8,
    mail_address: []const u8,
    mail_authentication: union(enum) {
        authorization: []const u8,
        credentials: struct { username: []const u8, password: []const u8 },
    },
    mail_poll_interval_ms: u32,
    max_parallel_attention: usize,
    max_attention_contexts: usize,
    context_limits: agent.Kernel.Limits,
    llm_base_url: []const u8,
    llm_api_key: []const u8,
    llm_model: []const u8,
    llm_max_output_tokens: u32,
    llm_reasoning: agent.Engine.Reasoning,

    /// Text borrows the process environment, which outlives the application.
    pub fn load(env: *const std.process.Environ.Map) !Config {
        const mail_auth = env.get("MAIL_AUTHORIZATION");
        const default_reasoning: agent.Engine.Reasoning = .{};
        const config: Config = .{
            .service_address = try serviceAddress(env),
            .data_dir = try nonempty(env, "DATA_DIR", ".ivenna"),
            .memory_ssh_target = try nonempty(env, "MEMORY_SSH_TARGET", "ivenna-memory"),
            .memory_ssh_config = env.get("MEMORY_SSH_CONFIG"),
            .mail_session_url = try nonempty(env, "MAIL_SESSION_URL", "http://127.0.0.1:8088/jmap/session"),
            .mail_address = try nonempty(env, "MAIL_ADDRESS", ""),
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
            .max_parallel_attention = try number(usize, env, "MAX_PARALLEL_ATTENTION", 4),
            .max_attention_contexts = try number(usize, env, "MAX_ATTENTION_CONTEXTS", 32),
            .context_limits = .{
                .request_bytes = try number(u64, env, "CONTEXT_REQUEST_BYTES", 65536),
                .compaction_bytes = try number(u64, env, "CONTEXT_COMPACTION_BYTES", 131072),
                .handover_bytes = try number(usize, env, "HANDOVER_MAX_BYTES", 8192),
            },
            .llm_base_url = try nonempty(env, "LLM_BASE_URL", responses.Provider.default_base_url),
            .llm_api_key = try nonempty(env, "LLM_API_KEY", ""),
            .llm_model = try nonempty(env, "LLM_MODEL", responses.Provider.default_model),
            .llm_max_output_tokens = try number(u32, env, "LLM_MAX_OUTPUT_TOKENS", 8192),
            .llm_reasoning = .{
                .core = try reasoningEffort(env, "LLM_CORE_REASONING_EFFORT", default_reasoning.core),
                .branch = try reasoningEffort(env, "LLM_BRANCH_REASONING_EFFORT", default_reasoning.branch),
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

fn reasoningEffort(env: *const std.process.Environ.Map, key: []const u8, fallback: Model.ReasoningEffort) !Model.ReasoningEffort {
    const value = env.get(key) orelse return fallback;
    return std.meta.stringToEnum(Model.ReasoningEffort, value) orelse error.InvalidReasoningEffort;
}

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

fn number(comptime T: type, env: *const std.process.Environ.Map, key: []const u8, default: T) !T {
    const text = env.get(key) orelse return default;
    const value = std.fmt.parseInt(T, text, 10) catch return error.InvalidConfiguration;
    if (value == 0) return error.InvalidConfiguration;
    return value;
}

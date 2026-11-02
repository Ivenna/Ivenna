const std = @import("std");
const Provider = @import("agent").Provider;

pub const Config = struct {
    database_url: []const u8,
    memory_ssh_target: []const u8,
    memory_ssh_config: ?[]const u8,
    host: []const u8,
    port: u16,
    llm_base_url: []const u8,
    llm_api_key: []const u8,
    llm_model: []const u8,

    /// Values borrow the process environment, which outlives the server.
    pub fn load(env: *const std.process.Environ.Map) !Config {
        const database_url = env.get("DATABASE_URL") orelse "postgres://ivenna:ivenna@127.0.0.1:5432/ivenna";
        if (database_url.len == 0) return error.MissingDatabaseUrl;
        const memory_ssh_target = env.get("MEMORY_SSH_TARGET") orelse "ivenna-memory";
        if (memory_ssh_target.len == 0) return error.MissingMemorySshTarget;
        const memory_ssh_config = env.get("MEMORY_SSH_CONFIG");
        if (memory_ssh_config) |config| {
            if (config.len == 0) return error.MissingMemorySshConfig;
        }
        const api_key = env.get("LLM_API_KEY") orelse "";
        const model = env.get("LLM_MODEL") orelse Provider.default_model;
        if (api_key.len == 0 or model.len == 0) {
            return error.MissingLlmCredentials;
        }
        return .{
            .database_url = database_url,
            .memory_ssh_target = memory_ssh_target,
            .memory_ssh_config = memory_ssh_config,
            .host = env.get("HOST") orelse "127.0.0.1",
            .port = try std.fmt.parseInt(u16, env.get("PORT") orelse "5882", 10),
            .llm_base_url = env.get("LLM_BASE_URL") orelse Provider.default_base_url,
            .llm_api_key = api_key,
            .llm_model = model,
        };
    }
};

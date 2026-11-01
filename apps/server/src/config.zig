const std = @import("std");

pub const Config = struct {
    database_url: []const u8,
    memory_database_url: []const u8,
    host: []const u8,
    port: u16,
    llm_base_url: []const u8,
    llm_api_key: []const u8,
    llm_model: []const u8,

    /// Values borrow the process environment, which outlives the server.
    pub fn load(env: *const std.process.Environ.Map) !Config {
        const database_url = env.get("DATABASE_URL") orelse "postgres://ivenna:ivenna@localhost:5432/ivenna";
        if (database_url.len == 0) return error.MissingDatabaseUrl;
        const memory_database_url = env.get("MEMORY_DATABASE_URL") orelse "postgres://ivenna_memory:ivenna_memory@localhost:5432/ivenna_memory";
        if (memory_database_url.len == 0) return error.MissingMemoryDatabaseUrl;
        const api_key = env.get("LLM_API_KEY") orelse "";
        const model = env.get("LLM_MODEL") orelse "deepseek-flash";
        if (api_key.len == 0 or model.len == 0) {
            return error.MissingLlmCredentials;
        }
        return .{
            .database_url = database_url,
            .memory_database_url = memory_database_url,
            .host = env.get("HOST") orelse "127.0.0.1",
            .port = try std.fmt.parseInt(u16, env.get("PORT") orelse "5882", 10),
            .llm_base_url = env.get("LLM_BASE_URL") orelse "https://api.deepseek.com",
            .llm_api_key = api_key,
            .llm_model = model,
        };
    }
};

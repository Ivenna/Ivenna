const std = @import("std");
const agent = @import("agent");
const Config = @import("config.zig").Config;
const Api = @import("api.zig").Api;

var stopping: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    const config = Config.load(init.environ_map) catch |err| {
        std.log.err("invalid server configuration: {s}", .{@errorName(err)});
        return err;
    };
    const io = init.io;
    const host_directory = try std.process.currentPathAlloc(io, init.gpa);
    defer init.gpa.free(host_directory);
    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    var store = try agent.Store.init(io, init.gpa, config.database_url);
    defer store.deinit();
    try store.initializeSchema();
    try store.recoverInterrupted();

    var engine: agent.Engine = .{
        .allocator = init.gpa,
        .io = io,
        .store = &store,
        .memory = .{
            .io = io,
            .ssh_target = config.memory_ssh_target,
            .ssh_config = config.memory_ssh_config,
        },
        .host = .init(io, host_directory, init.environ_map),
        .provider = .{
            .client = &client,
            .base_url = config.llm_base_url,
            .api_key = config.llm_api_key,
            .model = config.llm_model,
        },
    };
    var api: Api = .{
        .allocator = init.gpa,
        .io = io,
        .store = &store,
        .engine = &engine,
    };

    const address = try std.Io.net.IpAddress.parse(config.host, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    // Signal handlers only write a lock-free atomic. All cancellation and
    // resource cleanup happens in normal task context after the poll wakes.
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = requestStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous_int: std.posix.Sigaction = undefined;
    var previous_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &previous_int);
    defer std.posix.sigaction(.INT, &previous_int, null);
    std.posix.sigaction(.TERM, &action, &previous_term);
    defer std.posix.sigaction(.TERM, &previous_term, null);

    const Result = union(enum) { server: anyerror!void, shutdown: std.Io.Cancelable!void };
    var result_buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &result_buffer);
    defer select.cancelDiscard();
    try select.concurrent(.server, Api.listen, .{ &api, &listener });
    try select.concurrent(.shutdown, waitForStop, .{io});
    std.log.info("Ivenna listening on http://{s}:{d} (model: {s})", .{
        config.host, config.port, config.llm_model,
    });
    switch (try select.await()) {
        .server => |result| try result,
        .shutdown => |result| {
            try result;
            std.log.info("stopping Ivenna and waiting for active tasks", .{});
        },
    }
}

fn requestStop(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

fn waitForStop(io: std.Io) std.Io.Cancelable!void {
    while (!stopping.load(.acquire)) {
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}

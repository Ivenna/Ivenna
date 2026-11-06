const std = @import("std");
const agent = @import("agent");
const contracts = @import("agent_contracts");
const email = @import("email");
const responses = @import("responses");
const host = @import("host");
const memory = @import("memory");
const Config = @import("config.zig").Config;
const Service = @import("service.zig").Service;

var stopping: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    const config = Config.load(init.environ_map) catch |err| {
        std.log.err("invalid Ivenna configuration: {s}", .{@errorName(err)});
        return err;
    };
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const host_directory = try std.process.currentPathAlloc(io, a);
    const data_directory = try std.fs.path.resolve(a, &.{ host_directory, config.data_dir });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, data_directory, .fromMode(0o700));
    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    var mail: email.Integration = undefined;
    try mail.init(init.gpa, io, &client, .{
        .session_url = config.mail_session_url,
        .authorization = try config.authorization(a),
        .address = config.mail_address,
    }, data_directory);
    defer mail.deinit();
    var memory_client: memory.Memory = .{ .io = io, .ssh_target = config.memory_ssh_target, .ssh_config = config.memory_ssh_config };
    try memory_client.checkAvailable(a);
    var host_tools = host.Host.init(io, host_directory, data_directory, init.environ_map);
    var provider: responses.Provider = .{
        .client = &client,
        .base_url = config.llm_base_url,
        .api_key = config.llm_api_key,
        .model = config.llm_model,
        .max_output_tokens = config.llm_max_output_tokens,
    };
    const tools = [_]contracts.Tools{ try memory_client.tools(a), try host_tools.tools(a) };
    var engine: agent.Engine = .{
        .io = io,
        .model = provider.port(),
        .tools = &tools,
    };
    var kernel = try agent.Kernel.init(init.gpa, io, .{
        .engine = &engine,
        .inbox = mail.inbox(),
        .sender = mail.sender(),
        .handovers = mail.handovers(),
    }, .{
        .limits = config.context_limits,
        .poll_interval_ms = config.mail_poll_interval_ms,
        .max_parallel = config.max_parallel_attention,
        .max_contexts = config.max_attention_contexts,
    });
    defer kernel.deinit();
    var service = try Service.listen(io, config.service_address, &kernel);
    defer service.deinit();

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

    const Result = union(enum) { service: anyerror!void, kernel: anyerror!void, shutdown: std.Io.Cancelable!void };
    var result_buffer: [3]Result = undefined;
    var select = std.Io.Select(Result).init(io, &result_buffer);
    defer {
        kernel.closeReception();
        select.cancelDiscard();
    }
    try select.concurrent(.service, Service.run, .{&service});
    try select.concurrent(.kernel, agent.Kernel.run, .{&kernel});
    try select.concurrent(.shutdown, waitForStop, .{io});
    std.log.info("Ivenna listening on {f} as {s} (model: {s})", .{ service.listener.socket.address, config.mail_address, config.llm_model });
    switch (try select.await()) {
        .service => |result| try result,
        .kernel => |result| try result,
        .shutdown => |result| {
            try result;
            std.log.info("stopping Ivenna and waiting for active work", .{});
        },
    }
}

fn requestStop(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

fn waitForStop(io: std.Io) std.Io.Cancelable!void {
    while (!stopping.load(.acquire)) try io.sleep(.fromMilliseconds(50), .awake);
}

const std = @import("std");
const agent = @import("agent");
const contracts = @import("agent_contracts");
const email = @import("email");
const responses = @import("responses");
const host = @import("host");
const memory = @import("memory");
const resources = @import("resources");
const subscriptions = @import("subscriptions");
const Config = @import("config.zig").Config;
const Service = @import("service.zig").Service;

var stopping: std.atomic.Value(bool) = .init(false);

const usage =
    \\Usage: ivenna [--help]
    \\
    \\Run the Ivenna kernel. The current directory is the default location for
    \\directory listings and the default working directory for host commands.
    \\
    \\The kernel reads DATA_DIR and its service settings from the environment.
    \\See docs/running.md in the source tree for configuration.
    \\
    \\  -h, --help   Show this help and exit.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        const help = std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h");
        if (help and args.len == 2) {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            return 0;
        }
        const unexpected = if (help) args[2] else args[1];
        std.log.err("unexpected argument \"{f}\". See 'ivenna --help'.", .{std.zig.fmtString(unexpected)});
        return 2;
    }

    const config = try Config.load(init.environ_map);
    const io = init.io;
    var service = try Service.listen(io, config.service_address);
    defer service.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const host_directory = try std.process.currentPathAlloc(io, a);
    const data_directory = try std.fs.path.resolve(a, &.{ host_directory, config.data_dir });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, data_directory, .fromMode(0o700));
    var subscription_store = try subscriptions.Store.open(init.gpa, try std.fs.path.join(a, &.{ data_directory, subscriptions.filename }));
    defer subscription_store.close();
    var mail: email.Integration = undefined;
    try mail.init(init.gpa, io, .{
        .session_url = config.mail_session_url,
        .authorization = try config.authorization(a),
        .address = config.mail_address,
    });
    defer mail.deinit();
    var memory_client: memory.Memory = .{ .io = io, .ssh_target = config.memory_ssh_target, .ssh_config = config.memory_ssh_config };
    try memory_client.checkAvailable(a);
    var host_env = try init.environ_map.clone(a);
    defer host_env.deinit();
    try host_env.put("DATA_DIR", data_directory);
    const bin_dir = try std.process.executableDirPathAlloc(io, a);
    const reporter = comptime "ivenna-report" ++ @import("builtin").target.exeFileExt();
    try host_env.put("IVENNA_REPORT", try std.fs.path.join(a, &.{ bin_dir, reporter }));
    var host_tools = host.Host.init(init.gpa, io, host_directory, data_directory, &host_env, mail.callbackPublisher(), config.max_host_commands);
    defer host_tools.deinit();
    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    var provider: responses.Provider = .{
        .client = &client,
        .base_url = config.llm_base_url,
        .api_key = config.llm_api_key,
        .model = config.llm_model,
        .max_output_tokens = config.llm_max_output_tokens,
        .request_timeout_ms = config.llm_request_timeout_ms,
    };
    const fetcher: ?resources.DeepSeek = if (config.deepseek_api_key) |key| .{ .http = &client, .api_key = key } else null;
    var resource_tools: resources.Resources = .{
        .allocator = init.gpa,
        .io = io,
        .directory = host_directory,
        .web = if (fetcher) |*service_client| service_client.reader() else null,
    };
    defer resource_tools.deinit();
    const shared_tools = [_]contracts.Tools{ try memory_client.tools(a), try resource_tools.tools(a) };
    const activity_tools = [_]contracts.Tools{try host_tools.tools(a)};
    var engine: agent.Engine = .{
        .allocator = init.gpa,
        .io = io,
        .model = provider.port(),
        .shared_tools = &shared_tools,
        .activity_tools = &activity_tools,
        .reasoning = config.llm_reasoning,
    };
    const outbound_channels = [_]contracts.Communication.Channel{
        .{ .name = "email", .sender = mail.sender() },
    };
    var kernel = try agent.Kernel.init(init.gpa, io, .{
        .engine = &engine,
        .inbox = mail.inbox(),
        .channels = .{ .channels = &outbound_channels },
        .history = mail.history(),
        .callbacks = mail.callbackPublisher(),
        .subscriptions = &subscription_store,
    }, .{
        .limits = config.context_limits,
        .poll_interval_ms = config.mail_poll_interval_ms,
        .max_sessions = config.max_sessions,
        .max_pending_events = config.max_pending_events,
    });
    defer kernel.deinit();
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

    const Result = union(enum) { service: anyerror!void, kernel: anyerror!void, host: anyerror!void, shutdown: std.Io.Cancelable!void };
    var result_buffer: [4]Result = undefined;
    var select = std.Io.Select(Result).init(io, &result_buffer);
    defer {
        kernel.closeReception();
        select.cancelDiscard();
    }
    try select.concurrent(.service, Service.run, .{ &service, &kernel });
    try select.concurrent(.host, host.Host.run, .{&host_tools});
    try select.concurrent(.kernel, agent.Kernel.run, .{&kernel});
    try select.concurrent(.shutdown, waitForStop, .{io});
    std.log.info("Ivenna listening on {f} as {s} (model: {s})", .{ service.listener.socket.address, config.mail_address, config.llm_model });
    switch (try select.await()) {
        .service => |result| try result,
        .kernel => |result| try result,
        .host => |result| try result,
        .shutdown => |result| {
            try result;
            std.log.info("stopping Ivenna and waiting for active work", .{});
        },
    }
    return 0;
}

fn requestStop(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

fn waitForStop(io: std.Io) std.Io.Cancelable!void {
    while (!stopping.load(.acquire)) try io.sleep(.fromMilliseconds(50), .awake);
}

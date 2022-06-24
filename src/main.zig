pub const io_mode = .evented; // use event loop

const std = @import("std");
const dht = @import("dht");
const args = @import("args");

const index = @import("index.zig");
const hex = index.hex;

pub const log_level: std.log.Level = .info;

pub fn test_file() !void {
    var file = try std.fs.cwd().createFile("test.txt", .{ .read = true });
    _ = try file.writer().write("asdf");
    _ = try file.writer().write("fdsa");
    try file.seekTo(0);
    var buf: [3]u8 = undefined;
    _ = try file.reader().readAll(&buf);
    std.log.info("{s}", .{buf});
    _ = try file.reader().readAll(&buf);
    std.log.info("{s}", .{buf});
}

pub fn main() anyerror!void {
    try dht.init();

    // const options = try args.parseForCurrentProcess(struct {
    //     ip: ?[]const u8 = null,
    //     port: ?u16 = null,
    // }, std.heap.page_allocator, .print);
    // std.log.info("{s}", .{options.options.ip});

    // if (options.options.ip == null or options.options.port == null) {
    //     std.log.warn("Ip not defined", .{});
    //     return;
    // }

    // const block = index.block.Block{
    //     .hash = std.mem.zeroes(dht.Hash),
    // };

    // const server_id = dht.id.rand_id();
    // std.log.info("Server id: {}", .{hex(&server_id)});
    // const address = try std.net.Address.parseIp(options.options.ip.?, options.options.port.?);

    // const server = try dht.UDPServer.init(address, server_id);
    // _ = server;
    // // try server.start();

    // const N = 1024 * 1024 * 1024 / 64 * 3 / 2;
    // // const N = 1024 / 64;

    // std.log.info("A block {}", .{block});

    // var t2 = try std.time.Timer.start();
    // const base_N = 1024;
    // var merge_plotter = try index.plot.MergePlotter.init(std.heap.page_allocator, N, base_N);

    // const n_thread = 14;
    // const persistent_plot = b: {
    //     const plot_a = try merge_plotter.plot_multithread_blocking(n_thread);
    //     defer plot_a.deinit();
    //     std.log.info("Making Persistent a", .{});
    //     const plot = try index.plot.PersistentPlot.initPlot(std.heap.page_allocator, "plot_a.db", plot_a);
    //     // try plot.check_consistency();
    //     break :b plot;
    // };

    // const persistent_plot_b = b: {
    //     const plob_b = try merge_plotter.plot_multithread_blocking(n_thread);
    //     defer plob_b.deinit();
    //     std.log.info("Making Persistent b", .{});
    //     const plot = try index.plot.PersistentPlot.initPlot(std.heap.page_allocator, "plob_b.db", plob_b);
    //     // try plot.check_consistency();
    //     break :b plot;
    // };

    // const persistent_merged = try index.plot.PersistentPlot.initMerged(std.heap.page_allocator, "merged_plot.db", persistent_plot, persistent_plot_b);
    // std.log.info("Merged size: {}", .{persistent_merged.size});

    // std.log.info("two full plots + persisting + persistent merge took: {}s", .{t2.lap() / std.time.ns_per_s});
    // //try persistent_merged.check_consistency();
    // persistent_merged.deinit();

    const persistent_merged_loaded = try index.plot.PersistentPlot.init(std.heap.page_allocator, "merged_plot.db");
    // try persistent_merged_loaded.check_consistency();
    var flower: dht.Hash = undefined;

    dht.rng.random().bytes(&flower);
    std.log.info("{}", .{hex(&flower)});
    std.log.info("merged find: {}", .{persistent_merged_loaded.find(flower)});
    std.log.info("{}", .{persistent_merged_loaded.size});

    std.log.info("Start mining", .{});
    var i: usize = 0;

    const Plant = index.Plant;
    var closest = std.mem.zeroes(Plant);
    var closest_dist = std.mem.zeroes(dht.Hash);
    std.mem.set(u8, &closest_dist, 255);

    while (true) {
        dht.rng.random().bytes(&flower);
        const found = try persistent_merged_loaded.find(flower);

        const dist = Plant.distance(found, closest);

        if (std.mem.order(u8, &dist, &closest_dist) == .lt) {
            closest = found;
            closest_dist = dist;
            std.log.info("\r[{}] persistent search: {} find: {} dist:{}", .{ i, hex(&flower), hex(&found.flower), hex(&closest_dist) });
        }
    }

    // try server.wait();
    // std.log.info("{}", .{merged_plot});
}

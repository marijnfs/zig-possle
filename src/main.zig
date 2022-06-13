pub const io_mode = .evented; // use event loop

const std = @import("std");
const dht = @import("dht");
const args = @import("args");

const index = @import("index.zig");
pub const log_level: std.log.Level = .info;

pub fn main() anyerror!void {
    // var f = try std.fs.cwd().openFile("test.txt", .{});
    var f = try std.fs.cwd().openFile("test.txt", .{ .mode = .read_write });
    std.log.warn("{}", .{try f.getEndPos()});

    // try f.seekTo(128 * 1024 * 1024);
    var bla = try std.heap.page_allocator.alloc(u8, 128 * 1024 * 1024);
    for (bla) |*i| {
        i.* = ' ';
    }
    const written = try f.write(bla);
    std.log.warn("written {}", .{written});

    f.close();
    try dht.init();

    const options = try args.parseForCurrentProcess(struct {
        ip: ?[]const u8 = null,
        port: ?u16 = null,
    }, std.heap.page_allocator, .print);
    std.log.info("{s}", .{options.options.ip});

    if (options.options.ip == null or options.options.port == null) {
        std.log.warn("Ip not defined", .{});
        return;
    }

    const block = index.block.Block{
        .hash = std.mem.zeroes(dht.Hash),
    };

    const server_id = dht.id.rand_id();
    std.log.info("Server id: {}", .{index.hex(&server_id)});
    const address = try std.net.Address.parseIp(options.options.ip.?, options.options.port.?);

    const server = try dht.UDPServer.init(address, server_id);
    try server.start();

    const N = 1 * 1024 * 1024 / 64;
    // const N = 1024 / 64;

    std.log.info("A block {}", .{block});

    var queue = dht.AtomicQueue(*index.plot.Plot).init(std.heap.page_allocator);

    var t2 = try std.time.Timer.start();
    const base_N = 1024;
    var merge_plotter = try index.plot.MergePlotter.init(std.heap.page_allocator, N, base_N);

    const run = struct {
        fn run(q: *dht.AtomicQueue(*index.plot.Plot)) !void {
            while (true) {
                var new_plot = try index.plot.Plot.init(std.heap.page_allocator, base_N);
                try new_plot.seed();
                try q.push(new_plot);
            }
        }
    }.run;

    var runners = std.ArrayList(std.Thread).init(std.heap.page_allocator);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try runners.append(try std.Thread.spawn(.{}, run, .{&queue}));
    }

    while (!merge_plotter.check_done()) {
        // std.log.info("Plotting {} {}", .{ merge_plotter.plot_list.items.len, queue.size() });
        if (queue.pop()) |plot| {
            try merge_plotter.add_plot(plot);
        } else {
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.log.info("{}", .{t2.lap() / std.time.ns_per_ms});

    const merged_plot = merge_plotter.get_plot();
    std.log.info("Making Persistent a", .{});

    const persistent_plot = try index.plot.PersistentPlot.initPlot(std.heap.page_allocator, "plot_a.db", merged_plot);
    std.log.info("Making Persistent b", .{});
    const persistent_plot_b = try index.plot.PersistentPlot.initPlot(std.heap.page_allocator, "plot_b.db", merged_plot);
    std.log.info("Making Persistent merged", .{});

    const persistent_merged = try index.plot.PersistentPlot.initMerged(std.heap.page_allocator, "merged_plot.db", persistent_plot, persistent_plot_b);
    std.log.info("Merged size: {}", .{persistent_merged.size});
    persistent_merged.deinit();

    const persistent_merged_loaded = try index.plot.PersistentPlot.init(std.heap.page_allocator, "merged_plot.db");

    var flower: dht.Hash = undefined;

    dht.rng.random().bytes(&flower);
    try merged_plot.check_integrity();
    std.log.info("{}", .{index.hex(&flower)});
    std.log.info("merged find: {}", .{merged_plot.find(flower)});
    std.log.info("persistent find: {}", .{persistent_merged_loaded.find(flower)});

    std.log.info("{}", .{merged_plot.size});

    try server.wait();
    // std.log.info("{}", .{merged_plot});
}

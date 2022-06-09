const std = @import("std");
const dht = @import("dht");

const index = @import("index.zig");
pub const log_level: std.log.Level = .info;

pub fn main() anyerror!void {
    const block = index.block.Block{
        .hash = std.mem.zeroes(dht.Hash),
    };

    const N = 64 * 1024 * 1024 / 64;
    // const N = 1024 / 64;

    std.log.info("A block {}", .{block});

    // var find_hash: dht.Hash = undefined;

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
    while (i < 10) : (i += 1) {
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

    var flower: dht.Hash = undefined;

    dht.rng.random().bytes(&flower);
    try merged_plot.check_integrity();
    std.log.info("{}", .{index.hex(&flower)});
    std.log.info("{}", .{merged_plot.find(flower)});
    std.log.info("{}", .{merged_plot.plot_size});
    // std.log.info("{}", .{merged_plot});
}

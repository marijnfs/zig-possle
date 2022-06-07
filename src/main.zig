const std = @import("std");
const dht = @import("dht");

const index = @import("index.zig");
pub const log_level: std.log.Level = .info;

pub fn main() anyerror!void {
    const block = index.block.Block{
        .hash = std.mem.zeroes(dht.Hash),
    };

    const N = 8 * 1024 * 1024 / 64;
    // const N = 1024 / 64;

    var t = try std.time.Timer.start();
    var plot = try index.plot.Plot.init(std.heap.page_allocator, N);
    try plot.seed();
    std.log.info("{}", .{t.lap() / std.time.ns_per_ms});
    // var plot2 = try index.plot.Plot.init(std.heap.page_allocator, N);
    // try plot2.seed();

    // var plot_merged = try index.plot.Plot.merge_plots(std.heap.page_allocator, plot, plot2);
    // // for (plotMerged.land.items) |plant| {
    // //     std.log.warn("{}", .{plant});
    // // }

    std.log.info("A block {} {}", .{ block, plot.land.items.len });

    // var find_hash: dht.Hash = undefined;

    var t2 = try std.time.Timer.start();
    const base_N = 1024;
    var merged_miner = try index.plot.MergePlotter.init(std.heap.page_allocator, N, base_N);

    while (!merged_miner.check_done()) {
        std.log.info("Plotting {}", .{merged_miner.plot_list.items.len});
        var new_plot = try index.plot.Plot.init(std.heap.page_allocator, base_N);
        try new_plot.seed();
        try merged_miner.add_plot(new_plot);
    }

    std.log.info("{}", .{t2.lap() / std.time.ns_per_ms});

    // var n: usize = 0;
    // while (true) {
    //     dht.rng.random().bytes(&find_hash);
    //     _ = try plotMerged.find(find_hash);
    //     // std.log.info("Find {} {}", .{ index.hex(&find_hash), plant });
    //     n += 1;
    //     if (n % 1000 == 0) {
    //         std.log.info("{}", .{n});
    //     }
    // }
}

pub const io_mode = .evented; // use event loop

const std = @import("std");
const dht = @import("dht");
const args = @import("args");

const pos = @import("pos");

const hex = pos.hex;

pub const log_level: std.log.Level = .info;

pub fn main() anyerror!void {
    try dht.init();

    // Plotting
    const N = 16 * 1024 * 1024 * 1024 / 64;
    // const N = 1024 / 64;

    var t2 = try std.time.Timer.start();
    const base_N = 1024 * 1024;
    var merge_plotter = try pos.plot.MergePlotter.init(std.heap.page_allocator, N, base_N);

    const n_thread = 14;
    const persistent_plot = b: {
        std.log.info("Starting to plot", .{});
        const plot_a = try merge_plotter.plot_multithread_blocking(n_thread);
        defer plot_a.deinit();
        std.log.info("Making Persistent a", .{});
        const plot = try pos.plot.PersistentPlot.initPlot(std.heap.page_allocator, "plot_a.db", plot_a);
        // try plot.check_consistency();
        break :b plot;
    };

    const persistent_plot_b = b: {
        std.log.info("Starting to plot", .{});
        const plob_b = try merge_plotter.plot_multithread_blocking(n_thread);
        defer plob_b.deinit();
        std.log.info("Making Persistent b", .{});
        const plot = try pos.plot.PersistentPlot.initPlot(std.heap.page_allocator, "plot_b.db", plob_b);
        // try plot.check_consistency();
        break :b plot;
    };

    const persistent_merged = try pos.plot.PersistentPlot.initMerged(std.heap.page_allocator, "merged_plot.db", persistent_plot, persistent_plot_b);
    std.log.info("Merged size: {}", .{persistent_merged.size});

    std.log.info("two full plots + persisting + persistent merge took: {}s", .{t2.lap() / std.time.ns_per_s});
    //try persistent_merged.check_consistency();
    persistent_merged.deinit();
}

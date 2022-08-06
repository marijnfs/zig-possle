pub const io_mode = .evented; // use event loop

const std = @import("std");
const dht = @import("dht");
const args = @import("args");

const pos = @import("pos");
const plot = pos.plot;

const hex = pos.hex;

pub const log_level: std.log.Level = .info;
const allocator = std.heap.page_allocator;

pub fn main() anyerror!void {
    try dht.init();

    // Setup server
    const options = try args.parseForCurrentProcess(struct {
        out: []const u8,
        tmp: []const u8,
        plot_bytesize: usize,
        persistent_base_bytesize: usize,
        // base_bytesize: usize = 1024 * 1024,
        base_bytesize: usize = 1024,

        n_threads: usize = 4,
    }, allocator, .print);

    // Plotting
    const N = options.options.plot_bytesize / 64; //64 bytes per entry

    std.log.info("{} bytes means {} buds need to be calculated", .{ options.options.plot_bytesize, N });

    var t2 = try std.time.Timer.start();
    const base_N = options.options.base_bytesize / 64;
    var merge_plotter = try plot.MergePlotter.init(allocator, options.options.persistent_base_bytesize / 64, base_N);

    const n_threads = options.options.n_threads;

    var plot_list = std.ArrayList(*plot.PersistentPlot).init(allocator);

    var plot_counter: usize = 0;

    while (true) {
        if (plot_list.items.len == 1 and plot_list.items[0].size > N) {
            std.log.info("Done Plotting", .{});
            break;
        }

        const plot_path = try std.fmt.allocPrint(allocator, "{s}/plot_{}", .{ options.options.tmp, plot_counter });
        plot_counter += 1;
        const persistent_plot = b: {
            std.log.info("Starting to plot", .{});
            const plot_a = try merge_plotter.plot_multithread_blocking(n_threads);
            defer plot_a.deinit();
            std.log.info("Making Persistent", .{});
            const persistent_plot = try plot.PersistentPlot.initPlot(allocator, plot_path, plot_a);
            std.log.info("Done", .{});

            // try plot.check_consistency();
            break :b persistent_plot;
        };

        try plot_list.append(persistent_plot);

        if (plot_list.items.len < 2)
            continue;

        std.log.info("Merging", .{});

        while (true) {
            if (plot_list.items.len < 2)
                break;

            const last_plot = plot_list.items[plot_list.items.len - 1];
            const prelast_plot = plot_list.items[plot_list.items.len - 2];

            if (last_plot.size != prelast_plot.size)
                break;

            const merge_plot_path = b: {
                if (plot_list.items.len == 2 and plot_list.items[0].size + plot_list.items[1].size > N) {
                    std.log.info("getting path {s}", .{options.options.out});
                    // const final_path = try std.fs.cwd().realpathAlloc(allocator, options.options.out);
                    // std.log.info("Merging final plot {s}", .{options.options.out});
                    // break :b final_path;
                    break :b options.options.out;
                } else {
                    break :b try std.fmt.allocPrint(allocator, "{s}/plot_{}", .{ options.options.tmp, plot_counter });
                }
            };

            plot_counter += 1;

            std.log.info("Merging {s} {s} to {s}", .{ last_plot.path, prelast_plot.path, merge_plot_path });
            const merged_persistent_plot = try plot.PersistentPlot.initMerged(allocator, merge_plot_path, last_plot, prelast_plot);
            std.log.info("Removing merged plots", .{});

            {
                std.log.info("Deleting  {s} {s}", .{ last_plot.path, prelast_plot.path });

                last_plot.deinit();
                prelast_plot.deinit();

                try last_plot.delete_file();
                try prelast_plot.delete_file();
            }

            try plot_list.resize(plot_list.items.len - 2);
            try plot_list.append(merged_persistent_plot);
        }
    }

    std.log.info("full plots + persisting + persistent merge took: {}s", .{t2.lap() / std.time.ns_per_s});
}

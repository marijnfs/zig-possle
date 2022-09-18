pub const io_mode = .evented; // use event loop

const std = @import("std");
const dht = @import("dht");
const yazap = @import("yazap");

const pos = @import("pos");
const plot = pos.plot;

const hex = pos.hex;
const Command = yazap.Command;
const flag = yazap.flag;

pub const log_level: std.log.Level = .info;
// const allocator = std.heap.page_allocator;
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true, .stack_trace_frames = 12 }){};
const allocator = gpa.allocator();

fn read_size(str: []const u8) !usize {
    if (str.len == 0)
        return 0;
    if (str[str.len - 1] == 'K' or str[str.len - 1] == 'k') {
        return 1024 * try std.fmt.parseInt(usize, str[0 .. str.len - 1], 10);
    }
    if (str[str.len - 1] == 'M' or str[str.len - 1] == 'm') {
        return 1024 * 1024 * try std.fmt.parseInt(usize, str[0 .. str.len - 1], 10);
    }
    if (str[str.len - 1] == 'G' or str[str.len - 1] == 'g') {
        return 1024 * 1024 * 1024 * try std.fmt.parseInt(usize, str[0 .. str.len - 1], 10);
    }
    return try std.fmt.parseInt(usize, str[0 .. str.len - 1], 10);
}

pub fn main() anyerror!void {
    try dht.init();
    defer _ = gpa.deinit();
    // Setup server
    var mine = Command.new(allocator, "mine");
    defer mine.deinit();
    try mine.addArg(flag.argOne("size", null));
    try mine.addArg(flag.argOne("persistent_basesize", null));
    try mine.addArg(flag.argOne("basesize", null));
    try mine.addArg(flag.argOne("out", null));
    try mine.addArg(flag.argOne("n_threads", null));
    try mine.addArg(flag.argOne("tmp", null));

    var mine_args = try mine.parseProcess();
    defer mine_args.deinit();

    // const options = try args.parseForCurrentProcess(struct {
    //     out: []const u8,
    //     tmp: []const u8,
    //     plot_bytesize: usize,
    //     persistent_base_bytesize: usize,
    //     // base_bytesize: usize = 1024 * 1024,
    //     base_bytesize: usize = 1024,

    //     n_threads: usize = 4,
    // }, allocator, .print);

    // Plotting

    var plot_bytesize: usize = 4 << 30;
    if (mine_args.valueOf("size")) |size| {
        plot_bytesize = try read_size(size);
    }
    const N = plot_bytesize / 64;

    std.log.info("{} bytes means {} buds need to be calculated", .{ plot_bytesize, N });

    var t2 = try std.time.Timer.start();

    var persistent_base_bytesize: usize = 1 << 30;
    if (mine_args.valueOf("persistent_basesize")) |basesize| {
        persistent_base_bytesize = try read_size(basesize);
    }
    const persistent_size = persistent_base_bytesize / 64;

    var base_bytesize: usize = 1 << 20;
    if (mine_args.valueOf("basesize")) |basesize| {
        base_bytesize = try read_size(basesize);
    }
    const basesize = base_bytesize / 64;

    var n_threads: usize = 2;

    if (mine_args.valueOf("n_threads")) |threads| {
        n_threads = try std.fmt.parseInt(usize, threads, 10);
    }

    var plot_list = std.ArrayList(*plot.PersistentPlot).init(allocator);

    var plot_counter: usize = 0;

    var tmp: []const u8 = "/tmp";
    if (mine_args.valueOf("tmp")) |tmp_path| {
        tmp = tmp_path;
    }

    var output_path: []const u8 = "plot.data";
    if (mine_args.valueOf("out")) |path| {
        output_path = path;
    }

    while (true) {
        if (plot_list.items.len == 1 and plot_list.items[0].size > N) {
            std.log.info("Done Plotting", .{});
            break;
        }

        const plot_path = try std.fmt.allocPrint(allocator, "{s}/plot_{}", .{ tmp, plot_counter });
        // defer allocator.free(plot_path);

        plot_counter += 1;
        const persistent_plot = b: {
            std.log.info("Starting to plot", .{});
            var merge_plotter = try plot.MergePlotter.init(allocator, persistent_size, basesize);
            defer merge_plotter.deinit();
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

            const merge_plot_path = try std.fmt.allocPrint(allocator, "{s}/plot_{}", .{ tmp, plot_counter });
            // defer allocator.free(merge_plot_path);

            plot_counter += 1;

            std.log.info("Merging {s} {s} to {s}", .{ last_plot.path, prelast_plot.path, merge_plot_path });
            const merged_persistent_plot = try plot.PersistentPlot.initMerged(allocator, merge_plot_path, last_plot, prelast_plot);
            std.log.info("Removing merged plots", .{});

            {
                std.log.info("Deleting  {s} {s}", .{ last_plot.path, prelast_plot.path });

                try last_plot.delete_file();
                try prelast_plot.delete_file();

                last_plot.deinit();
                prelast_plot.deinit();
            }

            try plot_list.resize(plot_list.items.len - 2);
            try plot_list.append(merged_persistent_plot);
        }
    }

    std.log.info("full plots + persisting + persistent merge took: {}s", .{t2.lap() / std.time.ns_per_s});
}

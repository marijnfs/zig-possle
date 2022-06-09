const std = @import("std");
const dht = @import("dht");
const argon2 = std.crypto.pwhash.argon2;
const hex = std.fmt.fmtSliceHexLower;

pub fn binarySearch(
    comptime T: type,
    key: T,
    items: []const T,
    context: anytype,
    comptime compareFn: fn (context: @TypeOf(context), lhs: T, rhs: T) std.math.Order,
) usize {
    var left: usize = 0;
    var right: usize = items.len;

    while (left < right) {
        // Avoid overflowing in the midpoint calculation
        const mid = left + (right - left) / 2;
        // Compare the key with the midpoint element
        switch (compareFn(context, key, items[mid])) {
            .eq => return mid,
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    return left;
}

pub const Plant = struct {
    seed: dht.Hash,
    flower: dht.Hash,

    pub fn format(plant: *const Plant, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Plant[{x}] = {x}", .{ hex(&plant.seed), hex(&plant.flower) });
    }

    pub fn lessThan(_: void, lhs: Plant, rhs: Plant) bool {
        return std.mem.order(u8, &lhs.flower, &rhs.flower) == .lt;
    }

    pub fn order(_: void, lhs: Plant, rhs: Plant) std.math.Order {
        return std.mem.order(u8, &lhs.flower, &rhs.flower);
    }
};

pub const Plot = struct {
    land: std.ArrayList(Plant),
    plot_size: usize = 0,

    pub fn init(alloc: std.mem.Allocator, plot_size: usize) !*Plot {
        var plot = try alloc.create(Plot);
        plot.* = .{
            .land = std.ArrayList(Plant).init(alloc),
            .plot_size = plot_size,
        };
        try plot.land.ensureTotalCapacity(plot.plot_size);

        return plot;
    }

    pub fn deinit(plot: *Plot) void {
        plot.land.deinit();
    }

    pub fn find(plot: *Plot, flower: dht.Hash) !Plant {
        if (plot.land.items.len == 0)
            return error.NoItems;
        const ref = Plant{
            .seed = std.mem.zeroes(dht.Hash),
            .flower = flower,
        };
        const idx = binarySearch(Plant, ref, plot.land.items, {}, Plant.order);

        // wrap arround
        if (idx == plot.land.items.len)
            return plot.land.items[0];
        return plot.land.items[idx];
    }

    pub fn seed(plot: *Plot) !void {
        const salt = [_]u8{0x02} ** 32;

        // var buf = try std.heap.page_allocator.alloc(u8, 1 * 1024 * 1024);
        // defer std.heap.page_allocator.free(buf);
        var buf: [1 * 1024 * 1024]u8 = undefined;
        var alloc = std.heap.FixedBufferAllocator.init(&buf);

        var idx: usize = 0;
        while (idx < plot.plot_size) : (idx += 1) {
            var key: dht.Hash = undefined;
            var hash: dht.Hash = undefined;
            dht.rng.random().bytes(&key);

            try argon2.kdf(
                alloc.allocator(),
                &hash,
                &key,
                &salt,
                .{ .t = 2, .m = 512, .p = 1, .secret = null, .ad = null },
                .argon2d,
            );

            try plot.land.append(.{
                .seed = key,
                .flower = hash,
            });
        }

        std.sort.sort(Plant, plot.land.items, {}, Plant.lessThan);
    }

    pub fn merge_plots(alloc: std.mem.Allocator, l: *Plot, r: *Plot) !*Plot {
        var merged = try Plot.init(alloc, l.plot_size + r.plot_size);
        var il: usize = 0;
        var ir: usize = 0;

        while (il < l.plot_size and ir < r.plot_size) {
            if (Plant.lessThan({}, l.land.items[il], l.land.items[ir])) {
                try merged.land.append(l.land.items[il]);
                il += 1;
            } else {
                try merged.land.append(r.land.items[ir]);
                ir += 1;
            }
        }

        if (il < l.plot_size) {
            for (l.land.items[il..l.land.items.len]) |plant| {
                try merged.land.append(plant);
            }
        }
        if (ir < r.plot_size) {
            for (r.land.items[ir..r.land.items.len]) |plant| {
                try merged.land.append(plant);
            }
        }

        return merged;
    }
};

pub const MergePlotter = struct {
    alloc: std.mem.Allocator,
    plot_list: std.ArrayList(*Plot),
    final_plot_size: usize,
    plot_size: usize,

    pub fn init(alloc: std.mem.Allocator, final_plot_size: usize, plot_size: usize) !*MergePlotter {
        var plotter = try alloc.create(MergePlotter);
        plotter.* = .{
            .alloc = alloc,
            .plot_list = std.ArrayList(*Plot).init(alloc),
            .final_plot_size = final_plot_size,
            .plot_size = plot_size,
        };

        return plotter;
    }

    // Add a plot, and merge into previous plots if fitting
    pub fn add_plot(plotter: *MergePlotter, plot: *Plot) !void {
        try plotter.plot_list.append(plot);
        while (try plotter.merge_last()) {}
    }

    fn merge_last(plotter: *MergePlotter) !bool {
        if (plotter.plot_list.items.len < 2) {
            return false; //nothing to do
        }

        const last_plot = plotter.plot_list.items[plotter.plot_list.items.len - 1];
        const prelast_plot = plotter.plot_list.items[plotter.plot_list.items.len - 2];

        // check if we can merge
        if (last_plot.plot_size != prelast_plot.plot_size)
            return false;

        const merged = try Plot.merge_plots(plotter.alloc, last_plot, prelast_plot);

        // remove last two plots that are now in merged
        last_plot.deinit();
        prelast_plot.deinit();
        try plotter.plot_list.resize(plotter.plot_list.items.len - 2);

        // add merged plot
        try plotter.plot_list.append(merged);
        return true;
    }

    pub fn check_done(plotter: *MergePlotter) bool {
        return plotter.plot_list.items.len == 1 and plotter.plot_list.items[0].land.items.len == plotter.final_plot_size;
    }

    pub fn get_plot(plotter: *MergePlotter) *Plot {
        return plotter.plot_list.items[0];
    }
};

test "TestPlot" {
    const N = 1024 * 1024;
    var plot = Plot.init(std.testing.allocator, N);
    plot.seed();

    for (plot.land.items) |plant| {
        std.log.warn("{}", .{plant});
    }
}

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

    pub fn distance(lhs: Plant, rhs: Plant) dht.Hash {
        var result = lhs.flower;
        for (result) |r, i| {
            result[i] = r ^ rhs.flower[i];
        }
        return result;
    }
};

pub const Plot = struct {
    land: std.ArrayList(Plant),
    size: usize = 0,

    pub fn init(alloc: std.mem.Allocator, size: usize) !*Plot {
        var plot = try alloc.create(Plot);
        plot.* = .{
            .land = std.ArrayList(Plant).init(alloc),
            .size = size,
        };
        try plot.land.ensureTotalCapacity(plot.size);

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

        var rng = std.rand.DefaultPrng.init(dht.rng.random().int(u64));

        var idx: usize = 0;
        while (idx < plot.size) : (idx += 1) {
            var key: dht.Hash = undefined;
            var hash: dht.Hash = undefined;

            rng.random().bytes(&key);

            try argon2.kdf(
                alloc.allocator(),
                &hash,
                &key,
                &salt,
                .{ .t = 1, .m = 128, .p = 1, .secret = null, .ad = null }, // 60 days on ryzen 5950x?
                // .{ .t = 2, .m = 512, .p = 1, .secret = null, .ad = null }, // 600 days on ryzen 5950x
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
        var merged = try Plot.init(alloc, l.size + r.size);
        var il: usize = 0;
        var ir: usize = 0;

        while (il < l.size and ir < r.size) {
            if (Plant.lessThan({}, l.land.items[il], r.land.items[ir])) {
                try merged.land.append(l.land.items[il]);
                il += 1;
            } else {
                try merged.land.append(r.land.items[ir]);
                ir += 1;
            }
        }

        if (il < l.size) {
            for (l.land.items[il..l.size]) |plant| {
                try merged.land.append(plant);
            }
        }
        if (ir < r.size) {
            for (r.land.items[ir..r.size]) |plant| {
                try merged.land.append(plant);
            }
        }

        return merged;
    }

    pub fn check_integrity(plot: *Plot) !void {
        var i: usize = 0;
        while (i + 1 < plot.land.items.len) : (i += 1) {
            // This also dis-allows two consequtive equal items.
            // Technically this is not needed, but it is a sign of something else going wrong
            // We would like each plant to be unique
            if (!Plant.lessThan({}, plot.land.items[i], plot.land.items[i + 1])) {
                std.log.info("failed {}", .{i});
                return error.IntegrityFailed;
            }
        }
    }

    pub fn format(plot: *const Plot, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Plot size: {}", .{plot.size});
        for (plot.land.items) |plant| {
            try writer.print("{}\n", .{plant});
        }
    }
};

pub const PersistentPlot = struct {
    file: std.fs.File,
    size: usize = 0,
    path: []const u8 = "", //Opening path

    const Header = struct {
        size: usize,
    };

    pub fn deinit(plot: *PersistentPlot) void {
        plot.file.close();
    }

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !*PersistentPlot {
        var plot = try alloc.create(PersistentPlot);
        plot.* = .{
            .file = try std.fs.cwd().openFile(path, .{}),
            .size = 0,
            .path = path,
        };

        const header = try plot.read_header();
        plot.size = header.size;
        try plot.reset_head();

        return plot;
    }

    pub fn initPlot(alloc: std.mem.Allocator, path: []const u8, source_plot: *Plot) !*PersistentPlot {
        var plot = try alloc.create(PersistentPlot);
        plot.* = .{
            .file = try std.fs.cwd().createFile(path, .{ .read = true }),
            .size = source_plot.size,
            .path = path,
        };

        var buffered_writer = std.io.bufferedWriter(plot.file.writer());

        try dht.serial.serialise(Header{ .size = plot.size }, buffered_writer.writer());

        for (source_plot.land.items) |plant| {
            try dht.serial.serialise(plant, buffered_writer.writer());
        }

        try buffered_writer.flush();
        return plot;
    }

    pub fn initMerged(alloc: std.mem.Allocator, path: []const u8, source_plot_a: *PersistentPlot, source_plot_b: *PersistentPlot) !*PersistentPlot {
        if (source_plot_a.size == 0 or source_plot_b.size == 0) {
            return error.NoItems;
        }

        var plot = try alloc.create(PersistentPlot);
        plot.* = .{
            .file = try std.fs.cwd().createFile(path, .{ .read = true }),
            .size = source_plot_a.size + source_plot_b.size,
            .path = path,
        };

        var buffered_writer = std.io.bufferedWriter(plot.file.writer());

        var arena_alloc = std.heap.ArenaAllocator.init(alloc);
        defer arena_alloc.deinit();

        try dht.serial.serialise(Header{ .size = plot.size }, buffered_writer.writer());

        const header_a = try source_plot_a.read_header();
        const header_b = try source_plot_b.read_header();

        if (header_a.size != source_plot_a.size or header_b.size != source_plot_b.size) {
            return error.InvalidHeader;
        }

        const read_plant = struct {
            fn read_plant(reader: anytype) !Plant {
                return try dht.serial.deserialise(Plant, reader, null);
            }
        }.read_plant;

        var reader_a = std.io.bufferedReader(source_plot_a.file.reader());
        var reader_b = std.io.bufferedReader(source_plot_b.file.reader());

        var plant_a = try read_plant(reader_a.reader());
        var plant_b = try read_plant(reader_b.reader());

        var i_a: usize = 1; //we already read a plant
        var i_b: usize = 1;

        while (true) {
            if (Plant.lessThan({}, plant_a, plant_b)) {
                try dht.serial.serialise(plant_a, buffered_writer.writer());
                if (i_a >= source_plot_a.size)
                    break;
                plant_a = try read_plant(reader_a.reader());
                i_a += 1;
            } else {
                try dht.serial.serialise(plant_b, buffered_writer.writer());
                if (i_b >= source_plot_b.size)
                    break;
                plant_b = try read_plant(reader_b.reader());
                i_b += 1;
            }
        }

        if (i_b < source_plot_b.size) {
            while (i_b < source_plot_b.size) : (i_b += 1) {
                const plant = try read_plant(reader_b.reader());
                try dht.serial.serialise(plant, buffered_writer.writer());
            }
        } else {
            while (i_a < source_plot_a.size) : (i_a += 1) {
                const plant = try read_plant(reader_a.reader());
                try dht.serial.serialise(plant, buffered_writer.writer());
            }
        }

        try buffered_writer.flush();
        return plot;
    }

    pub fn find(plot: *PersistentPlot, flower: dht.Hash) !Plant {
        if (plot.size == 0) {
            return error.NoPlants;
        }
        var l: usize = 0;
        var r: usize = plot.size - 1;
        const ref = Plant{
            .seed = std.mem.zeroes(dht.Hash),
            .flower = flower,
        };

        while (l != r) {
            const m = l + (r - l) / 2;
            const plant = try plot.get_plant(m);
            if (Plant.lessThan({}, ref, plant)) {
                r = m;
            } else {
                l = m + 1;
            }
        }
        return try plot.get_plant(l);
    }

    pub fn reset_head(plot: *PersistentPlot) !void {
        try plot.file.seekTo(0);
    }

    pub fn read_next_plant(plot: *PersistentPlot) !Plant {
        return try dht.serial.deserialise(Plant, plot.file.reader(), null);
    }

    pub fn get_plant(plot: *PersistentPlot, idx: usize) !Plant {
        try plot.file.seekTo(@sizeOf(Header) + idx * @sizeOf(Plant));
        return try plot.read_next_plant();
    }

    pub fn read_header(plot: *PersistentPlot) !Header {
        try plot.file.seekTo(0);
        return try dht.serial.deserialise(Header, plot.file.reader(), null);
    }

    pub fn at_end(plot: *PersistentPlot) !bool {
        return (try plot.file.getPos()) == (try plot.file.getEndPos());
    }

    pub fn check_consistency(plot: *PersistentPlot) !void {
        var plant_ref = try plot.get_plant(0);
        var i: usize = 1;
        while (i + 1 < plot.size) : (i += 1) {
            const plant_next = try plot.read_next_plant();
            if (Plant.lessThan({}, plant_next, plant_ref)) {
                return error.InconsistentPersistentPlot;
            }
            plant_ref = plant_next;
        }
    }
};

pub const MergePlotter = struct {
    alloc: std.mem.Allocator,
    plot_list: std.ArrayList(*Plot),
    final_size: usize,
    block_size: usize,

    pub fn init(alloc: std.mem.Allocator, final_size: usize, block_size: usize) !*MergePlotter {
        var plotter = try alloc.create(MergePlotter);
        plotter.* = .{
            .alloc = alloc,
            .plot_list = std.ArrayList(*Plot).init(alloc),
            .final_size = final_size,
            .block_size = block_size,
        };

        return plotter;
    }

    pub fn plot_multithread_blocking(plotter: *MergePlotter, n_threads: usize) !*Plot {
        var counter = std.atomic.Atomic(usize).init(0);

        const run = struct {
            fn run(q: *dht.AtomicQueue(*Plot), block_size: usize, c: *std.atomic.Atomic(usize)) !void {
                while (c.load(.SeqCst) == 0) {
                    var new_plot = try Plot.init(std.heap.page_allocator, block_size);
                    try new_plot.seed();
                    try q.push(new_plot);
                }
            }
        }.run;

        var queue = dht.AtomicQueue(*Plot).init(std.heap.page_allocator);
        defer queue.deinit();

        var runners = std.ArrayList(std.Thread).init(std.heap.page_allocator);
        defer runners.deinit();
        var i: usize = 0;
        while (i < n_threads) : (i += 1) {
            try runners.append(try std.Thread.spawn(.{}, run, .{ &queue, plotter.block_size, &counter }));
        }

        while (!plotter.check_done()) {
            // std.log.info("Plotting {} {}", .{ merge_plotter.plot_list.items.len, queue.size() });
            if (queue.pop()) |plot| {
                try plotter.add_plot(plot);
            } else {
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
        _ = counter.fetchAdd(1, .Monotonic);
        for (runners.items) |*thread| {
            thread.join();
        }
        return plotter.extract_plot();
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
        if (last_plot.size != prelast_plot.size)
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
        return plotter.plot_list.items.len == 1 and plotter.plot_list.items[0].land.items.len == plotter.final_size;
    }

    pub fn extract_plot(plotter: *MergePlotter) *Plot {
        return plotter.plot_list.pop();
    }
};

test "TestPlot" {
    const N = 1024 * 1024;
    var plot = Plot.init(std.testing.allocator, N);
    plot.seed();

    for (plot.land.items) |plant| {
        std.log.debug("{}", .{plant});
    }
}

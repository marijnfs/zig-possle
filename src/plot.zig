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

        var arena_alloc = std.heap.ArenaAllocator.init(alloc);
        defer arena_alloc.deinit();

        const header_buffer = try dht.serial.serialise_alloc(Header{ .size = plot.size }, arena_alloc.allocator());
        defer arena_alloc.allocator().free(header_buffer);

        var buffered_writer = std.io.bufferedWriter(plot.file.writer());

        _ = try buffered_writer.write(header_buffer);
        for (source_plot.land.items) |plant| {
            const plant_buf = try dht.serial.serialise_alloc(plant, arena_alloc.allocator());
            defer arena_alloc.allocator().free(plant_buf);
            _ = try buffered_writer.write(plant_buf);
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

        {
            const header_buf = try dht.serial.serialise_alloc(Header{ .size = plot.size }, arena_alloc.allocator());
            defer arena_alloc.allocator().free(header_buf);
            _ = try buffered_writer.write(header_buf);
        }

        try source_plot_a.reset_head();
        try source_plot_b.reset_head();

        const header_a = try source_plot_a.read_header();
        const header_b = try source_plot_b.read_header();

        if (header_a.size != source_plot_a.size or header_b.size != source_plot_b.size) {
            return error.InvalidHeader;
        }

        var plant_a = try source_plot_a.read_next_plant();
        var plant_b = try source_plot_b.read_next_plant();

        while (true) {
            if (Plant.lessThan({}, plant_a, plant_b)) {
                const buffer = try dht.serial.serialise_alloc(plant_a, arena_alloc.allocator());
                defer arena_alloc.allocator().free(buffer);

                _ = try buffered_writer.write(buffer);
                if (try source_plot_a.at_end())
                    break;
                plant_a = try source_plot_a.read_next_plant();
            } else {
                const buffer = try dht.serial.serialise_alloc(plant_b, arena_alloc.allocator());
                defer arena_alloc.allocator().free(buffer);

                _ = try buffered_writer.write(buffer);
                if (try source_plot_b.at_end())
                    break;
                plant_b = try source_plot_b.read_next_plant();
            }
        }

        if (try source_plot_a.at_end()) {
            while (!try source_plot_b.at_end()) {
                const plant = try source_plot_b.read_next_plant();
                const buffer = try dht.serial.serialise_alloc(plant, arena_alloc.allocator());
                defer arena_alloc.allocator().free(buffer);

                _ = try buffered_writer.write(buffer);
            }
        } else {
            while (!try source_plot_a.at_end()) {
                const plant = try source_plot_a.read_next_plant();
                const buffer = try dht.serial.serialise_alloc(plant, arena_alloc.allocator());
                defer arena_alloc.allocator().free(buffer);
                _ = try buffered_writer.write(buffer);
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
            const plant = try plot.read_plant(m);
            if (Plant.lessThan({}, ref, plant)) {
                r = m;
            } else {
                l = m + 1;
            }
        }
        return try plot.read_plant(l);
    }

    pub fn reset_head(plot: *PersistentPlot) !void {
        try plot.file.seekTo(0);
    }

    pub fn read_next_plant(plot: *PersistentPlot) !Plant {
        var buf: [@sizeOf(Plant)]u8 = undefined;
        var buf_ptr: []u8 = &buf;
        _ = try plot.file.read(&buf);
        return try dht.serial.deserialise(Plant, &buf_ptr);
    }

    pub fn read_plant(plot: *PersistentPlot, idx: usize) !Plant {
        try plot.file.seekTo(@sizeOf(Header) + idx * @sizeOf(Plant));
        return try plot.read_next_plant();
    }

    pub fn read_header(plot: *PersistentPlot) !Header {
        var buf: [@sizeOf(Header)]u8 = undefined;
        var buf_ptr: []u8 = &buf;
        _ = try plot.file.read(&buf);
        return try dht.serial.deserialise(Header, &buf_ptr);
    }

    pub fn at_end(plot: *PersistentPlot) !bool {
        return (try plot.file.getPos()) == (try plot.file.getEndPos());
    }

    pub fn check_consistency(plot: *PersistentPlot) !void {
        var plant_ref = try plot.read_plant(0);
        var i: usize = 1;
        while (i < plot.size) : (i += 1) {
            const plant_next = try plot.read_next_plant();
            if (Plant.lessThan({}, plant_next, plant_ref)) {
                std.log.warn("{} {} {} {}", .{ i, plot.size, plant_ref, plant_next });
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

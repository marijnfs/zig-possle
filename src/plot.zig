const std = @import("std");
const dht = @import("dht");
const pos = @import("index.zig");

const allocator = pos.allocator;
const argon2 = std.crypto.pwhash.argon2;
const hex = std.fmt.fmtSliceHexLower;
const ID = dht.ID;
const id_ = dht.id;

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

pub fn hash_fast(data: []const u8) dht.Hash {
    var result: dht.Hash = undefined;
    std.crypto.hash.Blake3.hash(data, result[0..], .{});
    return result;
}

pub fn hash_fast_mul(data_list: [][]const u8) dht.Hash {
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (data_list) |data| {
        hasher.update(data);
    }
    var result: dht.Hash = undefined;
    hasher.final(result[0..]);
    return result;
}

pub fn hash_slow(key: []const u8) !dht.Hash {
    var hash: dht.Hash = undefined;

    const salt = [_]u8{0x02} ** 32;
    var buf: [1 * 1024 * 1024]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&buf);

    try argon2.kdf(
        alloc.allocator(),
        &hash,
        key,
        &salt,
        .{ .t = 1, .m = 1, .p = 1, .secret = null, .ad = null }, // 60 days on ryzen 5950x?
        // .{ .t = 1, .m = 128, .p = 1, .secret = null, .ad = null }, // 60 days on ryzen 5950x?
        // .{ .t = 2, .m = 512, .p = 1, .secret = null, .ad = null }, // 600 days on ryzen 5950x
        .argon2d,
    );
    return hash;
}
pub const Plant = struct {
    seed: dht.Hash = std.mem.zeroes(dht.Hash),
    bud: dht.Hash,

    pub fn format(plant: *const Plant, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Plant[{x}] = {x}", .{ hex(&plant.seed), hex(&plant.bud) });
    }

    pub fn lessThan(_: void, lhs: Plant, rhs: Plant) bool {
        return std.mem.order(u8, &lhs.bud, &rhs.bud) == .lt;
    }

    pub fn order(_: void, lhs: Plant, rhs: Plant) std.math.Order {
        return std.mem.order(u8, &lhs.bud, &rhs.bud);
    }

    pub fn distance(lhs: Plant, rhs: Plant) dht.Hash {
        return id_.xor(lhs.bud, rhs.bud);
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
        const alloc = plot.land.allocator; //abuse the managed ArrayList to get allocator
        plot.land.deinit();
        alloc.destroy(plot);
    }

    pub fn find(plot: *Plot, bud: dht.Hash) !Plant {
        if (plot.land.items.len == 0)
            return error.NoItems;
        const ref = Plant{
            .seed = std.mem.zeroes(dht.Hash),
            .bud = bud,
        };
        const idx = binarySearch(Plant, ref, plot.land.items, {}, Plant.order);

        // wrap arround
        if (idx == plot.land.items.len)
            return plot.land.items[0];
        return plot.land.items[idx];
    }

    pub fn get_plant(plot: *Plot, idx: usize) Plant {
        return plot.land.items[idx];
    }
    pub fn seed(plot: *Plot) !void {
        // var buf = try allocator.alloc(u8, 1 * 1024 * 1024);
        // defer allocator.free(buf);

        var rng = std.rand.DefaultPrng.init(dht.rng.random().int(u64));

        var idx: usize = 0;
        while (idx < plot.size) : (idx += 1) {
            var key: dht.Hash = undefined;
            rng.random().bytes(&key);

            const hash = try hash_slow(&key);

            try plot.land.append(.{
                .seed = key,
                .bud = hash,
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
    alloc: std.mem.Allocator,

    const Header = struct {
        size: usize,
    };

    pub fn deinit(plot: *PersistentPlot) void {
        plot.file.close();
        plot.alloc.destroy(plot);
    }

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !*PersistentPlot {
        var plot = try alloc.create(PersistentPlot);
        plot.* = .{
            .file = try std.fs.cwd().openFile(path, .{}),
            .size = 0,
            .path = path,
            .alloc = alloc,
        };

        const header = try plot.read_header();
        plot.size = header.size;
        try plot.reset_head();

        return plot;
    }

    pub fn initPlot(alloc: std.mem.Allocator, path: []const u8, source_plot: *Plot) !*PersistentPlot {
        var plot = try alloc.create(PersistentPlot);
        std.log.info("Opening {s}", .{path});
        plot.* = .{
            .file = try std.fs.cwd().createFile(path, .{ .read = true }),
            .size = source_plot.size,
            .path = path,
            .alloc = alloc,
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
            .alloc = alloc,
        };

        var buffered_writer = std.io.bufferedWriter(plot.file.writer());

        try dht.serial.serialise(Header{ .size = plot.size }, buffered_writer.writer());

        const header_a = try source_plot_a.read_header();
        const header_b = try source_plot_b.read_header();

        if (header_a.size != source_plot_a.size or header_b.size != source_plot_b.size) {
            return error.InvalidHeader;
        }

        const read_plant = struct {
            fn f(reader: anytype) !Plant {
                return try dht.serial.deserialise(Plant, reader, null);
            }
        }.f;

        var reader_a = std.io.bufferedReader(source_plot_a.file.reader());
        var reader_b = std.io.bufferedReader(source_plot_b.file.reader());

        var plant_a = try read_plant(reader_a.reader());
        var plant_b = try read_plant(reader_b.reader());

        var i_a: usize = 0; //we already read a plant
        var i_b: usize = 0;

        while (true) {
            if (Plant.lessThan({}, plant_a, plant_b)) {
                try dht.serial.serialise(plant_a, buffered_writer.writer());
                i_a += 1;
                if (i_a >= source_plot_a.size) {
                    try dht.serial.serialise(plant_b, buffered_writer.writer());
                    i_b += 1;
                    break;
                }
                plant_a = try read_plant(reader_a.reader());
            } else {
                try dht.serial.serialise(plant_b, buffered_writer.writer());
                i_b += 1;
                if (i_b >= source_plot_b.size) {
                    try dht.serial.serialise(plant_a, buffered_writer.writer());
                    i_a += 1;
                    break;
                }
                plant_b = try read_plant(reader_b.reader());
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

    pub fn find(plot: *PersistentPlot, bud: dht.Hash) !Plant {
        if (plot.size == 0) {
            return error.NoPlants;
        }
        var l: usize = 0;
        var r: usize = plot.size - 1;
        // return plot.find_lr(bud, l, r);
        return plot.find_lr_rec(bud, l, r);
    }

    pub fn find_lr(plot: *PersistentPlot, bud: dht.Hash, l_: usize, r_: usize) !Plant {
        var l = l_;
        var r = r_;
        const ref = Plant{
            .seed = std.mem.zeroes(dht.Hash),
            .bud = bud,
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

    pub fn find_lr_rec(plot: *PersistentPlot, bud: dht.Hash, l_: usize, r_: usize) !Plant {
        var l = l_;
        var r = r_;

        var bit: usize = 0;

        while (l != r) {
            // std.log.info("l:{} r:{}", .{ l, r });
            // what is our search bit on position 'bit'?
            const byte: usize = bit / 8;
            const bit_index: u3 = @intCast(u3, 7 - bit % 8); //bit index is reversed, 0 bit will be at 7'th pos in a byte (little endian)
            const mask: u8 = @intCast(u8, 1) << bit_index;
            const search_bit = bud[byte] & mask > 0;

            // find the first bit that is true in our search range
            const first_true_bit = try plot.find_lr_bit(l, r, bit);
            // std.log.info("bit:{} first:{}", .{ bit, first_true_bit });
            //if they are all true or all false, we continue to the next bit
            const all_true_or_false = first_true_bit == l or first_true_bit == r;

            //if we look for true, first_true_bit is our new l
            if (!all_true_or_false and search_bit) {
                l = first_true_bit;
            } else {
                r = first_true_bit;
            }

            bit += 1;
        }

        // std.log.info("found {}", .{l});
        return try plot.get_plant(l);
    }

    pub fn find_lr_bit(plot: *PersistentPlot, l_: usize, r_: usize, bit: usize) !usize {
        var byte: usize = bit / 8;
        var bit_index: u3 = @intCast(u3, 7 - bit % 8); //bit index is reversed, 0 bit will be at 7'th pos in a byte (little endian)

        var l = l_;
        var r = r_;

        while (l != r) {
            const m = l + (r - l) / 2;
            const plant = try plot.get_plant(m);
            const mask: u8 = @intCast(u8, 1) << bit_index;
            const bit_on = plant.bud[byte] & mask > 0;

            if (bit_on) {
                r = m;
            } else {
                l = m + 1;
            }
        }

        return l;
    }

    pub fn to_memory(plot: *PersistentPlot, alloc: std.mem.Allocator) !*Plot {
        var memory_plot = try Plot.init(alloc, plot.size);
        try plot.reset_to_plants();
        var i: usize = 0;
        while (i < plot.size) : (i += 1) {
            memory_plot.land.items[i] = try plot.read_next_plant();
        }
        return memory_plot;
    }

    pub fn delete_file(plot: *PersistentPlot) !void {
        try std.fs.cwd().deleteFile(plot.path);
    }

    pub fn reset_head(plot: *PersistentPlot) !void {
        try plot.file.seekTo(0);
    }

    pub fn reset_to_plants(plot: *PersistentPlot) !void {
        try plot.file.seekTo(@sizeOf(Header));
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

    pub fn reopen(plot: *PersistentPlot) !void {
        plot.file.close();
        plot.file = try std.fs.cwd().openFile(plot.path, .{});
    }
};

// Indexed plot
// Create Trie
pub const IndexedPersistentPlot = struct {
    persistent: *PersistentPlot,
    trie: std.ArrayList(Node), //trie data structure

    const Node = struct {
        l: i32 = 0, //negative if node index, positive if plot index
        r: i32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator, persistent: *PersistentPlot) !*IndexedPersistentPlot {
        if (persistent.size == 0)
            return error.NoItems;
        var plot = try alloc.create(IndexedPersistentPlot);
        plot.* = .{
            .persistent = persistent,
            .trie = std.ArrayList(Node).init(alloc),
        };

        try plot.setup_table(alloc);

        return plot;
    }

    pub fn find(plot: *IndexedPersistentPlot, bud: dht.Hash) !Plant {
        const index = try plot.find_index(bud);
        return try plot.persistent.get_plant(index);
    }

    pub fn find_index(plot: *IndexedPersistentPlot, bud: dht.Hash) !usize {
        var bit: usize = 0;
        var node_idx: i32 = 0;

        while (true) {
            if (node_idx < 0) { //A plot index
                return @intCast(usize, -node_idx);
            }
            const byte: usize = bit / 8;
            const bit_index: u3 = @intCast(u3, 7 - bit % 8); //bit index is reversed, 0 bit will be at 7'th pos in a byte (little endian)
            const mask: u8 = @intCast(u8, 1) << bit_index;
            const search_bit = bud[byte] & mask > 0;

            const node = plot.trie.items[@intCast(usize, node_idx)];

            if (node.l == 0 and node.r == 0) {
                return error.CorruptedNode;
            }

            if (node.l == 0) {
                node_idx = node.r;
            } else if (node.r == 0) {
                node_idx = node.l;
            } else if (search_bit) {
                node_idx = node.r;
            } else {
                node_idx = node.l;
            }

            bit += 1;
        }
    }

    pub fn setup_table(plot: *IndexedPersistentPlot, alloc: std.mem.Allocator) !void {
        std.log.info("Building table", .{});

        var progress = std.Progress{};
        const root_node = progress.start("Building Index", plot.persistent.size);
        defer root_node.end();

        const IndexNode = struct {
            bit: usize,
            l: usize,
            r: usize,
            parent_ref: struct { //Optional didn't work here
                idx: usize,
                right: bool,
            },
        };

        // reserve space for trie
        // this also ensures reference points don't move which are used during the build of the trie
        try plot.trie.ensureTotalCapacity(plot.persistent.size);

        std.log.info("Done building table", .{});

        // Setup stack
        var stack = std.ArrayList(IndexNode).init(alloc);
        defer stack.deinit();
        try stack.append(.{ .bit = 0, .l = 0, .r = plot.persistent.size, .parent_ref = .{ .idx = 0, .right = false } }); //for now parent_ref optional doesn't work so for the first node we use idx=0; should be fine it will get overwritten anyway after that

        while (stack.popOrNull()) |*index_node| {
            const l = index_node.l;
            const r = index_node.r;
            const bit = index_node.bit;
            const parent_ref = index_node.parent_ref;

            const idx = try plot.persistent.find_lr_bit(l, r, bit);

            root_node.completeOne();
            // if (idx % 10000 == 0)
            //     std.log.info("stack: {}", .{index_node});

            const new_node = Node{};
            try plot.trie.append(new_node);
            const node_idx = plot.trie.items.len - 1;
            var node = &plot.trie.items[node_idx]; //wish there was a last() function

            // It is a stack, so the last pushed gets popped first
            // We deal with the right case first, since we want to push the left last
            // This way we build the stack from low to high

            if (idx == r) {
                node.r = 0; //right now we use index 0 to indicate null. The very first node is 0 and is loaded first in any case and never pointed to, so we don't need this index anyway
            } else if (idx + 1 == r) {
                node.r = -@intCast(i32, idx); // add a leaf
            } else {
                try stack.append(.{ .bit = bit + 1, .l = idx, .r = r, .parent_ref = .{ .idx = node_idx, .right = true } });
            }

            if (l == idx) {
                node.l = 0; //right now we use index 0 to indicate null. The very first node is 0 and is loaded first in any case and never pointed to, so we don't need this index anyway
            } else if (l + 1 == idx) {
                node.l = -@intCast(i32, l); // add a leaf
            } else {
                try stack.append(.{ .bit = bit + 1, .l = l, .r = idx, .parent_ref = .{ .idx = node_idx, .right = false } });
            }
            // const ref = parent_ref;
            // if (index_node.parent_ref) |ref| {
            if (parent_ref.right) {
                plot.trie.items[parent_ref.idx].r = @intCast(i32, node_idx);
            } else {
                plot.trie.items[parent_ref.idx].l = @intCast(i32, node_idx);
            }
            // }
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

    pub fn deinit(plotter: *MergePlotter) void {
        for (plotter.plot_list.items) |plot| {
            plot.deinit();
        }

        const alloc = plotter.plot_list.allocator;
        plotter.plot_list.deinit();
        alloc.destroy(plotter);
    }

    pub fn plot_multithread_blocking(plotter: *MergePlotter, n_threads: usize) !*Plot {
        var counter = std.atomic.Atomic(usize).init(0);

        const run = struct {
            fn run(q: *dht.AtomicQueue(*Plot), block_size: usize, c: *std.atomic.Atomic(usize)) !void {
                while (c.load(.SeqCst) == 0) {
                    var new_plot = try Plot.init(allocator, block_size);
                    try new_plot.seed();
                    try q.push(new_plot);
                }
            }
        }.run;

        var queue = dht.AtomicQueue(*Plot).init(allocator);
        defer queue.deinit();

        var runners = std.ArrayList(std.Thread).init(allocator);
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

        // clear up the queue
        while (queue.pop()) |plot| {
            plot.deinit();
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
        return plotter.plot_list.items.len >= 1 and plotter.plot_list.items[plotter.plot_list.items.len - 1].size >= plotter.final_size;
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

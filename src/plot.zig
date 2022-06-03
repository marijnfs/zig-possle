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
        std.log.info("idx: {}", .{idx});
        return plot.land.items[idx];
    }

    pub fn seed(plot: *Plot) !void {
        plot.land.clearAndFree();
        try plot.land.ensureTotalCapacity(plot.plot_size);

        const salt = [_]u8{0x02} ** 16;

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
                .{ .t = 1, .m = 512, .p = 1, .secret = null, .ad = null },
                .argon2d,
            );

            try plot.land.append(.{
                .seed = key,
                .flower = hash,
            });
        }

        std.sort.sort(Plant, plot.land.items, {}, Plant.lessThan);
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

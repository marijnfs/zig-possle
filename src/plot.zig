const std = @import("std");
const dht = @import("dht");
const argon2 = std.crypto.pwhash.argon2;
const hex = std.fmt.fmtSliceHexLower;

pub const Plant = struct {
    key: dht.Hash,
    hash: dht.Hash,

    pub fn format(plant: *const Plant, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Plant[{x}] = {x}", .{ hex(&plant.key), hex(&plant.hash) });
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

    pub fn seed(plot: *Plot) !void {
        plot.land.clearAndFree();
        try plot.land.ensureTotalCapacity(plot.plot_size);

        const salt = [_]u8{0x02} ** 16;

        var buf: [1024 * 1024]u8 = undefined;
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
                .{ .t = 1, .m = 128, .p = 1, .secret = null, .ad = null },
                .argon2d,
            );

            try plot.land.append(.{
                .key = key,
                .hash = hash,
            });
        }

        const lessThan = struct {
            fn lessThan(_: void, lhs: Plant, rhs: Plant) bool {
                return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
            }
        }.lessThan;

        std.sort.sort(Plant, plot.land.items, {}, lessThan);
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

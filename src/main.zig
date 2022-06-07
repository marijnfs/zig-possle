const std = @import("std");
const dht = @import("dht");

const index = @import("index.zig");
pub const log_level: std.log.Level = .info;

pub fn main() anyerror!void {
    const block = index.block.Block{
        .hash = std.mem.zeroes(dht.Hash),
    };

    const N = 128 * 1024 * 1024 / 64;
    // const N = 1024 / 64;

    var plot = try index.plot.Plot.init(std.heap.page_allocator, N);
    try plot.seed();

    var plot2 = try index.plot.Plot.init(std.heap.page_allocator, N);
    try plot2.seed();

    var plotMerged = try index.plot.Plot.mergePlots(std.heap.page_allocator, plot, plot2);
    // for (plotMerged.land.items) |plant| {
    //     std.log.warn("{}", .{plant});
    // }

    std.log.info("A block {}", .{block});

    var find_hash: dht.Hash = undefined;

    var n: usize = 0;
    while (true) {
        dht.rng.random().bytes(&find_hash);
        _ = try plotMerged.find(find_hash);
        // std.log.info("Find {} {}", .{ index.hex(&find_hash), plant });
        n += 1;
        if (n % 1000 == 0) {
            std.log.info("{}", .{n});
        }
    }
}

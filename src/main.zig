const std = @import("std");
const dht = @import("dht");

const index = @import("index.zig");

pub fn main() anyerror!void {
    const block = index.block.Block{
        .hash = std.mem.zeroes(dht.Hash),
    };

    const N = 100;
    var plot = try index.plot.Plot.init(std.heap.page_allocator, N);
    try plot.seed();

    for (plot.land.items) |plant| {
        std.log.warn("{}", .{plant});
    }

    std.log.info("A block {}", .{block});
}

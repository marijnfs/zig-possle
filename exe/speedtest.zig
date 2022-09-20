const std = @import("std");

const dht = @import("dht");
const miner = @import("miner.zig");
const pos = @import("pos");
const hex = pos.hex;
const id_ = dht.id;

const ID = dht.ID;
const Hash = dht.Hash;
const Block = miner.Block;

const allocator = std.heap.page_allocator;
pub const log_level: std.log.Level = .info;

fn test_ssd_retrieval() !void {
    std.log.info("Loading", .{});

    const plot_path = "main-128.db";
    const persistent_plot = try pos.plot.PersistentPlot.init(allocator, plot_path);
    const t = std.time.milliTimestamp();
    std.log.info("To Mem", .{});

    var i: usize = 0;
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n found: {} {}", .{ i, std.time.milliTimestamp() - t });
        }

        const idx = dht.rng.random().uintLessThanBiased(usize, persistent_plot.size);
        try persistent_plot.file.seekTo(idx * @sizeOf(pos.Plant));

        var buf: [@sizeOf(pos.Plant)]u8 = undefined;
        const r = try persistent_plot.file.reader().readAll(&buf);
        if (r < @sizeOf(pos.Plant))
            return error.Fail;
        // _ = try persistent_plot.get_plant(idx);
        i += 1;
    }
}

fn test_mem_retrieval() !void {
    std.log.info("Loading", .{});

    const plot_path = "main-32.db";
    const persistent_plot = try pos.plot.PersistentPlot.init(allocator, plot_path);

    std.log.info("To Mem", .{});
    const plot = try persistent_plot.to_memory(allocator);
    var i: usize = 0;
    const t = std.time.milliTimestamp();

    std.log.info("Starting", .{});
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n found: {} {}", .{ i, std.time.milliTimestamp() - t });
        }
        const idx = dht.rng.random().uintLessThanBiased(usize, plot.size);
        _ = plot.get_plant(idx);
        i += 1;
    }
}

fn test_index_retrieval() !void {
    // const plot_path = "main.db";
    const plot_path = "main-128.db";
    const index_path = "index-128";

    const persistent_plot = try pos.plot.PersistentPlot.init(allocator, plot_path);
    const indexed_plot = try pos.plot.IndexedPersistentPlot.init_with_index(allocator, persistent_plot, index_path);

    const t = std.time.milliTimestamp();

    var i: usize = 0;
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n found: {} {}", .{ i, std.time.milliTimestamp() - t });
        }

        var prehash: ID = undefined;
        dht.rng.random().bytes(&prehash);

        // Get prehash
        _ = try indexed_plot.find_index(prehash);

        // try persistent_plot.file.seekTo(idx * @sizeOf(pos.Plant));

        // var buf: [@sizeOf(pos.Plant)]u8 = undefined;
        // const r = try persistent_plot.file.reader().readAll(&buf);
        // if (r < @sizeOf(pos.Plant))
        //     return error.Fail;

        i += 1;
    }
}

fn test_block_creation() !void {
    var chain_head = Block{};
    var tx: ID = dht.id.zeroes();

    var i: usize = 0;

    const t = std.time.milliTimestamp();
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n created: {} in {}ms", .{ i, std.time.milliTimestamp() - t });
        }
        var mining_block = Block{};
        var nonce: ID = undefined;
        dht.rng.random().bytes(&nonce);
        try mining_block.setup_mining_block(chain_head, tx, nonce);
        _ = mining_block.prehash; //created
        i += 1;
    }
}

pub fn main() !void {
    // std.log.info("Speed test", .{});
    try test_ssd_retrieval();
    // try test_mem_retrieval();
    // try test_index_retrieval();
    // try test_block_creation();
    // return error.UnImplemented;
}

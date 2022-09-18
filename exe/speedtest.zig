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

fn test_ssd_retrieval() !void {
    const plot_path = "main.db";
    const persistent_merged_loaded = try pos.plot.PersistentPlot.init(allocator, plot_path);

    var i: usize = 0;
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n found: {}", .{i});
        }

        const idx = dht.rng.random.intRangeLessThan(usize, persistent_merged_loaded.size);
        _ = persistent_merged_loaded.get_plant(idx);
    }
}

fn test_mem_retrieval() !void {
    // const plot_path = "main.db";
    // const persistent_merged_loaded = try pos.plot.PersistentPlot.init(allocator, plot_path);

    var i: usize = 0;
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n found: {}", .{i});
        }
    }
}

fn test_index_retrieval() !void {
    const plot_path = "main.db";
    const persistent_merged_loaded = try pos.plot.PersistentPlot.init(allocator, plot_path);
    const indexed_plot = try pos.plot.IndexedPersistentPlot.init(allocator, persistent_merged_loaded);

    var i: usize = 0;
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n found: {}", .{i});
        }

        var prehash: ID = undefined;
        dht.rng.random().bytes(&prehash);

        // Get prehash
        _ = try indexed_plot.find_index(prehash);
        i += 1;
    }
}

fn test_block_creation() !void {
    var chain_head = Block{};
    var tx: ID = dht.id.zeroes();

    var i: usize = 0;
    while (true) {
        if (i % 100000 == 0) {
            std.log.info("n created: {}", .{i});
        }
        var mining_block = Block{};
        var nonce: ID = undefined;
        dht.rng.random().bytes(&nonce);
        try mining_block.setup_mining_block(chain_head, tx, nonce);
        _ = mining_block.prehash; //created
    }
}

pub fn main() !void {
    return error.UnImplemented;
}

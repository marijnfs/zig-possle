const dht = @import("dht");

pub const Block = struct {
    proof: dht.Hash = undefined,
    hash: dht.Hash = undefined,

    data_hash: dht.Hash = undefined,
    prev_block: dht.hash = undefined,
};

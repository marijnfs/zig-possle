pub const io_mode = .evented; // use event loop

const std = @import("std");
const dht = @import("dht");
const args = @import("args");
const net = std.net;
const time = std.time;
const pos = @import("pos");
const hex = pos.hex;
const id_ = dht.id;

const ID = dht.ID;
const Hash = dht.Hash;

pub const log_level: std.log.Level = .info;

const Block = struct {
    tx: ID = dht.id.zeroes(),
    nonce: ID = dht.id.zeroes(),
    seed: ID = dht.id.zeroes(), //the proof
    time: i64 = 0,
    prev: ID = dht.id.zeroes(),
    hash: ID = dht.id.zeroes(),
    height: f64 = 0,

    pub fn prehash(block: *const Block) Hash {
        return pos.plot.hash_fast_mul(&.{ &block.prev, &block.tx, &block.nonce });
    }
};

const Api = union(enum) {
    block: Block,
};

var block_db: std.AutoHashMap(Hash, Block) = undefined;
var chain_head = Block{};
var our_block = Block{};
var closest_dist = dht.id.ones();

fn broadcast_hook(buf: []const u8, src_id: ID, src_address: net.Address) !void {
    std.log.info("Got broadcast: src:{} addr:{}", .{ hex(&src_id), src_address });

    const t = time.milliTimestamp();
    std.log.info("time: {}", .{t});
    const message = try dht.serial.deserialise_slice(Api, buf, std.heap.page_allocator);

    // Verify the block
    const block = message.block;
    std.log.info("tx:{}", .{hex(&block.tx)});

    std.log.info("new chain head block.height: {}", .{block.height});
    chain_head = block; //todo, fix. This is dumb acceptance of the block

    const prehash = block.prehash();

    const bud = try pos.plot.hash_slow(&block.seed);
    const dist = dht.id.xor(prehash, bud);

    //origin block
    var prev_height: f64 = 0;
    var prev_time: i64 = 0;
    if (!std.mem.eql(u8, &block.prev, &std.mem.zeroes(Hash))) {
        if (block_db.get(block.prev)) |prev_block| {
            prev_height = prev_block.height;
            prev_time = prev_block.time;
        } else {
            std.log.debug("Block refused, can't find prev block", .{});
        }
    }

    // calculate the relative height of the block
    const d_height: f64 = 3;
    const new_height = prev_height + d_height;
    std.log.info("height {} t:{}", .{ new_height, t });

    std.log.info("new height: {}", .{new_height});

    if (id_.less(dist, closest_dist)) {
        // accept block
        closest_dist = dist;
        std.log.info("accepted {}", .{hex(&dist)});
    }
}

fn direct_message_hook(buf: []const u8, src_id: dht.ID, src_address: net.Address) !void {
    // const t = time.time();

    std.log.info("Got direct message: {} {} {}", .{ dht.hex(buf), dht.hex(&src_id), src_address });
}

fn setup_our_block(seed: dht.ID) void {
    our_block.seed = seed;
    our_block.time = time.milliTimestamp();
    our_block.height = chain_head.height + 4;
}

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // Setup Chain block
    chain_head.time = time.milliTimestamp();

    // Setup Our block
    dht.rng.random().bytes(&our_block.tx); //our 'vote'

    // Setup server
    const options = try args.parseForCurrentProcess(struct {
        ip: ?[]const u8,
        port: ?u16,
        plot_path: []const u8,
        remote_ip: ?[]const u8 = null,
        remote_port: ?u16 = null,
        db_path: ?[]const u8 = null,
        public: bool = false,
    }, std.heap.page_allocator, .print);
    if (options.options.ip == null or options.options.port == null) {
        std.log.warn("Ip not defined", .{});
        return;
    }
    try dht.init();

    const address = try std.net.Address.parseIp(options.options.ip.?, options.options.port.?);
    const id = dht.id.rand_id();
    var server = try dht.server.Server.init(address, id, .{ .public = options.options.public });
    defer server.deinit();

    if (options.options.remote_ip != null and options.options.remote_port != null) {
        const address_remote = try std.net.Address.parseIp(options.options.remote_ip.?, options.options.remote_port.?);
        try server.routing.add_address_seen(address_remote);
        try server.job_queue.enqueue(.{ .connect = .{ .address = address_remote, .public = true } });
    }

    try server.add_direct_message_hook(direct_message_hook);
    try server.add_broadcast_hook(broadcast_hook);

    // Setup Mining
    const alloc = std.heap.page_allocator;
    const persistent_merged_loaded = try pos.plot.PersistentPlot.init(alloc, options.options.plot_path);

    const mem_bytes = 1024 * 1024; //1mb
    const indexed_plot = try pos.plot.IndexedPersistentPlot.init(alloc, persistent_merged_loaded, mem_bytes);

    std.log.info("{}", .{persistent_merged_loaded.size});
    std.log.info("block size:{} #:{}", .{ indexed_plot.block_size, indexed_plot.index_size });

    std.log.info("Start mining", .{});
    var i: usize = 0;

    const Plant = pos.Plant;
    var closest = std.mem.zeroes(Plant);

    try server.start();
    try server.queue_broadcast("hello");

    while (true) {
        // Setup our_block
        // Update nonce and perhaps tx
        dht.rng.random().bytes(&our_block.nonce);

        // Get prehash
        const prehash = our_block.prehash();
        const search_plant = Plant{ .bud = prehash };

        const found = try persistent_merged_loaded.find(prehash);

        // const found = try indexed_plot.find(bud);
        const dist = dht.id.xor(found.bud, search_plant.bud);

        if (std.mem.order(u8, &dist, &closest_dist) == .lt) {
            our_block.seed = found.seed;
            closest = found;
            closest_dist = dist;
            setup_our_block(found.seed);

            std.log.info("\r[{}] persistent search:dist:{} {} got:{}", .{
                i,
                hex(&closest_dist),
                hex(&search_plant.bud),
                hex(&found.bud),
            });

            const msg = Api{ .block = our_block };
            const buf = try dht.serial.serialise_alloc(msg, allocator);
            // defer allocator.free(msg);
            try server.queue_broadcast(buf);
        }

        i += 1;
    }

    try server.wait();
}

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

fn distance_to_difficulty(dist: ID) f64 {
    const log_value = pos.math.log2(dist);
    return 256.0 - log_value;
}

const Block = struct {
    hash: ID = dht.id.zeroes(),

    prev: ID = dht.id.zeroes(),
    tx: ID = dht.id.zeroes(),
    nonce: ID = dht.id.zeroes(),
    time: i64 = 0,
    height: f64 = 0,

    seed: ID = dht.id.zeroes(), //the proof
    bud: ID = dht.id.zeroes(), //the proof

    difficulty: f64 = 0,
    total_difficulty: f64 = 0,
    prehash: ID = dht.id.zeroes(),
    embargo: i64 = 0,
    total_embargo: i64 = 0,

    pub fn calculate_prehash(block: *Block) void {
        const prehash = pos.plot.hash_fast_mul(&.{
            &block.prev,
            &block.tx,
            &block.nonce,
            std.mem.asBytes(&block.time),
            std.mem.asBytes(&block.height),
        });
        block.prehash = prehash;
    }

    pub fn calculate_hash(block: *Block) void {
        block.hash = pos.plot.hash_fast_mul(&.{
            &block.prehash,
            &block.seed,
            &block.bud, //the proof
            std.mem.asBytes(&block.difficulty),
            std.mem.asBytes(&block.total_difficulty),
            std.mem.asBytes(&block.embargo),
            std.mem.asBytes(&block.total_embargo),
        });
    }

    pub fn calculate_bud(block: *Block) !void {
        block.bud = try pos.plot.hash_slow(&block.seed);
    }

    pub fn calculate_embargo(block: *Block) void {
        const dist = dht.id.xor(block.prehash, block.bud);
        block.difficulty = distance_to_difficulty(dist);
        // std.log.info("diff: {}, {}", .{ hex(&dist), block.difficulty });
        block.embargo = @floatToInt(i64, 100.0 / block.difficulty * 1000.0);
    }
};

const Api = union(enum) {
    block: Block,
    req: bool,
    rep: bool,
    req_block: Hash,
};

var block_db = std.AutoHashMap(Hash, Block).init(std.heap.page_allocator);
var chain_head = Block{};
var our_block = Block{};
var closest_dist = dht.id.ones();

fn broadcast_hook(buf: []const u8, src_id: ID, src_address: net.Address, server: *dht.Server) !void {
    const allocator = std.heap.page_allocator;

    _ = src_address;
    // _ = src_id;
    // std.log.info("Got broadcast: src:{} addr:{}", .{ hex(&src_id), src_address });

    // const t = time.milliTimestamp();
    // std.log.info("time: {}", .{t});
    const message = try dht.serial.deserialise_slice(Api, buf, allocator);

    // Verify the block
    switch (message) {
        .block => |block| {
            if (block.total_difficulty > chain_head.total_difficulty) {
                std.log.info("Accepting received block", .{});
                std.log.info("block total difficulty: {}, chain head: {}", .{ block.total_difficulty, chain_head.total_difficulty });

                try accept_block(block, server);
            } else {
                std.log.info("not accepting block {}: other:{} mine:{}", .{ hex(&block.hash), block.total_difficulty, chain_head.total_difficulty });
            }
        },
        .req => {
            const msg = Api{ .rep = true };
            const send_buf = try dht.serial.serialise_alloc(msg, allocator);
            // defer allocator.free(msg);
            try server.queue_broadcast(send_buf);
        },
        .rep => {
            std.log.info("Got Rep from: {}", .{hex(src_id[0..8])});
        },
        else => {},
    }
    // std.log.info("tx:{}", .{hex(&block.tx)});

    // std.log.info("new chain head block.height: {}", .{block.height});

    // Todo: Create copy and recalculate parameters to verify
    // _ = block.calculate_prehash();
    // block.calculate_embargo();

    //origin block
    // var prev_height: f64 = chain_head.height;
    // var prev_time: i64 = chain_head.time;

    // if (!std.mem.eql(u8, &block.prev, &std.mem.zeroes(Hash))) {
    //     if (block_db.get(block.prev)) |chain_head| {
    //         prev_height = chain_head.height;
    //         prev_time = chain_head.time;
    //     } else {
    //         std.log.debug("Block refused, can't find prev block", .{});
    //     }
    // }

    // calculate the relative height of the block
    // const new_height = prev_height + 1;
    // std.log.info("height {} t:{}", .{ new_height, t });
    // std.log.info("difficulty: {}", .{new_difficulty});

}

fn direct_message_hook(buf: []const u8, src_id: dht.ID, src_address: net.Address, server: *dht.Server) !void {
    // const t = time.time();

    std.log.info("Got direct message: {} {} {}", .{ dht.hex(buf), dht.hex(&src_id), src_address });
    const allocator = std.heap.page_allocator;

    _ = src_address;
    // _ = src_id;
    const message = try dht.serial.deserialise_slice(Api, buf, allocator);
    switch (message) {
        .block => |block| {
            std.log.info("Storing block {}", .{hex(block.hash[0..8])});
            try block_db.put(block.hash, block);
        },
        .req_block => |hash| {
            if (block_db.get(hash)) |block| {
                const msg = Api{ .block = block };
                const send_buf = try dht.serial.serialise_alloc(msg, allocator);
                try server.queue_direct_message(src_id, send_buf);
            } else {
                std.log.info("Dropping req block for hash: {}", .{hex(hash[0..8])});
            }
        },
        else => {
            std.log.info("Not block", .{});
        },
    }
}

fn setup_our_block(seed: dht.ID) !void {
    our_block.prev = chain_head.hash;
    our_block.seed = seed;
    // our_block.tx =
    try our_block.calculate_bud();
    our_block.height = chain_head.height + 1;

    our_block.calculate_prehash();
    our_block.calculate_embargo();
    // std.log.info("chain total diff{} + our diff{}", .{ chain_head.total_difficulty, our_block.difficulty });
    our_block.total_difficulty = chain_head.total_difficulty + our_block.difficulty;
    our_block.total_embargo = chain_head.total_embargo + our_block.embargo;

    our_block.calculate_hash();
}

var accept_mutex = std.Thread.Mutex{};

fn accept_block(new_block: Block, server: *dht.Server) !void {
    const allocator = std.heap.page_allocator;
    std.log.info("accepting block hash: {}, embargo: {}, curtime: {}", .{ hex(&new_block.hash), new_block.total_embargo, time.milliTimestamp() });
    accept_mutex.lock();
    defer accept_mutex.unlock();

    if (!id_.is_equal(chain_head.hash, new_block.prev)) {
        std.log.info("Chain overwritten {} {}", .{ hex(&chain_head.hash), hex(&new_block.prev) });
    }

    try block_db.put(new_block.hash, new_block);

    // loop back
    {
        var cur_hash = new_block.hash;
        var prev_t = new_block.total_embargo;
        while (block_db.get(cur_hash)) |block| {
            if (id_.is_zero(cur_hash))
                break;
            std.log.info("bid:{} t:{} dt:{} hash:{}  diff:{} parent:{}", .{
                block.height,
                block.time,
                prev_t - block.total_embargo,
                hex(cur_hash[0..8]),
                block.total_difficulty,
                hex(block.prev[0..8]),
            });
            cur_hash = block.prev;
            prev_t = block.total_embargo;
        }

        if (!id_.is_zero(cur_hash)) {
            if (try server.finger_table.get_random_active_finger()) |*finger| {
                const req_hash = Api{ .req_block = cur_hash };
                const buf = try dht.serial.serialise_alloc(req_hash, allocator);

                try server.queue_direct_message(finger.id, buf);
            }
        }
    }

    chain_head = new_block;
    closest_dist = dht.id.ones(); //reset closest

    try setup_our_block(id_.ones());
}

pub fn read_and_send(server: *dht.Server) !void {
    _ = server;
    nosuspend {
        const allocator = std.heap.page_allocator;

        var stdin = std.io.getStdIn();
        stdin.intended_io_mode = .blocking;
        var stdout = std.io.getStdOut();
        stdout.intended_io_mode = .blocking;

        var buf: [100]u8 = undefined;
        while (true) {
            const n = try stdin.reader().readUntilDelimiterOrEof(buf[0..], '\n');
            if (n) |_| {} else {
                std.log.info("Std in ended", .{});
                break;
            }
            std.log.info("read line", .{});

            // send req broadcast
            const msg = Api{ .req = true };
            const send_buf = try dht.serial.serialise_alloc(msg, allocator);
            try server.queue_broadcast(send_buf);

            try stdout.writeAll("fingers:\n");
            try server.finger_table.summarize(stdout.writer());
            try stdout.writeAll("public fingers:\n");
            try server.public_finger_table.summarize(stdout.writer());
            // }
        }
    }
}

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // Setup Chain block
    chain_head.time = time.milliTimestamp();
    chain_head.total_embargo = time.milliTimestamp();

    // Setup Our block
    dht.rng.random().bytes(&our_block.tx); //our 'vote'
    try setup_our_block(id_.ones());

    // Setup server
    const options = try args.parseForCurrentProcess(struct {
        ip: ?[]const u8,
        port: ?u16,
        plot_path: []const u8,
        remote_ip: ?[]const u8 = null,
        remote_port: ?u16 = null,
        db_path: ?[]const u8 = null,
        public: bool = false,
        req_thread: bool = false,
        enable_mining: bool = true,
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

    // Line reader for interaction
    // const read_and_send_frame = async read_and_send(server);
    var read_frame: std.Thread = undefined;
    if (options.options.req_thread) {
        read_frame = try std.Thread.spawn(.{}, read_and_send, .{server});
    }
    std.log.info("After frame", .{});

    if (options.options.remote_ip != null and options.options.remote_port != null) {
        const address_remote = try std.net.Address.parseIp(options.options.remote_ip.?, options.options.remote_port.?);
        try server.routing.add_address_seen(address_remote);
        try server.job_queue.enqueue(.{ .connect = .{ .address = address_remote, .public = true } });
    }

    try server.add_direct_message_hook(direct_message_hook);
    try server.add_broadcast_hook(broadcast_hook);

    try server.start();

    if (options.options.enable_mining) {
        // Setup Mining
        const alloc = std.heap.page_allocator;
        const persistent_merged_loaded = try pos.plot.PersistentPlot.init(alloc, options.options.plot_path);

        const mem_bytes = 1024 * 1024; //1mb
        const indexed_plot = try pos.plot.IndexedPersistentPlot.init(alloc, persistent_merged_loaded, mem_bytes);

        std.log.info("{}", .{persistent_merged_loaded.size});
        std.log.info("block size:{} #:{}", .{ indexed_plot.block_size, indexed_plot.index_size });

        std.log.info("Start mining", .{});
        var i: usize = 0;

        while (true) {
            const t = time.milliTimestamp();
            if (t > our_block.total_embargo) { //time to send block
                std.log.info("embargo passed, sending time: {}, embargo: {}", .{ t, our_block.total_embargo });

                const msg = Api{ .block = our_block };
                const buf = try dht.serial.serialise_alloc(msg, allocator);
                // defer allocator.free(msg);
                try server.queue_broadcast(buf);

                //accept our new block
                std.log.info("Accepting own block", .{});
                try accept_block(our_block, server);
            }

            // Setup our_block
            // Update nonce and perhaps tx
            dht.rng.random().bytes(&our_block.nonce);
            our_block.time = t;
            try setup_our_block(id_.ones());

            // Get prehash
            our_block.calculate_prehash();
            const prehash = our_block.prehash;
            const found = try persistent_merged_loaded.find(prehash);

            // const found = try indexed_plot.find(bud);
            const dist = dht.id.xor(found.bud, prehash);

            if (std.mem.order(u8, &dist, &closest_dist) == .lt) {
                // std.log.info("I:{} have chain hash: {} diff:{}, our diff:{}", .{ hex(server.id[0..8]), hex(chain_head.hash[0..8]), chain_head.total_difficulty, our_block.total_difficulty });
                our_block.seed = found.seed;
                our_block.bud = found.bud;

                closest_dist = dist;
                try setup_our_block(found.seed);
                // std.log.info("\r[{}] persistent search:dist:{} {} got:{}", .{
                //     i,
                //     hex(&closest_dist),
                //     hex(&our_block.prehash),
                //     hex(&found.bud),
                // });

                // const difficulty = distance_to_difficulty(closest_dist);
                // const embargo = 40.0 / difficulty;

                // std.log.info("difficulty:{} embargo:{}", .{ difficulty, embargo });
            }

            i += 1;
        }
    }

    try server.wait();
    // try await read_and_send_frame;
}

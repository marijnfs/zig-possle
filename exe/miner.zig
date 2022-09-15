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

const allocator = std.heap.page_allocator;

const MinerSettings = struct {
    accept_delay: i64 = 500,
    send_delay: i64 = 500,
    target_embargo: f64 = 5000,
};
var miner_settings = MinerSettings{};

fn distance_to_difficulty(dist: ID) f64 {
    const log_value = pos.math.log2(dist);
    return 256.0 - log_value;
}

const Block = struct {
    hash: ID = dht.id.zeroes(),

    prev: ID = dht.id.zeroes(),
    tx: ID = dht.id.zeroes(),
    nonce: ID = dht.id.zeroes(),
    // time: i64 = 0,
    height: u64 = 0,

    seed: ID = dht.id.zeroes(), //the proof
    bud: ID = dht.id.zeroes(), //the proof

    difficulty: f64 = 0,
    total_difficulty: f64 = 0,
    prehash: ID = dht.id.zeroes(),
    embargo: i64 = 0,
    total_embargo: i64 = 0,

    target_difficulty: f64 = 2,
    embargo_128: i64 = 0,

    pub fn setup_mining_block(block: *Block, parent: Block, tx: ID, nonce: ID) !void {
        block.tx = tx;
        block.nonce = nonce;
        block.set_parent(parent);
        block.calculate_prehash();
    }

    pub fn rebuild(block: *Block, parent: Block) !void {
        block.set_parent(parent);
        block.calculate_prehash();
        try block.calculate_bud();
        block.calculate_embargo(parent);
        block.calculate_hash();
    }

    pub fn set_parent(block: *Block, parent: Block) void {
        block.prev = parent.hash;
        block.height = parent.height + 1;
    }

    pub fn calculate_prehash(block: *Block) void {
        const prehash = pos.plot.hash_fast_mul(&.{
            &block.prev,
            &block.tx,
            &block.nonce,
            // std.mem.asBytes(&block.time),
            std.mem.asBytes(&block.height),
        });
        block.prehash = prehash;
    }

    pub fn calculate_hash(block: *Block) void {
        block.hash = pos.plot.hash_fast_mul(&.{
            &block.prehash,
            &block.seed, //the proof
            &block.bud,
            std.mem.asBytes(&block.difficulty),
            std.mem.asBytes(&block.total_difficulty),
            std.mem.asBytes(&block.embargo),
            std.mem.asBytes(&block.total_embargo),
        });
    }

    pub fn calculate_bud(block: *Block) !void {
        block.bud = try pos.plot.hash_slow(&block.seed);
    }

    pub fn calculate_embargo(block: *Block, parent: Block) void {
        const dist = dht.id.xor(block.prehash, block.bud);
        block.difficulty = distance_to_difficulty(dist);
        // std.log.info("dif: {} {} {} {} {}", .{ block.difficulty, hex(block.prehash[0..8]), hex(block.bud[0..8]), hex(block.nonce[0..8]), hex(dist[0..8]) });
        block.target_difficulty = parent.target_difficulty;

        // std.log.info("diff: {}, {}", .{ hex(&dist), block.difficulty });
        block.embargo = @floatToInt(i64, block.target_difficulty / block.difficulty * miner_settings.target_embargo);
        block.embargo_128 = parent.embargo_128 + block.embargo;
        const N = 16;
        if (block.height > 0 and block.height % N == 0) {
            // std.log.info("{} {} {}", .{
            //     block.target_difficulty,
            //     block.embargo_128,
            //     std.math.log2(miner_settings.target_embargo / (@intToFloat(f64, block.embargo_128) / N)),
            // });
            // Difficulty Adjustment code
            // block.target_difficulty = block.target_difficulty + std.math.log2(miner_settings.target_embargo / (@intToFloat(f64, block.embargo_128) / N));
            block.target_difficulty *= miner_settings.target_embargo / (@intToFloat(f64, block.embargo_128) / N);
            block.embargo_128 = 0;
        }
        block.total_difficulty = parent.total_difficulty + std.math.exp2(block.difficulty); //Total difficulty is kept track of in linear space
        block.total_embargo = parent.total_embargo + block.embargo;
    }
};

const Api = union(enum) {
    block: Block,
    req: bool,
    rep: []const u8,
    req_block: Hash,
    msg: []const u8,
};

var block_db = std.AutoHashMap(Hash, Block).init(std.heap.page_allocator);
var chain_head = Block{};
var our_best_block = Block{};
var closest_dist = dht.id.ones();

var best_block_mutex = std.Thread.Mutex{};
var chain_head_mutex = std.Thread.Mutex{};

fn broadcast_hook(buf: []const u8, src_id: ID, src_address: net.Address, server: *dht.Server) !bool {
    _ = src_address;
    const message = try dht.serial.deserialise_slice(Api, buf, allocator);

    // Verify the block
    switch (message) {
        .block => |block| {
            const t = time.milliTimestamp();
            if (t - miner_settings.accept_delay > block.total_embargo and block.total_difficulty > chain_head.total_difficulty) {
                std.log.info("Accepting received block", .{});
                std.log.info("block total difficulty: {}, chain head: {}", .{ block.total_difficulty, chain_head.total_difficulty });

                if (block_db.get(block.prev)) |head| {
                    var block_copy = block;
                    try block_copy.rebuild(head);
                    if (!std.mem.eql(u8, std.mem.asBytes(&block), std.mem.asBytes(&block_copy))) {
                        std.log.info("Block rebuild failed, rejecting \n{} \n{}", .{ block, block_copy });
                        return error.FalseRebuild;
                    }
                } else {
                    std.log.info("Don't have head, accepting blindly", .{}); //TODO: replace with proper syncing method
                }

                try accept_block(block, server);
            } else {
                std.log.info("not accepting block {}: from {}, other diff:{} mine diff:{}", .{ hex(block.hash[0..8]), hex(src_id[0..8]), block.total_difficulty, chain_head.total_difficulty });
            }
        },
        .req => {
            const msg = Api{ .rep = try std.fmt.allocPrint(allocator, "my head {} diff: {}", .{ hex(chain_head.hash[0..8]), chain_head.total_difficulty }) };
            const send_buf = try dht.serial.serialise_alloc(msg, allocator);

            try server.queue_direct_message(src_id, send_buf);
            std.log.info("I {} got req, broadcasting now", .{hex(server.id[0..8])});
        },
        .rep => |rep| {
            std.log.info("Got Rep from: {} {s}", .{ hex(src_id[0..8]), rep });
        },
        else => {},
    }
    return true;
}

fn direct_message_hook(buf: []const u8, src_id: dht.ID, src_address: net.Address, server: *dht.Server) !bool {
    // const t = time.time();

    // std.log.info("Got direct message from:{} {}", .{ dht.hex(src_id[0..8]), src_address });
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
        .msg => |msg| {
            std.log.info("{}: {s}", .{ hex(src_id[0..8]), msg });
        },
        .rep => |rep| {
            std.log.info("Got Rep from: {} {s}", .{ hex(src_id[0..8]), rep });
        },

        else => {
            std.log.info("Not block", .{});
        },
    }
    return true;
}

var accept_mutex = std.Thread.Mutex{};

fn accept_block(new_block: Block, server: *dht.Server) !void {
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
            std.log.info("bid:{} tx:{} emb:{}, target:{} dt:{} hash:{}  diff:{} parent:{}", .{
                block.height,
                block.tx[0],
                // block.time,
                block.total_embargo,
                block.target_difficulty,
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

    {
        chain_head_mutex.lock();
        defer chain_head_mutex.unlock();
        chain_head = new_block;
    }
    closest_dist = dht.id.ones(); //reset closest

    our_best_block = Block{};
}

pub fn read_and_send(server: *dht.Server) !void {
    _ = server;
    nosuspend {
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
        }
    }
}

fn send_block_if_embargo(t: i64, server: *dht.Server) !void {
    best_block_mutex.lock();
    defer best_block_mutex.unlock();

    if (our_best_block.total_embargo != 0 and t - miner_settings.send_delay > our_best_block.total_embargo) { //time to send block

        try debug_msg(try std.fmt.allocPrint(allocator, "sending own block: bid:{} emb:{} diff:{}", .{
            hex(our_best_block.hash[0..8]),
            our_best_block.total_embargo,
            our_best_block.total_difficulty,
        }), server);
        std.log.info("embargo passed, sending time: {}, embargo: {}", .{ t, our_best_block.total_embargo });

        const msg = Api{ .block = our_best_block };
        const buf = try dht.serial.serialise_alloc(msg, allocator);
        // defer allocator.free(msg);
        try server.queue_broadcast(buf);

        //accept our new block
        std.log.info("Accepting own block", .{});
        {
            var block_copy = our_best_block;

            if (!id_.is_zero(block_copy.hash)) {
                if (block_db.get(block_copy.prev)) |head| {
                    try block_copy.rebuild(head);
                    if (!std.mem.eql(u8, std.mem.asBytes(&our_best_block), std.mem.asBytes(&block_copy))) {
                        std.log.info("Self Block rebuild failed, rejecting \n{} \n{}", .{ our_best_block, block_copy });
                        return error.FalseRebuild;
                    }
                } else {
                    if (!id_.is_zero(block_copy.prev))
                        return error.PrevNotInDb;
                }
            }
        }
        try accept_block(our_best_block, server);
    }
}

fn debug_msg(buf: []const u8, server: *dht.Server) !void {
    const msg = Api{ .msg = buf };
    const send_buf = try dht.serial.serialise_alloc(msg, allocator);
    try server.queue_direct_message(dht.id.zeroes(), send_buf);
}

pub fn main() anyerror!void {
    // Setup Chain block
    chain_head.total_embargo = time.milliTimestamp();

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
        zero_id: bool = false,
        exp: i64 = 0,
    }, std.heap.page_allocator, .print);

    var tx = id_.zeroes();
    if (options.options.ip == null or options.options.port == null) {
        std.log.warn("Ip not defined", .{});
        return;
    }
    if (options.options.exp == 1) {
        miner_settings = .{ .accept_delay = 1500, .send_delay = 1500 };
        tx[0] = 1;
    }

    try dht.init();
    const address = try std.net.Address.parseIp(options.options.ip.?, options.options.port.?);
    var id = dht.id.rand_id();
    if (options.options.zero_id)
        id = dht.id.zeroes();

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

    if (!options.options.zero_id) {
        // Setup Mining
        const persistent_merged_loaded = try pos.plot.PersistentPlot.init(allocator, options.options.plot_path);

        const indexed_plot = try pos.plot.IndexedPersistentPlot.init(allocator, persistent_merged_loaded);

        std.log.info("{}", .{persistent_merged_loaded.size});
        std.log.info("trie size:{}", .{indexed_plot.trie.items.len});

        std.log.info("Start mining", .{});
        var i: usize = 0;

        while (true) {
            const t = time.milliTimestamp();
            try send_block_if_embargo(t, server);

            // Setup our_block
            // Update nonce and perhaps tx
            var mining_block = Block{};
            var nonce: ID = undefined;
            dht.rng.random().bytes(&nonce);

            chain_head_mutex.lock();
            defer chain_head_mutex.unlock();

            try mining_block.setup_mining_block(chain_head, tx, nonce);

            // Get prehash
            const prehash = mining_block.prehash;
            // const found = try persistent_merged_loaded.find(prehash);
            const found = try indexed_plot.find(prehash);

            const dist = dht.id.xor(prehash, found.bud);

            if (std.mem.order(u8, &dist, &closest_dist) == .lt) {
                closest_dist = dist;

                mining_block.seed = found.seed;
                mining_block.bud = found.bud;

                mining_block.calculate_embargo(chain_head);
                mining_block.calculate_hash();
                best_block_mutex.lock();
                defer best_block_mutex.unlock();
                our_best_block = mining_block;
            }

            i += 1;
        }
    }

    try server.wait();
    // try await read_and_send_frame;
}

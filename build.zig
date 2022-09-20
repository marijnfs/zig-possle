const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    b.use_stage1 = true;
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const dht_pkg = std.build.Pkg{
        .name = "dht",
        .source = .{ .path = "ext/zig-dht/src/index.zig" },
    };

    const args_pkg = std.build.Pkg{
        .name = "yazap",
        .source = .{ .path = "ext/yazap/src/lib.zig" },
    };
    const zigargs_pkg = std.build.Pkg{
        .name = "zig-args",
        .source = .{ .path = "ext/zig-args/args.zig" },
    };

    const pos_pkg = std.build.Pkg{
        .name = "pos",
        .source = .{ .path = "src/index.zig" },
        .dependencies = &.{dht_pkg},
    };

    const plotter = b.addExecutable("plotter", "exe/plotter.zig");
    plotter.setTarget(target);
    plotter.setBuildMode(mode);
    plotter.install();

    plotter.addPackage(dht_pkg);
    plotter.addPackage(args_pkg);
    plotter.addPackage(pos_pkg);

    const run_cmd_plotter = plotter.run();
    run_cmd_plotter.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd_plotter.addArgs(args);
    }

    const miner = b.addExecutable("miner", "exe/miner.zig");
    miner.setTarget(target);
    miner.setBuildMode(mode);
    miner.install();

    miner.addPackage(dht_pkg);
    miner.addPackage(args_pkg);
    miner.addPackage(pos_pkg);
    miner.addPackage(zigargs_pkg);

    const run_cmd_miner = miner.run();
    run_cmd_miner.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd_miner.addArgs(args);
    }

    const indexer = b.addExecutable("indexer", "exe/indexer.zig");
    indexer.setTarget(target);
    indexer.setBuildMode(mode);
    indexer.install();

    indexer.addPackage(dht_pkg);
    indexer.addPackage(args_pkg);
    indexer.addPackage(pos_pkg);
    indexer.addPackage(zigargs_pkg);

    const run_cmd_indexer = indexer.run();
    run_cmd_indexer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd_indexer.addArgs(args);
    }

    const speedtest = b.addExecutable("speedtest", "exe/speedtest.zig");
    speedtest.setTarget(target);
    speedtest.setBuildMode(mode);
    speedtest.install();

    speedtest.addPackage(dht_pkg);
    speedtest.addPackage(args_pkg);
    speedtest.addPackage(pos_pkg);

    const run_cmd_speedtest = speedtest.run();
    run_cmd_speedtest.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd_speedtest.addArgs(args);
    }
}

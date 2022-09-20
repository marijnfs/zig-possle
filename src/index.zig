const std = @import("std");

pub const block = @import("block.zig");
pub const plot = @import("plot.zig");
pub const math = @import("math.zig");

pub const Plant = plot.Plant;
pub const hex = std.fmt.fmtSliceHexLower;

pub var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true, .stack_trace_frames = 12 }){};
// pub const allocator = gpa.allocator();

pub const allocator = std.heap.page_allocator;

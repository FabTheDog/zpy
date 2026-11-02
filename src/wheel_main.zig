//! Writes the wheel of a staged package, see src/wheel.zig.
//! Usage: wheel <output.whl> <staged dir> <package name> <version> <platform tag> <metadata file>

const std = @import("std");
const wheel = @import("wheel.zig");
const options = @import("options");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) {
        std.debug.print("usage: {s} <output.whl> <staged dir> <package name> <version> <platform tag> <metadata file>\n", .{args[0]});
        return error.InvalidUsage;
    }

    const cwd = std.Io.Dir.cwd();
    var staged = try cwd.openDir(io, args[2], .{});
    defer staged.close(io);
    const metadata = try cwd.readFileAlloc(io, args[6], arena, .unlimited);

    const file = try cwd.createFile(io, args[1], .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try wheel.write(init.gpa, io, &writer.interface, .{
        .staged_dir = staged,
        .name = args[3],
        .version = args[4],
        .platform = args[5],
        .metadata = metadata,
        .generator = "zpy " ++ options.version,
    });
}

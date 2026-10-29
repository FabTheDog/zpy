//! Writes the ctypes module of the "bindings" module.
//! Usage: gen <output.py> <shared library file name> <bindings module directory>

const std = @import("std");
const bindgen = @import("bindgen");
const bindings = @import("bindings");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: {s} <output.py> <shared library file name> <bindings module directory>\n", .{args[0]});
        return error.InvalidUsage;
    }

    var source_dir = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer source_dir.close(io);
    var docs: bindgen.source.Index = .init(init.gpa, io, source_dir);
    defer docs.deinit();

    const file = try std.Io.Dir.cwd().createFile(io, args[1], .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try bindgen.python.generate(&writer.interface, bindings.api, bindings.config, .{
        .lib_file = args[2],
        .docs = &docs,
    });
    try writer.interface.flush();
}

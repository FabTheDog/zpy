//! Writes a wheel: a zip of a staged package and its `.dist-info` directory.
//!
//! Each entry is deflated in memory before it is written, so the local
//! headers carry the final sizes and no data descriptors are needed. Entries
//! are sorted and timestamps fixed, so the same inputs give the same bytes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zip = std.zip;
const flate = std.compress.flate;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.url_safe_no_pad.Encoder;

pub const Options = struct {
    /// Directory containing the package directory `name`.
    staged_dir: Io.Dir,
    name: []const u8,
    version: []const u8,
    /// Platform tag, e.g. "manylinux_2_17_x86_64".
    platform: []const u8,
    /// Complete METADATA file.
    metadata: []const u8,
    /// Generator line of the WHEEL file, e.g. "zpy 0.0.1".
    generator: []const u8,
};

pub const Error = error{
    /// The wheel would need zip64, which this writer does not produce.
    ZipTooLarge,
    /// RECORD is a CSV file and this writer does not quote paths.
    UnsupportedPath,
    UnsupportedFileKind,
};

/// Writes the wheel of `options.staged_dir/options.name` to `out`.
pub fn write(gpa: Allocator, io: Io, out: *Io.Writer, options: Options) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files = try packageFiles(arena, io, options.staged_dir, options.name);
    const dist_info = try std.fmt.allocPrint(arena, "{s}-{s}.dist-info", .{ options.name, options.version });
    try files.append(arena, .{
        .path = try std.fmt.allocPrint(arena, "{s}/METADATA", .{dist_info}),
        .data = options.metadata,
    });
    try files.append(arena, .{
        .path = try std.fmt.allocPrint(arena, "{s}/WHEEL", .{dist_info}),
        .data = try std.fmt.allocPrint(arena,
            \\Wheel-Version: 1.0
            \\Generator: {s}
            \\Root-Is-Purelib: false
            \\Tag: py3-none-{s}
            \\
        , .{ options.generator, options.platform }),
    });

    const record_path = try std.fmt.allocPrint(arena, "{s}/RECORD", .{dist_info});
    var record: Io.Writer.Allocating = .init(arena);
    for (files.items) |f| {
        if (std.mem.findAny(u8, f.path, ",\"\r\n") != null) return error.UnsupportedPath;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(f.data, &digest, .{});
        var encoded: [base64.calcSize(Sha256.digest_length)]u8 = undefined;
        try record.writer.print("{s},sha256={s},{d}\n", .{ f.path, base64.encode(&encoded, &digest), f.data.len });
    }
    try record.writer.print("{s},,\n", .{record_path});
    try files.append(arena, .{ .path = record_path, .data = record.written() });

    const window = try arena.alloc(u8, flate.max_window_len);
    const entries = try arena.alloc(Central, files.items.len);
    var offset: u64 = 0;
    for (files.items, entries) |f, *entry| {
        entry.* = try writeLocal(arena, out, window, f, offset);
        offset += @sizeOf(zip.LocalFileHeader) + f.path.len + entry.compressed_size;
    }

    const directory_offset = offset;
    for (entries) |entry| {
        try out.writeStruct(zip.CentralDirectoryFileHeader{
            .signature = zip.central_file_header_sig,
            .version_made_by = 0x031E, // Unix, zip 3.0
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = .deflate,
            .last_modification_time = dos_time,
            .last_modification_date = dos_date,
            .crc32 = entry.crc32,
            .compressed_size = entry.compressed_size,
            .uncompressed_size = entry.uncompressed_size,
            .filename_len = @intCast(entry.path.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0o100644 << 16, // regular file, rw-r--r--
            .local_file_header_offset = entry.offset,
        }, .little);
        try out.writeAll(entry.path);
        offset += @sizeOf(zip.CentralDirectoryFileHeader) + entry.path.len;
    }

    const count = std.math.cast(u16, entries.len) orelse return error.ZipTooLarge;
    try out.writeStruct(zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = count,
        .record_count_total = count,
        .central_directory_size = try u32Size(offset - directory_offset),
        .central_directory_offset = try u32Size(directory_offset),
        .comment_len = 0,
    }, .little);
    try out.flush();
}

/// 1980-01-01 00:00, the earliest DOS timestamp.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;
const dos_time: u16 = 0;

const File = struct {
    /// Path in the archive, with forward slashes.
    path: []const u8,
    data: []const u8,
};

const Central = struct {
    path: []const u8,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    offset: u32,
};

/// Every file under `staged_dir/name`, sorted by archive path.
fn packageFiles(arena: Allocator, io: Io, staged_dir: Io.Dir, name: []const u8) !std.ArrayList(File) {
    var dir = try staged_dir.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();

    var files: std.ArrayList(File) = .empty;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => continue,
            .file, .sym_link => {},
            else => return error.UnsupportedFileKind,
        }
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ name, entry.path });
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        const data = try entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited);
        try files.append(arena, .{ .path = path, .data = data });
    }
    std.mem.sort(File, files.items, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return files;
}

fn writeLocal(arena: Allocator, out: *Io.Writer, window: []u8, f: File, offset: u64) !Central {
    var compressed: Io.Writer.Allocating = try .initCapacity(arena, @max(64, f.data.len / 2));
    var compress: flate.Compress = try .init(&compressed.writer, window, .raw, .default);
    try compress.writer.writeAll(f.data);
    try compress.finish();
    const data = compressed.written();

    const entry: Central = .{
        .path = f.path,
        .crc32 = std.hash.Crc32.hash(f.data),
        .compressed_size = try u32Size(data.len),
        .uncompressed_size = try u32Size(f.data.len),
        .offset = try u32Size(offset),
    };
    try out.writeStruct(zip.LocalFileHeader{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = 20,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = .deflate,
        .last_modification_time = dos_time,
        .last_modification_date = dos_date,
        .crc32 = entry.crc32,
        .compressed_size = entry.compressed_size,
        .uncompressed_size = entry.uncompressed_size,
        .filename_len = std.math.cast(u16, f.path.len) orelse return error.UnsupportedPath,
        .extra_len = 0,
    }, .little);
    try out.writeAll(f.path);
    try out.writeAll(data);
    return entry;
}

fn u32Size(n: u64) Error!u32 {
    // 0xffffffff itself marks a zip64 field.
    return if (n < std.math.maxInt(u32)) @intCast(n) else error.ZipTooLarge;
}

const testing = std.testing;

const sub_source = "def f():\n    return 1\n\n\ndef g():\n    return f() + f()\n";

fn testWheel(tmp: *testing.TmpDir) !void {
    try tmp.dir.createDirPath(testing.io, "staged/pkg/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "staged/pkg/__init__.py", .data = "from .sub import x\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "staged/pkg/sub/__init__.py", .data = sub_source });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "staged/pkg/libpkg.so", .data = "" });

    var staged = try tmp.dir.openDir(testing.io, "staged", .{});
    defer staged.close(testing.io);
    const file = try tmp.dir.createFile(testing.io, "pkg.whl", .{});
    defer file.close(testing.io);
    var buffer: [256]u8 = undefined;
    var writer = file.writer(testing.io, &buffer);
    try write(testing.allocator, testing.io, &writer.interface, .{
        .staged_dir = staged,
        .name = "pkg",
        .version = "1.2.3",
        .platform = "manylinux_2_17_x86_64",
        .metadata = "Metadata-Version: 2.1\nName: pkg\nVersion: 1.2.3\n",
        .generator = "zpy test",
    });

    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);
    const whl = try tmp.dir.openFile(testing.io, "pkg.whl", .{});
    defer whl.close(testing.io);
    var reader_buffer: [4096]u8 = undefined;
    var reader = whl.reader(testing.io, &reader_buffer);
    try zip.extract(out, &reader, .{});
}

fn expectFile(dir: Io.Dir, path: []const u8, expected: []const u8) !void {
    const data = try dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(expected, data);
}

test "round trip through std.zip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testWheel(&tmp);

    try expectFile(tmp.dir, "out/pkg/__init__.py", "from .sub import x\n");
    try expectFile(tmp.dir, "out/pkg/sub/__init__.py", sub_source);
    try expectFile(tmp.dir, "out/pkg/libpkg.so", "");
    try expectFile(tmp.dir, "out/pkg-1.2.3.dist-info/METADATA", "Metadata-Version: 2.1\nName: pkg\nVersion: 1.2.3\n");
    try expectFile(tmp.dir, "out/pkg-1.2.3.dist-info/WHEEL",
        \\Wheel-Version: 1.0
        \\Generator: zpy test
        \\Root-Is-Purelib: false
        \\Tag: py3-none-manylinux_2_17_x86_64
        \\
    );
}

test "RECORD lists every file with its hash and size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testWheel(&tmp);

    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);
    const record = try out.readFileAlloc(testing.io, "pkg-1.2.3.dist-info/RECORD", testing.allocator, .unlimited);
    defer testing.allocator.free(record);

    const expected_paths = [_][]const u8{
        "pkg/__init__.py",
        "pkg/libpkg.so",
        "pkg/sub/__init__.py",
        "pkg-1.2.3.dist-info/METADATA",
        "pkg-1.2.3.dist-info/WHEEL",
    };
    var lines = std.mem.splitScalar(u8, record, '\n');
    for (expected_paths) |path| {
        var fields = std.mem.splitScalar(u8, lines.next().?, ',');
        try testing.expectEqualStrings(path, fields.next().?);
        const data = try out.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(data);
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(data, &digest, .{});
        var encoded: [base64.calcSize(Sha256.digest_length)]u8 = undefined;
        var hash_field: [64]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&hash_field, "sha256={s}", .{base64.encode(&encoded, &digest)}),
            fields.next().?,
        );
        try testing.expectEqual(data.len, try std.fmt.parseInt(usize, fields.next().?, 10));
        try testing.expectEqual(null, fields.next());
    }
    try testing.expectEqualStrings("pkg-1.2.3.dist-info/RECORD,,", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(null, lines.next());
}

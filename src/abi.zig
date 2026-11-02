//! How Zig types cross the C boundary. The exporter and the Python generator
//! both derive every signature and layout from here.

const std = @import("std");
const Config = @import("bindgen.zig").Config;

pub const Kind = enum {
    void,
    bool,
    int,
    float,
    @"enum",
    /// Struct of data fields, copied through an extern mirror.
    value,
    /// Tagged union of data payloads: `extern struct { tag, payload: extern union }`.
    @"union",
    /// `?T` of a data type: `extern struct { some, value }`.
    optional,
    /// `[]const T`, parameters only: `extern struct { ptr, len }`.
    slice,
    /// `[]T` of ints, floats or bools, parameters only: `extern struct { ptr, len }`
    /// pointing into a writable Python buffer, which the call fills in place.
    buffer,
    /// Owned by Zig (`T` by value, `*T` or `*const T`); Python holds a pointer
    /// to a heap copy made by the thunk returning it. `std.mem.Allocator` and
    /// `std.Io` are handles too, filled in by the library (see `isInjected`).
    handle,
    /// `[:0]const u8` or `[*:0]const u8`.
    string,
    unsupported,

    /// Can be a field, a union payload, an optional child and a result.
    pub fn isData(kind: Kind) bool {
        return switch (kind) {
            .bool, .int, .float, .@"enum", .value, .@"union", .optional => true,
            else => false,
        };
    }
};

pub fn kindOf(comptime T: type) Kind {
    return comptime classify(T);
}

fn classify(comptime T: type) Kind {
    @setEvalBranchQuota(100_000);
    if (T == void) return .void;
    if (T == bool) return .bool;
    return switch (@typeInfo(T)) {
        .int => |info| if (cSizedBits(info.bits) == info.bits) .int else .unsupported,
        .float => |info| if (info.bits == 32 or info.bits == 64) .float else .unsupported,
        .@"enum" => |info| if (cSizedBits(@typeInfo(info.tag_type).int.bits) != null) .@"enum" else .unsupported,
        .@"struct" => structKind(T),
        .@"union" => unionKind(T),
        .optional => |info| if (kindOf(info.child).isData()) .optional else .unsupported,
        .pointer => pointerKind(T),
        else => .unsupported,
    };
}

/// A struct is a value when every field is data or a pointer to a resource
/// (a handle with a `deinit`, like `RunConfig.physics`); one with a `deinit`
/// or a field Python cannot hold (allocator, list, vtable) is a handle.
fn structKind(comptime T: type) Kind {
    const info = @typeInfo(T).@"struct";
    if (info.is_tuple or info.layout == .@"packed") return .unsupported;
    if (@hasDecl(T, "deinit")) return .handle;
    for (info.field_types, info.field_attrs) |F, attrs| {
        if (attrs.@"comptime" or !(kindOf(F).isData() or isResourceRef(F))) return .handle;
    }
    return .value;
}

/// `*H` or `*const H` with `H` a handle that has a `deinit`.
fn isResourceRef(comptime F: type) bool {
    return @typeInfo(F) == .pointer and kindOf(F) == .handle and @hasDecl(@typeInfo(F).pointer.child, "deinit");
}

fn unionKind(comptime T: type) Kind {
    const info = @typeInfo(T).@"union";
    if (info.tag_type == null or info.layout != .auto) return .unsupported;
    for (info.field_types) |F| if (F != void and !kindOf(F).isData()) return .unsupported;
    return .@"union";
}

fn pointerKind(comptime T: type) Kind {
    if (isString(T)) return .string;
    const ptr = @typeInfo(T).pointer;
    switch (ptr.size) {
        .slice => if (ptr.sentinel_ptr != null) {} else if (ptr.attrs.@"const") switch (kindOf(ptr.child)) {
            .slice, .string => return .slice,
            else => |kind| if (kind.isData()) return .slice,
        } else switch (kindOf(ptr.child)) {
            .bool, .int, .float => return .buffer,
            else => {},
        },
        .one => if (@typeInfo(ptr.child) == .@"struct" and kindOf(ptr.child) == .handle) return .handle,
        else => {},
    }
    return .unsupported;
}

/// Smallest C integer size holding `bits`, null above 64.
fn cSizedBits(bits: u16) ?u16 {
    for ([_]u16{ 8, 16, 32, 64 }) |size| if (bits <= size) return size;
    return null;
}

fn isString(comptime T: type) bool {
    const ptr = @typeInfo(T).pointer;
    if (ptr.child != u8 or !ptr.attrs.@"const") return false;
    if (ptr.size != .slice and ptr.size != .many) return false;
    const sentinel = ptr.sentinel() orelse return false;
    return sentinel == 0;
}

/// The handle type behind `T`, `*T` or `*const T`, if `T` is a handle.
pub fn HandleOf(comptime P: type) ?type {
    if (kindOf(P) != .handle) return null;
    return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
}

/// Handles reached by a value of type `T`, directly or through its fields.
pub fn handlesIn(comptime T: type) []const type {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var found: []const type = &.{};
        switch (kindOf(T)) {
            .handle => found = &.{HandleOf(T).?},
            .value => for (@typeInfo(T).@"struct".field_types) |F| {
                found = found ++ handlesIn(F);
            },
            .@"union" => for (@typeInfo(T).@"union".field_types) |F| {
                found = found ++ handlesIn(F);
            },
            .optional => found = handlesIn(@typeInfo(T).optional.child),
            .slice => found = handlesIn(@typeInfo(T).pointer.child),
            else => {},
        }
        const final = found[0..found.len].*;
        break :blk &final;
    };
}

/// The interface a handle implements through its `interface` field, like
/// `std.Io.Writer`: such a handle can be passed where `*Interface` is expected.
pub fn InterfaceOf(comptime H: type) ?type {
    if (!@hasField(H, "interface")) return null;
    const I = @FieldType(H, "interface");
    return if (@typeInfo(I) == .@"struct" and kindOf(I) == .handle) I else null;
}

/// C representation of a value of type `T`: field, slice element, frame slot.
pub fn Abi(comptime T: type) type {
    return switch (kindOf(T)) {
        .bool, .int, .float => T,
        .@"enum" => EnumTag(T),
        .value => StructMirror(T),
        .@"union" => UnionMirror(T),
        .optional => extern struct { some: bool, value: Abi(@typeInfo(T).optional.child) },
        .slice => extern struct { ptr: ?[*]const Abi(@typeInfo(T).pointer.child), len: usize },
        .buffer => extern struct { ptr: ?[*]@typeInfo(T).pointer.child, len: usize },
        .handle => ?*anyopaque,
        .string => ?[*:0]const u8,
        // Union payloads only: an extern union needs a field per variant.
        .void => extern struct {},
        .unsupported => @compileError("bindgen: no C representation for " ++ @typeName(T)),
    };
}

/// Integer carrying an enum: its tag type rounded up to a C size.
pub fn EnumTag(comptime E: type) type {
    const Tag = @typeInfo(E).@"enum".tag_type;
    const info = @typeInfo(Tag).int;
    const bits = cSizedBits(info.bits).?;
    return if (bits == info.bits) Tag else @Int(info.signedness, bits);
}

/// Extern struct with the fields of `T`, each in its C representation.
/// Also used for extern structs, so enum fields are validated on the way in.
fn StructMirror(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var types: [info.field_types.len]type = undefined;
    inline for (info.field_types, &types) |F, *A| A.* = Abi(F);
    return @Struct(.@"extern", null, info.field_names, &types, &@splat(.{}));
}

fn UnionMirror(comptime T: type) type {
    const info = @typeInfo(T).@"union";
    var types: [info.field_types.len]type = undefined;
    inline for (info.field_types, &types) |F, *A| A.* = Abi(F);
    const Variants = @Union(.@"extern", null, info.field_names, &types, &@splat(.{}));
    return extern struct { tag: EnumTag(info.tag_type.?), payload: Variants };
}

/// What a call to `F` exchanges with C: the visible arguments `a0, a1, ...`
/// in their C representation, then `out` for the result unless it is void.
/// Every thunk takes a pointer to one, see `exporter.zig`.
pub fn Frame(comptime cfg: Config, comptime F: type) type {
    const params = visibleParams(cfg, F);
    const T = Payload(@typeInfo(F).@"fn".return_type.?);
    const n = params.len + @intFromBool(T != void);
    var names: [n][:0]const u8 = undefined;
    var types: [n]type = undefined;
    inline for (params, 0..) |P, i| {
        names[i] = std.fmt.comptimePrint("a{d}", .{i});
        types[i] = Abi(P);
    }
    if (T != void) {
        names[params.len] = "out";
        types[params.len] = Abi(T);
    }
    return @Struct(.@"extern", null, &names, &types, &@splat(.{}));
}

pub const ConvertError = error{ InvalidArgument, OutOfMemory };

pub fn toAbi(comptime T: type, v: T) Abi(T) {
    switch (comptime kindOf(T)) {
        .void => return .{},
        .bool, .int, .float => return v,
        .@"enum" => return @backingInt(v),
        .value => {
            var a: Abi(T) = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
                @field(a, name) = toAbi(F, @field(v, name));
            }
            return a;
        },
        .@"union" => switch (v) {
            inline else => |payload, tag| {
                var a: Abi(T) = .{ .tag = @backingInt(tag), .payload = undefined };
                @field(a.payload, @tagName(tag)) = toAbi(@TypeOf(payload), payload);
                return a;
            },
        },
        .optional => {
            const C = @typeInfo(T).optional.child;
            return if (v) |c| .{ .some = true, .value = toAbi(C, c) } else std.mem.zeroes(Abi(T));
        },
        .handle => return @ptrCast(@constCast(v)),
        .slice, .buffer, .string, .unsupported => @compileError("bindgen: cannot return " ++ @typeName(T)),
    }
}

/// Converts a C value. Slices whose elements need converting are copied into
/// `arena`, so they only live during the call; slices of integers, floats
/// and bools point to the Python buffer. Pointers are optional so a null
/// from Python is an `InvalidArgument` instead of a crash.
pub fn fromAbi(comptime T: type, a: Abi(T), arena: std.mem.Allocator) ConvertError!T {
    switch (comptime kindOf(T)) {
        .void => return {},
        .bool, .int, .float => return a,
        .@"enum" => return std.enums.fromInt(T, a) orelse error.InvalidArgument,
        .value => {
            var v: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
                @field(v, name) = try fromAbi(F, @field(a, name), arena);
            }
            return v;
        },
        .@"union" => {
            const Tag = @typeInfo(T).@"union".tag_type.?;
            switch (std.enums.fromInt(Tag, a.tag) orelse return error.InvalidArgument) {
                inline else => |tag| {
                    const name = @tagName(tag);
                    return @unionInit(T, name, try fromAbi(@FieldType(T, name), @field(a.payload, name), arena));
                },
            }
        },
        .optional => return if (a.some) try fromAbi(@typeInfo(T).optional.child, a.value, arena) else null,
        .handle => {
            const ptr: *HandleOf(T).? = @ptrCast(@alignCast(a orelse return error.InvalidArgument));
            return if (@typeInfo(T) == .pointer) ptr else ptr.*;
        },
        .slice => {
            const E = @typeInfo(T).pointer.child;
            if (a.len == 0) return &.{};
            const items = (a.ptr orelse return error.InvalidArgument)[0..a.len];
            if (Abi(E) == E) return items;
            const out = try arena.alloc(E, a.len);
            for (out, items) |*o, item| o.* = try fromAbi(E, item, arena);
            return out;
        },
        .buffer => {
            const E = @typeInfo(T).pointer.child;
            // An empty buffer may come with a null pointer; a dangling but
            // aligned one keeps the slice valid.
            const ptr = a.ptr orelse if (a.len == 0) @as([*]E, @ptrFromInt(@alignOf(E))) else return error.InvalidArgument;
            return ptr[0..a.len];
        },
        .string => {
            const ptr = a orelse return error.InvalidArgument;
            return if (@typeInfo(T).pointer.size == .slice) std.mem.span(ptr) else ptr;
        },
        .unsupported => @compileError("bindgen: cannot pass " ++ @typeName(T)),
    }
}

/// Filled in by the library instead of Python: `std.mem.Allocator`,
/// `std.Io` and the types of `Config.inject`.
pub fn isInjected(comptime cfg: Config, comptime P: type) bool {
    if (P == std.mem.Allocator or P == std.Io) return true;
    for (cfg.inject) |i| if (i.T == P) return true;
    return false;
}

/// Zig parameters of `F` that Python passes, in order.
pub fn visibleParams(comptime cfg: Config, comptime F: type) []const type {
    return comptime blk: {
        var params: []const type = &.{};
        for (@typeInfo(F).@"fn".param_types) |P| {
            if (!isInjected(cfg, P.?)) params = params ++ .{P.?};
        }
        const final = params[0..params.len].*;
        break :blk &final;
    };
}

/// Successful result of a function returning `R`.
pub fn Payload(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

/// Why `F` cannot be exported, or null if it can.
pub fn whyUnsupported(comptime cfg: Config, comptime F: type) ?[]const u8 {
    return comptime checkFn(cfg, F);
}

fn checkFn(comptime cfg: Config, comptime F: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const info = @typeInfo(F).@"fn";
    if (info.is_generic) return "generic function";
    if (info.attrs.varargs) return "variadic function";
    for (info.param_types, 0..) |P_opt, i| {
        const P = P_opt orelse return "anytype parameter";
        if (isInjected(cfg, P)) continue;
        switch (kindOf(P)) {
            .void, .unsupported => return std.fmt.comptimePrint("parameter {d} has unsupported type {s}", .{ i, @typeName(P) }),
            else => {},
        }
    }
    const R = info.return_type orelse return "generic return type";
    if (@typeInfo(R) == .error_union and
        @typeInfo(@typeInfo(R).error_union.error_set).error_set.error_names == null)
    {
        return "returns anyerror";
    }
    const T = Payload(R);
    const returnable = switch (kindOf(T)) {
        .void => true,
        // Python cannot rebuild handle objects from the pointers in a result.
        .bool, .int, .float, .@"enum", .value, .@"union", .optional => handlesIn(T).len == 0,
        // Borrowed pointers would outlive their owner in Python.
        .handle => @typeInfo(T) != .pointer,
        .slice, .buffer, .string, .unsupported => false,
    };
    if (!returnable) return std.fmt.comptimePrint("unsupported return type {s}", .{@typeName(T)});
    return null;
}

/// Canonical text of the C representation of `T`. Its hash, compiled into
/// both the library and the Python module, detects a stale module.
pub fn describe(comptime T: type) []const u8 {
    @setEvalBranchQuota(100_000);
    return comptime switch (kindOf(T)) {
        .void, .bool, .int, .float => @typeName(T),
        .@"enum" => blk: {
            const info = @typeInfo(T).@"enum";
            var s: []const u8 = "enum(" ++ @typeName(EnumTag(T)) ++ "){";
            for (info.field_names, info.field_values) |name, value| s = s ++ std.fmt.comptimePrint("{s}={d},", .{ name, value });
            break :blk s ++ "}";
        },
        .value => blk: {
            const info = @typeInfo(T).@"struct";
            var s: []const u8 = "struct{";
            for (info.field_names, info.field_types) |name, F| s = s ++ name ++ ":" ++ describe(F) ++ ",";
            break :blk s ++ "}";
        },
        .@"union" => blk: {
            const info = @typeInfo(T).@"union";
            var s: []const u8 = "union(" ++ describe(info.tag_type.?) ++ "){";
            for (info.field_names, info.field_types) |name, F| s = s ++ name ++ ":" ++ describe(F) ++ ",";
            break :blk s ++ "}";
        },
        .optional => "?" ++ describe(@typeInfo(T).optional.child),
        .slice => "[]" ++ describe(@typeInfo(T).pointer.child),
        .buffer => "[]var " ++ describe(@typeInfo(T).pointer.child),
        .handle => "handle",
        .string => "string",
        .unsupported => @compileError("bindgen: cannot describe " ++ @typeName(T)),
    };
}

test kindOf {
    const Vec = struct { x: f64, y: f64 = 1 };
    const Owner = struct {
        items: std.ArrayList(u8),
    };
    const Resource = struct {
        pub fn deinit(_: *@This()) void {}
    };
    const Ref = struct { resource: *const Resource, scale: f64 };
    const Interface = struct { vtable: *const Owner };
    const Color = enum { red, green };
    const Shape = union(enum) { dot, circle: f64, vec: Vec };
    try std.testing.expectEqual(.int, kindOf(c_int));
    try std.testing.expectEqual(.unsupported, kindOf(u7));
    try std.testing.expectEqual(.@"enum", kindOf(Color));
    try std.testing.expectEqual(.value, kindOf(Vec));
    try std.testing.expectEqual(.value, kindOf(struct { v: Vec, c: Color, s: ?Shape }));
    try std.testing.expectEqual(.handle, kindOf(Owner));
    try std.testing.expectEqual(.handle, kindOf(struct {
        pub fn deinit(_: @This()) void {}
    }));
    try std.testing.expectEqual(.value, kindOf(Ref));
    try std.testing.expectEqual(.handle, kindOf(Interface)); // not a resource
    try std.testing.expectEqual(.@"union", kindOf(Shape));
    try std.testing.expectEqual(.unsupported, kindOf(union { a: u8, b: f32 }));
    try std.testing.expectEqual(.optional, kindOf(?f64));
    try std.testing.expectEqual(.unsupported, kindOf(?*const Owner));
    try std.testing.expectEqual(.string, kindOf([:0]const u8));
    try std.testing.expectEqual(.slice, kindOf([]const u8));
    try std.testing.expectEqual(.slice, kindOf([]const []const u8));
    try std.testing.expectEqual(.buffer, kindOf([]u8));
    try std.testing.expectEqual(.buffer, kindOf([]f64));
    try std.testing.expectEqual(.buffer, kindOf([]bool));
    try std.testing.expectEqual(.unsupported, kindOf([]Vec)); // writes would not reach Python
    try std.testing.expectEqual(.unsupported, kindOf([:0]u8));
    try std.testing.expectEqual(.handle, kindOf(std.mem.Allocator));
    try std.testing.expectEqual(.handle, kindOf(*const Owner));
    try std.testing.expectEqual(.unsupported, kindOf(*Vec));
    try std.testing.expectEqual(1, handlesIn(Ref).len);
}

test "mirror layout and round trip" {
    const Color = enum { red, green, blue };
    const Shape = union(enum) { dot, circle: f64, poly: struct { n: u32 } };
    const Brush = struct { color: Color, size: f32, origin: struct { x: f64, y: f64 }, shape: ?Shape };
    const M = Abi(Brush);
    try std.testing.expectEqual(.@"extern", @typeInfo(M).@"struct".layout);
    try std.testing.expectEqual(u8, @FieldType(M, "color"));

    const F = Frame(.{ .prefix = "t" }, fn (Brush, std.mem.Allocator, u32) ?f64);
    try std.testing.expectEqual(3, @typeInfo(F).@"struct".field_names.len); // a0, a1, out
    try std.testing.expectEqual(M, @FieldType(F, "a0"));
    try std.testing.expectEqual(u32, @FieldType(F, "a1"));
    try std.testing.expectEqual(Abi(?f64), @FieldType(F, "out"));
    try std.testing.expectEqual(0, @typeInfo(Frame(.{ .prefix = "t" }, fn () void)).@"struct".field_names.len);

    const brushes = [_]Brush{
        .{ .color = .blue, .size = 2, .origin = .{ .x = 1, .y = -1 }, .shape = .{ .poly = .{ .n = 5 } } },
        .{ .color = .red, .size = 2, .origin = .{ .x = 1, .y = -1 }, .shape = .dot },
        .{ .color = .red, .size = 2, .origin = .{ .x = 1, .y = -1 }, .shape = null },
    };
    const no_arena = std.testing.failing_allocator;
    for (brushes) |brush| try std.testing.expectEqual(brush, try fromAbi(Brush, toAbi(Brush, brush), no_arena));

    var bad = toAbi(Brush, brushes[0]);
    bad.color = 7;
    try std.testing.expectError(error.InvalidArgument, fromAbi(Brush, bad, no_arena));
    bad = toAbi(Brush, brushes[0]);
    bad.shape.value.tag = 9;
    try std.testing.expectError(error.InvalidArgument, fromAbi(Brush, bad, no_arena));
}

test "slices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const floats = [_]f64{ 1, 2, 3 };
    const fs = try fromAbi([]const f64, .{ .ptr = &floats, .len = 3 }, a);
    try std.testing.expectEqual(&floats, fs.ptr); // no copy

    const Color = enum { red, green };
    const tags = [_]u8{ 1, 0 };
    const colors = try fromAbi([]const Color, .{ .ptr = &tags, .len = 2 }, a);
    try std.testing.expectEqualSlices(Color, &.{ .green, .red }, colors);
    const bad = [_]u8{ 1, 2 };
    try std.testing.expectError(error.InvalidArgument, fromAbi([]const Color, .{ .ptr = &bad, .len = 2 }, a));

    const words = [_]Abi([]const u8){ .{ .ptr = "ab", .len = 2 }, .{ .ptr = "c", .len = 1 } };
    const ws = try fromAbi([]const []const u8, .{ .ptr = &words, .len = 2 }, a);
    try std.testing.expectEqualStrings("ab", ws[0]);
    try std.testing.expectEqualStrings("c", ws[1]);

    try std.testing.expectEqual(0, (try fromAbi([]const f64, .{ .ptr = null, .len = 0 }, a)).len);
    try std.testing.expectError(error.InvalidArgument, fromAbi([]const f64, .{ .ptr = null, .len = 1 }, a));
    try std.testing.expectError(error.InvalidArgument, fromAbi([:0]const u8, null, a));

    var cells = [_]u32{ 0, 0 };
    const out = try fromAbi([]u32, .{ .ptr = &cells, .len = 2 }, no_arena_for_buffers);
    out[1] = 5;
    try std.testing.expectEqual(5, cells[1]); // written in place
    try std.testing.expectEqual(0, (try fromAbi([]u32, .{ .ptr = null, .len = 0 }, no_arena_for_buffers)).len);
    try std.testing.expectError(error.InvalidArgument, fromAbi([]u32, .{ .ptr = null, .len = 1 }, no_arena_for_buffers));
}

const no_arena_for_buffers = std.testing.failing_allocator;

test whyUnsupported {
    const cfg: Config = .{ .prefix = "t" };
    const Owner = struct { items: std.ArrayList(u8) };
    const S = struct {
        fn ok(_: std.mem.Allocator, _: i32, _: [:0]const u8, _: []const f64) error{A}!?f64 {
            return 0;
        }
        fn generic(x: anytype) void {
            _ = x;
        }
        fn mutable(_: []u8) void {}
        fn mutableStructs(_: []Owner) void {}
        fn any() anyerror!void {}
        fn borrowed(o: *Owner) *Owner {
            return o;
        }
        fn boxed() Owner {
            return .{ .items = .empty };
        }
    };
    try std.testing.expectEqual(null, whyUnsupported(cfg, @TypeOf(S.ok)));
    try std.testing.expectEqualStrings("generic function", whyUnsupported(cfg, @TypeOf(S.generic)).?);
    try std.testing.expectEqual(null, whyUnsupported(cfg, @TypeOf(S.mutable)));
    try std.testing.expect(whyUnsupported(cfg, @TypeOf(S.mutableStructs)) != null);
    try std.testing.expectEqualStrings("returns anyerror", whyUnsupported(cfg, @TypeOf(S.any)).?);
    try std.testing.expect(whyUnsupported(cfg, @TypeOf(S.borrowed)) != null);
    try std.testing.expectEqual(null, whyUnsupported(cfg, @TypeOf(S.boxed)));
    try std.testing.expectEqual(3, visibleParams(cfg, @TypeOf(S.ok)).len);
}

test describe {
    const Shape = union(enum) { dot, circle: f64 };
    try std.testing.expectEqualStrings(
        "struct{s:?union(enum(u8){dot=0,circle=1,}){dot:void,circle:f64,},n:u32,}",
        comptime describe(struct { s: ?Shape, n: u32 }),
    );
    try std.testing.expectEqualStrings("[][]u8", comptime describe([]const []const u8));
}

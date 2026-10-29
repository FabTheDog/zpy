//! Collects what an API exports. Pub declarations are walked breadth-first
//! from the API root, so a type re-exported at the root keeps its short name:
//! types become Python classes, functions get a thunk, constants of data
//! types are copied into the Python module. Types used by exported signatures
//! are added even when no declaration names them.

const std = @import("std");
const abi = @import("abi.zig");
const bindgen = @import("bindgen.zig");
const Config = bindgen.Config;

pub const Function = struct {
    /// Type declaring the function.
    container: type,
    /// Declaration name, e.g. "addVolume".
    name: [:0]const u8,
    /// Declaration path from the API root, e.g. "Geometry.addVolume".
    path: []const u8,
    /// Exported C symbol, e.g. "mpz_Geometry_addVolume".
    symbol: [:0]const u8,
};

/// A type with a Python class: an enum, a value, a union or a handle.
pub const Type = struct {
    T: type,
    /// Python name, e.g. "Vec3", "Source_TwoSurface".
    name: []const u8,
    kind: abi.Kind,
    /// Declaration path from the API root, empty if not declared.
    path: []const u8 = "",
};

pub const Constant = struct {
    container: type,
    name: [:0]const u8,
};

pub const Skipped = struct {
    path: []const u8,
    reason: []const u8,
};

pub const Api = struct {
    root: type,
    functions: []const Function,
    /// Each after the types it is built from.
    types: []const Type,
    constants: []const Constant,
    skipped: []const Skipped,

    pub fn typeName(comptime api: Api, comptime T: type) []const u8 {
        return comptime for (api.types) |t| {
            if (t.T == T) break t.name;
        } else @compileError("bindgen: " ++ @typeName(T) ++ " is not part of the API");
    }

    pub fn destroySymbol(comptime api: Api, comptime cfg: Config, comptime T: type) [:0]const u8 {
        return comptime underscored(cfg.prefix ++ "_" ++ api.typeName(T) ++ "__destroy");
    }

    pub fn interfaceSymbol(comptime api: Api, comptime cfg: Config, comptime T: type) [:0]const u8 {
        return comptime underscored(cfg.prefix ++ "_" ++ api.typeName(T) ++ "__interface");
    }

    pub fn hashSymbol(comptime cfg: Config) [:0]const u8 {
        return comptime underscored(cfg.prefix ++ "__abi_hash");
    }

    /// Hash of every exported signature and layout, compiled into both the
    /// library and the Python module.
    pub fn hash(comptime api: Api, comptime cfg: Config) u64 {
        return comptime blk: {
            @setEvalBranchQuota(1_000_000);
            var s: []const u8 = cfg.prefix;
            for (cfg.errors) |e| s = s ++ "," ++ @errorName(e);
            for (api.functions) |f| {
                const F = @TypeOf(@field(f.container, f.name));
                s = s ++ ";" ++ f.symbol ++ "(";
                for (abi.visibleParams(cfg, F)) |P| s = s ++ abi.describe(P) ++ ",";
                s = s ++ ")" ++ abi.describe(abi.Payload(@typeInfo(F).@"fn".return_type.?));
            }
            for (api.types) |t| s = s ++ ";" ++ t.name ++ "=" ++ abi.describe(t.T);
            break :blk std.hash.Wyhash.hash(0, s);
        };
    }
};

pub fn collect(comptime root: type, comptime cfg: Config) Api {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var w: Walker = .{ .cfg = cfg, .root = root };
        w.scanAll();
        w.dropUncallable();
        for (w.containers[1..]) |c| switch (c.kind) {
            .@"enum", .value, .@"union" => w.need(c.T, null),
            else => {},
        };
        for (w.functions) |f| {
            const F = @TypeOf(@field(f.container, f.name));
            if (f.container != root) w.need(f.container, null);
            for (abi.visibleParams(cfg, F)) |P| w.need(P, null);
            w.need(abi.Payload(@typeInfo(F).@"fn".return_type.?), null);
        }
        for (w.constants) |c| w.need(@TypeOf(@field(c.container, c.name)), null);
        w.checkNames();
        break :blk w.finish();
    };
}

const Walker = struct {
    cfg: Config,
    root: type,
    /// Every type reached through declarations, the root first.
    containers: []const Type = &.{},
    functions: []const Function = &.{},
    types: []const Type = &.{},
    constants: []const Constant = &.{},
    skipped: []const Skipped = &.{},

    fn scanAll(w: *Walker) void {
        w.containers = &.{.{ .T = w.root, .name = "", .kind = .value }};
        var i: usize = 0;
        while (i < w.containers.len) : (i += 1) w.scan(w.containers[i]);
    }

    fn scan(w: *Walker, comptime c: Type) void {
        const C = c.T;
        const decl_names = switch (@typeInfo(C)) {
            inline .@"struct", .@"enum", .@"union", .@"opaque" => |info| info.decl_names,
            else => return,
        };
        const has_class = C == w.root or switch (c.kind) {
            .@"enum", .value, .@"union", .handle => true,
            else => false,
        };
        for (decl_names) |name| {
            const path = if (c.path.len == 0) name else c.path ++ "." ++ name;
            if (w.isSkipped(path)) {
                w.skip(path, "listed in config.skip");
                continue;
            }
            const value = @field(C, name);
            const V = @TypeOf(value);
            if (V == type) {
                switch (@typeInfo(value)) {
                    .@"struct", .@"enum", .@"union", .@"opaque" => if (!abi.isInjected(w.cfg, value) and !w.declares(value)) {
                        w.containers = w.containers ++ .{Type{ .T = value, .name = underscored(path), .kind = abi.kindOf(value), .path = path }};
                    },
                    else => {},
                }
            } else if (@typeInfo(V) == .@"fn") {
                if (std.mem.eql(u8, name, "deinit") and c.kind == .handle) continue; // called by destroy
                if (!has_class) {
                    w.skip(path, "declared in " ++ @typeName(C) ++ ", which has no Python class");
                } else if (abi.whyUnsupported(w.cfg, V)) |reason| {
                    w.skip(path, reason);
                } else {
                    w.functions = w.functions ++ .{Function{
                        .container = C,
                        .name = name,
                        .path = path,
                        .symbol = underscored(w.cfg.prefix ++ "_" ++ path),
                    }};
                }
            } else if (has_class and abi.kindOf(V).isData() and abi.handlesIn(V).len == 0 and
                @typeInfo(@TypeOf(&@field(C, name))).pointer.attrs.@"const")
            {
                w.constants = w.constants ++ .{Constant{ .container = C, .name = name }};
            }
        }
    }

    /// Skips functions Python could never call, until every remaining one
    /// can be: ones using a handle the API does not declare (e.g.
    /// `*std.Io.Writer`), and ones taking a handle no exported function
    /// returns.
    fn dropUncallable(w: *Walker) void {
        while (true) {
            var kept: []const Function = &.{};
            for (w.functions) |f| {
                if (w.whyUncallable(f)) |reason| w.skip(f.path, reason) else kept = kept ++ .{f};
            }
            if (kept.len == w.functions.len) return;
            w.functions = kept;
        }
    }

    fn whyUncallable(w: *Walker, comptime f: Function) ?[]const u8 {
        const F = @TypeOf(@field(f.container, f.name));
        for (abi.visibleParams(w.cfg, F)) |P| for (abi.handlesIn(P)) |H| {
            if (!w.declares(H)) return "uses " ++ @typeName(H) ++ ", which the API does not declare";
            if (!w.obtainable(H)) return "takes a " ++ @typeName(H) ++ ", which no exported function returns";
        };
        for (abi.handlesIn(abi.Payload(@typeInfo(F).@"fn".return_type.?))) |H| {
            if (!w.declares(H)) return "uses " ++ @typeName(H) ++ ", which the API does not declare";
        }
        return null;
    }

    /// Returned by an exported function, directly or as the `interface` of
    /// a returned handle.
    fn obtainable(w: *Walker, comptime H: type) bool {
        for (w.functions) |f| {
            const T = abi.Payload(@typeInfo(@TypeOf(@field(f.container, f.name))).@"fn".return_type.?);
            if (T == H) return true;
            if (abi.kindOf(T) == .handle and abi.InterfaceOf(T) == H) return true;
        }
        return false;
    }

    fn declares(w: *Walker, comptime T: type) bool {
        for (w.containers) |c| if (c.T == T) return true;
        return false;
    }

    /// Adds the class of `T` to the Python types, after the types it is
    /// built from. `hint` names anonymous types after the field holding them.
    fn need(w: *Walker, comptime T: type, comptime hint: ?[]const u8) void {
        const kind = abi.kindOf(T);
        if (kind == .handle and @typeInfo(T) == .pointer) return w.need(abi.HandleOf(T).?, null);
        switch (kind) {
            .optional => return w.need(@typeInfo(T).optional.child, hint),
            .slice => return w.need(@typeInfo(T).pointer.child, hint),
            .@"enum", .value, .@"union", .handle => {},
            else => return,
        }
        for (w.types) |t| if (t.T == T) return;

        const name = w.className(T, hint);
        switch (kind) {
            .value => for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field, F| {
                w.need(F, name ++ "_" ++ field);
            },
            .@"union" => for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |field, F| {
                w.need(F, name ++ "_" ++ field);
            },
            .handle => if (abi.InterfaceOf(T)) |I| w.need(I, null),
            else => {},
        }
        w.types = w.types ++ .{Type{ .T = T, .name = name, .kind = kind, .path = w.pathOf(T) }};
    }

    /// Declaration path, else the field hint for anonymous types, else the
    /// enclosing types and the name, without the file: "Detector.BoundaryDetector.Config"
    /// is "BoundaryDetector_Config", "math.Ray" is "Ray".
    fn className(w: *Walker, comptime T: type, comptime hint: ?[]const u8) []const u8 {
        for (w.containers[1..]) |c| if (c.T == T) return c.name;
        const full = @typeName(T);
        if (hint) |h| for ([_][]const u8{ "__struct_", "__union_", "__enum_" }) |marker| {
            if (std.mem.indexOf(u8, full, marker) != null) return h;
        };
        const first_dot = std.mem.indexOfScalar(u8, full, '.') orelse return full;
        var start = std.mem.lastIndexOfScalar(u8, full, '.').? + 1;
        while (start > first_dot + 1) {
            const dot = std.mem.lastIndexOfScalar(u8, full[0 .. start - 1], '.').?;
            if (!std.ascii.isUpper(full[dot + 1])) break;
            start = dot + 1;
        }
        return underscored(full[start..]);
    }

    fn pathOf(w: *Walker, comptime T: type) []const u8 {
        for (w.containers[1..]) |c| if (c.T == T) return c.path;
        return "";
    }

    fn isSkipped(w: *Walker, comptime path: []const u8) bool {
        for (w.cfg.skip) |s| if (std.mem.eql(u8, s, path)) return true;
        return false;
    }

    fn skip(w: *Walker, comptime path: []const u8, comptime reason: []const u8) void {
        w.skipped = w.skipped ++ .{Skipped{ .path = path, .reason = reason }};
    }

    /// Symbols, Python class names and error class names must not collide.
    fn checkNames(w: *Walker) void {
        for (w.functions, 0..) |a, i| for (w.functions[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.symbol, b.symbol)) {
                @compileError("bindgen: " ++ a.path ++ " and " ++ b.path ++ " both export " ++ a.symbol);
            }
        };
        for (w.types, 0..) |a, i| for (w.types[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError("bindgen: " ++ @typeName(a.T) ++ " and " ++ @typeName(b.T) ++ " are both named " ++ a.name ++ " in Python");
            }
        };
        for (w.cfg.errors) |e| {
            const name = @errorName(e);
            for (bindgen.builtin_errors) |b| if (std.mem.eql(u8, b, name)) {
                @compileError("bindgen: error." ++ name ++ " is built in, remove it from config.errors");
            };
            for (w.types) |t| if (std.mem.eql(u8, name, t.name)) {
                @compileError("bindgen: error." ++ name ++ " and type " ++ name ++ " have the same Python name");
            };
        }
    }

    fn finish(w: *Walker) Api {
        const functions = w.functions[0..w.functions.len].*;
        const types = w.types[0..w.types.len].*;
        const constants = w.constants[0..w.constants.len].*;
        const skipped = w.skipped[0..w.skipped.len].*;
        return .{
            .root = w.root,
            .functions = &functions,
            .types = &types,
            .constants = &constants,
            .skipped = &skipped,
        };
    }
};

fn underscored(comptime path: []const u8) [:0]const u8 {
    return comptime blk: {
        var out: [path.len:0]u8 = undefined;
        for (path, 0..) |c, i| out[i] = if (c == '.') '_' else c;
        const final = out;
        break :blk &final;
    };
}

test collect {
    const api = struct {
        pub const Color = enum { red, green };
        pub const Vec = struct {
            x: f64,
            pub const zero: Vec = .{ .x = 0 };
            pub fn len(self: Vec) f64 {
                return self.x;
            }
        };
        pub const Canvas = struct {
            gpa: std.mem.Allocator,
            pub fn init(gpa: std.mem.Allocator) Canvas {
                return .{ .gpa = gpa };
            }
            pub fn deinit(_: *Canvas) void {}
            pub fn color(_: Canvas, _: Brush, _: ?Shape) Color {
                return .red;
            }
        };
        pub const Orphan = struct {
            items: std.ArrayList(u8),
            pub fn size(self: *const Orphan) usize {
                return self.items.items.len;
            }
        };
        /// Not declared at the root, still needed by `Canvas.color`.
        const Brush = struct { size: f32, tip: struct { round: bool } };
        const Shape = union(enum) { dot, line: Vec };
        pub fn generic(x: anytype) void {
            _ = x;
        }
        pub fn hidden() void {}
    };
    const result = comptime collect(api, .{ .prefix = "t", .skip = &.{"hidden"} });

    try std.testing.expectEqual(3, result.functions.len);
    try std.testing.expectEqualStrings("t_Vec_len", result.functions[0].symbol);
    try std.testing.expectEqualStrings("t_Canvas_init", result.functions[1].symbol);
    try std.testing.expectEqualStrings("t_Canvas_color", result.functions[2].symbol);

    try std.testing.expectEqual(6, result.types.len); // Color, Vec, Canvas, Brush_tip, Brush, Shape
    try std.testing.expectEqualStrings("Brush", comptime result.typeName(api.Brush));
    try std.testing.expectEqualStrings("Brush_tip", comptime result.typeName(@FieldType(api.Brush, "tip")));
    try std.testing.expectEqualStrings("Shape", comptime result.typeName(api.Shape));
    try std.testing.expectEqual(1, result.constants.len);

    try std.testing.expectEqual(3, result.skipped.len);
    try std.testing.expectEqualStrings("Orphan.size", result.skipped[2].path);
}

test "shortest path names" {
    const api = struct {
        pub const Inner = struct {
            pub const Point = struct { x: f64 };
        };
        pub const Point = Inner.Point;
    };
    const result = comptime collect(api, .{ .prefix = "t" });
    try std.testing.expectEqualStrings("Point", comptime result.typeName(api.Point));
}

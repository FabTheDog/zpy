//! Small API exercising every supported mapping, used by
//! `tests/python/test_fixture.py` through `zig build test-python`.

const std = @import("std");
const bindgen = @import("bindgen");

pub const api = struct {
    pub const Color = enum { red, green, blue };
    pub const Level = enum(c_int) { low = -1, high = 10 };

    pub const answer: i32 = 42;

    /// A point in the plane.
    pub const Vec2 = struct {
        x: f64,
        y: f64 = 0.5,

        pub const zero: Vec2 = .{ .x = 0, .y = 0 };

        pub fn init(x: f64, y: f64) Vec2 {
            return .{ .x = x, .y = y };
        }

        pub fn add(a: Vec2, b: Vec2) Vec2 {
            return .{ .x = a.x + b.x, .y = a.y + b.y };
        }

        /// Euclidean norm.
        pub fn length(self: Vec2) f64 {
            return @sqrt(self.x * self.x + self.y * self.y);
        }
    };

    pub const Rgb = extern struct { r: u8, g: u8, b: u8 };

    pub const Shape = union(enum) {
        dot,
        circle: f64,
        rect: Rect,
        poly: struct { sides: u32 = 3 },

        pub const Rect = struct { w: f64, h: f64 };

        pub fn area(self: Shape) f64 {
            return switch (self) {
                .dot, .poly => 0,
                .circle => |r| std.math.pi * r * r,
                .rect => |r| r.w * r.h,
            };
        }
    };

    pub const Brush = struct {
        color: Color = .green,
        size: f32 = 1.0,
        origin: Vec2 = .{ .x = 0, .y = 0 },
        rgb: Rgb,
        shape: ?Shape = null,
        tip: Shape = .{ .poly = .{} },
    };

    /// Strokes drawn with brushes.
    pub const Canvas = struct {
        gpa: std.mem.Allocator,
        strokes: std.ArrayList(Vec2) = .empty,
        last_color: Color = .red,
        name_len: usize,

        /// Fails when `name` is longer than 8 bytes.
        pub fn init(gpa: std.mem.Allocator, name: [:0]const u8) error{NameTooLong}!Canvas {
            if (name.len > 8) return error.NameTooLong;
            return .{ .gpa = gpa, .name_len = name.len };
        }

        pub fn deinit(self: *Canvas) void {
            self.strokes.deinit(self.gpa);
        }

        pub fn stroke(self: *Canvas, brush: Brush, to: Vec2) error{ OutOfMemory, OutOfBounds }!void {
            if (@abs(to.x) > 100 or @abs(to.y) > 100) return error.OutOfBounds;
            try self.strokes.append(self.gpa, brush.origin.add(to));
            self.last_color = brush.color;
        }

        pub fn count(self: *const Canvas) usize {
            return self.strokes.items.len;
        }

        pub fn last(self: Canvas) error{Empty}!Vec2 {
            return self.strokes.getLastOrNull() orelse error.Empty;
        }

        pub fn lastColor(self: *const Canvas) Color {
            return self.last_color;
        }

        pub fn nameLength(self: *const Canvas) usize {
            return self.name_len;
        }
    };

    /// Refers to a canvas without owning it.
    pub const Stamp = struct {
        canvas: *const Canvas,
        scale: f64 = 1,
    };

    pub fn stampedCount(stamp: Stamp) f64 {
        return @as(f64, @floatFromInt(stamp.canvas.count())) * stamp.scale;
    }

    /// Keeps `text` without copying it.
    pub const Label = struct {
        text: []const u8,

        pub fn init(text: []const u8) Label {
            return .{ .text = text };
        }

        pub fn checksum(self: *const Label) u32 {
            var total: u32 = 0;
            for (self.text) |c| total +%= c;
            return total;
        }
    };

    /// Interface implemented by `Tally`, the way `std.Io.Writer` is.
    pub const Counter = struct {
        vtable: *const VTable,

        pub const VTable = struct {
            add: *const fn (self: *Counter, n: u32) u32,
        };
    };

    pub const Tally = struct {
        interface: Counter = .{ .vtable = &.{ .add = addTo } },
        sum: u32 = 0,

        pub fn init() Tally {
            return .{};
        }

        pub fn total(self: *const Tally) u32 {
            return self.sum;
        }

        fn addTo(counter: *Counter, n: u32) u32 {
            const self: *Tally = @alignCast(@fieldParentPtr("interface", counter));
            self.sum += n;
            return self.sum;
        }
    };

    /// Adds `n` through any `Counter`.
    pub fn feed(counter: *Counter, n: u32) u32 {
        return counter.vtable.add(counter, n);
    }

    pub const Context = struct { magic: u32 };

    pub fn add(a: i32, b: i32) i32 {
        return a +% b;
    }

    pub fn divide(numerator: f64, denominator: f64) error{DivisionByZero}!f64 {
        if (denominator == 0) return error.DivisionByZero;
        return numerator / denominator;
    }

    pub fn mix(a: Color, b: Color) Color {
        return @fromBackingInt((@backingInt(a) +% @backingInt(b)) % 3);
    }

    pub fn levelValue(level: Level) c_int {
        return @backingInt(level);
    }

    pub fn isPositive(x: i64) bool {
        return x > 0;
    }

    pub fn half(x: ?f64) ?f64 {
        return if (x) |v| v / 2 else null;
    }

    pub fn widest(shapes: []const Shape) ?Shape {
        var best: ?Shape = null;
        for (shapes) |s| {
            if (best == null or s.area() > best.?.area()) best = s;
        }
        return best;
    }

    pub fn sum(xs: []const f64) f64 {
        var total: f64 = 0;
        for (xs) |x| total += x;
        return total;
    }

    pub fn byteSum(data: []const u8) u32 {
        var total: u32 = 0;
        for (data) |c| total += c;
        return total;
    }

    pub fn totalLength(words: []const []const u8) usize {
        var total: usize = 0;
        for (words) |w| total += w.len;
        return total;
    }

    pub fn countColor(colors: []const Color, color: Color) usize {
        var n: usize = 0;
        for (colors) |c| n += @intFromBool(c == color);
        return n;
    }

    pub fn centroid(points: []const Vec2) error{Empty}!Vec2 {
        if (points.len == 0) return error.Empty;
        var c: Vec2 = Vec2.zero;
        for (points) |p| c = c.add(p);
        const n: f64 = @floatFromInt(points.len);
        return .{ .x = c.x / n, .y = c.y / n };
    }

    pub fn magic(ctx: Context, x: u32) u32 {
        return ctx.magic + x;
    }

    pub fn cwdAccessible(io: std.Io) bool {
        std.Io.Dir.cwd().access(io, ".", .{}) catch return false;
        return true;
    }

    pub fn generic(x: anytype) void {
        _ = x;
    }

    pub fn mutable(buffer: []u8) void {
        _ = buffer;
    }

    pub fn hidden() void {}
};

fn context() api.Context {
    return .{ .magic = 7 };
}

pub const config: bindgen.Config = .{
    .prefix = "fixture",
    .errors = &.{ error.DivisionByZero, error.NameTooLong, error.OutOfBounds, error.Empty },
    .skip = &.{"hidden"},
    .inject = &.{.of(context)},
};

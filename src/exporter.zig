//! Exports one C-ABI thunk per function collected by `walk`. Every thunk has
//! the same signature:
//!
//!     c_int prefix_Container_fn(Frame *frame)
//!
//! where `Frame` (see `abi.Frame`) holds the arguments and the result slot.
//! The thunk converts the arguments (`abi.fromAbi`), fills in the injected
//! ones, calls the Zig function, writes the result and returns a status code.
//!
//! Handle types also get `prefix_Type__destroy(void *handle)`, and
//! `prefix_Type__interface(void *handle, void **out)` when they implement an
//! interface (see `abi.InterfaceOf`). `prefix__abi_hash()` returns the hash
//! the Python module checks at import.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const walk = @import("walk.zig");
const bindgen = @import("bindgen.zig");
const Config = bindgen.Config;
const code = bindgen.code;

/// Allocator of the binding layer, also passed to `std.mem.Allocator` parameters.
pub const gpa: std.mem.Allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;

pub inline fn exportAll(comptime root: type, comptime cfg: Config) void {
    const api = comptime walk.collect(root, cfg);
    comptime checkErrors(api, cfg);
    inline for (api.functions) |f| {
        @export(&Thunk(cfg, @field(f.container, f.name)).call, .{ .name = f.symbol });
    }
    inline for (api.types) |t| if (t.kind == .handle) {
        @export(&Destroy(cfg, t.T).call, .{ .name = api.destroySymbol(cfg, t.T) });
        if (abi.InterfaceOf(t.T) != null) {
            @export(&Interface(t.T).call, .{ .name = api.interfaceSymbol(cfg, t.T) });
        }
    };
    @export(&Hash(api.hash(cfg)).call, .{ .name = walk.Api.hashSymbol(cfg) });
}

/// The C function for `f`.
fn Thunk(comptime cfg: Config, comptime f: anytype) type {
    const F = @TypeOf(f);
    const info = @typeInfo(F).@"fn";
    const T = abi.Payload(info.return_type.?);

    return struct {
        fn call(frame_ptr: ?*abi.Frame(cfg, F)) callconv(.c) c_int {
            const frame = frame_ptr orelse return code.invalid_argument;
            // Holds converted slices until the call returns.
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();

            var args: std.meta.ArgsTuple(F) = undefined;
            comptime var n = 0;
            inline for (info.param_types, 0..) |P, i| {
                if (comptime abi.isInjected(cfg, P.?)) {
                    args[i] = inject(cfg, P.?);
                } else {
                    const a = @field(frame, std.fmt.comptimePrint("a{d}", .{n}));
                    args[i] = abi.fromAbi(P.?, a, arena.allocator()) catch |err| return errorCode(cfg, err);
                    n += 1;
                }
            }

            if (comptime abi.kindOf(T) == .handle) {
                // Boxed before the call, so a failed allocation cannot leak the result.
                const box = gpa.create(T) catch return code.out_of_memory;
                box.* = invoke(f, args) catch |err| {
                    gpa.destroy(box);
                    return errorCode(cfg, err);
                };
                frame.out = box;
            } else {
                const value = invoke(f, args) catch |err| return errorCode(cfg, err);
                if (T != void) frame.out = abi.toAbi(T, value);
            }
            return code.ok;
        }
    };
}

/// `f(args...)` as an error union, whatever `f` returns.
fn invoke(comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) anyerror!abi.Payload(@typeInfo(@TypeOf(f)).@"fn".return_type.?) {
    return @call(.auto, f, args);
}

/// Frees a handle, calling its `deinit` first when it has one.
fn Destroy(comptime cfg: Config, comptime T: type) type {
    return struct {
        fn call(handle: ?*anyopaque) callconv(.c) c_int {
            const ptr: *T = @ptrCast(@alignCast(handle orelse return code.ok));
            defer gpa.destroy(ptr);
            if (!@hasDecl(T, "deinit")) return code.ok;

            const info = @typeInfo(@TypeOf(T.deinit)).@"fn";
            var args: std.meta.ArgsTuple(@TypeOf(T.deinit)) = undefined;
            inline for (info.param_types, 0..) |P, i| {
                if (i == 0) {
                    args[0] = if (P.? == T) ptr.* else ptr;
                } else if (comptime abi.isInjected(cfg, P.?)) {
                    args[i] = inject(cfg, P.?);
                } else {
                    @compileError("bindgen: cannot fill parameter " ++ std.fmt.comptimePrint("{d}", .{i}) ++ " of " ++ @typeName(T) ++ ".deinit");
                }
            }
            invoke(T.deinit, args) catch |err| return errorCode(cfg, err);
            return code.ok;
        }
    };
}

/// Writes `&handle.interface` to `out`.
fn Interface(comptime H: type) type {
    return struct {
        fn call(handle: ?*anyopaque, out: ?*anyopaque) callconv(.c) c_int {
            const ptr: *H = @ptrCast(@alignCast(handle orelse return code.invalid_argument));
            const slot: **anyopaque = @ptrCast(@alignCast(out orelse return code.invalid_argument));
            slot.* = &ptr.interface;
            return code.ok;
        }
    };
}

fn Hash(comptime value: u64) type {
    return struct {
        fn call() callconv(.c) u64 {
            return value;
        }
    };
}

fn inject(comptime cfg: Config, comptime P: type) P {
    if (P == std.mem.Allocator) return gpa;
    if (P == std.Io) return io();
    inline for (cfg.inject) |i| if (i.T == P) {
        const provide: *const fn () P = @ptrCast(@alignCast(i.provide));
        return provide();
    };
    comptime unreachable;
}

var threaded: std.Io.Threaded = undefined;
var threaded_state: std.atomic.Value(u8) = .init(0); // 0: none, 1: initializing, 2: ready

/// `std.Io` of the binding layer, created on first use so Python processes
/// that never need it keep their signal handlers untouched.
fn io() std.Io {
    if (threaded_state.load(.acquire) != 2) {
        if (threaded_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
            threaded = .init(gpa, .{});
            threaded_state.store(2, .release);
        } else while (threaded_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return threaded.io();
}

fn errorCode(comptime cfg: Config, err: anyerror) c_int {
    if (err == error.InvalidArgument) return code.invalid_argument;
    if (err == error.OutOfMemory) return code.out_of_memory;
    inline for (cfg.errors, 1..) |e, i| if (err == e) return i;
    return code.unexpected;
}

/// Every error an exported function or `deinit` can return must have a code.
fn checkErrors(comptime api: walk.Api, comptime cfg: Config) void {
    for (api.functions) |f| checkReturn(cfg, @TypeOf(@field(f.container, f.name)), f.path);
    for (api.types) |t| if (t.kind == .handle and @hasDecl(t.T, "deinit")) {
        checkReturn(cfg, @TypeOf(t.T.deinit), @typeName(t.T) ++ ".deinit");
    };
}

fn checkReturn(comptime cfg: Config, comptime F: type, comptime path: []const u8) void {
    const R = @typeInfo(F).@"fn".return_type.?;
    if (@typeInfo(R) != .error_union) return;
    const names = @typeInfo(@typeInfo(R).error_union.error_set).error_set.error_names orelse
        @compileError("bindgen: " ++ path ++ " returns anyerror");
    outer: for (names) |name| {
        for (bindgen.builtin_errors) |b| if (std.mem.eql(u8, b, name)) continue :outer;
        for (cfg.errors) |e| if (std.mem.eql(u8, @errorName(e), name)) continue :outer;
        @compileError("bindgen: " ++ path ++ " can return error." ++ name ++ ", append it to config.errors");
    }
}

test "thunks convert arguments and errors" {
    const api = struct {
        pub const Color = enum { red, green, blue };
        pub const Vec = struct { x: f64, y: f64 };
        pub fn scale(v: Vec, k: f64) Vec {
            return .{ .x = v.x * k, .y = v.y * k };
        }
        pub fn next(c: Color) error{Last}!Color {
            return switch (c) {
                .red => .green,
                .green => .blue,
                .blue => error.Last,
            };
        }
    };
    const cfg: Config = .{ .prefix = "t", .errors = &.{error.Last} };

    const Scale = Thunk(cfg, api.scale);
    var scale: abi.Frame(cfg, @TypeOf(api.scale)) = .{ .a0 = .{ .x = 1, .y = 2 }, .a1 = 3, .out = undefined };
    try std.testing.expectEqual(code.ok, Scale.call(&scale));
    try std.testing.expectEqual(abi.Abi(api.Vec){ .x = 3, .y = 6 }, scale.out);
    try std.testing.expectEqual(code.invalid_argument, Scale.call(null));

    const Next = Thunk(cfg, api.next);
    var next: abi.Frame(cfg, @TypeOf(api.next)) = .{ .a0 = 0, .out = undefined };
    try std.testing.expectEqual(code.ok, Next.call(&next));
    try std.testing.expectEqual(1, next.out);
    next.a0 = 2;
    try std.testing.expectEqual(1, Next.call(&next)); // error.Last
    next.a0 = 3;
    try std.testing.expectEqual(code.invalid_argument, Next.call(&next));
}

test "handles are boxed and destroyed" {
    const Counter = struct {
        gpa: std.mem.Allocator,
        values: []u32,

        const Self = @This();
        pub fn init(allocator: std.mem.Allocator, n: u32) error{OutOfMemory}!Self {
            const values = try allocator.alloc(u32, n);
            @memset(values, 7);
            return .{ .gpa = allocator, .values = values };
        }
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.values);
        }
        pub fn sum(self: *const Self) u64 {
            var total: u64 = 0;
            for (self.values) |v| total += v;
            return total;
        }
    };
    const cfg: Config = .{ .prefix = "t" };

    var init: abi.Frame(cfg, @TypeOf(Counter.init)) = .{ .a0 = 3, .out = null };
    try std.testing.expectEqual(code.ok, Thunk(cfg, Counter.init).call(&init));
    var sum: abi.Frame(cfg, @TypeOf(Counter.sum)) = .{ .a0 = init.out, .out = undefined };
    try std.testing.expectEqual(code.ok, Thunk(cfg, Counter.sum).call(&sum));
    try std.testing.expectEqual(21, sum.out);
    try std.testing.expectEqual(code.ok, Destroy(cfg, Counter).call(init.out));
}

//! Python (ctypes) bindings generated from an idiomatic Zig API.
//!
//! A project provides one "bindings" module exposing `api` (the namespace to
//! export) and `config` (a `Config`). From it the build produces:
//! - a shared library whose root is `lib_root.zig`: one C-ABI thunk per
//!   exportable function, see `exporter.zig`;
//! - a ctypes module, written by `gen_main.zig` through `python.zig`.
//! Both walk the API with `walk.zig` and map types with `abi.zig`, so they
//! cannot disagree on a signature or a layout.

const std = @import("std");

pub const abi = @import("abi.zig");
pub const walk = @import("walk.zig");
pub const exporter = @import("exporter.zig");
pub const python = @import("python.zig");
pub const source = @import("source.zig");

pub const exportAll = exporter.exportAll;

pub const Config = struct {
    /// Prefix of every exported symbol.
    prefix: []const u8,
    /// Append-only: the C code of `errors[i]` is `i + 1`. Every error an
    /// exported function can return must be listed, or compilation fails,
    /// except the `builtin_errors`.
    errors: []const anyerror = &.{},
    /// Declaration paths from the API root (e.g. "Geometry.query") that are
    /// not exported.
    skip: []const []const u8 = &.{},
    /// Parameter types filled in by the library instead of Python, besides
    /// `std.mem.Allocator` and `std.Io`.
    inject: []const Injection = &.{},
};

pub const Injection = struct {
    T: type,
    /// `*const fn () T`.
    provide: *const anyopaque,

    pub fn of(comptime provide: anytype) Injection {
        return .{ .T = @typeInfo(@TypeOf(provide)).@"fn".return_type.?, .provide = &provide };
    }
};

/// Provider for `std.Io.Dir` parameters: the working directory of the process.
pub fn cwd() std.Io.Dir {
    return .cwd();
}

/// Status codes returned by every thunk besides the `Config.errors` ones.
pub const code = struct {
    pub const ok: c_int = 0;
    /// `error.InvalidArgument`, also raised by the binding layer: null
    /// pointer, enum value out of range.
    pub const invalid_argument: c_int = -1;
    /// `error.OutOfMemory`, also from an allocation of the binding layer.
    pub const out_of_memory: c_int = -2;
    /// An error missing from `Config.errors`. Cannot happen for exported
    /// functions, which are checked at compile time.
    pub const unexpected: c_int = -3;
};

/// Errors with a fixed code, see `code`; they must not be in `Config.errors`.
pub const builtin_errors = [_][]const u8{ "InvalidArgument", "OutOfMemory" };

test {
    std.testing.refAllDecls(@This());
}

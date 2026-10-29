//! Python (ctypes) bindings generated from a Zig API, see src/bindgen.zig.
//!
//! Other packages call `addPythonPackage` and `addPytest` from their build.zig
//! through `@import("zpy")`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/bindgen.zig"),
    }) });
    const test_step = b.step("test", "Run the generator tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const python = b.option([]const u8, "python", "Python interpreter for test-python (default: python3)") orelse "python3";
    const fixture = stagePackage(b, b, .{
        .name = "fixture",
        .bindings = b.path("tests/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pytest = addPytest(b, .{
        .python = python,
        .packages = &.{fixture},
        .tests = b.path("tests"),
    });
    const test_python_step = b.step("test-python", "Run the Python tests of the fixture bindings");
    test_python_step.dependOn(&pytest.step);
}

pub const PythonPackage = struct {
    /// Python package name, also the shared library name.
    name: []const u8,
    /// File exposing `api` and `config`, see src/bindgen.zig. It imports the
    /// generator as "bindgen".
    bindings: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link: []const *std.Build.Step.Compile = &.{},
};

pub const StagedPackage = struct {
    /// Directory containing the package directory, for `sys.path`.
    dir: std.Build.LazyPath,
    /// Installs the package to `zig-out/python/<name>/`.
    install: *std.Build.Step,
};

/// Builds the shared library of `package.bindings` and generates its ctypes
/// module, staged together as `<dir>/<name>/{__init__.py, lib<name>.so}`.
pub fn addPythonPackage(b: *std.Build, package: PythonPackage) StagedPackage {
    return stagePackage(b, b.dependencyFromBuildZig(@This(), .{}).builder, package);
}

/// `zpy` is the builder of this package, which resolves its sources.
fn stagePackage(b: *std.Build, zpy: *std.Build, package: PythonPackage) StagedPackage {
    const lib_mod = bindgenModule(b, zpy.path("src/lib_root.zig"), zpy, package.bindings, package.target, package.optimize);
    for (package.link) |l| lib_mod.linkLibrary(l);
    const lib = b.addLibrary(.{ .name = package.name, .root_module = lib_mod, .linkage = .dynamic });

    // The generator only reads types, so it runs on the host whatever the target.
    const gen = b.addExecutable(.{
        .name = b.fmt("{s}-pygen", .{package.name}),
        .root_module = bindgenModule(b, zpy.path("src/gen_main.zig"), zpy, package.bindings, b.graph.host, .Debug),
    });
    const gen_run = b.addRunArtifact(gen);
    const py_module = gen_run.addOutputFileArg("__init__.py");
    gen_run.addArg(lib.out_filename);
    gen_run.addDirectoryArg(package.bindings.dirname()); // parameter names and doc comments

    const staged = b.addWriteFiles();
    _ = staged.addCopyFile(py_module, b.fmt("{s}/__init__.py", .{package.name}));
    _ = staged.addCopyFile(lib.getEmittedBin(), b.fmt("{s}/{s}", .{ package.name, lib.out_filename }));

    const install = b.addInstallDirectory(.{
        .source_dir = staged.getDirectory(),
        .install_dir = .{ .custom = "python" },
        .install_subdir = "",
    });
    return .{ .dir = staged.getDirectory(), .install = &install.step };
}

pub const Pytest = struct {
    /// Python interpreter.
    python: []const u8 = "python3",
    /// Importable during the run, without being installed.
    packages: []const StagedPackage,
    /// Directory or file passed to pytest.
    tests: std.Build.LazyPath,
};

/// Runs pytest on `options.tests` with the staged packages on `sys.path`.
pub fn addPytest(b: *std.Build, options: Pytest) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        options.python, "-B", "-c",
        \\import sys
        \\n = int(sys.argv[1])
        \\sys.path[:0] = sys.argv[2:2 + n]
        \\import pytest
        \\sys.exit(pytest.main(["-q", "-p", "no:cacheprovider", *sys.argv[2 + n:]]))
    });
    run.addArg(b.fmt("{d}", .{options.packages.len}));
    for (options.packages) |p| run.addDirectoryArg(p.dir);
    run.addDirectoryArg(options.tests);
    return run;
}

/// Module rooted at `root`, importing "bindgen" and "bindings".
fn bindgenModule(
    b: *std.Build,
    root: std.Build.LazyPath,
    zpy: *std.Build,
    bindings: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const bindgen = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = zpy.path("src/bindgen.zig"),
    });
    const bindings_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = bindings,
        .imports = &.{.{ .name = "bindgen", .module = bindgen }},
    });
    return b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = root,
        .imports = &.{
            .{ .name = "bindgen", .module = bindgen },
            .{ .name = "bindings", .module = bindings_mod },
        },
    });
}

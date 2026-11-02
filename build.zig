//! Python (ctypes) bindings generated from a Zig API, see src/bindgen.zig.
//!
//! Other packages call `addPythonPackage`, `addWheel`, `addPytest` and
//! `addPythonScript` from their build.zig through `@import("zpy")`.

const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/bindgen.zig"),
    }) });
    const wheel_tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/wheel.zig"),
    }) });
    const test_step = b.step("test", "Run the generator and wheel tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(wheel_tests).step);

    const python = b.option([]const u8, "python", "Python interpreter for test-python (default: python3)") orelse "python3";
    const fixture = stagePackage(b, b, .{
        .name = "fixture",
        .bindings = b.path("tests/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_wheel = wheelFor(b, b, fixture, .{
        .version = "0.0.1",
        .summary = "Fixture of the zpy binding tests",
    });
    const wheel_step = b.step("wheel", "Build the fixture wheel into zig-out/wheels (needs -Doptimize=ReleaseFast)");
    wheel_step.dependOn(fixture_wheel.install);

    const pytest = addPytest(b, .{
        .python = python,
        .packages = &.{fixture},
        .tests = b.path("tests"),
        .wheel = fixture_wheel.file,
    });
    const test_python_step = b.step("test-python", "Run the Python tests of the fixture bindings and wheel");
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
    name: []const u8,
    /// Directory containing the package directory, for `sys.path`.
    dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    return .{
        .name = package.name,
        .dir = staged.getDirectory(),
        .target = package.target,
        .optimize = package.optimize,
        .install = &install.step,
    };
}

/// Core metadata of a wheel, one line per field.
pub const WheelMetadata = struct {
    version: []const u8,
    summary: ?[]const u8 = null,
    license: ?[]const u8 = null,
    requires_python: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

pub const Wheel = struct {
    file: std.Build.LazyPath,
    /// `<name>-<version>-py3-none-<platform>.whl`
    file_name: []const u8,
    /// Installs the wheel to `zig-out/wheels/`. Fails for Debug packages,
    /// whose library is mostly debug info.
    install: *std.Build.Step,
};

/// Packs a staged package into a wheel. The bindings use ctypes, not the
/// CPython ABI, so one wheel per platform serves every Python 3.
pub fn addWheel(b: *std.Build, package: StagedPackage, metadata: WheelMetadata) Wheel {
    return wheelFor(b, b.dependencyFromBuildZig(@This(), .{}).builder, package, metadata);
}

fn wheelFor(b: *std.Build, zpy: *std.Build, package: StagedPackage, metadata: WheelMetadata) Wheel {
    const tag = platformTag(b, package.target.result);
    const platform = tag orelse "unsupported";
    const file_name = b.fmt("{s}-{s}-py3-none-{s}.whl", .{ package.name, metadata.version, platform });

    var text: std.ArrayList(u8) = .empty;
    const fields = [_]struct { []const u8, ?[]const u8 }{
        .{ "Metadata-Version", "2.1" },
        .{ "Name", package.name },
        .{ "Version", metadata.version },
        .{ "Summary", metadata.summary },
        .{ "License", metadata.license },
        .{ "Requires-Python", metadata.requires_python },
        .{ "Author", metadata.author },
    };
    for (fields) |field| if (field[1]) |value| {
        if (std.mem.findAny(u8, value, "\r\n") != null) std.debug.panic("wheel {s} must be a single line: {s}", .{ field[0], value });
        text.print(b.allocator, "{s}: {s}\n", .{ field[0], value }) catch @panic("OOM");
    };
    const metadata_file = b.addWriteFiles().add("METADATA", text.items);

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const exe = b.addExecutable(.{
        .name = b.fmt("{s}-wheel", .{package.name}),
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = zpy.path("src/wheel_main.zig"),
            .imports = &.{.{ .name = "options", .module = options.createModule() }},
        }),
    });
    const run = b.addRunArtifact(exe);
    const file = run.addOutputFileArg(file_name);
    run.addDirectoryArg(package.dir);
    run.addArgs(&.{ package.name, metadata.version, platform });
    run.addFileArg(metadata_file);
    // Failing when the wheel is built rather than here keeps every other step
    // working on targets that have no wheel.
    if (tag == null) run.step.dependOn(&b.addFail(b.fmt(
        "no Python wheel platform tag for {s}",
        .{package.target.result.zigTriple(b.allocator) catch @panic("OOM")},
    )).step);

    const install = if (package.optimize == .debug)
        &b.addFail(b.fmt("refusing to install a Debug wheel of {s}; pass -Doptimize=ReleaseFast (or ReleaseSafe, ReleaseSmall)", .{package.name})).step
    else
        &b.addInstallFileWithDir(file, .{ .custom = "wheels" }, file_name).step;
    return .{ .file = file, .file_name = file_name, .install = install };
}

/// Platform tag of a wheel for `t`, see
/// https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/
fn platformTag(b: *std.Build, t: std.Target) ?[]const u8 {
    switch (t.os.tag) {
        .linux => {
            const arch = switch (t.cpu.arch) {
                .x86 => "i686",
                .powerpc64le => "ppc64le",
                else => @tagName(t.cpu.arch),
            };
            if (t.abi.isGnu()) {
                const glibc = t.os.version_range.linux.glibc;
                return b.fmt("manylinux_{d}_{d}_{s}", .{ glibc.major, glibc.minor, arch });
            }
            if (t.abi.isMusl()) return b.fmt("musllinux_1_2_{s}", .{arch});
        },
        .macos => {
            const min = t.os.version_range.semver.min;
            switch (t.cpu.arch) {
                .aarch64 => return b.fmt("macosx_{d}_{d}_arm64", .{ min.major, min.minor }),
                .x86_64 => return b.fmt("macosx_{d}_{d}_x86_64", .{ min.major, min.minor }),
                else => {},
            }
        },
        .windows => switch (t.cpu.arch) {
            .x86_64 => return "win_amd64",
            .aarch64 => return "win_arm64",
            .x86 => return "win32",
            else => {},
        },
        else => {},
    }
    return null;
}

pub const Pytest = struct {
    /// Python interpreter.
    python: []const u8 = "python3",
    /// Importable during the run, without being installed.
    packages: []const StagedPackage,
    /// Directory or file passed to pytest.
    tests: std.Build.LazyPath,
    /// Passed to pytest as `--wheel=<path>`, for tests/conftest.py.
    wheel: ?std.Build.LazyPath = null,
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
    if (options.wheel) |wheel| run.addPrefixedFileArg("--wheel=", wheel);
    return run;
}

pub const PythonScript = struct {
    python: []const u8 = "python3",
    /// Importable by the script, without being installed.
    packages: []const StagedPackage,
    script: std.Build.LazyPath,
};

/// Runs `options.script` as `__main__` with the staged packages on `sys.path`.
pub fn addPythonScript(b: *std.Build, options: PythonScript) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        options.python, "-B", "-c",
        \\import runpy, sys
        \\n = int(sys.argv[1])
        \\sys.path[:0] = sys.argv[2:2 + n]
        \\runpy.run_path(sys.argv[2 + n], run_name="__main__")
    });
    run.addArg(b.fmt("{d}", .{options.packages.len}));
    for (options.packages) |p| run.addDirectoryArg(p.dir);
    run.addFileArg(options.script);
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

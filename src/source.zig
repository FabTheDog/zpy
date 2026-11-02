//! Parameter names and doc comments of the API, read from its Zig sources:
//! `@typeInfo` has neither. A type is found from its `@typeName`, which is the
//! path of its file relative to the module root followed by its declaration
//! path, e.g. "math.Vec3" is `Vec3` in math.zig.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Root directory of the module declaring the API.
    dir: std.Io.Dir,
    /// Parsed files by path, null when missing or unreadable.
    files: std.StringHashMapUnmanaged(?*const Ast) = .empty,

    pub const Fn = struct {
        /// One per parameter, "_" when unnamed.
        params: []const []const u8,
        doc: ?[]const u8,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Index {
        return .{ .arena = .init(gpa), .io = io, .dir = dir };
    }

    pub fn deinit(index: *Index) void {
        index.arena.deinit();
    }

    pub fn typeDoc(index: *Index, type_name: []const u8) ?[]const u8 {
        const container = index.findContainer(type_name) orelse return null;
        return container.doc;
    }

    pub fn fnDoc(index: *Index, type_name: []const u8, fn_name: []const u8) ?Fn {
        const container = index.findContainer(type_name) orelse return null;
        return index.fnIn(container, fn_name);
    }

    /// Doc comment of a struct field, a union variant or an enum member.
    pub fn fieldDoc(index: *Index, type_name: []const u8, field_name: []const u8) ?[]const u8 {
        const container = index.findContainer(type_name) orelse return null;
        const tree = container.tree;
        for (container.members) |node| {
            const field = tree.fullContainerField(node) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(field.ast.main_token), field_name)) {
                return index.doc(tree, field.firstToken());
            }
        }
        return null;
    }

    const Container = struct {
        tree: *const Ast,
        /// File of `tree`, relative to `Index.dir`.
        path: []const u8,
        members: []const Ast.Node.Index,
        doc: ?[]const u8,
    };

    /// Follows re-exports such as `pub const mergeCsv = sinks.mergeCsv;`.
    /// Zig rejects declaration cycles, so this terminates.
    fn fnIn(index: *Index, container: Container, fn_name: []const u8) ?Fn {
        const tree = container.tree;
        for (container.members) |node| {
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buffer, node)) |proto| {
                const name_token = proto.name_token orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), fn_name)) continue;
                var params: std.ArrayList([]const u8) = .empty;
                var it = proto.iterate(tree);
                while (it.next()) |param| {
                    const name = if (param.name_token) |t| tree.tokenSlice(t) else "_";
                    params.append(index.arena.allocator(), name) catch return null;
                }
                return .{ .params = params.items, .doc = index.doc(tree, proto.firstToken()) };
            }
            const decl = tree.fullVarDecl(node) orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), fn_name)) continue;
            const init_node = decl.ast.init_node.unwrap() orelse return null;
            if (tree.nodeTag(init_node) != .field_access) return null;
            const lhs, const rhs = tree.nodeData(init_node).node_and_token;
            const target = index.resolve(container, lhs) orelse return null;
            return index.fnIn(target, tree.tokenSlice(rhs));
        }
        return null;
    }

    /// The container an expression names: an identifier declared in `scope`
    /// or its file, a field of one, `@import("file.zig")` or a container literal.
    fn resolve(index: *Index, scope: Container, node: Ast.Node.Index) ?Container {
        const tree = scope.tree;
        switch (tree.nodeTag(node)) {
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                return index.declared(scope, scope.members, name) orelse
                    index.declared(scope, tree.rootDecls(), name);
            },
            .field_access => {
                const lhs, const rhs = tree.nodeData(node).node_and_token;
                const parent = index.resolve(scope, lhs) orelse return null;
                return index.declared(parent, parent.members, tree.tokenSlice(rhs));
            },
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
                var buffer: [2]Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&buffer, node) orelse return null;
                if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return null;
                const literal = tree.tokenSlice(tree.nodeMainToken(params[0]));
                const import = literal[1 .. literal.len - 1];
                if (!std.mem.endsWith(u8, import, ".zig")) return null; // a module, not a file
                const dir = std.fs.path.dirname(scope.path) orelse "";
                const path = std.fs.path.join(index.arena.allocator(), &.{ dir, import }) catch return null;
                const imported = index.file(path) orelse return null;
                return .{ .tree = imported, .path = path, .members = imported.rootDecls(), .doc = index.doc(imported, 0) };
            },
            else => return null,
        }
    }

    /// Tries the longest file path first: "Geometry.Assembly" is either
    /// Geometry/Assembly.zig or `Assembly` in Geometry.zig.
    fn findContainer(index: *Index, type_name: []const u8) ?Container {
        const arena = index.arena.allocator();
        var segments: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, type_name, '.');
        while (it.next()) |segment| segments.append(arena, segment) catch return null;

        var k = segments.items.len;
        while (k > 0) : (k -= 1) {
            const joined = std.mem.join(arena, "/", segments.items[0..k]) catch return null;
            const path = std.mem.concat(arena, u8, &.{ joined, ".zig" }) catch return null;
            const tree = index.file(path) orelse continue;
            var container: Container = .{ .tree = tree, .path = path, .members = tree.rootDecls(), .doc = index.doc(tree, 0) };
            for (segments.items[k..]) |name| {
                container = index.declared(container, container.members, name) orelse return null;
            }
            return container;
        }
        return null;
    }

    fn file(index: *Index, path: []const u8) ?*const Ast {
        if (index.files.get(path)) |tree| return tree;
        const tree = index.parse(path);
        const arena = index.arena.allocator();
        const key = arena.dupe(u8, path) catch return null;
        index.files.put(arena, key, tree) catch return null;
        return tree;
    }

    fn parse(index: *Index, path: []const u8) ?*const Ast {
        const arena = index.arena.allocator();
        const text = index.dir.readFileAllocOptions(index.io, path, arena, .limited(16 << 20), .of(u8), 0) catch return null;
        const tree = arena.create(Ast) catch return null;
        tree.* = Ast.parse(arena, text, .{}) catch return null;
        return tree;
    }

    /// The container declared as `name` among `members`, which belong to
    /// the file of `scope`.
    fn declared(index: *Index, scope: Container, members: []const Ast.Node.Index, name: []const u8) ?Container {
        const tree = scope.tree;
        for (members) |node| {
            const decl = tree.fullVarDecl(node) orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
            const init_node = decl.ast.init_node.unwrap() orelse return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&buffer, init_node) orelse
                return index.resolve(scope, init_node);
            // Small containers keep their members in `buffer`.
            const decls = index.arena.allocator().dupe(Ast.Node.Index, container.ast.members) catch return null;
            return .{ .tree = tree, .path = scope.path, .members = decls, .doc = index.doc(tree, decl.firstToken()) };
        }
        return null;
    }

    /// The `///` comments right before `token`, or for token 0 the `//!`
    /// comments opening the file.
    fn doc(index: *Index, tree: *const Ast, token: Ast.TokenIndex) ?[]const u8 {
        var start = token;
        var end = token;
        if (token == 0) {
            while (tree.tokenTag(end) == .container_doc_comment) end += 1;
        } else {
            while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) start -= 1;
        }
        if (start == end) return null;
        var text: std.ArrayList(u8) = .empty;
        const arena = index.arena.allocator();
        var i = start;
        while (i < end) : (i += 1) {
            const line = tree.tokenSlice(i)[3..]; // "///" or "//!"
            if (i > start) text.append(arena, '\n') catch return null;
            text.appendSlice(arena, if (std.mem.startsWith(u8, line, " ")) line[1..] else line) catch return null;
        }
        return text.items;
    }
};

test Index {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "math.zig", .data =
        \\//! Vectors.
        \\
        \\/// A point in space.
        \\/// In meters.
        \\pub const Vec3 = struct {
        \\    x: f64,
        \\    /// Up.
        \\    y: f64 = 0,
        \\
        \\    /// Scales by `k`.
        \\    pub fn mul(self: Vec3, k: f64) Vec3 {
        \\        return .{ .x = self.x * k };
        \\    }
        \\};
        \\
    });

    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data =
        \\const math = @import("math.zig");
        \\pub const scale = math.Vec3.mul;
        \\
    });

    var index: Index = .init(std.testing.allocator, io, tmp.dir);
    defer index.deinit();
    try std.testing.expectEqualStrings("Vectors.", index.typeDoc("math").?);
    try std.testing.expectEqualStrings("A point in space.\nIn meters.", index.typeDoc("math.Vec3").?);
    const mul = index.fnDoc("math.Vec3", "mul").?;
    try std.testing.expectEqualStrings("Scales by `k`.", mul.doc.?);
    try std.testing.expectEqual(2, mul.params.len);
    try std.testing.expectEqualStrings("k", mul.params[1]);
    try std.testing.expectEqual(null, index.fnDoc("math.Vec3", "missing"));
    try std.testing.expectEqualStrings("Up.", index.fieldDoc("math.Vec3", "y").?);
    try std.testing.expectEqual(null, index.fieldDoc("math.Vec3", "x"));
    try std.testing.expectEqual(null, index.fieldDoc("math.Vec3", "mul"));
    try std.testing.expectEqualStrings("Scales by `k`.", index.fnDoc("root", "scale").?.doc.?);
    try std.testing.expectEqual(null, index.typeDoc("other.Vec3"));
    try std.testing.expectEqual(null, index.typeDoc("root"));
}

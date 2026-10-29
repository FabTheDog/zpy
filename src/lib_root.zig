//! Root of the shared library loaded by the generated Python module.

const bindgen = @import("bindgen");
const bindings = @import("bindings");

comptime {
    bindgen.exportAll(bindings.api, bindings.config);
}

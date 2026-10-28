package js

// The census of the Odin engine's heap (src/engine/jsrt/memprof.odin) read from a realm: `wj_heap_profile`, a
// development aid for memory work (jsengine mem; WREN_JS_MEMPROF=1 in jsdomtest). Engines without it print nothing.

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:wasm"

// jsrt's Prof_Row, in order
PROF_ROWS := [?]string{"str_flat8", "str_flat16", "str_rope", "symbol", "bigint", "shape", "shape_dict", "obj_plain", "obj_array",
	"obj_function", "obj_native", "obj_bound", "obj_arguments", "obj_error", "obj_collection", "obj_buffer", "obj_promise",
	"obj_other", "function_bc", "bc_code", "bc_cpool", "bc_defs", "bc_source", "bc_image", "var_ref", "module", "atom_table",
	"pool_free", "pool_chunks", "runtime_misc", "arenas"}
// jsrt's Cell_Sizes, in order
PROF_SIZES := [?]string{"Object", "String", "Var_Ref", "Shape", "Function_Bytecode", "Value", "Symbol", "Array_Data", "Func_Data",
	"Native_Data", "Object_Data", "Prop_Slot"}

prof_field :: proc(inst: ^wasm.Instance, index: int) -> i64 {
	argv := [2]u32{u32(index), 0}
	if wasm.call_raw(inst, "wj_heap_profile", argv[:], 2) != .Ok { return -1 }
	return i64(transmute(f64)(u64(argv[0]) | u64(argv[1]) << 32))
}

memprof_wanted :: proc() -> bool {
	return os.get_env("WREN_JS_MEMPROF", context.temp_allocator) == "1"
}

// Prints the census of the realm (stderr), one line per kind of cell. Returns false when the engine has none.
print_profile :: proc(inst: ^wasm.Instance, label: string) -> bool {
	if !wasm.has_export(inst, "wj_heap_profile") || prof_field(inst, 0) < 0 { return false }
	b := strings.builder_make(context.temp_allocator)
	for n, i in PROF_SIZES { fmt.sbprintf(&b, " %s=%d", n, prof_field(inst, 1000 + i)) }
	fmt.eprintfln("PROF [%s] sizeof:%s; linear memory %d KiB", label, strings.to_string(b), wasm.memory_bytes(inst) / 1024)
	fmt.eprintfln("PROF %-14s %9s %11s %11s %11s", "row", "count", "cell B", "extra B", "slack B")
	tc, te, ts: i64
	for name, i in PROF_ROWS {
		n, cb, eb, sb := prof_field(inst, i * 4), prof_field(inst, i * 4 + 1), prof_field(inst, i * 4 + 2), prof_field(inst, i * 4 + 3)
		if n == 0 && cb == 0 && eb == 0 { continue }
		fmt.eprintfln("PROF %-14s %9d %11d %11d %11d", name, n, cb, eb, sb)
		if name != "pool_free" && name != "pool_chunks" && name != "runtime_misc" && name != "arenas" { tc += cb; te += eb; ts += sb }
	}
	fmt.eprintfln("PROF cells+extra %d, slack %d", tc + te, ts)
	return true
}

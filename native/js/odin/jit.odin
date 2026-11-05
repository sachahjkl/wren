// jit.odin: the loop JIT of the Odin engine (src/engine/jsrt/jit.odin) seen from the browser: the same exports the C
// engine's JIT has (wj_jit_configure, wj_jit_stat), so src/js/jit.odin and the host's Engine_jitCompile / Engine_jitPoll
// serve both. Only the Odin engine has it; with QuickJS these names come from native/js/jit/wjit.h.
package odin_glue

import "base:runtime"
import "../odin/wj"
import jsrt "wb:engine/jsrt"

// (the imports are used in both backends: an import cannot sit in a `when`)
_jit_import :: jsrt.JIT_MAX_LOOPS
_Jit_Context :: runtime.Context

when wj.WJ_JSRT {

	// The context of the helpers compiled code calls, made once (a call of compiled code to compiled code goes through
	// one: wj.heap_context() each time was a measurable part of it)
	jit_context: runtime.Context

	@(export, link_name = "wj_jit_configure")
	wj_jit_configure :: proc "c" (flags: i32, call_threshold: i32, max_functions: i32, max_bytecode_bytes: i32, loop_threshold: i32) {
		context = wj.heap_context()
		jit_context = context
		// (bit 2 of the flags, the C engine's step-only test mode, has no meaning here: the translator has no step path, and
		// its trace goes to the profile of the page's functions, never to the console, where a test compares what the scripts print)
		if max_bytecode_bytes > 0 {jsrt.jit_cfg.max_code_bytes = int(max_bytecode_bytes)}
		jsrt.jit_configure(flags & 1 != 0 && max_functions != 0, wj.wr_Engine_jitCompile, wj.wr_Engine_jitPoll, nil, int(call_threshold))
	}

	// WREN_JS_PROFILE: why code stays in the interpreter. What the JIT refuses and every deopt counted in the profile of the page's functions (wj_profile_dump).
	@(export, link_name = "wj_jit_trace")
	wj_jit_trace :: proc "c" (on: i32) {
		jsrt.jit_cfg.log = on != 0 ? proc(msg: string) { wj.prof_note(msg) } : nil
		jsrt.jit_cfg.trace = on != 0
	}

	@(export, link_name = "wj_jit_stat")
	wj_jit_stat :: proc "c" (which: i32) -> f64 {
		return jsrt.jit_stat(int(which))
	}

	// The helpers compiled code calls (jsrt.JIT_HELPERS): the call's jsrt.Jit_Call_Result; 1 when the array changed kind.
	@(export, link_name = "wj_jit_call")
	wj_jit_call :: proc "c" (f: ^jsrt.Frame, sp: i32, argc: i32, kind: i32, pc: i32) -> i32 {
		context = jit_context
		return i32(jsrt.jit_call(f, int(sp), int(argc), jsrt.Jit_Call_Kind(kind), int(pc)))
	}

	@(export, link_name = "wj_jit_finish")
	wj_jit_finish :: proc "c" (f: ^jsrt.Frame, lo: u32, hi: u32, index: u32, slot: i32, a: u32) -> i32 {
		context = jit_context
		return jsrt.jit_call_finish(f, lo, hi, index, int(slot), jsrt.Atom(a)) ? 1 : 0
	}

	@(export, link_name = "wj_jit_new")
	wj_jit_new :: proc "c" (f: ^jsrt.Frame, kind: i32, a: i32, argc: i32) -> i32 {
		context = jit_context
		return i32(uintptr(jsrt.jit_new(f, jsrt.Jit_New_Kind(kind), int(a), int(argc))))
	}

	@(export, link_name = "wj_jit_reserve")
	wj_jit_reserve :: proc "c" (f: ^jsrt.Frame, o: ^jsrt.Object, n: i32) -> i32 {
		context = jit_context
		jsrt.jit_reserve(f, o, int(n))
		return 0
	}

	@(export, link_name = "wj_jit_add")
	wj_jit_add :: proc "c" (f: ^jsrt.Frame, sp: i32, slot: i32) -> i32 {
		context = jit_context
		return jsrt.jit_add(f, int(sp), int(slot)) ? 1 : 0
	}

	@(export, link_name = "wj_jit_streq")
	wj_jit_streq :: proc "c" (f: ^jsrt.Frame, a: ^jsrt.JS_String, b: ^jsrt.JS_String) -> i32 {
		context = jit_context
		return jsrt.jit_streq(f, a, b) ? 1 : 0
	}

	@(export, link_name = "wj_jit_get")
	wj_jit_get :: proc "c" (f: ^jsrt.Frame, getter: ^jsrt.Object, o: ^jsrt.Object, dest: i32, at: i32, a: u32, pc: i32) -> i32 {
		context = jit_context
		return jsrt.jit_getter(f, getter, o, int(dest), int(at), jsrt.Atom(a), int(pc)) ? 1 : 0
	}

	@(export, link_name = "wj_jit_set")
	wj_jit_set :: proc "c" (f: ^jsrt.Frame, setter: ^jsrt.Object, o: ^jsrt.Object, at: i32, a: u32, pc: i32) -> i32 {
		context = jit_context
		return jsrt.jit_setter(f, setter, o, int(at), jsrt.Atom(a), int(pc)) ? 1 : 0
	}

	@(export, link_name = "wj_jit_step")
	wj_jit_step :: proc "c" (f: ^jsrt.Frame, pc: i32, sp: i32) -> i32 {
		context = jit_context
		return jsrt.jit_step(f, int(pc), int(sp)) ? 1 : 0
	}

	@(export, link_name = "wj_jit_truthy")
	wj_jit_truthy :: proc "c" (tag: u32, lo: u32, hi: u32) -> i32 {
		context = jit_context
		return jsrt.jit_truthy(tag, lo, hi) ? 1 : 0
	}

	@(export, link_name = "wj_jit_array")
	wj_jit_array :: proc "c" (f: ^jsrt.Frame, slot: i32, kind: i32, out: ^jsrt.Jit_Arr) -> i32 {
		context = jit_context
		return jsrt.jit_array_again(f, int(slot), jsrt.Jit_Arr_Kind(kind), out) ? 0 : 1
	}

}

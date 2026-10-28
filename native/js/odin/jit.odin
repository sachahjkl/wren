// jit.odin: the loop JIT of the Odin engine (src/engine/jsrt/jit.odin) seen from the browser: the same exports the C
// engine's JIT has (wj_jit_configure, wj_jit_stat), so src/js/jit.odin and the host's Engine_jitCompile / Engine_jitPoll
// serve both. Only the Odin engine has it; with QuickJS these names come from native/js/jit/wjit.h.
package odin_glue

import "../odin/wj"
import jsrt "wb:engine/jsrt"

// (the import is used in both backends: an import cannot sit in a `when`)
_jit_import :: jsrt.JIT_MAX_LOOPS

when wj.WJ_JSRT {

	@(export, link_name = "wj_jit_configure")
	wj_jit_configure :: proc "c" (flags: i32, call_threshold: i32, max_functions: i32, max_bytecode_bytes: i32, loop_threshold: i32) {
		context = wj.heap_context()
		// (bit 2 of the flags, the C engine's step-only test mode, has no meaning here: the translator has no step path, and
		// its trace must not reach the console, where a test compares what the scripts print)
		log: proc(msg: string)
		if max_bytecode_bytes > 0 {jsrt.jit_cfg.max_code_bytes = int(max_bytecode_bytes)}
		jsrt.jit_configure(flags & 1 != 0 && max_functions != 0, wj.wr_Engine_jitCompile, wj.wr_Engine_jitPoll, log)
	}

	@(export, link_name = "wj_jit_stat")
	wj_jit_stat :: proc "c" (which: i32) -> f64 {
		return jsrt.jit_stat(int(which))
	}

}

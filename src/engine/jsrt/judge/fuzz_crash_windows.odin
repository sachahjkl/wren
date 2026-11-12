package jsrt_judge

// A mutant that crashes the judge says which instruction and native it was in (fuzz_run_one), through a vectored
// exception handler that lets the crash go on.

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"
import js "wb:engine/jsrt"

fuzz_crash_report_install :: proc() { win.AddVectoredExceptionHandler(1, crash_handler) }

@(private = "file")
crash_handler :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	context = runtime.default_context() // memcheck: the JavaScript engine's own heap (a guest allocator), not the browser's process memory
	when js.JSRT_TRACE_LAST_OP {
		name := "?"
		if js.trace_last_bc != nil {name = fmt.tprint(js.trace_last_bc.func_name)}
		nname := "?"
		if o := js.trace_native_obj; o != nil {
			i := js.shape_find(o.shape, js.pa(.A_name))
			if i >= 0 && o.slots[i].value.tag == .string {
				s := js.as_str(o.slots[i].value)
				if !s.is_wide && !s.is_rope {nname = string(js.str_u8(s)[:s.len])}
			}
		}
		fmt.eprintf("crash 0x%x after %v in function atom %s (last native %s)\n", info.ExceptionRecord.ExceptionCode, js.trace_last_op, name, nname)
		for a, i in js.trace_native_args {fmt.eprintf("  arg %d: %v %p\n", i, a.tag, a.u.ptr)}
	} else {
		fmt.eprintf("crash 0x%x (build with -define:JSRT_TRACE_LAST_OP=true for the last instruction)\n", info.ExceptionRecord.ExceptionCode)
	}
	return 0 // EXCEPTION_CONTINUE_SEARCH
}

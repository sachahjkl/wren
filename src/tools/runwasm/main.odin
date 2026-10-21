// Runs a Wasm module headlessly, outside any page: exports, one host import (console.console_log), the call deadline.
//   runwasm.exe build\hello.wasm
package runwasm

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:time"
import "wb:base"
import "wb:wasm"

// console.console_log(message: usvstring), written against the raw interface the generated bindings use.
log_native :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = base.process_context()
	f := wasm.frame(env, caller)
	n := wasm.addr(&f, a[1])
	p, ok := wasm.span(&f, wasm.addr(&f, a[0]), n)
	if !ok { return wasm.trap_bounds(&f, "console.console_log", "message") }
	fmt.printf("[guest] %s\n", string(p[:n]))
	return nil
}

IMPORTS := [?]wasm.Import{
	{module = "console", name = "console_log", fn = log_native, params = {.I32, .I32}, wide_params = {.I64, .I64}, wide_results = {}},
}

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: runwasm module.wasm"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read", os.args[1]); os.exit(2) }

	if !wasm.runtime_init() { fmt.eprintln("runtime init failed"); os.exit(1) }
	if !wasm.register(IMPORTS[:]) { fmt.eprintln("register failed"); os.exit(1) }

	opts := wasm.options_default()
	opts.max_call_ms = 100
	doc := base.scope_make("document")
	inst, e := wasm.instance_create(image, nil, doc, opts)
	if inst == nil { fmt.eprintln(e); os.exit(1) }

	fmt.println("wb_main  ->", wasm.call_raw(inst, "wb_main"))
	r, res := wasm.call_i32(inst, "add", 40, 2)
	fmt.println("add(40,2) ->", r, res)
	fmt.println("missing  ->", wasm.call_raw(inst, "nope"))

	started := time.tick_now()
	res = wasm.call_raw(inst, "spin")
	fmt.printf("spin (deadline) -> %v after %.0f ms: %s\n", res, time.duration_milliseconds(time.tick_since(started)), inst.last_error)
	r, res = wasm.call_i32(inst, "add", 1, 2)
	fmt.println("instance still usable: add(1,2) ->", r, res)

	base.scope_close(doc)   // frees the instance
	wasm.runtime_destroy()
	fmt.println("closed cleanly")
}

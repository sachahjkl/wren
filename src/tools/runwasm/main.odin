// Runs a Wasm module headlessly: exports, host imports, instruction budget, watchdog.
//   runwasm.exe build\hello.wasm
package runwasm

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "wb:base"
import "wb:wasm"

log_native :: proc "c" (env: wasm.Exec_Env, ptr: [^]u8, length: i32) {
	context = runtime.default_context()
	fmt.printf("[guest] %s\n", string(ptr[:length]))
}

console_symbols := [?]wasm.Native_Symbol{
	{"log", rawptr(log_native), "(*~)", nil},
}

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: runwasm module.wasm"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read", os.args[1]); os.exit(2) }

	if !wasm.runtime_init() { fmt.eprintln("runtime init failed"); os.exit(1) }
	if !wasm.register("console", console_symbols[:]) { fmt.eprintln("register failed"); os.exit(1) }

	opts := wasm.options_default()
	opts.budget = 5_000_000
	doc := base.scope_make("document")
	inst, e := wasm.instance_create(image, nil, doc, opts)
	if inst == nil { fmt.eprintln(e); os.exit(1) }

	fmt.println("wb_main  ->", wasm.call_raw(inst, "wb_main"))
	r, res := wasm.call_i32(inst, "add", 40, 2)
	fmt.println("add(40,2) ->", r, res)
	fmt.println("missing  ->", wasm.call_raw(inst, "nope"))

	started := time.tick_now()
	res = wasm.call_raw(inst, "spin")
	fmt.printf("spin (budget) -> %v after %.0f ms: %s\n", res, time.duration_milliseconds(time.tick_since(started)), inst.last_error)
	r, res = wasm.call_i32(inst, "add", 1, 2)
	fmt.println("instance still usable: add(1,2) ->", r, res)

	for _ in 0 ..< 1000 { wasm.call_raw(inst, "spin") }   // repeated overruns must not leak or corrupt
	r, res = wasm.call_i32(inst, "add", 5, 6)
	fmt.println("after 1000 overruns: add(5,6) ->", r, res, "| overruns:", inst.over_budget)

	base.scope_close(doc)   // frees the instance
	wasm.runtime_destroy()
	fmt.println("closed cleanly")
}

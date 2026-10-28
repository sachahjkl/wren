// spiketest: the executor of the Odin<->C link spike (native/js/odin_spike).
//   spiketest <spike.wasm>
// It instantiates the spike module (a WASI reactor), runs its _initialize, calls spike_init (which creates the QuickJS
// runtime and registers the Odin native functions), then evaluates small scripts that exercise the boundary and checks
// the results. Exit status 0 when every check passes, 1 otherwise. It reuses src/wasm (the browser's Wasmtime host), so
// it runs the module exactly as the browser would.
package spiketest

import "core:fmt"
import "core:os"
import "wb:wasm"
import "wb:base"

inst: ^wasm.Instance
failures: int

spike_log :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = base.process_context()
	f := wasm.frame(env, caller)
	if p, ok := wasm.span(&f, u64(u32(a[0].i32)), u64(u32(a[1].i32))); ok {
		fmt.eprintfln("  [module] %s", string(p[:u32(a[1].i32)]))
	}
	return nil
}

// Writes `src` into guest memory (through the module's wj_alloc), evaluates it with spike_eval, returns the int result.
eval :: proc(src: string) -> i32 {
	// QuickJS's JS_Eval needs buf[len] == 0 (quickjs.c: "'buf' must be zero terminated"), so allocate one extra byte.
	ptr, r := wasm.call_i32(inst, "wj_alloc", i32(len(src) + 1))
	if r != .Ok || ptr == 0 { fmt.eprintln("spiketest: wj_alloc failed:", inst.last_error); os.exit(1) }
	buf := wasm.guest_bytes(inst, u64(u32(ptr)), u64(len(src) + 1))
	if buf == nil { fmt.eprintln("spiketest: guest memory out of range"); os.exit(1) }
	copy(buf, src)
	buf[len(src)] = 0
	res, cr := wasm.call_i32(inst, "spike_eval", ptr, i32(len(src)))
	if cr != .Ok { fmt.eprintln("spiketest: spike_eval trapped:", inst.last_error); os.exit(1) }
	wasm.call_i32(inst, "wj_dealloc", ptr)
	return res
}

check :: proc(label: string, got, want: i32) {
	ok := got == want
	fmt.printf("%-40s got %-6d want %-6d  %s\n", label, got, want, ok ? "OK" : "FAIL")
	if !ok { failures += 1 }
}

main :: proc() {
	if len(os.args) != 2 { fmt.eprintln("usage: spiketest <spike.wasm>"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("spiketest: cannot read", os.args[1]); os.exit(2) }

	if !wasm.runtime_init() { fmt.eprintln("spiketest: the Wasm engine could not start"); os.exit(1) }
	if !wasm.register_wasi() { fmt.eprintln("spiketest: WASI registration failed"); os.exit(1) }
	imports := [?]wasm.Import{
		{module = "spike", name = "log", fn = spike_log, params = {.I32, .I32}},
	}
	if !wasm.register(imports[:]) { fmt.eprintln("spiketest: import registration failed"); os.exit(1) }

	opt := wasm.options_default()
	e: string
	inst, e = wasm.instance_create(image, nil, nil, opt, "spiketest")
	if inst == nil { fmt.eprintln("spiketest:", e); os.exit(1) }

	if wasm.call_raw(inst, "_initialize") != .Ok { fmt.eprintln("spiketest: _initialize:", inst.last_error); os.exit(1) }
	if res, _ := wasm.call_i32(inst, "spike_init"); res != 0 { fmt.eprintln("spiketest: spike_init failed:", res, inst.last_error); os.exit(1) }

	// C -> Odin, no engine
	mul, _ := wasm.call_i32(inst, "spike_odin_mul", 6, 7)
	check("C -> Odin (odin_mul 6*7)", mul, 42)

	// JS -> Odin -> C API -> JS (odin_add)
	check("JS -> Odin add(2,3)", eval("odin_add(2, 3)"), 5)
	check("JS -> Odin add(40,2)", eval("odin_add(40, 2)"), 42)
	check("JS -> Odin add in a loop", eval("let s=0; for (let i=0;i<10;i++) s=odin_add(s,i); s"), 45)

	// the engine itself still works end to end (sanity), before and after the string round-trips
	check("plain JS arithmetic (before)", eval("[1,2,3].reduce((a,b)=>a+b,0)"), 6)

	// odin_greet returns a JS string built through JS_NewStringLen; spike_eval returns 0 when it equals the expected text
	check("greet length via JS", eval("odin_greet().length"), 15)
	check("greet char code 0 (h)", eval("odin_greet().charCodeAt(0)"), 104)
	check("JS -> Odin greet() string", eval("odin_greet()"), 0)

	check("plain JS arithmetic (after)", eval("[1,2,3].reduce((a,b)=>a+b,0)"), 6)

	if failures == 0 { fmt.println("\nspike: all checks passed") } else { fmt.printfln("\nspike: %d check(s) FAILED", failures) }
	os.exit(failures == 0 ? 0 : 1)
}

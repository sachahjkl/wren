package e2e_scenarios

// The engine's machine code in the program (src/wasm/shipped.odin), in the real program on a new profile with an empty cache: what a user's first page after an
// install finds. The shared disk cache of the tests is taken away, or it would answer before the question is asked.

import "core:fmt"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") NO_SHARED_CACHE :: []string{"WREN_TEST_WASM_CACHE="}
// A value of a preference that is part of what the code is compiled for, other than the default: the program's code no longer fits.
@(private = "file") OTHER_CONFIGURATION :: "wasm.wasmtime.max_stack_bytes=16777216"
@(private = "file") SCRIPT :: "String(6 * 7)"
@(private = "file") SCRIPT_RESULT :: "42"
@(private = "file") EXTERNAL_SCRIPT :: "script.js"
@(private = "file") EXTERNAL_SOURCE :: "var a = 1"
@(private = "file") PAGE :: "<!doctype html><title>t</title><script src=script.js></script><p>x"
// Every script goes to a compile thread, which has an instance of the engine of its own: the code must serve it too (it ran on the other Wasmtime engine, and each thread compiled the image).
@(private = "file") SCRIPTS_TO_COMPILE_THREADS :: []string{"javascript.compile.offthread_min_bytes=0", "javascript.bytecode_cache.min_source_bytes=0"}
@(private = "file") REALM_AND_COMPILE_THREAD :: 2

@(private = "file")
scripted :: proc(t: ^testing.T, prefs: []string) -> ^e2e.Wren_Process {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..SCRIPTS_TO_COMPILE_THREADS)
	append(&all, ..prefs)
	p := e2e.launch(t, {profile = e2e.temp_profile(t), prefs = all[:], start = {env = NO_SHARED_CACHE}})
	dir := e2e.temp_folder(t)
	page := fmt.tprintf("%s/page.html", dir)
	e2e.write_text(page, PAGE)
	e2e.write_text(fmt.tprintf("%s/%s", dir, EXTERNAL_SCRIPT), EXTERNAL_SOURCE)
	_ = api.navigate(p.s, e2e.file_url(page), .Load)
	got, _ := api.eval(p.s, SCRIPT)
	testing.expect_value(t, got, SCRIPT_RESULT)
	api.wait_until(p.s, proc(s: ^api.Session) -> bool { st, _ := api.stats(s); return st.memory.wasm_instances >= REALM_AND_COMPILE_THREAD }, "the compile thread's instance")
	return p
}

@(test)
a_new_profile_runs_scripts_on_the_shipped_code_and_compiles_nothing :: proc(t: ^testing.T) {
	p := scripted(t, nil)
	st, _ := api.stats(p.s)
	m := st.memory
	testing.expectf(t, m.wasm_shipped_hits == 1 && m.wasm_compiles == 0 && m.wasm_shipped_refused == 0, "the engine from the program: %d taken, %d compiled, %d refused", m.wasm_shipped_hits, m.wasm_compiles, m.wasm_shipped_refused)
}

@(test)
another_configuration_passes_the_shipped_code_by_and_scripts_run :: proc(t: ^testing.T) {
	p := scripted(t, {OTHER_CONFIGURATION})
	st, _ := api.stats(p.s)
	m := st.memory
	testing.expectf(t, m.wasm_shipped_hits == 0 && m.wasm_compiles == 1 && m.wasm_shipped_refused == 1, "%s", fmt.tprintf("compiled once, however many threads wanted it: %d taken, %d compiled, %d refused", m.wasm_shipped_hits, m.wasm_compiles, m.wasm_shipped_refused))
}

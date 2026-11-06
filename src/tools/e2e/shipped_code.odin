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
@(private = "file") PAGE :: "data:text/html,<!doctype html><title>t</title><p>x"

@(private = "file")
scripted :: proc(t: ^testing.T, prefs: []string) -> ^e2e.Wren_Process {
	p := e2e.launch(t, {profile = e2e.temp_profile(t), prefs = prefs, start = {env = NO_SHARED_CACHE}})
	_ = api.navigate(p.s, PAGE, .Load)
	got, _ := api.eval(p.s, SCRIPT)
	testing.expect_value(t, got, SCRIPT_RESULT)
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

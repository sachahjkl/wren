package test_all

import "core:os"

// The environment of every step, the same on every machine: part of what a step's result depends on (this file is an input of every step, cache.odin).
set_test_environment :: proc(cfg: ^Config) {
	// this run's temporary files (several runs at once share no fixed name under the system's folder)
	temp := here(TEMP_DIR)
	os.set_env("TEMP", temp)
	os.set_env("TMP", temp)
	os.set_env("TMPDIR", temp)
	// No test lets a Wren integrate itself with the machine's desktop: Setup's offer at the start (setup.odin), the system watcher of the integration (desktop_shell.odin) and the
	// update check (update_check.odin) read this variable.
	os.set_env("WREN_DESKTOP_INTEGRATION", "off")
	// ... and none makes a sound: the media player's audio goes by in silence at the pace of the clock (src/media/audio_null.odin).
	os.set_env("WREN_AUDIO_OUTPUT", "null")
	// ... and none lets itself be taken for the user's Wren, or for another run's (src/browser/instance_shell.odin). The one scenario that checks it (src/tools/e2e/instance.odin) turns it on.
	os.set_env("WREN_SINGLE_INSTANCE", "off")
	// ... and all share the code the JavaScript engine's image compiled to (src/wasm/module_cache.odin): 5 s of CPU per process otherwise, with hundreds of processes in a run.
	if cfg.no_cache {
		os.unset_env("WREN_TEST_WASM_CACHE")
	} else if !env_set("WREN_TEST_WASM_CACHE") {
		os.set_env("WREN_TEST_WASM_CACHE", here("build/wasm_cache"))
	}
}

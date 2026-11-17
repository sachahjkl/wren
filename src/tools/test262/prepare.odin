package test262

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"
import toolbox "toolkit:toolbox"

// What a run needs, each kept when up to date: in build/test262/run, the suite and QuickJS-ng's runner configuration (toolbox.test262_fetch, pinned by the toolkit); build/js-test262, the test image of
// the engine (the shipped engine plus $262, print, the module loader: native/js/odin/test262_host.odin). Outputs in build/test262: wasm_errors.txt (run-test262's error-file format).
//   build/test262 [-quick] [-update] [-prepare] [-stride k] [-threads n] [-jit [-jit-threshold n] [-jit-loop n] [-jit-step] [-jit-sync]]
// -prepare: only that, no test run (test_all: one step makes it, the runs read it).
// -quick: every QUICK_STRIDE-th test. Exit status 1 on a regression: a test failing that src/tools/test262/known_failures.txt does not list. -update rewrites that list from a full run.

OUT_DIR :: "build/test262"
RUN_DIR :: "build/test262/run"
TEST_IMAGE_DIR :: "build/js-test262"
KNOWN_FAILURES :: "src/tools/test262/known_failures.txt"
QUICK_STRIDE :: 25
ERRORS_FILE :: "wasm_errors.txt"
// The JIT's run writes its own: it runs beside the interpreter's (test_all: two steps).
JIT_ERRORS_FILE :: "wasm_jit_errors.txt"

// Fetches and builds what is missing. False: said on standard error.
prepare :: proc() -> bool {
	// (the toolkit's pins: its native runner and this one judge the same suite against the same reference)
	if why := toolbox.test262_fetch(RUN_DIR); why != "" { fmt.eprintfln("test262: %s", why); return false }
	return tooling.build_js_engine({out = TEST_IMAGE_DIR, test262 = true})
}

// A file copied, as bytes.
copy_file :: proc(from, to: string) -> bool {
	data, err := os.read_entire_file(from, context.temp_allocator)
	if err != nil { return false }
	return os.write_entire_file(to, data) == nil
}

abs_of :: proc(path: string) -> string {
	root := tooling.repo_root(context.temp_allocator)
	return strings.concatenate({root, "/", path})
}

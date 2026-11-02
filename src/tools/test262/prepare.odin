package test262

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

// What a run needs, each kept when up to date, in build/test262: run/test262, the suite (the commit QuickJS-ng 0.17.0 runs, its submodule, as a GitHub archive checked by SHA-256); run/test262.conf and
// run/test262_errors.txt, QuickJS-ng's runner configuration, unchanged, from the engine's release source; build/js-test262, the test image of the engine (the shipped engine plus $262, print, the module loader:
// native/js/odin/test262_host.odin). Outputs: wasm_errors.txt (run-test262's error-file format).
//   build/test262 [-quick] [-update] [-prepare] [-stride k] [-threads n] [-jit [-jit-threshold n] [-jit-loop n] [-jit-step] [-jit-sync]]
// -prepare: only that, no test run (test_all: one step makes it, the runs read it).
// -quick: every QUICK_STRIDE-th test. Exit status 1 on a regression: a test failing that src/tools/test262/known_failures.txt does not list. -update rewrites that list from a full run.

TEST262_COMMIT :: "5ef1e5723be95296f36afb0386676fed0205869c"
TEST262_SHA256 :: "d67ff29d7bcee3493f38b3ef54db068ea5ad6d5a67b67b3f505dfee581dd3879"
OUT_DIR :: "build/test262"
RUN_DIR :: "build/test262/run"
TOOLS_DIR :: "build/tools"
TEST_IMAGE_DIR :: "build/js-test262"
KNOWN_FAILURES :: "src/tools/test262/known_failures.txt"
QUICK_STRIDE :: 25
ERRORS_FILE :: "wasm_errors.txt"
// The JIT's run writes its own: it runs beside the interpreter's (test_all: two steps).
JIT_ERRORS_FILE :: "wasm_jit_errors.txt"

// Fetches and builds what is missing. False: said on standard error.
prepare :: proc() -> bool {
	_ = os.make_directory_all(RUN_DIR)
	stamp := fmt.tprintf("%s/test262/COMMIT", RUN_DIR)
	known, err := os.read_entire_file(stamp, context.temp_allocator)
	if err != nil || strings.trim_space(string(known)) != TEST262_COMMIT {
		tarball := fmt.tprintf("%s/test262-%s.tar.gz", OUT_DIR, TEST262_COMMIT)
		if !tooling.download_pinned(fmt.tprintf("https://codeload.github.com/tc39/test262/tar.gz/%s", TEST262_COMMIT), tarball, TEST262_SHA256) { return false }
		_ = os.remove_all(fmt.tprintf("%s/test262", RUN_DIR))
		if tooling.run({command = {"tar", "-xzf", tarball, "-C", RUN_DIR}}) != 0 { fmt.eprintln("test262: tar failed"); return false }
		if os.rename(fmt.tprintf("%s/test262-%s", RUN_DIR, TEST262_COMMIT), fmt.tprintf("%s/test262", RUN_DIR)) != nil { fmt.eprintln("test262: the archive has not its usual folder"); return false }
		if os.write_entire_file(stamp, TEST262_COMMIT) != nil { return false }
	}
	// QuickJS-ng's release source, unpatched: the runner's configuration.
	version := tooling.QJS_VERSION
	source := fmt.tprintf("%s/quickjs-%s", OUT_DIR, version)
	if !os.exists(fmt.tprintf("%s/run-test262.c", source)) {
		tarball := fmt.tprintf("%s/quickjs-ng-v%s.tar.gz", TOOLS_DIR, version)
		if !tooling.download_pinned(fmt.tprintf("https://github.com/quickjs-ng/quickjs/archive/refs/tags/v%s.tar.gz", version), tarball, tooling.QJS_SHA256) { return false }
		if tooling.run({command = {"tar", "-xzf", tarball, "-C", OUT_DIR}}) != 0 { fmt.eprintln("test262: tar failed"); return false }
	}
	for f in ([]string{"test262.conf", "test262-fast.conf", "test262_errors.txt"}) {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", source, f), context.temp_allocator)
		if rerr != nil { fmt.eprintfln("test262: no %s in %s", f, source); return false }
		// (written only when it differs: two runs at once, the interpreter's and the JIT's, read it)
		to := fmt.tprintf("%s/%s", RUN_DIR, f)
		if have, herr := os.read_entire_file(to, context.temp_allocator); herr == nil && string(have) == string(data) { continue }
		if os.write_entire_file(to, data) != nil { return false }
	}
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

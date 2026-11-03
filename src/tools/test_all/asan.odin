package test_all

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "wb:tools/tooling"

// AddressSanitizer builds: heap and stack overflows, use after free, double frees, in the unit tests of packages (steps, one per package) or by hand in the browser and in a program.
// Odin's -sanitize:address links LLVM's static ASan runtime with the static C runtime (libcmt), which every native library of Wren uses too (Lexbor, the Rust libraries, Wasmtime).
// What it sees: every Odin allocation (the process heap: ASAN_OPTIONS=windows_hook_rtl_allocators=true routes HeapAlloc through ASan), Odin's stack and globals. What it does not: inside the native
// libraries (not instrumented; their own heaps), virtual memory arenas (base.Scope, vmem.Arena: VirtualAlloc, no redzones), Wasm linear memories (Wasmtime's guard pages already trap there).
// The browser's build, build/asan/browser_asan.exe (debug, 256 MiB of stack, the check build's tracker and script driver), runs through src/tools/e2e/memcheck.odin with WREN_MEMCHECK_EXE and ASAN_OPTIONS set.

ASAN_DIR :: "build/asan"
ASAN_PACKAGES := []string{"layout", "page", "browser", "base", "host", "dom", "html", "url", "http", "cookies", "csp", "httpcache", "fetch", "css", "style", "webfont", "images", "forms", "js", "webauthn", "wasm", "xml"}
// 256 MiB of default stack (the main thread, threads started with the executable's size): ASan's frames are several times larger (redzones), the 32 MiB of the normal builds overflow on the first page.
ASAN_STACK :: "-extra-linker-flags:/STACK:268435456"
// handle_segv=0: the access violations that are not errors stay with their owners (Wasmtime's guard pages, the stack guard pages of threads ASan does not know: the shell's, the system's, where ASan reported a "stack-overflow").
ASAN_OPTIONS :: "ASAN_OPTIONS=windows_hook_rtl_allocators=true:handle_segv=0:detect_stack_use_after_return=false"
ASAN_REPORT :: "ERROR: AddressSanitizer"
ASAN_REPORT_BEFORE :: 200
ASAN_REPORT_BYTES :: 6000

Asan_By_Hand :: struct {
	browser, console: bool,
	program, packages, names: string,
}

// Builds `path` with the instrumentation (its tests when `verb` is "test"): the executable, or "".
asan_build :: proc(run: proc(command: []string) -> int, verb, path, name: string, extra: []string, subsystem: string) -> string {
	_ = os.make_directory_all(ASAN_DIR)
	program := fmt.tprintf("%s/%s.exe", ASAN_DIR, name)
	mode := verb == "test" ? "-build-mode:test" : "-build-mode:exe"   // (odin test would run them, without ASAN_OPTIONS)
	if run(join({tooling.odin_program(), "build", path, mode, TOOLKIT, WB, "-sanitize:address", "-debug", ASAN_STACK, fmt.tprintf("-subsystem:%s", subsystem)}, extra, {fmt.tprintf("-out:%s", program)})) != 0 { return "" }
	return program
}

// The unit tests of one package, built and run: `t.arg` is its name.
task_asan_package :: proc(t: ^Task_Run) -> bool {
	@(thread_local) current: ^Task_Run
	current = t
	run_it :: proc(command: []string) -> int { return task_exec(current, command) }
	program := asan_build(run_it, "test", fmt.tprintf("src/%s", t.arg), fmt.tprintf("%s_asan_test", t.arg), {ONE_THREAD, "-define:ODIN_TEST_FANCY=false", "-define:ODIN_TEST_LOG_STATE_CHANGES=true"}, "console")
	if program == "" { return false }
	offset := tooling.file_size(t.log)
	task_exec(t, {program}, {ASAN_OPTIONS})
	data, err := os.read_entire_file(t.log, context.temp_allocator)
	if err != nil { return false }
	text := string(data[min(offset, i64(len(data))):])
	at := strings.index(text, ASAN_REPORT)
	if at >= 0 {
		// (the report where a reader looks: the end of the log)
		from := max(0, at - ASAN_REPORT_BEFORE)
		tooling.append_text(t.log, text[from:min(len(text), from + ASAN_REPORT_BYTES)])
		return false
	}
	return strings.contains(text, SUCCESS_MANY)
}

asan_steps :: proc(t: ^[dynamic]Step) {
	for pkg in ASAN_PACKAGES {
		append(t, Step{name = fmt.aprintf("unit tests under AddressSanitizer: %s (overflows, use after free, double frees)", pkg), actions = slice_of(Task{"asan", task_asan_package, pkg}), marks = {.Asan}, needs = COMMON_NEEDS, inputs = .Tree, limit = LONG_STEP_SECONDS})
	}
}

// -AsanBrowser, -AsanProgram, -AsanPackages: built (and for packages run) now, and the run ends here.
asan_by_hand :: proc(cfg: ^Config) -> bool {
	h := cfg.asan
	if !h.browser && h.program == "" && h.packages == "" { return false }
	run_it :: proc(command: []string) -> int { return tooling.run({command = command}) }
	failed := 0
	if h.browser {
		// (with the tracker of the check build: its script driver runs the sessions of src/tools/e2e/memcheck.odin and src/tools/endurance)
		built := asan_build(run_it, "build", "src/browser", "browser_asan", {"-define:WREN_CHANNEL=dev", "-resource:src/browser/wren_dev.rc", TRACK}, h.console ? "console" : "windows")
		if built == "" { failed += 1 } else { fmt.printfln("built %s (%s when you run it)", built, ASAN_OPTIONS) }
	}
	if h.program != "" {
		built := asan_build(run_it, "build", h.program, fmt.tprintf("%s_asan", filepath.base(strings.trim_right(h.program, "/\\"))), nil, "console")
		if built == "" { failed += 1 } else { fmt.printfln("built %s", built) }
	}
	if h.packages != "" {
		for pkg in strings.split(h.packages, ",") {
			flags := make([dynamic]string)
			append(&flags, ONE_THREAD, "-define:ODIN_TEST_FANCY=false", "-define:ODIN_TEST_LOG_STATE_CHANGES=true")
			if h.names != "" { append(&flags, fmt.aprintf("-define:ODIN_TEST_NAMES=%s", h.names)) }
			built := asan_build(run_it, "test", fmt.tprintf("src/%s", pkg), fmt.tprintf("%s_asan_test", pkg), flags[:], "console")
			if built == "" || tooling.run({command = {built}, env = {ASAN_OPTIONS}}) != 0 { failed += 1; fmt.printfln("FAIL unit tests of %s under AddressSanitizer", pkg) } else { fmt.printfln("PASS unit tests of %s under AddressSanitizer", pkg) }
		}
	}
	os.exit(failed > 0 ? 1 : 0)
}

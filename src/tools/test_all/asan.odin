package test_all

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "wb:tools/tooling"

// AddressSanitizer builds: heap and stack overflows, use after free, double frees, in the unit tests of packages (steps, one per package) or by hand in the browser and in a program.
// Odin's -sanitize:address links LLVM's static ASan runtime, under which windows_hook_rtl_allocators (below) makes CreateProcess fail (os.process_exec: INVALID_PARAMETER). So the Odin code is compiled
// with the instrumentation to object files (-build-mode:obj) and linked here with MSVC's dynamic ASan runtime (clang_rt.asan_dynamic, next to the executable) and the dynamic C runtime in place of
// the static one the native libraries name (their calls to it are plain ones: /MT, crt-static), with every library the normal build links (-print-linker-flags).
// What it sees: every Odin allocation (the process heap: ASAN_OPTIONS=windows_hook_rtl_allocators=true routes HeapAlloc through ASan), Odin's stack and globals. What it does not: inside the native
// libraries (not instrumented; their own heaps), virtual memory arenas (base.Scope, vmem.Arena: VirtualAlloc, no redzones), Wasm linear memories (Wasmtime's guard pages already trap there).
// The browser's build, build/asan/browser_asan.exe (debug, 256 MiB of stack, the check build's tracker and script driver), runs through src/tools/e2e/memcheck.odin with WREN_MEMCHECK_EXE and ASAN_OPTIONS set.

ASAN_DIR :: "build/asan"
ASAN_PACKAGES := []string{"layout", "page", "browser", "base", "host", "dom", "html", "url", "http", "cookies", "csp", "httpcache", "fetch", "css", "style", "webfont", "images", "forms", "js", "webauthn", "wasm", "xml"}
// 256 MiB of default stack (the main thread, threads started with the executable's size): ASan's frames are several times larger (redzones), the 32 MiB of the normal builds overflow on the first page.
ASAN_STACK :: "/STACK:268435456"
// handle_segv=0: the access violations that are not errors stay with their owners (Wasmtime's guard pages, the stack guard pages of threads ASan does not know: the shell's, the system's, where ASan reported a "stack-overflow").
ASAN_OPTIONS :: "ASAN_OPTIONS=windows_hook_rtl_allocators=true:handle_segv=0:detect_stack_use_after_return=false"
ASAN_REPORT :: "ERROR: AddressSanitizer"
ASAN_REPORT_BEFORE :: 200
ASAN_REPORT_BYTES :: 6000
VSWHERE :: "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
// The browser's link flags are printed by a compile of the whole browser, under a lock three steps wait on: a hang there must end.
ASAN_FLAGS_LIMIT :: 20 * time.Minute

Asan_By_Hand :: struct {
	browser, console: bool,
	program, packages, names: string,
}

// What the links of a run share: found once, by the first step that needs them.
Asan_Tools :: struct {
	lock:  sync.Mutex,
	ready, skip, failed: bool,
	link, runtime_lib, thunk_lib: string,
	libs, libpaths: []string,
}
asan_tools: Asan_Tools

// MSVC's linker and dynamic runtime of the newest toolset; the libraries of the browser, which links every package (odin test cannot print its own; a library a test does not use costs nothing; the question is a compile of the whole browser).
asan_prepare :: proc(log: string) -> ^Asan_Tools {
	a := &asan_tools
	sync.guard(&a.lock)
	if a.ready { return a }
	a.ready = true
	text, code := tooling.capture({VSWHERE, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"})
	if code != 0 { tooling.say(log, fmt.tprintfln("vswhere: %s", text)); a.failed = true; return a }
	vs := strings.trim_space(text)
	tools_dir := fmt.tprintf("%s/VC/Tools/MSVC", vs)
	entries, err := os.read_all_directory_by_path(tools_dir, context.temp_allocator)
	if err != nil || len(entries) == 0 { tooling.say(log, fmt.tprintfln("no MSVC in %s", tools_dir)); a.failed = true; return a }
	slice.sort_by(entries, proc(x, y: os.File_Info) -> bool { return x.name > y.name })
	msvc := entries[0].fullpath
	a.link = fmt.aprintf("%s/bin/Hostx64/x64/link.exe", msvc)
	a.runtime_lib = fmt.aprintf("%s/lib/x64/clang_rt.asan_dynamic-x86_64.lib", msvc)
	a.thunk_lib = fmt.aprintf("%s/lib/x64/clang_rt.asan_dynamic_runtime_thunk-x86_64.lib", msvc)
	dll := fmt.tprintf("%s/bin/Hostx64/x64/clang_rt.asan_dynamic-x86_64.dll", msvc)
	if !os.exists(dll) {
		tooling.say(log, "SKIP MSVC has no AddressSanitizer runtime (the \"C++ AddressSanitizer\" component of Visual Studio): nothing checked\n")
		a.skip = true
		return a
	}
	_ = os.make_directory_all(ASAN_DIR)
	if content, rerr := os.read_entire_file(dll, context.temp_allocator); rerr == nil { _ = os.write_entire_file(fmt.tprintf("%s/clang_rt.asan_dynamic-x86_64.dll", ASAN_DIR), content) }
	flags, flags_code := tooling.capture({tooling.odin_program(), "build", "src/browser", TOOLKIT, WB, "-sanitize:address", "-debug", "-define:WREN_CHANNEL=dev", "-resource:src/browser/wren_dev.rc",
		fmt.tprintf("-out:%s/browser_flags.exe", ASAN_DIR), "-print-linker-flags"}, limit = ASAN_FLAGS_LIMIT)
	_ = flags_code   // (it prints them and goes on to fail or not: what counts is what it printed)
	libs := make([dynamic]string)
	paths := make([dynamic]string)
	seen := make(map[string]bool, 64, context.temp_allocator)
	rest := flags
	for {
		quote := strings.index_byte(rest, '"')
		if quote < 0 { break }
		end := strings.index_byte(rest[quote + 1:], '"')
		if end < 0 { break }
		value := rest[quote + 1:quote + 1 + end]
		before := rest[:quote]
		if strings.has_suffix(before, "/LIBPATH:") {
			append(&paths, fmt.aprintf("/LIBPATH:%s", value))
		} else if (strings.has_suffix(value, ".lib") || strings.has_suffix(value, ".res")) && !strings.contains(value, "clang_rt") && value not_in seen {
			seen[value] = true
			append(&libs, strings.clone(dynamic_crt(value)))
		}
		rest = rest[quote + 1 + end + 1:]
	}
	if len(libs) == 0 { tooling.say(log, fmt.tprintfln("FAIL cannot read the browser's libraries: %s", flags)); a.failed = true; return a }
	append(&libs, "winmm.lib", "psapi.lib")   // (what the browser's normal build does not use: layout's benchmarks, the driver's counters)
	a.libs, a.libpaths = libs[:], paths[:]
	return a
}

// The dynamic C runtime in place of the static one the foreign imports name.
@(private = "file")
dynamic_crt :: proc(lib: string) -> string {
	switch lib {
	case "libcmt.lib":  return "msvcrt.lib"
	case "libucrt.lib": return "ucrt.lib"
	}
	return lib
}

// Compiles `path` with the instrumentation (odin build or odin test), links it with the dynamic runtimes: the executable, or "".
asan_build :: proc(run: proc(command: []string) -> int, verb, path, name: string, extra: []string, subsystem: string, tools: ^Asan_Tools) -> string {
	objects := fmt.tprintf("%s/obj_%s", ASAN_DIR, name)
	_ = os.remove_all(objects)
	_ = os.make_directory_all(objects)
	program := fmt.tprintf("%s/%s.exe", ASAN_DIR, name)
	if run(join({tooling.odin_program(), verb, path, TOOLKIT, WB, "-sanitize:address", "-debug"}, extra, {"-build-mode:obj", fmt.tprintf("-out:%s/%s.obj", objects, name)})) != 0 { return "" }
	entries, err := os.read_all_directory_by_path(objects, context.temp_allocator)
	if err != nil { return "" }
	link := make([dynamic]string, context.temp_allocator)
	append(&link, tools.link, "/nologo")
	for e in entries { if strings.has_suffix(e.name, ".obj") { append(&link, e.fullpath) } }
	append(&link, fmt.tprintf("/OUT:%s", program), "/DEBUG", "/ENTRY:wmainCRTStartup", fmt.tprintf("/SUBSYSTEM:%s", subsystem), "/MACHINE:X64", "/INCREMENTAL:NO", ASAN_STACK, "/NODEFAULTLIB:libcmt", "/NODEFAULTLIB:libucrt", "/DEFAULTLIB:msvcrt")
	append(&link, ..tools.libpaths)
	append(&link, tools.runtime_lib, tools.thunk_lib)
	append(&link, ..tools.libs)
	if run(link[:]) != 0 { return "" }
	return program
}

// The unit tests of one package, built and run: `t.arg` is its name.
task_asan_package :: proc(t: ^Task_Run) -> bool {
	tools := asan_prepare(t.log)
	if tools.failed { return false }
	if tools.skip { return true }
	@(thread_local) current: ^Task_Run
	current = t
	run_it :: proc(command: []string) -> int { return task_exec(current, command) }
	program := asan_build(run_it, "test", fmt.tprintf("src/%s", t.arg), fmt.tprintf("%s_asan_test", t.arg), {ONE_THREAD, "-define:ODIN_TEST_FANCY=false", "-define:ODIN_TEST_LOG_STATE_CHANGES=true"}, "CONSOLE", tools)
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

asan_steps :: proc(t: ^[dynamic]Step, cfg: ^Config) {
	for pkg in ASAN_PACKAGES {
		append(t, Step{name = fmt.aprintf("unit tests under AddressSanitizer: %s (overflows, use after free, double frees)", pkg), actions = slice_of(Task{"asan", task_asan_package, pkg}), marks = {.Asan}, needs = COMMON_NEEDS, inputs = .Tree, limit = suite_limit(cfg)})
	}
}

// -AsanBrowser, -AsanProgram, -AsanPackages: built (and for packages run) now, and the run ends here.
asan_by_hand :: proc(cfg: ^Config) -> bool {
	h := cfg.asan
	if !h.browser && h.program == "" && h.packages == "" { return false }
	tools := asan_prepare("")
	if tools.failed { os.exit(1) }
	if tools.skip { return true }
	run_it :: proc(command: []string) -> int { return tooling.run({command = command}) }
	failed := 0
	if h.browser {
		// (with the tracker of the check build: its script driver runs the sessions of src/tools/e2e/memcheck.odin and src/tools/endurance)
		built := asan_build(run_it, "build", "src/browser", "browser_asan", {"-define:WREN_CHANNEL=dev", "-resource:src/browser/wren_dev.rc", TRACK}, h.console ? "CONSOLE" : "WINDOWS", tools)
		if built == "" { failed += 1 } else { fmt.printfln("built %s (%s when you run it)", built, ASAN_OPTIONS) }
	}
	if h.program != "" {
		built := asan_build(run_it, "build", h.program, fmt.tprintf("%s_asan", filepath.base(strings.trim_right(h.program, "/\\"))), nil, "CONSOLE", tools)
		if built == "" { failed += 1 } else { fmt.printfln("built %s", built) }
	}
	if h.packages != "" {
		for pkg in strings.split(h.packages, ",") {
			flags := make([dynamic]string)
			append(&flags, ONE_THREAD, "-define:ODIN_TEST_FANCY=false", "-define:ODIN_TEST_LOG_STATE_CHANGES=true")
			if h.names != "" { append(&flags, fmt.aprintf("-define:ODIN_TEST_NAMES=%s", h.names)) }
			built := asan_build(run_it, "test", fmt.tprintf("src/%s", pkg), fmt.tprintf("%s_asan_test", pkg), flags[:], "CONSOLE", tools)
			if built == "" || tooling.run({command = {built}, env = {ASAN_OPTIONS}}) != 0 { failed += 1; fmt.printfln("FAIL unit tests of %s under AddressSanitizer", pkg) } else { fmt.printfln("PASS unit tests of %s under AddressSanitizer", pkg) }
		}
	}
	os.exit(failed > 0 ? 1 : 0)
}

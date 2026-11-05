// Package builder: Wren's build on Windows, from the sources to build\wren.exe (what build.bat did; build.bat now only hands its arguments to `wrentool build`).
//   wrentool build [dev|debug|profile|check|release]     the browser (dev by default; `wrentool build help` lists the variants and the environment)
//   wrentool build lexbor|native|tracy [-Force] [-Profile p]  one dependency (package deps)
//
// Channel: every build is a *development* build (blueprint icon, "development build" in about:home and the menu) but `release` (amber icon). It goes in as -define:WREN_CHANNEL (about.odin:
// APP_CHANNEL) with its icon, and in build\wren.channel, which wrentool package checks before packaging.
//
// Compile speed: Odin hands LLVM one module per package with -use-separate-modules, and LLVM then works on all cores. Measured on 2026-10-26: the Odin step of the development build (-o:speed -debug,
// separate modules) takes about 25 s and `check` about 17 s, against 140 to 230 s for `release`, one module. The development, debug and check builds use it; `release` and `profile` keep a single
// module (inlining across packages; measurements as in the shipped build). A build that takes minutes more than that has a trap in it: -o:speed with -debug on a function that holds a large value
// (kilobytes) in a local makes LLVM spend ten minutes on its module (render.Surface in window_open: see render.surface_init). Bisect with the exact command of the variant, and give a build a time limit.
//
// Steps: 1. checks   2. dependencies   3. generated code   4. common flags   5. the build itself
package builder

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"
import "wb:tools/wrentool/deps"

EXIT_USAGE :: 2
ABOUT_FILE :: "src/browser/about.odin"
VERSION_MARK :: "APP_VERSION"
VERSION_H :: "build/wren_version.h"
ODIN_VERSION_FILE :: "odin.version"
TOOLKIT_DEFAULT :: "ext/gui_toolkit"
TOOLKIT_PROBE :: "ext/gui_toolkit/ui"   // empty when the submodule was not checked out
CHANNEL_FILE :: "build/wren.channel"
LAUNCHER :: "build/wren.com"
LAUNCHER_SOURCES :: "src/tools/wrencom"
// 32 MiB of stack for the window thread: Wasm calls run on it (wasm.wasmtime.max_stack_bytes + host_stack_reserve_bytes)
STACK_BYTES :: 64 << 20
// every thread's temporary allocator keeps its first block for life: 64 KiB instead of Odin's 4 MiB (at 1 MiB each it was 70 MB of private bytes on a page with a video, mostly never touched); the threads of a frame's passes ask for more (host.thread_temp_hot)
TEMP_ALLOCATOR_BACKING_BYTES :: 64 << 10
SEPARATE_MODULES :: "-use-separate-modules"

Variant :: enum { Dev, Debug, Profile, Check, Release }

Variant_Spec :: struct {
	name, about:      string,
	program:          string,     // build/<program><suffix>.exe
	flags:            []string,   // after the common ones
	separate_modules: bool,       // one LLVM module per package: fast to compile, no inlining across packages
	native_release:   bool,       // the Rust library with Cargo's `release` profile (fat LTO) instead of `quick` (no LTO: a change rebuilds one crate)
	release_channel:  bool,       // amber icon, the release channel
	store_symbols:    bool,       // the linker's map also kept in build/symbols (the builds that are handed out: a later crash report names them)
	channel_file:     bool,       // writes build/wren.channel (the programs named build/wren*.exe)
}

VARIANTS := [Variant]Variant_Spec{
	// -debug is there for the PDB: a crash report then names functions and lines (crashtrace). It also makes ODIN_DEBUG true, which would turn on
	// the Direct3D debug layer (the toolkit's D3D_DEBUG): every draw call validated, the licence card's frame twice the CPU; the debug variant keeps it
	.Dev     = {name = "dev", about = "(default) optimised, PDB, fast to compile          -> build\\wren.exe", program = "wren", flags = {"-o:speed", "-debug", "-define:D3D_DEBUG=false"}, separate_modules = true, channel_file = true},
	.Debug   = {name = "debug", about = "debug information, no optimisation                 -> build\\wren.exe", program = "wren", flags = {"-debug"}, separate_modules = true, channel_file = true},
	// one module, as the release; a PDB for the profiler; no Direct3D debug layer (GPU and present times as shipped)
	.Profile = {name = "profile", about = "optimised, PDB, the built-in profiler (bench perf) -> build\\wren_prof.exe", program = "wren_prof", flags = {"-o:speed", "-debug", "-define:PROFILE=true", "-define:D3D_DEBUG=false"}, native_release = true},
	// debug information, Odin's bounds checks and assertions, the contracts checked in debug builds only (thread ownership), and every allocation of the process tracked (src\base\memory.odin). At
	// exit the blocks still allocated go to <profile>\memtrack.txt (or WREN_MEMTRACK_REPORT); WREN_MEMTRACK_FAIL=1 makes them exit code 3, WREN_MEMTRACK_STACK=1 records each block's call stack.
	// Never shipped: the tracker serializes every allocation.
	.Check   = {name = "check", about = "debug, allocations tracked, freed memory poisoned -> build\\wren_check.exe", program = "wren_check", flags = {"-debug", "-define:WREN_TRACK_MEMORY=true", "-define:WREN_POISON_MEMORY=true"}, separate_modules = true},
	// one module: LLVM inlines across packages
	.Release = {name = "release", about = "what the release packages (one module, amber icon) -> build\\wren.exe", program = "wren", flags = {"-o:speed"}, native_release = true, release_channel = true, store_symbols = true, channel_file = true},
}

// What a build is made with. The command line takes them from the environment (options_from_env); wrentool experimental sets the label and the licence itself.
Options :: struct {
	variant:          Variant,
	toolkit:          string,   // WREN_TOOLKIT: another gui_toolkit checkout (S:/gt_wt/other), to compare two toolkits with the same browser sources
	wgpu:             bool,     // WREN_RENDER=wgpu: the WebGPU render backend (default d3d11)
	dwrite:           bool,     // WREN_TEXT=dwrite: DirectWrite's shaper and analyzers instead of the toolkit's native text backend
	tracy:            bool,     // WREN_TRACY=1: the Tracy client linked (package trace; -> wren_prof_tracy.exe...)
	odin_extra:       string,   // WREN_ODIN_EXTRA: more Odin flags, space-separated ("-define:TOOLKIT_WGPU_BACKEND=vulkan")
	tag:              string,   // WREN_TAG: a suffix for the output name, to keep several builds side by side
	label:            string,   // WREN_VERSION_LABEL: shown after the version number (about:wren, the menu, the file's Details)
	accept_dev_key:   bool,     // WREN_ACCEPT_DEV_LICENSE_KEY: also accepts the licences of the development key pair (public on purpose: wrentool experimental hands a demonstration licence out with it)
	embedded_license: string,   // WREN_EMBEDDED_LICENSE: the one line of a .wrenlicense, put in the profile the first time it has none (browser/license_shell.odin); needs a label
	any_odin:         bool,     // WREN_ANY_ODIN: builds with another Odin than odin.version says
	js_odin_flags:    []string, // WREN_ODIN_FLAGS (;-separated): more flags for the JavaScript engine's glue and engine
	log:              string,   // where the compilers' output goes ("": here)
}

options_from_env :: proc(variant: Variant) -> Options {
	o := Options{variant = variant}
	o.toolkit = env("WREN_TOOLKIT")
	o.wgpu = env("WREN_RENDER") == "wgpu"
	o.dwrite = env("WREN_TEXT") == "dwrite"
	o.tracy = env("WREN_TRACY") == "1"
	o.odin_extra = env("WREN_ODIN_EXTRA")
	o.tag = env("WREN_TAG")
	o.label = env("WREN_VERSION_LABEL")
	o.accept_dev_key = env("WREN_ACCEPT_DEV_LICENSE_KEY") != ""
	o.embedded_license = env("WREN_EMBEDDED_LICENSE")
	o.any_odin = env("WREN_ANY_ODIN") != ""
	if extra := env("WREN_ODIN_FLAGS"); extra != "" { o.js_odin_flags = strings.split(extra, ";", context.temp_allocator) }
	return o
}

// `wrentool build`: the browser, or one dependency.
run :: proc(args: []string) -> int {
	what := len(args) > 0 ? args[0] : VARIANTS[.Dev].name
	switch what {
	case "lexbor", "native", "tracy": return deps.run_build(args)
	case "help", "-h", "--help", "/?": usage(); return 0
	}
	for spec, v in VARIANTS {
		if spec.name != what { continue }
		if len(args) > 1 { fmt.eprintfln("wrentool build %s takes no more arguments (the environment says the rest: wrentool build help)", what); return EXIT_USAGE }
		return browser(options_from_env(v)) ? 0 : 1
	}
	fmt.eprintfln("unknown build \"%s\"\n", what)
	usage()
	return EXIT_USAGE
}

usage :: proc() {
	fmt.println("usage: wrentool build [variant]   (or build.bat [variant])\n")
	for spec in VARIANTS { fmt.printfln("  %-9s %s", spec.name, spec.about) }
	fmt.println("  lexbor | native | tracy [-Force] [-Profile quick|release]: one dependency")
	fmt.println("  help      this text\n")
	fmt.println("environment:")
	fmt.println("  WREN_RENDER=wgpu      the WebGPU render backend (-> wren_wgpu.exe, wren_prof_wgpu.exe...)")
	fmt.println("  WREN_TEXT=dwrite      DirectWrite's shaper instead of the native text backend (-> wren_dwrite.exe...)")
	fmt.println("  WREN_TRACY=1          the Tracy profiler's client, on demand (-> wren_prof_tracy.exe...; docs\\performance.md, Profilers)")
	fmt.println("  WREN_TAG=_x           a suffix for the output name, to keep several builds side by side")
	fmt.println("  WREN_ODIN_EXTRA=...   more Odin flags")
	fmt.println("  WREN_TOOLKIT=path     another gui_toolkit checkout instead of ext\\gui_toolkit")
	fmt.println("  WREN_ANY_ODIN=1       build with another Odin than odin.version says")
	fmt.println("  WREN_VERSION_LABEL=l  a label after the version number (experimental-2026-10-24)")
	fmt.println("\nthen: build\\wren.exe [URL]   tests: odin run src/tools/test_all -collection:wb=src -keep-executable -out:build/test_all.exe -- -Quick")
}

// The program of a variant (build/wren.exe, build/wren_prof_wgpu.exe...).
program_of :: proc(o: Options) -> string {
	return fmt.tprintf("build/%s%s%s%s%s%s", VARIANTS[o.variant].program, o.wgpu ? "_wgpu" : "", o.tracy ? "_tracy" : "", o.tag, o.dwrite ? "_dwrite" : "", tooling.EXE_SUFFIX)
}

// The whole build of one variant: each step does nothing when its output is up to date, but the Odin compile (Odin has no incremental build).
// The dependencies of a variant's build (step 2 of `browser`): nothing to do when their stamps say they are up to date. test_all
// makes them a step of their own, which every step that links build\native waits for: no program links the library while it is
// being replaced (a dev and a release build use different profiles of it).
dependencies :: proc(o: Options) -> bool {
	return deps.all({profile = VARIANTS[o.variant].native_release ? "release" : "quick", tracy = o.tracy, log = o.log})
}

browser :: proc(o: Options) -> bool {
	when ODIN_OS != .Windows {
		return say_fail(o, "wrentool build is Windows' build: on Linux, ./build.sh wren")
	}
	spec := VARIANTS[o.variant]

	// 1. Checks
	if !os.exists(TOOLKIT_PROBE) { return say_fail(o, "ext\\gui_toolkit is empty: run  git submodule update --init") }
	// the Odin compiler this tree is written for (the CI installs that release, pinned by SHA-256 in .github\actions\setup\action.yml): another one may build differently or not at all
	if !o.any_odin && !odin_matches(o) { return false }
	if o.embedded_license != "" && o.label == "" { return say_fail(o, "WREN_EMBEDDED_LICENSE needs WREN_VERSION_LABEL: a build with a licence inside is not a release") }

	// 2. Dependencies: Wasmtime (C API, pinned release), Lexbor (+ the C shims of src\shim, MSVC), Noto Color Emoji (compiled into the exe), the one Rust library of native\ (image decoders, WOFF2,
	// the network stack, the toolkit's text backend and accessibility adapter): package deps, each pinned and stamped
	if !dependencies(o) { return false }

	// 3. Generated code: the web API from its description (api\*.widl: host bindings, guest SDK, docs, conformance tests; only what changed), the JavaScript engine (build\js\wren_js.wasm, embedded in
	// wren.exe), the console launcher (build\wren.com, embedded in wren.exe)
	if !bindgen(o) { return false }
	if !tooling.build_js_engine({odin_flags = o.js_odin_flags, log = o.log}) { return say_fail(o, "building the JavaScript engine failed: run  odin run src/tools/buildjs -collection:wb=src -out:build/buildjs.exe") }
	if !launcher(o.log) { return false }

	// 4. Common flags; the version resource of wren.exe (publisher, product, File version) takes its numbers from APP_VERSION
	if !version_h(o.label) { return say_fail(o, fmt.tprintf("%s cannot be written (%s in %s)", VERSION_H, VERSION_MARK, ABOUT_FILE)) }
	flags := common_flags(o)
	// wgpu links wgpu-native as a DLL (wgpu_native.dll beside the program: Wren already links one Rust static library, and two cannot coexist), with the DXC DLLs next to it so that Direct3D 12
	// compiles the shaders in 0.3 s instead of 2.8 s: the toolkit's own tool fetches them
	if o.wgpu && tooling.run({command = {tooling.odin_program(), "run", "ext/gui_toolkit/tools/tk", "-out:build/tk.exe", "--", "fetch_wgpu", "-dest:build", fmt.tprintf("-odin:%s", tooling.odin_program())}, log = o.log}) != 0 {
		return say_fail(o, "fetching the wgpu dependencies failed")
	}

	// 5. The build
	program := program_of(o)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, tooling.odin_program(), "build", "src/browser", fmt.tprintf("-out:%s", program))
	append(&command, ..flags)
	append(&command, ..spec.flags)
	if spec.separate_modules { append(&command, SEPARATE_MODULES) }
	if tooling.run({command = command[:], log = o.log}) != 0 { return false }
	// a variant without -debug has no PDB: one left beside it by an earlier build is another program's, and would name its
	// frames wrong (crash reports, wren ctl stacks)
	if !slice.contains(spec.flags, "-debug") { _ = os.remove(fmt.tprintf("%s.pdb", strings.trim_suffix(program, ".exe"))) }

	// the linker's map becomes <exe>-<fingerprint>.map beside the exe (wrentool crash-symbolize reads them)
	named, ok := deps.publish_symbols(program, spec.store_symbols)
	if !ok { return say_fail(o, fmt.tprintf("naming the symbols of %s failed: run  wrentool symbols -Publish %s", program, program)) }
	tooling.say(o.log, fmt.tprintfln("symbols: %s%s", named, spec.store_symbols ? " (and in build/symbols)" : ""))
	channel := channel_of(o)
	if spec.channel_file {
		if os.write_entire_file(CHANNEL_FILE, fmt.tprintf("%s\r\n", channel)) != nil { return say_fail(o, fmt.tprintf("%s cannot be written", CHANNEL_FILE)) }
		tooling.say(o.log, fmt.tprintfln("built %s (%s, %s channel)", program, spec.name, channel))
	} else {
		tooling.say(o.log, fmt.tprintfln("built %s", program))
	}
	return true
}

channel_of :: proc(o: Options) -> string { return VARIANTS[o.variant].release_channel ? "release" : "dev" }

// The flags every variant shares, in the order build.bat gave them.
common_flags :: proc(o: Options) -> []string {
	f := make([dynamic]string, context.temp_allocator)
	release := VARIANTS[o.variant].release_channel
	// collections: "toolkit:<package>" and "wb:<package>"; the channel and its icon
	append(&f, fmt.tprintf("-collection:toolkit=%s", o.toolkit != "" ? o.toolkit : TOOLKIT_DEFAULT), "-collection:wb=src")
	append(&f, fmt.tprintf("-resource:%s", release ? "src/browser/wren.rc" : "src/browser/wren_dev.rc"), fmt.tprintf("-define:WREN_CHANNEL=%s", channel_of(o)))
	// /MAP: the linker's map (every function's address) next to the exe, the symbols of a release, which has no PDB (it changes nothing in the exe)
	append(&f, fmt.tprintf("-extra-linker-flags:/STACK:%d /MAP", STACK_BYTES))
	append(&f, fmt.tprintf("-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=%d", TEMP_ALLOCATOR_BACKING_BYTES))
	commit, date := source_commit()
	append(&f, fmt.tprintf("-define:WREN_COMMIT=%s", commit))
	if date != "" { append(&f, fmt.tprintf("-define:WREN_COMMIT_DATE=%s", date)) }
	if o.label != "" { append(&f, fmt.tprintf("-define:WREN_VERSION_LABEL=%s", o.label)) }
	if o.accept_dev_key { append(&f, "-define:WREN_ACCEPT_DEV_LICENSE_KEY=true") }
	if o.embedded_license != "" { append(&f, fmt.tprintf("-define:WREN_EMBEDDED_LICENSE=%s", o.embedded_license)) }
	append(&f, "-vet", "-subsystem:windows")
	if o.wgpu { append(&f, "-define:TOOLKIT_RENDER=wgpu", "-define:WGPU_SHARED=true") }
	if o.tracy { append(&f, "-define:WREN_TRACY=true") }
	append(&f, ..strings.fields(o.odin_extra, context.temp_allocator))
	// text: the toolkit's native text backend (Fontations, HarfRust and ICU4X, built into Wren's Rust library by deps: a program links one Rust static library at most) shapes, breaks and reads the
	// fonts (the system's fonts and their fallback come from DirectWrite in both)
	if !o.dwrite { append(&f, "-define:FONT_BACKEND=native", "-define:FONT_NATIVE_LINK=false") }
	// accessibility: the toolkit's AccessKit adapter (UI Automation), built into the same library (feature `a11y` of native\wren_native)
	append(&f, "-define:A11Y_ACCESSKIT=true", "-define:A11Y_NATIVE_LINK=false")
	return f[:]
}

// The version of the sources (about.odin: APP_COMMIT, APP_COMMIT_DATE): g<short hash> as git describe writes it (Odin would read an all-digit value as a number), "+" when the tree has uncommitted
// changes, and its date; "dev" and no date without git.
source_commit :: proc() -> (commit, date: string) {
	hash, code := tooling.capture({"git", "rev-parse", "--short", "HEAD"}, allocator = context.temp_allocator)
	if code != 0 || strings.trim_space(hash) == "" { return "dev", "" }
	commit = fmt.tprintf("g%s", strings.trim_space(hash))
	if when_text, c := tooling.capture({"git", "log", "-1", "--format=%cs"}, allocator = context.temp_allocator); c == 0 { date = strings.trim_space(when_text) }
	if _, dirty := tooling.capture({"git", "diff", "--quiet", "HEAD", "--"}, allocator = context.temp_allocator); dirty != 0 { commit = fmt.tprintf("%s+", commit) }
	return
}

// Is `odin` the release odin.version names?
odin_matches :: proc(o: Options) -> bool {
	data, err := os.read_entire_file(ODIN_VERSION_FILE, context.temp_allocator)
	if err != nil { return say_fail(o, fmt.tprintf("%s cannot be read", ODIN_VERSION_FILE)) }
	want := strings.trim_space(string(data))
	found, _ := tooling.capture({tooling.odin_program(), "version"}, allocator = context.temp_allocator)
	if strings.contains(found, want) { return true }
	return say_fail(o, fmt.tprintf("This tree needs Odin %s (odin.version); found: %s\nInstall that release, or set WREN_ANY_ODIN=1 to build anyway.", want, strings.trim_space(found)))
}

// bindgen, as an exe of its own deleted after: two builds at once (test_all in two trees, by hand beside it) would write the same one together and one would be refused (Error(013)).
bindgen :: proc(o: Options) -> bool {
	exe := fmt.tprintf("build/bindgen_%d_%d%s", os.get_pid(), rand.uint32(), tooling.EXE_SUFFIX)
	defer _ = os.remove(exe)
	return tooling.run({command = {tooling.odin_program(), "run", "src/tools/bindgen", "-collection:wb=src", "-vet", SEPARATE_MODULES, fmt.tprintf("-out:%s", exe)}, log = o.log}) == 0
}

// build/wren.com, the console launcher (src\tools\wrencom, core library only): cmd and PowerShell prefer it to wren.exe when `wren` is typed; wren.exe embeds it (src\browser\console_launcher.odin)
// and Setup writes it beside itself with the PATH entry. Built only when a source is newer than it: two builds at once would otherwise both write it, and one of them is refused (Error(013)) when
// the other, or a test that runs it, holds the file.
launcher :: proc(log: string) -> bool {
	odin_source :: proc(path: string) -> bool { return strings.has_suffix(path, ".odin") }
	if built, ok := tooling.modified(LAUNCHER); ok && !tooling.any_newer(LAUNCHER_SOURCES, built, odin_source) { return true }
	return tooling.run({command = {tooling.odin_program(), "build", LAUNCHER_SOURCES, "-vet", "-subsystem:console", "-o:size", fmt.tprintf("-out:%s", LAUNCHER)}, log = log}) == 0
}

// The version the sources say.
source_version :: proc() -> string {
	data, err := os.read_entire_file(ABOUT_FILE, context.temp_allocator)
	if err != nil { return "" }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if !strings.has_prefix(line, VERSION_MARK) { continue }
		a := strings.index_byte(line, '"')
		b := strings.last_index_byte(line, '"')
		if a >= 0 && b > a { return line[a + 1:b] }
	}
	return ""
}

// The label of a build that is not the release (WREN_VERSION_LABEL), as a file's name may carry it: "-<label>", "" without one.
version_label :: proc(label: string) -> string {
	if label == "" { return "" }
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '-')
	for c in transmute([]u8)label {
		good := c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-'
		strings.write_byte(&b, good ? c : '-')
	}
	return strings.to_string(b)
}

// build/wren_version.h for the version resource: rewritten only when its content changes, to leave the link alone on a build that changes nothing.
version_h :: proc(label: string) -> bool {
	v := source_version()
	parts := strings.split(v, ".", context.temp_allocator)
	if len(parts) != 3 { return false }
	text := fmt.tprintf("// Generated by wrentool build from APP_VERSION (src/browser/about.odin): do not edit.\r\n#define WREN_VER_MAJOR %s\r\n#define WREN_VER_MINOR %s\r\n#define WREN_VER_PATCH %s\r\n#define WREN_VER_STRING \"%s\"\r\n#define WREN_VER_PRODUCT \"%s%s\"\r\n\r\n", parts[0], parts[1], parts[2], v, v, version_label(label))
	_ = os.make_directory_all("build")
	if have, err := os.read_entire_file(VERSION_H, context.temp_allocator); err == nil && string(have) == text { return true }
	return os.write_entire_file(VERSION_H, text) == nil
}

@(private) env :: proc(name: string) -> string { v, _ := os.lookup_env(name, context.temp_allocator); return v }

@(private) say_fail :: proc(o: Options, text: string) -> bool {
	tooling.say(o.log, fmt.tprintln(text))
	if o.log != "" { fmt.eprintln(text) }
	return false
}

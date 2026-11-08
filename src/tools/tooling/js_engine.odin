package tooling

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import toolbox "../../../ext/gui_toolkit/src/toolbox"

// Wren's JavaScript engine: the Odin engine (src/engine/jsrt, through the QuickJS C API of src/engine/jscapi) and the browser's bindings (native/js/odin, with the generated
// native/js/odin/bindings_gen.odin), compiled to WebAssembly, then pre-initialized: the engine, its intrinsics and the bindings set up once, at build time, and stored in the module's
// memory image, so that a realm starts from that image instead of running the engine's start-up code. Outputs, in <out>: wren_js_raw.wasm, the engine as compiled (a WASI reactor);
// wren_js.wasm, the pre-initialized module the browser embeds (src/js/engine.odin); wren_js.code, its machine code, which the program embeds as well (not the test image's). The linker is the wasm-ld that ships with Odin (on Linux, the system's lld on the PATH). Nothing happens when <out>/STAMP matches the hash of
// every input (the glue, the engine and the host package that pre-initializes it).

// Not used to build anything: test262's configuration, and the reference wrentool bench js measures against, are QuickJS-ng's release source (src/browser/about_wren_test.odin and
// wrentool bench js read these two lines).
QJS_VERSION :: "0.17.0"
QJS_SHA256 :: "559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9"

// The stack in linear memory, first in it (--stack-first: running past its end is a trap, not a write over the engine's data). Every page of it is committed for each realm, touched or not: a
// recursion that runs past it goes on in the engine's heap (src/engine/jsrt/stack.odin, for which the host moves the stack pointer: the export). The engine's limit comes from what the linker made of this.
WASM_STACK_BYTES :: 2 << 20
JS_OUT_DEFAULT :: "build/js"
JS_CODE_NAME :: "wren_js.code"   // the machine code of wren_js.wasm, which the program ships (src/wasm/shipped.odin, src/js/image/code)
THIS_FILE :: "src/tools/tooling/js_engine.odin"
BYTES_PER_KIB :: 1024

Js_Options :: struct {
	out:         string,     // "": build/js
	force:       bool,
	names:       bool,       // the function names kept in the module (a readable profile)
	no_snapshot: bool,       // stop at the raw module
	test262:     bool,       // the test image: $262, print, the module loader (native/js/odin/test262_host.odin)
	odin_opt:    string,     // the -o: of the glue and engine ("": speed)
	odin_flags:  []string,   // more flags for them (WREN_ODIN_FLAGS, ;-separated)
	log:         string,     // "": standard output
}

@(private = "file")
collect_inputs :: proc(dir: string, recursive: bool, suffixes: []string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory {
			if recursive { collect_inputs(e.fullpath, true, suffixes, out) }
			continue
		}
		for s in suffixes {
			if strings.has_suffix(e.name, s) { append(out, strings.clone(e.fullpath, context.temp_allocator)); break }
		}
	}
}

// The packages the glue compiles, followed through their imports (relative and wb:, not the compiler's own) from GLUE_PACKAGE: their sources, tests aside, and what they
// #load. Not the folders beside them that nothing imports (the engine's judges and generators, the ABI's benches and checks): a change there builds nothing again.
GLUE_PACKAGE :: "native/js/odin"
WB_COLLECTION :: "src"
TOOLKIT_COLLECTION :: "ext/gui_toolkit/src"

@(private = "file")
quoted_after :: proc(line, prefix: string) -> (string, bool) {
	k := strings.index(line, prefix)
	if k < 0 { return "", false }
	rest := line[k + len(prefix):]
	a := strings.index_byte(rest, '"')
	if a < 0 { return "", false }
	b := strings.index_byte(rest[a + 1:], '"')
	if b < 0 { return "", false }
	return rest[a + 1:][:b], true
}

@(private = "file")
glue_inputs :: proc(dir: string, seen: ^map[string]bool, out: ^[dynamic]string) {
	clean, _ := filepath.clean(dir, context.temp_allocator)
	key, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
	if key in seen { return }
	seen[key] = true
	entries, err := os.read_all_directory_by_path(key, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") { continue }
		path := strings.clone(e.fullpath, context.temp_allocator)
		append(out, path)
		data, _ := os.read_entire_file(path, context.temp_allocator)
		for line in strings.split_lines(string(data), context.temp_allocator) {
			l := strings.trim_space(line)
			if strings.has_prefix(l, "import ") {
				target, ok := quoted_after(l, "import")
				if !ok || strings.has_prefix(target, "base:") || strings.has_prefix(target, "core:") || strings.has_prefix(target, "vendor:") { continue }
				switch {
				case strings.has_prefix(target, "wb:"): glue_inputs(fmt.tprintf("%s/%s", WB_COLLECTION, target[3:]), seen, out)
				case strings.has_prefix(target, "toolkit:"): glue_inputs(fmt.tprintf("%s/%s", TOOLKIT_COLLECTION, target[8:]), seen, out)
				case: glue_inputs(fmt.tprintf("%s/%s", key, target), seen, out)
				}
			}
			if loaded, ok := quoted_after(l, "#load_directory("); ok {
				collect_inputs(fmt.tprintf("%s/%s", key, loaded), false, {""}, out)
			} else if loaded, ok = quoted_after(l, "#load("); ok {
				append(out, fmt.tprintf("%s/%s", key, loaded))
			}
		}
	}
}

// What the engine is made of: change any of it and it is built again. The glue's packages (glue_inputs); the snapshot tool and the runtime it runs the engine on, tests aside.
@(private = "file")
js_stamp :: proc(o: Js_Options) -> string {
	files := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	glue_inputs(GLUE_PACKAGE, &seen, &files)
	for dir in ([]string{"src/wasm", "src/tools/jsengine"}) {
		start := len(files)
		collect_inputs(dir, false, {".odin"}, &files)
		kept := start
		for f in files[start:] { if !strings.has_suffix(f, "_test.odin") { files[kept] = f; kept += 1 } }
		resize(&files, kept)
	}
	append(&files, THIS_FILE)
	slice.sort(files[:])
	all := strings.builder_make(context.temp_allocator)
	for f in files {
		name, _ := strings.replace_all(f, "\\", "/", context.temp_allocator)
		strings.write_string(&all, name)
		data, _ := os.read_entire_file(f, context.temp_allocator)
		strings.write_bytes(&all, data)
	}
	fmt.sbprintf(&all, "%v|%s|%v|%v", o.test262, o.odin_opt, o.odin_flags, o.names)
	return toolbox.sha256_hex(all.buf[:])
}

// src/tools/jsengine, in <out>: the tool that pre-initializes the image and compiles it.
@(private = "file")
build_jsengine_tool :: proc(o: Js_Options) -> (exe: string, ok: bool) {
	exe = fmt.tprintf("%s/jsengine%s", o.out, EXE_SUFFIX)
	build := make([dynamic]string, context.temp_allocator)
	append(&build, odin_program(), "build", "src/tools/jsengine", "-collection:wb=src", "-vet", fmt.tprintf("-out:%s", exe), "-o:speed")
	append(&build, ..STACK_FLAGS)
	if run({command = build[:], log = o.log}) != 0 { say(o.log, "building src/tools/jsengine failed\n"); return "", false }
	return exe, true
}

// The image's machine code for this system, from an image built elsewhere: only Windows builds the image, and code is made for the system it runs on (Linux: build.sh).
build_js_code :: proc(options: Js_Options) -> bool {
	o := options
	if o.out == "" { o.out = JS_OUT_DEFAULT }
	final := fmt.tprintf("%s/wren_js.wasm", o.out)
	if !os.exists(final) { say(o.log, fmt.tprintfln("%s is missing", final)); return false }
	code := fmt.tprintf("%s/%s", o.out, JS_CODE_NAME)
	// (the empty file test_all leaves where no image was built: no engine in the program, no code for it)
	if info, err := os.stat(final, context.temp_allocator); err == nil && info.size == 0 { return os.write_entire_file(code, "") == nil }
	exe := build_jsengine_tool(o) or_return
	return run({command = {exe, "precompile", final, code}, log = o.log}) == 0
}

// Builds it unless it is up to date. False: said in the log.
build_js_engine :: proc(options: Js_Options) -> bool {
	o := options
	if o.out == "" { o.out = JS_OUT_DEFAULT }
	if o.odin_opt == "" { o.odin_opt = "speed" }
	raw := fmt.tprintf("%s/wren_js_raw.wasm", o.out)
	final := fmt.tprintf("%s/wren_js.wasm", o.out)
	stamp_file := fmt.tprintf("%s/STAMP", o.out)
	stamp := js_stamp(o)
	if !o.force && os.exists(final) && (o.test262 || os.exists(fmt.tprintf("%s/%s", o.out, JS_CODE_NAME))) {
		known, err := os.read_entire_file(stamp_file, context.temp_allocator)
		if err == nil && strings.trim_space(string(known)) == stamp {
			say(o.log, fmt.tprintfln("wren_js up to date in %s", o.out))
			return true
		}
	}
	root_text, root_code := capture({odin_program(), "root"})
	if root_code != 0 { say(o.log, "`odin root` failed\n"); return false }
	wasm_ld, _ := filepath.join({strings.trim_space(root_text), "bin", strings.concatenate({"wasm-ld", EXE_SUFFIX})}, context.temp_allocator)
	// (Odin's Windows release ships it; its Linux release does not, and the system's lld does: wasm-ld from the PATH)
	if !os.exists(wasm_ld) {
		_, found := capture({"wasm-ld", "--version"})
		if found != 0 { say(o.log, fmt.tprintfln("%s not found, nor wasm-ld on the PATH (Odin's Windows release ships it; on Linux, lld)", wasm_ld)); return false }
		wasm_ld = "wasm-ld"
	}
	_ = os.make_directory_all(o.out)

	// The glue and engine to one freestanding wasm32 object, no Odin runtime start-up (wj_preinit runs it). -o:speed: the natives gain more than the interpreter loses on a page (round 34 of docs/performance.md).
	object := fmt.tprintf("%s/odin_glue.o", o.out)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_program(), "build", "native/js/odin", "-build-mode:obj", "-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-vet",
		fmt.tprintf("-o:%s", o.odin_opt))
	append(&cmd, ..o.odin_flags)
	append(&cmd, "-collection:wb=src", "-collection:toolkit=ext/gui_toolkit/src", "-define:WJ_JSRT=true", "-define:JSCAPI_EXPORT=true")
	if o.test262 { append(&cmd, "-define:WREN_TEST262=true") }
	append(&cmd, fmt.tprintf("-out:%s", object))
	if run({command = cmd[:], log = o.log}) != 0 { say(o.log, "the odin build of native/js/odin failed\n"); return false }

	link := make([dynamic]string, context.temp_allocator)
	append(&link, wasm_ld, "--no-entry", "--gc-sections", "--stack-first", "--export=__stack_pointer", "--extra-features=mutable-globals", "-z", fmt.tprintf("stack-size=%d", WASM_STACK_BYTES))
	if !o.names { append(&link, "--strip-debug") }
	append(&link, object, "-o", raw)
	if run({command = link[:], log = o.log}) != 0 { say(o.log, "wasm-ld failed\n"); return false }
	if o.no_snapshot { return true }

	// Pre-initialize (src/tools/jsengine: runs wj_preinit under Wasmtime and writes the snapshot). Wasm calls run on the main thread: room for wasm.wasmtime.max_stack_bytes.
	// (in <out>: the test image of test262 is built beside the browser's engine, at the same time)
	exe := build_jsengine_tool(o) or_return
	if run({command = {exe, "snapshot", raw, final}, log = o.log}) != 0 { say(o.log, "the pre-initialization of the engine failed\n"); return false }
	if !o.test262 && run({command = {exe, "precompile", final, fmt.tprintf("%s/%s", o.out, JS_CODE_NAME)}, log = o.log}) != 0 { say(o.log, "the engine's machine code could not be made\n"); return false }
	if os.write_entire_file(stamp_file, stamp) != nil { return false }
	if fi, err := os.stat(final, context.temp_allocator); err == nil {
		say(o.log, fmt.tprintfln("built %s (%d KiB)", final, fi.size / BYTES_PER_KIB))
	}
	return true
}

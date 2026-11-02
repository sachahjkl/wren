package tooling

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Wren's JavaScript engine: the Odin engine (src/engine/jsrt, through the QuickJS C API of src/engine/jscapi) and the browser's bindings (native/js/odin, with the generated
// native/js/odin/bindings_gen.odin), compiled to WebAssembly, then pre-initialized: the engine, its intrinsics and the bindings set up once, at build time, and stored in the module's
// memory image, so that a realm starts from that image instead of running the engine's start-up code. Outputs, in <out>: wren_js_raw.wasm, the engine as compiled (a WASI reactor);
// wren_js.wasm, the pre-initialized module the browser embeds (src/js/engine.odin). The linker is the wasm-ld that ships with Odin. Nothing happens when <out>/STAMP matches the hash of
// every input (the glue, the engine and the host package that pre-initializes it).

// Not used to build anything: test262's configuration, and the reference js_bench.ps1 measures against, are QuickJS-ng's release source (src/browser/about_wren_test.odin and
// tools/js_bench.ps1 read these two lines).
QJS_VERSION :: "0.17.0"
QJS_SHA256 :: "559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9"

// The C stack in linear memory: JavaScript recursion depth is bounded by JS_SetMaxStackSize (768 KiB); the rest is room for what runs past that bound before unwinding (reporting
// the RangeError of a listener deep in a recursion through the browser: its error event, the host calls). Each realm commits its stack: 1 MiB, not more.
WASM_STACK_BYTES :: 1048576
JS_OUT_DEFAULT :: "build/js"
THIS_FILE :: "src/tools/tooling/js_engine.odin"
BYTES_PER_KIB :: 1024

Js_Options :: struct {
	out:         string,     // "": build/js
	force:       bool,
	names:       bool,       // the function names kept in the module (a readable profile)
	no_snapshot: bool,       // stop at the raw module
	test262:     bool,       // the test image: $262, print, the module loader (native/js/odin/test262_host.odin)
	odin_opt:    string,     // the -o: of the glue and engine ("": size)
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

// What the engine is made of: change any of it and it is built again (the Odin engine and its packages count: the glue imports them from src).
@(private = "file")
js_stamp :: proc(o: Js_Options) -> string {
	files := make([dynamic]string, context.temp_allocator)
	collect_inputs("native/js", true, {".c", ".h", ".js", ".odin"}, &files)
	collect_inputs("src/engine", true, {".odin"}, &files)
	collect_inputs("src/wasm", false, {".odin"}, &files)
	collect_inputs("src/tools/jsengine", false, {".odin"}, &files)
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
	return sha256_of(all.buf[:], context.temp_allocator)
}

// Builds it unless it is up to date. False: said in the log.
build_js_engine :: proc(options: Js_Options) -> bool {
	o := options
	if o.out == "" { o.out = JS_OUT_DEFAULT }
	if o.odin_opt == "" { o.odin_opt = "size" }
	raw := fmt.tprintf("%s/wren_js_raw.wasm", o.out)
	final := fmt.tprintf("%s/wren_js.wasm", o.out)
	stamp_file := fmt.tprintf("%s/STAMP", o.out)
	stamp := js_stamp(o)
	if !o.force && os.exists(final) {
		known, err := os.read_entire_file(stamp_file, context.temp_allocator)
		if err == nil && strings.trim_space(string(known)) == stamp {
			say(o.log, fmt.tprintfln("wren_js up to date in %s", o.out))
			return true
		}
	}
	root_text, root_code := capture({odin_program(), "root"})
	if root_code != 0 { say(o.log, "`odin root` failed\n"); return false }
	wasm_ld, _ := filepath.join({strings.trim_space(root_text), "bin", strings.concatenate({"wasm-ld", EXE_SUFFIX})}, context.temp_allocator)
	if !os.exists(wasm_ld) { say(o.log, fmt.tprintfln("%s not found (it ships with Odin)", wasm_ld)); return false }
	_ = os.make_directory_all(o.out)

	// The glue and engine to one freestanding wasm32 object, no Odin runtime start-up (wj_preinit runs it), -o:size to match the engine's size budget.
	object := fmt.tprintf("%s/odin_glue.o", o.out)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin_program(), "build", "native/js/odin", "-build-mode:obj", "-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-vet",
		fmt.tprintf("-o:%s", o.odin_opt))
	append(&cmd, ..o.odin_flags)
	append(&cmd, "-collection:wb=src", "-collection:toolkit=ext/gui_toolkit", "-define:WJ_JSRT=true", "-define:JSCAPI_EXPORT=true")
	if o.test262 { append(&cmd, "-define:WREN_TEST262=true") }
	append(&cmd, fmt.tprintf("-out:%s", object))
	if run({command = cmd[:], log = o.log}) != 0 { say(o.log, "the odin build of native/js/odin failed\n"); return false }

	link := make([dynamic]string, context.temp_allocator)
	append(&link, wasm_ld, "--no-entry", "--gc-sections", "-z", fmt.tprintf("stack-size=%d", WASM_STACK_BYTES))
	if !o.names { append(&link, "--strip-debug") }
	append(&link, object, "-o", raw)
	if run({command = link[:], log = o.log}) != 0 { say(o.log, "wasm-ld failed\n"); return false }
	if o.no_snapshot { return true }

	// Pre-initialize (src/tools/jsengine: runs wj_preinit under Wasmtime and writes the snapshot). Wasm calls run on the main thread: room for wasm.wasmtime.max_stack_bytes.
	exe := fmt.tprintf("build/jsengine%s", EXE_SUFFIX)
	build := make([dynamic]string, context.temp_allocator)
	append(&build, odin_program(), "build", "src/tools/jsengine", "-collection:wb=src", "-vet", fmt.tprintf("-out:%s", exe), "-o:speed")
	append(&build, ..STACK_FLAGS)
	if run({command = build[:], log = o.log}) != 0 { say(o.log, "building src/tools/jsengine failed\n"); return false }
	if run({command = {exe, "snapshot", raw, final}, log = o.log}) != 0 { say(o.log, "the pre-initialization of the engine failed\n"); return false }
	if os.write_entire_file(stamp_file, stamp) != nil { return false }
	if fi, err := os.stat(final, context.temp_allocator); err == nil {
		say(o.log, fmt.tprintfln("built %s (%d KiB)", final, fi.size / BYTES_PER_KIB))
	}
	return true
}

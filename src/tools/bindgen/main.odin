// bindgen: generates every copy of the web API from its description (api/*.widl, see src/tools/bindgen/idl).
//   bindgen          writes what changed (build.bat runs it)
//   bindgen -check   writes nothing, fails if a generated file is missing, stale or left over (test_all runs it)
// Run from the repository root. Targets:
//   * the browser API: api/*.widl -> src/page/api_generated.odin (host), sdk/odin/web/<module>.odin (guest SDK),
//     native/js/gen/wren_api.h (C guests), docs/api/*.md, examples/apiconformance + src/tools/apiconformance/cases_generated.odin (conformance tests)
//   * the host-call benchmark: src/tools/wasmbench/bench.widl -> its host and guest bindings
package bindgen

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "wb:tools/bindgen/idl"
import "wb:tools/bindgen/jsgen"
import "wb:tools/bindgen/webidl"

Target :: struct {
	sources:          []string,   // .widl files or directories of them
	host:             idl.Host_Config,
	host_out:         string,
	guest_package:    string,
	guest_dir:        string,     // one file per module ("" = none)
	guest_file:       string,     // or everything in one file
	docs_dir:         string,
	conf_guest:       string,
	conf_guest_pkg:   string,
	conf_table:       string,
	conf_table_pkg:   string,
	c_header:         string,     // the imports for C guests ("" = none)
}

PAGE_HOST :: idl.Host_Config{
	package_name = "page", wasm_import = "wb:wasm", call_type = "Call", begin = "api_begin", raise = "api_raise",
	scrub = "utf8_scrub", invoke = "call_guest", call_export = "call_export", invoke_ctx = "^Page", collection = "wb:",
}

BENCH_HOST :: idl.Host_Config{
	package_name = "wasmbench", wasm_import = "wb:wasm", call_type = "Call", begin = "api_begin", raise = "api_raise",
	scrub = "api_scrub", invoke = "api_invoke", call_export = "api_call_export", invoke_ctx = "rawptr", collection = "wb:",
}

TARGETS := [?]Target{
	{
		sources = {"api"}, host = PAGE_HOST, host_out = "src/page/api_generated.odin",
		guest_package = "web", guest_dir = "sdk/odin/web", docs_dir = "docs/api",
		conf_guest = "examples/apiconformance/main.odin", conf_guest_pkg = "apiconformance",
		conf_table = "src/tools/apiconformance/cases_generated.odin", conf_table_pkg = "apiconformance",
		c_header = "native/js/gen/wren_api.h",
	},
	{
		sources = {"src/tools/wasmbench/bench.widl"}, host = BENCH_HOST, host_out = "src/tools/wasmbench/bench_generated.odin",
		guest_package = "wasmbench", guest_file = "examples/wasmbench/bench_generated.odin",
	},
}

check_only: bool
problems: int
written: int

main :: proc() {
	for a in os.args[1:] {
		switch a {
		case "-check": check_only = true
		case:
			fmt.eprintfln("bindgen: unknown argument %s (usage: bindgen [-check])", a)
			os.exit(2)
		}
	}
	for t, i in TARGETS {
		api := run(t)
		if i == 0 { run_js(api) }
	}
	if problems > 0 {
		if check_only { fmt.eprintfln("bindgen: %d generated file(s) out of date: run bindgen (or build.bat)", problems) }
		os.exit(1)
	}
	if !check_only && written > 0 { fmt.printfln("bindgen: %d file(s) written", written) }
}

collect :: proc(sources: []string) -> []idl.File_Source {
	files := make([dynamic]idl.File_Source)
	paths := make([dynamic]string)
	for s in sources {
		if os.is_dir(s) {
			infos, err := os.read_all_directory_by_path(s, context.allocator)
			if err != nil { fmt.eprintfln("bindgen: cannot read %s", s); os.exit(1) }
			for fi in infos { if strings.has_suffix(fi.name, ".widl") { append(&paths, filepath.join({s, fi.name}) or_else "") } }
		} else {
			append(&paths, s)
		}
	}
	slice.sort(paths[:])
	for p in paths {
		data, err := os.read_entire_file(p, context.allocator)
		if err != nil { fmt.eprintfln("bindgen: cannot read %s", p); os.exit(1) }
		name, _ := strings.replace_all(p, "\\", "/")
		append(&files, idl.File_Source{name = name, text = string(data)})
	}
	return files[:]
}

run :: proc(t: Target) -> ^idl.Api {
	api := idl.load(collect(t.sources))
	if len(api.diags) > 0 {
		for d in api.diags { fmt.eprintfln("%s:%d:%d: %s", d.pos.file, d.pos.line, d.pos.col, d.msg) }
		fmt.eprintfln("bindgen: %d error(s) in the description", len(api.diags))
		os.exit(1)
	}
	emit(t.host_out, idl.emit_host(api, t.host))
	if t.guest_dir != "" {
		keep := make(map[string]bool)
		for m in api.modules {
			if m.partial { continue }
			path := filepath.join({t.guest_dir, fmt.tprintf("%s.odin", m.name)}) or_else ""
			emit(path, idl.emit_guest_module(api, idl.Guest_Config{package_name = t.guest_package}, m))
			keep[filepath.base(path)] = true
		}
		prune(t.guest_dir, ".odin", keep)
	}
	if t.guest_file != "" {
		b := strings.builder_make()
		for m in api.modules {
			if m.partial { continue }
			strings.write_string(&b, idl.emit_guest_module(api, idl.Guest_Config{package_name = t.guest_package}, m))
		}
		emit(t.guest_file, strings.to_string(b))
	}
	if t.docs_dir != "" {
		keep := make(map[string]bool)
		for f in idl.emit_docs(api, t.host) {
			emit(filepath.join({t.docs_dir, f.name}) or_else "", f.text)
			keep[f.name] = true
		}
		prune(t.docs_dir, ".md", keep)
	}
	if t.c_header != "" { emit(t.c_header, idl.emit_c_header(api, "WREN_API_H")) }
	if t.conf_guest != "" {
		c := idl.emit_conformance(api, t.conf_guest_pkg, t.conf_table_pkg)
		emit(t.conf_guest, c.guest)
		emit(t.conf_table, c.table)
	}
	return api
}

// The JavaScript bindings: the official Web IDL (native/js/webref) bound to the browser's API (src/tools/bindgen/jsgen).
WEBREF_DIR :: "native/js/webref"
JS_IMPL_DIR :: "native/js/runtime"

run_js :: proc(api: ^idl.Api) {
	sources := make([dynamic]webidl.Source)
	infos, err := os.read_all_directory_by_path(WEBREF_DIR, context.allocator)
	if err != nil { fmt.eprintfln("bindgen: cannot read %s", WEBREF_DIR); os.exit(1) }
	paths := make([dynamic]string)
	for fi in infos { if strings.has_suffix(fi.name, ".idl") { append(&paths, filepath.join({WEBREF_DIR, fi.name}) or_else "") } }
	slice.sort(paths[:])
	for p in paths {
		data, rerr := os.read_entire_file(p, context.allocator)
		if rerr != nil { fmt.eprintfln("bindgen: cannot read %s", p); os.exit(1) }
		name, _ := strings.replace_all(p, "\\", "/")
		append(&sources, webidl.Source{name = name, text = string(data)})
	}
	model := webidl.load(sources[:])
	for d in model.diags {
		if strings.contains(d.msg, "partial definitions only") || strings.contains(d.msg, "unknown") { continue }   // other specifications' partials
		fmt.eprintfln("%s:%d: %s", d.pos.file, d.pos.line, d.msg)
		problems += 1
	}
	out := jsgen.generate(api, model, scan_raw_impls(JS_IMPL_DIR), "page")
	emit("native/js/gen/bindings.c", out.c)
	emit("native/js/gen/bindings.h", out.h)
	emit("src/page/js_interfaces_generated.odin", out.odin)
	emit("docs/js/coverage.md", out.coverage)
}

// Names of the hand-written members: `wjr_<...>` functions defined (or declared) at the start of a line of the C files.
scan_raw_impls :: proc(dir: string) -> []string {
	out := make([dynamic]string)
	walk :: proc(dir: string, out: ^[dynamic]string) {
		infos, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil { return }
		for fi in infos {
			if fi.type == .Directory { walk(fi.fullpath, out); continue }
			if !strings.has_suffix(fi.name, ".c") { continue }
			data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
			if rerr != nil { continue }
			for line in strings.split_lines(string(data)) {
				if len(line) == 0 || line[0] == ' ' || line[0] == '\t' || line[0] == '/' || line[0] == '*' || line[0] == '#' { continue }
				i := strings.index(line, "wjr_")
				if i <= 0 { continue }
				j := i
				for j < len(line) && (line[j] == '_' || (line[j] >= 'a' && line[j] <= 'z') || (line[j] >= 'A' && line[j] <= 'Z') || (line[j] >= '0' && line[j] <= '9')) { j += 1 }
				if j < len(line) && line[j] == '(' {
					name := line[i:j]
					found := false
					for x in out { if x == name { found = true; break } }
					if !found { append(out, strings.clone(name)) }
				}
			}
		}
	}
	walk(dir, &out)
	return out[:]
}

// Writes `text` to `path` when it differs (or reports it with -check).
emit :: proc(path, text: string) {
	old, err := os.read_entire_file(path, context.allocator)
	if err == nil && string(old) == text { return }
	if check_only {
		fmt.eprintfln("bindgen: %s is %s", path, err == nil ? "out of date" : "missing")
		problems += 1
		return
	}
	_ = os.make_directory_all(filepath.dir(path))
	if werr := os.write_entire_file(path, transmute([]u8)text); werr != nil {
		fmt.eprintfln("bindgen: cannot write %s: %v", path, werr)
		problems += 1
		return
	}
	written += 1
}

// Deletes generated files of `dir` no description produces any more (hand-written files are left alone).
prune :: proc(dir, ext: string, keep: map[string]bool) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil { return }
	for fi in infos {
		if !strings.has_suffix(fi.name, ext) || fi.name in keep { continue }
		data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil || !strings.contains(string(data[:min(len(data), 200)]), idl.GENERATED_BY) { continue }
		if check_only {
			fmt.eprintfln("bindgen: %s is generated but no description produces it any more", fi.fullpath)
			problems += 1
			continue
		}
		_ = os.remove(fi.fullpath)
		written += 1
	}
}

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
	c_header:         string,     // the imports for C guests, when -emit:c ("" = none)
	odin_imports:     string,     // the imports for Odin guests, when -emit:odin ("" = none)
	odin_imports_pkg: string,
}

// Which glue the guest side is generated in. The host trampolines, the guest SDK, the docs and the conformance tests
// are the same whatever this is; only the low-level glue that a non-Odin / Odin guest links against differs:
//   c    native/js/gen/*  (wren_api.h imports, bindings.c interface table and QuickJS trampolines): the default, until
//        the JavaScript engine itself is Odin.
//   odin native/js/odin_gen/* (the interface table, trampolines against the wj layer): what the engine will link once
//        it is Odin (agent spk's wj_iface.odin).
// The foreign wr_* imports for Odin (native/js/odin/wj/wr_imports.odin) are emitted in both modes: the ported glue
// declares no import by hand.
Emit :: enum { C, Odin }
emit_mode: Emit = .C

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
		odin_imports = "native/js/odin/wj/wr_imports.odin", odin_imports_pkg = "wj",
	},
	{
		sources = {"src/tools/wasmbench/bench.widl"}, host = BENCH_HOST, host_out = "src/tools/wasmbench/bench_generated.odin",
		guest_package = "wasmbench", guest_file = "examples/wasmbench/bench_generated.odin",
	},
}

check_only: bool
problems: int
written: int
convert_widl: bool

main :: proc() {
	for a in os.args[1:] {
		switch {
		case a == "-check": check_only = true
		case a == "-emit:c": emit_mode = .C
		case a == "-emit:odin": emit_mode = .Odin
		case a == "-convert-widl": convert_widl = true
		case a == "-verify-roundtrip": verify_roundtrip(); return
		case:
			fmt.eprintfln("bindgen: unknown argument %s (usage: bindgen [-check] [-emit:c|-emit:odin] [-convert-widl])", a)
			os.exit(2)
		}
	}
	if convert_widl {
		run_convert()
		if !check_only && written > 0 { fmt.printfln("bindgen: %d file(s) written", written) }
		if problems > 0 { os.exit(1) }
		return
	}
	for t, i in TARGETS {
		api := run(t)
		if i == 0 {
			switch emit_mode {
			case .C:    run_js(api)
			case .Odin: run_js_odin(api)
			}
		}
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
	if emit_mode == .C && t.c_header != "" { emit(t.c_header, idl.emit_c_header(api, "WREN_API_H")) }
	// the Odin imports are emitted in both modes: the ported glue (native/js/odin, package wj) links against them
	// next to the C that still includes wren_api.h
	if t.odin_imports != "" { emit(t.odin_imports, idl.emit_odin_imports(api, t.odin_imports_pkg)) }
	if t.conf_guest != "" {
		c := idl.emit_conformance(api, t.conf_guest_pkg, t.conf_table_pkg)
		emit(t.conf_guest, c.guest)
		emit(t.conf_table, c.table)
	}
	return api
}

// bindgen -convert-widl: writes an Odin description file next to each api/*.widl, so the input can move off .widl.
// The Odin reader (idl.load_odin) produces the same Api, hence the same generated outputs (verified by diffing after
// pointing the targets' sources at the .odin files).
run_convert :: proc() {
	files := collect({"api"})
	api := idl.load(files)
	if len(api.diags) > 0 {
		for d in api.diags { fmt.eprintfln("%s:%d:%d: %s", d.pos.file, d.pos.line, d.pos.col, d.msg) }
		fmt.eprintfln("bindgen -convert-widl: %d error(s) in the description", len(api.diags))
		os.exit(1)
	}
	// one .odin per source module declaration (Odin: one package per file). A .widl declaring several modules — or the
	// same module several times (one full plus partials, or several partials) — gives several files; the filename
	// encodes the source, and the module name and an index when they would collide, so names stay unique and every
	// declaration survives. The logical module name is in the directive, so partials spread over files merge on read.
	names_in_file := make(map[string]int)      // (file) -> count of distinct module names
	seen := make(map[string]int)               // a stem -> how many times used so far
	seen_name := make(map[string]bool)         // (file|name) seen, to count distinct names per file
	for m in api.modules {
		key := strings.concatenate({m.file, "|", m.name})
		if key not_in seen_name { seen_name[key] = true; names_in_file[m.file] += 1 }
	}
	for m in api.modules {
		base := filepath.stem(filepath.base(m.file))
		root := names_in_file[m.file] > 1 ? fmt.tprintf("%s__%s", base, m.name) : base
		stem := root
		if n := seen[root]; n > 0 { stem = fmt.tprintf("%s_%d", root, n) }
		seen[root] += 1
		pkg := strings.concatenate({"api_", sanitize_pkg(stem)})
		out := idl.convert_module(api, m, pkg)
		emit(fmt.tprintf("api/%s.odin", stem), out)
	}
}

// A valid Odin package identifier from a file stem (dashes and the like become underscores).
sanitize_pkg :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		strings.write_byte(&b, ok ? c : '_')
	}
	return strings.to_string(b)
}

// bindgen -verify-roundtrip: loads api/*.widl and the converted api/*.odin (run -convert-widl first), generates the
// host, every guest SDK module, the docs and the conformance from each, and reports the first output that differs.
// The whole point of the Odin reader is that it changes nothing downstream; this is how that is proved.
verify_roundtrip :: proc() {
	t := TARGETS[0]
	widl := idl.load(collect({"api"}))
	odin_files := make([dynamic]idl.File_Source)
	infos, _ := os.read_all_directory_by_path("api", context.allocator)
	paths := make([dynamic]string)
	for fi in infos { if strings.has_suffix(fi.name, ".odin") { append(&paths, filepath.join({"api", fi.name}) or_else "") } }
	slice.sort(paths[:])
	for p in paths {
		data, _ := os.read_entire_file(p, context.allocator)
		name, _ := strings.replace_all(p, "\\", "/")
		append(&odin_files, idl.File_Source{name = name, text = string(data)})
	}
	odin := idl.load_odin(odin_files[:])
	if len(odin.diags) > 0 {
		for d in odin.diags { fmt.eprintfln("%s:%d:%d: %s", d.pos.file, d.pos.line, d.pos.col, d.msg) }
		fmt.eprintfln("bindgen -verify-roundtrip: the Odin form does not parse (%d error(s))", len(odin.diags))
		os.exit(1)
	}
	diffs := 0
	check :: proc(what, a, b: string, diffs: ^int) {
		if a == b { return }
		diffs^ += 1
		n := min(len(a), len(b))
		at := 0
		for at < n && a[at] == b[at] { at += 1 }
		lo := max(0, at - 40)
		fmt.eprintfln("bindgen -verify-roundtrip: %s differs at byte %d:\n  widl: ...%q\n  odin: ...%q", what, at, a[lo:min(len(a), at + 40)], b[lo:min(len(b), at + 40)])
	}
	check("host", idl.emit_host(widl, t.host), idl.emit_host(odin, t.host), &diffs)
	by_name := make(map[string]^idl.Module)
	for m in odin.modules { if !m.partial { by_name[m.name] = m } }
	for m in widl.modules {
		if m.partial { continue }
		om, ok := by_name[m.name]
		if !ok { fmt.eprintfln("bindgen -verify-roundtrip: module %s missing from the Odin form", m.name); diffs += 1; continue }
		check(fmt.tprintf("guest %s", m.name), idl.emit_guest_module(widl, idl.Guest_Config{package_name = t.guest_package}, m), idl.emit_guest_module(odin, idl.Guest_Config{package_name = t.guest_package}, om), &diffs)
	}
	// docs carry a "Source: `api/<file>`" line and a count of modules per spec in the README: these legitimately name
	// the new .odin files, so they are normalized away before comparing (the migration renames the source, the
	// documented API does not change).
	strip_source :: proc(s: string) -> string {
		// drop the "Source: `...`." clause wherever it appears (it names the file, which the migration renames)
		b := strings.builder_make(context.allocator)
		rest := s
		for {
			i := strings.index(rest, "Source: `")
			if i < 0 { strings.write_string(&b, rest); break }
			strings.write_string(&b, rest[:i])
			rest = rest[i:]
			j := strings.index(rest, "`.")
			if j < 0 { strings.write_string(&b, rest); break }
			rest = rest[j + 2:]
		}
		return strings.to_string(b)
	}
	dw := idl.emit_docs(widl, t.host)
	docs_odin := idl.emit_docs(odin, t.host)
	docs_by_name := make(map[string]string)
	for f in docs_odin { docs_by_name[f.name] = f.text }
	for f in dw {
		if f.name == "README.md" { continue }   // the by-spec table keys on the file name: covered by per-module docs
		check(fmt.tprintf("docs %s", f.name), strip_source(f.text), strip_source(docs_by_name[f.name] or_else ""), &diffs)
	}
	cw := idl.emit_conformance(widl, t.conf_guest_pkg, t.conf_table_pkg)
	co := idl.emit_conformance(odin, t.conf_guest_pkg, t.conf_table_pkg)
	check("conformance guest", cw.guest, co.guest, &diffs)
	check("conformance table", cw.table, co.table, &diffs)
	check("odin imports", idl.emit_odin_imports(widl, t.odin_imports_pkg), idl.emit_odin_imports(odin, t.odin_imports_pkg), &diffs)
	if diffs == 0 { fmt.println("bindgen -verify-roundtrip: identical (host, guests, docs, conformance, imports)") } else { os.exit(1) }
}

// The JavaScript bindings: the official Web IDL (native/js/webref) bound to the browser's API (src/tools/bindgen/jsgen).
WEBREF_DIR :: "native/js/webref"
JS_IMPL_DIR :: "native/js/odin"

run_js :: proc(api: ^idl.Api) {
	model := load_webidl_model()
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

// -emit:odin counterpart of run_js: the interface metadata table in Odin (native/js/odin_gen), against wj_iface.odin.
// The node-interface indices and the coverage are emitted either way; the member glue bodies are not generated here
// yet (they need spk's wj conversions), so the table's fn/get/set slots stay nil and spk fills them.
run_js_odin :: proc(api: ^idl.Api) {
	model := load_webidl_model()
	out := jsgen.generate(api, model, scan_raw_impls(JS_IMPL_DIR), "page", jsgen.Mode.Odin)
	emit("native/js/odin_gen/js_interfaces_table.odin", out.odin_tables)
	emit("src/page/js_interfaces_generated.odin", out.odin)
	emit("docs/js/coverage.md", out.coverage)
}

// Loads native/js/webref/*.idl into a webidl.Model (shared by run_js and run_js_odin).
load_webidl_model :: proc() -> ^webidl.Model {
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
	return webidl.load(sources[:])
}

// Names of the hand-written members: the `wjr_<...>` symbols the Odin glue exports (`@(export, link_name = "wjr_...")`).
// The glue used to be C files (native/js/runtime/*.c); it is Odin now, so this reads native/js/odin.
scan_raw_impls :: proc(dir: string) -> []string {
	out := make([dynamic]string)
	seen := make(map[string]bool)
	walk :: proc(dir: string, out: ^[dynamic]string, seen: ^map[string]bool) {
		infos, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil { return }
		for fi in infos {
			if fi.type == .Directory { walk(fi.fullpath, out, seen); continue }
			if !strings.has_suffix(fi.name, ".odin") { continue }
			data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
			if rerr != nil { continue }
			text := string(data)
			for {
				i := strings.index(text, "link_name = \"wjr_")
				if i < 0 { break }
				text = text[i + len("link_name = \""):]
				j := 0
				for j < len(text) && text[j] != '"' { j += 1 }
				name := text[:j]
				if name not_in seen^ { seen[strings.clone(name)] = true; append(out, strings.clone(name)) }
				text = text[j:]
			}
		}
	}
	walk(dir, &out, &seen)
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

// bindgen: generates every copy of the web API from its description (api/*.widl, see src/tools/bindgen/idl).
//   bindgen          writes what changed (wrentool build runs it)
//   bindgen -check   writes nothing, fails if a generated file is missing, stale or left over (test_all runs it)
// Run from the repository root. Targets:
//   * the browser API: api/*.widl -> src/page/api_generated.odin (host), sdk/odin/<package>/<module>.odin (guest SDK),
//     native/js/odin/wj/wr_imports.odin (the engine's imports), docs/api/*.md, examples/apiconformance +
//     src/tools/apiconformance/cases_generated.odin (conformance tests)
//   * the JavaScript bindings: native/js/webref/*.idl bound to the browser API -> native/js/odin/bindings_gen.odin,
//     src/page/js_interfaces_generated.odin, docs/js/coverage.md
//   * the extension namespaces: api/ext_<namespace>.widl -> src/page/ext_api_generated.odin (method table, decoders,
//     gates, constants), src/page/ext_api_generated_test.odin (conformance cases), docs/api/ext/*.md
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
	guest:            idl.Guest_Config,
	guest_dir:        string,     // the collection: <package>/<module>.odin ("" = none)
	guest_file:       string,     // or everything in one file
	docs_dir:         string,
	conf_guest:       string,
	conf_guest_pkg:   string,
	conf_table:       string,
	conf_table_pkg:   string,
	odin_imports:     string,     // the imports of the JavaScript engine's glue ("" = none)
	odin_imports_pkg: string,
	ext_host:         string,     // the extension namespaces (api/ext_<namespace>.widl): tables and decoders ("" = none)
	ext_cases:        string,     // their conformance cases (a _test file of the same package)
	ext_package:      string,
	ext_docs_dir:     string,
}

PAGE_HOST :: idl.Host_Config{
	package_name = "page", wasm_import = "wb:wasm", call_type = "Call", begin = "api_begin", route = "api_route", unroute = "api_unroute", raise = "api_raise",
	scrub = "utf8_scrub", invoke = "call_guest", call_export = "call_export", invoke_ctx = "^Page", collection = "wb:",
}

BENCH_HOST :: idl.Host_Config{
	package_name = "wasmbench", wasm_import = "wb:wasm", call_type = "Call", begin = "api_begin", raise = "api_raise",
	scrub = "api_scrub", invoke = "api_invoke", call_export = "api_call_export", invoke_ctx = "rawptr", collection = "wb:",
}

// The Odin SDK's packages of several modules (every other module is a package of its own name): core is what every
// package shares (errors, host objects, promises, buffers, event targets: the three modules name each other's types,
// and Odin packages cannot import each other), webcodecs the modules of one specification.
SDK_PACKAGES := [?]idl.Guest_Package{
	{name = "core", modules = {"web", "async", "events"}},
	{name = "webcodecs", modules = {"webcodecs", "webcodecs_audio_decoder", "webcodecs_codec", "webcodecs_encoders", "webcodecs_image", "webcodecs_video_decoder"}},
}

TARGETS := [?]Target{
	{
		sources = {"api"}, host = PAGE_HOST, host_out = "src/page/api_generated.odin",
		guest = {collection = "wren", packages = SDK_PACKAGES[:]}, guest_dir = "sdk/odin", docs_dir = "docs/api",
		conf_guest = "examples/apiconformance/main.odin", conf_guest_pkg = "apiconformance",
		conf_table = "src/tools/apiconformance/cases_generated.odin", conf_table_pkg = "apiconformance",
		odin_imports = "native/js/odin/wj/wr_imports.odin", odin_imports_pkg = "wj",
		ext_host = "src/page/ext_api_generated.odin", ext_cases = "src/page/ext_api_generated_test.odin", ext_package = "page",
		ext_docs_dir = "docs/api/ext",
	},
	{
		sources = {"src/tools/wasmbench/bench.widl"}, host = BENCH_HOST, host_out = "src/tools/wasmbench/bench_generated.odin",
		guest = {package_name = "wasmbench"}, guest_file = "examples/wasmbench/bench_generated.odin",
	},
}

check_only: bool
problems: int
written: int

main :: proc() {
	for a in os.args[1:] {
		switch {
		case a == "-check": check_only = true
		case:
			fmt.eprintfln("bindgen: unknown argument %s (usage: bindgen [-check])", a)
			os.exit(2)
		}
	}
	for t, i in TARGETS {
		api := run(t)
		// the JavaScript bindings bind the browser API, not the benchmark's
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
		for c in idl.guest_name_clashes(api, t.guest) { fmt.eprintfln("bindgen: the Odin SDK: %s", c); problems += 1 }
		keep := make(map[string]bool)   // <package>/<module>.odin
		for m in api.modules {
			if m.partial { continue }
			file := fmt.tprintf("%s/%s.odin", idl.guest_package_of(t.guest, m.name), m.name)
			emit(filepath.join({t.guest_dir, file}) or_else "", idl.emit_guest_module(api, t.guest, m))
			keep[file] = true
		}
		prune_packages(t.guest_dir, keep)
	}
	if t.guest_file != "" {
		b := strings.builder_make()
		for m in api.modules {
			if m.partial { continue }
			strings.write_string(&b, idl.emit_guest_module(api, t.guest, m))
		}
		emit(t.guest_file, strings.to_string(b))
	}
	if t.docs_dir != "" {
		keep := make(map[string]bool)
		for f in idl.emit_docs(api, t.host, t.guest) {
			emit(filepath.join({t.docs_dir, f.name}) or_else "", f.text)
			keep[f.name] = true
		}
		prune(t.docs_dir, ".md", keep)
	}
	if t.odin_imports != "" { emit(t.odin_imports, idl.emit_odin_imports(api, t.odin_imports_pkg)) }
	if t.conf_guest != "" {
		c := idl.emit_conformance(api, t.conf_guest_pkg, t.conf_table_pkg)
		emit(t.conf_guest, c.guest)
		emit(t.conf_table, c.table)
	}
	if t.ext_host != "" {
		emit(t.ext_host, idl.emit_ext_host(api, t.ext_package))
		emit(t.ext_cases, idl.emit_ext_cases(api, t.ext_package))
		keep := make(map[string]bool)
		for f in idl.emit_ext_docs(api) {
			emit(filepath.join({t.ext_docs_dir, f.name}) or_else "", f.text)
			keep[f.name] = true
		}
		prune(t.ext_docs_dir, ".md", keep)
	}
	return api
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
	for pr in out.problems { fmt.eprintfln("bindgen: %s", pr) }
	emit("native/js/odin/bindings_gen.odin", out.odin_glue)
	emit("src/page/js_interfaces_generated.odin", out.odin)
	emit("docs/js/coverage.md", out.coverage)
}

// Loads native/js/webref/*.idl into a webidl.Model.
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
	if jsgen.raw_idents == nil { jsgen.raw_idents = make(map[string]string) }
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
				// the identifier the symbol is declared with: the name before the next ::, on this line or the next
				rest := text[j:]
				if k := strings.index(rest, "::"); k > 0 {
					e := k
					for e > 0 && (rest[e - 1] == ' ' || rest[e - 1] == '\t') { e -= 1 }
					s := e
					for s > 0 && (rest[s - 1] == '_' || (rest[s - 1] >= 'a' && rest[s - 1] <= 'z') || (rest[s - 1] >= 'A' && rest[s - 1] <= 'Z') || (rest[s - 1] >= '0' && rest[s - 1] <= '9')) { s -= 1 }
					if e > s {
						in_wj := strings.contains(fi.fullpath, "\\wj\\") || strings.contains(fi.fullpath, "/wj/")
						jsgen.raw_idents[strings.clone(name)] = strings.concatenate({in_wj ? "wj." : "", rest[s:e]})
					}
				}
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

// prune over the package folders of a collection (`keep` names <package>/<file>); a folder left empty is removed.
prune_packages :: proc(root: string, keep: map[string]bool) {
	infos, err := os.read_all_directory_by_path(root, context.allocator)
	if err != nil { return }
	for fi in infos {
		if fi.type != .Directory { continue }
		in_dir := make(map[string]bool, context.temp_allocator)
		prefix := fmt.tprintf("%s/", fi.name)
		for k in keep { if strings.has_prefix(k, prefix) { in_dir[k[len(prefix):]] = true } }
		prune(fi.fullpath, ".odin", in_dir)
		if check_only { continue }
		if left, lerr := os.read_all_directory_by_path(fi.fullpath, context.temp_allocator); lerr == nil && len(left) == 0 { _ = os.remove(fi.fullpath) }
	}
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

package test_all

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// The package-level variables of the browser's packages (GLOBALS_DIRS; not the constants, procedures and types: `name :: ...`), against the list of those allowed (tools/globals_allowed.txt,
// one line each: "<dir>/<file> <name> <class>  # why"). A global that is not in the list fails, and so does one the list names that is gone (the list follows the code). The rule
// (docs/architecture.md, "Where state lives"): what is one App's lives in App (or what App owns: a window, a tab, a page), so that several Apps can run in one process, each on a thread
// of its own. A global is allowed only as what it is:
//   const     a table: written by the compiler, or once (a sync.Once) before anything reads it, and never again. Any thread reads it.
//   process   a resource of the process: there is one whatever the number of Apps (the Wasm engine, a thread pool, a library of the system, the single-instance channel). Any
//             thread may reach it: it is locked or atomic, or the note says which thread it is bound to.
//   app       one App's state still kept in a global: to move into App (the profile, the preferences read, a cache of its frames, a registry of its pages). Two Apps would share it.
//   window    one window's, read as the active window's: to move into Browser_Window.own (Window_Own)
//   page      one page's or tab's: to move into Page / Tab
//   thread    @(thread_local): each thread its own (and a global marked so is of this class)
//   test      a test's own
//   test_all -Globals        every global with its class
//   test_all -GlobalsWrite   the list rewritten from the code, keeping the classes known; new ones get "app?": to classify by hand

GLOBALS_LIST :: "tools/globals_allowed.txt"
// The packages whose globals are listed, under src.
GLOBALS_DIRS :: [?]string{"browser", "page", "style", "layout", "media", "js"}
GLOBAL_CLASSES :: [?]string{"const", "process", "app", "window", "page", "thread", "test"}

Global :: struct { file, name: string, test, thread_local: bool }
Listed :: struct { class, why: string }

// What the compiler's own parser reads: the top level, not inside a procedure, a struct, a foreign block or a `when`.
find_globals :: proc(dir: string, allocator := context.allocator) -> []Global {
	found := make([dynamic]Global, allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return nil }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator) })
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { continue }
		file := ast.File{src = string(data), fullpath = e.fullpath}
		p := parser.default_parser({.Optional_Semicolons})
		p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
		p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
		if !parser.parse_file(&p, &file) { fmt.eprintfln("%s does not parse", e.fullpath); continue }
		for decl in file.decls {
			v, is_value := decl.derived_stmt.(^ast.Value_Decl)
			if !is_value || !v.is_mutable { continue }
			local := is_thread_local(v)
			for name in v.names {
				if id, is_ident := name.derived_expr.(^ast.Ident); is_ident {
					append(&found, Global{strings.clone(e.name, allocator), strings.clone(id.name, allocator), strings.has_suffix(e.name, "_test.odin"), local})
				}
			}
		}
	}
	return found[:]
}

// `@(thread_local)`, alone or among other attributes (`@(private = "file", thread_local)`).
@(private = "file")
is_thread_local :: proc(v: ^ast.Value_Decl) -> bool {
	for a in v.attributes {
		for elem in a.elems {
			name := elem
			if fv, is_field := elem.derived_expr.(^ast.Field_Value); is_field { name = fv.field }
			if id, is_ident := name.derived_expr.(^ast.Ident); is_ident && id.name == "thread_local" { return true }
		}
	}
	return false
}

@(private = "file")
global_key :: proc(dir, file, name: string) -> string { return strings.concatenate({dir, "/", file, " ", name}) }

@(private = "file")
class_known :: proc(c: string) -> bool {
	classes := GLOBAL_CLASSES
	return slice.contains(classes[:], c)
}

// False when the code and the list disagree (or, with `write`, when the list cannot be written).
lint_globals :: proc(list := false, write := false, log := "") -> bool {
	Found :: struct { dir: string, g: Global }
	found := make([dynamic]Found)
	for dir in GLOBALS_DIRS {
		for g in find_globals(fmt.tprintf("src/%s", dir)) { append(&found, Found{dir, g}) }
	}
	known := make(map[string]Listed)
	header := make([dynamic]string)
	data, err := os.read_entire_file(GLOBALS_LIST, context.allocator)
	if err == nil {
		in_header := true
		text := string(data)
		for raw in strings.split_lines_iterator(&text) {
			line := strings.trim_right(raw, "\r")
			if strings.has_prefix(line, "#") && in_header { append(&header, line) }
			trimmed := strings.trim_space(line)
			if trimmed == "" || trimmed[0] == '#' { continue }
			in_header = false
			fields := strings.fields(trimmed)
			if len(fields) < 3 { continue }
			why := ""
			if at := strings.index(trimmed, "#"); at >= 0 { why = strings.trim_space(trimmed[at + 1:]) }
			known[strings.concatenate({fields[0], " ", fields[1]})] = {fields[2], why}
		}
	}
	if write {
		b := strings.builder_make()
		for h in header { fmt.sbprintln(&b, h) }
		for f in found {
			c, has := known[global_key(f.dir, f.g.file, f.g.name)]
			if !has { c = {f.g.test ? "test" : (f.g.thread_local ? "thread" : "app?"), ""} }
			fmt.sbprintf(&b, "%s/%s %s %s", f.dir, f.g.file, f.g.name, c.class)
			if c.why != "" { fmt.sbprintf(&b, "  # %s", c.why) }
			fmt.sbprintln(&b)
		}
		if os.write_entire_file(GLOBALS_LIST, strings.to_string(b)) != nil { return false }
		fmt.printfln("%d globals written to %s", len(found), GLOBALS_LIST)
		return true
	}
	fail := 0
	seen := make(map[string]bool)
	// per package, the count of each class (the last column: the package's own total)
	counts := make(map[string]map[string]int)
	out := strings.builder_make()
	for f in found {
		g := f.g
		k := global_key(f.dir, g.file, g.name)
		seen[k] = true
		c, has := known[k]
		class := has ? c.class : "NEW"
		if f.dir not_in counts { counts[f.dir] = make(map[string]int) }
		per := &counts[f.dir]
		per[class] += 1
		if list { fmt.sbprintfln(&out, "%-44s %-34s %s", fmt.tprintf("%s/%s", f.dir, g.file), g.name, class) }
		switch {
		case !has:
			fmt.sbprintfln(&out, "error: src\\%s\\%s: a new global '%s'. One App's state goes into App (or its window, tab or page); a table, a resource of the process or a thread's is added to tools\\globals_allowed.txt with its class and why (docs\\architecture.md, Where state lives)", f.dir, g.file, g.name)
			fail += 1
		case !class_known(c.class):
			fmt.sbprintfln(&out, "error: tools\\globals_allowed.txt gives '%s' the class '%s': it is one of const, process, app, window, page, thread, test", k, c.class)
			fail += 1
		case g.thread_local && c.class != "thread":
			fmt.sbprintfln(&out, "error: src\\%s\\%s: '%s' is @(thread_local): its class is thread, not %s", f.dir, g.file, g.name, c.class)
			fail += 1
		case !g.thread_local && c.class == "thread":
			fmt.sbprintfln(&out, "error: src\\%s\\%s: '%s' is of the class thread and is not @(thread_local): every thread would share it", f.dir, g.file, g.name)
			fail += 1
		}
	}
	for k in known {
		if k not_in seen {
			fmt.sbprintfln(&out, "error: tools\\globals_allowed.txt names '%s', which is no longer a global: take it out of the list", k)
			fail += 1
		}
	}
	fmt.sbprintf(&out, "globals: %d", len(found))
	for dir in GLOBALS_DIRS {
		per, any := counts[dir]
		if !any { continue }
		names := make([dynamic]string, context.temp_allocator)
		total := 0
		for c, n in per { append(&names, c); total += n }
		slice.sort(names[:])
		fmt.sbprintf(&out, "; src\\%s %d (", dir, total)
		for c, i in names { fmt.sbprintf(&out, "%s%s %d", i > 0 ? ", " : "", c, per[c]) }
		fmt.sbprint(&out, ")")
	}
	fmt.sbprintln(&out)
	tooling.say(log, strings.to_string(out))
	return fail == 0
}

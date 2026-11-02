package test_all

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// The package-level variables of src/browser (not the constants, procedures and types: `name :: ...`), against the list of those allowed (tools/globals_allowed.txt, one line each:
// "<file> <name> <class>  # why"). A global that is not in the list fails: the shell is moving its per-window state into the window (Browser_Window, windows.odin) and its per-tab state into
// the tab, so a new global of a window or a tab is to go there, not beside the others. One the list names that is gone fails too (the list follows the code). Classes:
//   process   the process's (the profile, the network, the fonts, the renderer, the loop, a table built once, statistics)
//   window    one window's, read as the active window's: to move into Browser_Window.own (Window_Own)
//   page      one page's or tab's: to move into Page / Tab
//   test      a test's own
//   test_all -Globals        every global with its class
//   test_all -GlobalsWrite   the list rewritten from the code, keeping the classes known; new ones get "window?": to classify by hand

GLOBALS_LIST :: "tools/globals_allowed.txt"
BROWSER_DIR :: "src/browser"

Global :: struct { file, name: string, test: bool }
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
			for name in v.names {
				if id, is_ident := name.derived_expr.(^ast.Ident); is_ident {
					append(&found, Global{strings.clone(e.name, allocator), strings.clone(id.name, allocator), strings.has_suffix(e.name, "_test.odin")})
				}
			}
		}
	}
	return found[:]
}

@(private = "file")
global_key :: proc(file, name: string) -> string { return strings.concatenate({file, " ", name}) }

// False when the code and the list disagree (or, with `write`, when the list cannot be written).
lint_globals :: proc(list := false, write := false, log := "") -> bool {
	found := find_globals(BROWSER_DIR)
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
			known[global_key(fields[0], fields[1])] = {fields[2], why}
		}
	}
	if write {
		b := strings.builder_make()
		for h in header { fmt.sbprintln(&b, h) }
		for g in found {
			c, has := known[global_key(g.file, g.name)]
			if !has { c = {g.test ? "test" : "window?", ""} }
			fmt.sbprintf(&b, "%s %s %s", g.file, g.name, c.class)
			if c.why != "" { fmt.sbprintf(&b, "  # %s", c.why) }
			fmt.sbprintln(&b)
		}
		if os.write_entire_file(GLOBALS_LIST, strings.to_string(b)) != nil { return false }
		fmt.printfln("%d globals written to %s", len(found), GLOBALS_LIST)
		return true
	}
	fail := 0
	seen := make(map[string]bool)
	classes := make(map[string]int)
	out := strings.builder_make()
	for g in found {
		k := global_key(g.file, g.name)
		seen[k] = true
		c, has := known[k]
		classes[has ? c.class : "NEW"] += 1
		if list { fmt.sbprintfln(&out, "%-34s %-34s %s", g.file, g.name, has ? c.class : "NEW") }
		if !has {
			fmt.sbprintfln(&out, "error: src\\browser\\%s: a new global '%s'. A window's state goes into Browser_Window (windows.odin), a tab's into Tab; a global of the process is added to tools\\globals_allowed.txt with its class and why", g.file, g.name)
			fail += 1
		}
	}
	for k in known {
		if k not_in seen {
			fmt.sbprintfln(&out, "error: tools\\globals_allowed.txt names '%s', which is no longer a global: take it out of the list", k)
			fail += 1
		}
	}
	names := make([dynamic]string, context.temp_allocator)
	for c in classes { append(&names, c) }
	slice.sort(names[:])
	fmt.sbprintf(&out, "globals of src\\browser: %d (", len(found))
	for c, i in names { fmt.sbprintf(&out, "%s%s %d", i > 0 ? ", " : "", c, classes[c]) }
	fmt.sbprintln(&out, ")")
	tooling.say(log, strings.to_string(out))
	return fail == 0
}

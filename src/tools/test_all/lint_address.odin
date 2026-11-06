package test_all

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

// The address field's text has one writer (src/browser/windows.odin address_sync): it follows the window's current tab unless the user edited it. Everything else changes the tab and
// lets the next build show it. A procedure that replaces a field's whole text and speaks of the address field fails, an alias of the field included: the writers that came
// before each had a rule of their own (a home tab's "about:home", what is being typed overwritten).

ADDRESS_LINT_DIRS :: [?]string{"src/browser", "src/tools/e2e"}
ADDRESS_WRITER :: "address_sync"
ADDRESS_WRITES :: [?]string{"ui.field_set(", "ui.field_clear("}
ADDRESS_NAMES :: [?]string{".address", "window_address("}

@(private = "file")
any_of :: proc(text: string, words: []string) -> bool {
	for w in words { if strings.contains(text, w) { return true } }
	return false
}

// The procedures of a file's top level that break the rule.
address_writers :: proc(path, src: string) -> []string {
	found := make([dynamic]string, context.temp_allocator)
	file := ast.File{src = src, fullpath = path}
	p := parser.default_parser({.Optional_Semicolons})
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	if !parser.parse_file(&p, &file) { append(&found, "(it does not parse)"); return found[:] }
	writes, names := ADDRESS_WRITES, ADDRESS_NAMES
	for decl in file.decls {
		v, is_value := decl.derived_stmt.(^ast.Value_Decl)
		if !is_value || len(v.names) != 1 || len(v.values) != 1 { continue }
		lit, is_proc := v.values[0].derived_expr.(^ast.Proc_Lit)
		if !is_proc { continue }
		name := src[v.names[0].pos.offset:v.names[0].end.offset]
		text := src[lit.pos.offset:lit.end.offset]
		if name != ADDRESS_WRITER && any_of(text, writes[:]) && any_of(text, names[:]) { append(&found, strings.clone(name, context.temp_allocator)) }
	}
	return found[:]
}

lint_address :: proc(log := "") -> bool {
	out := strings.builder_make()
	hits := 0
	for dir in ADDRESS_LINT_DIRS {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { fmt.sbprintfln(&out, "%s cannot be read", dir); hits += 1; continue }
		for e in entries {
			if e.type == .Directory || !strings.has_suffix(e.name, ".odin") { continue }
			data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			for name in address_writers(e.fullpath, string(data)) {
				fmt.sbprintfln(&out, "%s: %s writes the address field: only %s does (change the tab, the next build shows it)", e.fullpath, name, ADDRESS_WRITER)
				hits += 1
			}
		}
		free_all(context.temp_allocator)
	}
	if hits > 0 { tooling.say(log, strings.to_string(out)) }
	return hits == 0
}

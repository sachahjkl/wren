package test_all

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

// Preferences in src/browser/ are read one way: into typed subsystem Settings structs bound via config.bind
// inside *_settings_from_prefs readers. Direct config.*_of reads outside settings readers are allowed only
// for explicit UI/registry browsers and generic single-preference toggle helpers listed below.

PREFS_LINT_DIR :: "src/browser"

Prefs_Allow :: struct {
	file:   string,   // basename in src/browser/
	proc_:  string,   // top-level proc name, or "" for any proc in the file
	reason: string,
}

PREFS_READ_ALLOWED :: [?]Prefs_Allow{
	{file = "config_ui.odin",         proc_ = "",                reason = "about:config registry browser and editor"},
	{file = "palette.odin",           proc_ = "",                reason = "command palette preference display and toggle"},
	{file = "blocker_dashboard.odin", proc_ = "pref_row",        reason = "generic boolean preference toggle row widget"},
	{file = "commands.odin",          proc_ = "js_on_for",       reason = "per-site JavaScript override list lookup"},
	{file = "commands.odin",          proc_ = "js_toggle_site",  reason = "per-site JavaScript override list toggle"},
	{file = "devtools.odin",          proc_ = "set_pref_string", reason = "generic preference write-back comparison"},
	{file = "devtools.odin",          proc_ = "dev_toggle_pref", reason = "generic boolean preference toggle helper"},
}

@(private = "file")
PREFS_READ_CALLS :: [?]string{"bool_of", "int_of", "float_of", "string_of", "ref_of", "value_of"}

@(private = "file")
PREFS_FORBIDDEN_PROCS :: [?]string{"apply_prefs", "pref_groups_of"}

@(private = "file")
is_settings_reader :: proc(name: string) -> bool {
	return name == "settings_from_prefs" || strings.has_suffix(name, "_settings_from_prefs") || name == "font_settings_start"
}

@(private = "file")
is_pref_read_call :: proc(call: ^ast.Call_Expr, src: string) -> (string, bool) {
	sel, ok := call.expr.derived_expr.(^ast.Selector_Expr)
	if !ok { return "", false }
	id, id_ok := sel.expr.derived_expr.(^ast.Ident)
	if !id_ok || id.name != "config" || sel.field == nil { return "", false }
	field := sel.field.name
	for allowed in PREFS_READ_CALLS {
		if field == allowed { return field, true }
	}
	return "", false
}

@(private = "file")
Pref_Hit :: struct {
	proc_name: string,
	call:      string,
	line:      int,
}

@(private = "file")
Pref_Walk :: struct {
	src:       string,
	proc_name: string,
	hits:      ^[dynamic]Pref_Hit,
}

@(private = "file")
pref_walk_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil { return nil }
	w := (^Pref_Walk)(visitor.data)
	if call, ok := node.derived.(^ast.Call_Expr); ok {
		if name, is_read := is_pref_read_call(call, w.src); is_read {
			append(w.hits, Pref_Hit{proc_name = w.proc_name, call = name, line = call.pos.line})
		}
	}
	return visitor
}

@(private = "file")
prefs_file_scan :: proc(path, src: string) -> (hits: []Pref_Hit, forbidden: []string, parse_ok: bool) {
	file := ast.File{src = src, fullpath = path}
	p := parser.default_parser({.Optional_Semicolons})
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	if !parser.parse_file(&p, &file) { return nil, nil, false }
	found := make([dynamic]Pref_Hit, context.temp_allocator)
	bad_procs := make([dynamic]string, context.temp_allocator)
	for decl in file.decls {
		v, is_value := decl.derived_stmt.(^ast.Value_Decl)
		if !is_value || len(v.names) != 1 || len(v.values) != 1 { continue }
		lit, is_proc := v.values[0].derived_expr.(^ast.Proc_Lit)
		if !is_proc { continue }
		name := src[v.names[0].pos.offset:v.names[0].end.offset]
		for f in PREFS_FORBIDDEN_PROCS {
			if name == f { append(&bad_procs, strings.clone(name, context.temp_allocator)) }
		}
		if is_settings_reader(name) { continue }
		w := Pref_Walk{src = src, proc_name = name, hits = &found}
		vis := ast.Visitor{visit = pref_walk_visit, data = &w}
		ast.walk(&vis, lit.body)
	}
	return found[:], bad_procs[:], true
}

@(private = "file")
allow_index :: proc(file, proc_name: string) -> int {
	for a, i in PREFS_READ_ALLOWED {
		if a.file == file && (a.proc_ == "" || a.proc_ == proc_name) { return i }
	}
	return -1
}

lint_prefs :: proc(log := "") -> bool {
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	hits := 0
	used: [len(PREFS_READ_ALLOWED)]int

	entries, err := os.read_all_directory_by_path(PREFS_LINT_DIR, context.temp_allocator)
	if err != nil {
		fmt.sbprintfln(&out, "%s cannot be read", PREFS_LINT_DIR)
		tooling.say(log, strings.to_string(out))
		return false
	}
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") { continue }
		if strings.has_suffix(e.name, "_test.odin") || strings.contains(e.name, "_test_") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		found, forbidden, ok := prefs_file_scan(e.fullpath, string(data))
		if !ok {
			fmt.sbprintfln(&out, "%s: failed to parse", e.fullpath)
			hits += 1
			continue
		}
		for name in forbidden {
			fmt.sbprintfln(&out, "%s: obsolete dispatcher %s must not reappear (use per-prefix config.bind)", e.fullpath, name)
			hits += 1
		}
		for h in found {
			if idx := allow_index(e.name, h.proc_name); idx >= 0 {
				used[idx] += 1
				continue
			}
			fmt.sbprintfln(&out, "%s:%d: %s calls config.%s outside a *_settings_from_prefs reader (bind a typed Settings struct via config.bind)", e.fullpath, h.line, h.proc_name, h.call)
			hits += 1
		}
	}
	for a, i in PREFS_READ_ALLOWED {
		if used[i] == 0 {
			fmt.sbprintfln(&out, "lint_prefs: stale allowlist entry %s:%s (%s)", a.file, a.proc_, a.reason)
			hits += 1
		}
	}
	free_all(context.temp_allocator)
	if hits > 0 { tooling.say(log, strings.to_string(out)) }
	return hits == 0
}

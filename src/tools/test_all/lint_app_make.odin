package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// An App is made by its staged constructor (src/browser/app_make.odin: app_make, then the stages a program or a test needs) and
// a Tab by tab_new or tab_new_bare (src/browser/main.odin): an App or a Tab built field by field keeps the invariants of the day
// it was written, and the next one breaks it (App.tab_ids, the map of tab ids: two harnesses broke on it). A new(App) or
// new(browser.App) outside app_make.odin, or a new(Tab) or new(browser.Tab) outside main.odin, anywhere in src, fails.

APP_MAKE_ROOT :: #directory + "/../../.."
APP_MAKE_DIR :: "src"

@(private = "file")
App_Make_Rule :: struct {
	type:  string,   // the type allocated
	owner: string,   // the one file that allocates it (from the repository's root)
	use:   string,   // what to call instead
}

@(private = "file")
app_make_rules := [?]App_Make_Rule{
	{"App", "src/browser/app_make.odin", "browser.app_make and its stages"},
	{"Tab", "src/browser/main.odin", "tab_new, or tab_new_bare and tab_adopt"},
}

App_Make_Use :: struct { path: string, line: int, name: string }   // name: the type allocated

// The lines of the .odin files under root/dir that allocate an App or a Tab with new() outside their owner, outside comments and strings.
find_app_makes :: proc(root, dir: string, allocator := context.allocator) -> []App_Make_Use {
	found := make([dynamic]App_Make_Use, allocator)
	scan_app_makes(root, dir, &found, allocator)
	return found[:]
}

@(private = "file")
scan_app_makes :: proc(root, rel: string, found: ^[dynamic]App_Make_Use, allocator := context.allocator) {
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/%s", root, rel), context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		path := strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") { scan_app_makes(root, path, found, allocator) }
			continue
		}
		if !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		text := string(data)
		rules := app_make_rules
		n := 0
		for line in strings.split_lines_iterator(&text) {
			n += 1
			name := allocates_app_or_tab(line)
			if name == "" { continue }
			owned := false
			for r in rules { if r.type == name && r.owner == path { owned = true } }
			if !owned { append(found, App_Make_Use{strings.clone(path, allocator), n, name}) }
		}
	}
}

// The type ("App" or "Tab") that `line` allocates with new(T) or new(browser.T), in its code: not after a // of the code, nor
// in a string ("...", '...', `...` on one line). "": none.
allocates_app_or_tab :: proc(line: string) -> string {
	in_name :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' }
	rules := app_make_rules
	i := 0
	for i < len(line) {
		c := line[i]
		i += 1
		switch c {
		case '/':
			if i < len(line) && line[i] == '/' { return "" }
		case '"', '\'', '`':
			for i < len(line) && line[i] != c {
				i += line[i] == '\\' && c != '`' ? 2 : 1
			}
			i += 1
		case 'n':
			if i >= 2 && in_name(line[i - 2]) { continue }   // (renew(, x.new(: not the builtin)
			rest := line[i - 1:]
			if !strings.has_prefix(rest, "new(") { continue }
			arg := strings.trim_left_space(rest[len("new("):])
			arg = strings.trim_prefix(arg, "browser.")
			for r in rules {
				if !strings.has_prefix(arg, r.type) { continue }
				after := arg[len(r.type):]
				if len(after) == 0 || after[0] == ')' || after[0] == ',' || after[0] == ' ' { return r.type }
			}
		}
	}
	return ""
}

lint_app_make :: proc(log := "") -> bool {
	uses := find_app_makes(APP_MAKE_ROOT, APP_MAKE_DIR, context.temp_allocator)
	if len(uses) == 0 { return true }
	rules := app_make_rules
	out := strings.builder_make(context.temp_allocator)
	for u in uses {
		use := ""
		for r in rules { if r.type == u.name { use = r.use } }
		fmt.sbprintfln(&out, "%s:%d: new(%s): use %s (src/browser/app_make.odin): one built by hand misses the invariants of the browser's", u.path, u.line, u.name, use)
	}
	tooling.say(log, strings.to_string(out))
	return false
}

task_lint_app_make :: proc(t: ^Task_Run) -> bool {
	return lint_app_make(log = t.log)
}

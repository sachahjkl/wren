package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// The web platform's case is ASCII (base.ascii_lower, ascii_equal_fold...: tag and attribute names, CSS keywords, MIME types, header names, URL schemes,
// encoding labels). strings.to_lower, to_upper and equal_fold, and unicode.to_lower and to_upper, fold by Unicode: the Kelvin sign U+212A is 'k' to them, the
// long s U+017F 's'. A call of one of them in src (not src/tools: our own programs) or native fails unless tools/unicode_case_allowed.txt lists its line with
// why (user text: the address bar's search, a panel's filter; text-transform; Windows paths), and so does an entry that matches no line (the list follows
// the code). An entry is "<path> <code>  # why": the line of <path> (from the repository's root) that holds <code>. Read from the sources where this file is.

UNICODE_CASE_ROOT :: #directory + "/../../.."
UNICODE_CASE_LIST :: "tools/unicode_case_allowed.txt"
UNICODE_CASE_DIRS :: [?]string{"src", "native"}
UNICODE_CASE_SKIP :: [?]string{"src/tools"}
UNICODE_CASE_CALLS :: [?]string{"strings.to_lower(", "strings.to_upper(", "strings.equal_fold(", "unicode.to_lower(", "unicode.to_upper("}
UNICODE_CASE_WHY :: "  # "

Unicode_Case_Use :: struct { path: string, line: int, code: string }
Unicode_Case_Entry :: struct { path, code: string, used: bool }

// The lines of the .odin files under root/dirs (but those under root/skip) that call one of UNICODE_CASE_CALLS, outside comments and string literals.
find_unicode_case :: proc(root: string, dirs, skip: []string, allocator := context.allocator) -> []Unicode_Case_Use {
	found := make([dynamic]Unicode_Case_Use, allocator)
	for dir in dirs { scan_unicode_case(root, dir, skip, &found, allocator) }
	return found[:]
}

@(private = "file")
scan_unicode_case :: proc(root, rel: string, skip: []string, found: ^[dynamic]Unicode_Case_Use, allocator := context.allocator) {
	if slice.contains(skip, rel) { return }
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/%s", root, rel), context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		path := strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") { scan_unicode_case(root, path, skip, found, allocator) }
			continue
		}
		if !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		text := string(data)
		n := 0
		for line in strings.split_lines_iterator(&text) {
			n += 1
			if calls_unicode_case(line) {
				append(found, Unicode_Case_Use{strings.clone(path, allocator), n, strings.clone(strings.trim_space(line), allocator)})
			}
		}
	}
}

// One of UNICODE_CASE_CALLS in the code of `line`: not after a // of the code, nor in a string ("...", '...', `...` on one line).
calls_unicode_case :: proc(line: string) -> bool {
	in_name :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' }
	calls := UNICODE_CASE_CALLS
	i := 0
	for i < len(line) {
		c := line[i]
		i += 1
		switch c {
		case '/':
			if i < len(line) && line[i] == '/' { return false }
		case '"', '\'', '`':
			for i < len(line) && line[i] != c {
				i += line[i] == '\\' && c != '`' ? 2 : 1
			}
			i += 1
		case:
			if i >= 2 && in_name(line[i - 2]) { continue }
			for call in calls { if strings.has_prefix(line[i - 1:], call) { return true } }
		}
	}
	return false
}

// The entries of the list: "<path> <code>  # why", '#' lines comments.
parse_unicode_case_list :: proc(text: string, allocator := context.allocator) -> (entries: []Unicode_Case_Entry, bad: []string) {
	out := make([dynamic]Unicode_Case_Entry, allocator)
	wrong := make([dynamic]string, allocator)
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		sp := strings.index_byte(line, ' ')
		why := strings.last_index(line, UNICODE_CASE_WHY)
		if sp < 0 || why <= sp || strings.trim_space(line[why + len(UNICODE_CASE_WHY):]) == "" || !calls_unicode_case(line[sp:why]) {
			append(&wrong, line)
			continue
		}
		append(&out, Unicode_Case_Entry{path = line[:sp], code = strings.trim_space(line[sp:why])})
	}
	return out[:], wrong[:]
}

lint_unicode_case :: proc(log := "", root := UNICODE_CASE_ROOT) -> bool {
	dirs, skip := UNICODE_CASE_DIRS, UNICODE_CASE_SKIP
	list, _ := os.read_entire_file(fmt.tprintf("%s/%s", root, UNICODE_CASE_LIST), context.allocator)
	entries, bad := parse_unicode_case_list(string(list))
	out := strings.builder_make()
	for b in bad { fmt.sbprintfln(&out, "error: %s: '%s' is no \"<path> <code>  # why\" whose code calls a Unicode case procedure", UNICODE_CASE_LIST, b) }
	uses := find_unicode_case(root, dirs[:], skip[:])
	unlisted, stale := 0, 0
	for u in uses {
		allowed := false
		for &e in entries {
			if e.path == u.path && strings.contains(u.code, e.code) { e.used, allowed = true, true }
		}
		if allowed { continue }
		unlisted += 1
		fmt.sbprintfln(&out, "error: %s(%d): '%s' folds by Unicode, where the web platform asks for ASCII (base.ascii_lower, ascii_equal_fold...); if it is user text, list it in %s with why", u.path, u.line, u.code, UNICODE_CASE_LIST)
	}
	for e in entries {
		if e.used { continue }
		stale += 1
		fmt.sbprintfln(&out, "error: %s: '%s %s' matches no line of the code: drop it", UNICODE_CASE_LIST, e.path, e.code)
	}
	fmt.sbprintfln(&out, "Unicode case calls: %d (%d not in the list); entries of the list that match nothing: %d", len(uses), unlisted, stale)
	tooling.say(log, strings.to_string(out))
	return unlisted == 0 && stale == 0 && len(bad) == 0
}

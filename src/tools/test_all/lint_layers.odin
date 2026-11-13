package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// Two layering rules of the product (docs/architecture.md, Layers; docs/portability.md, Rules), outside src/tools:
//   * no import of wb:tools/*: a tool may use the product, never the reverse (what both need lives in src:
//     stacks, testenv);
//   * core:sys/windows only in a file named *_windows.odin: a neutral file that imports it compiles on Linux only as
//     long as nobody calls what it declares, and the next caller breaks the Linux build.
// The files of src/tools are programs of their own; they keep their #+build lines.

LAYERS_ROOT :: #directory + "/../../.."
LAYERS_DIRS := [?]string{"src", "native/js"}   // (native/js: the Odin of the engine's glue; the rest of native is Rust and its build)
LAYERS_SKIP :: "src/tools"

Layer_Breach :: struct { path: string, line: int, import_path: string }

// The imports of the .odin files under root/dirs that break a rule (paths from the repository's root).
find_layer_breaches :: proc(root: string, dirs: []string, allocator := context.allocator) -> []Layer_Breach {
	found := make([dynamic]Layer_Breach, allocator)
	for d in dirs { scan_layers(root, d, &found, allocator) }
	return found[:]
}

@(private = "file")
scan_layers :: proc(root, rel: string, found: ^[dynamic]Layer_Breach, allocator := context.allocator) {
	if rel == LAYERS_SKIP { return }
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/%s", root, rel), context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		path := strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") { scan_layers(root, path, found, allocator) }
			continue
		}
		if !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		windows_file := strings.has_suffix(e.name, "_windows.odin")
		text := string(data)
		n := 0
		for line in strings.split_lines_iterator(&text) {
			n += 1
			imported := import_path_of(line)
			if imported == "" { continue }
			tool := strings.has_prefix(imported, "wb:tools/")
			win32 := !windows_file && (imported == "core:sys/windows" || strings.has_prefix(imported, "core:sys/windows/"))
			if tool || win32 { append(found, Layer_Breach{strings.clone(path, allocator), n, strings.clone(imported, allocator)}) }
		}
	}
}

// The path `line` imports ("": it is no import). Takes `import "p"`, `import name "p"`, `import _ "p"` and an attribute before
// them (`@(require) import "p"`).
import_path_of :: proc(line: string) -> string {
	s := strings.trim_space(line)
	if strings.has_prefix(s, "@(") {
		close := strings.index_byte(s, ')')
		if close < 0 { return "" }
		s = strings.trim_left_space(s[close + 1:])
	}
	if !strings.has_prefix(s, "import ") { return "" }
	open := strings.index_byte(s, '"')
	if open < 0 { return "" }
	rest := s[open + 1:]
	close := strings.index_byte(rest, '"')
	if close < 0 { return "" }
	return rest[:close]
}

lint_layers :: proc(log := "") -> bool {
	dirs := LAYERS_DIRS
	breaches := find_layer_breaches(LAYERS_ROOT, dirs[:], context.temp_allocator)
	if len(breaches) == 0 { return true }
	out := strings.builder_make(context.temp_allocator)
	for b in breaches {
		if strings.has_prefix(b.import_path, "wb:tools/") {
			fmt.sbprintfln(&out, "%s:%d: imports %s: the product does not import a tool (move what both need into src)", b.path, b.line, b.import_path)
		} else {
			fmt.sbprintfln(&out, "%s:%d: imports %s in a file that is not *_windows.odin (move the use there, with an *_other.odin counterpart)", b.path, b.line, b.import_path)
		}
	}
	tooling.say(log, strings.to_string(out))
	return false
}

task_lint_layers :: proc(t: ^Task_Run) -> bool {
	return lint_layers(log = t.log)
}

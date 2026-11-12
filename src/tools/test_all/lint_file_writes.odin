package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// The profile's files have one writer (src/host/profile_file.odin: host.Profile_File, profile_write, file_put): it writes off
// the interface thread, atomically, and tries again after a failure. A direct write elsewhere in the product (a write of a
// whole file, an open for writing, a rename, a removal) is how a file got cut short by a crash, or a slow disk held the
// interface (docs/organisation-review.md, 3). The ones left are the ones of tools/file_writes_allowed.txt, each with why it
// stays: a new one fails here, and so does a line that says more than the file has, so that the list shrinks with the code.

FILE_WRITES_ALLOWED :: "tools/file_writes_allowed.txt"
FILE_WRITER_SOURCE :: "src/host/profile_file.odin"
// Not the product: the tools, the test harnesses, the generators (and every *_test.odin and *_test_<system>.odin).
FILE_WRITE_SKIPPED :: [?]string{"src/tools/", "src/e2e/", "src/testenv/", "/judge/", "/gen/"}
FILE_WRITE_CALLS :: [?]string{
	"os.write_entire_file(", "os.rename(", "os.remove(", "os.remove_all(",
	"base.file_write_atomic(", "base.file_write_parts(", "base.file_replace(", "base.file_delete(", "base.remove_tree(",
	"fsx.write_atomic(", "fsx.write_parts(", "fsx.replace(", "fsx.delete_file(", "fsx.remove_tree(",
}
// An os.open is a write when its line asks for one of these.
FILE_WRITE_OPEN_FLAGS :: [?]string{".Write", ".Create", ".Append", ".Trunc", "O_WRONLY", "O_RDWR", "O_CREATE", "O_APPEND", "O_TRUNC"}

@(private = "file")
is_product_source :: proc(path: string) -> bool {
	if !strings.has_suffix(path, ".odin") || path == FILE_WRITER_SOURCE { return false }
	for s in FILE_WRITE_SKIPPED { if strings.contains(path, s) { return false } }
	name := path[strings.last_index_byte(path, '/') + 1:]
	return !strings.contains(name, "_test.") && !strings.contains(name, "_test_")
}

// The code of a line: what is in a string ("...", '...', `...` on the line) and what follows a // of the code left out.
code_of_line :: proc(line: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(line) {
		c := line[i]
		i += 1
		switch c {
		case '/':
			if i < len(line) && line[i] == '/' { return strings.to_string(b) }
			strings.write_byte(&b, c)
		case '"', '\'', '`':
			for i < len(line) && line[i] != c {
				if line[i] == '\\' && c != '`' { i += 1 }
				i += 1
			}
			i += 1
			strings.write_byte(&b, c)
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// How many direct file writes a source has.
count_file_writes :: proc(text: string) -> int {
	n := 0
	rest := text
	calls, flags := FILE_WRITE_CALLS, FILE_WRITE_OPEN_FLAGS
	for line in strings.split_lines_iterator(&rest) {
		code := code_of_line(line)
		for call in calls { n += strings.count(code, call) }
		if opens := strings.count(code, "os.open("); opens > 0 {
			for f in flags { if strings.contains(code, f) { n += opens; break } }
		}
	}
	return n
}

@(private = "file")
scan_file_writes :: proc(dir: string, found: ^map[string]int) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		path := strings.concatenate({dir, "/", e.name})
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") { scan_file_writes(path, found) }
			continue
		}
		if !is_product_source(path) { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		if n := count_file_writes(string(data)); n > 0 { found[path] = n }
	}
}

lint_file_writes :: proc(log := "") -> bool {
	out := strings.builder_make()
	errors := 0
	data, err := os.read_entire_file(FILE_WRITES_ALLOWED, context.allocator)
	if err != nil { tooling.say(log, fmt.tprintfln("error: %s cannot be read", FILE_WRITES_ALLOWED)); return false }
	allowed, bad := parse_test_sleeps_allowed(string(data))   // (the same "<path> <count>  # why" lines)
	for l in bad { fmt.sbprintfln(&out, "error: %s: not `<path> <count>  # why`: %s", FILE_WRITES_ALLOWED, l); errors += 1 }
	found: map[string]int
	scan_file_writes("src", &found)
	names := make([dynamic]string)
	for path in found { append(&names, path) }
	for path in allowed { if path not_in found { append(&names, path) } }
	slice.sort(names[:])
	total := 0
	for path in names {
		n, listed := found[path] or_else 0, allowed[path] or_else 0
		total += n
		if n > listed { fmt.sbprintfln(&out, "error: %s: %d direct file write(s), %d allowed: write through the profile's writer (%s), or say in %s why not", path, n, listed, FILE_WRITER_SOURCE, FILE_WRITES_ALLOWED); errors += 1 }
		if n < listed { fmt.sbprintfln(&out, "error: %s: %d direct file write(s), %s says %d: lower it", path, n, FILE_WRITES_ALLOWED, listed); errors += 1 }
	}
	fmt.sbprintfln(&out, "direct file writes in the product: %d in %d files, %d error(s)", total, len(found), errors)
	tooling.say(log, strings.to_string(out))
	return errors == 0
}

task_lint_file_writes :: proc(t: ^Task_Run) -> bool {
	return lint_file_writes(log = t.log)
}

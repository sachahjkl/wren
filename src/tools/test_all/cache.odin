package test_all

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:tools/tooling"

// What a step depends on, a key made of the contents of those files, and the results of the steps that passed, by key (build/test_cache/<key>.txt, as Bazel's action cache does). A step
// whose key has a result does not run again: the same inputs have passed. Nothing here looks at a time stamp to decide: a stamp only says whether a file need be read again within a run.
//
// The key: Odin's version, the run's flags, the step's name and commands, and the path and hash of every input, which `Step.inputs` says:
//   - .Packages: the files of the packages it compiles and runs, of every package they import (wb:, toolkit:, web:, relative: parsed from the sources; every build tag), what they #load, the
//     libraries they link, the paths written in their strings ("examples/site/...": what a test reads while it runs), and examples/ and assets/;
//   - .Tree: the whole tree a build and a script can read, tests of packages aside; .Sources: that with the tests; .Everything: docs/, site/, changelog.d/ and licence/ too; .Dirs: only its folders.
// What cannot be resolved (an unknown collection, an import that names no folder) falls back on the whole tree: an input too many reruns a step, one too few could hide a failure.
// Only a pass is kept, and a key is computed again when the step has ended: a source edited during the step leaves no result. A result lasts CACHE_MAX_AGE_DAYS days (a certificate, a date
// in a test: what no file says). cache_test.odin tests this file.

CACHE_MAX_AGE_DAYS :: 7
SECONDS_PER_DAY :: 86400
CACHE_FORMAT :: "wren-test-cache 2"
CACHE_DIR :: "build/test_cache"
// The file every step's result depends on: what the steps inherit.
ENV_SOURCE :: "src/tools/test_all/env.odin"

TREE_DIRS := []string{"src", "ext/gui_toolkit", "tools", "wpt", "native", "api", "sdk", "examples", "assets"}
TREE_FILES := []string{"build.bat", "build.sh", "odin.version", "build/js/wren_js.wasm", "build/lexbor/lexbor.lib", "build/native/wren_native.lib", "build/native/STAMP"}
ALL_DIRS := []string{"docs", "site", "changelog.d", "licence"}
ALL_FILES := []string{"CHANGELOG.md", "README.md", "CONTRIBUTING.md", "THIRD_PARTY.md", "LICENSE"}
DATA_PATH_ROOTS := []string{"ext", "examples", "assets", "tools", "wpt", "docs", "site", "licence", "native", "api", "sdk", "src"}
// What ends a path written in a string: a format verb, a pattern.
DATA_PATH_STOP :: "%*:|<>? \t"
LIBRARY_SUFFIXES := []string{".lib", ".a", ".obj", ".res", ".o"}
LOAD_DIRECTIVES := []string{"#load(", "#load_directory(", "#load_hash("}

File_Stamp :: struct { modified: time.Time, size: i64 }
Hash_Memo :: struct { stamp: File_Stamp, hash: string }

// What one package says it uses, kept until its files change.
Package_Node :: struct {
	files, imports: [dynamic]string,
	unresolved:     bool,
}

Cached_Result :: struct { seconds, checks: int, when_: string }

Cache :: struct {
	root, dir, prefix: string,
	names:   map[string]string,       // every path of a run, once
	stamps, other_stamps: map[string]File_Stamp,   // the tree as last looked at, and the map of the next look
	outside: map[string]bool,         // the files a package reaches outside the walk: inputs of what imports it, of no other step: a key must not depend on the packages read before it
	memo:    map[string]Hash_Memo,    // what its files hashed to, while they stay as they were
	nodes:   map[string]^Package_Node,// the packages read since the tree last changed
}

full_path :: proc(c: ^Cache, rel: string) -> string {
	return c.root == "." ? rel : strings.concatenate({c.root, "/", rel}, context.temp_allocator)
}

// Starts the cache of this run: `flags` say what changes a result besides the files. The old results go, they will not be read again.
cache_init :: proc(c: ^Cache, root, flags: string) {
	c.root = strings.clone(root)
	c.dir = strings.clone(full_path(c, CACHE_DIR))
	_ = os.make_directory_all(c.dir)
	version, _ := tooling.capture({tooling.odin_program(), "version"})
	c.prefix = fmt.aprintf("%s\n%s\n%s", CACHE_FORMAT, strings.trim_space(version), flags)
	entries, err := os.read_all_directory_by_path(c.dir, context.temp_allocator)
	if err == nil {
		limit := time.time_add(time.now(), -time.Duration(CACHE_MAX_AGE_DAYS * SECONDS_PER_DAY) * time.Second)
		for e in entries { if time.diff(e.modification_time, limit) > 0 { _ = os.remove(e.fullpath) } }
	}
	cache_look_again(c)
}

@(private = "file")
is_output :: proc(rel: string) -> bool {
	// (what a build writes among the sources: a guest's .wasm, in examples/site for the pages of the test server)
	return strings.has_suffix(rel, ".wasm") && strings.has_prefix(rel, "examples/")
}

@(private = "file")
intern :: proc(c: ^Cache, s: string) -> string {
	if owned, ok := c.names[s]; ok { return owned }
	owned := strings.clone(s)
	c.names[owned] = owned
	return owned
}

@(private = "file")
walk :: proc(c: ^Cache, rel: string, into: ^map[string]File_Stamp) {
	entries, err := os.read_all_directory_by_path(full_path(c, rel), context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.name == ".git" { continue }
		child := strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			walk(c, child, into)
			continue
		}
		if !is_output(child) { into[intern(c, child)] = {e.modification_time, e.size} }
	}
}

// Looks at the tree again: names, stamps; contents only when a stamp has changed. What a key needs: one walk, not a look at each file for each step. What the packages say stands while nothing of the tree has changed.
cache_look_again :: proc(c: ^Cache) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	fresh := &c.other_stamps
	clear(fresh)
	for d in TREE_DIRS { walk(c, d, fresh) }
	for d in ALL_DIRS { walk(c, d, fresh) }
	singles := [2][]string{TREE_FILES, ALL_FILES}
	for list in singles {
		for f in list {
			if fi, err := os.stat(full_path(c, f), context.temp_allocator); err == nil { fresh[intern(c, f)] = {fi.modification_time, fi.size} }
		}
	}
	for f in c.outside {
		if fi, err := os.stat(full_path(c, f), context.temp_allocator); err == nil { fresh[f] = {fi.modification_time, fi.size} }
	}
	same := len(fresh) == len(c.stamps)
	if same {
		for k, v in fresh {
			if old, ok := c.stamps[k]; !ok || old != v { same = false; break }
		}
	}
	c.stamps, c.other_stamps = c.other_stamps, c.stamps
	if same { return }
	for _, n in c.nodes { delete(n.files); delete(n.imports); free(n) }
	clear(&c.nodes)
}

@(private = "file")
in_dirs :: proc(rel: string, dirs: []string) -> bool {
	for d in dirs {
		if len(rel) > len(d) && rel[len(d)] == '/' && strings.has_prefix(rel, d) { return true }
	}
	return false
}

is_test_source :: proc(rel: string) -> bool {
	return strings.has_suffix(rel, "_test.odin") || strings.contains(rel, "/tests/")
}

// Every file a build or a script can read; `everything`: the documentation and the changelog too; `tests`: *_test.odin as well.
tree_files :: proc(c: ^Cache, everything, tests: bool, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(c.stamps), allocator)
	for rel in c.stamps {
		if rel in c.outside { continue }
		wanted := in_dirs(rel, TREE_DIRS) || slice.contains(TREE_FILES, rel)
		if everything { wanted = wanted || in_dirs(rel, ALL_DIRS) || slice.contains(ALL_FILES, rel) }
		if wanted && (tests || !is_test_source(rel)) { append(&out, rel) }
	}
	return out[:]
}

// What the test server and the tests read while they run, and how a step is run.
data_files :: proc(c: ^Cache, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for rel in c.stamps {
		if rel in c.outside { continue }
		if strings.has_prefix(rel, "examples/") || strings.has_prefix(rel, "assets/") || strings.has_prefix(rel, "tools/testserver/") || strings.has_prefix(rel, "sdk/") || strings.has_prefix(rel, "api/") ||
		   strings.has_prefix(rel, "build/native/") || strings.has_prefix(rel, "build/lexbor/") || rel == ENV_SOURCE || rel == "odin.version" {
			append(&out, rel)
		}
	}
	return out[:]
}

// What a source says it uses, without compiling it. (A line that is commented out counts: an input too many.)
Source_Facts :: struct { imports, loads, data: [dynamic]string }

scan_source :: proc(text: string) -> (f: Source_Facts) {
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_left_space(raw)
		if line == "" { continue }
		// @(...) import name "path"
		probe := line
		if strings.has_prefix(probe, "@(") {
			if close := strings.index_byte(probe, ')'); close >= 0 { probe = strings.trim_left_space(probe[close + 1:]) }
		}
		is_import := strings.has_prefix(probe, "import ")
		quote := strings.index_byte(line, '"')
		for quote >= 0 {
			end := strings.index_byte(line[quote + 1:], '"')
			if end < 0 { break }
			value := line[quote + 1:quote + 1 + end]
			before := strings.trim_right_space(line[:quote])
			if is_import {
				append(&f.imports, value)
				break
			}
			loaded := false
			for d in LOAD_DIRECTIVES { if strings.has_suffix(before, d) { loaded = true } }
			if loaded {
				append(&f.loads, value)
			} else {
				library := !strings.contains_any(value, " \t") && !strings.contains_rune(value, ':')
				if library {
					suffix := false
					for s in LIBRARY_SUFFIXES { if strings.has_suffix(value, s) { suffix = true } }
					library = suffix
				}
				if library { append(&f.loads, value) }
				// what a test reads while it runs, up to the first format verb
				for r in DATA_PATH_ROOTS {
					if len(value) > len(r) && strings.has_prefix(value, r) && (value[len(r)] == '/' || value[len(r)] == '\\') {
						stop := strings.index_any(value, DATA_PATH_STOP)
						append(&f.data, stop >= 0 ? value[:stop] : value)
						break
					}
				}
			}
			line = line[quote + 1 + end + 1:]
			quote = strings.index_byte(line, '"')
		}
	}
	return
}

// A path made canonical: forward slashes, no . or .. ; "" when it goes above the root.
canon :: proc(path: string, allocator := context.temp_allocator) -> string {
	p, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	parts := make([dynamic]string, context.temp_allocator)
	for part in strings.split(p, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(parts) == 0 { return "" }
			pop(&parts)
		case: append(&parts, part)
		}
	}
	return strings.join(parts[:], "/", allocator)
}

// A package's folder from an import: "" and known for what comes with the compiler, not known when it cannot be resolved.
resolve_import :: proc(c: ^Cache, dir, path: string) -> (pkg: string, known: bool) {
	resolved: string
	if colon := strings.index_byte(path, ':'); colon >= 0 {
		rest := path[colon + 1:]
		switch path[:colon] {
		case "core", "base", "vendor": return "", true
		case "wb": resolved = strings.concatenate({"src/", rest}, context.temp_allocator)
		case "toolkit": resolved = strings.concatenate({"ext/gui_toolkit/src/", rest}, context.temp_allocator)
		case "wren": resolved = strings.concatenate({"sdk/odin/", rest}, context.temp_allocator)
		case: return "", false
		}
	} else {
		resolved = strings.concatenate({dir, "/", path}, context.temp_allocator)
	}
	resolved = canon(resolved)
	return resolved, resolved != "" && os.is_dir(full_path(c, resolved))
}

@(private = "file")
add_path_or_dir :: proc(c: ^Cache, n: ^Package_Node, target: string) {
	if target == "" || is_output(target) { return }
	if target in c.stamps { append(&n.files, intern(c, target)); return }
	// (a file outside what the walk sees, such as a #load of the build folder)
	full := full_path(c, target)
	if os.is_file(full) {
		if fi, err := os.stat(full, context.temp_allocator); err == nil {
			owned := intern(c, target)
			c.stamps[owned] = {fi.modification_time, fi.size}
			c.outside[owned] = true
			append(&n.files, owned)
		}
		return
	}
	if os.is_dir(full) {
		prefix := strings.concatenate({target, "/"}, context.temp_allocator)
		for rel in c.stamps { if strings.has_prefix(rel, prefix) { append(&n.files, rel) } }
	}
}

@(private = "file")
node_of :: proc(c: ^Cache, dir: string) -> ^Package_Node {
	if n, ok := c.nodes[dir]; ok { return n }
	n := new(Package_Node)
	c.nodes[intern(c, dir)] = n
	entries, err := os.read_all_directory_by_path(full_path(c, dir), context.temp_allocator)
	if err != nil { return n }
	for e in entries {
		rel := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			// a folder of data beside a package's sources (not a package: no .odin file in it)
			if !has_odin_files(c, rel) { add_path_or_dir(c, n, rel) }
			continue
		}
		if is_output(rel) { continue }
		add_path_or_dir(c, n, rel)
		if !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		facts := scan_source(string(data))
		for imp in facts.imports {
			pkg, known := resolve_import(c, dir, imp)
			if !known { n.unresolved = true; continue }
			if pkg != "" { append(&n.imports, intern(c, pkg)) }
		}
		for load in facts.loads { add_path_or_dir(c, n, canon(strings.concatenate({dir, "/", load}, context.temp_allocator))) }
		for path in facts.data { add_path_or_dir(c, n, canon(path)) }
	}
	return n
}

@(private = "file")
has_odin_files :: proc(c: ^Cache, dir: string) -> bool {
	entries, err := os.read_all_directory_by_path(full_path(c, dir), context.temp_allocator)
	if err != nil { return false }
	for e in entries {
		if e.type == .Directory { if has_odin_files(c, strings.concatenate({dir, "/", e.name}, context.temp_allocator)) { return true } }
		if strings.has_suffix(e.name, ".odin") { return true }
	}
	return false
}

// The files of `packages` and of everything they import; not ok when something cannot be resolved: the caller takes the whole tree.
closure :: proc(c: ^Cache, packages: []string, allocator := context.temp_allocator) -> (files: []string, ok: bool) {
	seen := make(map[string]bool, 64, context.temp_allocator)
	set := make(map[string]bool, 1024, context.temp_allocator)
	todo := make([dynamic]string, context.temp_allocator)
	for p in packages {
		pkg := canon(p)
		if !os.is_dir(full_path(c, pkg)) { return nil, false }
		if pkg not_in seen { seen[pkg] = true; append(&todo, pkg) }
	}
	for len(todo) > 0 {
		n := node_of(c, pop(&todo))
		if n.unresolved { return nil, false }
		for f in n.files { set[f] = true }
		for pkg in n.imports { if pkg not_in seen { seen[pkg] = true; append(&todo, pkg) } }
	}
	out := make([]string, len(set), allocator)
	i := 0
	for f in set { out[i] = f; i += 1 }
	return out, true
}

// The packages of a closure, for the comparison with the compiler's import graph (cache_test.odin).
closure_packages :: proc(c: ^Cache, packages: []string, allocator := context.temp_allocator) -> (out: []string, ok: bool) {
	files, good := closure(c, packages)
	if !good { return nil, false }
	set := make(map[string]bool, 64, context.temp_allocator)
	for f in files { if strings.has_suffix(f, ".odin") { set[f[:strings.last_index_byte(f, '/')]] = true } }
	list := make([]string, len(set), allocator)
	i := 0
	for p in set { list[i] = p; i += 1 }
	return list, true
}

// `sources` read one by one: `own`, themselves and what they load and read; the packages they import go into `pkgs`. false: an import that names no folder, or a file that cannot be read: the caller takes the whole tree.
@(private = "file")
source_inputs :: proc(c: ^Cache, sources: []string, pkgs: ^[dynamic]string) -> (own: []string, ok: bool) {
	n := Package_Node{files = make([dynamic]string, context.temp_allocator)}
	for rel in sources {
		data, err := os.read_entire_file(full_path(c, rel), context.temp_allocator)
		if err != nil { return }
		dir := rel[:strings.last_index_byte(rel, '/')]
		facts := scan_source(string(data))
		add_path_or_dir(c, &n, rel)
		for imp in facts.imports {
			pkg, known := resolve_import(c, dir, imp)
			if !known { return }
			if pkg != "" { append(pkgs, pkg) }
		}
		for load in facts.loads { add_path_or_dir(c, &n, canon(strings.concatenate({dir, "/", load}, context.temp_allocator))) }
		for path in facts.data { add_path_or_dir(c, &n, canon(path)) }
	}
	return n.files[:], true
}

// The files a step depends on (repository-relative, sorted).
step_inputs :: proc(c: ^Cache, s: ^Step, allocator := context.temp_allocator) -> []string {
	files: []string
	switch s.inputs {
	case .Everything: files = tree_files(c, true, true, allocator)
	case .Tree: files = tree_files(c, false, false, allocator)
	case .Sources: files = tree_files(c, false, true, allocator)
	case .Dirs:
		list := make([dynamic]string, allocator)
		for rel in c.stamps { if rel not_in c.outside && in_dirs(rel, s.packages) { append(&list, rel) } }
		files = list[:]
	case .Packages:
		pkgs := make([dynamic]string, context.temp_allocator)
		append(&pkgs, ..s.packages)
		for a in s.actions { if cmd, is_command := a.(Command); is_command && cmd.pkg != "" { append(&pkgs, cmd.pkg) } }
		own, read := source_inputs(c, s.sources, &pkgs)
		code, resolved := closure(c, pkgs[:], allocator)
		if len(pkgs) == 0 || !resolved || !read {
			files = tree_files(c, false, false, allocator)
		} else {
			both := make([dynamic]string, 0, len(code) + len(own) + len(c.stamps) / 2, allocator)
			append(&both, ..code)
			append(&both, ..own)
			append(&both, ..data_files(c))
			slice.sort(both[:])
			files = slice.unique(both[:])
			return files
		}
	}
	slice.sort(files)
	return files
}

hash_file :: proc(c: ^Cache, rel: string) -> string {
	stamp, known := c.stamps[rel]
	if !known { return "missing" }
	if m, ok := c.memo[rel]; ok && m.stamp == stamp { return m.hash }
	data, err := os.read_entire_file(full_path(c, rel), context.temp_allocator)
	if err != nil { return "unreadable" }
	h := xxhash.XXH3_128(data)
	text := fmt.aprintf("%032x", h)
	if m, ok := c.memo[rel]; ok { delete(m.hash) }
	c.memo[intern(c, rel)] = {stamp, text}
	return text
}

// What a step does, as it goes into its key.
step_text :: proc(s: ^Step, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for a in s.actions {
		switch v in a {
		case Command:
			fmt.sbprintfln(&b, "%v | %v | %s | %s | %s | %v", v.argv, v.env, v.dir, v.tests_of, v.also, v.only)
		case Task:
			fmt.sbprintfln(&b, "task %s %s", v.name, v.arg)
		}
	}
	return strings.to_string(b)
}

step_key :: proc(c: ^Cache, s: ^Step) -> string {
	files := step_inputs(c, s)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n%s\n%s", c.prefix, s.name, step_text(s))
	for f in files { fmt.sbprintf(&b, "\n%s %s", f, hash_file(c, f)) }
	return fmt.aprintf("%032x", xxhash.XXH3_128(b.buf[:]))
}

// What a step wrote that a later step uses: a result stands only while they are what the step left (going back to sources of two changes ago finds the result, but the program on the disk is another's).
step_outputs :: proc(s: ^Step, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	append(&out, ..s.outs)
	for a in s.actions { if cmd, ok := a.(Command); ok && cmd.out != "" { append(&out, cmd.out) } }
	return out[:]
}

file_id :: proc(c: ^Cache, rel: string, allocator := context.temp_allocator) -> string {
	fi, err := os.stat(full_path(c, rel), context.temp_allocator)
	if err != nil { return fmt.aprintf("%s|missing", rel, allocator = allocator) }
	return fmt.aprintf("%s|%d|%d", rel, fi.size, time.to_unix_nanoseconds(fi.modification_time), allocator = allocator)
}

// A step's result for this key.
result_of :: proc(c: ^Cache, key: string, s: ^Step) -> (r: Cached_Result, found: bool) {
	path := fmt.tprintf("%s/%s.txt", c.dir, key)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	FACTS :: 4
	if len(lines) < FACTS || lines[0] != "PASS" { return }
	for l in lines[FACTS:] {
		if l == "" { continue }
		bar := strings.index_byte(l, '|')
		if bar < 0 || file_id(c, l[:bar]) != l { return {}, false }
	}
	r.seconds, _ = strconv.parse_int(lines[1])
	r.checks, _ = strconv.parse_int(lines[2])
	r.when_ = strings.clone(lines[3])
	return r, true
}

result_save :: proc(c: ^Cache, key: string, s: ^Step, seconds, checks: int) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "PASS\n%d\n%d\n%s\n", seconds, checks, now_stamp())
	for o in step_outputs(s) { fmt.sbprintln(&b, file_id(c, o)) }
	path := fmt.tprintf("%s/%s.txt", c.dir, key)
	temp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(temp, strings.to_string(b)) == nil { _ = os.rename(temp, path) }
}

// The tests a source file declares: the procedures it marks @(test), as the compiler's own parser reads them. (The test programs have no list of their tests by file; this reads what they were built from.)
declared_tests :: proc(path: string) -> (names: [dynamic]string, why: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return names, fmt.aprintf("cannot read %s", path) }
	full, _ := filepath.abs(path, context.temp_allocator)
	file := ast.File{src = string(data), fullpath = full}
	p := parser.default_parser({.Optional_Semicolons})
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	if !parser.parse_file(&p, &file) { return names, fmt.aprintf("%s does not parse", path) }
	for decl in file.decls {
		v, is_value := decl.derived_stmt.(^ast.Value_Decl)
		if !is_value || len(v.names) == 0 { continue }
		marked := false
		for attr in v.attributes {
			for elem in attr.elems {
				if id, is_ident := elem.derived_expr.(^ast.Ident); is_ident && id.name == "test" { marked = true }
			}
		}
		if !marked { continue }
		if id, is_ident := v.names[0].derived_expr.(^ast.Ident); is_ident { append(&names, id.name) }
	}
	if len(names) == 0 { return names, fmt.aprintf("no @(test) in %s", path) }
	return names, ""
}

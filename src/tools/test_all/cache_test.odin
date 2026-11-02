package test_all

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:tools/tooling"

// Of cache.odin: the inputs of a step (against the compiler's own import graph), and that a change of an input, and of nothing else, changes a key.

SPIN_FOR_NEW_STAMP :: 15 * time.Millisecond

@(private = "file")
Fixture :: struct {
	root: string,
	c:    Cache,
	step: Step,
}

@(private = "file")
put :: proc(f: ^Fixture, rel, text: string) {
	path := fmt.tprintf("%s/%s", f.root, rel)
	_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, text)
}

@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> ^Fixture {
	f := new(Fixture, context.allocator)
	f.root = fmt.aprintf("%s/cache_test_%s_%d", TEMP_DIR, name, os.get_pid())
	_ = os.remove_all(f.root)
	put(f, "src/app/main.odin", "package app\nimport \"core:fmt\"\nimport \"wb:lib\"\nD :: #load(\"data.txt\")\nmain :: proc() { fmt.println(lib.x, \"tools/fixture.ps1\") }\n")
	put(f, "src/app/data.txt", "one")
	put(f, "src/app/app_test.odin", "package app\n")
	put(f, "src/lib/lib.odin", "package lib\nx := 1\n")
	put(f, "src/other/other.odin", "package other\n")
	put(f, "tools/fixture.ps1", "# fixture")
	put(f, "tools/unrelated.ps1", "# unrelated")
	put(f, "docs/page.md", "doc")
	put(f, "examples/site/page.html", "page")
	put(f, "examples/site/guest.wasm", "output of a build")
	put(f, "odin.version", "x")
	cache_init(&f.c, f.root, "flags")
	f.step = Step{name = "app", actions = slice_of(Command{argv = strs("odin", "test", "src/app"), pkg = "src/app"})}
	return f
}

@(private = "file")
drop :: proc(f: ^Fixture) { _ = os.remove_all(f.root) }

// A change of `rel` to `text`: does the key move? (The stamp is compared: the clock must have moved.)
@(private = "file")
changes_key :: proc(f: ^Fixture, before, rel, text: string) -> bool {
	full := fmt.tprintf("%s/%s", f.root, rel)
	old, _ := os.read_entire_file(full, context.temp_allocator)
	time.sleep(SPIN_FOR_NEW_STAMP)
	put(f, rel, text)
	cache_look_again(&f.c)
	moved := step_key(&f.c, &f.step) != before
	time.sleep(SPIN_FOR_NEW_STAMP)
	_ = os.write_entire_file(full, old)
	cache_look_again(&f.c)
	return moved
}

@(test)
inputs_of_a_package :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	f := fixture(t, "inputs")
	defer drop(f)
	inputs := step_inputs(&f.c, &f.step)
	for rel in ([]string{"src/app/main.odin", "src/app/data.txt", "src/app/app_test.odin", "src/lib/lib.odin", "tools/fixture.ps1", "examples/site/page.html"}) {
		testing.expectf(t, slice.contains(inputs, rel), "an input of the package: %s", rel)
	}
	for rel in ([]string{"src/other/other.odin", "tools/unrelated.ps1", "docs/page.md", "examples/site/guest.wasm"}) {
		testing.expectf(t, !slice.contains(inputs, rel), "not an input of the package: %s", rel)
	}
}

@(test)
a_key_follows_its_inputs_and_nothing_else :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	f := fixture(t, "key")
	defer drop(f)
	k0 := step_key(&f.c, &f.step)
	testing.expect(t, k0 == step_key(&f.c, &f.step), "the same inputs: the same key")
	moves := [][2]string{{"src/app/main.odin", "package app\nimport \"wb:lib\"\nD :: #load(\"data.txt\")\nmain :: proc() { _ = lib.x; _ = \"tools/fixture.ps1\" }\n"}, {"src/lib/lib.odin", "package lib\nx := 2\n"}, {"src/app/data.txt", "two"}, {"tools/fixture.ps1", "# changed"}, {"examples/site/page.html", "changed"}, {"odin.version", "y"}}
	for m in moves { testing.expectf(t, changes_key(f, k0, m[0], m[1]), "changes the key: %s", m[0]) }
	stays := [][2]string{{"src/other/other.odin", "package other\nz := 1\n"}, {"docs/page.md", "changed"}, {"examples/site/guest.wasm", "another output"}}
	for m in stays { testing.expectf(t, !changes_key(f, k0, m[0], m[1]), "leaves the key: %s", m[0]) }

	other := f.step
	other.name = "app 2"
	testing.expect(t, step_key(&f.c, &other) != k0, "another step: another key")
	other = f.step
	other.actions = slice_of(Command{argv = strs("odin", "test", "src/app", "-define:X=1"), pkg = "src/app"})
	testing.expect(t, step_key(&f.c, &other) != k0, "another flag: another key")
	saved := f.c.prefix
	f.c.prefix = "another odin version"
	testing.expect(t, step_key(&f.c, &f.step) != k0, "another version of Odin or other flags of the run: another key")
	f.c.prefix = saved
}

// A subject of the test program: its file and what that imports, not what the other files of its package do.
@(test)
a_step_on_some_files_of_a_package_follows_those_files :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	f := fixture(t, "sources")
	defer drop(f)
	put(f, "src/mixed/one.odin", "package mixed\nimport \"wb:lib\"\nA :: lib.x\n")
	put(f, "src/mixed/two.odin", "package mixed\nimport \"wb:other\"\nB :: 1\n")
	cache_look_again(&f.c)
	f.step = Step{name = "one", actions = slice_of(Command{argv = strs("program", "-tests:a")}), sources = strs("src/mixed/one.odin")}
	inputs := step_inputs(&f.c, &f.step)
	for rel in ([]string{"src/mixed/one.odin", "src/lib/lib.odin", "examples/site/page.html"}) { testing.expectf(t, slice.contains(inputs, rel), "an input: %s", rel) }
	for rel in ([]string{"src/mixed/two.odin", "src/other/other.odin"}) { testing.expectf(t, !slice.contains(inputs, rel), "not an input: %s", rel) }
	k0 := step_key(&f.c, &f.step)
	testing.expect(t, changes_key(f, k0, "src/lib/lib.odin", "package lib\nx := 2\n"), "what the file imports changes the key")
	testing.expect(t, !changes_key(f, k0, "src/mixed/two.odin", "package mixed\nimport \"wb:other\"\nB :: 2\n"), "another file of the package leaves it")
}

@(test)
what_cannot_be_resolved_takes_the_whole_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	f := fixture(t, "wide")
	defer drop(f)
	time.sleep(SPIN_FOR_NEW_STAMP)
	put(f, "src/lib/lib.odin", "package lib\nimport \"shared:nowhere\"\n")
	cache_look_again(&f.c)
	testing.expect(t, slice.contains(step_inputs(&f.c, &f.step), "src/other/other.odin"), "an unknown collection: the whole tree")
	script := Step{name = "s", inputs = .Tree}
	testing.expect(t, slice.contains(step_inputs(&f.c, &script), "src/other/other.odin"), "a script: the whole tree")
	testing.expect(t, !slice.contains(step_inputs(&f.c, &script), "docs/page.md"), "a script: not the documentation")
	docs := Step{name = "d", inputs = .Everything}
	testing.expect(t, slice.contains(step_inputs(&f.c, &docs), "docs/page.md"), "the documentation step: the documentation")
}

@(test)
a_result_needs_the_program_it_built :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	f := fixture(t, "result")
	defer drop(f)
	step := Step{name = "tool", outs = strs("build/tool.exe")}
	_, found := result_of(&f.c, "nokey", &step)
	testing.expect(t, !found, "no result for an unknown key")
	put(f, "build/tool.exe", "program")
	result_save(&f.c, "k1", &step, 3, 7)
	r, again := result_of(&f.c, "k1", &step)
	testing.expect(t, again && r.seconds == 3 && r.checks == 7, "a saved result comes back")
	put(f, "build/tool.exe", "another program!")
	_, stale := result_of(&f.c, "k1", &step)
	testing.expect(t, !stale, "another program on the disk: no result")
	_ = os.remove(fmt.tprintf("%s/build/tool.exe", f.root))
	_, gone := result_of(&f.c, "k1", &step)
	testing.expect(t, !gone, "no program on the disk: no result")
}

// The packages found are those the compiler imports (at least), for packages of each kind.
@(test)
closure_against_the_compilers_import_graph :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	c: Cache
	c.root = "."
	cache_look_again(&c)
	for pkg in ([]string{"src/url", "src/page", "src/tools/wpt", "ext/gui_toolkit/tests/keyboard"}) {
		mine, ok := closure_packages(&c, {pkg})
		testing.expectf(t, ok && len(mine) > 0, "%s: its packages are found", pkg)
		graph, _ := tooling.capture({tooling.odin_program(), "check", pkg, TOOLKIT, WB, ONE_THREAD, "-show-import-graph", "-no-entry-point"})
		graph, _ = strings.replace_all(graph, "\\", "/", context.temp_allocator)
		root := here(".")
		root, _ = strings.replace_all(root, "\\", "/", context.temp_allocator)
		rest := graph
		for {
			quote := strings.index_byte(rest, '"')
			if quote < 0 { break }
			end := strings.index_byte(rest[quote + 1:], '"')
			if end < 0 { break }
			path := rest[quote + 1:quote + 1 + end]
			rest = rest[quote + 1 + end + 1:]
			at := strings.index(strings.to_lower(path, context.temp_allocator), strings.to_lower(root, context.temp_allocator))
			if at < 0 { continue }
			rel := strings.trim(path[at + len(root):], "/")
			if rel == "" || strings.has_suffix(rel, ".odin") { continue }
			testing.expectf(t, slice.contains(mine, rel), "%s: %s of the compiler's import graph", pkg, rel)
		}
	}
}

@(test)
tests_of_a_file_are_read_from_its_declarations :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	root := fmt.tprintf("%s/cache_test_tests_%d", TEMP_DIR, os.get_pid())
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	path := fmt.tprintf("%s/subject.odin", root)
	_ = os.write_entire_file(path, "#+private file\npackage p\n\nimport \"core:testing\"\n\n// @(test)\n// commented_out :: proc(t: ^testing.T) {}\n\n@(test)\nfirst :: proc(t: ^testing.T) {}\n\nhelper :: proc() {}\n\n@(test, private)\nsecond :: proc(t: ^testing.T) { s := `@(test)\nin_a_string :: proc`; _ = s }\n")
	names, why := declared_tests(path)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "first")
	testing.expect_value(t, names[1], "second")
	_ = os.write_entire_file(path, "package p\n")
	_, none := declared_tests(path)
	testing.expect(t, none != "", "a file with no test says so")
}

@(test)
the_globals_are_the_mutable_declarations_of_the_top_level :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	root := fmt.tprintf("%s/lint_test_%d", TEMP_DIR, os.get_pid())
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	_ = os.write_entire_file(fmt.tprintf("%s/a.odin", root), "package p\nCONSTANT :: 1\nglobal := 2\nmany, more: int\n@(private)\nmarked: bool\nfunction :: proc() { inside := 1; _ = inside }\nwhen true {\n\tin_when: int\n}\nText := `{`\nafter_text: int\n@(thread_local)\nper_thread: int\n@(private = \"file\", thread_local)\nalso_per_thread: int\n")
	_ = os.write_entire_file(fmt.tprintf("%s/b_test.odin", root), "package p\nof_a_test: int\n")
	names: [dynamic]string
	test_names: [dynamic]string
	thread_names: [dynamic]string
	for g in find_globals(root) {
		if g.test { append(&test_names, g.name) } else { append(&names, g.name) }
		if g.thread_local { append(&thread_names, g.name) }
	}
	want := []string{"global", "many", "more", "marked", "Text", "after_text", "per_thread", "also_per_thread"}
	testing.expect_value(t, len(names), len(want))
	for w in want { testing.expectf(t, slice.contains(names[:], w), "a global: %s", w) }
	testing.expect_value(t, len(test_names), 1)
	// (the lint holds a @(thread_local) global to the class thread, and that class to the attribute)
	testing.expect_value(t, len(thread_names), 2)
	testing.expect(t, slice.contains(thread_names[:], "per_thread") && slice.contains(thread_names[:], "also_per_thread"), "the thread-local globals, with the attribute alone or among others")
}

@(test)
the_code_a_test_file_runs_at_every_start_is_found :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	root := fmt.tprintf("%s/lint_inits_test_%d", TEMP_DIR, os.get_pid())
	_ = os.make_directory_all(fmt.tprintf("%s/sub", root))
	defer os.remove_all(root)
	_ = os.write_entire_file(fmt.tprintf("%s/sub/a_test.odin", root), "package p\n@(init)\nfirst :: proc \"contextless\" () {}\n@(private = \"file\", init)\nsecond :: proc \"contextless\" () {}\n@fini\nthird :: proc \"contextless\" () {}\ncalled := make_it()\nnested := Thing{f = g(1)}\nwhen true {\n\tin_when := h()\n}\nCONSTANT :: 3\ndata := [2]int{1, 2}\nlater := proc() { make_it() }\ntyped: int\n@(test)\nits_test :: proc(t: ^testing.T) { inside := make_it(); _ = inside }\n")
	_ = os.write_entire_file(fmt.tprintf("%s/b.odin", root), "package p\n@(init)\nof_the_product :: proc \"contextless\" () {}\nalso := make_it()\n")
	names: [dynamic]string
	for f in find_test_inits({root}) {
		append(&names, f.name)
		if f.name == "called" { testing.expect_value(t, f.line, 8) }
	}
	want := []string{"first", "second", "third", "called", "nested", "in_when"}
	testing.expect_value(t, len(names), len(want))
	for w in want { testing.expectf(t, slice.contains(names[:], w), "found: %s", w) }
}

// What another package reaches outside the walk, or names among the outputs of a build, changes nothing of a key computed before or after it.
@(test)
a_key_does_not_depend_on_the_packages_read_before_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	f := fixture(t, "order")
	defer drop(f)
	put(f, "build/native/extra.lib", "a library")
	put(f, "src/names/names.odin", "package names\nA :: \"examples/site/guest.wasm\"\nforeign import x \"../../build/native/extra.lib\"\n")
	script := Step{name = "script", inputs = .Tree}
	k_package := step_key(&f.c, &f.step)
	k_script := step_key(&f.c, &script)
	other := Step{name = "names", actions = slice_of(Command{argv = strs("odin", "test", "src/names"), pkg = "src/names"})}
	inputs := step_inputs(&f.c, &other)
	testing.expect(t, slice.contains(inputs, "build/native/extra.lib"), "its library is an input of what links it")
	testing.expect(t, !slice.contains(inputs, "examples/site/guest.wasm"), "an output of a build is no input")
	testing.expect_value(t, step_key(&f.c, &f.step), k_package)
	testing.expect_value(t, step_key(&f.c, &script), k_script)
}

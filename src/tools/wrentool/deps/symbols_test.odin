package deps

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:tools/tooling"

// A release's crash, named: the test tool src/tools/crashmodes built as a release is (no PDB, a map named by the build's fingerprint) indexes out of range; the report says which build and
// where it was loaded, the frames of the program are offsets in it, and the map names them: the function that indexed out of range, under main. A report from before the "build" line goes through its minidump.

CRASH_EXE :: "build/crashmodes_rel" + tooling.EXE_SUFFIX

@(test)
map_lines_are_read_and_addresses_named :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/wren-symbols-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	path := fmt.tprintf("%s/x-5F00000012345.map", dir)
	_ = os.write_entire_file(path, ` wren

 Timestamp is 5f000000 (Thu Jul 02 2020)

 Preferred load address is 0000000140000000

  Address         Publics by Value              Rva+Base               Lib:Object

 0000:00000000       __guard_flags              0000000000000100     <absolute>
 0001:00000000       runtime::bounds_trap       0000000140001000 f   a.obj
 0001:00000100       page::[dom.odin]::walk     0000000140001100 f   a.obj
`)
	m, ok := read_linker_map(path, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(m.symbols), 2)
	testing.expect_value(t, m.stamp, "5F000000")
	testing.expect_value(t, resolve_map_address(m, 0x1010), "runtime.bounds_trap+0x10")
	testing.expect_value(t, resolve_map_address(m, 0x1104), "page.walk+0x4  (dom.odin)")
	testing.expect_value(t, resolve_map_address(m, 0x10), "")
	testing.expect(t, strings.has_suffix(find_build_symbols("5F00000012345", {dir}), "x-5F00000012345.map"))
}

@(test)
frame_and_module_lines :: proc(t: ^testing.T) {
	m, ok := module_line("  build crashmodes_rel.exe 5F00000012345, base 0x7FF600000000, size 0x12345")
	testing.expect(t, ok)
	testing.expect_value(t, m.name, "crashmodes_rel.exe")
	testing.expect_value(t, m.base, u64(0x7FF600000000))
	testing.expect_value(t, m.size, u64(0x12345))
	head, addr, is_frame := frame_line("  #03 0x7FF600001010 something+1")
	testing.expect(t, is_frame)
	testing.expect_value(t, head, "  #03 0x7FF600001010")
	testing.expect_value(t, addr, u64(0x7FF600001010))
	_, _, not_frame := frame_line("*** crash: exception")
	testing.expect(t, !not_frame)
}

when ODIN_OS == .Windows {

// (the program built and crashed for real: test_all runs this outside the CI, and the crash leaves a report, no window)
@(test)
a_release_crash_is_named_from_its_map :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator   // (what tooling keeps for the process: this test is the only one that asks)
	root := tooling.repo_root()
	testing.expect(t, os.set_working_directory(root) == nil)
	code := tooling.run({command = {tooling.odin_program(), "build", "src/tools/crashmodes", "-collection:wb=src", "-o:speed", "-vet", "-out:" + CRASH_EXE, "-extra-linker-flags:/MAP"}})
	if !testing.expect_value(t, code, 0) { return }
	_, published := publish_symbols(CRASH_EXE, false)
	testing.expect(t, published, "the map is named by the fingerprint")
	fp, _ := fingerprint_of(CRASH_EXE)
	dir := fmt.tprintf("%s/wren-crash-symbolize-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	_ = tooling.run({command = {CRASH_EXE, "bounds", dir}, log = fmt.tprintf("%s/out.log", dir)})

	report := ""
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for e in entries { if strings.has_prefix(e.name, "crash ") && strings.has_suffix(e.name, ".txt") { report = e.fullpath } }
	if !testing.expect(t, report != "", "the crash left a report") { return }
	data, _ := os.read_entire_file(report, context.temp_allocator)
	text := string(data)
	testing.expectf(t, strings.contains(text, fmt.tprintf("build crashmodes_rel.exe %s, base 0x", fp)), "the report gives the build's fingerprint and base: %s", text)
	testing.expect(t, strings.contains(text, "[crashmodes_rel.exe+0x"), "and module offsets")

	named := strings.builder_make(context.temp_allocator)
	testing.expect(t, crash_symbolize(&named, report, nil))
	said := strings.to_string(named)
	trap, under := strings.index(said, "runtime.bounds_trap"), strings.index(said, "crashmodes.index_out_of_range+0x")
	testing.expectf(t, trap >= 0 && under > trap && strings.index(said[under:], "main+0x") > 0, "the frames are named from the map, the function under the trap, main under it: %s", said)

	// a report from before the "build" line: through the minidump beside it
	old_dir := fmt.tprintf("%s/old", dir)
	_ = os.make_directory_all(old_dir)
	kept := strings.builder_make(context.temp_allocator)
	for l in strings.split_lines(text, context.temp_allocator) { if !strings.has_prefix(strings.trim_left_space(l), "build ") { fmt.sbprintln(&kept, l) } }
	old := fmt.tprintf("%s/crash old.txt", old_dir)
	_ = os.write_entire_file(old, strings.to_string(kept))
	_ = os.copy_file(fmt.tprintf("%s/crash old.dmp", old_dir), fmt.tprintf("%s.dmp", report[:len(report) - len(".txt")]))
	from_dump := strings.builder_make(context.temp_allocator)
	testing.expect(t, crash_symbolize(&from_dump, old, {"build"}))
	said = strings.to_string(from_dump)
	testing.expectf(t, strings.contains(said, "come from the minidump") && strings.contains(said, "crashmodes.index_out_of_range+0x"), "named through its minidump: %s", said)
}

}

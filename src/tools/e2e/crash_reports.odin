#+build windows
package e2e_scenarios

// What leaves a crash report (the toolkit's gt:crash) and what does not need to: the test tool src/tools/crashmodes dies in each of the ways a Wren has
// died and the report folder is looked at. An access violation, an Odin assertion, a stack overflow (main thread and another one: the handler writes
// the report from a thread of its own, with stack guaranteed), a corrupted heap (the system ends the process without calling the filter: the vectored
// handler does) leave "crash-<date>-<time>-<pid>.txt" and a minidump; a fail-fast (nothing runs in the process) leaves a session file that the next start turns into
// "unclean-<date>-<time>-<pid>.txt". (test_all builds build\crashmodes.exe; the names of a release's frames: the toolkit's toolbox crash_symbolize tests.)

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file")
Mode :: struct { name, cause: string }

// (each writes a minidump: they run side by side)
// A damaged stack is seen by its report: the text comes first, and the dump, last, sometimes did not follow on a machine at work, unexplained.
@(private = "file") DUMP_MAY_LACK :: "wild_stack"
@(private = "file") MODES := [?]Mode{
	{"access", "access violation"}, {"assert", "illegal instruction"}, {"overflow", "stack overflow"}, {"overflow_thread", "stack overflow"}, {"heap", "heap corruption"},
	{"two_threads", "access violation"}, {"pool", "access violation"}, {"timer", "access violation"}, {"window_procedure", "access violation"}, {"wild_stack", "access violation"},
}

@(test)
each_way_of_dying_leaves_a_report_with_its_cause_and_a_minidump :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	exe := e2e.build_path("crashmodes", ".exe")
	dirs: [len(MODES)]string
	programs: [len(MODES)]^e2e.Program
	for m, i in MODES {
		dirs[i] = fmt.tprintf("%s/%s", root, m.name)
		_ = os.make_directory_all(dirs[i])
		programs[i] = e2e.program(t, {exe, m.name, dirs[i]})
	}
	for m, i in MODES {
		code := e2e.program_wait(programs[i])
		testing.expectf(t, !os.exists(fmt.tprintf("%s/session.txt", dirs[i])), "%s: the report ends the session, the next start reports it no second time", m.name)
		reports := e2e.files_with_prefix(dirs[i], "crash-", ".txt")
		dumps := e2e.files_with_prefix(dirs[i], "crash-", ".dmp")
		text := len(reports) == 1 ? e2e.read_text(reports[0]) : ""
		testing.expectf(t, len(reports) == 1 && (len(dumps) == 1 || m.name == DUMP_MAY_LACK) && strings.contains(text, m.cause) && strings.contains(text, "#00\t0x"), "%s: a report with the cause and a stack, and a minidump: exit %d, %d report(s), %d dump(s): %s", m.name, code, len(reports), len(dumps), text)
	}
}

// An end the program chose with its session open (a library that gives up, a path that forgot the session) says who asked for it, and is no "unclean exit" at the next start.
@(test)
an_end_of_its_own_leaves_a_report_with_the_stack_that_asked_for_it :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	exe := e2e.build_path("crashmodes", ".exe")
	for mode in ([]string{"exit", "terminate"}) {
		dir := fmt.tprintf("%s/%s", root, mode)
		_ = os.make_directory_all(dir)
		e2e.program_wait(e2e.program(t, {exe, mode, dir}))
		testing.expectf(t, !os.exists(fmt.tprintf("%s/session.txt", dir)), "%s: the report ends the session", mode)
		reports := e2e.files_with_prefix(dir, "exit-", ".txt")
		text := len(reports) == 1 ? e2e.read_text(reports[0]) : ""
		testing.expectf(t, strings.contains(text, "ended itself") && strings.contains(text, "code: 0x00000009") && strings.contains(text, "die"), "%s: who asked for it: %d report(s): %s", mode, len(reports), text)
	}
}

@(private = "file")
Poison_Mode :: struct { name, cause, said: string }

// (crashmodes_poison: the build with freed memory poisoned, base/poison.odin; gt:crash does not look for the poison in the registers: a read
// through a freed pointer is an access violation in the report, the poison is in its address)
@(private = "file") POISON_MODES := [?]Poison_Mode{
	{"freed_read", "access violation", ""}, {"arena_read", "access violation", ""},
	{"double_free", "illegal instruction", "memory: fatal: double free"}, {"freed_write", "illegal instruction", "memory: fatal: a write to freed memory"},
}

@(test)
freed_memory_ends_the_process_with_a_report_that_says_so :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	exe := e2e.build_path("crashmodes_poison", ".exe")
	for m in POISON_MODES {
		dir := fmt.tprintf("%s/%s", root, m.name)
		_ = os.make_directory_all(dir)
		p := e2e.program(t, {exe, m.name, dir}, {env = {"WREN_POISON_PAGES="}})
		code := e2e.program_wait(p)
		_, said := e2e.program_output(p)
		reports := e2e.files_with_prefix(dir, "crash-", ".txt")
		text := len(reports) == 1 ? e2e.read_text(reports[0]) : ""
		testing.expectf(t, strings.contains(text, m.cause) && strings.contains(text, "#00\t0x") && strings.contains(said, m.said), "%s: a report with the cause and a stack: exit %d, %d report(s): %s, it said: %s", m.name, code, len(reports), text, said)
	}
}

// WREN_POISON_PAGES: a read of a plain number of a freed block faults too, the block on pages of its own (poison_windows.odin), and a program works on them.
@(test)
a_freed_number_faults_on_pages_of_their_own :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	exe := e2e.build_path("crashmodes_poison", ".exe")
	e2e.program_wait(e2e.program(t, {exe, "freed_number", dir}, {env = {"WREN_POISON_PAGES="}}))
	testing.expect_value(t, len(e2e.files_with_prefix(dir, "crash-", ".txt")), 0)
	e2e.program_wait(e2e.program(t, {exe, "freed_number", dir}, {env = {"WREN_POISON_PAGES=1"}}))
	reports := e2e.files_with_prefix(dir, "crash-", ".txt")
	text := len(reports) == 1 ? e2e.read_text(reports[0]) : ""
	testing.expectf(t, strings.contains(text, "access violation") && strings.contains(text, "die"), "a report at the read: %d report(s): %s", len(reports), text)
}

@(test)
a_fail_fast_is_reported_by_the_next_start_once :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	exe := e2e.build_path("crashmodes", ".exe")
	session := fmt.tprintf("%s/session.txt", dir)
	e2e.program_wait(e2e.program(t, {exe, "failfast", dir}))
	testing.expect_value(t, len(e2e.files_with_prefix(dir, "crash-")), 0)
	testing.expect(t, os.exists(session), "nothing runs in the process: a session file is left")
	e2e.program_wait(e2e.program(t, {exe, "clean", dir}))
	reports := e2e.files_with_prefix(dir, "unclean-", ".txt")
	testing.expect_value(t, len(reports), 1)
	if len(reports) == 1 { testing.expect(t, strings.contains(e2e.read_text(reports[0]), "ended without a report"), "the next start reports the session") }
	testing.expect(t, !os.exists(session), "a clean end removes the session file")
	e2e.program_wait(e2e.program(t, {exe, "clean", dir}))
	testing.expect_value(t, len(e2e.files_with_prefix(dir, "unclean-", ".txt")), 1)
}

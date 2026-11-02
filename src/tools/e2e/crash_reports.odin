#+build windows
package e2e_scenarios

// What leaves a crash report (src/tools/crashtrace) and what does not need to: the test tool src/tools/crashmodes dies in each of the ways a Wren has
// died and the report folder is looked at. An access violation, an Odin assertion, a stack overflow (main thread and another one: the handler writes
// the report from a thread of its own, with stack guaranteed), a corrupted heap (the system ends the process without calling the filter: the vectored
// handler does) leave "crash <date>.txt" and a minidump; a fail-fast (nothing runs in the process) leaves a session file that the next start turns into
// "unclean exit <date>.txt", with Windows' own record of the end. (test_all builds build\crashmodes.exe; the names of a release's frames: src/tools/wrentool/deps/symbols_test.odin.)

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file")
Mode :: struct { name, cause: string }

// (each writes a minidump: they run side by side)
@(private = "file") MODES := [?]Mode{
	{"access", "access violation"}, {"assert", "illegal instruction"}, {"overflow", "stack overflow"}, {"overflow_thread", "stack overflow"}, {"heap", "heap corruption"},
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
		reports := e2e.files_with_prefix(dirs[i], "crash ", ".txt")
		dumps := e2e.files_with_prefix(dirs[i], "crash ", ".dmp")
		text := len(reports) == 1 ? e2e.read_text(reports[0]) : ""
		testing.expectf(t, len(reports) == 1 && len(dumps) == 1 && strings.contains(text, m.cause) && strings.contains(text, "#00 0x"), "%s: a report with the cause and a stack, and a minidump: exit %d, %d report(s), %d dump(s): %s", m.name, code, len(reports), len(dumps), text)
	}
}

@(test)
a_fail_fast_is_reported_by_the_next_start_once :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	exe := e2e.build_path("crashmodes", ".exe")
	session := fmt.tprintf("%s/session.txt", dir)
	e2e.program_wait(e2e.program(t, {exe, "failfast", dir}))
	testing.expect_value(t, len(e2e.files_with_prefix(dir, "crash ")), 0)
	testing.expect(t, os.exists(session), "nothing runs in the process: a session file is left")
	e2e.program_wait(e2e.program(t, {exe, "clean", dir}))
	reports := e2e.files_with_prefix(dir, "unclean exit ", ".txt")
	testing.expect_value(t, len(reports), 1)
	if len(reports) == 1 { testing.expect(t, strings.contains(e2e.read_text(reports[0]), "ended without a crash report"), "the next start reports the session") }
	testing.expect(t, !os.exists(session), "a clean end removes the session file")
	e2e.program_wait(e2e.program(t, {exe, "clean", dir}))
	testing.expect_value(t, len(e2e.files_with_prefix(dir, "unclean exit ", ".txt")), 1)
}

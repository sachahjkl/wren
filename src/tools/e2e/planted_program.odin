#+build windows
package e2e_scenarios

// The programs the browser starts are the system's, by their full path (src\desktop\system_windows.odin, crashtrace): a program of the same name in
// the working directory must not run. The case that was open: after a session that ended without a report (killed, a fail-fast), the next start asks
// `wevtutil.exe` for Windows' record of that end; started by its bare name, CreateProcess looked in the working directory first, so a wevtutil.exe
// beside a document opened from that folder ran with the user's rights.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") PLANTED_SOURCE :: `package main
import "core:os"
main :: proc() {{ _ = os.write_entire_file(%q, transmute([]byte)string("ran")) }}
`

@(test)
a_program_of_the_working_folder_never_runs_in_place_of_the_systems :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	trap := fmt.tprintf("%s/trap", dir)
	profile := fmt.tprintf("%s/profile", dir)
	_ = os.make_directory_all(trap)
	source := fmt.tprintf("%s/planted.odin", dir)
	marker, _ := strings.replace_all(fmt.tprintf("%s/planted_ran.txt", dir), `\`, "/", context.temp_allocator)
	planted := fmt.tprintf("%s/wevtutil.exe", trap)
	e2e.write_text(source, fmt.tprintf(PLANTED_SOURCE, marker))
	built := e2e.run(t, {"odin", "build", source, "-file", fmt.tprintf("-out:%s", planted)})
	testing.expectf(t, built.code == 0 && os.exists(planted), "the planted program is built: %s %s", built.out, built.err)

	e2e.kill(e2e.launch(t, {profile = profile}))
	next := e2e.launch(t, {profile = profile, start = {cwd = trap}})
	crashes := fmt.tprintf("%s/crashes", profile)
	e2e.wait_for(t, crashes, proc(dir: string) -> bool { return len(e2e.files_with_prefix(dir, "unclean exit")) > 0 }, "the report of the session that ended without one")
	testing.expect(t, !os.exists(marker), "the wevtutil.exe of the working folder did not run")
	e2e.quit(next)
}

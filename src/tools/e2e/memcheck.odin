package e2e_scenarios

// The browser's check build on a real session: several tabs, navigations (JavaScript, images, forms, animations, shadow DOM), back / forward / reload
// (the back/forward cache), closed tabs and their reopening, the command palette, about:history and its tree, then a normal exit. The check build
// (build.bat check -> build\wren_check.exe: every allocation tracked, src\base\memory.odin) drives itself from a script (WREN_MEMCHECK_SCRIPT,
// src\browser\memcheck.odin), writes what is still allocated at exit to the profile's memtrack.txt and exits with code 3 when anything is
// (WREN_MEMTRACK_FAIL=1). WREN_MEMTRACK_STACK=1 in the environment: the report names the callers of each block. WREN_MEMCHECK_EXE: another such program.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:e2e"

// A session of the check build takes minutes under load: this is what ends one that hangs.
@(private = "file") SESSION_LIMIT :: 5 * time.Minute

// {o}: the test server's origin.
@(private = "file") SESSION :: `load
open {o}/site/js.html
load
open {o}/site/images.html
load
open {o}/site/forms.html
load
open {o}/site/js-dom.html
load
go {o}/site/animations.html
load
frames 20
go {o}/site/mutation.html
load
frames 20
command nav.back
load
command nav.back
load
command nav.forward
load
command nav.reload
load
command tab.close
command tab.close
command tab.reopen_closed
load
command browser.command_palette
frames 10
command browser.history
wait 500
command browser.history_tree
wait 500
command tab.close
open {o}/site/shadow-dom.html
load
open {o}/site/layout.html
load
open about:wren?card=sample
load
frames 60
wait 500
open {o}/site/media.html
load
command tab.duplicate
load
command tab.close
command tab.close
command tab.close
wait 500
quit
`

@(test)
the_check_build_exits_a_scripted_session_with_nothing_allocated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, SESSION_LIMIT * 2)
	server := e2e.test_server(t)
	dir := e2e.temp_folder(t)
	profile := fmt.tprintf("%s/profile", dir)
	_ = os.make_directory_all(profile)
	script := fmt.tprintf("%s/session.txt", dir)
	text, _ := strings.replace_all(SESSION, "{o}", server.origin, context.temp_allocator)
	e2e.write_text(script, text)
	exe, chosen := os.lookup_env("WREN_MEMCHECK_EXE", context.temp_allocator)
	if !chosen || exe == "" { exe = e2e.build_path("wren_check", ".exe") }
	p := e2e.program(t, {exe, "--profile", profile, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false", e2e.url(server, "/site/index.html")},
		{env = {fmt.tprintf("WREN_MEMCHECK_SCRIPT=%s", script), "WREN_MEMTRACK_FAIL=1"}})
	code := e2e.program_wait(p, SESSION_LIMIT)
	testing.expectf(t, code == 0, "the check build exits clean: code %d (3: allocations left at exit)\n%s", code, e2e.read_text(fmt.tprintf("%s/memtrack.txt", profile)))
}

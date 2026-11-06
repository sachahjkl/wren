#+build windows
package e2e_scenarios

// wren.com, the console launcher (src\tools\wrencom): `wren ctl ...` gives its output and its exit code to the caller, whatever the outputs are (what a
// terminal's `>`, `2>`, `2>&1` and `|` hand over to it), an address or an option of the window lets go at once, the launcher dies with its child and
// refuses to start itself; and Setup (package desktop) writes it beside wren.exe with the PATH entry and takes it away with it. Everything in a scratch
// folder with scratch desktop roots (WREN_DESKTOP_*).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

// `wren ctl`'s exit codes, and the launcher's.
@(private = "file") EXIT_NO_SERVER :: 3
@(private = "file") EXIT_USAGE :: 4
@(private = "file") EXIT_NOT_RUNNABLE :: 126
@(private = "file") EXIT_NOT_FOUND :: 127
// `--desktop-integration=status`.
@(private = "file") STATUS_ABSENT :: 1
@(private = "file") STATUS_TO_REPAIR :: 2
@(private = "file") HELP_WORDS :: "drives a running Wren"
@(private = "file") UNKNOWN_WORDS :: "unknown command"
@(private = "file") NOT_THE_LAUNCHER :: "somebody else's program"
// What the system may take over a process killed with its graphics device (10 to 22 s measured with every processor busy); only ends a failing run.
@(private = "file") LEAVES_THE_SYSTEM_MS :: 60_000

// wren.exe and wren.com side by side, as Setup leaves them; the environment of a program there.
@(private = "file")
side_by_side :: proc(t: ^testing.T, root: string) -> (com: string, env: []string) {
	app := fmt.tprintf("%s/app", root)
	_ = os.make_directory_all(app)
	com = fmt.tprintf("%s/wren.com", app)
	testing.expect_value(t, os.copy_file(fmt.tprintf("%s/wren.exe", app), e2e.wren_exe()), nil)
	testing.expect_value(t, os.copy_file(com, e2e.build_path("wren", ".com")), nil)
	return com, desktop_scratch(t, root).env
}

@(test)
a_console_command_gives_its_output_and_its_exit_code :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	com, env := side_by_side(t, root)
	start := api.Start_Options{env = env}

	help := e2e.run(t, {com, "ctl", "help"}, start)
	testing.expect_value(t, help.code, 0)
	testing.expectf(t, strings.contains(help.out, HELP_WORDS) && strings.contains(help.out, "  run"), "the text is on the standard output, read through a pipe as `|` does: %q", help.out)
	one := e2e.run(t, {com, "ctl", "help", "ping"}, start)
	testing.expectf(t, strings.contains(one.out, "wren ctl ping"), "help <command>: the text of that command: %q", one.out)

	bad := e2e.run(t, {com, "ctl", "nosuchcommand"}, start)
	testing.expect_value(t, bad.code, EXIT_USAGE)
	testing.expectf(t, strings.contains(bad.err, UNKNOWN_WORDS) && !strings.contains(bad.out, UNKNOWN_WORDS), "the message is on the error output: %q, %q", bad.out, bad.err)

	// `> file`, `2> file`
	to_file := fmt.tprintf("%s/out.txt", root)
	e2e.run(t, {com, "ctl", "help"}, {env = env, stdout = {file = to_file}, stderr = {file = fmt.tprintf("%s/none.txt", root)}})
	testing.expect_value(t, e2e.read_text(to_file), help.out)
	o, e := fmt.tprintf("%s/o.txt", root), fmt.tprintf("%s/e.txt", root)
	in_files := e2e.run(t, {com, "ctl", "nosuchcommand"}, {env = env, stdout = {file = o}, stderr = {file = e}})
	testing.expect_value(t, in_files.code, EXIT_USAGE)
	testing.expectf(t, e2e.read_text(o) == "" && strings.contains(e2e.read_text(e), UNKNOWN_WORDS), "the error output goes to its own file, the standard output stays empty")
	// `2>&1`
	merged := e2e.run(t, {com, "ctl", "nosuchcommand"}, {env = env, stdout = {pipe = true}, merged = true})
	testing.expectf(t, strings.contains(merged.out, UNKNOWN_WORDS), "the error message comes through the standard output: %q", merged.out)

	nobody := e2e.run(t, {com, "ctl", "ping", "--remote", fmt.tprintf("nosuchwren-%s", e2e.unique())}, start)
	testing.expect_value(t, nobody.code, EXIT_NO_SERVER)

	// the integration's flag is a console command as well
	status := e2e.run(t, {com, "--desktop-integration=status"}, start)
	testing.expectf(t, status.code == STATUS_ABSENT && strings.contains(status.out, "absent"), "it waits, prints, code 1: %d, %q", status.code, status.out)
}

@(test)
setup_writes_the_launcher_with_the_path_entry_and_takes_it_away :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	bare := fmt.tprintf("%s/bare", root)
	_ = os.make_directory_all(bare)
	exe := fmt.tprintf("%s/wren.exe", bare)
	testing.expect_value(t, os.copy_file(exe, e2e.wren_exe()), nil)
	com := fmt.tprintf("%s/wren.com", bare)
	profile := fmt.tprintf("%s/profile", root)
	start := api.Start_Options{env = desktop_scratch(t, root).env}
	integration :: proc(t: ^testing.T, exe, profile, mode: string, with_path: bool, start: api.Start_Options) -> e2e.Run {
		return e2e.run(t, {exe, "--profile", profile, "--pref", fmt.tprintf("browser.desktop_integration.add_to_path=%v", with_path), fmt.tprintf("--desktop-integration=%s", mode)}, start)
	}

	r := integration(t, exe, profile, "install", false, start)
	testing.expectf(t, r.code == 0 && !os.exists(com), "without the PATH option: no wren.com: %d, %s", r.code, r.out)
	r = integration(t, exe, profile, "install", true, start)
	testing.expectf(t, r.code == 0 && os.exists(com), "with the PATH option: wren.com is written beside wren.exe: %d, %s", r.code, r.out)
	testing.expect_value(t, e2e.read_text(com), e2e.read_text(e2e.build_path("wren", ".com")))
	r = integration(t, exe, profile, "status", true, start)
	testing.expectf(t, r.code == 0 && strings.has_prefix(r.out, "installed"), "the status is complete with it: %d, %s", r.code, r.out)
	os.remove(com)
	r = integration(t, exe, profile, "status", true, start)
	testing.expectf(t, r.code == STATUS_TO_REPAIR && strings.contains(r.out, "to repair"), "the status says to repair without it: %d, %s", r.code, r.out)
	integration(t, exe, profile, "install", true, start)
	testing.expect(t, os.exists(com), "installing again puts it back")
	integration(t, exe, profile, "install", false, start)
	testing.expect(t, !os.exists(com), "the PATH option unticked: wren.com goes")
	integration(t, exe, profile, "install", true, start)
	integration(t, exe, profile, "remove", true, start)
	testing.expect(t, !os.exists(com), "removing the integration: wren.com goes")
	e2e.write_text(com, NOT_THE_LAUNCHER)
	integration(t, exe, profile, "install", true, start)
	integration(t, exe, profile, "remove", true, start)
	testing.expect_value(t, e2e.read_text(com), NOT_THE_LAUNCHER)
}

@(test)
the_launcher_alone_says_what_is_wrong :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	self := fmt.tprintf("%s/selfstart.exe", root)
	testing.expect_value(t, os.copy_file(self, e2e.build_path("wren", ".com")), nil)
	r := e2e.run(t, {self, "ctl", "help"})
	testing.expectf(t, r.code == EXIT_NOT_RUNNABLE && strings.contains(r.err, "would start itself"), "named .exe it would start itself: %d, %q", r.code, r.err)
	lone := fmt.tprintf("%s/wren.com", root)
	testing.expect_value(t, os.copy_file(lone, e2e.build_path("wren", ".com")), nil)
	r = e2e.run(t, {lone, "ctl", "help"})
	testing.expectf(t, r.code == EXIT_NOT_FOUND && strings.contains(r.err, "wren.exe"), "without a wren.exe beside it: %d, %q", r.code, r.err)
}

// A window's options: it returns at once with code 0, before the Wren it started has any window (the Wren then answers, and its channel closes it).
@(test)
an_interface_start_lets_go_at_once :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	com, env := side_by_side(t, root)
	name := fmt.tprintf("wrencom-%s", e2e.unique())
	started := e2e.run(t, {com, "--headless", "--no-single-instance", "--profile", fmt.tprintf("%s/profile_gui", root), fmt.tprintf("--remote=%s", name), "about:blank"}, {env = env})
	testing.expect_value(t, started.code, 0)
	s := api.Session{name = name, connect_wait_ms = e2e.PROCESS_WAIT_MS}
	who, e := api.ping(&s)
	testing.expectf(t, e == .None, "the Wren it started answers: %v", e)
	process, opened := api.process_open(who.pid)
	testing.expect(t, opened)
	defer api.process_release(&process)
	api.quit(&s)
	testing.expect(t, api.process_wait(&process, e2e.PROCESS_WAIT_MS), "quit: it has closed")
	api.close_session(&s)
}

// --cli waits for anything; the launcher's death takes its child along (the job object). Killed is an exit code on the process: not the process gone
// from the list, which a process killed with its graphics device leaves to the system (7 to 18 s with every core busy, the code having been set at once).
@(test)
the_launcher_dies_with_its_child :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	com, env := side_by_side(t, root)
	name := fmt.tprintf("wrencom-%s", e2e.unique())
	launcher := e2e.program(t, {com, "--cli", "--headless", "--no-single-instance", "--profile", fmt.tprintf("%s/profile_job", root), fmt.tprintf("--remote=%s", name), "about:blank"}, {env = env})
	s := api.Session{name = name, connect_wait_ms = e2e.PROCESS_WAIT_MS}
	who, e := api.ping(&s)
	testing.expectf(t, e == .None, "the Wren it started answers: %v", e)
	api.close_session(&s)
	testing.expect(t, api.process_alive(&launcher.process), "--cli: the launcher waits while the Wren it started runs")
	wren, opened := api.process_open(who.pid)
	testing.expect(t, opened)
	defer api.process_release(&wren)
	api.process_kill(&launcher.process)
	e2e.wait_for(t, &wren, proc(p: ^api.Process) -> bool { return api.process_ended(p) }, "the Wren it started to be killed")
	// (its program is a copy in this test's folder, which goes only when the system has done with the process: seconds more under load,
	// sometimes over a minute with its graphics device. How fast the system lets go is not the launcher's doing: no check, only the wait.)
	api.process_wait(&wren, LEAVES_THE_SYSTEM_MS)
}

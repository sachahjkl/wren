#+build windows
package e2e_scenarios

// The single instance of real wren.exe processes (src/browser/instance_shell.odin, toolkit:instance): a second start with the same profile hands its
// addresses to the first one and ends with exit code 0; the cases that must not (another profile, another executable, --new-window, a first Wren that
// does not answer) keep a process of their own. Hidden windows, scratch profiles, each with WREN_SINGLE_INSTANCE=on; the first one is read over its channel.

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"
import "core:time"
import "wb:e2e"
import "wb:remote/api"

foreign import ntdll "system:ntdll.lib"
@(default_calling_convention = "system", private = "file")
foreign ntdll {
	NtSuspendProcess :: proc(h: win.HANDLE) -> i32 ---
	NtResumeProcess  :: proc(h: win.HANDLE) -> i32 ---
}

@(private = "file") SINGLE_ON := []string{"WREN_SINGLE_INSTANCE=on"}
@(private = "file") SINGLE_OFF := []string{"WREN_SINGLE_INSTANCE=off"}
// What restores the tabs a test reads back from the file a close leaves.
@(private = "file") RESTORE_PREF :: "browser.session.restore=true"
// How long a start waits for a first one that does not answer (instance_shell.odin, INSTANCE_ACQUIRE_WAIT_MS: 3 s); a little less, the clock's grain.
@(private = "file") UNANSWERED_AT_LEAST_MS :: 2500

// The first Wren of a profile: it answers on its channel once it owns the window a second start talks to.
@(private = "file")
first :: proc(t: ^testing.T, profile: string, address := "about:config") -> ^e2e.Wren_Process {
	return e2e.launch(t, {hidden = true, profile = profile, single_instance = true, prefs = {RESTORE_PREF}, no_address = true, extra = {address}, start = {env = SINGLE_ON}})
}

// A later start, as a person's: hidden too, no channel asked for; it ends by itself when it hands over.
@(private = "file")
later :: proc(t: ^testing.T, exe, profile: string, env: []string, extra: ..string) -> ^e2e.Program {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, exe, "--hidden", "--profile", profile, "--pref", RESTORE_PREF, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false")
	append(&args, ..extra)
	return e2e.program(t, args[:], {env = env})
}

@(private = "file")
tabs_of :: proc(p: ^e2e.Wren_Process) -> string {
	targets, _ := api.targets(p.s)
	urls := make([dynamic]string, context.temp_allocator)
	for tab in targets.tabs { append(&urls, tab.url) }
	return strings.join(urls[:], " ", context.temp_allocator)
}

// A start that keeps a process of its own has opened its profile for good: the marker it writes says so, with its pid (a start that hands over never gets there).
@(private = "file")
keeps_its_own :: proc(t: ^testing.T, p: ^e2e.Program, profile, what: string, loc := #caller_location) {
	Look :: struct { p: ^e2e.Program, marker: string }
	e2e.wait_for(t, Look{p, fmt.tprintf("%s/running.txt", profile)}, proc(l: Look) -> bool {
		return !api.process_alive(&l.p.process) || strings.contains(e2e.read_text(l.marker), fmt.tprintf("pid %d", l.p.pid))
	}, what, loc = loc)
	testing.expectf(t, api.process_alive(&p.process), "%s: a process of its own", what, loc = loc)
}

@(test)
a_second_start_hands_its_addresses_over_and_ends_with_code_0 :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	a := first(t, profile)
	api.wait_load(a.s)
	b := later(t, e2e.wren_exe(), profile, SINGLE_ON, "about:wren", "about:about")
	testing.expect_value(t, e2e.program_wait(b), 0)
	api.wait_until(a.s, proc(s: ^api.Session) -> bool {
		targets, _ := api.targets(s)
		return len(targets.tabs) == 3
	}, "the two addresses to open in the first window")
	testing.expect_value(t, tabs_of(a), "about:config about:wren about:about")
	e2e.quit(a)
}

@(test)
a_start_with_no_address_brings_the_window_forward :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	a := first(t, profile)
	api.set_window(a.s, {state = "minimized"})
	api.wait_until(a.s, proc(s: ^api.Session) -> bool { b, _ := api.window_bounds(s); return b.state == "minimized" }, "the window to be minimized")
	testing.expect_value(t, e2e.program_wait(later(t, e2e.wren_exe(), profile, SINGLE_ON)), 0)
	api.wait_until(a.s, proc(s: ^api.Session) -> bool { b, _ := api.window_bounds(s); return b.state != "minimized" }, "the first window to be restored")
	targets, _ := api.targets(a.s)
	testing.expect_value(t, len(targets.tabs), 1)
	e2e.quit(a)
}

@(test)
what_must_not_hand_over_keeps_a_process_of_its_own :: proc(t: ^testing.T) {
	root := e2e.temp_folder(t)
	profile := fmt.tprintf("%s/p1", root)
	a := first(t, profile)

	// (its own folder: two windows do not write one session)
	own := fmt.tprintf("%s/p1nw", root)
	keeps_its_own(t, later(t, e2e.wren_exe(), own, SINGLE_ON, "--new-window", "about:wren"), own, "--new-window")
	other := fmt.tprintf("%s/p2", root)
	keeps_its_own(t, later(t, e2e.wren_exe(), other, SINGLE_ON, "about:about"), other, "another profile")

	// Setup must be able to replace the installed copy while it runs. (These two share the first one's profile, so its marker stays: the first's tabs are what says.)
	dir := fmt.tprintf("%s/copy", root)
	_ = os.make_directory_all(dir)
	copy := fmt.tprintf("%s/wren.exe", dir)
	testing.expect_value(t, os.copy_file(copy, e2e.wren_exe()), nil)
	another := e2e.launch(t, {exe = copy, hidden = true, profile = profile, single_instance = true, prefs = {RESTORE_PREF}, no_address = true, extra = {"about:wren"}, start = {env = SINGLE_ON}})
	off := e2e.launch(t, {hidden = true, profile = profile, single_instance = true, prefs = {RESTORE_PREF}, no_address = true, extra = {"about:about"}, start = {env = SINGLE_OFF}})
	targets, _ := api.targets(a.s)
	testing.expect_value(t, len(targets.tabs), 1)
	e2e.quit(off)
	e2e.quit(another)
	e2e.quit(a)
}

@(test)
a_first_wren_that_does_not_answer_does_not_hold_the_second :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	a := first(t, profile)
	api.wait_load(a.s)
	NtSuspendProcess(a.wren.process.handle)
	began := time.tick_now()
	b := later(t, e2e.wren_exe(), profile, SINGLE_ON, "about:wren")
	// (the marker stays the first's: a Wren runs on the profile; the second start says it did not hand over by living past the wait and making its window)
	e2e.wait_for(t, b.pid, proc(pid: int) -> bool { return has_a_window(pid) }, "the second start's own window")
	waited := time.duration_milliseconds(time.tick_since(began))
	NtResumeProcess(a.wren.process.handle)
	testing.expect(t, api.process_alive(&b.process), "a process of its own")
	testing.expectf(t, waited >= UNANSWERED_AT_LEAST_MS, "after about the 3 s it waits, not at once: %.0f ms", waited)
	e2e.quit(a)
}

// Does the process have a window of its own, shown or not? (A start that hands over ends before it makes one.)
@(private = "file")
has_a_window :: proc(pid: int) -> bool {
	Find :: struct { pid: win.DWORD, found: bool }
	f := Find{pid = win.DWORD(pid)}
	win.EnumWindows(proc "system" (h: win.HWND, l: win.LPARAM) -> win.BOOL {
		f := (^Find)(rawptr(uintptr(l)))
		owner: win.DWORD
		win.GetWindowThreadProcessId(h, &owner)
		if owner == f.pid { f.found = true; return false }
		return true
	}, win.LPARAM(uintptr(&f)))
	return f.found
}

// A start while the first one is closing: its address is not lost, whichever of the two ends up with it.
@(test)
a_start_while_the_first_one_closes_loses_nothing :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	a := first(t, profile)
	api.wait_load(a.s)
	// (told to close, not waited for: the second start comes right behind)
	api.browser_close(a.s)
	api.close_session(a.s)
	// (with a channel of its own, to close it if it keeps a process: it takes the profile over, or hands its address over and ends)
	b := e2e.launch_begin(t, {hidden = true, profile = profile, single_instance = true, prefs = {RESTORE_PREF}, no_address = true, extra = {"about:wren"}, start = {env = SINGLE_ON}})
	api.connect_launched(b.s, &b.wren, api.START_WAIT_MS)
	testing.expect(t, api.process_wait(&a.wren.process, api.QUIT_WAIT_MS), "the first one has closed")
	a.ended = true
	testing.expect_value(t, e2e.quit(b), 0)
	session := e2e.read_text(fmt.tprintf("%s/session.txt", profile))
	testing.expectf(t, strings.contains(session, "about:wren"), "the address arrived, whichever kept it: %q", session)
}

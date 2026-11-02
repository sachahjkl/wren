package e2e_scenarios

// After a Wren ends abnormally the next start brings the tabs back, and never loops (src/browser/crash_recovery.odin, docs/crash-recovery.md). Real
// processes on a scratch profile; a Wren is "crashed" by ending its process, which leaves running.txt and recovery.txt in the profile as a crash does.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") TAB_A :: "about:config"
@(private = "file") TAB_B :: "about:demos"
// Snapshots soon after a change.
@(private = "file") SNAPSHOT_PREF :: "browser.session.crash_snapshot_ms=500"
// A restoring start that soon counts as stable.
@(private = "file") STABLE_SOON_PREF :: "browser.session.crash_stable_ms=1000"
@(private = "file") MARKER_FILE :: "running.txt"
@(private = "file") SNAPSHOT_FILE :: "recovery.txt"
@(private = "file") BACKUP_PREFIX :: "crashed-session "

@(private = "file")
start_on :: proc(t: ^testing.T, profile: string, prefs: ..string) -> ^e2e.Wren_Process {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, SNAPSHOT_PREF)
	append(&all, ..prefs)
	return e2e.launch(t, {profile = profile, prefs = all[:]})
}

// The addresses of its tabs, in their order.
@(private = "file")
tabs_of :: proc(p: ^e2e.Wren_Process) -> string {
	targets, _ := api.targets(p.s)
	urls := make([dynamic]string, context.temp_allocator)
	for tab in targets.tabs { append(&urls, tab.url) }
	return strings.join(urls[:], " ", context.temp_allocator)
}

@(private = "file")
file_of :: proc(profile, name: string) -> string { return fmt.tprintf("%s/%s", profile, name) }

@(private = "file")
open_two_tabs :: proc(t: ^testing.T, p: ^e2e.Wren_Process, profile: string) {
	api.new_tab(p.s, TAB_A)
	api.new_tab(p.s, TAB_B)
	e2e.wait_file(t, file_of(profile, SNAPSHOT_FILE), TAB_B)
}

@(test)
a_crash_brings_the_tabs_back_and_two_in_a_row_do_not_loop :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	marker := file_of(profile, MARKER_FILE)
	restored := fmt.tprintf("about:blank %s %s about:blank", TAB_A, TAB_B)

	first := start_on(t, profile)
	text := e2e.read_text(marker)
	testing.expectf(t, strings.contains(text, "wren-running 1") && strings.contains(text, "restoring 0"), "a start writes its marker: %q", text)
	open_two_tabs(t, first, profile)
	e2e.kill(first)
	testing.expect(t, os.exists(marker) && os.exists(file_of(profile, SNAPSHOT_FILE)), "a crash leaves the marker and the snapshot")

	// (the address a start is given opens after the restored tabs)
	second := start_on(t, profile)
	testing.expect_value(t, tabs_of(second), restored)
	testing.expect(t, strings.contains(e2e.read_text(marker), "restoring 1"), "its marker says it is restoring")

	// the restoring start crashes before it is stable: the third does not open the tabs again
	e2e.kill(second)
	third := start_on(t, profile)
	testing.expect_value(t, tabs_of(third), "about:blank")
	backups := e2e.files_with_prefix(profile, BACKUP_PREFIX)
	testing.expect_value(t, len(backups), 1)
	if len(backups) == 1 {
		saved := e2e.read_text(backups[0])
		testing.expectf(t, strings.contains(saved, TAB_A) && strings.contains(saved, TAB_B), "the tabs are kept in a file of the profile: %q", saved)
	}
	testing.expect(t, strings.contains(e2e.read_text(marker), "restoring 0"), "its marker does not say restoring")
	api.run_command(third.s, "tab.restore_crashed")
	// (the file is the last snapshot of the start that crashed: with its own address or without, as it had the time to take one or not)
	api.wait_until(third.s, proc(s: ^api.Session) -> bool {
		targets, _ := api.targets(s)
		return len(targets.tabs) >= 3
	}, "the command to bring the tabs back")
	back := tabs_of(third)
	testing.expectf(t, strings.contains(back, TAB_A) && strings.contains(back, TAB_B), "the tabs came back: %q", back)

	// a normal end removes both files, and the next start restores nothing
	testing.expect_value(t, e2e.quit(third), 0)
	testing.expect(t, !os.exists(marker) && !os.exists(file_of(profile, SNAPSHOT_FILE)), "a normal end removes the marker and the snapshot")
	fourth := start_on(t, profile)
	testing.expect_value(t, tabs_of(fourth), "about:blank")
	e2e.quit(fourth)
}

// A restoring start that lived long enough counts as stable: the crash after it is a first crash again.
@(test)
a_crash_after_a_stable_restore_restores_again :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	first := start_on(t, profile)
	open_two_tabs(t, first, profile)
	e2e.kill(first)
	second := start_on(t, profile, STABLE_SOON_PREF)
	testing.expect_value(t, tabs_of(second), fmt.tprintf("about:blank %s %s about:blank", TAB_A, TAB_B))
	e2e.wait_for(t, file_of(profile, MARKER_FILE), proc(path: string) -> bool { return strings.contains(e2e.read_text(path), "restoring 0") }, "the marker to stop saying restoring")
	e2e.kill(second)
	third := start_on(t, profile)
	testing.expect(t, strings.has_prefix(tabs_of(third), fmt.tprintf("about:blank %s %s", TAB_A, TAB_B)), "not the second in a row")
	e2e.kill(third)
}

// A Wren that still runs on the profile is not a crash: the second start leaves its files alone.
@(test)
a_wren_that_runs_is_not_a_crash :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	marker := file_of(profile, MARKER_FILE)
	first := start_on(t, profile)
	api.new_tab(first.s, TAB_A)
	e2e.wait_file(t, file_of(profile, SNAPSHOT_FILE), TAB_A)
	before := e2e.read_text(marker)
	second := e2e.launch(t, {profile = profile})
	targets, _ := api.targets(second.s)
	testing.expect_value(t, len(targets.tabs), 1)
	testing.expect_value(t, e2e.read_text(marker), before)
	e2e.quit(second)
	testing.expect_value(t, e2e.read_text(marker), before)
	e2e.quit(first)
}

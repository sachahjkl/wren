package e2e_scenarios

// What Ctrl+Shift+T brings back (closed_tabs.odin), each with what it had: a tab its history, its place and its group, a window its
// tabs together, the session of the run before all of it, in a run that started on the start page. And the option that reopens the
// session at start-up, from the menu's command.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:browser"
import "wb:e2e"

@(private = "file") REOPEN_KEY :: "Ctrl+Shift+T"

@(private = "file")
titled :: proc(dir, title: string) -> string {
	return e2e.file_page(dir, fmt.tprintf("%s.html", title), fmt.tprintf("<!doctype html><meta charset=utf-8><title>%s</title><body>%s", title, title))
}

// "One Two [Three]": the titles of the tabs of every window, in order, the pinned ones in brackets.
@(private = "file")
strip :: proc(s: ^e2e.Session) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for x, i in e2e.targets(s).tabs {
		if i > 0 { strings.write_byte(&sb, ' ') }
		strings.write_string(&sb, x.pinned ? fmt.tprintf("[%s]", x.title) : x.title)
	}
	return strings.to_string(sb)
}

// A tab more, loaded.
@(private = "file")
add_tab :: proc(s: ^e2e.Session, url: string) -> int {
	id := e2e.new_tab(s, url)
	e2e.wait_load(s)
	return id
}

@(private = "file")
closed_count :: proc(s: ^e2e.Session) -> int {
	context = s.ctx
	return len(browser.closed_items(s.app))
}

// The strip reads `want` (a tab loads its title when it is shown: a reopened one has it from what was saved).
@(private = "file")
wait_strip :: proc(s: ^e2e.Session, want: string, loc := #caller_location) {
	e2e.wait_until(s, want, proc(s: ^e2e.Session, want: string) -> bool { return strip(s) == want }, fmt.tprintf("the tabs to read %q, not %q", want, strip(s)), loc = loc)
}

// A tab back at its place, with its history, shown.
@(test)
a_closed_tab_comes_back_at_its_place_with_its_history :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {url = titled(dir, "One")})
	middle := add_tab(s, titled(dir, "Two"))
	e2e.navigate(s, titled(dir, "Three"))
	add_tab(s, titled(dir, "Four"))
	testing.expect_value(t, strip(s), "One Three Four")

	e2e.close_tab(s, middle)
	testing.expect_value(t, strip(s), "One Four")
	testing.expect_value(t, closed_count(s), 1)

	e2e.key(s, REOPEN_KEY)
	wait_strip(s, "One Three Four")
	testing.expect_value(t, closed_count(s), 0)
	e2e.wait_load(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), "Three")
	e2e.go_back(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), "Two")
}

// The start page and a tab that never went anywhere are nothing to reopen.
@(test)
a_tab_that_showed_nothing_is_not_kept :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = "about:blank"})
	blank := e2e.new_tab(s, "about:blank")
	e2e.wait_load(s)
	e2e.close_tab(s, blank)
	testing.expect_value(t, closed_count(s), 0)
}

// A tab of a group goes back in it.
@(test)
a_closed_tab_goes_back_in_its_group :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {url = titled(dir, "One")})
	e2e.run_command(s, "tab.group_new")
	group := e2e.targets(s).groups[0].id
	second := add_tab(s, titled(dir, "Two"))
	{
		context = s.ctx
		browser.tab_group_add(s.app, browser.current_tab(s.app), u64(group))
	}
	e2e.wait_frames(s)
	e2e.close_tab(s, second)
	e2e.key(s, REOPEN_KEY)
	wait_strip(s, "One Two")
	got := e2e.targets(s)
	testing.expect_value(t, len(got.groups), 1)
	for x in got.tabs { testing.expectf(t, x.group == group, "%s is in group %d, not %d", x.title, x.group, group) }
}

// A run that started on the start page: the tabs of the run before come back at one stroke, in its place.
@(test)
the_session_before_comes_back_after_a_restart :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {profile = profile, url = titled(dir, "One")})
	add_tab(s, titled(dir, "Two"))
	e2e.navigate(s, titled(dir, "Three"))

	s = e2e.restart(s, {profile = profile, no_address = true})
	testing.expect_value(t, len(e2e.targets(s).tabs), 1)
	testing.expect_value(t, closed_count(s), 1)
	e2e.key(s, REOPEN_KEY)
	wait_strip(s, "One Three")
	testing.expect_value(t, closed_count(s), 0)
	e2e.wait_load(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), "Three")
	e2e.go_back(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), "Two")
}

// A start on an address of the command line with the option on does not lose the session either.
@(test)
a_start_on_an_address_keeps_the_session_to_reopen :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	prefs := []string{"browser.session.restore=true"}
	s := e2e.start(t, {profile = profile, prefs = prefs, url = titled(dir, "One")})
	add_tab(s, titled(dir, "Two"))

	s = e2e.restart(s, {profile = profile, prefs = prefs, url = titled(dir, "Three")})
	testing.expect_value(t, strip(s), "Three")
	e2e.key(s, REOPEN_KEY)
	wait_strip(s, "Three One Two")
}

// What was closed in a run is still there in the next, behind the session.
@(test)
closed_tabs_outlive_a_restart :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {profile = profile, url = titled(dir, "One")})
	gone := add_tab(s, titled(dir, "Two"))
	e2e.navigate(s, titled(dir, "Three"))
	e2e.close_tab(s, gone)

	s = e2e.restart(s, {profile = profile, no_address = true})
	testing.expect_value(t, closed_count(s), 2)
	e2e.key(s, REOPEN_KEY)
	wait_strip(s, "One")
	e2e.key(s, REOPEN_KEY)
	wait_strip(s, "One Three")
	e2e.wait_load(s)
	e2e.go_back(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), "Two")

	// and what was reopened is not there a run later
	s = e2e.restart(s, {profile = profile, url = "about:blank"})
	testing.expect_value(t, closed_count(s), 1)
}

// A window closes with all its tabs: they come back together, in a window of their own.
@(test)
a_closed_window_comes_back_with_its_tabs :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {url = titled(dir, "One")})
	first := e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	second := wins[0].id != first ? wins[0].id : wins[1].id
	e2e.in_window(s, second)
	e2e.navigate(s, titled(dir, "Two"))
	add_tab(s, titled(dir, "Three"))
	e2e.close_window(s)
	e2e.in_window(s, first)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(e2e.windows(s)) == 1 }, "the window to close")
	testing.expect_value(t, closed_count(s), 1)

	e2e.key(s, REOPEN_KEY)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(e2e.windows(s)) == 2 }, "the window to come back")
	wait_strip(s, "One Two Three")
	testing.expect_value(t, closed_count(s), 0)
	got := e2e.targets(s)
	testing.expectf(t, len(got.tabs) == 3 && got.tabs[1].window == got.tabs[2].window && got.tabs[1].window != got.tabs[0].window, "its tabs are together: %v", got.tabs)
}

// Every window of the session comes back.
@(test)
a_session_of_two_windows_comes_back_whole :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {profile = profile, url = titled(dir, "One")})
	first := e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	e2e.in_window(s, wins[0].id != first ? wins[0].id : wins[1].id)
	e2e.navigate(s, titled(dir, "Two"))

	s = e2e.restart(s, {profile = profile, no_address = true})
	testing.expect_value(t, len(e2e.windows(s)), 1)
	e2e.key(s, REOPEN_KEY)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(e2e.windows(s)) == 2 }, "the second window to come back")
	got := e2e.targets(s)
	testing.expect_value(t, len(got.tabs), 2)
	testing.expectf(t, strings.contains(strip(s), "One") && strings.contains(strip(s), "Two"), "the tabs of both: %s", strip(s))
}

// The pinned tabs come back at start-up by themselves: the session does not bring them a second time.
@(test)
reopening_the_session_does_not_double_the_pinned_tabs :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {profile = profile, url = titled(dir, "One")})
	e2e.run_command(s, "tab.pin")
	add_tab(s, titled(dir, "Two"))

	s = e2e.restart(s, {profile = profile, url = "about:blank"})
	e2e.wait_frames(s)
	testing.expect_value(t, len(e2e.targets(s).tabs), 2)
	e2e.key(s, REOPEN_KEY)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return strings.contains(strip(s), "Two") }, "the session to come back")
	testing.expect_value(t, strings.count(strip(s), "One"), 1)
}

// The menu's command is the option: it stays from one run to the next, and the tabs come back by themselves. Off again, they wait for Ctrl+Shift+T.
@(test)
the_option_reopens_the_session_at_start_up :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {profile = profile, url = titled(dir, "One")})
	add_tab(s, titled(dir, "Two"))
	e2e.run_command(s, "browser.session_restore")
	testing.expect_value(t, e2e.pref_get(s, "browser.session.restore"), "true")

	s = e2e.restart(s, {profile = profile, no_address = true})
	wait_strip(s, "One Two")
	testing.expect_value(t, closed_count(s), 0)

	e2e.run_command(s, "browser.session_restore")
	s = e2e.restart(s, {profile = profile, no_address = true})
	testing.expect_value(t, len(e2e.targets(s).tabs), 1)
	testing.expect_value(t, closed_count(s), 1)
}

// Clearing the history clears what was closed in that time.
@(test)
clearing_the_history_forgets_what_was_closed :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {url = titled(dir, "One")})
	gone := add_tab(s, titled(dir, "Two"))
	e2e.close_tab(s, gone)
	testing.expect_value(t, closed_count(s), 1)
	{
		context = s.ctx
		browser.global_history_remove_range(s.app, min(i64), max(i64))
	}
	testing.expect_value(t, closed_count(s), 0)
}

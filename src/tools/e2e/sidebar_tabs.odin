package e2e_scenarios

// The tab sidebar's features that need a page or a profile: the sound of a tab, what is saved in the profile. (Its widths, pinned tabs and groups, with no browser around it: chrome_sidebar.odin.)

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SIDEBAR_SIZE :: [2]int{1100, 700}
@(private = "file") SOUND_FILE :: "examples/site/devtools/assets/tone_opus.webm"

// A page of its own per title (file: pages; a top-level data: address is refused).
@(private = "file")
page_titled :: proc(dir, title: string, body := "") -> string {
	return e2e.file_page(dir, fmt.tprintf("%s.html", title), fmt.tprintf("<!doctype html><meta charset=utf-8><title>%s</title><body style='font:20px sans-serif'>%s %s", title, title, body))
}

// "[Bravo] Alpha": the tabs in order, pinned ones in brackets.
@(private = "file")
order :: proc(s: ^e2e.Session) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x, i in e2e.targets(s).tabs {
		if i > 0 { strings.write_byte(&b, ' ') }
		fmt.sbprintf(&b, x.pinned ? "[%s]" : "%s", x.title)
	}
	return strings.to_string(b)
}

// The interface's animations have ended: what the tab bar draws is where a tab is.
@(private = "file")
settled :: proc(s: ^e2e.Session, loc := #caller_location) { e2e.wait_chrome_still(s, loc = loc) }

@(private = "file")
select_tab :: proc(s: ^e2e.Session, title: string, loc := #caller_location) {
	e2e.activate_tab(s, e2e.tab_titled(s, title, loc).id, loc)
	e2e.wait_frames(s, loc = loc)
}

// The window with its tabs on the left, five tabs: Alpha to Echo.
@(private = "file")
with_five_tabs :: proc(t: ^testing.T, dir: string, loc := #caller_location) -> ^e2e.Session {
	s := e2e.start(t, {size = SIDEBAR_SIZE, prefs = {"browser.ui.animations=on"}, url = page_titled(dir, "Alpha")}, loc)
	// (set as the user does: one given on the command line would stay above what the test sets later)
	e2e.pref_set(s, "browser.tabs.position", "left")
	for n in ([]string{"Bravo", "Charlie", "Delta", "Echo"}) {
		id := e2e.new_tab(s, page_titled(dir, n))
		s.tab = id
		e2e.wait_load(s)
		s.tab = 0
	}
	settled(s)
	return s
}

@(test)
sidebar_sound :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := with_five_tabs(t, dir)
	// (a file: page reads only files under its own folder)
	tone, err := os.read_entire_file(fmt.tprintf("%s/%s", e2e.repo_root(), SOUND_FILE), context.temp_allocator)
	testing.expect(t, err == nil, "the sound file is there")
	_ = os.write_entire_file(fmt.tprintf("%s/tone.webm", dir), tone)
	e2e.pref_set(s, "media.autoplay.policy", "allow-all")
	e2e.new_tab(s, page_titled(dir, "Sound", "<audio src='tone.webm' autoplay loop></audio>"))
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { for x in e2e.targets(s).tabs { if x.title == "Sound" && x.audible { return true } }; return false }, "the tab playing a tone to be audible")
	sound := e2e.tab_titled(s, "Sound")
	testing.expect(t, sound.audible && sound.playing, "a tab that plays sound shows its speaker (audible)")
	testing.expect(t, !e2e.tab_titled(s, "Alpha").audible, "the others do not")
	e2e.shot(s, "son, haut-parleur.png")
	e2e.run_command(s, "tab.mute")
	sound = e2e.tab_titled(s, "Sound")
	testing.expect(t, sound.muted && !sound.audible && sound.playing, "muted: the speaker is crossed out, the page still plays")
	testing.expect_value(t, e2e.eval(s, `String(document.querySelector("audio").muted)`), "false")   // the page is not told (its element is not muted)
	e2e.shot(s, "son, onglet muet.png")
	e2e.pref_set(s, "browser.tabs.sidebar_collapsed", "true")
	settled(s)
	e2e.shot(s, "son, barre reduite.png")
	e2e.pref_set(s, "browser.tabs.sidebar_collapsed", "false")
	settled(s)
	e2e.run_command(s, "tab.mute")
	testing.expect(t, !e2e.tab_titled(s, "Sound").muted, "unmuted")
	e2e.pref_set(s, "browser.tabs.audio_hold_ms", "0")
	e2e.eval(s, `document.querySelector("audio").pause(); 1`)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { x := e2e.tab_titled(s, "Sound"); return !x.audible && !x.playing }, "paused, the speaker goes")
	e2e.run_command(s, "tab.close")
}

// Saved in the profile: the pinned tabs come back without the session, the groups with it.
@(test)
sidebar_persist :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	prefs := []string{"browser.tabs.position=left"}
	s := e2e.start(t, {size = SIDEBAR_SIZE, profile = profile, prefs = prefs, url = page_titled(dir, "One")})
	s.tab = e2e.new_tab(s, page_titled(dir, "Two"))
	e2e.wait_load(s)
	s.tab = 0
	select_tab(s, "One")
	e2e.run_command(s, "tab.pin")

	s = e2e.restart(s, {size = SIDEBAR_SIZE, profile = profile, prefs = prefs, url = page_titled(dir, "Three")})
	o := order(s)
	testing.expectf(t, strings.has_prefix(o, "[One] "), "the pinned tab came back without the session: %s", o)
	e2e.pref_set(s, "browser.session.restore", "true")
	for x in e2e.targets(s).tabs {
		if !x.pinned { e2e.activate_tab(s, x.id); e2e.wait_frames(s); break }
	}
	e2e.run_command(s, "tab.group_new")
	e2e.run_command(s, "tab.group_color.purple")

	// (no address: a session is restored only when none is given)
	s = e2e.restart(s, {size = SIDEBAR_SIZE, profile = profile, prefs = {"browser.tabs.position=left", "browser.session.restore=true"}, no_address = true})
	e2e.wait_frames(s)
	got := e2e.targets(s)
	testing.expectf(t, len(got.groups) == 1 && got.groups[0].color == "purple", "the group came back with the session: %s, %v", order(s), got.groups)
	in_group := 0
	if len(got.groups) == 1 { for x in got.tabs { if x.group == got.groups[0].id { in_group += 1 } } }
	testing.expect_value(t, in_group, 1)
	testing.expect(t, len(got.tabs) > 0 && got.tabs[0].pinned, "and the pinned tab with it")
}

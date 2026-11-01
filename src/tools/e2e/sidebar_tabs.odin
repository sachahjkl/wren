package e2e_scenarios

// The tab sidebar's features (synthetic input, nothing timed): the titles fade in and out when the sidebar opens or closes, its width going
// through the widths between; pinned tabs, tab groups, the sound of a tab; what is saved in the profile.

import "core:fmt"
import "core:math"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SIDEBAR_SIZE :: [2]int{1100, 700}
@(private = "file") SLOW_ANIMATION_MS :: "2000"   // slow enough to see the frames between, frames that come as fast as the machine makes them: the most the preference takes
@(private = "file") USUAL_ANIMATION_MS :: "180"
@(private = "file") WIDTH_SLACK :: 0.5           // of a page's innerWidth, between two looks at one width
@(private = "file") LEAST_WIDTHS_BETWEEN :: 2    // a sidebar that does not jump goes through at least these
@(private = "file") TAB_DRAG_STEPS :: 12
@(private = "file") SETTLED_FRAMES :: 4
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
settled :: proc(s: ^e2e.Session, loc := #caller_location) {
	// (several frames in a row: a frame in which a change has not begun to move yet is not the end of it)
	quiet := 0
	e2e.wait_until(s, &quiet, proc(s: ^e2e.Session, quiet: ^int) -> bool {
		quiet^ = e2e.stats(s).chrome_animating ? 0 : quiet^ + 1
		return quiet^ >= SETTLED_FRAMES
	}, "the interface's animations to end", loc = loc)
}

// A tab is in its place in the tab bar: it has a rectangle in the last frame.
@(private = "file")
tab_rect :: proc(s: ^e2e.Session, title: string, loc := #caller_location) -> e2e.Rect {
	settled(s, loc)
	x := e2e.tab_titled(s, title, loc)
	if !x.has_rect { e2e.wait_frames(s, loc = loc); x = e2e.tab_titled(s, title, loc) }
	return x.rect
}

@(private = "file")
select_tab :: proc(s: ^e2e.Session, title: string, loc := #caller_location) {
	e2e.activate_tab(s, e2e.tab_titled(s, title, loc).id, loc)
	e2e.wait_frames(s, loc = loc)
}

@(private = "file")
drag_tab :: proc(s: ^e2e.Session, from, to: e2e.Rect, loc := #caller_location) {
	e2e.drag(s, e2e.center(from), e2e.center(to), {steps = TAB_DRAG_STEPS, space = .Window}, loc = loc)
	settled(s, loc)
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

// The page's width once the sidebar's animation has ended and the page has been laid out at its area's width (the interface does not wait for that).
@(private = "file")
width_at_rest :: proc(s: ^e2e.Session) -> f64 {
	settled(s)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return math.abs(e2e.eval_f64(s, "innerWidth") - e2e.window_bounds(s).page_rect.w) <= WIDTH_SLACK }, "the page to be laid out at its area's width")
	return e2e.eval_f64(s, "innerWidth")
}

@(test)
sidebar_fade :: proc(t: ^testing.T) {
	s := with_five_tabs(t, e2e.temp_folder(t))
	e2e.pref_set(s, "browser.tabs.sidebar_animation_ms", SLOW_ANIMATION_MS)
	w0 := e2e.eval_f64(s, "innerWidth")
	// (the page notes every width it is given: a frame of each)
	e2e.eval(s, `window.__w = []; addEventListener("resize", () => __w.push(innerWidth)); 1`)
	e2e.run_command(s, "view.tabs_sidebar_collapse")
	w1 := width_at_rest(s)
	raw := e2e.eval(s, "__w.join(' ')")
	seen := make([dynamic]f64, context.temp_allocator)
	for word in strings.fields(raw, context.temp_allocator) {
		v, _ := json.parse_string(word, allocator = context.temp_allocator)
		#partial switch x in v {
		case json.Integer: append(&seen, f64(x))
		case json.Float:   append(&seen, f64(x))
		}
	}
	testing.expectf(t, w1 > w0, "closing the sidebar gave the page its room (%v -> %v)", w0, w1)
	between := make(map[f64]bool, 8, context.temp_allocator)
	for w in seen { if w > w0 + 1 && w < w1 - 1 { between[w] = true } }
	testing.expectf(t, len(between) >= LEAST_WIDTHS_BETWEEN, "the width goes through widths between (no jump): %s", raw)
	for k in 1 ..< max(len(seen), 1) { testing.expectf(t, seen[k] >= seen[k - 1] - WIDTH_SLACK, "the page only widens while the sidebar closes: %s", raw) }
	e2e.run_command(s, "view.tabs_sidebar_collapse")
	w2 := width_at_rest(s)
	testing.expectf(t, math.abs(w2 - w0) <= WIDTH_SLACK, "opening it again gives back the width it had: %v, not %v", w2, w0)
	e2e.pref_set(s, "browser.tabs.sidebar_animation_ms", "0")
	e2e.run_command(s, "view.tabs_sidebar_collapse")
	w3 := e2e.window_bounds(s).page_rect.w   // (two frames later, the page's area: the page is laid out for it next)
	testing.expectf(t, math.abs(w3 - w1) <= WIDTH_SLACK, "with browser.tabs.sidebar_animation_ms 0 it closes at once: %v two frames later, not %v", w3, w1)
	e2e.run_command(s, "view.tabs_sidebar_collapse")
	e2e.pref_set(s, "browser.tabs.sidebar_animation_ms", USUAL_ANIMATION_MS)
}

@(test)
sidebar_pins :: proc(t: ^testing.T) {
	s := with_five_tabs(t, e2e.temp_folder(t))
	select_tab(s, "Bravo")
	e2e.run_command(s, "tab.pin")
	select_tab(s, "Delta")
	e2e.run_command(s, "tab.pin")
	testing.expect_value(t, order(s), "[Bravo] [Delta] Alpha Charlie Echo")   // pinned tabs go first, in the order they were pinned
	e2e.shot(s, "onglets epingles.png")
	drag_tab(s, tab_rect(s, "Delta"), tab_rect(s, "Bravo"))
	testing.expect_value(t, order(s), "[Delta] [Bravo] Alpha Charlie Echo")   // a pinned tab dragged onto another takes its place
	drag_tab(s, tab_rect(s, "Echo"), tab_rect(s, "Bravo"))
	testing.expect_value(t, order(s), "[Delta] [Echo] [Bravo] Alpha Charlie")   // a tab of the list dragged up to the pinned tabs is pinned
	drag_tab(s, tab_rect(s, "Echo"), tab_rect(s, "Charlie"))
	o := order(s)
	testing.expectf(t, strings.has_prefix(o, "[Delta] [Bravo]") && strings.contains(o, " Echo") && !strings.contains(o, "[Echo]"), "a pinned tab dragged down into the list is no longer pinned: %s", o)
	select_tab(s, "Bravo")
	e2e.run_command(s, "tab.pin")
	o = order(s)
	testing.expectf(t, strings.has_prefix(o, "[Delta] Bravo "), "unpinned, it is the first of the others: %s", o)
	e2e.pref_set(s, "browser.tabs.sidebar_collapsed", "true")
	settled(s)
	e2e.shot(s, "epingles, barre reduite.png")
	e2e.pref_set(s, "browser.tabs.sidebar_collapsed", "false")
	settled(s)
	e2e.pref_set(s, "browser.tabs.position", "top")
	settled(s)
	e2e.shot(s, "epingles, onglets en haut.png")
	e2e.pref_set(s, "browser.tabs.position", "left")
	settled(s)
}

@(test)
sidebar_groups :: proc(t: ^testing.T) {
	s := with_five_tabs(t, e2e.temp_folder(t))
	select_tab(s, "Alpha")
	e2e.run_command(s, "tab.group_new")
	groups := e2e.targets(s).groups
	testing.expect_value(t, len(groups), 1)   // a new group
	group := groups[0].id
	testing.expect_value(t, e2e.tab_titled(s, "Alpha").group, group)   // the tab is in it
	drag_tab(s, tab_rect(s, "Charlie"), tab_rect(s, "Alpha"))
	testing.expect_value(t, e2e.tab_titled(s, "Charlie").group, group)   // a tab dragged onto a tab of the group joins it
	select_tab(s, "Alpha")
	e2e.run_command(s, "tab.group_rename")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).group_name_focused }, "the group's name to have the keyboard")
	e2e.type_text(s, "Work")
	e2e.key(s, "Enter")
	testing.expect_value(t, e2e.targets(s).groups[0].name, "Work")   // renamed in its header
	e2e.run_command(s, "tab.group_color.green")
	testing.expect_value(t, e2e.targets(s).groups[0].color, "green")   // its colour
	e2e.shot(s, "groupe Work.png")
	runs, prev := 0, -1
	for x in e2e.targets(s).tabs {
		if x.group != prev && x.group != 0 { runs += 1 }
		prev = x.group
	}
	testing.expect_value(t, runs, 1)   // the group's tabs are next to each other
	settled(s)
	e2e.click_at(s, e2e.center(e2e.targets(s).groups[0].rect), .Window)
	settled(s)
	testing.expect(t, e2e.targets(s).groups[0].collapsed, "a click on the header collapses the group")
	for x in e2e.targets(s).tabs { if x.active { testing.expectf(t, x.group != group, "the current tab left the collapsed group: %s", x.title) } }
	testing.expect(t, !e2e.tab_titled(s, "Alpha").has_rect, "its tabs are not drawn")
	// (two clicks in the system's double-click time are a double click: the header's rename)
	e2e.forget_clicks(s)
	e2e.shot(s, "groupe Work replie.png")
	e2e.click_at(s, e2e.center(e2e.targets(s).groups[0].rect), .Window)
	settled(s)
	testing.expect(t, !e2e.targets(s).groups[0].collapsed, "a second click expands it")
	below: e2e.Rect
	for x in e2e.targets(s).tabs { if x.group == 0 && !x.pinned { below = x.rect } }
	drag_tab(s, tab_rect(s, "Charlie"), below)
	testing.expect_value(t, e2e.tab_titled(s, "Charlie").group, 0)   // dragged onto a tab outside the group, it leaves the group
	select_tab(s, "Alpha")
	e2e.run_command(s, "tab.group_leave")
	testing.expect_value(t, len(e2e.targets(s).groups), 0)   // its last tab gone, the group goes
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

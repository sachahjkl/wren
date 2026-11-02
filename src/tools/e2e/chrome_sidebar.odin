package e2e_scenarios

// The tab sidebar with no browser around it (chrome_world.odin): the titles' room when it opens and closes, its width going through the widths between; pinned tabs and tab groups, by
// the interface's own commands and by the pointer. (A tab's sound needs a page, what comes back in the next start a profile: sidebar_tabs.odin.)

import "core:fmt"
import "core:strings"
import "core:testing"
import session "toolkit:testkit/session"
import "wb:remote/api"

@(private = "file") TITLES := []string{"Alpha", "Bravo", "Charlie", "Delta", "Echo"}
@(private = "file") LEFT :: "browser.tabs.position=left"
@(private = "file") SLOW_ANIMATION_MS :: "2000"
@(private = "file") ANIMATION_FRAMES :: 180      // a frame of 16 ms: more than it takes, whatever is left of its ease
@(private = "file") LEAST_WIDTHS_BETWEEN :: 2    // a sidebar that does not jump goes through at least these
@(private = "file") WIDTH_SLACK :: 0.5
@(private = "file") SIDEBAR_BOX :: "sidebar"
@(private = "file") TOGGLE :: "view.tabs_sidebar_collapse"

// "[Bravo] Alpha": the tabs in order, pinned ones in brackets.
@(private = "file")
order :: proc(w: ^Chrome_World) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x, i in w.wnd.tabs {
		if i > 0 { strings.write_byte(&b, ' ') }
		fmt.sbprintf(&b, x.pinned ? "[%s]" : "%s", x.title)
	}
	return strings.to_string(b)
}

@(private = "file")
middle :: proc(r: api.Rect) -> [2]f32 { m := api.center(r); return {f32(m.x), f32(m.y)} }

@(private = "file")
drag_tab :: proc(w: ^Chrome_World, from, to: string, loc := #caller_location) {
	chrome_still(w, loc)
	session.drag(w.s, middle(chrome_tab(w, from, loc).rect), middle(chrome_tab(w, to, loc).rect), TAB_DRAG_STEPS)
	chrome_still(w, loc)
}
@(private = "file") TAB_DRAG_STEPS :: 12

@(private = "file")
sidebar_width :: proc(w: ^Chrome_World, loc := #caller_location) -> f32 {
	r := session.get(w.s, SIDEBAR_BOX, loc).rect
	return r.max.x - r.min.x
}

@(test)
chrome_sidebar_opens_and_closes_through_the_widths_between :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = TITLES, prefs = {LEFT, "browser.ui.animations=on"}})
	chrome_still(w)
	opened := sidebar_width(w)
	chrome_pref(w, "browser.tabs.sidebar_animation_ms", SLOW_ANIMATION_MS)
	chrome_command(w, TOGGLE)
	between := make(map[f32]bool, 8, context.temp_allocator)
	last := opened
	for _ in 0 ..< ANIMATION_FRAMES {
		session.frame(w.s)
		now := sidebar_width(w)
		testing.expectf(t, now <= last + WIDTH_SLACK, "it only narrows while it closes: %v after %v", now, last)
		between[now] = true
		last = now
	}
	chrome_still(w)
	closed := sidebar_width(w)
	testing.expectf(t, closed < opened, "closing it gives the page its room (%v -> %v)", opened, closed)
	delete_key(&between, closed)
	delete_key(&between, opened)
	testing.expectf(t, len(between) >= LEAST_WIDTHS_BETWEEN, "the width goes through widths between (no jump): %v", between)

	chrome_command(w, TOGGLE)
	chrome_still(w)
	testing.expect_value(t, sidebar_width(w), opened)   // opening it gives back the width it had

	chrome_pref(w, "browser.tabs.sidebar_animation_ms", "0")
	chrome_command(w, TOGGLE)
	testing.expect_value(t, sidebar_width(w), closed)   // with no animation it closes at once
}

@(test)
chrome_sidebar_pinned_tabs :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = TITLES, prefs = {LEFT}})
	chrome_still(w)
	chrome_select(w, "Bravo")
	chrome_command(w, "tab.pin")
	chrome_select(w, "Delta")
	chrome_command(w, "tab.pin")
	testing.expect_value(t, order(w), "[Bravo] [Delta] Alpha Charlie Echo")   // pinned tabs go first, in the order they were pinned
	drag_tab(w, "Delta", "Bravo")
	testing.expect_value(t, order(w), "[Delta] [Bravo] Alpha Charlie Echo")   // a pinned tab dragged onto another takes its place
	drag_tab(w, "Echo", "Bravo")
	testing.expect_value(t, order(w), "[Delta] [Echo] [Bravo] Alpha Charlie")   // a tab of the list dragged up to the pinned tabs is pinned
	drag_tab(w, "Echo", "Charlie")
	o := order(w)
	testing.expectf(t, strings.has_prefix(o, "[Delta] [Bravo]") && strings.contains(o, " Echo") && !strings.contains(o, "[Echo]"), "a pinned tab dragged down into the list is no longer pinned: %s", o)
	chrome_select(w, "Bravo")
	chrome_command(w, "tab.pin")
	o = order(w)
	testing.expectf(t, strings.has_prefix(o, "[Delta] Bravo "), "unpinned, it is the first of the others: %s", o)
}

@(test)
chrome_sidebar_tab_groups :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = TITLES, prefs = {LEFT}})
	chrome_still(w)
	chrome_select(w, "Alpha")
	chrome_command(w, "tab.group_new")
	testing.expect_value(t, len(w.wnd.groups), 1)   // a new group
	group := w.wnd.groups[0].id
	testing.expect_value(t, chrome_tab(w, "Alpha").group, int(group))   // the tab is in it
	drag_tab(w, "Charlie", "Alpha")
	testing.expect_value(t, chrome_tab(w, "Charlie").group, int(group))   // a tab dragged onto a tab of the group joins it
	chrome_select(w, "Alpha")
	chrome_command(w, "tab.group_rename")
	session.frames(w.s, 2)
	session.type_text(w.s, "Work")
	session.key(w.s, .Return)
	testing.expect_value(t, w.wnd.groups[0].name, "Work")   // renamed in its header
	chrome_command(w, "tab.group_color.green")
	runs, prev := 0, u64(0)
	for x in w.wnd.tabs {
		if x.group != prev && x.group != 0 { runs += 1 }
		prev = x.group
	}
	testing.expect_value(t, runs, 1)   // the group's tabs are next to each other

	header :: proc(w: ^Chrome_World) -> [2]f32 { return middle(chrome_groups(w)[0].rect) }
	chrome_still(w)
	session.click_at(w.s, header(w))
	chrome_still(w)
	testing.expect(t, w.wnd.groups[0].collapsed, "a click on the header collapses the group")
	cur := w.wnd.tabs[w.wnd.current]
	testing.expectf(t, cur.group != group, "the current tab left the collapsed group: %s", cur.title)
	testing.expect(t, !chrome_tab(w, "Alpha").has_rect, "its tabs are not drawn")
	session.advance(w.s, DOUBLE_CLICK_APART_MS)   // (two clicks in the double-click time are a double click: the header's rename)
	session.click_at(w.s, header(w))
	chrome_still(w)
	testing.expect(t, !w.wnd.groups[0].collapsed, "a second click expands it")
	drag_tab(w, "Charlie", "Echo")
	testing.expect_value(t, chrome_tab(w, "Charlie").group, 0)   // dragged onto a tab outside the group, it leaves the group
	chrome_select(w, "Alpha")
	chrome_command(w, "tab.group_leave")
	testing.expect_value(t, len(w.wnd.groups), 0)   // its last tab gone, the group goes
}
@(private = "file") DOUBLE_CLICK_APART_MS :: 1000

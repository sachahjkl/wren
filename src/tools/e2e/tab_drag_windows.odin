package e2e_scenarios

// A tab dragged from one window onto another's tabs. The pointer is injected into the window the press began in, which keeps the drag as a captured
// mouse would. The window it is carried over shows where it would go (the insertion mark) exactly where the release puts it, among pinned tabs and
// groups: in a row of tabs, between two tabs of a group (it joins the group); in the sidebar's list, on the lower half of a group's header (the start
// of the group, in it). Each time: the mark's place and what it says (index, group), then the release and the tabs' order.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") DRAG_SIZE :: [2]int{1100, 600}
@(private = "file") SECOND_WINDOW_AT :: [2]int{DRAG_SIZE.x + 100, 0}   // beside the first: a pointer over one is not over the other (headless windows have no stacking order)
@(private = "file") DRAG_MOVES :: 10
@(private = "file") FAR_BELOW_THE_ROW :: 300       // px: the tab leaves its row
@(private = "file") FAR_BESIDE_THE_LIST :: 500     // px: the tab leaves the sidebar
@(private = "file") INTO_THE_TAB :: 6              // px from a tab's left edge: the gap before it
@(private = "file") ONTO_THE_TAB :: 4
@(private = "file") LOWER_HALF :: 0.75             // of a group's header
@(private = "file") MARK_WITHIN :: 1.5             // px
@(private = "file") SETTLE :: 4

@(private = "file")
titled_page :: proc(dir, title: string) -> string {
	return e2e.file_page(dir, fmt.tprintf("%s.html", title), fmt.tprintf("<!doctype html><meta charset=utf-8><title>%s</title><body style='font:20px sans-serif'>%s", title, title))
}

@(private = "file")
add_tabs :: proc(s: ^e2e.Session, dir: string, titles: []string) {
	for title in titles {
		s.tab = e2e.new_tab(s, titled_page(dir, title))
		e2e.wait_load(s)
		s.tab = 0
	}
}

// "[Pin] Two{g} One{g} Free": a window's tabs in order, pinned ones in brackets, those of a group marked.
@(private = "file")
order :: proc(s: ^e2e.Session, window: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x in e2e.targets(s).tabs {
		if x.window != window { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		fmt.sbprintf(&b, x.pinned ? "[%s%s]" : "%s%s", x.title, x.group != 0 ? "{g}" : "")
	}
	return strings.to_string(b)
}

@(private = "file")
window_of :: proc(s: ^e2e.Session, id: int, loc := #caller_location) -> e2e.Window {
	w, ok := e2e.window_with_id(e2e.windows(s, loc), id)
	if !ok { e2e.stop_test(s.t, fmt.tprintf("no window %d", id), loc) }
	return w
}

// A tab in its place in its window's last frame: the interface still, its rectangle there.
@(private = "file")
rect_of :: proc(s: ^e2e.Session, window: int, title: string, loc := #caller_location) -> e2e.Rect {
	e2e.in_window(s, window)
	e2e.wait_chrome_still(s, loc = loc)
	x := e2e.tab_titled(s, title, loc)
	if !x.has_rect { e2e.stop_test(s.t, fmt.tprintf("the tab %s has no place in its window", title), loc) }
	return x.rect
}

// A point of window `to` (its client pixels) in the client pixels of window `from`, where the drag's pointer is injected.
@(private = "file")
across :: proc(s: ^e2e.Session, from, to: int, at: e2e.Point) -> e2e.Point {
	f, d := window_of(s, from), window_of(s, to)
	return {f64(d.client_left) + at.x - f64(f.client_left), f64(d.client_top) + at.y - f64(f.client_top)}
}

// The drag of `from` through `away` to `over` with the button still down, the window under it having seen it.
@(private = "file")
carry :: proc(s: ^e2e.Session, a, b: int, from, away, over: e2e.Point) -> e2e.Window {
	{
		e2e.in_window(s, a)
		e2e.drag(s, from, over, {via = {away}, steps = DRAG_MOVES, space = .Window, hold = true})
	}
	{
		e2e.in_window(s, b)
		e2e.wait_until(s, b, proc(s: ^e2e.Session, b: int) -> bool { return window_of(s, b).dropping }, "the mark in the window under the pointer")
	}
	return window_of(s, b)
}

// The release at the place held; the carried window goes.
@(private = "file")
drop_there :: proc(s: ^e2e.Session, a, b: int, over: e2e.Point) {
	{
		e2e.in_window(s, a)
		e2e.drag(s, over, over, {steps = 1, space = .Window, resume = true})
	}
	e2e.in_window(s, b)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(e2e.windows(s)) == 2 }, "the carried window to close")
	e2e.wait_chrome_still(s)
}

@(test)
tab_drag_between_windows :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {size = DRAG_SIZE, url = titled_page(dir, "Alpha")})
	e2e.pref_set(s, "browser.ui.animations", "off")
	a := e2e.windows(s)[0].id
	add_tabs(s, dir, {"Carried", "Charlie"})

	// window B: a pinned tab, a group of two, a tab in none
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	b := wins[0].id != a ? wins[0].id : wins[1].id
	g: int
	{
		e2e.in_window(s, b)
		e2e.set_window(s, {size = DRAG_SIZE, pos = SECOND_WINDOW_AT})
		e2e.navigate(s, titled_page(dir, "Pin"))
		add_tabs(s, dir, {"GroupOne", "GroupTwo", "Free"})
		e2e.activate_tab(s, e2e.tab_titled(s, "Pin").id)
		e2e.run_command(s, "tab.pin")
		e2e.activate_tab(s, e2e.tab_titled(s, "GroupOne").id)
		e2e.run_command(s, "tab.group_new")
	}
	{
		// GroupTwo dragged onto GroupOne joins its group (the row's own reorder)
		r1, r2 := rect_of(s, b, "GroupOne"), rect_of(s, b, "GroupTwo")
		e2e.in_window(s, b)
		e2e.drag(s, e2e.center(r2), {r1.x + ONTO_THE_TAB, r1.y + r1.h / 2}, {steps = DRAG_MOVES, space = .Window})
		e2e.wait_chrome_still(s)
		g = e2e.tab_titled(s, "GroupOne").group
		testing.expect(t, g != 0, "window B has a group")
		testing.expect_value(t, order(s, b), "[Pin] GroupTwo{g} GroupOne{g} Free")   // a pinned tab, a group of two, a tab in none
	}

	// 1. a row of tabs: Carried over the gap between the group's two tabs
	e2e.activate_tab(s, e2e.tab_titled(s, "Alpha").id)
	rc, rg := rect_of(s, a, "Carried"), rect_of(s, b, "GroupOne")
	from := e2e.center(rc)
	over := across(s, a, b, {rg.x + INTO_THE_TAB, rg.y + rg.h / 2})
	mark := carry(s, a, b, from, {from.x, rc.y + FAR_BELOW_THE_ROW}, over)
	testing.expectf(t, mark.drop_index == 2 && mark.drop_group == g && math.abs(mark.drop_mark - rg.x) <= MARK_WITHIN, "over B's row: the mark is between the group's two tabs, and says it joins the group: index %d, group %d (%d), mark %v at %v", mark.drop_index, mark.drop_group, g, mark.drop_mark, rg.x)
	testing.expect_value(t, len(e2e.windows(s)), 3)   // the tab left its row for a window of its own, which follows the pointer
	{ e2e.in_window(s, b); e2e.shot(s, "07 row, mark between two tabs of the group.png") }
	drop_there(s, a, b, over)
	testing.expect_value(t, order(s, b), "[Pin] GroupTwo{g} Carried{g} GroupOne{g} Free")   // released there: where the mark was
	testing.expect_value(t, e2e.tab_titled(s, "Carried").group, g)                          // in the group
	testing.expect(t, !window_of(s, b).dropping, "the mark is gone")
	{ e2e.in_window(s, b); e2e.shot(s, "10 row after the drop.png") }

	// 2. the sidebar's list: Charlie over the lower half of the group's header
	e2e.pref_set(s, "browser.tabs.position", "left")
	{ e2e.in_window(s, a); e2e.wait_frames(s, SETTLE) }
	{ e2e.in_window(s, b); e2e.wait_frames(s, SETTLE) }
	// (the page, to be found as it was after the drop: nothing reloads it)
	s.tab = e2e.tab_titled(s, "Charlie").id
	e2e.eval(s, "window.kept = 'as it was'; 'ok'")
	s.tab = 0
	rc = rect_of(s, a, "Charlie")
	header: e2e.Tab_Group
	{
		e2e.in_window(s, b)
		e2e.wait_until(s, g, proc(s: ^e2e.Session, g: int) -> bool {
			for x in e2e.targets(s).groups { if x.id == g && x.has_rect { return true } }
			return false
		}, "the group's header in the list")
		for x in e2e.targets(s).groups { if x.id == g { header = x } }
	}
	hr := header.rect
	from = e2e.center(rc)
	over = across(s, a, b, {hr.x + hr.w / 2, hr.y + hr.h * LOWER_HALF})
	mark = carry(s, a, b, from, {from.x + FAR_BESIDE_THE_LIST, from.y}, over)
	testing.expectf(t, mark.drop_index == 1 && mark.drop_group == g && math.abs(mark.drop_mark - (hr.y + hr.h)) <= MARK_WITHIN, "over B's list, on the lower half of the group's header: the mark is under the header, the start of the group: index %d, group %d (%d), mark %v, header %v", mark.drop_index, mark.drop_group, g, mark.drop_mark, hr)
	{ e2e.in_window(s, b); e2e.shot(s, "08 sidebar, mark under the group's header.png") }
	drop_there(s, a, b, over)
	testing.expect_value(t, order(s, b), "[Pin] Charlie{g} GroupTwo{g} Carried{g} GroupOne{g} Free")   // released there: the first tab of the group
	{
		e2e.in_window(s, b)
		testing.expect_value(t, e2e.eval(s, `document.title + "|" + document.body.textContent + "|" + window.kept`), "Charlie|Charlie|as it was")   // the tab dropped is the current one of B, its page as it was
		e2e.shot(s, "09 sidebar after the drop.png")
	}
	testing.expect_value(t, e2e.stats(s).frame_gate.violations, 0)   // no violation of the frame gate
}

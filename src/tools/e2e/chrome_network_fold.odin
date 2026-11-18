package e2e_scenarios

// The Network tab's request detail beside the table, the toolkit's foldable side panel (src/md/features/network-detail-fold.md),
// with no browser around it: it folds to its rail when the developer tools get too narrow for the table's least, and opens when
// they are wide again; a fold or an opening by hand holds until the next crossing; the fold button stays at its pixel; the fold
// is a preference, so a restart keeps it.

import "core:fmt"
import "core:strings"
import "core:testing"
import config "toolkit:config"
import session "toolkit:testkit/session"
import "wb:browser"

@(private = "file") FOLD_WINDOW :: [2]int{1700, 800}
// The table keeps 30 % of the split: with the Name column at its 260 px, the detail folds under about 900 px of panel.
@(private = "file") FOLD_SPLIT :: "browser.devtools.network.split=0.3"
@(private = "file") WIDE :: 1100
@(private = "file") WIDER :: 1050       // wide still: no crossing
@(private = "file") NARROW :: 700       // beside the table still (640 px or more), but the table would get 210 px
@(private = "file") NARROWER :: 720
@(private = "file") WIDTH_WITHIN :: 4   // the handle's grab, a rounding
@(private = "file") RAIL_MOST :: 60     // the rail: the fold button and its gaps

@(private = "file")
fold_world :: proc(t: ^testing.T, prefs: []string = nil, loc := #caller_location) -> ^Chrome_World {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "browser.devtools.visible=true", "browser.devtools.tab=network", FOLD_SPLIT)
	append(&all, ..prefs)
	w := chrome_start(t, {size = FOLD_WINDOW, prefs = all[:]}, loc)
	why := browser.control_devtools(w.app, "network", "right")
	testing.expectf(t, why == "", "docked at the right: %s", why, loc = loc)
	session.frames(w.s, 2)
	chrome_still(w, loc)
	return w
}

// The docked panel at this width, by its zone's handle.
@(private = "file")
fold_panel_width :: proc(w: ^Chrome_World, width: int, loc := #caller_location) {
	panel := proc(w: ^Chrome_World) -> f32 { r := w.wnd.own.devtools.rect; return r.max.x - r.min.x }
	handle := session.get(w.s, "view_handle_Right", loc = loc)
	from := (handle.rect.min + handle.rect.max) * 0.5
	to := from
	to.x -= f32(width) - panel(w)   // (the handle is on the page's side: towards it, the panel grows)
	session.drag(w.s, from, to)
	chrome_still(w, loc)
	testing.expectf(w.s.t, abs(panel(w) - f32(width)) <= WIDTH_WITHIN, "a panel of %d: it has %v", width, panel(w), loc = loc)
}

// A request in the tab's log, selected: its detail shows (a log as net_observe makes it).
@(private = "file")
fold_select_request :: proc(w: ^Chrome_World, loc := #caller_location) {
	tab := browser.current_tab(w.app)
	tab.net.next_seq += 1
	append(&tab.net.entries, browser.Net_Entry{id = 1, seq = tab.net.next_seq, method = strings.clone("GET"), url = strings.clone("https://blank.test/app.js"),
		type = .JS, status = 200, status_text = strings.clone("OK"), ms = 12})
	tab.net.version += 1
	v := &browser.dev().net
	v.has_sel, v.sel_id = true, 1
	browser.request_frames(w.app, 2)
	session.frames(w.s, 2)
	chrome_still(w, loc)
}

@(private = "file")
fold_pref :: proc(w: ^Chrome_World) -> string { return config.string_of(&w.app.prefs, browser.NET_DETAIL_FOLD_PREF) }

@(private = "file")
detail_width :: proc(w: ^Chrome_World, loc := #caller_location) -> f32 {
	b := session.get(w.s, "dt_net_detail_box", loc = loc)
	return b.rect.max.x - b.rect.min.x
}

@(private = "file")
expect_folded :: proc(w: ^Chrome_World, folded: bool, pref: string, why: string, loc := #caller_location) {
	dw := detail_width(w, loc)
	if folded {
		testing.expectf(w.s.t, dw <= RAIL_MOST, "%s: the detail is its rail, not %v px wide", why, dw, loc = loc)
	} else {
		testing.expectf(w.s.t, dw > RAIL_MOST * 4, "%s: the detail is open, not %v px wide", why, dw, loc = loc)
	}
	testing.expectf(w.s.t, fold_pref(w) == pref, "%s: the fold saved is %q, not %q", why, fold_pref(w), pref, loc = loc)
}

@(private = "file")
fold_button_at :: proc(w: ^Chrome_World, loc := #caller_location) -> [2]f32 {
	b := session.get(w.s, "dt_net_fold", loc = loc)
	return (b.rect.min + b.rect.max) * 0.5
}

@(private = "file")
fold_click :: proc(w: ^Chrome_World, loc := #caller_location) {
	before := fold_button_at(w, loc)
	session.click(w.s, "dt_net_fold", loc = loc)
	chrome_still(w, loc)
	after := fold_button_at(w, loc)
	testing.expectf(w.s.t, before == after, "the fold button stays under the pointer: %v, then %v", before, after, loc = loc)
}

@(test)
chrome_network_detail_folds_when_narrow :: proc(t: ^testing.T) {
	w := fold_world(t)
	fold_panel_width(w, WIDE)
	fold_select_request(w)
	expect_folded(w, false, "", "wide")
	fold_panel_width(w, NARROW)
	expect_folded(w, true, "folded narrow", "narrow")
	fold_panel_width(w, WIDE)
	expect_folded(w, false, "", "wide again")
}

@(test)
chrome_network_detail_manual_fold_holds_until_a_crossing :: proc(t: ^testing.T) {
	w := fold_world(t)
	fold_panel_width(w, WIDE)
	fold_select_request(w)
	fold_click(w)
	expect_folded(w, true, "folded", "folded by hand while wide")
	fold_panel_width(w, WIDER)
	expect_folded(w, true, "folded", "wide still")
	fold_panel_width(w, NARROW)
	expect_folded(w, true, "folded narrow", "narrow: the crossing")
	fold_click(w)
	expect_folded(w, false, "narrow", "opened by hand while narrow")
	fold_panel_width(w, NARROWER)
	expect_folded(w, false, "narrow", "narrow still")
	fold_panel_width(w, WIDE)
	expect_folded(w, false, "", "wide: the crossing")
	fold_panel_width(w, NARROW)
	expect_folded(w, true, "folded narrow", "narrow: the rule again")
}

// What the fold button saved (the test above reads it), at the next start in a panel of the same width.
@(private = "file")
fold_restart :: proc(t: ^testing.T, pref: string, width: int, folded: bool, loc := #caller_location) {
	w := fold_world(t, {fmt.tprintf("%s=%s", browser.NET_DETAIL_FOLD_PREF, pref)}, loc)
	fold_panel_width(w, width, loc)
	fold_select_request(w, loc)   // (after the width: the first measure is the restarted panel's own)
	expect_folded(w, folded, pref, fmt.tprintf("started with %q at %d px", pref, width), loc)
}

@(test)
chrome_network_detail_fold_by_hand_survives_a_restart :: proc(t: ^testing.T) { fold_restart(t, "folded", WIDE, true) }

@(test)
chrome_network_detail_opening_by_hand_survives_a_restart :: proc(t: ^testing.T) { fold_restart(t, "narrow", NARROW, false) }

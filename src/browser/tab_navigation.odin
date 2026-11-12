package browser

// The navigation of a tab, one state (Tab_Nav.phase), changed by nav_to:
//
//     any phase -> Requested -> (Responded) -> Adopted -> Painted
//                      \-----------/
//                       nav_cancel: back to the old page (Painted), or nothing to go back to (Idle)
//
// Beside it the frame of the old page (Paint_Hold, first_paint.odin) goes None -> Waiting -> Counting -> None by hold_step.
// What the tab shows changes here and in the back/forward cache only (bfcache_take, bfcache_restore): `t.page` and `t.nav`
// have no other writer (but hold_step giving a page back, and blank_close). What ends a page's life leaves the draw: nav_tick, in the page phase of each frame.
//
// The page is left when the navigation starts (leave_page), not when the next document arrives as in HTML: the session
// has the new entry from that moment (history_push), so what a pagehide or unload listener writes in the history would
// land in the next document's entry, and a page that runs on loses its held frame at its first change, where a frozen one
// keeps it. A navigation that comes to nothing gives the document back as it left: frozen (pageshow), or unloaded (once).

import "core:strings"
import "wb:base"
import "wb:host"
import "wb:page"

Nav_Phase :: enum u8 {
	Idle,       // nothing under way: the tab shows a view of the browser, or nothing (stopped with no page to go back to)
	Requested,  // the request is out; the page left is held, or gone
	Responded,  // the head of the answer is in and it makes no document yet (an image: the document comes with its bytes)
	Adopted,    // t.page is the new document; it has not painted
	Painted,    // it has
}

// How a navigation ended with no document.
Nav_End :: enum u8 { Stopped, Downloaded }

nav_to :: proc(app: ^App, t: ^Tab, to: Nav_Phase) {
	n := &t.nav_state
	n.phase = to
	if to == .Requested { n.started, n.arrived = host.now_ns(&app.loop), 0 }
	ext_tab_nav(app, t, to)   // ext_window_api.odin: tabs.onUpdated (loading, complete)
}

// No answer has made a document: nothing has replaced what the tab showed.
nav_pending :: proc(t: ^Tab) -> bool { return t.nav_state.phase == .Requested || t.nav_state.phase == .Responded }

// The tab starts over: what its navigation scope held goes, and the tab shows `kind`, with no page yet.
nav_fresh :: proc(t: ^Tab, kind: Tab_Kind) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, kind
	t.nav_state.no_store = false
}

// A view of the browser, with no page (about:config, about:history...).
nav_show_view :: proc(app: ^App, t: ^Tab, kind: Tab_Kind) {
	nav_fresh(t, kind)
	nav_to(app, t, .Idle)
}

// A built-in page: an ordinary document the browser writes, shown at once.
nav_show_page :: proc(app: ^App, t: ^Tab, address: string) {
	nav_fresh(t, .Web)
	nav_adopt(app, t, page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, address, console_sink, t))
}

// `p` is the tab's document.
nav_adopt :: proc(app: ^App, t: ^Tab, p: ^page.Page) {
	attach_page(app, t, p)
	t.page = p
	nav_to(app, t, .Adopted)
}

// The page phase has seen the tab's new document: the clock of "since the document arrived" starts, the hold's limit with it.
nav_arrived :: proc(app: ^App, t: ^Tab) {
	if t.nav_state.arrived == 0 { t.nav_state.arrived = shell_now_ns() }
	hold_step(app, t, .Arrival)
}

// The tab's document painted. (Never a window's initial about:blank while the navigation that replaces it is out.)
nav_painted :: proc(app: ^App, t: ^Tab) {
	if t.nav_state.phase != .Adopted { return }
	nav_to(app, t, .Painted)
	request_frames(app, 2)   // (a paint from the draw, for a new size: the next frame's tick lets the old page go)
}

// Each frame of a window, in its page phase, before and after the page is prepared: what holds an old page ends here, so
// no page closes or goes to the back/forward cache under a draw.
nav_tick :: proc(app: ^App) {
	wnd := active_window(app)
	t := current_tab(app)
	for other in wnd.tabs { if other != t { hold_step(app, other, .Over) } }   // a frame held in a tab not shown is of no use
	if t == nil { return }
	if t.page != nil { nav_arrived(app, t) }
	if hold_ended(app, t) { hold_step(app, t, .Over) }
}

// A navigation ends with no document (Stop before an answer, an answer that is a download): the tab goes back to what it
// showed. The held page, else the entry it left, else nothing: Stop leaves the tab empty, a download closes a tab that
// was opened for it alone. `load` is gone after this.
nav_cancel :: proc(app: ^App, t: ^Tab, load: ^Doc_Load, how: Nav_End) {
	before := load.left_entry != 0 || (load.pushed && page.session_peek(&t.session, -1) != nil)
	if how == .Stopped && t.hold.state == .None && !before {
		t.load = nil   // (its scope still owns it)
		nav_to(app, t, .Idle)
		return
	}
	restore_stop(app, t)
	t.nav_state.timing.active = false
	if load.pushed { page.session_drop_current(&t.session) }
	if e := page.session_find(&t.session, load.left_entry); e != nil { page.session_goto(&t.session, e) }
	sync_history(app, t)
	if t.hold.state != .None {
		hold_step(app, t, .Back)
		set_status(t, how == .Stopped ? "Stopped" : "Done")
		return
	}
	if cur := page.session_current(&t.session); cur != nil {
		if bfcache_restore(app, t, cur) { return }
		navigate(app, t, strings.clone(cur.url, context.temp_allocator), record = false, restore = true, origin = .Replay)
		return
	}
	if w, _ := window_of_tab(app, t); w != nil && (len(window_tabs(app, w)) > 1 || len(app.windows) > 1) {
		tab_close_tab(app, t)
		return
	}
	navigate(app, t, "", record = false)
}

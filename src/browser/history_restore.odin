package browser

// What an entry of the tab's history showed comes back with it (HTML "persisted user state" and "restore persisted
// state"):
//   * when the tab leaves an entry (a navigation, back, forward, a reload, pushState, a fragment, closing the tab, the
//     session being saved) the document's scroll position, the positions of the scroll containers that were moved,
//     the page zoom and the form controls the user changed are saved in it (page.Persisted_State);
//   * when a new document shows that entry again (back, forward, a reload, a restored session) they are put back. The
//     controls once the document is parsed; the scroll positions as soon as the layout is tall (or wide) enough for
//     them: the page grows while it loads, so this is tried at each layout until the load event plus
//     history.restore.after_load_ms, or history.restore.max_wait_ms, then the scroller goes as far as it can. The user
//     (or a script) scrolling first wins: the restoration stops. No smooth scrolling: it jumps;
//   * a same-document traversal (popstate) restores the positions of the entry at once;
//   * history.scrollRestoration = "manual" (the entry's) leaves the scroll positions to the page;
//   * a page from the back/forward cache needs none of it (bfcache.odin): it is as it was.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:host"
import lay "wb:layout"
import "wb:page"

Restore_Kind :: enum u8 { New_Document, Same_Document }

Restore :: struct {
	active:    bool,
	kind:      Restore_Kind,
	entry:     u64,             // the entry being restored (its id in the tab's tree)
	page:      rawptr,          // the document it is restored into
	started:   time.Tick,
	load_seen: bool,
	load_at:   time.Tick,
	applied:   f32,             // the document's offset as last set here: anything else means someone else scrolled
	doc_done:  bool,
	controls_done: bool,
	done:      [dynamic]bool,   // per container of the entry
	fragment:  bool,            // the entry's saved position wins over the URL's fragment
	timer:     base.Handle,     // the deadline, so that the last attempt happens without other activity
}

// What a traversal measured (history.debug): from the user's request to the frame that shows the entry.
Traverse_Timing :: struct {
	active: bool,
	from_cache: bool,
	started: time.Tick,
	url:    string,   // owned
}

// The tab's part of this (one field of Tab).
Tab_Nav :: struct {
	restore:  Restore,
	timing:   Traverse_Timing,
	left:     rawptr,   // the page leave_page already handled (once per page)
	bf_entry: u64,      // the entry the page that is being left goes into the back/forward cache with (0: it is not kept)
	no_store: bool,     // the current document came with Cache-Control: no-store
	last_visit: string, // owned: the address last recorded in the global history for this tab
}

tab_nav_destroy :: proc(app: ^App, t: ^Tab) {
	restore_stop(app, t)
	delete(t.nav_state.restore.done)
	delete(t.nav_state.timing.url)
	delete(t.nav_state.last_visit)
	t.nav_state = {}
}

////////////////////////////////
// Saving

// Saves what the tab's document shows into `e` (an entry of that document).
entry_capture :: proc(app: ^App, t: ^Tab, e: ^page.History_Entry) {
	if e == nil || t.page == nil || t.kind != .Web || t.page.closed { return }
	if e.doc != page.page_id(t.page) { return }
	r := &t.nav_state.restore
	// still being restored and not touched since: what it should show is still what was saved
	if r.active && r.entry == e.id && r.page == rawptr(t.page) && abs(t.scroll - r.applied) <= 0.5 { return }
	ps := &e.persisted
	page.persisted_clear(ps)
	ps.saved = true
	ps.zoom = t.zoom
	scale := t.layout.valid && t.layout.scale > 0 ? t.layout.scale : page_scale(app)
	if scale <= 0 { scale = 1 }
	if t.layout.valid {
		ps.scroll = {0, smooth_pending(app, t, base.NIL_HANDLE).y / scale}
		for node, off in t.layout.scroll {
			if off == {} { continue }
			pos := smooth_pending(app, t, node)
			path := page.element_path(t.page.doc, node)
			if path != "" { page.persisted_add_container(ps, path, pos / scale) }
		}
	} else {
		ps.scroll = {0, t.scroll / scale}
	}
	if hcfg.restore_forms { page.persisted_capture_controls(t.page, ps) }
}

// The current entry, if it is the document's.
entry_capture_current :: proc(app: ^App, t: ^Tab) {
	entry_capture(app, t, page.session_current(&t.session))
}

// Embedder.leaving: the document goes to another of its entries (pushState, a fragment, popstate).
page_entry_leaving :: proc(user: rawptr, p: ^page.Page, e: ^page.History_Entry) {
	t := (^Tab)(user)
	if t.page != p { return }
	entry_capture(the_app, t, e)
}

// Embedder.entered: a same-document traversal reached `e`: its positions come back now.
page_entry_entered :: proc(user: rawptr, p: ^page.Page, e: ^page.History_Entry) {
	t := (^Tab)(user)
	if t.page != p { return }
	restore_begin(the_app, t, e, .Same_Document)
}

////////////////////////////////
// Restoring

// Starts restoring `e` into the tab's document (the current one, or the one about to load: `page` is then set when it
// arrives, restore_tick takes the first page it sees).
restore_begin :: proc(app: ^App, t: ^Tab, e: ^page.History_Entry, kind: Restore_Kind) {
	restore_stop(app, t)
	if e == nil || !hcfg.restore || !e.persisted.saved { return }
	r := &t.nav_state.restore
	r.active, r.kind, r.entry, r.started = true, kind, e.id, time.tick_now()
	r.page = kind == .Same_Document ? rawptr(t.page) : nil
	r.applied = t.scroll
	r.doc_done = e.scroll_manual
	r.controls_done = kind == .Same_Document || !hcfg.restore_forms
	r.load_seen = false
	r.fragment = !e.scroll_manual
	clear(&r.done)
	for _ in e.persisted.containers { append(&r.done, e.scroll_manual) }
	restore_arm(app, t, hcfg.restore_max_ms)
	request_frames(app, 2)
}

restore_stop :: proc(app: ^App, t: ^Tab) {
	r := &t.nav_state.restore
	r.active = false
	if r.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, r.timer); r.timer = base.NIL_HANDLE }
}

@(private = "file")
restore_arm :: proc(app: ^App, t: ^Tab, ms: f64) {
	r := &t.nav_state.restore
	if r.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, r.timer) }
	r.timer = host.set_timer(&app.loop, max(ms, 1), 0, proc(data: rawptr) {
		t := (^Tab)(data)
		t.nav_state.restore.timer = base.NIL_HANDLE
		request_frames(the_app, 2)
	}, t, t.scope)
}

@(private = "file")
page_loaded :: proc(p: ^page.Page) -> bool {
	if p.scripts != nil && p.scripts.started { return p.scripts.loaded }
	return p.render.painted
}

// Whether the restoration ran out of time: the scrollers then go as far as they can.
restore_expired :: proc(started, load_at: time.Tick, load_seen: bool, max_ms, after_ms: f64) -> bool {
	if f64(time.duration_milliseconds(time.tick_since(started))) >= max_ms { return true }
	return load_seen && f64(time.duration_milliseconds(time.tick_since(load_at))) >= after_ms
}

// A scroller that needs `want` and can go up to `limit` now: where to put it, and whether that is the end of it.
restore_step :: proc(want, limit: f32, expired: bool) -> (pos: f32, done: bool) {
	if limit + 0.5 >= want { return want, true }
	if expired { return max(limit, 0), true }
	return 0, false
}

// Each frame, after the layout of the tab's document and before it scrolls to its fragment.
restore_tick :: proc(app: ^App, t: ^Tab, viewport: [2]f32) {
	r := &t.nav_state.restore
	if !r.active || t.page == nil || !t.layout.valid { return }
	if r.page == nil { r.page, r.applied = t.page, t.scroll }   // the new document's first layout
	e := page.session_current(&t.session)
	if r.page != rawptr(t.page) || e == nil || e.id != r.entry || !e.persisted.saved { restore_stop(app, t); return }
	if abs(t.scroll - r.applied) > 0.5 { restore_stop(app, t); return }   // scrolled by the user or a script: theirs
	p := t.page
	ps := &e.persisted
	if r.fragment {
		delete(t.fragment_seen)
		t.fragment_seen = strings.clone(p.env.location.href)
	}
	if !r.controls_done && p.render.adopted {
		r.controls_done = true
		page.persisted_restore_controls(p, ps)
	}
	if !r.load_seen && page_loaded(p) {
		r.load_seen, r.load_at = true, time.tick_now()
		restore_arm(app, t, hcfg.restore_after_ms)
	}
	expired := restore_expired(r.started, r.load_at, r.load_seen, hcfg.restore_max_ms, hcfg.restore_after_ms)
	scale := t.layout.scale > 0 ? t.layout.scale : 1
	if !r.doc_done {
		pos, done := restore_step(ps.scroll.y * scale, max(t.layout.height - viewport.y, 0), expired)
		if done {
			scroll_document_to(app, t, pos, false)
			r.doc_done = true
		}
	}
	r.applied = t.scroll
	all := r.doc_done
	for &c, i in ps.containers {
		if i >= len(r.done) || r.done[i] { continue }
		h := page.element_from_path(p.doc, c.path)
		limit, ok := lay.scroll_max(&t.layout, h)
		if !ok {
			if expired { r.done[i] = true } else { all = false }
			continue
		}
		x, dx := restore_step(c.pos.x * scale, limit.x, expired)
		y, dy := restore_step(c.pos.y * scale, limit.y, expired)
		if dx && dy {
			lay.set_scroll(&t.layout, h, {x, y})
			r.done[i] = true
		} else { all = false }
	}
	if all && r.controls_done { restore_stop(app, t) }
}

////////////////////////////////
// Measuring traversals (history.debug: WREN_HISTORY_TIMING names a file the times are appended to)

timing_begin :: proc(t: ^Tab, from_cache: bool, address: string) {
	tm := &t.nav_state.timing
	tm.active, tm.from_cache, tm.started = true, from_cache, time.tick_now()
	delete(tm.url)
	tm.url = strings.clone(address)
}

// After a frame painted the tab's document: the first one after a traversal ends its measure (a new document: once
// its scroll position is back too).
timing_painted :: proc(t: ^Tab) {
	tm := &t.nav_state.timing
	if !tm.active || t.page == nil || !t.page.render.painted { return }
	if !tm.from_cache && t.nav_state.restore.active && !t.nav_state.restore.doc_done { return }
	tm.active = false
	ms := time.duration_milliseconds(time.tick_since(tm.started))
	how := tm.from_cache ? "from the back/forward cache" : "loaded again"
	tab_log(t, .Log, fmt.tprintf("history: entry shown in %.1f ms (%s)", ms, how))
	if path := os.get_env("WREN_HISTORY_TIMING", context.temp_allocator); path != "" {
		if f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
			os.write_string(f, fmt.tprintf("%s\t%.2f\t%s\n", tm.from_cache ? "bfcache" : "load", ms, tm.url))
			os.close(f)
		}
	}
}

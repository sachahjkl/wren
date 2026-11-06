package page

// The page's side of the back/forward cache: a document the user navigates away from may be kept alive, frozen, and
// shown again at once when the user comes back (HTML "the bfcache", the shell's bfcache.odin decides and keeps it).
//   * Eligibility (HTML "unload" rules and Chromium's NotRestoredReasons, the ones that apply here): no unload or
//     beforeunload listener on the Window, no WebSocket or EventSource open, no dedicated worker running, no request
//     of the page in flight (fetch, XMLHttpRequest, scripts, stylesheets, fonts), the document finished loading. The
//     shell adds its own (Cache-Control: no-store on the document, an error page, a dialog open...).
//   * Freezing: no task of the page runs (posted tasks, timers, idle callbacks, animation frames): what comes due
//     while frozen is kept and runs, in order, when the page is thawed. Network callbacks cannot come: nothing was in
//     flight.
//   * pagehide (persisted: true) and visibilitychange (hidden) as it goes in; visibilitychange (visible) and pageshow
//     (persisted: true) as it comes back.

import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:style"

Bfcache_Blocker :: enum u8 {
	Unload_Listener,      // unload / beforeunload on the Window
	Web_Socket,
	Event_Source,
	Worker,
	Request_In_Flight,    // a fetch, a script, a stylesheet, a font still loading
	Loading,              // the load event has not fired yet
	Unloaded,             // its unload ran, for a navigation that came to nothing: it stays a document, not one to keep (HTML "salvageable")
	Closed,
}

Bfcache_Blockers :: bit_set[Bfcache_Blocker]

// Why this page cannot go into the back/forward cache (empty: it can).
bfcache_blockers :: proc(p: ^Page) -> Bfcache_Blockers {
	out: Bfcache_Blockers
	if p == nil || p.closed || p.web == nil { return {.Closed} }
	if p.web.unloaded { return {.Unloaded} }
	w := p.web
	if w.window != 0 && (object_has_listener(p, w.window, "unload") || object_has_listener(p, w.window, "beforeunload")) { out += {.Unload_Listener} }
	it: u32
	for _, o in base.pool_next(&p.objects.pool, &it) {
		if o.vt == &websocket_vt {
			if ws := (^Web_Socket)(o.data); ws != nil && ws.state < WS_CLOSED { out += {.Web_Socket} }   // CONNECTING, OPEN, CLOSING
		} else if o.vt == &eventsource_vt {
			if es := (^Event_Source)(o.data); es != nil && es.state != ES_CLOSED { out += {.Event_Source} }
		}
	}
	for h in p.workers.hosts {
		if h.state == .Loading || h.state == .Running { out += {.Worker} }
	}
	fi: u32
	for _, f in base.pool_next(&p.fetches, &fi) { if f.task != base.NIL_HANDLE { out += {.Request_In_Flight} } }
	for _, l in p.link_loads { if l.task != base.NIL_HANDLE { out += {.Request_In_Flight} } }
	for l in p.import_loads { if l.task != base.NIL_HANDLE { out += {.Request_In_Flight} } }
	for _, f in p.fonts.faces { if f.state == .Queued || f.state == .Loading { out += {.Request_In_Flight} } }
	if webauthn_busy(p) { out += {.Request_In_Flight} }   // a passkey dialog is open for it
	if s := p.scripts; s != nil {
		for f in s.fetches { if f.task != base.NIL_HANDLE { out += {.Request_In_Flight} } }
		if s.started && !s.loaded { out += {.Loading} }
	}
	return out
}

page_frozen :: proc(p: ^Page) -> bool { return p != nil && p.web != nil && p.web.frozen }

// The document goes into the back/forward cache: pagehide (persisted), hidden, then frozen.
page_freeze :: proc(p: ^Page) {
	if p == nil || p.closed || p.web.frozen { return }
	fire_page_transition(p, "pagehide", true)
	if p.closed { return }
	set_page_visible(p, false)
	if p.closed { return }
	w := p.web
	w.frozen = true
	if w.idle_timer != base.NIL_HANDLE { host.clear_timer(p.loop, w.idle_timer); w.idle_timer = base.NIL_HANDLE }
	if p.engine != nil { style.engine_release_spares(p.engine) }
}

// Back from the back/forward cache: what came due runs (tasks first, in the order they were posted, then timers),
// visible, then pageshow (persisted). `visible`: the tab is shown.
page_thaw :: proc(p: ^Page, visible := true) {
	if p == nil || p.closed || !p.web.frozen { return }
	w := p.web
	w.frozen = false
	tasks := w.frozen_tasks
	w.frozen_tasks = nil
	for d in tasks { host.post(p.loop, run_page_task, d) }   // (run_page_task frees them)
	delete(tasks)
	for h in w.frozen_timers {
		if t := base.pool_get(&p.timers, h); t != nil && t.handle == base.NIL_HANDLE {
			t.handle = host.set_timer(p.loop, 0, 0, timer_fire, t, p.scope)
		}
	}
	clear(&w.frozen_timers)
	idle_schedule(p)
	if visible { set_page_visible(p, true) }
	if p.closed { return }
	fire_page_transition(p, "pageshow", true)
}

// pagehide / pageshow at the Window; `persisted` is PageTransitionEvent.persisted (Event_code).
fire_page_transition :: proc(p: ^Page, type: string, persisted: bool) {
	fire_window_event(p, dom.Event{type = type, code = persisted ? 1 : 0})
}

// A document that is not kept goes: its frames' documents first, then pagehide (not persisted) and unload (HTML "unload a
// document and its descendants"), once. While that runs it starts no navigation.
page_unload :: proc(p: ^Page) {
	if p == nil || p.closed || p.web.frozen || p.web.unloaded { return }
	p.web.unloaded = true
	if p.frames != nil {
		ids := make([dynamic]u64, 0, len(p.frames.children), context.temp_allocator)
		for n in p.frames.children { append(&ids, n.id) }
		for id in ids {
			if n := navigable_by_id(id); n != nil { page_unload(n.page) }
			if p.closed { return }
		}
	}
	p.web.unloading += 1
	fire_page_transition(p, "pagehide", false)
	if p.closed { return }
	fire_window_event(p, dom.Event{type = "unload"})
	if !p.closed { p.web.unloading -= 1 }
}

// The tab's history goes on without the document, or takes it back. It may run on while its frame is held (first_paint.odin), and writes in no entry of the next one.
page_set_left :: proc(p: ^Page, left: bool) { p.web.left = left }

// The document is about to be left: beforeunload (no prompt: a script's navigation has no user activation to ask with, HTML
// "prompt to unload"). While that runs it starts no navigation.
page_before_unload :: proc(p: ^Page) {
	if p == nil || p.closed || p.web.frozen { return }
	p.web.unloading += 1
	fire_window_event(p, dom.Event{type = "beforeunload", cancelable = true})
	if !p.closed { p.web.unloading -= 1 }
}

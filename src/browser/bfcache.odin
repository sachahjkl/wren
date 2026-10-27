package browser

// The back/forward cache (HTML "bfcache", as Chromium and Firefox keep one): when a tab leaves a document by a
// navigation, the document may stay alive, frozen (page.page_freeze: pagehide with persisted, no task of it runs),
// with its layout, its images and its JavaScript realm, so that going back (or forward, or to it from the tab's
// history tree) shows it at once, exactly as it was, then thaws it (pageshow with persisted). Otherwise the entry
// loads again (history_restore.odin then brings its scroll positions and forms back).
//   * Who may stay: the page's own rules (page.bfcache_blockers: unload handlers, open sockets, workers, requests in
//     flight, still loading) and the shell's: a web document (not about:config, not an error page, not view-source),
//     no Cache-Control: no-store on its response, no file or color picker waiting.
//   * How long: history.bfcache.timeout_s; at most history.bfcache.max_entries pages and history.bfcache.max_memory
//     (an estimate) for all tabs; the pages left longest ago go first. An entry gone from its tab's history tree, or
//     its tab closed, takes its page with it.
//   * While the next page loads, the page left is still shown (paint holding, first_paint.odin): it goes into the
//     cache when the hold ends instead of closing.
// The tab's scope owns every cached page's scope: closing the tab closes them.

import "core:fmt"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:page"

Bf_Entry :: struct {
	tab:      u64,              // Tab.id
	entry:    u64,              // the history entry it shows
	nav:      ^base.Scope,      // its navigation scope: the page and all it started
	page:     ^page.Page,
	layout:   Layout,
	scroll:   f32,
	zoom:     f32,
	url:      string,           // owned (the tab's address while it was shown)
	title:    string,           // owned
	fragment_seen: string,      // owned
	image_sizes: u64,
	web_fonts: int,
	no_store: bool,
	stored:   time.Tick,
	bytes:    int,              // its estimated memory
}

Bfcache :: struct {
	entries: [dynamic]^Bf_Entry,   // oldest first
	timer:   base.Handle,
	stores, restores, evictions, refusals: int,   // statistics (about:history, wren ctl stats)
	traversals, misses: int,       // back / forward to a document: how many, and how many found no cached page
	reasons: map[string]int,       // owned keys: why pages were not kept (each page blocker counted apart), and why a
	                               // traversal missed ("evicted or never kept")
	last_refusal: string,          // owned: why the last page could not be kept
}

bf: Bfcache

bfcache_shutdown :: proc(app: ^App) {
	if bf.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, bf.timer) }
	for e in bf.entries { bf_entry_free(e, close = true) }
	delete(bf.entries)
	delete(bf.last_refusal)
	for k in bf.reasons { delete(k) }
	delete(bf.reasons)
	bf = {}
}

// One more page (or traversal) for why (bf.reasons).
@(private = "file")
bf_count :: proc(why: string) {
	if why in bf.reasons { bf.reasons[why] += 1 } else { bf.reasons[strings.clone(why)] = 1 }
}

@(private = "file")
bf_entry_free :: proc(e: ^Bf_Entry, close: bool) {
	if close { base.scope_close(e.nav) }
	layout_destroy(&e.layout)
	page_fonts_drop(&page_render.fonts, e)
	delete(e.url); delete(e.title); delete(e.fragment_seen)
	free(e)
}

// Why the tab's page cannot be kept ("" when it can).
bfcache_refusal :: proc(app: ^App, t: ^Tab) -> string {
	if !hcfg.bf_enabled || hcfg.bf_max_entries == 0 { return "the back/forward cache is off" }
	if t.kind != .Web || t.page == nil { return "not a document" }
	p := t.page
	if t.load != nil && t.load.failed != .None { return "an error page" }
	if t.load != nil && t.load.view_source { return "a source view" }
	if t.nav_state.no_store { return "Cache-Control: no-store" }
	if !p.render.painted { return "never shown" }
	if p.formctl != nil && p.formctl.picker != base.NIL_HANDLE { return "a picker is open" }
	if b := page.bfcache_blockers(p); b != {} { return fmt.tprintf("%v", b) }
	return ""
}

// The tab leaves its page (a navigation away, a traversal to another document): its current entry's state is saved;
// the page is frozen for the back/forward cache when it may be kept (bf_entry is then its entry), else unloaded.
// Once per page. `keep` false: the page is not to be kept whatever it is (a reload, location.replace: another document
// takes its entry), and its entry keeps nothing either when `save` is false.
leave_page :: proc(app: ^App, t: ^Tab, keep := true, save := true) {
	if t.page == nil || t.kind != .Web || t.nav_state.left == rawptr(t.page) { return }
	p := t.page
	t.nav_state.left = p
	t.nav_state.bf_entry = 0
	restore_stop(app, t)
	cur := page.session_current(&t.session)
	if cur == nil || cur.doc != page.page_id(p) { page.page_unload(p); return }
	if save { entry_capture(app, t, cur) }
	if !keep { page.page_unload(p); return }
	if why := bfcache_refusal(app, t); why != "" {
		bf.refusals += 1
		delete(bf.last_refusal)
		bf.last_refusal = strings.clone(why)
		if b := page.bfcache_blockers(p); b != {} {
			for x in page.Bfcache_Blocker { if x in b { bf_count(fmt.tprintf("%v", x)) } }
		} else {
			bf_count(why)
		}
		page.page_unload(p)
		return
	}
	page.page_freeze(p)
	if !p.closed { t.nav_state.bf_entry = cur.id }
}

// The tab's page goes into the cache now (it was frozen by leave_page): the tab gets an empty navigation scope and
// layout. False when the page is not to be kept.
bfcache_take :: proc(app: ^App, t: ^Tab) -> bool {
	id := t.nav_state.bf_entry
	if id == 0 || t.page == nil || t.nav_state.left != rawptr(t.page) || t.page.closed { return false }
	e := new(Bf_Entry)
	e^ = Bf_Entry{tab = t.id, entry = id, nav = t.nav, page = t.page, layout = t.layout, scroll = t.scroll, zoom = t.zoom,
		url = strings.clone(t.url), title = strings.clone(t.title), fragment_seen = strings.clone(t.fragment_seen),
		image_sizes = t.image_sizes, web_fonts = t.web_fonts, no_store = t.nav_state.no_store, stored = time.tick_now()}
	page_fonts_transfer(&page_render.fonts, t, e)   // its web faces stay with its layout
	t.layout = {}
	t.web_font_page, t.web_fonts = nil, 0
	t.nav = base.scope_make("navigation", t.scope)
	t.page = nil
	t.nav_state.bf_entry = 0
	bf_store(app, e)
	return true
}

// The held frame's page (first_paint.odin hold_release) goes into the cache instead of closing. False: not kept.
bfcache_take_held :: proc(app: ^App, t: ^Tab) -> bool {
	h := &t.hold
	id := h.bf_entry
	h.bf_entry = 0
	if id == 0 || h.page == nil || h.page.closed { return false }
	e := new(Bf_Entry)
	e^ = Bf_Entry{tab = t.id, entry = id, nav = h.nav, page = h.page, layout = h.layout, scroll = h.scroll, zoom = h.zoom,
		url = strings.clone(h.page.env.location.href), title = default_tab_title(h.page.env.location.href, context.allocator), fragment_seen = strings.clone(h.page.env.location.href),
		image_sizes = h.image_sizes, web_fonts = h.web_fonts, stored = time.tick_now()}
	page_fonts_transfer(&page_render.fonts, h, e)
	if t.web_font_page == rawptr(h.page) {   // the next page has not taken the tab's faces over yet: they are this one's
		page_fonts_transfer(&page_render.fonts, t, e)
		t.web_font_page, t.web_fonts = nil, 0
	}
	h.layout = {}
	bf_store(app, e)
	return true
}

@(private = "file")
bf_store :: proc(app: ^App, e: ^Bf_Entry) {
	// one page per entry: an older one for it goes
	for i := len(bf.entries) - 1; i >= 0; i -= 1 {
		o := bf.entries[i]
		if o.tab == e.tab && o.entry == e.entry { ordered_remove(&bf.entries, i); bf_entry_free(o, close = true) }
	}
	e.bytes = bf_estimate(e)
	append(&bf.entries, e)
	bf.stores += 1
	bfcache_evict(app)
}

@(private = "file")
bf_estimate :: proc(e: ^Bf_Entry) -> int {
	p := e.page
	n := p.held + p.doc.nodes.count * 256
	n += len(e.layout.items) * size_of(e.layout.items[0]) + len(e.layout.boxes) * size_of(e.layout.boxes[0])
	if p.js != nil || len(p.instances) > 0 { n += hcfg.bf_overhead }
	return n
}

// Applies the limits: expired pages, pages of entries no longer in their tab's tree, then the oldest past the count
// and the memory. Arms the timer of the next expiry.
bfcache_evict :: proc(app: ^App) {
	now := time.tick_now()
	total := 0
	for i := len(bf.entries) - 1; i >= 0; i -= 1 {
		e := bf.entries[i]
		t := tab_by_id(app, e.tab)
		gone := t == nil || page.session_find(&t.session, e.entry) == nil || e.page.closed
		expired := f64(time.duration_milliseconds(time.tick_diff(e.stored, now))) >= hcfg.bf_timeout_ms
		if gone || expired || !hcfg.bf_enabled {
			ordered_remove(&bf.entries, i)
			bf_entry_free(e, close = t != nil)
			bf.evictions += 1
			continue
		}
		total += e.bytes
	}
	for len(bf.entries) > 0 && (len(bf.entries) > hcfg.bf_max_entries || total > hcfg.bf_max_bytes) {
		e := bf.entries[0]
		total -= e.bytes
		ordered_remove(&bf.entries, 0)
		bf_entry_free(e, close = true)
		bf.evictions += 1
	}
	if bf.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, bf.timer); bf.timer = base.NIL_HANDLE }
	if len(bf.entries) > 0 {
		left := hcfg.bf_timeout_ms - f64(time.duration_milliseconds(time.tick_diff(bf.entries[0].stored, now)))
		bf.timer = host.set_timer(&app.loop, max(left, 1) + 1, 0, proc(data: rawptr) {
			bf.timer = base.NIL_HANDLE
			bfcache_evict((^App)(data))
		}, app)
	}
}

// A tab closes: its cached pages go (its scope closes them: only the rest is freed here).
bfcache_drop_tab :: proc(t: ^Tab) {
	for i := len(bf.entries) - 1; i >= 0; i -= 1 {
		e := bf.entries[i]
		if e.tab != t.id { continue }
		ordered_remove(&bf.entries, i)
		bf_entry_free(e, close = false)
	}
}

// The page cached for `entry` of `t`, if any, goes (another document now shows that entry).
bfcache_forget :: proc(t: ^Tab, entry: u64) {
	for i := len(bf.entries) - 1; i >= 0; i -= 1 {
		e := bf.entries[i]
		if e.tab != t.id || e.entry != entry { continue }
		ordered_remove(&bf.entries, i)
		bf_entry_free(e, close = true)
		bf.evictions += 1
	}
}

tab_by_id :: proc(app: ^App, id: u64) -> ^Tab {
	for t in tabs_all(app) { if t.id == id { return t } }
	return nil
}

// Whether `entry` of `t` has a page in the cache.
bfcache_has :: proc(t: ^Tab, entry: u64) -> bool {
	for e in bf.entries { if e.tab == t.id && e.entry == entry && !e.page.closed { return true } }
	return false
}

// Shows `entry` (now the tab's current one) from the cache, if it is there: the page the tab had goes (into the cache
// itself when it may). False: the caller loads the entry.
bfcache_restore :: proc(app: ^App, t: ^Tab, entry: ^page.History_Entry) -> bool {
	at := -1
	for e, i in bf.entries { if e.tab == t.id && e.entry == entry.id && !e.page.closed { at = i; break } }
	bf.traversals += 1
	if at < 0 { bf.misses += 1; bf_count("evicted or never kept"); return false }
	e := bf.entries[at]
	ordered_remove(&bf.entries, at)
	// the tab's own page, frozen by leave_page when it may be kept, or closed
	hold_release(t)
	if bfcache_take(app, t) {
		base.scope_close(t.nav)   // the empty one it left
	} else {
		if t.page != nil && t.nav_state.left != rawptr(t.page) { page.page_unload(t.page) }
		base.scope_close(t.nav)
		layout_reset(&t.layout)
	}
	page_fonts_drop(&page_render.fonts, t)
	layout_destroy(&t.layout)
	t.nav, t.page, t.layout, t.load, t.kind = e.nav, e.page, e.layout, nil, .Web
	page_fonts_transfer(&page_render.fonts, e, t)
	t.web_font_page, t.web_fonts, t.image_sizes = e.page, e.web_fonts, e.image_sizes
	t.scroll, t.scroll_target = e.scroll, base.NIL_HANDLE
	if hcfg.restore_zoom && e.zoom > 0 { t.zoom = e.zoom }
	t.nav_state.no_store = e.no_store
	t.nav_state.left = nil
	delete(t.fragment_seen); t.fragment_seen = e.fragment_seen
	delete(t.url); t.url = e.url
	delete(t.title); t.title = e.title
	e.fragment_seen, e.url, e.title = "", "", ""
	e.layout = {}
	tab_icon_destroy(&t.icon)
	console_reset(t)
	set_status(t, "Restored from the back/forward cache")
	address_set(app, t, t.url)
	bf_entry_free(e, close = false)
	bf.restores += 1
	global_history_visit(app, t, t.url, t.title)
	timing_begin(t, true, t.url)
	page.page_thaw(t.page, visible = current_tab(app) == t)
	request_frames(app, 3)
	return true
}

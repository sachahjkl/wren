package page

// The load and error events of <link rel=stylesheet> (HTML §4.2.4, "process the linked resource"; §4.6.7 for the
// stylesheet's critical subresources): once the sheet is in the style engine and every @import under it is settled, a
// task fires `load` at the element; when the sheet will not come (network error, HTTP error, refused by policy, too
// large), `error`. A link removed or pointed elsewhere before that fires nothing. Loaders wait for these: Next.js and
// Turbopack load a CSS chunk with a <link> and go on in its onload (DuckDuckGo's home page waited forever for the part
// below the fold, with a spinner animating).

import "wb:base"
import "wb:dom"
import "wb:style"

// A <link> was connected or one of its attributes changed: its stylesheet is fetched now, not at the next rendering
// (which a hidden tab or a page without a window never does, and its load event would never come). One task reads
// every link of the document again, whatever the number of changes before it runs.
@(private)
link_changed :: proc(p: ^Page) {
	if p.link_sync_queued || p.engine == nil { return }
	p.link_sync_queued = true
	post_page_task(p, proc(p: ^Page, _: rawptr) {
		if p == nil { return }
		p.link_sync_queued = false
		// before the document is adopted render_begin reads them; after, styles() would at the next rendering
		if !p.closed && p.engine != nil && p.doc != nil && p.render.adopted { sync_styles(p) }
	}, nil)
}

// `l` reached its end: its sheet is registered (ok) or will not come. Called once per load.
@(private)
style_load_settled :: proc(p: ^Page, l: ^Style_Load, ok: bool) {
	if l.settled { return }
	l.settled = true
	if !ok { l.failed = true }
	if l.is_import {
		// the link the import belongs to may have been waiting for it
		if owner := import_root_owner(p, l); owner != base.NIL_HANDLE {
			if ll, has := p.link_loads[owner]; has { link_maybe_fire(p, ll) }
		}
		return
	}
	link_maybe_fire(p, l)
}

@(private)
link_maybe_fire :: proc(p: ^Page, l: ^Style_Load) {
	if !l.settled || l.fired || l.is_import { return }
	if !l.failed {
		for il in p.import_loads {
			if !il.settled && import_root_owner(p, il) == l.owner { return }
		}
	}
	l.fired = true
	Link_Event :: struct { node: base.Handle, error: bool }
	ev := new(Link_Event)
	ev^ = {l.owner, l.failed}
	post_page_task(p, proc(p: ^Page, data: rawptr) {
		ev := (^Link_Event)(data)
		defer free(ev)
		if p == nil || p.closed || p.doc == nil || dom.get(p.doc, ev.node) == nil { return }
		dispatch_event(p, ev.node, dom.Event{type = ev.error ? "error" : "load"})
	}, ev)
}

// The element whose sheet an @import is under (a <link>, a <style>), following imports of imports.
@(private)
import_root_owner :: proc(p: ^Page, il: ^Style_Load) -> base.Handle {
	if p.engine == nil { return base.NIL_HANDLE }
	s := style.engine_find_sheet(p.engine, il.sheet_id)
	for s != nil && s.parent != nil { s = s.parent }
	return s != nil ? s.owner : base.NIL_HANDLE
}

package page

// The Fullscreen API (api/fullscreen.widl; Fullscreen Standard): element.requestFullscreen(), document.exitFullscreen(),
// document.fullscreenElement / fullscreenEnabled, the "fullscreenchange" and "fullscreenerror" events and the
// :fullscreen pseudo-class (style.State.fullscreen; the UA rule in style/ua.odin makes the element cover the viewport).
//
//   * Each document keeps its fullscreen element (Page.fullscreen). A nested document that goes fullscreen makes the
//     container of every ancestor document the fullscreen element of that ancestor, up to the tab's document (`top`),
//     which is what the shell sees: one tab is in full screen when its top document has a fullscreen element.
//   * The shell makes the window fill the screen and hides its interface (Fullscreen_Embedder.set); it answers false
//     when it cannot (the tab is not the one shown, no window). Without an embedder (the headless tools) the request
//     simply succeeds, the page state being all there is.
//   * A request needs what browsers ask: full screen turned on, an element of the document (HTML, SVG, MathML) that is
//     connected, the document allowed by the Permissions Policy ("fullscreen": an <iframe> needs allowfullscreen or
//     allow="fullscreen"), and a recent click or key press (the transient activation record of the passkeys, see
//     fullscreen.user_activation_ms). The events and the promise's settlement are a task of their own, never inside the
//     call.
//   * It ends by exitFullscreen(), by the shell (Escape, F11, a tab switch), when the element leaves the document, when
//     its document goes away. Nested fullscreen elements are not stacked: a request for another element replaces the
//     fullscreen element, and any exit leaves full screen altogether.
//   * The WebKit-prefixed names (webkitRequestFullscreen, webkitFullscreenElement, webkitfullscreenchange...) are
//     aliases in native/js/prelude/compat.js; both spellings of each event are fired.

import "core:strings"
import "wb:base"
import "wb:config"
import "wb:dom"

Fullscreen_Settings :: struct {
	enabled:            bool,
	require_activation: bool,
	activation_ns:      i64,
}

FULLSCREEN_PREFS := [?]config.Def{
	{name = "fullscreen.enabled", kind = .Bool, default = {b = true},
		description = "The Fullscreen API: a page's element (a video player) can fill the screen (element.requestFullscreen). Off: document.fullscreenEnabled is false and every request fails with a TypeError and a fullscreenerror event."},
	{name = "fullscreen.require_user_activation", kind = .Bool, default = {b = true},
		description = "A request for full screen needs a recent click or key press in the document, as in other browsers. Off only to test pages that go fullscreen by themselves."},
	{name = "fullscreen.user_activation_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "How long after a click or key press a page may still ask for full screen."},
}

fullscreen_settings_from_prefs :: proc(p: ^config.Prefs) -> Fullscreen_Settings {
	return {
		enabled = config.bool_of(p, "fullscreen.enabled"),
		require_activation = config.bool_of(p, "fullscreen.require_user_activation"),
		activation_ns = config.int_of(p, "fullscreen.user_activation_ms") * 1_000_000,
	}
}

// What the shell does with full screen. nil proc: no window (the headless tools).
Fullscreen_Embedder :: struct {
	// The tab's document `top` has (on) or no longer has (off) an element in full screen: the window fills the screen
	// and the interface goes, or the window is back as it was. False (on only) when it cannot be: the request fails.
	set: proc(top: ^Page, on: bool, navigation: Api_FullscreenNavigation) -> bool,
	// The window takes time to change its size: the events and promises of a change wait for the shell to call
	// fullscreen_settled (it must, while fullscreen_waiting says so).
	deferred: bool,
}

fullscreen_embedder: Fullscreen_Embedder

@(private)
Page_Fullscreen :: struct {
	element: base.Handle,   // this document's fullscreen element; NIL: none
	waiting: [dynamic]^Fs_Task,   // changes whose events wait for the window's new size (fs_queue)
}

// Whether the tab's document has an element in full screen (for the shell).
fullscreen_active :: proc(top: ^Page) -> bool {
	return top != nil && top.fullscreen != nil && top.fullscreen.element != base.NIL_HANDLE
}

@(private)
fs_ensure :: proc(p: ^Page) -> ^Page_Fullscreen {
	if p.fullscreen == nil {
		p.fullscreen = new(Page_Fullscreen)
		base.on_close(p.scope, fullscreen_page_closing, p)
	}
	return p.fullscreen
}

// The document goes away (a navigation, a closed tab or frame). A top-level document tells the shell; a nested one
// leaves the tree's full screen (its container is the ancestors' fullscreen element).
@(private)
fullscreen_page_closing :: proc(data: rawptr) {
	p := (^Page)(data)
	f := p.fullscreen
	if f == nil { return }
	had := f.element != base.NIL_HANDLE
	p.fullscreen = nil
	for t in f.waiting {
		delete(t.message, base.process_allocator())
		free(t, base.process_allocator())
	}
	delete(f.waiting)
	free(f)
	if !had { return }
	p.style_state.fullscreen = base.NIL_HANDLE
	nav := p.frames != nil ? p.frames.nav : nil
	if nav != nil && nav.parent != nil {
		if par := nav.parent; !par.scope.closing && !par.closed { fullscreen_exit_tree(page_top(par)) }
	} else if fullscreen_embedder.set != nil {
		fullscreen_embedder.set(p, false, .Auto)
	}
}

// Every live document of the tree with a fullscreen element, the tab's first.
@(private)
fs_collect :: proc(p: ^Page, out: ^[dynamic]^Page) {
	if p.closed || p.scope.closing { return }
	if fullscreen_active(p) { append(out, p) }
	if p.frames == nil { return }
	for n in p.frames.children { if n.page != nil { fs_collect(n.page, out) } }
}

// Leaves full screen for the whole tree of `top` (the shell's Escape, document.exitFullscreen(), a removed element).
// `promise` of `promise_page` is settled with the events. True when there was something to leave.
@(private)
fullscreen_exit_tree :: proc(top: ^Page, promise_page: ^Page = nil, promise: u64 = 0, notify := true) -> bool {
	pages := make([dynamic]^Page, context.temp_allocator)
	fs_collect(top, &pages)
	if len(pages) == 0 { return false }
	for pg in pages {
		el := pg.fullscreen.element
		pg.fullscreen.element = base.NIL_HANDLE
		pg.style_state.fullscreen = base.NIL_HANDLE
		fs_queue(pg, el, .Change, pg == promise_page ? promise : 0)
	}
	if notify && fullscreen_embedder.set != nil { fullscreen_embedder.set(top, false, .Auto) }
	return true
}

// The shell leaves full screen on the page's behalf (Escape, F11, another tab shown).
fullscreen_exit :: proc(top: ^Page) -> bool { return fullscreen_exit_tree(top) }

// A node left the document: when it was the fullscreen element (or held it), full screen ends (the DOM's removal hook).
fullscreen_note_removed :: proc(p: ^Page) {
	f := p.fullscreen
	if f == nil || f.element == base.NIL_HANDLE { return }
	if dom.get(p.doc, f.element) == nil || !dom.is_connected(p.doc, f.element) { fullscreen_exit_tree(page_top(p)) }
}

////////////////////////////////
// Events and promises: a task

@(private)
Fs_Kind :: enum u8 { Change, Error }

@(private)
Fs_Task :: struct {
	node:    base.Handle,
	kind:    Fs_Kind,
	promise: u64,         // settled after the events: resolved by a change, rejected by an error
	message: string,      // owned (process allocator): the error's text
}

// A change waits (with a shell: Fullscreen_Embedder.deferred) until the window has its new size and the page has been
// laid out for it: the scripts' handlers read the viewport, and Blink too fires the events after the resize. The shell
// calls fullscreen_settled; the events of a page that goes away are dropped with it.
@(private)
fs_queue :: proc(p: ^Page, node: base.Handle, kind: Fs_Kind, promise: u64 = 0, message := "") {
	t := new(Fs_Task, base.process_allocator())
	t^ = {node = node, kind = kind, promise = promise, message = strings.clone(message, base.process_allocator())}
	if kind == .Change && fullscreen_embedder.deferred && !p.scope.closing {
		append(&fs_ensure(p).waiting, t)
		return
	}
	fs_post(p, t)
}

// The shell's window has the size of the tree's full screen state: the changes the tree's pages were waiting with happen.
fullscreen_settled :: proc(p: ^Page) {
	if p == nil || p.closed || p.scope.closing { return }
	if f := p.fullscreen; f != nil {
		for t in f.waiting { fs_post(p, t) }
		clear(&f.waiting)
	}
	if p.frames == nil { return }
	for n in p.frames.children { if n.page != nil { fullscreen_settled(n.page) } }
}

// Whether a change of the tree of `top` waits for the shell.
fullscreen_waiting :: proc(top: ^Page) -> bool {
	if top == nil || top.closed || top.scope.closing { return false }
	if top.fullscreen != nil && len(top.fullscreen.waiting) > 0 { return true }
	if top.frames == nil { return false }
	for n in top.frames.children { if n.page != nil && fullscreen_waiting(n.page) { return true } }
	return false
}

@(private = "file")
fs_post :: proc(p: ^Page, t: ^Fs_Task) {
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Fs_Task)(data)
		defer { delete(t.message, base.process_allocator()); free(t, base.process_allocator()) }
		if pg == nil || pg.closed { return }
		// at the element while it is in the document, else at the document (events bubble and cross shadow trees)
		target := pg.doc.root
		if t.node != base.NIL_HANDLE && dom.get(pg.doc, t.node) != nil && dom.is_connected(pg.doc, t.node) { target = t.node }
		type, prefixed := "fullscreenchange", "webkitfullscreenchange"
		if t.kind == .Error { type, prefixed = "fullscreenerror", "webkitfullscreenerror" }
		dispatch_event(pg, target, dom.Event{type = type, bubbles = true, composed = true})
		if pg.closed { return }
		dispatch_event(pg, target, dom.Event{type = prefixed, bubbles = true, composed = true})
		if pg.closed || t.promise == 0 { return }
		if t.kind == .Error { promise_reject(pg, t.promise, WEB_ERR_TYPE, t.message) } else { promise_resolve(pg, t.promise, 0) }
	}, t)
}

////////////////////////////////
// requestFullscreen / exitFullscreen

// Why `el` of the document may not go to full screen now; "" when it may.
@(private)
fullscreen_denied :: proc(p: ^Page, el: base.Handle) -> string {
	s := &p.settings.fullscreen
	n := dom.get(p.doc, el)
	switch {
	case !s.enabled: return "Fullscreen is turned off (fullscreen.enabled)."
	case n == nil || n.kind != .Element || n.ns == .None || n.ns == .Other: return "The element is not an HTML, SVG or MathML element."
	case !dom.is_connected(p.doc, el): return "The element is not in the document."
	case p.web != nil && p.web.frozen: return "The document is not fully active."
	case !feature_enabled(p, .Fullscreen): return "Permissions check failed (a frame needs allowfullscreen or allow=\"fullscreen\")."
	}
	if s.require_activation {
		age, ok := activation_age_ns(p)
		if !ok || age > s.activation_ns { return "API can only be initiated by a user gesture." }
	}
	return ""
}

Element_requestFullscreen :: proc(c: ^Call, element: Api_Element, navigation: Api_FullscreenNavigation) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	el := H(element.handle)
	if f := p.fullscreen; f != nil && f.element == el && dom.get(p.doc, el) != nil {
		resolve_later(p, pr, 0)   // already the fullscreen element
		return pr
	}
	if why := fullscreen_denied(p, el); why != "" {
		fs_queue(p, el, .Error, pr, strings.concatenate({"TypeError: Failed to execute 'requestFullscreen' on 'Element': ", why}, context.temp_allocator))
		return pr
	}
	top := page_top(p)
	// another element (of this document or a sibling frame's) was in full screen: it is replaced, not stacked
	fullscreen_exit_tree(top, notify = false)
	if fullscreen_embedder.set != nil && !fullscreen_embedder.set(top, true, navigation) {
		fs_queue(p, el, .Error, pr, "TypeError: Failed to execute 'requestFullscreen' on 'Element': the window cannot go to full screen now (this tab is not the one shown).")
		return pr
	}
	// the element, and the containers of the frames above it
	cur, node := p, el
	for {
		f := fs_ensure(cur)
		f.element = node
		cur.style_state.fullscreen = node
		fs_queue(cur, node, .Change, cur == p ? pr : 0)
		nav := cur.frames != nil ? cur.frames.nav : nil
		if nav == nil || nav.parent == nil { break }
		cur, node = nav.parent, nav.element
	}
	return pr
}

Document_exitFullscreen :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if !fullscreen_active(p) {
		reject_later(p, pr, WEB_ERR_TYPE, "TypeError: Failed to execute 'exitFullscreen' on 'Document': Document not active")
		return pr
	}
	fullscreen_exit_tree(page_top(p), p, pr)
	return pr
}

Document_fullscreenElement :: proc(c: ^Call) -> u64 {
	p := c.page
	if !fullscreen_active(p) { return 0 }
	d := p.doc
	el := p.fullscreen.element
	if !dom.is_connected(d, el) { return 0 }
	return u64(dom.retarget(d, el, d.root))
}

ShadowRoot_fullscreenElement :: proc(c: ^Call, root: Api_Node) -> u64 {
	p := c.page
	if !fullscreen_active(p) { return 0 }
	d := p.doc
	r := H(root.handle)
	t := dom.retarget(d, p.fullscreen.element, r)
	if dom.tree_root(d, t) != r { return 0 }
	return u64(t)
}

Document_fullscreenEnabled :: proc(c: ^Call) -> bool {
	p := c.page
	return p.settings.fullscreen.enabled && feature_enabled(p, .Fullscreen)
}

Document_fullscreen :: proc(c: ^Call) -> bool { return fullscreen_active(c.page) }

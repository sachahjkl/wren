package browser

import "core:fmt"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:a11y"
import "wb:base"
import "wb:dom"
import "wb:forms"
import lay "wb:layout"
import "wb:page"

// The accessibility tree of the page shown in a window (src/a11y): a tree of its own, grafted under the page area of
// the chrome's tree (A11y_Info.graft), sent after the chrome's (the graft node must be there first). Each frame's
// document (an iframe) has a tree of its own too, grafted under its frame element's node, sent after its parent's.
// After a document's first whole tree, only the nodes its changes reach are written (a11y.live_update: the mutation and
// style journals, the forms, the geometry) and handed to the adapter with platform.a11y_diff_patch; nothing at all is
// built while nothing changed. Each window keeps its own (Window_Own.a11y): two windows show two pages to the screen
// readers. Requests of screen readers for page nodes (click, focus, set a value, scroll into view) act on the page as
// the user would.

// One document's tree as the adapter has it.
@(private = "file")
Doc_Tree :: struct {
	page:  ^page.Page,
	tab:   ^Tab,                      // its tab, or its frame's stand-in tab
	tree:  platform.A11y_Tree_Id,
	live:  a11y.Live,
	full:  platform.A11y_Update,      // what live_update wrote last (a whole tree or a patch)
	diff:  platform.A11y_Diff,
	sent:  bool,
	focus: u64,
	seen:  u64,                       // the update round that last found it
}

// A window's page trees (Window_Own.a11y).
Page_A11y :: struct {
	tab_id:   u64,
	top:      ^Doc_Tree,
	frames:   [dynamic]^Doc_Tree,
	grafted:  u64,       // the tab whose tree the chrome's build grafted (0: none this build)
	round:    u64,
	// statistics (wren ctl stats)
	builds, patches, sends, refused, verify_failed: int,
	verify_diff: string,   // the last difference accessibility.page.verify found (owned)
}

// What `wren ctl stats` reports of a window's page trees.
Page_A11y_Stats :: struct {
	builds, patches, sends, refused, verify_failed, nodes, frames, written: int,
	fallback, verify_diff: string,
}

page_a11y_destroy :: proc(pa: ^Page_A11y) {
	doc_tree_free(pa.top)
	for d in pa.frames { doc_tree_free(d) }
	delete(pa.frames)
	delete(pa.verify_diff)
	pa^ = {}
}

@(private = "file")
doc_tree_free :: proc(d: ^Doc_Tree) {
	if d == nil { return }
	a11y.live_destroy(&d.live)
	platform.a11y_update_destroy(&d.full)
	platform.a11y_diff_destroy(&d.diff)
	free(d)
}

// The tree id of tab (or frame stand-in tab) `id`'s document (not zero: zero is the window's own tree).
page_tree_id :: proc(id: u64) -> platform.A11y_Tree_Id {
	t: platform.A11y_Tree_Id
	t[0] = 0x57   // 'W'
	t[1] = 0x01
	v := id
	for i in 0 ..< 8 { t[8 + i] = u8(v); v >>= 8 }
	return t
}

// In the page area's build: the page's tree is grafted there, and while the page has the keyboard screen readers are
// in it (its own focus counts).
page_a11y_graft :: proc(app: ^App, t: ^Tab, pb: ^ui.Box) {
	if t == nil || t.page == nil || t.kind != .Web || !ui.a11y_wanted() { return }
	if !a11y.settings_from_prefs(&app.prefs).enabled { return }
	ui.a11y_set(pb, {graft = page_tree_id(t.id)})
	window_own(app).a11y.grafted = t.id
	if forms_view(app).page_focus && ui.focus_key() == 0 { ui.a11y_focus_on(pb.key) }
}

// After the chrome's build (its tree sent): the page's requests, then its tree and its frames' when they changed.
page_a11y_frame :: proc(app: ^App) {
	wnd := active_window(app)
	pa := &window_own(app).a11y
	grafted := pa.grafted
	pa.grafted = 0
	t := current_tab(app)
	if !ui.a11y_active(wnd.ui) || t == nil || grafted != t.id {
		// no graft this build (no reader, no page, another view): the adapter dropped the page's trees with it
		if pa.top != nil { pa.top.sent = false }
		for d in pa.frames { d.sent = false }
		return
	}
	if t.page == nil || t.kind != .Web || t.page.formctl == nil { return }
	set := a11y.settings_from_prefs(&app.prefs)
	if pa.tab_id != t.id {
		// another page under the graft: its trees are new to the adapter
		doc_tree_free(pa.top)
		for d in pa.frames { doc_tree_free(d) }
		clear(&pa.frames)
		pa.top = nil
		pa.tab_id = t.id
	}
	if pa.top == nil || pa.top.page != t.page {
		doc_tree_free(pa.top)
		pa.top = new(Doc_Tree)
		pa.top.page = t.page
		pa.top.tree = page_tree_id(t.id)
	}
	pa.top.tab = t
	pa.round += 1

	// the requests, to the document whose tree they name
	for r in ui.a11y_requests() {
		if r.tree == pa.top.tree { page_a11y_request(app, t, t.page, r); continue }
		for d in pa.frames { if r.tree == d.tree && d.tab != nil { page_a11y_request(app, d.tab, d.page, r); break } }
	}

	// where the keyboard is: the frame documents down to the one that has it
	chain := focus_chain(app, t.page)
	size := draw.rect_size(wnd.page_rect)
	if !doc_tree_update(app, pa, pa.top, t, size, wnd.page_rect.min, chain, set) { return }
	if !set.frames { return }
	frames_update(app, pa, pa.top, t, size, chain, set)
	// frames that went: their trees went with their graft nodes
	k := 0
	for d in pa.frames {
		if d.seen == pa.round { pa.frames[k] = d; k += 1 } else { doc_tree_free(d) }
	}
	resize(&pa.frames, k)
}

// The documents from the page down to the frame document that has the keyboard (the page alone when none does).
@(private = "file")
focus_chain :: proc(app: ^App, top: ^page.Page) -> []^page.Page {
	out := make([dynamic]^page.Page, 0, 4, context.temp_allocator)
	append(&out, top)
	target := window_own(app).frames.focus
	if target == nil || target == top { return out[:] }
	find :: proc(p, target: ^page.Page, out: ^[dynamic]^page.Page) -> bool {
		if p.frames == nil { return false }
		for n in page.frames_children(p) {
			if n.page == nil { continue }
			append(out, n.page)
			if n.page == target || find(n.page, target, out) { return true }
			pop(out)
		}
		return false
	}
	if !find(top, target, &out) { resize(&out, 1) }
	return out[:]
}

// The frame element of `child` in `parent` (NIL: none).
@(private = "file")
frame_element :: proc(parent, child: ^page.Page) -> base.Handle {
	if parent == nil || parent.frames == nil { return base.NIL_HANDLE }
	for n in page.frames_children(parent) { if n.page == child { return n.element } }
	return base.NIL_HANDLE
}

@(private = "file")
Frame_Ctx :: struct { parent: ^page.Page }

// a11y.View.frame_tree: the tree of the document of a frame element, when the frame is laid out.
@(private = "file")
frame_tree_of :: proc(user: rawptr, element: base.Handle) -> (platform.A11y_Tree_Id, bool) {
	fc := (^Frame_Ctx)(user)
	n := page.frame_of_element(fc.parent, element)
	if n == nil || n.page == nil { return {}, false }
	fv := frame_view_of(n.page)
	if fv == nil || !fv.ready || !fv.tab.layout.valid { return {}, false }
	return page_tree_id(fv.tab.id), true
}

// One document's tree brought up to date and sent; false when the adapter did not take it (its frames wait).
@(private = "file")
doc_tree_update :: proc(app: ^App, pa: ^Page_A11y, d: ^Doc_Tree, t: ^Tab, viewport: [2]f32, origin: [2]f32, chain: []^page.Page, set: a11y.Settings) -> bool {
	p := t.page
	d.seen = pa.round
	f := page.page_forms(p)
	if p.doc == nil || f == nil { return false }
	fc := Frame_Ctx{parent = p}
	focus := base.NIL_HANDLE
	if forms_view(app).page_focus {
		for doc, i in chain {
			if doc != p { continue }
			focus = i + 1 < len(chain) ? frame_element(p, chain[i + 1]) : f.focus
		}
	}
	title := t.title
	if t.frame != nil { title = document_title(p.doc) }
	v := a11y.View{
		src = {doc = p.doc, styled = p.styled, forms = f},
		layout = &t.layout, viewport = viewport, doc_scroll = t.scroll, origin = origin,
		focus = focus, title = title, url = t.frame != nil ? p.env.location.href : t.url,
		max_nodes = set.max_nodes,
	}
	if set.frames { v.frame_tree, v.frame_user = frame_tree_of, &fc }
	d.live.hashes = set.verify
	whole := a11y.live_update(&d.live, &v, &d.full, set.incremental && d.sent)
	d.full.tree = d.tree
	if whole { pa.builds += 1 } else if len(d.full.nodes) > 0 { pa.patches += 1 }
	if set.verify && !whole {
		if diff := a11y.live_verify(&d.live, &v); diff != "" {
			pa.verify_failed += 1
			delete(pa.verify_diff)
			pa.verify_diff = strings.clone(diff)
			page.log(p, .Warn, fmt.tprintf("accessibility.page.verify: an update differs from a whole tree: %s", diff))
			a11y.live_reset(&d.live)
		}
	}
	out := whole ? platform.a11y_diff(&d.diff, &d.full, all = !d.sent) : platform.a11y_diff_patch(&d.diff, &d.full)
	if len(out.nodes) == 0 && out.focus == d.focus { return d.sent }
	switch platform.a11y_send(active_window(app).win, out, "gui_toolkit", ui.VERSION) {
	case .Applied:
		d.sent, d.focus = true, out.focus
		pa.sends += 1
		return true
	case .Invalid:
		pa.refused += 1
		page.log(p, .Warn, fmt.tprintf("accessibility: the adapter refused an update of %d nodes (%s)", len(out.nodes), whole ? "whole" : "patch"))
		fallthrough
	case .Inactive, .Failed:
		d.sent = false
		platform.a11y_diff_reset(&d.diff)
		a11y.live_reset(&d.live)
	}
	return false
}

// The frames of `t`'s document (and theirs), each tree after its parent's.
@(private = "file")
frames_update :: proc(app: ^App, pa: ^Page_A11y, parent: ^Doc_Tree, t: ^Tab, viewport: [2]f32, chain: []^page.Page, set: a11y.Settings) {
	p := t.page
	if p == nil || p.frames == nil || !t.layout.valid { return }
	for n in page.frames_children(p) {
		if n.page == nil { continue }
		fv := frame_view_of(n.page)
		if fv == nil || !fv.ready || !fv.tab.layout.valid { continue }
		// the frame's content box in its parent's document coordinates (the parent's transform does the rest)
		// (only under a graft node the adapter has: an element hidden from the tree grafts nothing)
		if er, has := parent.live.recs[u64(n.element)]; !has || !er.graft { continue }
		r, ok := lay.box_of(&t.layout, n.element, viewport, 0)
		if !ok { continue }
		d := frame_doc_tree(pa, n.page, fv)
		if doc_tree_update(app, pa, d, &fv.tab, fv.size, r.content.min, chain, set) {
			frames_update(app, pa, d, &fv.tab, fv.size, chain, set)
		}
	}
}

@(private = "file")
frame_doc_tree :: proc(pa: ^Page_A11y, p: ^page.Page, fv: ^Frame_View) -> ^Doc_Tree {
	tree := page_tree_id(fv.tab.id)
	for d in pa.frames { if d.page == p && d.tree == tree { d.tab = &fv.tab; return d } }
	d := new(Doc_Tree)
	d.page, d.tab, d.tree = p, &fv.tab, tree
	append(&pa.frames, d)
	return d
}

// The text of a document's <title> (a frame's document names its tree with it).
@(private = "file")
document_title :: proc(d: ^dom.Document) -> string {
	for cur := dom.next_in_tree(d, d.root, d.root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, d.root) {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { continue }
		if n.name == "body" { break }
		if n.name == "title" { return strings.trim_space(dom.text_content(d, cur)) }
	}
	return ""
}

// What `wren ctl stats` says of window `wnd`'s page trees.
page_a11y_stats :: proc(wnd: ^Browser_Window) -> (s: Page_A11y_Stats) {
	pa := &wnd.own.a11y
	s.builds, s.patches, s.sends, s.refused, s.verify_failed = pa.builds, pa.patches, pa.sends, pa.refused, pa.verify_failed
	s.frames = len(pa.frames)
	s.verify_diff = pa.verify_diff
	if pa.top != nil {
		s.nodes = len(pa.top.live.recs)
		s.written = pa.top.live.written
		s.fallback = pa.top.live.fallback
	}
	return
}

// A request of a screen reader for a node of a document (a tab's or a frame's): what the user would do.
@(private = "file")
page_a11y_request :: proc(app: ^App, t: ^Tab, p: ^page.Page, r: platform.A11y_Request) {
	wnd := active_window(app)
	f := page.page_forms(p)
	h := base.Handle(r.target)
	if h == base.NIL_HANDLE || p.doc == nil || f == nil { return }
	if r.target == u64(p.doc.root) && r.action != .Scroll_Into_View { return }
	#partial switch r.action {
	case .Click, .Expand, .Collapse:
		scroll_into_view(app, t, h)
		page.click_element(p, h)
	case .Focus:
		if forms.focus(f, h, by_keyboard = true) {
			forms_view(app).page_focus = true
			window_own(app).frames.focus = t.frame != nil ? p : nil
			ui.set_focus(0)
			scroll_into_view(app, t, h)
		}
	case .Blur:
		forms.blur_element(f, h)
	case .Scroll_Into_View:
		scroll_into_view(app, t, h)
	case .Set_Value, .Replace_Selected_Text:
		if r.data == .Value {
			forms.set_value(f, h, r.value, by_user = true)
		} else if r.data == .Numeric_Value {
			forms.set_value(f, h, fmt.tprintf("%v", r.num), by_user = true)
		}
	case .Set_Text_Selection:
		page_a11y_select_text(f, p, h, r)
	case .Increment, .Decrement:
		// a range or number input: one step (stepUp / stepDown, firing input and change as the arrow keys do)
		forms.step(f, h, r.action == .Increment ? 1 : -1, by_user = true)
	case .Scroll_Down, .Scroll_Up:
		page_h := t.frame != nil ? t.frame.size.y : wnd.page_rect.max.y - wnd.page_rect.min.y
		amount := (r.data == .Scroll_Unit && r.num == 1) ? page_h * 0.9 : 60
		t.scroll = max(t.scroll + (r.action == .Scroll_Down ? amount : -amount), 0)
	}
	request_frames(app, 2)
}

// Set_Text_Selection on a text field: anchor and focus are characters of its text run.
@(private = "file")
page_a11y_select_text :: proc(f: ^forms.Forms, p: ^page.Page, h: base.Handle, r: platform.A11y_Request) {
	if r.data != .Text_Selection { return }
	// (the request names the field, or its run)
	field := h
	if dom.get(p.doc, field) == nil { field = base.Handle(a11y.run_owner(r.target)) }
	if dom.get(p.doc, field) == nil || !forms.selection_applies(f, field) { return }
	text := forms.value(f, field)
	a := a11y.char_to_byte(text, int(r.sel[1]))
	b := a11y.char_to_byte(text, int(r.sel[3]))
	dir := forms.Direction.Forward
	if b < a { a, b = b, a; dir = .Backward }
	forms.set_selection(f, field, a, b, dir)
}

package page

// Where the history puts the view (HTML "scroll to the fragment", "restore persisted state", the Navigation API's
// "process scroll behavior"). The page does it itself, at once, from its layout as its scripts read it (js_layout_now),
// whoever lays it out (the shell, the WPT runner's headless host):
//   * a fragment navigation scrolls to the indicated part of the document (an element of that id, an <a> of that name,
//     the top) and makes it the target element (:target); a new document does it once laid out, when its embedder asks
//     (scroll_to_fragment: the shell, at its first layout, unless it restores the entry);
//   * leaving an entry for another of the same document saves the scroll positions in it: the document's and those of the
//     scroll containers that were moved (an embedder with a view of its own saves them itself: Embedder.leaving);
//   * a traversal to an entry of the same document puts them back (none saved: the fragment), unless the entry's
//     history.scrollRestoration is "manual" or a navigate listener intercepted the traversal;
//   * an intercepted navigation scrolls when its handlers are done, or when the page calls event.scroll()
//     (Navigation_scroll): a traversal puts the entry's positions back unless the document was scrolled since its
//     navigate event, anything else goes to the fragment, else to the top.

import "wb:base"
import "wb:dom"
import "wb:style"
import "wb:url"

// HTML "select the indicated part": an element whose id is the fragment, else the first <a> whose name is; again with
// the fragment percent-decoded; "top" (in any case) or an empty fragment is the top of the document. No fragment, or one
// that names nothing: NIL and not `top`.
indicated_part :: proc(p: ^Page) -> (el: base.Handle, top: bool) {
	loc := p.env.location
	if !loc.has_fragment { return base.NIL_HANDLE, false }
	if loc.fragment == "" { return base.NIL_HANDLE, true }
	if h := potential_indicated(p.doc, loc.fragment); h != base.NIL_HANDLE { return h, false }
	decoded := url.percent_decode(loc.fragment)
	if h := potential_indicated(p.doc, decoded); h != base.NIL_HANDLE { return h, false }
	return base.NIL_HANDLE, base.ascii_equal_fold(decoded, "top")
}

@(private = "file")
potential_indicated :: proc(d: ^dom.Document, name: string) -> base.Handle {
	if h := dom.find_by_id(d, name); h != base.NIL_HANDLE { return h }
	for cur := d.root; cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, d.root) {
		n := dom.get(d, cur)
		if n.kind != .Element || n.ns != .HTML || n.name != "a" { continue }
		if v, ok := dom.get_attribute(d, cur, "name"); ok && v == name { return cur }
	}
	return base.NIL_HANDLE
}

// The target element (:target) is the indicated part of the document's URL, or none.
target_from_url :: proc(p: ^Page) {
	el, _ := indicated_part(p)
	target_set(p, el)
}

@(private = "file")
target_set :: proc(p: ^Page, el: base.Handle) {
	id := ""
	if el != base.NIL_HANDLE { id, _ = dom.get_attribute(p.doc, el, "id") }   // (:target matches by id: an <a name> without one matches nothing)
	st := p.style_state
	st.target_id = id
	set_style_state(p, st)
}

// HTML "scroll to the fragment": the indicated part becomes the target element and comes into view (its start at the
// top of what shows it, nearest edge across); the top of the document: the beginning. Nothing indicated: no target, no
// scrolling, unless `to_top` (the Navigation API's push, replace and reload: the beginning of the document). `animate`:
// as the document's scroll-behavior says (a new document jumps).
scroll_to_fragment :: proc(p: ^Page, to_top := false, animate := true) {
	passage, has_passage := text_directive_apply(p)
	el, top := indicated_part(p)
	target_set(p, el)
	smooth := animate && smooth_scrolling(p)
	if has_passage {
		// (the element that holds the text: what a text directive shows, whatever else the URL says)
		holder := passage.node
		if n := dom.get(p.doc, holder); n != nil && n.kind == .Text { holder = n.parent }
		scroll_into_view(p, holder, .Center, .Nearest, smooth)
	} else if el != base.NIL_HANDLE {
		scroll_into_view(p, el, .Start, .Nearest, smooth)
	} else if top || to_top {
		js_layout_now(p)   // (the range the document scrolls in is the one it has now)
		scroll_document_to(p, 0, 0, smooth)
	}
}

// The document's computed scroll-behavior is smooth (CSSOM View: that of the root element), and the preferences let it.
@(private = "file")
smooth_scrolling :: proc(p: ^Page) -> bool {
	if p.styled == nil || !p.settings.web.fragment_smooth { return false }
	cs := style.style_of(p.styled, jd_document_element(p.doc))
	return cs != nil && cs.scroll_behavior == .Smooth
}

// The scroll positions of the document and of the scroll containers that were moved, into `e` (CSS px).
@(private)
persisted_capture_scroll :: proc(p: ^Page, e: ^History_Entry) {
	jl := &js_dom_state(p).layout
	if !jl.has { return }
	vp := jl.embedder.viewport(jl.embedder.user, p)
	if vp.scale <= 0 { vp.scale = 1 }
	ps := &e.persisted
	persisted_clear(ps)
	ps.saved = true
	ps.scroll = {f32(vp.scroll_x), f32(vp.scroll_y)}
	l := jl.result
	if l == nil || !l.valid { return }
	for node, off in l.scroll {
		if off == {} { continue }
		if path := element_path(p.doc, node); path != "" { persisted_add_container(ps, path, off / f32(vp.scale)) }
	}
}

// The scroll positions saved in `e` come back.
@(private)
persisted_restore_scroll :: proc(p: ^Page, e: ^History_Entry) {
	ps := &e.persisted
	js_layout_now(p)
	scroll_document_to(p, f64(ps.scroll.x), f64(ps.scroll.y))
	for c in ps.containers {
		if h := element_from_path(p.doc, c.path); h != base.NIL_HANDLE { scroll_element_to(p, h, f64(c.pos.x), f64(c.pos.y)) }
	}
}

// A traversal reached `e`, an entry of this document: its target element, and its scroll positions unless the traversal
// was intercepted (the Navigation API scrolls then) or the entry leaves them to the page.
@(private)
traversal_scroll :: proc(p: ^Page, e: ^History_Entry, intercepted: bool) {
	target_from_url(p)
	if intercepted || e.scroll_manual { return }
	if e.persisted.saved { persisted_restore_scroll(p, e) } else { scroll_to_fragment(p) }
}

// The document's scroll position now, CSS px (0, 0 without a layout).
@(private)
document_scroll :: proc(p: ^Page) -> [2]f64 {
	jl := &js_dom_state(p).layout
	if !jl.has { return {} }
	vp := jl.embedder.viewport(jl.embedder.user, p)
	return {vp.scroll_x, vp.scroll_y}
}

// The scroll of an intercepted navigation of `type` (Nav_Type), after its handlers or at event.scroll(). A traversal
// restores the entry's positions (whatever history.scrollRestoration says), unless the document was scrolled since its
// navigate event fired; a push, a replace or a reload goes to the fragment, else to the top.
Navigation_scroll :: proc(c: ^Call, type: i32) {
	p := c.page
	if p.web == nil { return }
	if Nav_Type(type) != .Traverse {
		scroll_to_fragment(p, to_top = true)
		return
	}
	cur := session_current(p.web.session)
	if cur == nil || !cur.persisted.saved || document_scroll(p) != p.web.nav_scrolled_from { return }
	persisted_restore_scroll(p, cur)
}

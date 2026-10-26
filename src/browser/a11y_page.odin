package browser

import "core:fmt"
import "core:hash"
import "core:mem"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:a11y"
import "wb:base"
import "wb:forms"
import "wb:page"

// The accessibility tree of the current page (src/a11y): a tree of its own, grafted under the page area of the chrome's
// tree (A11y_Info.graft), sent after the chrome's (the graft node must be there first). It is made again only when what
// it reads changed (the document, the forms, the layout's size and scroll, the focus, the title), and only the nodes that
// changed go to the adapter (platform.A11y_Diff). Requests of screen readers for its nodes (click, focus, set a value,
// scroll into view) act on the page as the user would.

@(private = "file")
Page_Tree :: struct {
	tab_id: u64,
	tree:   platform.A11y_Tree_Id,
	full:   platform.A11y_Update,
	diff:   platform.A11y_Diff,
	sig:    u64,
	sent:   bool,
	focus:  u64,
}

@(private = "file")
pa: struct {
	cur:      Page_Tree,   // the current tab's (one at a time: the chrome grafts the current page only)
	grafted:  u64,         // the tab whose tree the chrome's build grafted (0: none this build)
	builds, sends, refused: int,
}

a11y_page_destroy :: proc() {
	platform.a11y_update_destroy(&pa.cur.full)
	platform.a11y_diff_destroy(&pa.cur.diff)
	pa = {}
}

// The tree id of tab `id`'s page (not zero: zero is the window's own tree).
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
	ui.a11y_set(pb, {graft = page_tree_id(t.id)})
	pa.grafted = t.id
	if forms_view(app).page_focus && ui.focus_key() == 0 { ui.a11y_focus_on(pb.key) }
}

// After the chrome's build (its tree sent): the page's requests, then its tree when it changed.
page_a11y_frame :: proc(app: ^App) {
	grafted := pa.grafted
	pa.grafted = 0
	t := current_tab(app)
	if !ui.a11y_active(app.ui_state) || t == nil || grafted != t.id {
		// no graft this build (no reader, no page, another view): the adapter dropped the page's tree with it
		pa.cur.sent = false
		return
	}
	if t.page == nil || t.kind != .Web || t.page.formctl == nil { return }
	p := t.page
	f := page.page_forms(p)
	tree := page_tree_id(t.id)
	for r in ui.a11y_requests() {
		if r.tree == tree { page_a11y_request(app, t, p, f, r) }
	}

	st := &pa.cur
	if st.tab_id != t.id {
		// another page under the graft: its tree is new to the adapter
		st.tab_id, st.tree, st.sent, st.sig = t.id, tree, false, 0
		platform.a11y_diff_reset(&st.diff)
	}
	size := draw.rect_size(app.page_rect)
	sig := page_a11y_signature(app, t, p, f, size)
	if st.sent && sig == st.sig { return }

	platform.a11y_update_clear(&st.full)
	v := a11y.View{
		src = {doc = p.doc, styled = p.styled, forms = f},
		layout = &t.layout, viewport = size, doc_scroll = t.scroll, origin = app.page_rect.min,
		focus = forms_view(app).page_focus ? f.focus : base.NIL_HANDLE, title = t.title, url = t.url,
		max_nodes = 50_000,
	}
	a11y.build(&v, &st.full)
	st.full.tree = tree
	pa.builds += 1
	out := platform.a11y_diff(&st.diff, &st.full, all = !st.sent)
	if len(out.nodes) == 0 && out.focus == st.focus { st.sig = sig; return }
	switch platform.a11y_send(app.win, out, "gui_toolkit", ui.VERSION) {
	case .Applied:
		st.sent, st.sig, st.focus = true, sig, out.focus
		pa.sends += 1
	case .Invalid:
		pa.refused += 1
		st.sent = false
		platform.a11y_diff_reset(&st.diff)
	case .Inactive, .Failed:
		st.sent = false
		platform.a11y_diff_reset(&st.diff)
	}
}

// Builds of the page's tree, updates sent, updates refused (wren ctl stats).
page_a11y_stats :: proc() -> (builds, sends, refused, nodes: int) {
	return pa.builds, pa.sends, pa.refused, len(pa.cur.full.nodes)
}

// What the page's tree is made from, in one number: when it holds, the tree would be the same.
@(private = "file")
page_a11y_signature :: proc(app: ^App, t: ^Tab, p: ^page.Page, f: ^forms.Forms, size: [2]f32) -> u64 {
	Sig :: struct {
		mutations, tree_v, attr_v, forms_serial: u64,
		layout_mut: u64,
		focus: base.Handle,
		page_focus: bool,
		scroll: f32,
		rect: draw.Rect,
		title_hash, url_hash: u64,
	}
	s := Sig{
		mutations = p.doc.mutations, tree_v = p.doc.tree_version, attr_v = p.doc.attr_version, forms_serial = f.serial,
		layout_mut = u64(t.layout.mutations), focus = f.focus, page_focus = forms_view(app).page_focus, scroll = t.scroll,
		rect = app.page_rect, title_hash = hash.fnv64a(transmute([]u8)t.title), url_hash = hash.fnv64a(transmute([]u8)t.url),
	}
	_ = size
	return hash.fnv64a(mem.ptr_to_bytes(&s))
}

// A request of a screen reader for a node of the page: what the user would do.
@(private = "file")
page_a11y_request :: proc(app: ^App, t: ^Tab, p: ^page.Page, f: ^forms.Forms, r: platform.A11y_Request) {
	h := base.Handle(r.target)
	if h == base.NIL_HANDLE || p.doc == nil { return }
	if r.target == u64(p.doc.root) && r.action != .Scroll_Into_View { return }
	#partial switch r.action {
	case .Click, .Expand, .Collapse:
		scroll_into_view(app, t, h)
		page.click_element(p, h)
	case .Focus:
		if forms.focus(f, h, by_keyboard = true) {
			forms_view(app).page_focus = true
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
	case .Increment, .Decrement:
		// a range or number input: one step (stepUp / stepDown, firing input and change as the arrow keys do)
		forms.step(f, h, r.action == .Increment ? 1 : -1, by_user = true)
	case .Scroll_Down, .Scroll_Up:
		page_h := app.page_rect.max.y - app.page_rect.min.y
		amount := (r.data == .Scroll_Unit && r.num == 1) ? page_h * 0.9 : 60
		t.scroll = max(t.scroll + (r.action == .Scroll_Down ? amount : -amount), 0)
	}
	app.frames_requested = max(app.frames_requested, 2)
}

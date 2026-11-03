package style

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:html"

// The weights the style threads share the work by, on a page with shadow trees: each element's flat subtree (its shadow
// tree's content in place of its children, a slot's assigned nodes in place of its fallback), against a count made by
// recursion over the flat tree.
@(test)
flat_sizes_of_the_flat_tree :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	src := `<!doctype html><body><div id=host><template shadowrootmode=open><section><slot name=a><i>fallback</i><i></i></slot><p><b></b></p></section><slot><u>fallback</u></slot></template><em slot=a><b></b></em><em slot=a></em><span>default</span><span><b><i></i></b></span>text</div><ul><li><a></a></li><li></li></ul></body>`
	html.parse_into(doc, doc.root, transmute([]byte)src, 100_000)
	testing.expect(t, dom.has_shadow_trees(doc), "the page has a shadow tree")
	count :: proc(doc: ^dom.Document, h: base.Handle) -> i32 {
		n: i32 = 1
		for ch := dom.flat_first_child(doc, h); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
			if nd := dom.get(doc, ch); nd != nil && nd.kind == .Element { n += count(doc, ch) }
		}
		return n
	}
	sizes := flat_sizes(doc)
	checked := 0
	it: u32
	for h, nd in base.pool_next(&doc.nodes, &it) {
		in_flat := nd.parent == doc.root || dom.flat_parent(doc, h) != base.NIL_HANDLE
		if nd.kind != .Element || !in_flat || !dom.is_connected(doc, h) { continue }
		testing.expectf(t, sizes[base.handle_index(h)] == count(doc, h), "<%s>: %d, the flat tree holds %d", nd.name, sizes[base.handle_index(h)], count(doc, h))
		checked += 1
	}
	testing.expect(t, checked > 10)
	// the host, section, the slot a with its two <em> and the <b> of one, p, b, the default slot with its two <span>, b, i
	testing.expect_value(t, sizes[base.handle_index(dom.find_by_id(doc, "host"))], 13)
}

// A pass recycled by the engine hands its slots to a later one: their room is kept, the new pass sees none of the old
// records, and its styles are those of a pass of an engine that never recycled one.
@(test)
recycled_pass_slots :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	src := `<!doctype html><style>p { color: rgb(1 2 3) } .x { margin-left: 7px } div > p:nth-child(2) { color: rgb(9 9 9) }</style><body><div id=d><p>a</p><p class=x>b</p><p>c</p></div><div id=gone><p>d</p><p>e</p></div></body>`
	html.parse_into(doc, doc.root, transmute([]byte)src, 100_000)
	ss := settings_default()
	defer settings_destroy(&ss)
	e := engine_make(ss)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)

	// new elements, made before the first pass (the slots are as many as the document's nodes) and inserted after it
	d := dom.find_by_id(doc, "d")
	news: [4]base.Handle
	for &p in news {
		p = dom.create_element(doc, "p")
		dom.set_attribute(doc, p, "class", "x")
	}
	first := compute_styles(e, doc, {}, pool, 0)
	gone := dom.find_by_id(doc, "gone")
	gone_p := dom.get(doc, gone).first_child
	slots := raw_data(first.by_node)
	styled_recycle(e, first)
	testing.expect(t, raw_data(e.spare_by_node) == slots && len(e.spare_by_node) == 0, "the slots are kept, empty")

	// elements go, others come
	dom.remove_child(doc, dom.get(doc, gone).parent, gone)
	for p in news { dom.append_child(doc, d, p) }
	second := compute_styles(e, doc, {}, pool, 0)
	defer styled_destroy(second)
	testing.expect(t, raw_data(second.by_node) == slots, "the next pass took them")
	testing.expect(t, e.spare_by_node == nil)
	testing.expect(t, style_of(second, gone) == nil && style_of(second, gone_p) == nil, "no record of an element out of the document")

	other := engine_make(ss)
	defer engine_destroy(other)
	sync_document_sheets(other, doc, "about:test")
	fresh := compute_styles(other, doc, {})
	defer styled_destroy(fresh)
	differ, styled := 0, 0
	it: u32
	for h, nd in base.pool_next(&doc.nodes, &it) {
		if nd.kind != .Element { continue }
		a, b := style_of(second, h), style_of(fresh, h)
		if (a == nil) != (b == nil) || (a != nil && !computed_equal(a, b)) { differ += 1 }
		if a != nil { styled += 1 }
	}
	testing.expectf(t, differ == 0, "%d elements differ from a pass of an engine that recycled none", differ)
	testing.expect(t, styled >= 10)
}

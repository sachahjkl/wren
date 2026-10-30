package style

import "core:fmt"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"

@(private = "file")
PARALLEL_CSS :: `
:root { --gap: 3px; --c: rgb(10 20 30) }
body { margin: 0; font-size: 15px }
section { padding: var(--gap); border: 1px solid #ccc }
section:nth-child(3n+1) > p { color: var(--c) }
section:nth-child(even) { --c: #a50; font-size: 1.1em }
p + p { margin-top: 2px }
p ~ span { text-decoration: underline }
.k3 b, .k5 b { font-weight: bold; width: 10vw }
[data-x="7"] { background: #eee }
section:has(> i) { outline: 2px solid red }
b::before { content: "[" ; color: green }
b::after { content: "]" }
@media (min-width: 600px) { p { line-height: 1.5 } }
body { counter-reset: sec }
section { counter-increment: sec }
span::before { content: "S" counter(sec) "." counters(list-item, "-") " " open-quote }
span::after { content: close-quote }
ol { list-style-type: upper-roman }
`

// A page is rarely balanced: nearly everything under one chain of containers, a few small things beside it. The work is shared by
// the weight of the subtrees (flat_sizes), not by how deep the tree was opened: several threads get a part, the result is the same.
@(test)
parallel_pass_shares_a_lopsided_tree :: proc(t: ^testing.T) {
	settings := settings_default()
	defer settings_destroy(&settings)
	e := engine_make(settings)
	defer engine_destroy(e)
	doc := dom.document_create()
	defer dom.document_destroy(doc)

	html := dom.create_element(doc, "html")
	dom.append_child(doc, doc.root, html)
	head := dom.create_element(doc, "head")
	dom.append_child(doc, html, head)
	st := dom.create_element(doc, "style")
	dom.append_child(doc, head, st)
	dom.set_text_content(doc, st, PARALLEL_CSS)
	body := dom.create_element(doc, "body")
	dom.append_child(doc, html, body)
	header := dom.create_element(doc, "header")
	dom.append_child(doc, body, header)
	for _ in 0 ..< 3 { dom.append_child(doc, header, dom.create_element(doc, "p")) }
	holder := body
	for _ in 0 ..< 10 {   // ten containers, one in the other: every level has the whole page under its only child
		d := dom.create_element(doc, "div")
		dom.append_child(doc, holder, d)
		holder = d
	}
	for i in 0 ..< 400 {
		sec := dom.create_element(doc, "section")
		dom.set_attribute(doc, sec, "class", fmt.tprintf("k%d", i % 7))
		dom.append_child(doc, holder, sec)
		for k in 0 ..< 3 {
			p := dom.create_element(doc, "p")
			dom.set_attribute(doc, p, "data-x", fmt.tprintf("%d", (i + k) % 9))
			dom.append_child(doc, sec, p)
			dom.append_child(doc, p, dom.create_element(doc, "b"))
		}
	}
	sync_document_sheets(e, doc, "http://x.test/")

	sizes := flat_sizes(doc)
	testing.expect_value(t, int(sizes[base.handle_index(html)]), 1 + 1 + 1 + 1 + 1 + 3 + 10 + 400 * 7)   // html, head, style, body, header + 3 p, the divs, the sections
	testing.expect_value(t, int(sizes[base.handle_index(header)]), 4)

	seq := compute_styles(e, doc, {})
	defer styled_destroy(seq)
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)
	par := compute_styles(e, doc, {}, pool, 0)
	defer styled_destroy(par)
	testing.expect(t, len(par.thread_arenas) > 1, "the page was shared out, not run as one task")
	differ := 0
	it: u32
	for h, n in base.pool_next(&doc.nodes, &it) {
		if n.kind == .Element && !computed_equal(style_of(seq, h), style_of(par, h)) { differ += 1 }
	}
	testing.expectf(t, differ == 0, "%d elements differ", differ)
}

// The same document styled on one thread and on four: every computed style must be equal.
@(test)
parallel_pass_gives_the_sequential_result :: proc(t: ^testing.T) {
	settings := settings_default()
	defer settings_destroy(&settings)
	e := engine_make(settings)
	defer engine_destroy(e)
	doc := dom.document_create()
	defer dom.document_destroy(doc)

	html := dom.create_element(doc, "html")
	dom.append_child(doc, doc.root, html)
	head := dom.create_element(doc, "head")
	dom.append_child(doc, html, head)
	st := dom.create_element(doc, "style")
	dom.append_child(doc, head, st)
	dom.set_text_content(doc, st, PARALLEL_CSS)
	body := dom.create_element(doc, "body")
	dom.append_child(doc, html, body)
	for i in 0 ..< 600 {
		sec := dom.create_element(doc, "section")
		dom.set_attribute(doc, sec, "class", fmt.tprintf("k%d", i % 7))
		if i % 11 == 0 { dom.set_attribute(doc, sec, "style", fmt.tprintf("margin-left: %dvw; --gap: %dpx", i % 5, i % 4)) }
		dom.append_child(doc, body, sec)
		for k in 0 ..< 3 {
			p := dom.create_element(doc, "p")
			dom.set_attribute(doc, p, "data-x", fmt.tprintf("%d", (i + k) % 9))
			dom.append_child(doc, sec, p)
			b := dom.create_element(doc, "b")
			dom.append_child(doc, p, b)
			dom.append_child(doc, b, dom.create_text(doc, "text"))
		}
		dom.append_child(doc, sec, dom.create_element(doc, "span"))
		if i % 3 == 0 {
			// lists: the counters of a parallel pass are resolved by the ordered walk afterwards
			ol := dom.create_element(doc, "ol")
			if i % 2 == 0 { dom.set_attribute(doc, ol, "start", "4") }
			dom.append_child(doc, sec, ol)
			for _ in 0 ..< 3 {
				li := dom.create_element(doc, "li")
				dom.append_child(doc, ol, li)
				dom.append_child(doc, li, dom.create_element(doc, "span"))
			}
		}
		if i % 13 == 0 { dom.append_child(doc, sec, dom.create_element(doc, "i")) }
	}
	sync_document_sheets(e, doc, "http://x.test/")

	seq := compute_styles(e, doc, {})
	defer styled_destroy(seq)
	seq_vw, seq_ignored := e.viewport_units, e.ignored_properties

	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)
	for round in 0 ..< 3 {
		e.viewport_units, e.ignored_properties = false, 0
		par := compute_styles(e, doc, {}, pool, 0)
		defer styled_destroy(par)
		testing.expect(t, len(par.thread_arenas) > 0, "the pass really ran on several threads")
		testing.expect_value(t, par.root_font_size, seq.root_font_size)
		testing.expect_value(t, e.viewport_units, seq_vw)
		testing.expect_value(t, e.ignored_properties, seq_ignored)
		elements, differ := 0, 0
		it: u32
		for h, n in base.pool_next(&doc.nodes, &it) {
			if n.kind != .Element { continue }
			elements += 1
			if !computed_equal(style_of(seq, h), style_of(par, h)) { differ += 1 }
		}
		testing.expectf(t, differ == 0, "round %d: %d of %d elements differ", round, differ, elements)
		testing.expect(t, elements > 4000)
	}
}

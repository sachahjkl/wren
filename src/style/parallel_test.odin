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
`

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

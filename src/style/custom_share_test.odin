package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"

// What a Tailwind 4 page does: a universal rule declares ~100 custom properties on every element.
TW_VARS :: #config(TW_VARS, 100)

@(private = "file")
tailwind_like_css :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ":root { --brand: #123456 }\n*, ::before, ::after {")
	for i in 0 ..< TW_VARS { fmt.sbprintf(&b, " --tw-v%d: initial;", i) }
	strings.write_string(&b, " }\n.ring { --tw-v7: 3px; outline-width: var(--tw-v7, 1px) }\n")
	strings.write_string(&b, "p { color: var(--brand); margin-top: var(--tw-v3, 2px) }\n")
	return strings.to_string(b)
}

@(private = "file")
Tw_Nodes :: struct { ring_sec, ring_div, ring_p, plain_div, plain_p: base.Handle }

@(private = "file")
tailwind_like_doc :: proc(doc: ^dom.Document, sections: int) -> (n: Tw_Nodes) {
	html := dom.create_element(doc, "html")
	dom.append_child(doc, doc.root, html)
	head := dom.create_element(doc, "head")
	dom.append_child(doc, html, head)
	st := dom.create_element(doc, "style")
	dom.append_child(doc, head, st)
	dom.set_text_content(doc, st, tailwind_like_css())
	body := dom.create_element(doc, "body")
	dom.append_child(doc, html, body)
	for i in 0 ..< sections {
		sec := dom.create_element(doc, "section")
		if i % 10 == 0 { dom.set_attribute(doc, sec, "class", "ring") }
		dom.append_child(doc, body, sec)
		for _ in 0 ..< 4 {
			d := dom.create_element(doc, "div")
			dom.append_child(doc, sec, d)
			p := dom.create_element(doc, "p")
			dom.append_child(doc, d, p)
			dom.append_child(doc, p, dom.create_text(doc, "text"))
			if i == 0 { n.ring_sec, n.ring_div, n.ring_p = sec, d, p }
			if i == 1 { n.plain_div, n.plain_p = d, p }
		}
	}
	return
}

// An element whose declared custom properties all end as its parent has them shares the parent's table; one whose
// values differ gets its own, with the right values.
@(test)
custom_properties_shared_when_unchanged :: proc(t: ^testing.T) {
	settings := settings_default()
	defer settings_destroy(&settings)
	e := engine_make(settings)
	defer engine_destroy(e)
	doc := dom.document_create()
	defer dom.document_destroy(doc)
	n := tailwind_like_doc(doc, 20)
	sync_document_sheets(e, doc, "http://x.test/")
	s := compute_styles(e, doc, {})
	defer styled_destroy(s)

	p := style_of(s, n.plain_p)
	div := style_of(s, n.plain_div)
	testing.expect(t, p.custom == div.custom, "a universal reset that changes nothing shares the parent's table")
	brand, _ := custom_get(p.custom, "--brand")
	testing.expect_value(t, brand, "#123456")
	has := custom_has(p.custom, "--tw-v3")
	testing.expect(t, !has, "initial: the guaranteed-invalid value")

	ring := style_of(s, n.ring_sec)
	v7, _ := custom_get(ring.custom, "--tw-v7")
	testing.expect_value(t, v7, "3px")
	// its children reset --tw-v7 to initial: a value that differs, a table of their own without it
	rd := style_of(s, n.ring_div)
	testing.expect(t, rd.custom != ring.custom, "a value that changes gets its own table")
	testing.expect(t, !custom_has(rd.custom, "--tw-v7"))
	brand2, _ := custom_get(rd.custom, "--brand")
	testing.expect_value(t, brand2, "#123456")
}

// Timing of a full pass over a Tailwind-like page (printed; the test only checks it runs).
@(test)
custom_properties_tailwind_like_pass_time :: proc(t: ^testing.T) {
	settings := settings_default()
	defer settings_destroy(&settings)
	e := engine_make(settings)
	defer engine_destroy(e)
	doc := dom.document_create()
	defer dom.document_destroy(doc)
	tailwind_like_doc(doc, 600)
	sync_document_sheets(e, doc, "http://x.test/")
	best := max(f64)
	for _ in 0 ..< 5 {
		t0 := time.tick_now()
		s := compute_styles(e, doc, {})
		ms := time.duration_milliseconds(time.tick_since(t0))
		styled_destroy(s)
		best = min(best, ms)
	}
	fmt.printfln("STYLE_TAILWIND_PASS_MS %.2f (best of 5, %d elements)", best, 600 * 9 + 4)
	testing.expect(t, best > 0)
}

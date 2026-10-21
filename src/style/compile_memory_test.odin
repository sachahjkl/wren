package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:dom"
import "wb:html"

// Compiled rules keep their declarations, not what validating them needed: two computed styles per rule went to the
// engine's arena (44 MB for a site's 8000 rules). Here 2000 rules of three declarations (one a shorthand) cost 6.4 KiB each before, under 2 KiB now,
// and a style attribute compiled during a pass must not leave computed styles in the pass's memory either.
@(test)
compiled_rules_memory :: proc(t: ^testing.T) {
	RULES :: 2000
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<style>")
	for i in 0 ..< RULES { fmt.sbprintf(&b, ".r%d {{ color: #%06x; margin: %dpx 2px; display: block }}\n", i, i * 97, i % 7) }
	strings.write_string(&b, "</style>")
	for i in 0 ..< 200 { fmt.sbprintf(&b, "<p class=r%d style='padding: %dpx; border: 1px solid red'>x</p>", i, i) }
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)strings.to_string(b), 2_000_000)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	st := compute_styles(e, doc, {})
	defer styled_destroy(st)
	per_rule := f64(e.arena.total_used) / RULES
	testing.expectf(t, per_rule < 2048, "%.0f bytes of compiled rules per rule", per_rule)
	// the rules still apply
	p := dom.find_first_by_tag(doc, "p")
	c := style_of(st, p)
	testing.expect(t, c != nil && c.display == .Block && c.margin[.Top].v == 0 && c.padding[.Left].v == 0)
	per_element := f64(st.arena.total_used) / 200
	testing.expectf(t, per_element < 16 * 1024, "%.0f bytes of computed styles per element with a style attribute", per_element)
}

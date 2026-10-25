package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:dom"
import "wb:html"

@(private = "file")
styled_page :: proc(src: string, max_layers: int) -> (doc: ^dom.Document, eng: ^Engine, st: ^Styled) {
	doc = dom.document_create(nil)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	s.custom_max_layers = max_layers
	eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(eng, doc, "about:test")
	st = compute_styles(eng, doc, {})
	return
}

// Hundreds of variables on :root and a few more set on every level of a deep tree (DuckDuckGo's pages): each element
// keeps a layer of its own names, not a copy of every inherited one, and reads the same values as with copies.
@(test)
custom_properties_layers :: proc(t: ^testing.T) {
	VARS :: 300
	DEPTH :: 40
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<style>:root{")
	for i in 0 ..< VARS { fmt.sbprintf(&b, "--v%d: %dpx;", i, i) }
	strings.write_string(&b, "} div { --depth: attr-less; } .bad { --v7: var(--nope); } .back { --v7: 77px; }")
	strings.write_string(&b, " @property --solo { syntax: '<length>'; inherits: false; initial-value: 0px; } .solo { --solo: 5px; }")
	for i in 0 ..< DEPTH { fmt.sbprintf(&b, " .l%d {{ --depth: %d }}", i, i) }
	strings.write_string(&b, "</style>")
	for i in 0 ..< DEPTH {
		cls := i == 10 ? "bad" : i == 20 ? "back" : i == 30 ? "solo" : ""
		fmt.sbprintf(&b, "<div id=d%d class='l%d %s'>", i, i, cls)
	}
	for _ in 0 ..< DEPTH { strings.write_string(&b, "</div>") }

	for max_layers in ([]int{8, 0}) {
		doc, eng, st := styled_page(strings.to_string(b), max_layers)
		defer { styled_destroy(st); engine_destroy(eng); dom.document_destroy(doc) }
		for i in 0 ..< DEPTH {
			c := style_of(st, dom.find_by_id(doc, fmt.tprintf("d%d", i)))
			testing.expect(t, c != nil && c.custom != nil)
			if c == nil || c.custom == nil { return }
			p := c.custom
			v, ok := custom_get(p, "--depth")
			testing.expectf(t, ok && v == fmt.tprintf("%d", i), "d%d: --depth = %q", i, v)
			v, ok = custom_get(p, "--v299")
			testing.expectf(t, ok && v == "299px", "d%d inherits --v299: %q", i, v)
			// invalid at computed-value time below .bad: absent until .back sets it again
			v, ok = custom_get(p, "--v7")
			if i >= 10 && i < 20 { testing.expectf(t, !ok, "d%d: --v7 is invalid (%q)", i, v) } else {
				testing.expectf(t, ok && v == (i >= 20 ? "77px" : "7px"), "d%d: --v7 = %q", i, v)
			}
			// a registered property that does not inherit: on .solo only
			_, ok = custom_get(p, "--solo")
			testing.expectf(t, ok == (i == 30), "d%d: --solo present %v", i, ok)
			testing.expect_value(t, len(custom_flatten(p, context.temp_allocator)), p.total)
			testing.expect(t, p.depth <= max_layers)
			if max_layers > 0 {
				testing.expectf(t, p.parent == nil || len(p.values) <= 3, "d%d keeps only its own names (%d)", i, len(p.values))
			} else {
				testing.expect(t, p.parent == nil && len(p.values) == p.total)
			}
			// a flat copy has the same values as the layers
			flat := new(Custom_Props, context.temp_allocator)
			flat.values = custom_flatten(p, context.temp_allocator)
			flat.total = len(flat.values)
			testing.expect(t, custom_equal(p, flat) && custom_equal(flat, p))
		}
	}
}

@(test)
custom_properties_layer_edits :: proc(t: ^testing.T) {
	a := context.temp_allocator
	root := custom_begin(nil, 4, a)
	custom_set(root, "--a", "1")
	custom_set(root, "--b", "2")
	testing.expect_value(t, root.total, 2)
	l := custom_begin(root, 4, a)
	custom_remove(l, "--a", a)
	custom_set(l, "--c", "3")
	custom_set(l, "--b", "20")
	testing.expect_value(t, l.total, 2)
	custom_set(l, "--a", "10")   // back after a removal
	testing.expect_value(t, l.total, 3)
	custom_remove(l, "--c", a)
	testing.expect_value(t, l.total, 2)
	custom_remove(l, "--zz", a)   // not there: nothing changes
	testing.expect_value(t, l.total, 2)
	v, ok := custom_get(l, "--a")
	testing.expect(t, ok && v == "10")
	v, ok = custom_get(l, "--b")
	testing.expect(t, ok && v == "20")
	testing.expect(t, !custom_has(l, "--c"))
	other := custom_begin(nil, 4, a)
	custom_set(other, "--b", "20")
	custom_set(other, "--a", "10")
	testing.expect(t, custom_equal(l, other))
	custom_set(other, "--a", "11")
	testing.expect(t, !custom_equal(l, other))
}

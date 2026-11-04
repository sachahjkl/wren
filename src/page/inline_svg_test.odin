package page

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import lay "wb:layout"

// The parts of an inline <svg>'s picture split at its foreign objects: each part's markup has the shapes between two of
// them (in groups too), all of them keep what is referenced (<defs>, gradients), and the whole picture has every shape.
@(test)
inline_svg_parts :: proc(t: ^testing.T) {
	test_pages(t)
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "http://127.0.0.1:8765/t.html")
	defer page_close(p)
	d := p.doc
	el :: proc(d: ^dom.Document, parent: base.Handle, name: string, id := "") -> base.Handle {
		h := dom.create_element(d, name)
		if id != "" { dom.set_attribute(d, h, "id", id) }
		dom.append_child(d, parent, h)
		return h
	}
	svg := el(d, dom.find_first_by_tag(d, "body"), "svg")
	defs := el(d, svg, "defs")
	_ = el(d, defs, "lineargradient", "grad")
	_ = el(d, svg, "rect", "before")
	_ = el(d, svg, "foreignobject")
	g := el(d, svg, "g", "group")
	_ = el(d, g, "circle", "between")
	_ = el(d, g, "foreignobject")
	_ = el(d, svg, "path", "after")
	has :: proc(markup, id: string) -> bool { return strings.contains(markup, strings.concatenate({`id="`, id, `"`}, context.temp_allocator)) }
	all, ok := svg_serialize(p, svg, 10, 10)
	testing.expect(t, ok && has(all, "before") && has(all, "between") && has(all, "after"), "the whole picture")
	first, _ := svg_serialize(p, svg, 10, 10, lay.Svg_Parts{0, 1})
	testing.expect(t, has(first, "before") && !has(first, "between") && !has(first, "after") && has(first, "grad"), "before the first foreign object")
	mid, _ := svg_serialize(p, svg, 10, 10, lay.Svg_Parts{1, 2})
	testing.expect(t, !has(mid, "before") && has(mid, "group") && has(mid, "between") && !has(mid, "after") && has(mid, "grad"), "between the two, in the group")
	last, _ := svg_serialize(p, svg, 10, 10, lay.Svg_Parts{2, 0})
	testing.expect(t, !has(last, "before") && !has(last, "between") && has(last, "after"), "after the last, to the end")
}

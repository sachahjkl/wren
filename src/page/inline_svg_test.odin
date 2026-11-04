package page

import "core:strings"
import "core:testing"
import "core:time"
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

@(private = "file") SVG_PIXELS_DEADLINE_S :: 10
@(private = "file") SVG_PIXELS_POLL_MS :: 5
@(private = "file") SVG_PIXELS_SIDE :: 16   // device px, and CSS px at scale 1

// New markup of an inline <svg> (a new colour, as :hover gives currentColor) is rasterised on the decoding threads: every
// frame meanwhile draws the old picture, never nothing, and the new one comes.
@(test)
inline_svg_keeps_its_picture_while_the_new_one_is_made :: proc(t: ^testing.T) {
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
	svg := dom.create_element(d, "svg")
	dom.set_attribute(d, svg, "viewbox", "0 0 16 16")
	dom.append_child(d, dom.find_first_by_tag(d, "body"), svg)
	path := dom.create_element(d, "path")
	dom.set_attribute(d, path, "d", "M0 8h16")
	dom.set_attribute(d, path, "stroke", "red")
	dom.set_attribute(d, path, "stroke-width", "8")
	dom.append_child(d, svg, path)
	// the middle pixel: red (0) or blue (2) the most
	stroke :: proc(fp: Frame_Pixels) -> int {
		px := fp.pixels[fp.height / 2 * fp.stride + fp.width / 2 * 4:][:3]
		return px[0] > px[2] ? 0 : 2
	}
	pixels :: proc(p: ^Page, svg: base.Handle) -> Frame_Pixels {
		return inline_svg_pixels(p, svg, SVG_PIXELS_SIDE, SVG_PIXELS_SIDE, {}, SVG_PIXELS_SIDE, SVG_PIXELS_SIDE, 0, 0)
	}
	start := time.tick_now()
	first := pixels(p, svg)
	for !first.ok && time.duration_seconds(time.tick_since(start)) < SVG_PIXELS_DEADLINE_S {
		host.loop_wait(&loop, SVG_PIXELS_POLL_MS)
		first = pixels(p, svg)
	}
	testing.expect(t, first.ok && stroke(first) == 0, "the first picture is made")
	if !first.ok { return }

	dom.set_attribute(d, path, "stroke", "blue")
	now := pixels(p, svg)
	testing.expect(t, now.ok && now.texture == first.texture, "the old picture is drawn while the new one is made")
	start = time.tick_now()
	for now.ok && now.texture == first.texture && time.duration_seconds(time.tick_since(start)) < SVG_PIXELS_DEADLINE_S {
		host.loop_wait(&loop, SVG_PIXELS_POLL_MS)
		now = pixels(p, svg)
		testing.expect(t, now.ok, "a picture at every frame")
	}
	testing.expect(t, now.ok && now.texture != first.texture && stroke(now) == 2, "the new picture comes")
}

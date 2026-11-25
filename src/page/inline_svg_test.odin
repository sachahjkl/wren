package page

import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import lay "wb:layout"
import "wb:style"

// The parts of an inline <svg>'s picture split at its foreign objects: each part's markup has the shapes between two of
// them (in groups too), all of them keep what is referenced (<defs>, gradients), and the whole picture has every shape.
@(test)
inline_svg_parts :: proc(t: ^testing.T) {
	test_pages(t)
	loop: host.Loop
	host.loop_init(&loop)
	defer test_loop_destroy(&loop)
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
	defer test_loop_destroy(&loop)
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

// Inline <svg> descendants styled and animated with fill-opacity, stroke-width, stroke-dasharray and stroke-dashoffset
// serialize their animated values into the SVG markup and count as seen whenever their enclosing <svg> box is visible.
@(test)
inline_svg_css_animation_serializes_and_is_seen :: proc(t: ^testing.T) {
	test_pages(t)
	loop: host.Loop
	host.loop_init(&loop)
	defer test_loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "http://127.0.0.1:8765/svg_anim.html")
	defer page_close(p)

	html_src := `<!doctype html><style>
		@keyframes dash { to { fill-opacity: 1; stroke-width: 0; stroke-dashoffset: 0; } }
		svg { width: 100px; height: 100px; }
		#p { fill: #ffe475; fill-opacity: 0; stroke: #fafafa; stroke-width: 0.5; stroke-dasharray: 600; stroke-dashoffset: 600; animation: dash 1s linear 1 forwards; }
	</style><svg id="s" viewBox="0 0 100 100"><polygon id="p" points="10,10 90,10 50,90"></polygon></svg>`
	load_html(p, transmute([]byte)html_src)

	svg := dom.find_by_id(p.doc, "s")
	poly := dom.find_by_id(p.doc, "p")
	testing.expect(t, svg != base.NIL_HANDLE && poly != base.NIL_HANDLE, "svg and polygon exist")
	if svg == base.NIL_HANDLE || poly == base.NIL_HANDLE { return }

	set_frame_time(p, 1000)
	_ = styles(p, 800, 600, 1)
	m0, ok0 := svg_serialize(p, svg, 100, 100)
	testing.expect(t, ok0, "t=0 serializes")
	testing.expectf(t, strings.contains(m0, "fill-opacity:0.000;"), "t=0 has fill-opacity:0 (%s)", m0)
	testing.expectf(t, strings.contains(m0, "stroke-width:0.500;"), "t=0 has stroke-width:0.5 (%s)", m0)
	testing.expectf(t, strings.contains(m0, "stroke-dasharray:600.000;"), "t=0 has stroke-dasharray:600 (%s)", m0)
	testing.expectf(t, strings.contains(m0, "stroke-dashoffset:600.000;"), "t=0 has stroke-dashoffset:600 (%s)", m0)

	// Advance the page animation timeline by 500ms and verify serialized markup updates.
	changed := style.timeline_tick(p.anim.timeline, p.doc, p.styled, 1500)
	testing.expect(t, changed, "animation tick advances SVG polygon styles")
	m500, ok500 := svg_serialize(p, svg, 100, 100)
	testing.expect(t, ok500 && m500 != m0, "t=500ms markup differs from t=0")
	testing.expectf(t, strings.contains(m500, "fill-opacity:0.500;"), "t=500ms has fill-opacity:0.5 (%s)", m500)
	testing.expectf(t, strings.contains(m500, "stroke-dashoffset:300.000;"), "t=500ms has stroke-dashoffset:300 (%s)", m500)
	testing.expectf(t, strings.contains(m500, "stroke-width:0.250;"), "t=500ms has stroke-width:0.25 (%s)", m500)

	// Verify animations_seen treats an SVG descendant as seen when its enclosing <svg> box is in the viewport.
	l: lay.Layout
	defer lay.destroy(&l)
	ls := lay.settings_default()
	lay.run(&l, lay.Input{
		doc = p.doc, styled = p.styled, settings = &ls,
		text = lay.Text_Api{
			font = proc(_: rawptr, _: []string, _: u16, _: bool) -> lay.Font { return 1 },
			width = proc(_: rawptr, _: lay.Font, sz: f32, s: string) -> f32 { return f32(len(s)) * sz * 0.5 },
			metrics = proc(_: rawptr, _: lay.Font, sz: f32) -> lay.Font_Metrics { return {ascent = sz * 0.8, descent = sz * 0.2, x_height = sz * 0.5} },
		},
		viewport = {800, 600}, scale = 1, band_h = 256,
	})
	p.anim.seen = Anim_Seen{ok = true, frame = Obs_Frame{ok = true, l = &l, vp = Viewport{width = 800, height = 600, scale = 1}, view = lay.view_make(&l, {800, 600}, 0, cull = false)}}
	testing.expect(t, animations_seen(p, poly, false), "SVG polygon descendant counts as seen via its enclosing <svg>")

	// Continuous animation ticks while the first decode is in flight must not cancel the decode and starve pixels.
	t_ms: f64 = 1500
	start := time.tick_now()
	fp := inline_svg_pixels(p, svg, 32, 32, {}, 32, 32, 0, 0)
	for !fp.ok && time.duration_seconds(time.tick_since(start)) < SVG_PIXELS_DEADLINE_S {
		t_ms += 16
		_ = style.timeline_tick(p.anim.timeline, p.doc, p.styled, t_ms)
		host.loop_wait(&loop, SVG_PIXELS_POLL_MS)
		fp = inline_svg_pixels(p, svg, 32, 32, {}, 32, 32, 0, 0)
	}
	testing.expect(t, fp.ok, "continuous animation ticks must not starve inline SVG rasterization")
}

// Static inline <svg> elements skip re-serialization when unrelated elements animate, while animating inline <svg>
// elements reuse a single stable texture key and do not accumulate dead single-frame entries in the image cache.
@(test)
inline_svg_skips_static_re_serialize_and_reuses_animated_texture :: proc(t: ^testing.T) {
	test_pages(t)
	loop: host.Loop
	host.loop_init(&loop)
	defer test_loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "http://127.0.0.1:8765/svg_perf.html")
	defer page_close(p)

	html_src := `<!doctype html><style>
		@keyframes twinkle { 0%, 100% { opacity: 1; } 50% { opacity: 0.2; } }
		#r { animation: twinkle 1s linear infinite; }
	</style>
	<svg id="static" viewBox="0 0 16 16"><rect width="16" height="16" fill="#00f"/></svg>
	<svg id="anim" viewBox="0 0 16 16"><rect id="r" width="16" height="16" fill="#f00"/></svg>`
	load_html(p, transmute([]byte)html_src)

	svg_static := dom.find_by_id(p.doc, "static")
	svg_anim := dom.find_by_id(p.doc, "anim")
	testing.expect(t, svg_static != base.NIL_HANDLE && svg_anim != base.NIL_HANDLE, "both svgs exist")
	if svg_static == base.NIL_HANDLE || svg_anim == base.NIL_HANDLE { return }

	set_frame_time(p, 1000)
	_ = styles(p, 800, 600, 1)

	wait_pixels :: proc(loop: ^host.Loop, p: ^Page, h: base.Handle) -> Frame_Pixels {
		start := time.tick_now()
		fp := inline_svg_pixels(p, h, 16, 16, {}, 16, 16, 0, 0)
		for !fp.ok && time.duration_seconds(time.tick_since(start)) < SVG_PIXELS_DEADLINE_S {
			host.loop_wait(loop, SVG_PIXELS_POLL_MS)
			fp = inline_svg_pixels(p, h, 16, 16, {}, 16, 16, 0, 0)
		}
		return fp
	}

	s0 := wait_pixels(&loop, p, svg_static)
	a0 := wait_pixels(&loop, p, svg_anim)
	testing.expect(t, s0.ok && a0.ok, "initial rasters ready")
	if !s0.ok || !a0.ok { return }

	static_rec := p.images.svgs[Svg_Key{svg_static, {}}]
	static_req := static_rec.request
	static_hash := static_rec.hash

	// Advance animation across multiple frames and wait for each animated frame to rasterize.
	base_entries := len(the_pages.image_cache.by_id)
	stable_tex: u64
	gens_seen := 0
	prev_gen := a0.generation
	for step in 1 ..= 6 {
		_ = style.timeline_tick(p.anim.timeline, p.doc, p.styled, 1000 + f64(step) * 80)
		s_now := inline_svg_pixels(p, svg_static, 16, 16, {}, 16, 16, 0, 0)
		testing.expect(t, s_now.ok && s_now.texture == s0.texture, "static svg keeps same texture across unrelated animation ticks")
		testing.expect(t, static_rec.request == static_req && static_rec.hash == static_hash, "static svg request untouched")

		start := time.tick_now()
		a_now := inline_svg_pixels(p, svg_anim, 16, 16, {}, 16, 16, 0, 0)
		for a_now.ok && a_now.generation == prev_gen && time.duration_seconds(time.tick_since(start)) < SVG_PIXELS_DEADLINE_S {
			host.loop_wait(&loop, SVG_PIXELS_POLL_MS)
			a_now = inline_svg_pixels(p, svg_anim, 16, 16, {}, 16, 16, 0, 0)
		}
		if a_now.ok && a_now.generation != prev_gen {
			if stable_tex == 0 {
				stable_tex = a_now.texture
			} else {
				testing.expect_value(t, a_now.texture, stable_tex)
			}
			prev_gen = a_now.generation
			gens_seen += 1
		}
	}
	testing.expectf(t, gens_seen >= 4, "animated svg produced updated generations: %d", gens_seen)
	testing.expectf(t, len(the_pages.image_cache.by_id) <= base_entries + 2, "dead animated svg cache entries did not accumulate: %d (base %d)", len(the_pages.image_cache.by_id), base_entries)
}

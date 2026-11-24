package page

import "core:testing"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

@(test)
image_download_queue_min_heap_ordering :: proc(t: ^testing.T) {
	test_pages(t)
	pi: Page_Images
	pi.queue = make([dynamic]^Img_Request)
	defer {
		for r in pi.queue { free(r) }
		delete(pi.queue)
	}

	mk :: proc(dist: f32) -> ^Img_Request {
		r := new(Img_Request)
		r.distance = dist
		r.queue_idx = -1
		return r
	}

	a := mk(500)
	b := mk(100)
	c := mk(100)
	d := mk(900)
	for r in ([]^Img_Request{a, b, c, d}) { img_queue_push(&pi, r) }

	// Lower d's distance to 0 (nearest viewport)
	d.distance = 0
	img_queue_update(&pi, d)

	// Remove a from interior
	rem := img_queue_remove_at(&pi, int(a.queue_idx))
	testing.expect(t, rem == a && rem.queue_idx == -1, "interior remove")
	free(rem)

	// Pop order: d (0), b (100, earlier seq), c (100, later seq)
	p0 := img_queue_pop(&pi)
	p1 := img_queue_pop(&pi)
	p2 := img_queue_pop(&pi)
	testing.expect(t, p0 == d && p1 == b && p2 == c, "min-heap pops nearest distance first with FIFO ties")
	free(p0); free(p1); free(p2)
	testing.expect_value(t, len(pi.queue), 0)
}

@(test)
resize_observer_direct_measure_and_serial_key :: proc(t: ^testing.T) {
	test_pages(t)
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<body style="margin:0"><div id=box style="width:120px;height:60px;padding:4px 6px;border:2px solid black;box-sizing:content-box"></div></body>`), 64 * 1024)

	ss := style.settings_default()
	defer style.settings_destroy(&ss)
	eng := style.engine_make(ss)
	defer style.engine_destroy(eng)
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)

	l: lay.Layout
	defer lay.destroy(&l)
	ls := lay.settings_default()
	lay.run(&l, lay.Input{
		doc = doc, styled = st, settings = &ls,
		text = lay.Text_Api{
			font = proc(_: rawptr, _: []string, _: u16, _: bool) -> lay.Font { return 1 },
			width = proc(_: rawptr, _: lay.Font, sz: f32, s: string) -> f32 { return f32(len(s)) * sz * 0.5 },
			metrics = proc(_: rawptr, _: lay.Font, sz: f32) -> lay.Font_Metrics { return {ascent = sz * 0.8, descent = sz * 0.2, x_height = sz * 0.5} },
		},
		viewport = {800, 600}, scale = 2, band_h = 256,
	})

	p: Page
	p.doc = doc
	w: Web_State
	p.web = &w
	box := dom.find_by_id(doc, "box")

	// Measure directly without lay.view_make
	m := ro_measure(&p, &l, 2, box)
	testing.expect(t, m.content == {120, 60}, "content size in CSS px")
	testing.expect(t, m.border == {136, 72}, "border size in CSS px")
	testing.expect(t, m.device == {240, 120}, "devicePixelContentBoxSize scaled by DPR")
	testing.expect(t, m.left == 6 && m.top == 4, "content rect padding offsets")

	// Key gating: equal when nothing changes; changes on layout pass, scale, or target serial
	vp := Viewport{width = 400, height = 300, scale = 2}
	k0 := ro_key_of(&p, &l, vp)
	k1 := ro_key_of(&p, &l, vp)
	testing.expect_value(t, k0, k1)
	w.observers.ro_target_serial += 1
	testing.expect(t, ro_key_of(&p, &l, vp) != k0, "ro_target_serial invalidates Ro_Key")

	// Io_Key changes on scroll_digest or viewport change
	ik0 := io_key_of(&p, &l, vp)
	vp2 := vp
	vp2.scroll_y = 50
	testing.expect(t, io_key_of(&p, &l, vp2) != ik0, "viewport scroll invalidates Io_Key")
}

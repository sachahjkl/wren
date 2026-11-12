package browser

// The picture that follows a drag from the page (HTML "drag feedback"): the element setDragImage named, at the offset
// it gave (an <img> or a <canvas>: their pixels; another element: how it is drawn now), else a translucent ghost of
// the dragged element (an image: its pixels), grabbed where the pointer took it. Inside the window the shell draws it
// over everything at the pointer; when the drag leaves the window the same picture goes to the system's drag
// (platform.drag_start), which draws it over other applications too, with the same hot spot.
//
// Another element is painted alone into an offscreen target of the toolkit (draw.offscreen_begin, the frame after the
// drag started: what dragstart's listeners changed is in it), whatever its place: off the screen (top: -1000px, the
// usual trick of a custom drag picture), under other elements or scrolled away; then read back
// (render.readback_poll, from a timer of the loop: a frame asked for at every turn only to look would race the
// software rasterizer of a machine with no GPU for the processors). A drag of selected text of the document gets a picture of the selection: its text with the
// selection's highlight over each line, faded as the ghost.

import "core:math"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "wb:base"
import "wb:dom"
import "wb:host"
import lay "wb:layout"
import "wb:page"
import "wb:config"

DND_IMAGE_PREFS := [?]config.Def{
	{name = "browser.dnd.image_opacity", kind = .Float, default = {f = 0.7}, bounded = true, min = 0, max = 1,
		description = "Opacity of the picture of a dragged element that follows the pointer (the ghost; a picture the page gave with setDragImage is shown as it is). 0 hides it."},
	{name = "browser.dnd.image_max_px", kind = .Int, default = {i = 480}, bounded = true, min = 16, max = 4096, unit = "px",
		description = "Largest width or height of the drag picture, in device pixels: a larger element or image is scaled down to fit (Windows draws large drag pictures badly)."},
}

// Frames the drag's picture waits for a layout of the page as it is: a page that changes at every frame gets none.
@(private = "file") DRAG_PICTURE_WAIT_FRAMES :: 8

// How often the read-back of a painted picture is looked at (loop ms), and how long it may take before the drag uses a
// plain picture of the same size instead: the system's software rasterizer can be far behind a frame, a lost device never
// answers, and the system's drag waits for the picture (dnd_shell.odin hand_off).
@(private = "file") READBACK_POLL_MS :: 4
@(private = "file") READBACK_DEADLINE_MS :: 1000

// Where the picture of a drag is: no drag, a painted element waiting for a layout as new as the page, then for its pixels, then made.
Picture_State :: enum u8 { None, Wait_Layout, Readback, Ready }

// A window's drag picture (Window_Own.dimg).
Dnd_Image :: struct {
	state:   Picture_State,
	waited:  int,             // frames the picture waited for the layout to catch up with the page
	readback: render.Readback_Id,
	asked_ns: i64,            // when the read-back was recorded (the loop's clock): its deadline counts from there
	mode:    Picture_Of,
	el:      base.Handle,     // Element: what is painted
	bounds:  draw.Rect,       // what is painted (page area px, the viewport's: scrolled)
	hot:     [2]f32,          // where the pointer is in the picture
	fade:    f32,             // opacity applied to the capture
	img:     platform.Drag_Image,   // owned pixels (empty until ready)
	tex:     render.Texture,
	tex_ok:  bool,
	pos:     [2]f32,          // the pointer (window px)
	shown:   bool,            // drawn in the window (false while the system's drag shows it)
	target:  [4]f32,          // a file input the drop would fill: outlined (empty: none)
}


@(private = "file")
Picture_Of :: enum u8 { Element, Selection }

// The last drag picture made: its size, hot spot and middle pixel (RGBA, the opacity applied; App.dnd_last_picture).
Dnd_Picture :: struct { size, hot: [2]int, middle: [4]u8 }

// The largest offscreen picture painted for a drag (device px a side): a larger element or selection is painted around
// the pointer (drag_image_fit then scales it to browser.dnd.image_max_px).
@(private = "file") PAINT_MAX_PX :: 2048

// A drag from the page started at `pointer` (window px): the picture is made (now for pixels, the next frame for a
// capture).
dnd_image_begin :: proc(app: ^App, t: ^Tab, p: ^page.Page, pointer: [2]f32) {
	dnd_image_end(app)
	s := page.drag_session(p)
	if s == nil { return }
	window_own(app).dimg.state, window_own(app).dimg.pos, window_own(app).dimg.shown = .Ready, pointer, true
	scale := page_scale(app)
	limit := int(config.int_of(&app.prefs, "browser.dnd.image_max_px"))
	el, off := page.drag_session_image(p)
	given := el != base.NIL_HANDLE
	fade := given ? f32(1) : f32(config.float_of(&app.prefs, "browser.dnd.image_opacity"))
	local := pointer - active_window(app).page_rect.min
	if !given {
		if s.kind == .Selection && page.selection_active(p) {
			// the selection of the document: its lines, as they are highlighted
			b, ok := selection_bounds(app, t)
			if !ok { window_own(app).dimg.state = .None; return }
			start_paint(app, .Selection, base.NIL_HANDLE, b, local, local - b.min, fade)
			return
		}
		if s.source == base.NIL_HANDLE { window_own(app).dimg.state = .None; return }
		el = s.source
	}
	// an image or a canvas: their pixels, at the size they are shown
	if rgba, size, css, ok := page.drag_image_pixels(p, el, context.temp_allocator); ok {
		want := [2]f32{f32(css.x) * scale, f32(css.y) * scale}
		if want.x <= 0 || want.y <= 0 { want = {f32(size.x), f32(size.y)} }
		k := want.x / f32(size.x)
		px, w, h := rgba, size.x, size.y
		if abs(k - 1) > 0.01 { px, w, h = scale_rgba(rgba, size.x, size.y, k) }
		defer if abs(k - 1) > 0.01 { delete(px) }
		hot := given ? [2]f32{f32(off.x) * scale, f32(off.y) * scale} : grab_point(app, t, el, pointer)
		set_picture(app, active_window(app), platform.Drag_Image{px, {w, h}, {int(math.round(hot.x)), int(math.round(hot.y))}}, fade, limit)
		return
	}
	// another element: painted alone, wherever it is (an element that is not rendered at all, display: none, has no
	// picture: the dragged element's ghost then, as browsers do)
	b, ok := element_paint_bounds(app, t, el)
	if !ok && given && s.source != base.NIL_HANDLE {
		el, given, fade = s.source, false, f32(config.float_of(&app.prefs, "browser.dnd.image_opacity"))
		b, ok = element_paint_bounds(app, t, el)
	}
	if !ok { window_own(app).dimg.state = .None; return }
	hot := given ? [2]f32{f32(off.x) * scale, f32(off.y) * scale} : local - b.min
	start_paint(app, .Element, el, b, b.min + hot, hot, fade)
}

// Where element `el` is painted (page area px of the viewport, its whole box, on the screen or not).
@(private = "file")
element_paint_bounds :: proc(app: ^App, t: ^Tab, el: base.Handle) -> (draw.Rect, bool) {
	if t.page == nil || !t.layout.valid { return {}, false }
	r, found := lay.box_of(&t.layout, el, draw.rect_size(active_window(app).page_rect), t.scroll)
	if !found || r.bounds.max.x <= r.bounds.min.x || r.bounds.max.y <= r.bounds.min.y { return {}, false }
	return draw.rect_shift(draw.Rect{r.bounds.min, r.bounds.max}, -doc_scroll_vec(t)), true
}

// The bounds of the selected text (page area px of the viewport): each text item's selected part.
@(private = "file")
selection_bounds :: proc(app: ^App, t: ^Tab) -> (draw.Rect, bool) {
	p := t.page
	a, b, ok := page.selection_range(p)
	if !ok || a == b || !t.layout.valid { return {}, false }
	l := &t.layout
	v := lay.view_make(l, draw.rect_size(active_window(app).page_rect), t.scroll, cull = false)
	api := page_text_api(&app.page_render.fonts, &app.measure, &app.page_settings.style)
	out: draw.Rect
	found := false
	for i in 0 ..< len(l.items) {
		it := &l.items[i]
		if it.kind != .Text { continue }
		ia, ib, in_range := lay.item_range(l, p.doc, i, a, b)
		if !in_range || ia == ib { continue }
		off := v.offsets[it.space]
		x0, x1 := lay.item_caret_x(l, it, ia, api), lay.item_caret_x(l, it, ib, api)
		r := draw.Rect{{it.rect.min.x + off.x + min(x0, x1), it.rect.min.y + off.y}, {it.rect.min.x + off.x + max(x0, x1), it.rect.max.y + off.y}}
		out = found ? draw.Rect{{min(out.min.x, r.min.x), min(out.min.y, r.min.y)}, {max(out.max.x, r.max.x), max(out.max.y, r.max.y)}} : r
		found = true
	}
	return out, found && out.max.x > out.min.x && out.max.y > out.min.y
}

// What will be painted at the next frame: `bounds` cut to PAINT_MAX_PX around `at` (page area px), the hot spot from
// its corner.
@(private = "file")
start_paint :: proc(app: ^App, mode: Picture_Of, el: base.Handle, bounds: draw.Rect, at, hot: [2]f32, fade: f32) {
	b := bounds
	for k in 0 ..< 2 {
		if b.max[k] - b.min[k] > PAINT_MAX_PX {
			lo := clamp(at[k] - PAINT_MAX_PX / 2, b.min[k], b.max[k] - PAINT_MAX_PX)
			b.min[k], b.max[k] = lo, lo + PAINT_MAX_PX
		}
	}
	b.min, b.max = {math.floor(b.min.x), math.floor(b.min.y)}, {math.ceil(b.max.x), math.ceil(b.max.y)}
	window_own(app).dimg.mode, window_own(app).dimg.el, window_own(app).dimg.bounds, window_own(app).dimg.fade = mode, el, b, fade
	window_own(app).dimg.hot = hot - (b.min - bounds.min)
	window_own(app).dimg.state = .Wait_Layout
	request_frames(app, 3)
}

// The page's items that make the picture, painted into an offscreen target, its corner at dimg.bounds.min: those of
// the element and below it (not cut by its ancestors' overflow nor moved by their effects: the element alone), or the
// selected text with its highlight.
@(private = "file")
paint_picture :: proc(app: ^App, dc: ^draw.Context) -> render.Readback_Id {
	t := current_tab(app)
	if t == nil || t.page == nil || !t.layout.valid { return 0 }
	p := t.page
	if t.layout.mutations != p.doc.mutations { return 0 }   // (a dragstart handler changed the page: its items show strings that may be gone)
	l := &t.layout
	d := p.doc
	b := window_own(app).dimg.bounds
	size := [2]int{int(b.max.x - b.min.x), int(b.max.y - b.min.y)}
	if !draw.offscreen_begin(dc, size) { return 0 }
	circular := draw.set_circular_corners(dc, true)
	interp := draw.set_interpolation(dc, .Srgb)
	v := lay.view_make(l, draw.rect_size(active_window(app).page_rect), t.scroll, cull = false)
	sel_a, sel_b, has_sel := page.selection_range(p)
	api := page_text_api(&app.page_render.fonts, &app.measure, &app.page_settings.style)
	for i in 0 ..< len(l.items) {
		it := &l.items[i]
		off := v.offsets[it.space] - b.min
		r := draw.Rect{it.rect.min + off, it.rect.max + off}
		clipped := false
		switch window_own(app).dimg.mode {
		case .Element:
			if it.node == base.NIL_HANDLE || !dom.is_ancestor_or_self(d, window_own(app).dimg.el, it.node) { continue }
		case .Selection:
			if !has_sel { continue }
			#partial switch it.kind {
			case .Text:
				ia, ib, in_range := lay.item_range(l, d, i, sel_a, sel_b)
				if !in_range || ia == ib { continue }
				// only the selected part of the piece of text
				x0, x1 := lay.item_caret_x(l, it, ia, api), lay.item_caret_x(l, it, ib, api)
				draw.push_clip(dc, {{r.min.x + min(x0, x1), r.min.y}, {r.min.x + max(x0, x1), r.max.y}})
				clipped = true
			case .Replaced:
				if !lay.node_in_range(d, it.node, sel_a, sel_b) { continue }
			case: continue
			}
		}
		paint_item(l, dc, d, &v, it, r, off, -b.min)
		if clipped { draw.pop_clip(dc) }
	}
	draw.set_interpolation(dc, interp)
	draw.set_circular_corners(dc, circular)
	return draw.offscreen_end(dc)
}

// Where the pointer took an element (picture px from its top left).
@(private = "file")
grab_point :: proc(app: ^App, t: ^Tab, el: base.Handle, pointer: [2]f32) -> [2]f32 {
	if er, ok := element_window_rect(app, t, el); ok { return pointer - {er[0], er[1]} }
	return {}
}

// The picture of window `w`'s drag (the active one, or the one whose read-back a timer took).
@(private = "file")
set_picture :: proc(app: ^App, w: ^Browser_Window, img: platform.Drag_Image, fade: f32, limit: int) {
	d := &w.own.dimg
	fit := platform.drag_image_fit(img, {limit, limit})
	if !platform.drag_image_valid(fit) { d.state = .None; window_request(app, w, 2); return }   // (a hand-off waiting for it looks again)
	platform.drag_image_fade(fit, fade)
	delete(d.img.rgba)
	d.img = fit
	// what the remote control reports (wren ctl stats: dragPicture): its size, hot spot, the pixel at its middle
	mid := (fit.size.y / 2 * fit.size.x + fit.size.x / 2) * 4
	app.dnd_last_picture = {fit.size, fit.offset, {fit.rgba[mid], fit.rgba[mid + 1], fit.rgba[mid + 2], fit.rgba[mid + 3]}}
	if d.tex_ok { render.destroy_texture(&app.r, d.tex); d.tex_ok = false }
	d.tex = render.create_texture_rgba(&app.r, fit.size.x, fit.size.y, false)
	if d.tex != 0 {
		render.update_texture_rgba(&app.r, d.tex, 0, 0, fit.size.x, fit.size.y, fit.rgba)
		d.tex_ok = true
	}
	window_request(app, w, 2)
}

// What the drag shows when the painted picture never came back (past READBACK_DEADLINE_MS, a failed read-back): a plain
// translucent box of the painted size and the same hot spot, so that the drag still shows what it carries and where it
// was taken. Made at most browser.dnd.image_max_px a side: a box needs no detail.
@(private = "file")
set_plain_picture :: proc(app: ^App, w: ^Browser_Window) {
	d := &w.own.dimg
	limit := int(config.int_of(&app.prefs, "browser.dnd.image_max_px"))
	size := [2]f32{d.bounds.max.x - d.bounds.min.x, d.bounds.max.y - d.bounds.min.y}
	if size.x < 1 || size.y < 1 { d.state = .None; window_request(app, w, 2); return }
	k := min(f32(1), f32(limit) / max(size.x, size.y))
	pw, ph := max(int(size.x * k), 1), max(int(size.y * k), 1)
	px := make([]u8, pw * ph * 4, context.temp_allocator)
	for i in 0 ..< pw * ph { px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3] = PLAIN_GREY, PLAIN_GREY, PLAIN_GREY, PLAIN_ALPHA }
	hot := d.hot * k
	set_picture(app, w, platform.Drag_Image{px, {pw, ph}, {int(math.round(hot.x)), int(math.round(hot.y))}}, 1, limit)
}

// The plain picture's grey and opacity (straight RGBA bytes): neutral on a light or a dark page.
@(private = "file") PLAIN_GREY :: 160
@(private = "file") PLAIN_ALPHA :: 160

// The loop's timer of a read-back (READBACK_POLL_MS): its pixels when the GPU has them, the plain picture past the
// deadline. `data` is the window's id and the read-back's: a tick of a read-back that was forgotten (a drag that ended,
// another that began) finds another id and stops.
@(private = "file")
readback_tick :: proc(data: rawptr) {
	app := the_app
	if app == nil { return }
	packed := u64(uintptr(data))
	w := window_by_id(app, int(packed >> 32))
	if w == nil { return }
	d := &w.own.dimg
	if d.state != .Readback || u64(d.readback) != packed & 0xFFFF_FFFF { return }
	pixels, size, st := render.readback_poll(&app.r, d.readback, context.temp_allocator)
	switch st {
	case .None, .Pending:
		if host.now_ns(&app.loop) - d.asked_ns >= READBACK_DEADLINE_MS * NS_PER_MS {
			render.readback_release(&app.r, d.readback)
			d.state, d.readback = .Ready, 0
			set_plain_picture(app, w)
			return
		}
		readback_arm(app, w)
	case .Failed:
		d.state, d.readback = .Ready, 0
		set_plain_picture(app, w)
	case .Ready:
		d.state, d.readback = .Ready, 0
		set_picture(app, w, platform.Drag_Image{pixels, size, {int(math.round(d.hot.x)), int(math.round(d.hot.y))}}, d.fade, int(config.int_of(&app.prefs, "browser.dnd.image_max_px")))
	}
}

// The next look at window `w`'s read-back. A one-shot timer each time: nothing to clear when the drag ends, the tick
// that finds another read-back stops by itself.
@(private = "file")
readback_arm :: proc(app: ^App, w: ^Browser_Window) {
	packed := u64(u32(w.id)) << 32 | u64(w.own.dimg.readback)
	host.set_timer(&app.loop, READBACK_POLL_MS, 0, readback_tick, rawptr(uintptr(packed)))
}

// Every frame (drawing): the picture is painted offscreen once; its pixels are read from a timer (readback_tick).
@(private = "file")
dnd_image_poll :: proc(app: ^App, dc: ^draw.Context) {
	img := &window_own(app).dimg
	#partial switch img.state {
	case .Wait_Layout:
		request_frames(app, 2)
		// (a dragstart that changed the page, a class on what is dragged: the picture is of the next layout)
		if t := current_tab(app); t != nil && t.page != nil && layout_behind(&t.layout, t.page.doc) && img.waited < DRAG_PICTURE_WAIT_FRAMES {
			img.waited += 1
			return
		}
		img.waited = 0
		img.readback = paint_picture(app, dc)
		img.state = img.readback != 0 ? .Readback : .Ready   // (no readback on this renderer: the system's own picture)
		if img.readback != 0 {
			img.asked_ns = host.now_ns(&app.loop)
			readback_arm(app, active_window(app))
		}
	}
}

// The picture is still being painted or read back.
dnd_image_waiting :: proc() -> bool { s := window_own(the_app).dimg.state; return s == .Wait_Layout || s == .Readback }

// The pointer moved (window px).
dnd_image_move :: proc(pos: [2]f32) { window_own(the_app).dimg.pos = pos }

// The file input a drop would fill (outlined while the drag is over it), or none.
dnd_image_target :: proc(rect: Maybe([4]f32)) {
	r, ok := rect.?
	window_own(the_app).dimg.target = ok ? r : {}
}

// The picture for the system's drag (a view of the shell's: valid until dnd_image_end), nil while it is not ready.
dnd_image_system :: proc() -> Maybe(platform.Drag_Image) {
	if window_own(the_app).dimg.state == .None || !platform.drag_image_valid(window_own(the_app).dimg.img) { return nil }
	return window_own(the_app).dimg.img
}

// The system's drag shows the picture now (or no longer).
dnd_image_system_shows :: proc(on: bool) { window_own(the_app).dimg.shown = !on }

// The drag is over: the picture goes.
dnd_image_end :: proc(app: ^App) { dnd_image_forget(window_own(app)) }

// So in window `own`, which is not the one framed when a document under the drag closes.
dnd_image_forget :: proc(own: ^Window_Own) {
	img := &own.dimg
	// a readback not taken yet: forgotten
	if img.readback != 0 { render.readback_release(&the_app.r, img.readback) }
	if img.tex_ok { render.destroy_texture(&the_app.r, img.tex) }
	delete(img.img.rgba)
	img^ = {}
}

// Whether a picture is being drawn or waited for (tests, the remote control's state).
dnd_image_state :: proc() -> (active, ready: bool, size, hot: [2]int) {
	return window_own(the_app).dimg.state != .None, platform.drag_image_valid(window_own(the_app).dimg.img), window_own(the_app).dimg.img.size, window_own(the_app).dimg.img.offset
}

// Over everything the frame drew (main.odin, after the interface): the picture at the pointer, and the outline of a
// file input that would take the dropped files.
dnd_paint :: proc(app: ^App, dc: ^draw.Context) {
	dnd_image_poll(app, dc)
	if window_own(app).dimg.target[2] > 0 && window_own(app).dimg.target[3] > 0 {
		r := draw.Rect{{window_own(app).dimg.target[0], window_own(app).dimg.target[1]}, {window_own(app).dimg.target[0] + window_own(app).dimg.target[2], window_own(app).dimg.target[1] + window_own(app).dimg.target[3]}}
		w := max(2 * page_scale(app), 1)
		c := chrome_palette(app).accent
		accent := draw.srgb(f32(c >> 24) / 255, f32((c >> 16) & 255) / 255, f32((c >> 8) & 255) / 255, 1)
		draw.rect(dc, draw.rect_pad(r, w), accent, 3 * page_scale(app), border = w)
	}
	if window_own(app).dimg.state == .None || !window_own(app).dimg.shown || !window_own(app).dimg.tex_ok { return }
	img := window_own(app).dimg.img
	at := window_own(app).dimg.pos - {f32(img.offset.x), f32(img.offset.y)}
	draw.image(dc, window_own(app).dimg.tex, {at, at + {f32(img.size.x), f32(img.size.y)}})
}

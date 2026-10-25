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
// (render.readback_poll). A drag of selected text of the document gets a picture of the selection: its text with the
// selection's highlight over each line, faded as the ghost.

import "core:math"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:config"

DND_IMAGE_PREFS := [?]config.Def{
	{name = "browser.dnd.image_opacity", kind = .Float, default = {f = 0.7}, bounded = true, min = 0, max = 1,
		description = "Opacity of the picture of a dragged element that follows the pointer (the ghost; a picture the page gave with setDragImage is shown as it is). 0 hides it."},
	{name = "browser.dnd.image_max_px", kind = .Int, default = {i = 480}, bounded = true, min = 16, max = 4096, unit = "px",
		description = "Largest width or height of the drag picture, in device pixels: a larger element or image is scaled down to fit (Windows draws large drag pictures badly)."},
}

@(private = "file")
Dnd_Image :: struct {
	active:  bool,
	waiting: bool,            // the picture is to be painted offscreen and read back
	asked:   bool,            // painted: the readback is waited for
	readback: render.Readback_Id,
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
dimg: Dnd_Image

@(private = "file")
Picture_Of :: enum u8 { Element, Selection }

// The last drag picture made: its size, hot spot and middle pixel (RGBA, the opacity applied).
dnd_last_picture: struct { size, hot: [2]int, middle: [4]u8 }

// The largest offscreen picture painted for a drag (device px a side): a larger element or selection is painted around
// the pointer (drag_image_fit then scales it to browser.dnd.image_max_px).
@(private = "file") PAINT_MAX_PX :: 2048

// A drag from the page started at `pointer` (window px): the picture is made (now for pixels, the next frame for a
// capture).
dnd_image_begin :: proc(app: ^App, t: ^Tab, p: ^page.Page, pointer: [2]f32) {
	dnd_image_end(app)
	s := page.drag_session(p)
	if s == nil { return }
	dimg.active, dimg.pos, dimg.shown = true, pointer, true
	scale := page_scale(app)
	limit := int(config.int_of(&app.prefs, "browser.dnd.image_max_px"))
	el, off := page.drag_session_image(p)
	given := el != base.NIL_HANDLE
	fade := given ? f32(1) : f32(config.float_of(&app.prefs, "browser.dnd.image_opacity"))
	local := pointer - app.page_rect.min
	if !given {
		if s.kind == .Selection && page.selection_active(p) {
			// the selection of the document: its lines, as they are highlighted
			b, ok := selection_bounds(app, t)
			if !ok { dimg.active = false; return }
			start_paint(app, .Selection, base.NIL_HANDLE, b, local, local - b.min, fade)
			return
		}
		if s.source == base.NIL_HANDLE { dimg.active = false; return }
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
		set_picture(app, platform.Drag_Image{px, {w, h}, {int(math.round(hot.x)), int(math.round(hot.y))}}, fade, limit)
		return
	}
	// another element: painted alone, wherever it is (an element that is not rendered at all, display: none, has no
	// picture: the dragged element's ghost then, as browsers do)
	b, ok := element_paint_bounds(app, t, el)
	if !ok && given && s.source != base.NIL_HANDLE {
		el, given, fade = s.source, false, f32(config.float_of(&app.prefs, "browser.dnd.image_opacity"))
		b, ok = element_paint_bounds(app, t, el)
	}
	if !ok { dimg.active = false; return }
	hot := given ? [2]f32{f32(off.x) * scale, f32(off.y) * scale} : local - b.min
	start_paint(app, .Element, el, b, b.min + hot, hot, fade)
}

// Where element `el` is painted (page area px of the viewport, its whole box, on the screen or not).
@(private = "file")
element_paint_bounds :: proc(app: ^App, t: ^Tab, el: base.Handle) -> (draw.Rect, bool) {
	if t.page == nil || !t.layout.valid { return {}, false }
	r, found := lay.box_of(&t.layout, el, draw.rect_size(app.page_rect), t.scroll)
	if !found || r.bounds.max.x <= r.bounds.min.x || r.bounds.max.y <= r.bounds.min.y { return {}, false }
	return draw.Rect{{r.bounds.min.x, r.bounds.min.y - t.scroll}, {r.bounds.max.x, r.bounds.max.y - t.scroll}}, true
}

// The bounds of the selected text (page area px of the viewport): each text item's selected part.
@(private = "file")
selection_bounds :: proc(app: ^App, t: ^Tab) -> (draw.Rect, bool) {
	p := t.page
	a, b, ok := page.selection_range(p)
	if !ok || a == b || !t.layout.valid { return {}, false }
	l := &t.layout
	v := lay.view_make(l, draw.rect_size(app.page_rect), t.scroll, cull = false)
	api := page_text_api(&page_render.fonts, &app.measure, &app.page_settings.style)
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
	dimg.mode, dimg.el, dimg.bounds, dimg.fade = mode, el, b, fade
	dimg.hot = hot - (b.min - bounds.min)
	dimg.waiting = true
	app.frames_requested = max(app.frames_requested, 3)
}

// The page's items that make the picture, painted into an offscreen target, its corner at dimg.bounds.min: those of
// the element and below it (not cut by its ancestors' overflow nor moved by their effects: the element alone), or the
// selected text with its highlight.
@(private = "file")
paint_picture :: proc(app: ^App, dc: ^draw.Context) -> render.Readback_Id {
	t := current_tab(app)
	if t == nil || t.page == nil || !t.layout.valid { return 0 }
	p := t.page
	l := &t.layout
	d := p.doc
	b := dimg.bounds
	size := [2]int{int(b.max.x - b.min.x), int(b.max.y - b.min.y)}
	if !draw.offscreen_begin(dc, size) { return 0 }
	circular := draw.set_circular_corners(dc, true)
	interp := draw.set_interpolation(dc, .Srgb)
	v := lay.view_make(l, draw.rect_size(app.page_rect), t.scroll, cull = false)
	sel_a, sel_b, has_sel := page.selection_range(p)
	api := page_text_api(&page_render.fonts, &app.measure, &app.page_settings.style)
	for i in 0 ..< len(l.items) {
		it := &l.items[i]
		off := v.offsets[it.space] - b.min
		r := draw.Rect{it.rect.min + off, it.rect.max + off}
		clipped := false
		switch dimg.mode {
		case .Element:
			if it.node == base.NIL_HANDLE || !dom.is_ancestor_or_self(d, dimg.el, it.node) { continue }
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

@(private = "file")
set_picture :: proc(app: ^App, img: platform.Drag_Image, fade: f32, limit: int) {
	fit := platform.drag_image_fit(img, {limit, limit})
	if !platform.drag_image_valid(fit) { dimg.active = false; return }
	platform.drag_image_fade(fit, fade)
	delete(dimg.img.rgba)
	dimg.img = fit
	// what the remote control reports (wren ctl stats: dragPicture): its size, hot spot, the pixel at its middle
	mid := (fit.size.y / 2 * fit.size.x + fit.size.x / 2) * 4
	dnd_last_picture = {fit.size, fit.offset, {fit.rgba[mid], fit.rgba[mid + 1], fit.rgba[mid + 2], fit.rgba[mid + 3]}}
	if dimg.tex_ok { render.destroy_texture(&app.r, dimg.tex); dimg.tex_ok = false }
	dimg.tex = render.create_texture_rgba(&app.r, fit.size.x, fit.size.y, false)
	if dimg.tex != 0 {
		render.update_texture_rgba(&app.r, dimg.tex, 0, 0, fit.size.x, fit.size.y, fit.rgba)
		dimg.tex_ok = true
	}
	app.frames_requested = max(app.frames_requested, 2)
}

// Every frame (drawing): the picture is painted offscreen once, then its pixels read when the GPU has them.
@(private = "file")
dnd_image_poll :: proc(app: ^App, dc: ^draw.Context) {
	if !dimg.active || !dimg.waiting { return }
	app.frames_requested = max(app.frames_requested, 2)
	if !dimg.asked {
		dimg.readback = paint_picture(app, dc)
		dimg.asked = true
		if dimg.readback == 0 { dimg.waiting, dimg.asked = false, false }   // (no readback on this renderer: the system's own picture)
		return
	}
	pixels, size, st := render.readback_poll(&app.r, dimg.readback, context.temp_allocator)
	switch st {
	case .None, .Pending:
	case .Failed: dimg.waiting, dimg.asked, dimg.readback = false, false, 0
	case .Ready:
		dimg.waiting, dimg.asked, dimg.readback = false, false, 0
		hot := dimg.hot
		set_picture(app, platform.Drag_Image{pixels, size, {int(math.round(hot.x)), int(math.round(hot.y))}}, dimg.fade, int(config.int_of(&app.prefs, "browser.dnd.image_max_px")))
	}
}

// The picture is still being painted or read back.
dnd_image_waiting :: proc() -> bool { return dimg.active && dimg.waiting }

// The pointer moved (window px).
dnd_image_move :: proc(pos: [2]f32) { dimg.pos = pos }

// The file input a drop would fill (outlined while the drag is over it), or none.
dnd_image_target :: proc(rect: Maybe([4]f32)) {
	r, ok := rect.?
	dimg.target = ok ? r : {}
}

// The picture for the system's drag (a view of the shell's: valid until dnd_image_end), nil while it is not ready.
dnd_image_system :: proc() -> Maybe(platform.Drag_Image) {
	if !dimg.active || !platform.drag_image_valid(dimg.img) { return nil }
	return dimg.img
}

// The system's drag shows the picture now (or no longer).
dnd_image_system_shows :: proc(on: bool) { dimg.shown = !on }

// The drag is over: the picture goes.
dnd_image_end :: proc(app: ^App) {
	// a readback not taken yet: forgotten
	if dimg.readback != 0 && app != nil { render.readback_release(&app.r, dimg.readback) }
	if dimg.tex_ok && app != nil { render.destroy_texture(&app.r, dimg.tex) }
	delete(dimg.img.rgba)
	dimg = {}
}

// Whether a picture is being drawn or waited for (tests, the remote control's state).
dnd_image_state :: proc() -> (active, ready: bool, size, hot: [2]int) {
	return dimg.active, platform.drag_image_valid(dimg.img), dimg.img.size, dimg.img.offset
}

// Over everything the frame drew (main.odin, after the interface): the picture at the pointer, and the outline of a
// file input that would take the dropped files.
dnd_paint :: proc(app: ^App, dc: ^draw.Context) {
	dnd_image_poll(app, dc)
	if dimg.target[2] > 0 && dimg.target[3] > 0 {
		r := draw.Rect{{dimg.target[0], dimg.target[1]}, {dimg.target[0] + dimg.target[2], dimg.target[1] + dimg.target[3]}}
		w := max(2 * page_scale(app), 1)
		pal, pal_ok := ui.palette_named(app.cfg.ui_theme)
		if !pal_ok { pal = ui.PALETTE_GRAPHITE }
		c := pal.accent
		accent := draw.srgb(f32(c >> 24) / 255, f32((c >> 16) & 255) / 255, f32((c >> 8) & 255) / 255, 1)
		draw.rect(dc, draw.rect_pad(r, w), accent, 3 * page_scale(app), border = w)
	}
	if !dimg.active || !dimg.shown || !dimg.tex_ok { return }
	img := dimg.img
	at := dimg.pos - {f32(img.offset.x), f32(img.offset.y)}
	draw.image(dc, dimg.tex, {at, at + {f32(img.size.x), f32(img.size.y)}})
}

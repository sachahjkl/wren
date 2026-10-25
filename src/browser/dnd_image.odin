package browser

// The picture that follows a drag from the page (HTML "drag feedback"): the element setDragImage named, at the offset
// it gave (an <img> or a <canvas>: their pixels; another element: how it is drawn now), else a translucent ghost of
// the dragged element (an image: its pixels), grabbed where the pointer took it. Inside the window the shell draws it
// over everything at the pointer; when the drag leaves the window the same picture goes to the system's drag
// (platform.drag_start), which draws it over other applications too, with the same hot spot.
//
// How an element is drawn is read back from the frame (render.capture_request of its box, the frame after the drag
// started: what dragstart's listeners changed is in it); the part of it outside the page's visible area is not.

import "core:math"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:page"

DND_IMAGE_PREFS := [?]config.Def{
	{name = "browser.dnd.image_opacity", kind = .Float, default = {f = 0.7}, bounded = true, min = 0, max = 1,
		description = "Opacity of the picture of a dragged element that follows the pointer (the ghost; a picture the page gave with setDragImage is shown as it is). 0 hides it."},
	{name = "browser.dnd.image_max_px", kind = .Int, default = {i = 480}, bounded = true, min = 16, max = 4096, unit = "px",
		description = "Largest width or height of the drag picture, in device pixels: a larger element or image is scaled down to fit (Windows draws large drag pictures badly)."},
}

@(private = "file")
Dnd_Image :: struct {
	active:  bool,
	waiting: bool,            // the picture is to be read back from the frame
	asked:   bool,            // the capture is asked (render.capture_request), not read yet
	rect:    [4]int,          // what is captured (window px)
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
	if !given {
		if s.kind == .Selection || s.source == base.NIL_HANDLE { dimg.active = false; return }   // (the system's own picture of text)
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
	// another element: as it is drawn, read back from the next frame
	er, ok := element_window_rect(app, t, el)
	if !ok || er[2] <= 0 || er[3] <= 0 { dimg.active = false; return }
	pr := app.page_rect
	x0, y0 := max(er[0], pr.min.x), max(er[1], pr.min.y)
	x1, y1 := min(er[0] + er[2], pr.max.x), min(er[1] + er[3], pr.max.y)
	if x1 <= x0 || y1 <= y0 { dimg.active = false; return }
	dimg.rect = {int(math.floor(x0)), int(math.floor(y0)), int(math.ceil(x1 - x0)), int(math.ceil(y1 - y0))}
	dimg.hot = given ? [2]f32{f32(off.x) * scale + (er[0] - x0), f32(off.y) * scale + (er[1] - y0)} : pointer - {f32(dimg.rect[0]), f32(dimg.rect[1])}
	dimg.fade = fade
	dimg.waiting = true
	app.frames_requested = max(app.frames_requested, 3)
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
	if dimg.tex_ok { render.destroy_texture(&app.r, dimg.tex); dimg.tex_ok = false }
	dimg.tex = render.create_texture_rgba(&app.r, fit.size.x, fit.size.y, false)
	if dimg.tex != 0 {
		render.update_texture_rgba(&app.r, dimg.tex, 0, 0, fit.size.x, fit.size.y, fit.rgba)
		dimg.tex_ok = true
	}
	app.frames_requested = max(app.frames_requested, 2)
}

// Every frame: the capture asked for is read when the GPU has it.
@(private = "file")
dnd_image_poll :: proc(app: ^App) {
	if !dimg.active || !dimg.waiting { return }
	app.frames_requested = max(app.frames_requested, 2)
	if !dimg.asked {
		// (a capture of the remote control's in the way: the next frame)
		if render.capture_pending(&app.r) || !render.capture_request(&app.r, dimg.rect) { return }
		dimg.asked = true
		return
	}
	pixels, size, st := render.capture_poll(&app.r, context.temp_allocator)
	switch st {
	case .None, .Pending:
	case .Failed: dimg.waiting, dimg.asked = false, false
	case .Ready:
		dimg.waiting, dimg.asked = false, false
		hot := dimg.hot
		set_picture(app, platform.Drag_Image{pixels, size, {int(math.round(hot.x)), int(math.round(hot.y))}}, dimg.fade, int(config.int_of(&app.prefs, "browser.dnd.image_max_px")))
	}
}

// The picture is still being read back from the frame.
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
	// a capture of ours not read yet: forgotten, so that it does not stand in the way of the next one
	if dimg.asked && app != nil { render.capture_cancel(&app.r) }
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
	dnd_image_poll(app)
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

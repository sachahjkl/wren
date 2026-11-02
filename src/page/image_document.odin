package page

// An image opened by itself (the shell writes its document: browser/download.odin show_image_document) is an image
// viewer, as the image documents of other browsers are their own code: the document holds the <img> and this state, and
// the viewer writes the image's style attribute (size, place, rotation, cursor) from it. The shell routes the input to
// it (browser/image_document_shell.odin): the page dispatches no wheel events and the shell owns Ctrl+wheel.
//   * the first view fits the image in the view, never larger than its natural size (it follows the view's size);
//   * zoom: around the pointer (the wheel with Ctrl, a touchpad's pinch) or the view's center (+ / -); 0 fits it again;
//   * pan: the pointer dragged on the image, the wheel, the arrows, when the image is larger than the view that way
//     (the image never leaves an edge of the view inside it: an axis that fits stays centered);
//   * a click: fit <-> 100 % around the pointer (as in Chrome and Firefox), when the image is larger than the view;
//   * rotate: a quarter turn either way (R, Shift+R, the context menu);
//   * a double click resets everything: fit, no rotation.
// Units: CSS px of the view (its top left corner is 0, 0). Until the image is decoded the document's own style shows it.

import "core:fmt"
import "core:math"
import "core:time"
import "wb:base"
import "wb:dom"

IMAGE_ZOOM_STEP :: f32(1.25)         // one notch of the wheel, one + or - press
IMAGE_ZOOM_MIN :: f32(0.05)
IMAGE_ZOOM_MAX :: f32(32)
IMAGE_CLICK_SLOP_PX :: f32(4)       // a press that moves less than this before its release is a click, farther a drag
IMAGE_QUARTER_TURNS :: 4
IMAGE_QUARTER_DEG :: 90

Image_Drag :: enum u8 { Idle, Pressed, Dragging }

Image_Document :: struct {
	img:           base.Handle,   // NIL: the document is no image document
	view:          [2]f32,        // the view's size
	fit:           bool,          // the zoom follows the view (the whole image, at most its natural size)
	zoom:          f32,           // view px per image px, when not `fit`
	offset:        [2]f32,        // the image's center from the view's
	turns:         int,           // quarter turns clockwise, 0 ..< IMAGE_QUARTER_TURNS
	drag:          Image_Drag,
	press_at:      [2]f32,
	press_offset:  [2]f32,        // `offset` at the press
	last_click:    time.Tick,     // the last click, for a double click
	last_click_at: [2]f32,
}

// Called by the shell once it wrote an image document: its <img> becomes the viewer's.
image_document_begin :: proc(p: ^Page) {
	p.image_document = Image_Document{img = dom.find_first_by_tag(p.doc, "img"), fit = true, zoom = 1}
}

// The document is an image document whose image is decoded: the viewer has its natural size.
image_document_active :: proc(p: ^Page) -> bool {
	_, ok := natural_of(p)
	return ok
}

// The shell's view size, each frame (the fit follows it); the style is written when it changes.
image_document_frame :: proc(p: ^Page, view: [2]f32) {
	d := &p.image_document
	d.view = view
	apply(p)
}

// A wheel's turn with Ctrl or a pinch: `notches` > 0 zooms out (the wheel towards the user), around `at`.
image_document_zoom :: proc(p: ^Page, notches: f32, at: [2]f32) {
	zoom_to(p, current_zoom(p) * math.pow(IMAGE_ZOOM_STEP, -notches), at)
}

// + / -: one step around the view's center.
image_document_zoom_step :: proc(p: ^Page, steps: f32) {
	zoom_to(p, current_zoom(p) * math.pow(IMAGE_ZOOM_STEP, steps), p.image_document.view / 2)
}

// The image moved by `d` (the wheel, the arrows), clamped to the view.
image_document_pan :: proc(p: ^Page, d: [2]f32) {
	p.image_document.offset += d
	apply(p)
}

// 0: the whole image again (the rotation stays).
image_document_fit :: proc(p: ^Page) {
	d := &p.image_document
	d.fit, d.offset = true, {}
	apply(p)
}

// A quarter turn: 1 clockwise, -1 the other way.
image_document_rotate :: proc(p: ^Page, dir: int) {
	d := &p.image_document
	d.turns = ((d.turns + dir) % IMAGE_QUARTER_TURNS + IMAGE_QUARTER_TURNS) % IMAGE_QUARTER_TURNS
	apply(p)
}

// A double click: the first view.
image_document_reset :: proc(p: ^Page) {
	d := &p.image_document
	d.fit, d.zoom, d.offset, d.turns = true, 1, {}, 0
	apply(p)
}

image_document_press :: proc(p: ^Page, at: [2]f32) {
	d := &p.image_document
	d.drag, d.press_at, d.press_offset = .Pressed, at, d.offset
	apply(p)
}

// A press is held (the shell takes its release).
image_document_pressed :: proc(p: ^Page) -> bool { return p.image_document.drag != .Idle }

image_document_move :: proc(p: ^Page, at: [2]f32) {
	d := &p.image_document
	if d.drag == .Idle { return }
	moved := at - d.press_at
	if d.drag == .Pressed && max(abs(moved.x), abs(moved.y)) < IMAGE_CLICK_SLOP_PX { return }
	d.drag = .Dragging
	d.offset = d.press_offset + moved
	apply(p)
}

// The release of a press: a drag ends; a click toggles fit and 100 %, a second one soon after at the same place resets.
image_document_release :: proc(p: ^Page, at: [2]f32, double_click_ms: f64) {
	d := &p.image_document
	was := d.drag
	d.drag = .Idle
	if was != .Pressed { apply(p); return }
	now := time.tick_now()
	near := at - d.last_click_at
	if d.last_click != {} && time.duration_milliseconds(time.tick_diff(d.last_click, now)) <= double_click_ms && max(abs(near.x), abs(near.y)) < IMAGE_CLICK_SLOP_PX {
		d.last_click = {}
		image_document_reset(p)
		return
	}
	d.last_click, d.last_click_at = now, at
	nat, ok := natural_of(p)
	if !ok { return }
	if !d.fit {
		image_document_fit(p)
	} else if fit_zoom(d, nat) < 1 {
		zoom_to(p, 1, at)
	}
}

////////////////////////////////

// The image's natural size (CSS px), once decoded.
@(private = "file")
natural_of :: proc(p: ^Page) -> ([2]f32, bool) {
	d := &p.image_document
	if d.img == base.NIL_HANDLE || dom.get(p.doc, d.img) == nil { return {}, false }
	v := image_view(p, d.img)
	if v.state != .Ready || v.natural.x <= 0 || v.natural.y <= 0 { return {}, false }
	return v.natural, true
}

// The natural size as turned.
@(private = "file")
turned :: proc(d: ^Image_Document, nat: [2]f32) -> [2]f32 { return d.turns % 2 == 1 ? [2]f32{nat.y, nat.x} : nat }

@(private = "file")
fit_zoom :: proc(d: ^Image_Document, nat: [2]f32) -> f32 {
	r := turned(d, nat)
	return min(1, d.view.x / r.x, d.view.y / r.y)
}

@(private = "file")
current_zoom :: proc(p: ^Page) -> f32 {
	d := &p.image_document
	nat, ok := natural_of(p)
	if !ok { return 1 }
	return d.fit ? fit_zoom(d, nat) : d.zoom
}

// Zoom `z`, the image's point under `at` staying there.
@(private = "file")
zoom_to :: proc(p: ^Page, z: f32, at: [2]f32) {
	d := &p.image_document
	if _, ok := natural_of(p); !ok { return }
	from := current_zoom(p)
	to := clamp(z, IMAGE_ZOOM_MIN, IMAGE_ZOOM_MAX)
	rel := at - d.view / 2
	d.offset = rel - (to / from) * (rel - d.offset)
	d.fit, d.zoom = false, to
	apply(p)
}

// The offset kept inside: on an axis where the image is larger than the view, no edge comes inside it; else centered.
@(private = "file")
clamp_offset :: proc(d: ^Image_Document, shown: [2]f32) {
	for i in 0 ..< 2 {
		room := max((shown[i] - d.view[i]) / 2, 0)
		d.offset[i] = clamp(d.offset[i], -room, room)
	}
}

// The image's style attribute from the state (written only when it changes).
@(private = "file")
apply :: proc(p: ^Page) {
	d := &p.image_document
	nat, ok := natural_of(p)
	if !ok || d.view.x <= 0 || d.view.y <= 0 { return }
	z := d.fit ? fit_zoom(d, nat) : d.zoom
	shown := turned(d, nat) * z
	clamp_offset(d, shown)
	larger := shown.x > d.view.x || shown.y > d.view.y
	cursor := "default"
	switch {
	case d.drag == .Dragging: cursor = "grabbing"
	case larger:              cursor = "grab"
	case d.fit && fit_zoom(d, nat) < 1: cursor = "zoom-in"
	case !d.fit:              cursor = "zoom-out"
	}
	text := fmt.tprintf("position: absolute; left: 50%%; top: 50%%; display: block; margin: 0; margin-left: %.3fpx; margin-top: %.3fpx; width: %.3fpx; height: %.3fpx; max-width: none; max-height: none; transform: rotate(%ddeg) scale(%.5f); cursor: %s",
		d.offset.x - nat.x / 2, d.offset.y - nat.y / 2, nat.x, nat.y, d.turns * IMAGE_QUARTER_DEG, z, cursor)
	if now, has := dom.get_attribute(p.doc, d.img, "style"); has && now == text { return }
	dom.set_attribute(p.doc, d.img, "style", text)
}

package e2e_scenarios

// An image opened by itself is a viewer (page/image_document.odin, browser/image_document_shell.odin): the image as
// drawn (getBoundingClientRect, transforms applied) after Ctrl+wheel, a pinch, + / - / 0, clicks, a drag, the wheel,
// the arrows, R / Shift+R and a double click; the window's cursor over it; the page's zoom left alone.

import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") VIEWER_SIZE :: [2]int{600, 500}
@(private = "file") VIEWER_DPI :: 192                     // twice 96: the view (CSS px) is narrower than the image
@(private = "file") IMAGE_PATH :: "/site/images/effects-photo.png"
@(private = "file") NATURAL :: [2]f64{320, 200}
@(private = "file") ZOOM_STEP :: 1.25                     // page/image_document.odin IMAGE_ZOOM_STEP
@(private = "file") PINCH :: -0.5                         // a touchpad's pinch: a fraction of a notch, with Ctrl
@(private = "file") WITHIN :: 0.6                         // CSS px of rounding
@(private = "file") DRAG_BY :: e2e.Point{-40, -20}
@(private = "file") WHEEL_NOTCHES :: 3
@(private = "file") WHEEL_AT :: e2e.Point{-60, -25}         // from the view's center
@(private = "file") CLICK_AT :: e2e.Point{-15, -10}         // (far enough from WHEEL_AT: no double click)

// The image's rectangle as drawn, CSS px of the view.
@(private = "file")
Rect :: struct { x, y, w, h: f64 }

@(private = "file")
rect :: proc(s: ^e2e.Session, loc := #caller_location) -> Rect {
	e2e.wait_frames(s, loc = loc)
	text := e2e.eval(s, `(r => [r.left, r.top, r.width, r.height].join(","))(document.images[0].getBoundingClientRect())`, loc = loc)
	parts := strings.split(text, ",", context.temp_allocator)
	v: [4]f64
	for p, i in parts[:4] { v[i], _ = strconv.parse_f64(p) }
	return {v[0], v[1], v[2], v[3]}
}

@(private = "file")
center :: proc(r: Rect) -> [2]f64 { return {r.x + r.w / 2, r.y + r.h / 2} }

@(private = "file")
near :: proc(a, b: f64) -> bool { return math.abs(a - b) <= WITHIN }

@(private = "file")
expect_size :: proc(t: ^testing.T, r: Rect, want: [2]f64, what: string, loc := #caller_location) {
	testing.expectf(t, near(r.w, want.x) && near(r.h, want.y), "%s: %.2f x %.2f, want %.2f x %.2f", what, r.w, r.h, want.x, want.y, loc = loc)
}

// The point of the image under `at` (fractions of its rectangle) is the same before and after.
@(private = "file")
expect_anchored :: proc(t: ^testing.T, before, after: Rect, at: e2e.Point, what: string, loc := #caller_location) {
	fb := [2]f64{(at.x - before.x) / before.w, (at.y - before.y) / before.h}
	fa := [2]f64{(at.x - after.x) / after.w, (at.y - after.y) / after.h}
	testing.expectf(t, math.abs(fb.x - fa.x) * after.w <= WITHIN && math.abs(fb.y - fa.y) * after.h <= WITHIN, "%s: the point under the pointer moved (%v -> %v)", what, fb, fa, loc = loc)
}

@(private = "file")
cursor_is :: proc(t: ^testing.T, s: ^e2e.Session, name, what: string, loc := #caller_location) {
	e2e.wait_frames(s, loc = loc)
	got := e2e.stats(s, loc).cursor.name
	testing.expectf(t, got == name, "%s: the cursor %q, want %q", what, got, name, loc = loc)
}

@(test)
image_viewer :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = VIEWER_SIZE, dpi = VIEWER_DPI, url = e2e.url(server, IMAGE_PATH)})
	e2e.wait_js(s, `document.images[0].complete && document.images[0].style.transform != ""`)
	// (innerWidth / innerHeight are whole numbers: the view as laid out, from a box over all of it)
	view_text := e2e.eval(s, `(() => { const d = document.createElement("div"); d.style.cssText = "position: fixed; inset: 0"; document.body.append(d); const r = d.getBoundingClientRect(); d.remove(); return r.width + "," + r.height; })()`)
	comma := strings.index_byte(view_text, ',')
	view: [2]f64
	view.x, _ = strconv.parse_f64(view_text[:comma])
	view.y, _ = strconv.parse_f64(view_text[comma + 1:])
	dpr := e2e.eval_f64(s, "devicePixelRatio")
	fit := min(1, view.x / NATURAL.x, view.y / NATURAL.y)
	testing.expectf(t, fit < 1, "the view (%v) is smaller than the image", view)
	mid := e2e.Point{view.x / 2, view.y / 2}

	// fitted and centered; a click would zoom in
	r0 := rect(s)
	expect_size(t, r0, NATURAL * fit, "the first view fits")
	testing.expectf(t, near(center(r0).x, mid.x) && near(center(r0).y, mid.y), "centered: %v", center(r0))
	e2e.hover(s, mid)
	cursor_is(t, s, "zoom-in", "over a fitted image larger than the view")

	// Ctrl+wheel: steps around the pointer (larger than the view both ways: no edge holds it); the page's zoom stays
	at := e2e.Point{mid.x + WHEEL_AT.x, mid.y + WHEEL_AT.y}
	e2e.scroll(s, -WHEEL_NOTCHES, at, ctrl = true)
	r1 := rect(s)
	expect_size(t, r1, NATURAL * fit * math.pow(ZOOM_STEP, WHEEL_NOTCHES), "Ctrl+wheel zooms the image in")
	expect_anchored(t, r0, r1, at, "Ctrl+wheel")
	testing.expectf(t, e2e.eval_f64(s, "devicePixelRatio") == dpr, "the page's zoom is left alone")

	// a pinch: a fraction of a step
	e2e.scroll(s, PINCH, at, ctrl = true)
	r2 := rect(s)
	expect_size(t, r2, NATURAL * fit * math.pow(ZOOM_STEP, WHEEL_NOTCHES - PINCH), "a pinch zooms by its fraction")
	expect_anchored(t, r1, r2, at, "a pinch")

	// a click when zoomed: fit again; another (elsewhere: no double click): 100 % around the pointer
	e2e.click_at(s, at)
	expect_size(t, rect(s), NATURAL * fit, "a click fits the zoomed image")
	r3 := rect(s)
	at2 := e2e.Point{mid.x + CLICK_AT.x, mid.y + CLICK_AT.y}
	e2e.click_at(s, at2)
	r4 := rect(s)
	expect_size(t, r4, NATURAL, "a click on the fitted image: 100 %")
	expect_anchored(t, r3, r4, at2, "the click's zoom")

	// + twice: around the center; larger than the view both ways: it can be grabbed
	e2e.key(s, "+ +")
	r5 := rect(s)
	expect_size(t, r5, NATURAL * ZOOM_STEP * ZOOM_STEP, "+ zooms in")
	testing.expect(t, r5.w > view.x && r5.h > view.y, "the image is larger than the view")
	e2e.hover(s, mid)
	cursor_is(t, s, "grab", "over an image larger than the view")

	// a drag moves it with the pointer, grabbing
	e2e.press(s, mid)
	e2e.hover(s, {mid.x + DRAG_BY.x / 2, mid.y + DRAG_BY.y / 2})
	e2e.hover(s, {mid.x + DRAG_BY.x, mid.y + DRAG_BY.y})
	cursor_is(t, s, "grabbing", "while dragging")
	e2e.release(s, {mid.x + DRAG_BY.x, mid.y + DRAG_BY.y})
	r6 := rect(s)
	testing.expectf(t, near(r6.x - r5.x, DRAG_BY.x) && near(r6.y - r5.y, DRAG_BY.y), "the drag moved it by %v, want %v", [2]f64{r6.x - r5.x, r6.y - r5.y}, DRAG_BY)
	testing.expectf(t, near(r6.w, r5.w), "a drag does not zoom (%.2f, was %.2f)", r6.w, r5.w)

	// a drag far past the edge: the edge stops at the view's
	e2e.drag(s, mid, {mid.x + view.x, mid.y})
	testing.expectf(t, near(rect(s).x, 0), "dragged far right, the left edge stops at the view's: %.2f", rect(s).x)

	// the wheel and the arrows move it as they would scroll
	before := rect(s)
	e2e.scroll(s, 1, mid)
	testing.expectf(t, rect(s).y < before.y, "the wheel moves the image up (%.2f, was %.2f)", rect(s).y, before.y)
	before = rect(s)
	e2e.key(s, "Right")
	testing.expectf(t, rect(s).x < before.x, "Right moves it left (%.2f, was %.2f)", rect(s).x, before.x)

	// - zooms out around the center; 0 fits
	e2e.key(s, "-")
	expect_size(t, rect(s), NATURAL * ZOOM_STEP, "- zooms out")
	e2e.key(s, "0")
	expect_size(t, rect(s), NATURAL * fit, "0 fits")

	// R: a quarter turn, the turned image fitted; Shift+R back
	e2e.key(s, "r")
	turned := [2]f64{NATURAL.y, NATURAL.x}
	turned_fit := min(1, view.x / turned.x, view.y / turned.y)
	expect_size(t, rect(s), turned * turned_fit, "R turns it a quarter")
	testing.expectf(t, strings.contains(e2e.eval(s, "document.images[0].style.transform"), "rotate(90deg)"), "R turns it clockwise")
	e2e.key(s, "Shift+r")
	expect_size(t, rect(s), NATURAL * fit, "Shift+R turns it back")

	// a double click resets: no turn, fitted
	e2e.key(s, "r r +")
	e2e.click_at(s, mid, count = 2)
	r7 := rect(s)
	expect_size(t, r7, NATURAL * fit, "a double click resets")
	testing.expectf(t, strings.contains(e2e.eval(s, "document.images[0].style.transform"), "rotate(0deg)"), "and the turn: %s", e2e.eval(s, "document.images[0].style.transform"))
	testing.expectf(t, near(center(r7).x, mid.x) && near(center(r7).y, mid.y), "and the place: %v", center(r7))
}

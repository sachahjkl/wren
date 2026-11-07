package e2e_scenarios

// The page's cursors (examples/site/cursors.html): the pointer goes over each case and the cursor the window asked for is read. A cursor the system has is the
// system's, one it has not is drawn, `none` hides the pointer, an image is the image at the window's scale with its hotspot. A press held on the page keeps its
// cursor while the pointer moves elsewhere. What the system then shows for them, and the size of a drawn one, is real_window.odin's.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") CURSOR_SIZE :: [2]int{1400, 1000}   // (the cases are scrolled to; every frame of it is drawn, on a runner by the processor)
@(private = "file") CURSOR_DPI :: 168                  // a scale that is not a whole number: an image's rounding shows
@(private = "file") CURSOR_SCALE :: f64(CURSOR_DPI) / e2e.DPI_ONE
@(private = "file") IMAGE_CSS_PX :: 32
@(private = "file") PNG_HOTSPOT :: [2]f64{16, 16}
@(private = "file") SVG_HOTSPOT :: [2]f64{3, 29}
@(private = "file") HOTSPOT_WITHIN :: 1                // device px
@(private = "file") TITLE_BAR_POINT :: e2e.Point{900, 40}  // window px: the empty caption, below the resize band

@(private = "file") SYSTEM_KEYWORDS := [?]string{
	"default", "help", "pointer", "progress", "wait", "crosshair", "text", "move", "not-allowed", "all-scroll",
	"n-resize", "e-resize", "s-resize", "w-resize", "ne-resize", "nw-resize", "se-resize", "sw-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
}
@(private = "file") DRAWN_KEYWORDS := [?]string{"context-menu", "cell", "vertical-text", "alias", "copy", "no-drop", "grab", "grabbing", "col-resize", "row-resize", "zoom-in", "zoom-out"}
// Who shows those: the toolkit draws them on Windows, which has none of its own; an X or Wayland cursor theme has them all.
@(private = "file") DRAWN_SOURCE :: "drawn" when ODIN_OS == .Windows else "system"

// The pointer over element `id`, at this fraction of its box; the page has what it asked for (its images) and the frames have seen it.
@(private = "file")
over :: proc(s: ^e2e.Session, id: string, fx := 0.5, fy := 0.5, loc := #caller_location) -> e2e.Cursor_Shown {
	b := e2e.eval(s, fmt.tprintf(`(() => {{ const e = document.getElementById(%q); e.scrollIntoView({{block: "center"}}); const r = e.getBoundingClientRect(); return (r.left + r.width * %v) + "," + (r.top + r.height * %v); }})()`, id, fx, fy), loc = loc)
	e2e.wait_frames(s, loc = loc)
	comma := strings.index_byte(b, ',')
	x, _ := strconv.parse_f64(b[:comma])
	y, _ := strconv.parse_f64(b[comma + 1:])
	e2e.hover(s, {x, y}, loc = loc)
	e2e.wait_idle(s, loc = loc)
	e2e.wait_frames(s, loc = loc)
	return e2e.stats(s, loc).cursor
}

@(private = "file")
expect_cursor :: proc(t: ^testing.T, s: ^e2e.Session, id, name: string, source := "system", fx := 0.5, fy := 0.5, loc := #caller_location) {
	c := over(s, id, fx, fy, loc)
	testing.expectf(t, c.name == name && c.source == source && !c.custom, "over #%s: the %s cursor %s, got %v", id, source, name, c, loc = loc)
}

@(private = "file")
expect_image :: proc(t: ^testing.T, s: ^e2e.Session, id: string, hotspot: [2]f64, loc := #caller_location) {
	over(s, id, loc = loc)
	// (a first look at an image at this size starts its decoding, on another thread: the frame after that one has it, or the window's cursor is the fallback until then)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).cursor.custom }, "the image to be the cursor", loc = loc)
	c := e2e.stats(s, loc).cursor
	px := int(math.round(IMAGE_CSS_PX * CURSOR_SCALE))
	testing.expectf(t, c.custom && c.size == {px, px}, "over #%s: the image at the window's scale (%d px), got %v", id, px, c, loc = loc)
	if hotspot != {} {
		want := hotspot * CURSOR_SCALE
		testing.expectf(t, math.abs(f64(c.hotspot.x) - want.x) <= HOTSPOT_WITHIN && math.abs(f64(c.hotspot.y) - want.y) <= HOTSPOT_WITHIN, "over #%s: the hotspot at %v, got %v", id, want, c.hotspot, loc = loc)
	}
}

@(test)
page_cursors :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = CURSOR_SIZE, dpi = CURSOR_DPI, url = e2e.url(server, "/site/cursors.html")})
	e2e.wait_chrome_still(s)

	for name in SYSTEM_KEYWORDS { expect_cursor(t, s, fmt.tprintf("k-%s", name), name) }
	for name in DRAWN_KEYWORDS { expect_cursor(t, s, fmt.tprintf("k-%s", name), name, DRAWN_SOURCE) }
	expect_cursor(t, s, "k-auto", "default")              // (a cell's text cannot be selected: auto is the arrow)
	expect_cursor(t, s, "k-none", "none", "hidden")

	expect_image(t, s, "png", PNG_HOTSPOT)                // the 32 px target, its hotspot at its center
	expect_image(t, s, "svg", SVG_HOTSPOT)                // the pen, rasterized at the scale, its hotspot at its tip
	expect_image(t, s, "set", {})                         // image-set(): the candidate for the screen
	expect_cursor(t, s, "huge", "not-allowed")            // too large: the fallback
	expect_cursor(t, s, "missing", "grab", DRAWN_SOURCE)       // no such image: the fallback
	expect_cursor(t, s, "hidden", "none", "hidden")

	// what `auto` does
	expect_cursor(t, s, "text", "text", fx = 0.15, fy = 0.2)
	expect_cursor(t, s, "link", "pointer")
	expect_cursor(t, s, "noselect", "default")
	expect_cursor(t, s, "field", "text")
	expect_cursor(t, s, "area", "text")
	expect_cursor(t, s, "button", "default")
	expect_cursor(t, s, "select", "default")
	expect_cursor(t, s, "range", "default")
	expect_cursor(t, s, "disabled", "default")
	expect_cursor(t, s, "editable", "text", fx = 0.9)
	expect_cursor(t, s, "over", "copy", DRAWN_SOURCE)          // pointer-events: none: the cursor of what is under
	expect_cursor(t, s, "scroll", "help", fx = 0.4)       // a scroll box: its cursor
	expect_cursor(t, s, "scroll", "default", fx = 0.985)  // its scroll bar: the arrow

	// a press held on the grab cell keeps grab while the pointer goes over the pointer cell, until released
	over(s, "k-grab")
	at := e2e.Point{e2e.eval_f64(s, `(r => r.left + r.width / 2)(document.getElementById("k-grab").getBoundingClientRect())`), e2e.eval_f64(s, `(r => r.top + r.height / 2)(document.getElementById("k-grab").getBoundingClientRect())`)}
	e2e.press(s, at)
	expect_cursor(t, s, "k-pointer", "grab", DRAWN_SOURCE)
	e2e.release(s, at)
	expect_cursor(t, s, "k-pointer", "pointer", fx = 0.4)

	// the chrome keeps its own above the page
	e2e.hover(s, TITLE_BAR_POINT, .Window)
	testing.expect_value(t, e2e.stats(s).cursor.name, "default")
}

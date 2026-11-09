package e2e_scenarios

// The painting start page's shortcuts (src/browser/newtab_art_page.odin): inline <svg> icons in currentColor, under a
// drop-shadow filter, on chips with a backdrop-filter. A hover gives an icon a new colour, so new markup that the decoding
// threads parse and rasterise: every frame meanwhile shows the icon in its old colour (it blinked out for a frame or more),
// then the new one comes. The threads are held through the hover, so that the frames before the new picture are there.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:images"

@(private = "file") HOVER_SIZE :: [2]int{1100, 700}
@(private = "file") HOVER_FRAMES :: 12             // consecutive frames captured with the new picture held back
@(private = "file") INK_DIFFERENCE :: 90           // summed channel difference from the chip's own background that counts as the icon's ink
@(private = "file") INK_KEPT :: 0.8                // of the icon's ink before the hover, at least, in every frame
@(private = "file") BACKGROUND_INSET :: 6          // px left of the icon: the chip's padding, its background

@(private = "file")
Icon :: struct {
	x, y, w, h: int,   // page px
}

// The icon's ink in a capture of the page: pixels unlike the chip's background beside it, and their summed brightness.
@(private = "file")
ink :: proc(img: e2e.Image, ic: Icon) -> (n: int, light: int) {
	bg := e2e.pixel(img, ic.x - BACKGROUND_INSET, ic.y + ic.h / 2)
	for y in ic.y ..< ic.y + ic.h {
		for x in ic.x ..< ic.x + ic.w {
			p := e2e.pixel(img, x, y)
			d := abs(int(p.r) - int(bg.r)) + abs(int(p.g) - int(bg.g)) + abs(int(p.b) - int(bg.b))
			if d > INK_DIFFERENCE { n += 1; light += int(p.r) + int(p.g) + int(p.b) }
		}
	}
	return
}

@(private = "file")
first_icon :: proc(s: ^e2e.Session) -> Icon {
	b := e2e.eval(s, `(r => [r.left, r.top, r.width, r.height].map(Math.round).join(","))(document.querySelector(".art-chip svg").getBoundingClientRect())`)
	v: [4]int
	for f, i in strings.split(b, ",", context.temp_allocator) { if i < len(v) { v[i], _ = strconv.parse_int(f) } }
	return Icon{v[0], v[1], v[2], v[3]}
}

@(test)
inline_svg_kept_through_a_hover :: proc(t: ^testing.T) {
	// no painting (no source: the page's own gradient): the icon's ink is measured against the chip's background, and a
	// light painting under the translucent chip, one at random in two, left it under INK_DIFFERENCE (0 px) though it was drawn
	s := e2e.start(t, {size = HOVER_SIZE, prefs = {"browser.newtab.art.enabled=true", "browser.newtab.art.sources="}, url = "about:home"})
	e2e.wait_selector(s, ".art-chip svg", visible = true)
	ic := first_icon(s)
	e2e.wait_until(s, ic, proc(s: ^e2e.Session, ic: Icon) -> bool { n, _ := ink(e2e.capture(s, {target = .Page}), ic); return n > 0 }, "the icon drawn")
	before, before_light := ink(e2e.capture(s, {target = .Page}), ic)

	images.decoder_hold(true)
	defer images.decoder_hold(false)   // (a failed call ends the test here)
	e2e.hover(s, {f64(ic.x + ic.w / 2), f64(ic.y + ic.h / 2)})
	for i in 0 ..< HOVER_FRAMES {
		n, _ := ink(e2e.capture(s, {target = .Page}), ic)
		testing.expectf(t, f64(n) >= f64(before) * INK_KEPT, "frame %d of the hover: the icon's ink %d px, %d before", i, n, before)
	}
	images.decoder_hold(false)

	// the hover's colour (white, from 94 % white) once its picture is made
	Lit :: struct { ic: Icon, light: int }
	e2e.wait_until(s, Lit{ic, before_light}, proc(s: ^e2e.Session, l: Lit) -> bool { _, light := ink(e2e.capture(s, {target = .Page}), l.ic); return light > l.light }, fmt.tprintf("the icon lighter than %d", before_light))
}

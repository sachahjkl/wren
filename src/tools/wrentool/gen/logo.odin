package gen

// The Wren browser logo, drawn by the toolkit's paint package: a rounded square with a soft vertical gradient and a darker border (same
// family as the gui_toolkit logo), carrying a white wren: round body, round head, thin beak, the wren's cocked-up tail, standing on a
// white perch. The eye and the wing line are holes that show the body gradient through. A semicircular notch in the top edge of the
// square nods to WebAssembly (the only execution engine of the browser).
// Small sizes use a simpler drawing (detail level picked from the size by detail_for): 2 = full (64+), 1 = no legs, perch or wing,
// bigger eye (32-48), 0 = also no eye and no notch, larger bird, thicker tail, thin margin (16-24).
// The dev variant marks the development builds (every build but build.bat release): the same bird on a blueprint, a cyanotype blue
// square ruled with a fine white grid drawn per size on whole pixels (draw_grid), gone at 32 px and below.
//   wrentool logo [-Out assets] [-Variant amber|dev|violet|amber-plain]
// Writes logo.png (512), logo_256/64/32/16.png and wren.ico (16/24/32/48/64/128/256) into -Out; for -Variant dev, into assets/dev by
// default, the icon named wren_dev.ico (src/browser/wren_dev.rc).
//   wrentool logo -Out build/logo_variants -Variant violet -Single
// With -Single, only writes logo_<variant>.png (512) and a check sheet logo_<variant>_sizes.png: every size on a dark and on a light
// background, plus 48/32/24/16 magnified (nearest neighbour) on both.

import "core:fmt"
import "core:math"
import "core:os"
import "wb:tools/tooling"
import paint "../../../../ext/gui_toolkit/src/paint"

// Drawn at LOGO_UNITS * LOGO_SUPERSAMPLE in LOGO_UNITS-unit coordinates, then scaled down.
LOGO_SUPERSAMPLE :: 4
LOGO_UNITS :: 512
LOGO_FILE_SIZES :: [?]int{512, 256, 64, 32, 16}
LOGO_ICO_SIZES :: [?]int{16, 24, 32, 48, 64, 128, 256}
// From this size an icon's picture is a PNG; below, a classic DIB.
LOGO_ICO_PNG_FROM :: 64
// The wing's curve, cut in lines that stray this far from it (in units).
WING_FLATNESS :: 0.35
// Scaled down in steps of at most this factor, so the bicubic filter stays clean down to 16 px.
LOGO_SHRINK_STEP :: 4

Logo_Variant :: struct {
	name:                                    string,
	body_top, body_bottom, edge_top, edge_bottom: u32,
	notched:                                 bool,   // the WebAssembly notch
	layered:                                 bool,   // a grid between the body and the bird (render)
}

LOGO_VARIANTS :: [?]Logo_Variant{
	{"amber", 0xf39a2e, 0xc25a0c, 0xd9781c, 0x8c3a05, true, false},
	{"dev", 0x2363b8, 0x153f86, 0x1a4f9c, 0x0b2560, true, true},
	{"violet", 0x7b63f2, 0x4a2fc0, 0x5f47d8, 0x2c1984, true, false},
	{"amber-plain", 0xf39a2e, 0xc25a0c, 0xd9781c, 0x8c3a05, false, false},
}

// The square: 400 units with a 56 margin (like the toolkit), almost full-bleed at the smallest detail level; the notch is dropped at
// the smallest detail level, where it would read as a dent.
Logo_Geometry :: struct {
	m, r, w, nr, bw: f32,   // margin, corner radius, width, notch radius, border width
}

// What draw_layer draws: the whole logo, or for the variants that put something between the body and the bird (the blueprint grid),
// one layer of it.
Logo_Layer :: enum {
	All,
	Fill,   // the body
	Edge,   // border and highlight
	Bird,   // the wren alone, its eye and wing cut out as transparent holes
}

run_logo :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Out= -Variant= -Single")
	if !ok { return 2 }
	name := tooling.flag(f, "-Variant", "amber")
	variant: Logo_Variant
	found := false
	for v in LOGO_VARIANTS { if v.name == name { variant, found = v, true } }
	if !found { fmt.eprintfln("logo: -Variant amber, dev, violet or amber-plain, not %s", name); return 2 }
	out := tooling.flag(f, "-Out", variant.name == "dev" ? "assets/dev" : "assets")
	if err := os.make_directory_all(out); err != nil && !os.is_dir(out) { fmt.eprintfln("logo: %s cannot be made", out); return 1 }

	if tooling.flag_has(f, "-Single") {
		big := logo_render(variant, 512, 2)
		defer paint.canvas_destroy(&big)
		sheet := logo_sheet(variant)
		defer paint.canvas_destroy(&sheet)
		single := fmt.tprintf("%s/logo_%s.png", out, variant.name)
		sizes := fmt.tprintf("%s/logo_%s_sizes.png", out, variant.name)
		if !paint.write_png(big, single) || !paint.write_png(sheet, sizes) { fmt.eprintfln("logo: %s cannot be written", out); return 1 }
		fmt.printfln("wrote %s and %s", single, sizes)
		return 0
	}
	for s in LOGO_FILE_SIZES {
		path := s == 512 ? fmt.tprintf("%s/logo.png", out) : fmt.tprintf("%s/logo_%d.png", out, s)
		c := logo_render(variant, s, detail_for(s))
		written := paint.write_png(c, path)
		paint.canvas_destroy(&c)
		if !written { fmt.eprintfln("logo: %s cannot be written", path); return 1 }
	}
	sizes := LOGO_ICO_SIZES
	entries: [len(LOGO_ICO_SIZES)]paint.Ico_Entry
	for s, i in sizes {
		c := logo_render(variant, s, detail_for(s))
		entries[i] = {s, s >= LOGO_ICO_PNG_FROM ? paint.png_encode(c, context.temp_allocator) : paint.dib_encode(c, context.temp_allocator)}
		paint.canvas_destroy(&c)
	}
	ico := fmt.tprintf("%s/%s", out, variant.name == "dev" ? "wren_dev.ico" : "wren.ico")
	if os.write_entire_file(ico, paint.ico_encode(entries[:], context.temp_allocator)) != nil { fmt.eprintfln("logo: %s cannot be written", ico); return 1 }
	fmt.printfln("wrote %s/logo.png, logo_256/64/32/16.png, %s", out, ico)
	return 0
}

detail_for :: proc(size: int) -> int { return size <= 24 ? 0 : size <= 48 ? 1 : 2 }

logo_geometry :: proc(v: Logo_Variant, detail: int) -> (g: Logo_Geometry) {
	if detail == 0 { g.m, g.r, g.bw = 20, 110, 18 } else { g.m, g.r, g.bw = 56, 100, 10 }
	g.w = LOGO_UNITS - 2 * g.m
	if v.notched && detail > 0 { g.nr = 34 * g.w / 400 }
	return
}

// A rounded rectangle; when nr > 0, a semicircular notch of radius nr is cut into the middle of the top edge.
notch_rect :: proc(p: ^paint.Path, x, y, w, h, r, nr: f32) {
	d := 2 * r
	paint.start_figure(p)
	paint.arc(p, x, y, d, d, 180, 90)
	if nr > 0 {
		cx := x + w / 2
		paint.line_to(p, x + r, y)
		paint.line_to(p, cx - nr, y)
		paint.arc(p, cx - nr, y - nr, 2 * nr, 2 * nr, 180, -180)
	}
	paint.arc(p, x + w - d, y, d, d, 270, 90)
	paint.arc(p, x + w - d, y + h - d, d, d, 0, 90)
	paint.arc(p, x, y + h - d, d, d, 90, 90)
	paint.close(p)
}

// An ellipse centred on (cx, cy), rotated by `degrees` (clockwise, y down).
rotated_ellipse :: proc(p: ^paint.Path, cx, cy, w, h, degrees: f32) {
	paint.ellipse(p, cx - w / 2, cy - h / 2, w, h)
	paint.path_transform(p, paint.rotate_at(paint.IDENTITY, degrees, cx, cy))
}

// A rounded rectangle centred on (cx, cy), rotated by `degrees`.
rotated_round_rect :: proc(p: ^paint.Path, cx, cy, w, h, r, degrees: f32) {
	paint.round_rect(p, cx - w / 2, cy - h / 2, w, h, r)
	paint.path_transform(p, paint.rotate_at(paint.IDENTITY, degrees, cx, cy))
}

// A layer of the logo at LOGO_UNITS * LOGO_SUPERSAMPLE pixels.
draw_layer :: proc(v: Logo_Variant, detail: int, what: Logo_Layer) -> paint.Canvas {
	N :: LOGO_UNITS * LOGO_SUPERSAMPLE
	c := paint.canvas_make(N, N)
	// (the committed pictures were GDI+'s: this puts the shapes where it put them)
	c.transform = paint.scale(paint.translate(paint.IDENTITY, paint.GDIPLUS_OFFSET, paint.GDIPLUS_OFFSET), LOGO_SUPERSAMPLE, LOGO_SUPERSAMPLE)
	g := logo_geometry(v, detail)
	m, r, w, nr, bw := g.m, g.r, g.w, g.nr, g.bw
	fill := paint.linear({0, m}, {0, LOGO_UNITS - m}, paint.hex(v.body_top), paint.hex(v.body_bottom), .Repeat)
	path: paint.Path
	defer paint.path_destroy(&path)
	if what == .All || what == .Fill {
		notch_rect(&path, m, m, w, w, r, nr)
		paint.fill(&c, path, fill, .Even_Odd)
	}
	if what == .Fill { return c }
	if what != .Bird {
		// darker border just inside the edge (a gradient too, so it stays darker than the body everywhere)
		edge := paint.linear({0, m}, {0, LOGO_UNITS - m}, paint.hex(v.edge_top), paint.hex(v.edge_bottom), .Repeat)
		clear(&path.verbs); clear(&path.points)
		notch_rect(&path, m + bw / 2, m + bw / 2, w - bw, w - bw, r - bw / 2, nr > 0 ? nr + bw / 2 : 0)
		paint.stroke(&c, path, {width = bw}, edge)
		// a faint highlight along the top inner edge
		if detail > 0 {
			clear(&path.verbs); clear(&path.points)
			notch_rect(&path, m + bw + 1, m + bw + 1, w - 2 * bw - 2, w - 2 * bw - 2, r - bw, nr > 0 ? nr + bw + 1 : 0)
			paint.stroke(&c, path, {width = 2}, paint.solid(paint.hex(0xFFFFFF, 40)))
		}
		if what == .Edge { return c }
	}

	// the wren, facing right, nudged left so the bird (not its bounding box) sits in the middle; drawn larger at the lower detail
	// levels. Every shape is a path moved by bm; a hole is filled with the untouched body paint, or (the bird layer) cleared, so that
	// what is under the layer (grid lines) shows through it.
	k: f32 = detail == 0 ? 1.22 : detail == 1 ? 1.1 : 1.0
	bm := paint.translate(paint.scale(paint.translate(paint.IDENTITY, 256, 268), k, k), -256 - 14, -268)
	Put :: struct { c: ^paint.Canvas, bm: paint.Matrix, hole: paint.Paint, cut: bool }
	put := Put{&c, bm, fill, what == .Bird}
	white :: proc(put: Put, p: ^paint.Path, rule := paint.Fill_Rule.Even_Odd) {
		paint.path_transform(p, put.bm)
		paint.fill(put.c, p^, paint.solid(paint.hex(0xFFFFFF)), rule)
		paint.path_destroy(p)
	}
	hole :: proc(put: Put, p: ^paint.Path, rule := paint.Fill_Rule.Even_Odd) {
		paint.path_transform(p, put.bm)
		if put.cut {
			paint.set_clip(put.c, p^, rule)
			paint.clear(put.c)
			paint.reset_clip(put.c)
		} else {
			paint.fill(put.c, p^, put.hole, rule)
		}
		paint.path_destroy(p)
	}
	round_pen := paint.Pen{width = 12, cap = .Round}
	if detail == 2 {
		// perch and legs
		perch: paint.Path
		paint.round_rect(&perch, 150, 384, 220, 26, 13)
		white(put, &perch)
		legs: paint.Path
		paint.line_to(&legs, 248, 340); paint.line_to(&legs, 242, 392)
		paint.start_figure(&legs)
		paint.line_to(&legs, 278, 340); paint.line_to(&legs, 280, 392)
		wide := paint.widen(legs, round_pen)
		paint.path_destroy(&legs)
		white(put, &wide, .Non_Zero)
	}
	// cocked tail (a narrow rounded bar standing almost upright), body, head
	tw: f32 = detail == 0 ? 62 : 52
	tail, body, head: paint.Path
	rotated_round_rect(&tail, 176, 200, tw, 184, tw / 2, -20)
	white(put, &tail)
	rotated_ellipse(&body, 262, 292, 214, 160, -14)
	white(put, &body)
	rotated_ellipse(&head, 330, 224, 124, 124, 0)
	white(put, &head)
	// thin beak, slightly drooping
	beak: paint.Path
	if detail == 0 { paint.polygon(&beak, {{376, 192}, {440, 232}, {380, 250}}) } else { paint.polygon(&beak, {{378, 198}, {434, 230}, {382, 242}}) }
	white(put, &beak)
	if detail >= 1 {
		// eye hole
		er: f32 = detail == 1 ? 16 : 13
		eye: paint.Path
		rotated_ellipse(&eye, 346, 214, 2 * er, 2 * er, 0)
		hole(put, &eye)
	}
	if detail == 2 {
		// wing line: a curve cut through the body, sweeping from the shoulder back toward the tail
		wing: paint.Path
		paint.move_to(&wing, 306, 264)
		paint.cubic_to(&wing, 286, 302, 248, 320, 208, 312)
		// (GDI+'s Widen cut the curve in 8 lines, which show: this flatness makes the same 8 here)
		wide := paint.widen(wing, round_pen, WING_FLATNESS)
		paint.path_destroy(&wing)
		hole(put, &wide, .Non_Zero)
	}
	return c
}

// A layer scaled down to `size` in steps of at most LOGO_SHRINK_STEP; `big` is destroyed.
shrink :: proc(big: paint.Canvas, size: int) -> paint.Canvas {
	cur := big
	for cur.width > size {
		next := paint.resize(cur, max(size, cur.width / LOGO_SHRINK_STEP), max(size, cur.width / LOGO_SHRINK_STEP))
		paint.canvas_destroy(&cur)
		cur = next
	}
	return cur
}

// .NET's Math.Round and PowerShell's [int]: a half goes to the even neighbour (the grid's lines are where the old script put them).
round_even :: proc(x: f32) -> int {
	f := math.floor(x)
	d := x - f
	n := int(f)
	if d > 0.5 || (d == 0.5 && n % 2 != 0) { n += 1 }
	return n
}

// A rectangle of whole pixels, filled over what is there.
fill_rect :: proc(c: ^paint.Canvas, x, y, w, h: f32, color: paint.Color) {
	p: paint.Path
	defer paint.path_destroy(&p)
	paint.rect(&p, x, y, w, h)
	paint.fill(c, p, paint.solid(color))
}

// The blueprint grid, drawn at the output size (not shrunk from 512, which would blur it into a haze): 1-pixel lines on whole pixels,
// mirrored about the middle of the square, minor and major lines while they are far enough apart to read, none at all at 32 px and
// below (there the blue and the bird say it). Clipped to the inside of the border, without antialiasing.
draw_grid :: proc(c: ^paint.Canvas, v: Logo_Variant, size, detail: int) {
	if size <= 32 { return }
	g := logo_geometry(v, detail)
	k := f32(size) / LOGO_UNITS
	lo, hi := (g.m + g.bw) * k, (LOGO_UNITS - g.m - g.bw) * k
	inside: paint.Path
	defer paint.path_destroy(&inside)
	notch_rect(&inside, lo, lo, hi - lo, hi - lo, (g.r - g.bw) * k, g.nr > 0 ? (g.nr + g.bw) * k : 0)
	paint.set_clip(c, inside, .Even_Odd, antialias = false)
	defer paint.reset_clip(c)
	// one cell of 25 units, a major line every 4 cells, one through the middle (the grid is mirrored about the middle of pixel
	// size/2: every line on whole pixels)
	Line :: struct { offset, alpha: int }   // pixels from the middle, 0 to 255
	lines := make([dynamic]Line, context.temp_allocator)
	minor := 25 * k
	if 4 * minor >= 10 {
		for i := 0; f32(i) * minor < f32(size) / 2; i += 1 {
			major := i % 4 == 0
			if !major && minor < 7 { continue }
			append(&lines, Line{round_even(f32(i) * minor), major ? 70 : 30})
		}
	} else {
		// 48: a coarse grid of four cells across
		step := (hi - lo) / 4
		append(&lines, Line{0, 60}, Line{round_even(step), 60})
	}
	middle := size / 2
	for l in lines {
		color := paint.hex(0xFFFFFF, l.alpha)
		at := [2]int{middle - l.offset, middle + l.offset}
		for p in at[:l.offset == 0 ? 1 : 2] {
			fill_rect(c, f32(p), 0, 1, f32(size), color)
			fill_rect(c, 0, f32(p), f32(size), 1, color)
		}
	}
	// a dimension line under the perch, the length of the perch, with end ticks (from 128 px, where it reads as one)
	if size >= 128 && detail == 2 {
		color := paint.hex(0xFFFFFF, 150)
		lw := f32(max(1, round_even(f32(size) / 256)))
		x0, x1, y := f32(round_even(136 * k)), f32(round_even(356 * k)), f32(round_even(426 * k))
		t := f32(max(2, round_even(9 * k)))
		fill_rect(c, x0, y, x1 - x0 + lw, lw, color)
		for x in ([2]f32{x0, x1}) { fill_rect(c, x, y - t, lw, 2 * t + lw, color) }
	}
}

// `src` drawn over `dst` at the same size; `src` is destroyed.
over :: proc(dst: ^paint.Canvas, src: paint.Canvas) {
	src := src
	paint.draw_canvas(dst, src, {0, 0, dst.width, dst.height}, {0, 0, src.width, src.height}, .Nearest)
	paint.canvas_destroy(&src)
}

// The logo at `size` x `size`.
logo_render :: proc(v: Logo_Variant, size, detail: int) -> paint.Canvas {
	if !v.layered { return shrink(draw_layer(v, detail, .All), size) }
	b := shrink(draw_layer(v, detail, .Fill), size)
	draw_grid(&b, v, size, detail)
	over(&b, shrink(draw_layer(v, detail, .Edge), size))
	over(&b, shrink(draw_layer(v, detail, .Bird), size))
	return b
}

// Every size side by side, then 48/32/24/16 magnified (nearest neighbour) on a second row to check the small sizes pixel by pixel;
// once on a dark grey (a dark taskbar) and once on a light one.
logo_sheet :: proc(v: Logo_Variant) -> paint.Canvas {
	SIZES :: [?]int{256, 128, 64, 48, 32, 24, 16}
	MAGNIFIED :: [?]int{48, 32, 24, 16}
	GAP :: 16
	ZOOM :: 192
	ZOOM_CELL :: ZOOM + GAP
	BAND :: 288 + ZOOM_CELL
	sizes := SIZES
	magnified := MAGNIFIED
	imgs: [len(SIZES)]paint.Canvas
	for s, i in sizes { imgs[i] = logo_render(v, s, detail_for(s)) }
	defer for &img in imgs { paint.canvas_destroy(&img) }
	sw := 0
	for s in sizes { sw += s + GAP }
	sheet := paint.canvas_make(max(sw + GAP, len(MAGNIFIED) * ZOOM_CELL + GAP), 2 * BAND)
	bands := [2][2]int{{0, 0x2b2f38}, {BAND, 0xeef0f4}}
	for band in bands {
		y0 := band[0]
		fill_rect(&sheet, 0, f32(y0), f32(sheet.width), BAND, paint.hex(u32(band[1])))
		x := GAP
		for s, i in sizes {
			paint.draw_canvas(&sheet, imgs[i], {x, y0 + GAP, s, s}, {0, 0, s, s}, .Nearest)
			x += s + GAP
			for m, j in magnified {
				if m == s { paint.draw_canvas(&sheet, imgs[i], {GAP + ZOOM_CELL * j, y0 + 288, ZOOM, ZOOM}, {0, 0, s, s}, .Nearest) }
			}
		}
	}
	return sheet
}

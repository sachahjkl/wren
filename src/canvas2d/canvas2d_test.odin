package canvas2d

import "core:math"
import "core:testing"

@(private = "file")
make_ctx :: proc(w, h: int) -> (c: Context, b: ^Bitmap) {
	b = new(Bitmap)
	b^, _ = bitmap_create(w, h)
	context_init(&c, b, DEFAULT_OPTIONS)
	return
}

@(private = "file")
free_ctx :: proc(c: ^Context, b: ^Bitmap) {
	context_destroy(c)
	bitmap_destroy(b)
	free(b)
}

@(private = "file")
px :: proc(b: ^Bitmap, x, y: int) -> [4]u8 {
	p := b.pix[(y * b.w + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
near :: proc(a, b: u8, tol: int) -> bool { return abs(int(a) - int(b)) <= tol }

@(private = "file")
alpha_sum :: proc(b: ^Bitmap) -> f64 {
	s := 0.0
	for i := 3; i < len(b.pix); i += 4 { s += f64(b.pix[i]) / 255 }
	return s
}

@(test)
fill_rect_aligned :: proc(t: ^testing.T) {
	c, b := make_ctx(20, 20)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {1, 0, 0, 1})
	ctx_fill_rect(&c, 5, 5, 10, 10)
	testing.expect_value(t, px(b, 5, 5), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(b, 14, 14), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(b, 4, 5), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, px(b, 15, 14), [4]u8{0, 0, 0, 0})
	testing.expect_value(t, px(b, 10, 15), [4]u8{0, 0, 0, 0})
	testing.expect(t, bitmap_has_dirty(b), "the drawing marks the bitmap dirty")
	testing.expect_value(t, b.dirty_min, [2]int{0, 0})   // (the creation marked all; the bounds only grow)
}

@(test)
fill_rect_fractional :: proc(t: ^testing.T) {
	c, b := make_ctx(10, 10)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {0, 0, 1, 1})
	ctx_fill_rect(&c, 2.5, 2.25, 3, 3)
	// the column at x = 2 is half covered, row 2 is three quarters covered: 0.5 * 0.75
	testing.expect(t, near(px(b, 2, 3)[3], 128, 1), "half-covered column")
	testing.expect(t, near(px(b, 3, 2)[3], 191, 1), "three-quarter row")
	testing.expect(t, near(px(b, 2, 2)[3], 96, 1), "corner pixel: 0.5 * 0.75")
	testing.expect_value(t, px(b, 3, 3), [4]u8{0, 0, 255, 255})
	// the sum of the coverage is the area exactly
	testing.expect(t, abs(alpha_sum(b) - 9) < 0.05, "area")
}

@(test)
circle_area_and_symmetry :: proc(t: ^testing.T) {
	c, b := make_ctx(64, 64)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {0, 0, 0, 1})
	path_arc(&c.path, c.state.ctm, 32, 32, 20, 0, 2 * math.PI, false)
	ctx_fill(&c, .Nonzero)
	area := math.PI * 400
	testing.expect(t, abs(alpha_sum(b) - area) / area < 0.005, "circle area within half a percent")
	testing.expect_value(t, px(b, 32, 32)[3], 255)
	testing.expect_value(t, px(b, 2, 2)[3], 0)
	// symmetric about the center (32, 32)
	testing.expect(t, near(px(b, 12, 32)[3], px(b, 51, 32)[3], 2), "left-right symmetry")
	testing.expect(t, near(px(b, 32, 12)[3], px(b, 32, 51)[3], 2), "top-bottom symmetry")
}

@(test)
triangle_coverage :: proc(t: ^testing.T) {
	c, b := make_ctx(32, 32)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {0, 0, 0, 1})
	path_move_to(&c.path, IDENTITY, 2, 2)
	path_line_to(&c.path, IDENTITY, 28.3, 5.7)
	path_line_to(&c.path, IDENTITY, 9.1, 27.9)
	path_close(&c.path)
	ctx_fill(&c, .Nonzero)
	// area of the triangle
	ax, ay, bx, by, cx, cy := 2.0, 2.0, 28.3, 5.7, 9.1, 27.9
	area := abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2
	testing.expect(t, abs(alpha_sum(b) - area) / area < 0.01, "triangle area")
}

@(test)
nonzero_vs_evenodd :: proc(t: ^testing.T) {
	// two nested squares wound the same way: the inner one is a hole for evenodd only
	for rule in Fill_Rule {
		c, b := make_ctx(30, 30)
		defer free_ctx(&c, b)
		style_set_color(&c.state.fill, {0, 0, 0, 1})
		path_rect(&c.path, IDENTITY, 2, 2, 26, 26)
		path_rect(&c.path, IDENTITY, 10, 10, 10, 10)
		ctx_fill(&c, rule)
		center := px(b, 15, 15)[3]
		if rule == .Nonzero { testing.expect_value(t, center, 255) } else { testing.expect_value(t, center, 0) }
		testing.expect_value(t, px(b, 5, 5)[3], 255)
	}
}

@(test)
source_over_alpha :: proc(t: ^testing.T) {
	c, b := make_ctx(4, 4)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {1, 0, 0, 1})
	ctx_fill_rect(&c, 0, 0, 4, 4)
	style_set_color(&c.state.fill, {0, 0, 1, 1})
	c.state.alpha = 0.5
	ctx_fill_rect(&c, 0, 0, 4, 4)
	p := px(b, 1, 1)
	testing.expect(t, near(p[0], 128, 1) && near(p[2], 128, 1) && p[3] == 255, "half blue over red")
	// a translucent color over nothing stays premultiplied
	ctx_clear_rect(&c, 0, 0, 4, 4)
	c.state.alpha = 1
	style_set_color(&c.state.fill, {1, 1, 1, 0.5})
	ctx_fill_rect(&c, 0, 0, 4, 4)
	testing.expect_value(t, px(b, 0, 0), [4]u8{128, 128, 128, 128})
	out: [4]u8
	bitmap_read_straight(b, 0, 0, 1, 1, out[:])
	testing.expect_value(t, out, [4]u8{255, 255, 255, 128})
}

@(test)
composite_operators :: proc(t: ^testing.T) {
	c, b := make_ctx(4, 4)
	defer free_ctx(&c, b)
	paint_two :: proc(c: ^Context, op: Composite_Op) {
		ctx_clear_rect(c, 0, 0, 4, 4)
		c.state.op = .Source_Over
		style_set_color(&c.state.fill, {1, 0, 0, 1})
		ctx_fill_rect(c, 0, 0, 2, 4)   // left half: opaque red destination
		c.state.op = op
		style_set_color(&c.state.fill, {0, 0, 1, 1})
		ctx_fill_rect(c, 1, 0, 2, 4)   // columns 1 and 2: blue source
	}
	paint_two(&c, .Destination_Out)
	testing.expect_value(t, px(b, 0, 1)[3], 255)   // untouched
	testing.expect_value(t, px(b, 1, 1)[3], 0)     // erased under the source
	testing.expect_value(t, px(b, 2, 1)[3], 0)

	paint_two(&c, .Lighter)
	testing.expect_value(t, px(b, 1, 1), [4]u8{255, 0, 255, 255})   // red + blue
	testing.expect_value(t, px(b, 2, 1), [4]u8{0, 0, 255, 255})

	paint_two(&c, .Xor)
	testing.expect_value(t, px(b, 1, 1)[3], 0)       // both opaque: nothing
	testing.expect_value(t, px(b, 2, 1), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(b, 0, 1), [4]u8{255, 0, 0, 255})

	// source-in is unbounded: it clears what the source does not cover
	paint_two(&c, .Source_In)
	testing.expect_value(t, px(b, 1, 1), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(b, 2, 1)[3], 0)   // no destination under the source's right column
	testing.expect_value(t, px(b, 0, 1)[3], 0)   // outside the source: cleared
	testing.expect_value(t, px(b, 3, 1)[3], 0)

	paint_two(&c, .Copy)
	testing.expect_value(t, px(b, 1, 1), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(b, 0, 1)[3], 0)

	paint_two(&c, .Multiply)
	testing.expect_value(t, px(b, 1, 1), [4]u8{0, 0, 0, 255})   // red x blue
	testing.expect_value(t, px(b, 2, 1), [4]u8{0, 0, 255, 255})  // over nothing: the source
	paint_two(&c, .Screen)
	testing.expect_value(t, px(b, 1, 1), [4]u8{255, 0, 255, 255})
	paint_two(&c, .Difference)
	testing.expect_value(t, px(b, 1, 1), [4]u8{255, 0, 255, 255})
}

@(test)
stroke_lines_and_caps :: proc(t: ^testing.T) {
	c, b := make_ctx(40, 40)
	defer free_ctx(&c, b)
	style_set_color(&c.state.stroke, {0, 0, 0, 1})
	c.state.line_width = 4
	path_move_to(&c.path, IDENTITY, 10, 20)
	path_line_to(&c.path, IDENTITY, 30, 20)
	ctx_stroke(&c)
	// a butt-capped 20 x 4 bar: rows 18..21, columns 10..29
	testing.expect_value(t, px(b, 10, 18)[3], 255)
	testing.expect_value(t, px(b, 29, 21)[3], 255)
	testing.expect_value(t, px(b, 9, 20)[3], 0)
	testing.expect_value(t, px(b, 30, 20)[3], 0)
	testing.expect_value(t, px(b, 15, 17)[3], 0)
	testing.expect(t, abs(alpha_sum(b) - 80) < 0.1, "area of the bar")

	ctx_clear_rect(&c, 0, 0, 40, 40)
	c.state.cap = .Square
	ctx_stroke(&c)
	testing.expect(t, abs(alpha_sum(b) - 96) < 0.1, "square caps add 2 x 4 x 2")
	testing.expect_value(t, px(b, 8, 20)[3], 255)

	ctx_clear_rect(&c, 0, 0, 40, 40)
	c.state.cap = .Round
	ctx_stroke(&c)
	area := 80.0 + math.PI * 4
	testing.expect(t, abs(alpha_sum(b) - area) / area < 0.01, "round caps add a disc")
}

@(test)
stroke_joins :: proc(t: ^testing.T) {
	// an L with width 4: the outer corner is square (miter), cut (bevel) or rounded
	areas: [Line_Join]f64
	for join in Line_Join {
		c, b := make_ctx(40, 40)
		defer free_ctx(&c, b)
		style_set_color(&c.state.stroke, {0, 0, 0, 1})
		c.state.line_width = 4
		c.state.join = join
		path_move_to(&c.path, IDENTITY, 10, 30)
		path_line_to(&c.path, IDENTITY, 10, 10)
		path_line_to(&c.path, IDENTITY, 30, 10)
		ctx_stroke(&c)
		areas[join] = alpha_sum(b)
	}
	// two bars of 20 x 4 overlapping in a 2 x 2 square... the legs run 8 and 28 long measured on the centerline
	miter := areas[.Miter]
	testing.expect(t, abs(miter - 160) < 0.2, "miter area: two bars (80 each), their 2 x 2 overlap once, the outer 2 x 2 corner")
	testing.expect(t, areas[.Bevel] < miter - 1.5, "a bevel cuts the corner (half of the 2 x 2 square)")
	testing.expect(t, areas[.Round] > areas[.Bevel] && areas[.Round] < miter, "round is between")
}

@(test)
miter_limit_falls_back :: proc(t: ^testing.T) {
	// a very sharp turn: with the default limit of 10 the miter is cut to a bevel
	c, b := make_ctx(60, 60)
	defer free_ctx(&c, b)
	style_set_color(&c.state.stroke, {0, 0, 0, 1})
	c.state.line_width = 4
	path_move_to(&c.path, IDENTITY, 5, 5)
	path_line_to(&c.path, IDENTITY, 50, 30)
	path_line_to(&c.path, IDENTITY, 5, 12)
	ctx_stroke(&c)
	small := alpha_sum(b)
	ctx_clear_rect(&c, 0, 0, 60, 60)
	c.state.miter_limit = 100
	ctx_stroke(&c)
	testing.expect(t, alpha_sum(b) > small + 5, "a higher limit shows the long miter")
}

@(test)
dashes :: proc(t: ^testing.T) {
	c, b := make_ctx(60, 10)
	defer free_ctx(&c, b)
	style_set_color(&c.state.stroke, {0, 0, 0, 1})
	c.state.line_width = 2
	c.state.dash = make([]f64, 2)
	c.state.dash[0], c.state.dash[1] = 5, 5
	path_move_to(&c.path, IDENTITY, 0, 5)
	path_line_to(&c.path, IDENTITY, 60, 5)
	ctx_stroke(&c)
	testing.expect_value(t, px(b, 2, 5)[3], 255)
	testing.expect_value(t, px(b, 7, 5)[3], 0)
	testing.expect_value(t, px(b, 12, 5)[3], 255)
	testing.expect(t, abs(alpha_sum(b) - 60) < 0.2, "half of 60 x 2")
	// the offset shifts the pattern
	ctx_clear_rect(&c, 0, 0, 60, 10)
	c.state.dash_offset = 5
	ctx_stroke(&c)
	testing.expect_value(t, px(b, 2, 5)[3], 0)
	testing.expect_value(t, px(b, 7, 5)[3], 255)
}

@(test)
stroke_under_nonuniform_scale :: proc(t: ^testing.T) {
	// the line width is in user space: a scale of (4, 1) makes a vertical line 4 times wider than a horizontal one
	c, b := make_ctx(60, 60)
	defer free_ctx(&c, b)
	style_set_color(&c.state.stroke, {0, 0, 0, 1})
	ctx_scale(&c, 4, 1)
	c.state.line_width = 2
	path_move_to(&c.path, c.state.ctm, 5, 5)
	path_line_to(&c.path, c.state.ctm, 5, 55)
	ctx_stroke(&c)
	// device: x from 4 * 5 - 4 = 16 to 24; 50 tall
	testing.expect_value(t, px(b, 16, 30)[3], 255)
	testing.expect_value(t, px(b, 23, 30)[3], 255)
	testing.expect_value(t, px(b, 15, 30)[3], 0)
	testing.expect_value(t, px(b, 24, 30)[3], 0)
}

@(test)
clip_limits_drawing :: proc(t: ^testing.T) {
	c, b := make_ctx(30, 30)
	defer free_ctx(&c, b)
	path_arc(&c.path, c.state.ctm, 15, 15, 8, 0, 2 * math.PI, false)
	ctx_clip(&c, .Nonzero)
	style_set_color(&c.state.fill, {0, 1, 0, 1})
	ctx_fill_rect(&c, 0, 0, 30, 30)
	testing.expect_value(t, px(b, 15, 15), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, px(b, 1, 1)[3], 0)
	area := math.PI * 64
	testing.expect(t, abs(alpha_sum(b) - area) / area < 0.01, "only the disc is painted")
	// save / restore brings the old clip back
	ctx_clear_rect(&c, 0, 0, 30, 30)
	context_save(&c)
	path_clear(&c.path)
	path_rect(&c.path, IDENTITY, 0, 0, 3, 3)
	ctx_clip(&c, .Nonzero)
	ctx_fill_rect(&c, 0, 0, 30, 30)
	testing.expect_value(t, px(b, 15, 15)[3], 0)   // outside the intersection (the small square is outside the disc)
	context_restore(&c)
	ctx_fill_rect(&c, 0, 0, 30, 30)
	testing.expect_value(t, px(b, 15, 15)[3], 255)
}

@(test)
linear_gradient :: proc(t: ^testing.T) {
	c, b := make_ctx(100, 4)
	defer free_ctx(&c, b)
	g := gradient_linear(0, 0, 100, 0)
	defer gradient_release(g)
	gradient_add_stop(g, 0, {1, 0, 0, 1})
	gradient_add_stop(g, 1, {0, 0, 1, 1})
	style_set_gradient(&c.state.fill, g)
	ctx_fill_rect(&c, 0, 0, 100, 4)
	testing.expect(t, near(px(b, 0, 1)[0], 253, 3) && near(px(b, 0, 1)[2], 2, 3), "red at the start")
	testing.expect(t, near(px(b, 49, 1)[0], 128, 4) && near(px(b, 49, 1)[2], 127, 4), "purple in the middle")
	testing.expect(t, near(px(b, 99, 1)[2], 253, 3), "blue at the end")
	// a gradient is positioned in user space: translate moves it
	ctx_clear_rect(&c, 0, 0, 100, 4)
	ctx_translate(&c, 50, 0)
	ctx_fill_rect(&c, -50, 0, 100, 4)
	testing.expect(t, near(px(b, 99, 1)[0], 130, 4), "moved with the transform: user x = 49 is device 99")
	testing.expect(t, near(px(b, 0, 1)[0], 253, 3), "device 0 is user -50: padded red")
}

@(test)
radial_and_conic_gradients :: proc(t: ^testing.T) {
	c, b := make_ctx(40, 40)
	defer free_ctx(&c, b)
	g := gradient_radial(20, 20, 0, 20, 20, 20)
	defer gradient_release(g)
	gradient_add_stop(g, 0, {1, 1, 1, 1})
	gradient_add_stop(g, 1, {0, 0, 0, 1})
	style_set_gradient(&c.state.fill, g)
	ctx_fill_rect(&c, 0, 0, 40, 40)
	testing.expect(t, px(b, 20, 20)[0] > 245, "white at the center")
	testing.expect(t, near(px(b, 30, 20)[0], 128, 8), "mid grey halfway")
	testing.expect(t, px(b, 39, 39)[0] < 4, "black past the end circle (padded)")

	gc := gradient_conic(0, 20, 20)
	defer gradient_release(gc)
	gradient_add_stop(gc, 0, {1, 0, 0, 1})
	gradient_add_stop(gc, 0.5, {0, 1, 0, 1})
	gradient_add_stop(gc, 1, {1, 0, 0, 1})
	style_set_gradient(&c.state.fill, gc)
	ctx_fill_rect(&c, 0, 0, 40, 40)
	// to the right of the center is angle 0: red; to the left is half a turn: green
	testing.expect(t, px(b, 38, 20)[0] > 240 && px(b, 38, 20)[1] < 20, "red at angle 0")
	testing.expect(t, px(b, 1, 20)[1] > 240 && px(b, 1, 20)[0] < 20, "green at half a turn")
}

@(test)
pattern_repeats :: proc(t: ^testing.T) {
	src, _ := bitmap_create(2, 2)
	defer bitmap_destroy(&src)
	// a 2 x 2 tile: red, green / blue, white
	copy(src.pix, []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255})
	pat := pattern_create(&src, true, true)
	defer pattern_release(pat)
	c, b := make_ctx(8, 8)
	defer free_ctx(&c, b)
	c.state.smoothing = false
	style_set_pattern(&c.state.fill, pat)
	ctx_fill_rect(&c, 0, 0, 8, 8)
	testing.expect_value(t, px(b, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(b, 3, 0), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, px(b, 4, 5), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(b, 7, 7), [4]u8{255, 255, 255, 255})
	// no repeat: only one tile
	ctx_clear_rect(&c, 0, 0, 8, 8)
	pat.repeat_x, pat.repeat_y = false, false
	ctx_fill_rect(&c, 0, 0, 8, 8)
	testing.expect_value(t, px(b, 1, 1), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(b, 2, 0)[3], 0)
}

@(test)
draw_image_scales_and_flips :: proc(t: ^testing.T) {
	src, _ := bitmap_create(2, 1)
	defer bitmap_destroy(&src)
	copy(src.pix, []u8{255, 0, 0, 255, 0, 0, 255, 255})
	c, b := make_ctx(8, 4)
	defer free_ctx(&c, b)
	c.state.smoothing = false
	ctx_draw_image(&c, &src, 0, 0, 2, 1, 0, 0, 8, 4)
	testing.expect_value(t, px(b, 1, 1), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(b, 6, 3), [4]u8{0, 0, 255, 255})
	// a source rectangle partly outside the image is cut with the destination
	ctx_clear_rect(&c, 0, 0, 8, 4)
	ctx_draw_image(&c, &src, -2, 0, 4, 1, 0, 0, 8, 4)
	testing.expect_value(t, px(b, 1, 1)[3], 0)   // that half has no pixels
	testing.expect_value(t, px(b, 5, 1), [4]u8{255, 0, 0, 255})
	// drawn smoothed and rotated does not crash and covers something
	ctx_clear_rect(&c, 0, 0, 8, 4)
	c.state.smoothing = true
	ctx_translate(&c, 4, 2)
	ctx_rotate(&c, 0.5)
	ctx_draw_image(&c, &src, 0, 0, 2, 1, -2, -1, 4, 2)
	testing.expect(t, alpha_sum(b) > 4, "rotated image painted")
	// onto itself
	ctx_reset_transform(&c)
	ctx_draw_image(&c, b, 0, 0, 4, 4, 4, 0, 4, 4)
}

@(test)
shadow_offsets_and_blurs :: proc(t: ^testing.T) {
	c, b := make_ctx(40, 40)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {1, 0, 0, 1})
	c.state.shadow = Shadow{color = {0, 0, 0, 1}, ox = 10, oy = 10}
	ctx_fill_rect(&c, 5, 5, 10, 10)
	testing.expect_value(t, px(b, 7, 7), [4]u8{255, 0, 0, 255})        // the shape over its shadow
	testing.expect_value(t, px(b, 17, 17), [4]u8{0, 0, 0, 255})         // the offset shadow
	testing.expect_value(t, px(b, 27, 27)[3], 0)
	ctx_clear_rect(&c, 0, 0, 40, 40)
	c.state.shadow.ox, c.state.shadow.oy, c.state.shadow.blur = 0, 0, 8
	ctx_fill_rect(&c, 15, 15, 10, 10)
	edge := px(b, 13, 20)[3]
	testing.expect(t, edge > 5 && edge < 200, "the blur spreads past the edge")
	// the shadow adds about as much alpha as the shape had
	testing.expect(t, alpha_sum(b) > 115 && alpha_sum(b) < 200, "the shape plus the shadow that spills past it")
}

@(test)
paths_and_hit_testing :: proc(t: ^testing.T) {
	c, b := make_ctx(20, 20)
	defer free_ctx(&c, b)
	path_rect(&c.path, IDENTITY, 2, 2, 10, 10)
	testing.expect(t, ctx_is_point_in_path(&c, 5, 5, .Nonzero), "inside")
	testing.expect(t, !ctx_is_point_in_path(&c, 15, 5, .Nonzero), "outside")
	c.state.line_width = 2
	testing.expect(t, ctx_is_point_in_stroke(&c, 2, 6), "on the left edge")
	testing.expect(t, !ctx_is_point_in_stroke(&c, 7, 7), "in the middle, away from the stroke")
	// arcTo with a negative radius is an error; NaN is ignored
	testing.expect_value(t, path_arc_to(&c.path, IDENTITY, 0, 0, 1, 1, -1), Path_Error.Index_Size)
	n := len(c.path.verbs)
	path_line_to(&c.path, IDENTITY, math.nan_f64(), 3)
	path_ellipse(&c.path, IDENTITY, math.inf_f64(1), 0, 1, 1, 0, 0, 1, false)
	testing.expect_value(t, len(c.path.verbs), n)
}

@(test)
arc_to_rounds_a_corner :: proc(t: ^testing.T) {
	c, b := make_ctx(40, 40)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {0, 0, 0, 1})
	path_move_to(&c.path, IDENTITY, 5, 5)
	path_arc_to(&c.path, IDENTITY, 35, 5, 35, 35, 10)
	path_line_to(&c.path, IDENTITY, 35, 35)
	path_line_to(&c.path, IDENTITY, 5, 35)
	path_close(&c.path)
	ctx_fill(&c, .Nonzero)
	testing.expect_value(t, px(b, 34, 6)[3], 0)        // the top right corner is cut away
	testing.expect_value(t, px(b, 20, 20)[3], 255)
	testing.expect(t, abs(alpha_sum(b) - (30 * 30 - 100 + math.PI * 25 * 1)) < 40, "area: a square minus the cut")
}

@(test)
round_rect_and_rect_close :: proc(t: ^testing.T) {
	c, b := make_ctx(40, 40)
	defer free_ctx(&c, b)
	style_set_color(&c.state.fill, {0, 0, 0, 1})
	r := [4][2]f64{{8, 8}, {8, 8}, {8, 8}, {8, 8}}
	path_round_rect(&c.path, IDENTITY, 4, 4, 32, 32, r)
	ctx_fill(&c, .Nonzero)
	testing.expect_value(t, px(b, 4, 4)[3], 0)
	testing.expect_value(t, px(b, 20, 4)[3], 255)
	expected := 32.0 * 32 - (4 - math.PI) * 64
	testing.expect(t, abs(alpha_sum(b) - expected) / expected < 0.01, "rounded rectangle area")
}

@(test)
image_data_roundtrip :: proc(t: ^testing.T) {
	c, b := make_ctx(4, 4)
	defer free_ctx(&c, b)
	data := []u8{
		10, 20, 30, 255, 200, 100, 50, 128, 0, 0, 0, 0, 255, 255, 255, 1,
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
	}
	ctx_put_image_data(&c, data, 4, 2, 0, 0, 0, 0, 4, 2)
	out := make([]u8, 32)
	defer delete(out)
	ctx_get_image_data(&c, 0, 0, 4, 2, out)
	testing.expect_value(t, [4]u8{out[0], out[1], out[2], out[3]}, [4]u8{10, 20, 30, 255})
	testing.expect(t, near(out[4], 200, 2) && near(out[5], 100, 2) && near(out[6], 50, 2) && out[7] == 128, "alpha 128 survives within rounding")
	testing.expect_value(t, [4]u8{out[8], out[9], out[10], out[11]}, [4]u8{0, 0, 0, 0})
	// a block partly off the canvas reads transparent there
	big := make([]u8, 6 * 6 * 4)
	defer delete(big)
	ctx_get_image_data(&c, -1, -1, 6, 6, big)
	testing.expect_value(t, big[3], 0)
	testing.expect_value(t, [4]u8{big[(7) * 4], big[(7) * 4 + 1], big[(7) * 4 + 2], big[(7) * 4 + 3]}, [4]u8{10, 20, 30, 255})
	// putImageData ignores the clip and the transform, and honors the dirty rectangle
	ctx_reset_transform(&c)
	ctx_translate(&c, 2, 2)
	ctx_clear_rect(&c, -2, -2, 4, 4)
	ctx_put_image_data(&c, data, 4, 2, 0, 0, 1, 0, 1, 1)
	testing.expect(t, near(px(b, 1, 0)[0], 100, 2) || px(b, 1, 0)[3] == 128, "dirty rectangle at its own place")
}

@(test)
font_parsing :: proc(t: ^testing.T) {
	f, ok := font_parse("italic bold 16px/1.5 \"Helvetica Neue\", Arial, sans-serif", 10)
	testing.expect(t, ok, "parses")
	testing.expect_value(t, f.size, 16)
	testing.expect_value(t, f.weight, 700)
	testing.expect(t, f.italic, "italic")
	testing.expect_value(t, len(f.families), 3)
	testing.expect_value(t, f.families[0], "Helvetica Neue")
	testing.expect_value(t, f.text, "italic bold 16px \"Helvetica Neue\", Arial, sans-serif")
	font_spec_destroy(&f)

	f, ok = font_parse("12pt Times New Roman", 10)
	testing.expect(t, ok, "unquoted multi-word family")
	testing.expect_value(t, f.size, 16)
	testing.expect_value(t, f.families[0], "Times New Roman")
	font_spec_destroy(&f)

	f, ok = font_parse("2em serif", 8)
	testing.expect_value(t, f.size, 16)
	font_spec_destroy(&f)

	for bad in ([]string{"", "16px", "bold", "serif 16px", "-3px serif", "16px 'unterminated", "10px / serif"}) {
		_, bok := font_parse(bad, 10)
		testing.expectf(t, !bok, "%q is not a font", bad)
	}
}

@(test)
hostile_numbers_do_not_crash :: proc(t: ^testing.T) {
	c, b := make_ctx(16, 16)
	defer free_ctx(&c, b)
	nan, inf := math.nan_f64(), math.inf_f64(1)
	style_set_color(&c.state.fill, {0, 0, 0, 1})
	ctx_fill_rect(&c, nan, 0, 1, 1)
	ctx_fill_rect(&c, 0, 0, inf, 1)
	ctx_fill_rect(&c, -1e300, -1e300, 2e300, 2e300)
	testing.expect_value(t, px(b, 8, 8)[3], 255)   // the huge rectangle covers the canvas
	ctx_clear_rect(&c, 0, 0, 16, 16)
	ctx_transform(&c, nan, 0, 0, 1, 0, 0)
	ctx_scale(&c, 1e200, 1e200)
	ctx_scale(&c, 1e200, 1e200)   // overflows to infinity: ignored
	testing.expect(t, matrix_finite(c.state.ctm), "the transform stays finite")
	ctx_reset_transform(&c)
	path_move_to(&c.path, IDENTITY, -1e300, -1e300)
	path_line_to(&c.path, IDENTITY, 1e300, 1e300)
	path_line_to(&c.path, IDENTITY, 1e300, -1e300)
	ctx_fill(&c, .Nonzero)
	c.state.line_width = 1e300
	style_set_color(&c.state.stroke, {0, 0, 0, 1})
	ctx_stroke(&c)
	ctx_clip(&c, .Evenodd)
	// singular transform: nothing is drawn, nothing breaks
	ctx_set_transform(&c, 0, 0, 0, 0, 0, 0)
	ctx_fill_rect(&c, 0, 0, 10, 10)
	ctx_stroke_rect(&c, 0, 0, 10, 10)
	// a zero-size bitmap
	zb := new(Bitmap)
	zb^, _ = bitmap_create(0, 0)
	zc: Context
	context_init(&zc, zb, DEFAULT_OPTIONS)
	ctx_fill_rect(&zc, 0, 0, 5, 5)
	ctx_stroke_rect(&zc, 0, 0, 5, 5)
	ctx_clip(&zc, .Nonzero)
	ctx_draw_image(&zc, zb, 0, 0, 1, 1, 0, 0, 1, 1)
	free_ctx(&zc, zb)
}

@(test)
save_restore_and_reset :: proc(t: ^testing.T) {
	c, b := make_ctx(8, 8)
	defer free_ctx(&c, b)
	c.opts.max_states = 3
	c.state.alpha = 0.3
	ctx_translate(&c, 2, 3)
	testing.expect(t, context_save(&c), "save")
	c.state.alpha = 0.9
	ctx_scale(&c, 2, 2)
	context_restore(&c)
	testing.expect_value(t, c.state.alpha, 0.3)
	testing.expect_value(t, c.state.ctm, Matrix{1, 0, 0, 1, 2, 3})
	for _ in 0 ..< 3 { testing.expect_value(t, context_save(&c), true) }
	testing.expect(t, !context_save(&c), "the stack is bounded")
	context_restore(&c)   // restore on an empty stack does nothing, and a full one pops
	style_set_color(&c.state.fill, {1, 1, 1, 1})
	ctx_fill_rect(&c, 0, 0, 8, 8)
	context_reset(&c)
	testing.expect_value(t, px(b, 3, 3)[3], 0)
	testing.expect_value(t, len(c.stack), 0)
	testing.expect_value(t, c.state.alpha, 1)
}

// A text engine whose glyphs are unit squares: enough to see where text goes.
@(private = "file")
fake_outline: Path

@(private = "file")
fake_engine :: proc() -> Text_Engine {
	if len(fake_outline.verbs) == 0 { path_rect(&fake_outline, IDENTITY, 0, 0, 0.5, 0.7) }
	return Text_Engine{
		font = proc(user: rawptr, spec: ^Font_Spec) -> u64 { return 1 },
		shape = proc(user: rawptr, font: u64, size: f32, text: string, rtl: bool, ls, ws: f32, glyphs: ^[dynamic]Placed_Glyph) -> f32 {
			x := f32(0)
			for r in text {
				append(glyphs, Placed_Glyph{face = 1, gid = u16(r), x = x, y = 0})
				x += size * 0.6
			}
			return x
		},
		outline = proc(user: rawptr, face: u64, gid: u16) -> ^Path { return gid == ' ' ? nil : &fake_outline },
		metrics = proc(user: rawptr, font: u64, size: f32) -> Font_Metrics {
			return {ascent = size * 0.8, descent = size * 0.2, em_ascent = size * 0.8, em_descent = size * 0.2}
		},
	}
}

@(test)
text_is_drawn_from_outlines :: proc(t: ^testing.T) {
	c, b := make_ctx(60, 30)
	defer free_ctx(&c, b)
	defer path_destroy(&fake_outline)
	c.text = fake_engine()
	style_set_color(&c.state.fill, {0, 0, 0, 1})
	c.state.font.size = 10
	ctx_draw_text(&c, "ab", 10, 20, 0, false, false)
	// each glyph is a 5 x 7 box above the baseline at y = 20, advancing 6
	testing.expect_value(t, px(b, 11, 15)[3], 255)
	testing.expect_value(t, px(b, 17, 15)[3], 255)
	testing.expect_value(t, px(b, 11, 21)[3], 0)
	testing.expect_value(t, px(b, 9, 15)[3], 0)
	// center alignment moves it left by half the width (12 / 2)
	ctx_clear_rect(&c, 0, 0, 60, 30)
	c.state.text_align = .Center
	ctx_draw_text(&c, "ab", 30, 20, 0, false, false)
	testing.expect_value(t, px(b, 25, 15)[3], 255)
	testing.expect_value(t, px(b, 23, 15)[3], 0)
	// maxWidth squeezes it
	ctx_clear_rect(&c, 0, 0, 60, 30)
	c.state.text_align = .Left
	ctx_draw_text(&c, "ab", 10, 20, 6, true, false)
	testing.expect_value(t, px(b, 11, 15)[3], 255)
	testing.expect_value(t, px(b, 17, 15)[3], 0)
	// baseline top: the text hangs from y
	ctx_clear_rect(&c, 0, 0, 60, 30)
	c.state.baseline = .Top
	ctx_draw_text(&c, "a", 10, 10, 0, false, false)
	testing.expect_value(t, px(b, 11, 11)[3], 255)
	testing.expect_value(t, px(b, 11, 8)[3], 0)
	tm, ok := ctx_measure_text(&c, "abc")
	testing.expect(t, ok && abs(tm.width - 18) < 1e-4, "measured width")
	// strokeText draws an outline only
	ctx_clear_rect(&c, 0, 0, 60, 30)
	c.state.baseline = .Alphabetic
	style_set_color(&c.state.stroke, {0, 0, 0, 1})
	c.state.line_width = 1
	ctx_draw_text(&c, "a", 10, 20, 0, false, true)
	testing.expect_value(t, px(b, 12, 17)[3], 0)   // inside the glyph
	testing.expect(t, px(b, 10, 17)[3] > 100, "its edge")
}

@(test)
big_bitmap_limits :: proc(t: ^testing.T) {
	_, ok := bitmap_create(40000, 10)
	testing.expect(t, !ok, "past the side limit")
	_, ok = bitmap_create(30000, 30000, 1 << 30)
	testing.expect(t, !ok, "past the byte count")
	_, ok = bitmap_create(1000, 1000, 1000)
	testing.expect(t, !ok, "past the caller's budget")
	_, ok = bitmap_create(-1, 5)
	testing.expect(t, !ok, "negative")
	b, ok2 := bitmap_create(0, 0)
	testing.expect(t, ok2, "an empty canvas is fine")
	bitmap_destroy(&b)
}

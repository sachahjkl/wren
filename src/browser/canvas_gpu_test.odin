package browser

import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:testing"
import "toolkit:render"
import "wb:canvas2d"
import "wb:images"

// The GPU canvas against the software rasterizer (the reference): the same drawing calls on a software context and on a GPU
// one, on an offscreen renderer (WARP), compared pixel by pixel. Antialiasing differs a little (the GPU takes 16 samples on
// the pixels an edge touches, the rasterizer 16 sub-scanlines with exact coverage along them), so a few edge pixels may differ
// by up to a few percent of the range; what must not differ is any interior pixel. A failing comparison writes the two
// pictures and their difference to build\tmp\canvas_gpu_<name>_*.png.

@(private = "file")
Env :: struct {
	r:    render.Renderer,
	host: ^canvas2d.Gpu_Host,
}

@(private = "file")
env_open :: proc(e: ^Env) -> bool {
	if !render.init_offscreen(&e.r, {16, 16}, warp = true, space = .Srgb) { return false }
	e.host = canvas_gpu_setup(&e.r, 1 << 28)
	return e.host != nil
}

@(private = "file")
env_close :: proc(e: ^Env) {
	canvas_gpu_teardown()
	render.destroy(&e.r)
	for p in ([2]^^canvas2d.Path{&test_glyph_a, &test_glyph_o}) {
		if p^ != nil { canvas2d.path_destroy(p^); free(p^); p^ = nil }
	}
}

Scenario :: proc(c: ^canvas2d.Context)

@(private = "file")
Diff :: struct {
	max_diff:  int,
	mean:      f64,
	bad:       int,         // pixels with a channel off by more than `tol`
	worst:     [2]int,
}

// The picture a scenario makes in software and on the GPU.
@(private = "file")
render_both :: proc(e: ^Env, w, h: int, sc: Scenario, opaque := false) -> (sw, gpu: []u8, ok: bool) {
	opts := canvas2d.DEFAULT_OPTIONS
	sb, bok := canvas2d.bitmap_create(w, h)
	if !bok { return }
	defer canvas2d.bitmap_destroy(&sb)
	sb.opaque = opaque
	canvas2d.bitmap_reset_contents(&sb)
	sc_ctx: canvas2d.Context
	canvas2d.context_init(&sc_ctx, &sb, opts)
	sc_ctx.text = test_text_engine()
	sc(&sc_ctx)
	sw = make([]u8, len(sb.pix))
	copy(sw, sb.pix)
	canvas2d.context_destroy(&sc_ctx)

	gb, gok := canvas2d.bitmap_virtual(w, h, 0)
	if !gok { return }
	gb.opaque = opaque
	g_ctx: canvas2d.Context
	canvas2d.context_init(&g_ctx, &gb, opts)
	canvas2d.context_enable_gpu(&g_ctx, e.host)
	g_ctx.text = test_text_engine()
	sc(&g_ctx)
	bm := canvas2d.gpu_bitmap(&g_ctx)
	if bm == nil { canvas2d.context_destroy(&g_ctx); canvas2d.bitmap_destroy(&gb); return }
	gpu = make([]u8, len(bm.pix))
	copy(gpu, bm.pix)
	canvas2d.context_destroy(&g_ctx)
	canvas2d.bitmap_destroy(&gb)
	return sw, gpu, true
}

@(private = "file")
diff_of :: proc(a, b: []u8, w, h: int, tol: int) -> (d: Diff) {
	sum := 0
	for i in 0 ..< w * h {
		m := 0
		for k in 0 ..< 4 { m = max(m, abs(int(a[i * 4 + k]) - int(b[i * 4 + k]))) }
		sum += m
		if m > d.max_diff { d.max_diff, d.worst = m, {i % w, i / w} }
		if m > tol { d.bad += 1 }
	}
	d.mean = f64(sum) / f64(w * h)
	return
}

@(private = "file")
write_png :: proc(path: string, pix: []u8, w, h: int) {
	// premultiplied over black is what the canvas shows over a black page: encode as is (straight conversion for the encoder)
	bytes, ok := images.encode_rgba(pix, w, h, .Png, 1, true)
	if !ok { return }
	defer delete(bytes)
	_ = os.write_entire_file(path, bytes)
}

// Compares the two renderings; `tol`: a pixel counts as bad when a channel differs by more; `bad_frac`: the share of bad pixels
// that is allowed (edges); `mean`: the mean of the worst channel difference that is allowed.
@(private = "file")
test_lock: sync.Mutex   // the canvas host is one per process: the comparisons run one at a time

@(private = "file")
compare :: proc(t: ^testing.T, name: string, w, h: int, sc: Scenario, tol := 40, bad_frac := 0.015, mean := 1.2, opaque := false) {
	sync.mutex_lock(&test_lock)
	defer sync.mutex_unlock(&test_lock)
	e: Env
	if !env_open(&e) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer env_close(&e)
	sw, gpu, ok := render_both(&e, w, h, sc, opaque)
	if !ok { testing.fail_now(t, "the contexts could not be made") }
	defer delete(sw)
	defer delete(gpu)
	d := diff_of(sw, gpu, w, h, tol)
	frac := f64(d.bad) / f64(w * h)
	pass := frac <= bad_frac && d.mean <= mean
	if !pass {
		dir := "build/tmp"
		os.make_directory(dir)
		write_png(fmt.tprintf("%s/canvas_gpu_%s_sw.png", dir, name), sw, w, h)
		write_png(fmt.tprintf("%s/canvas_gpu_%s_gpu.png", dir, name), gpu, w, h)
		df := make([]u8, w * h * 4, context.temp_allocator)
		for i in 0 ..< w * h {
			m := 0
			for k in 0 ..< 4 { m = max(m, abs(int(sw[i * 4 + k]) - int(gpu[i * 4 + k]))) }
			v := u8(min(m * 4, 255))
			df[i * 4], df[i * 4 + 1], df[i * 4 + 2], df[i * 4 + 3] = v, v, v, 255
		}
		write_png(fmt.tprintf("%s/canvas_gpu_%s_diff.png", dir, name), df, w, h)
	}
	testing.expectf(t, pass, "%s: %.2f%% of the pixels differ by more than %d (allowed %.2f%%), mean %.2f (allowed %.2f), worst %d at %v",
		name, frac * 100, tol, bad_frac * 100, d.mean, mean, d.max_diff, d.worst)
}

////////////////////////////////
// Helpers of the scenarios

@(private = "file")
fill :: proc(c: ^canvas2d.Context, r, g, b: f32, a: f32 = 1) { canvas2d.style_set_color(&c.state.fill, {r, g, b, a}) }
@(private = "file")
stroke_style :: proc(c: ^canvas2d.Context, r, g, b: f32, a: f32 = 1) { canvas2d.style_set_color(&c.state.stroke, {r, g, b, a}) }
@(private = "file")
begin :: proc(c: ^canvas2d.Context) { canvas2d.path_clear(&c.path) }
@(private = "file")
move :: proc(c: ^canvas2d.Context, x, y: f64) { canvas2d.path_move_to(&c.path, c.state.ctm, x, y) }
@(private = "file")
line :: proc(c: ^canvas2d.Context, x, y: f64) { canvas2d.path_line_to(&c.path, c.state.ctm, x, y) }
@(private = "file")
close :: proc(c: ^canvas2d.Context) { canvas2d.path_close(&c.path) }
@(private = "file")
arc :: proc(c: ^canvas2d.Context, x, y, r, a0, a1: f64, ccw := false) { canvas2d.path_arc(&c.path, c.state.ctm, x, y, r, a0, a1, ccw) }
@(private = "file")
rect_path :: proc(c: ^canvas2d.Context, x, y, w, h: f64) { canvas2d.path_rect(&c.path, c.state.ctm, x, y, w, h) }
@(private = "file")
cubic :: proc(c: ^canvas2d.Context, a, b, d, e, x, y: f64) { canvas2d.path_cubic_to(&c.path, c.state.ctm, a, b, d, e, x, y) }
@(private = "file")
nonzero :: proc(c: ^canvas2d.Context) { canvas2d.ctx_fill(c, .Nonzero) }
@(private = "file")
stroke_path :: proc(c: ^canvas2d.Context) { canvas2d.ctx_stroke(c) }

// A 32 x 32 picture with a transparent corner: red/blue quadrants, a green diagonal.
@(private = "file")
make_picture :: proc() -> canvas2d.Bitmap {
	b, _ := canvas2d.bitmap_create(32, 32)
	for y in 0 ..< 32 {
		for x in 0 ..< 32 {
			p := b.pix[(y * 32 + x) * 4:][:4]
			a := u8(255)
			if x + y < 8 { a = 0 }
			r, g, bl := u8(x < 16 ? 220 : 20), u8(abs(x - y) < 3 ? 200 : 40), u8(x >= 16 ? 230 : 30)
			p[0], p[1], p[2], p[3] = u8(u32(r) * u32(a) / 255), u8(u32(g) * u32(a) / 255), u8(u32(bl) * u32(a) / 255), a
		}
	}
	canvas2d.bitmap_touch_all(&b)
	return b
}

////////////////////////////////
// Scenarios

@(test)
canvas_gpu_rects :: proc(t: ^testing.T) {
	compare(t, "rects", 128, 96, proc(c: ^canvas2d.Context) {
		fill(c, 0.9, 0.2, 0.1)
		canvas2d.ctx_fill_rect(c, 10, 10, 50, 30)
		fill(c, 0.1, 0.5, 0.9, 0.5)
		canvas2d.ctx_fill_rect(c, 30.5, 20.25, 60.5, 40.5)
		fill(c, 0.2, 0.9, 0.3)
		canvas2d.ctx_fill_rect(c, 100, 5, -20, 12)
		c.state.alpha = 0.4
		fill(c, 1, 1, 1)
		canvas2d.ctx_fill_rect(c, 0, 60, 128, 20)
		c.state.alpha = 1
		canvas2d.ctx_clear_rect(c, 40, 50, 20, 10)
		canvas2d.ctx_clear_rect(c, 70.3, 25.7, 10.2, 8.4)
	})
}

@(test)
canvas_gpu_transformed_rects :: proc(t: ^testing.T) {
	compare(t, "transformed_rects", 128, 128, proc(c: ^canvas2d.Context) {
		fill(c, 0.9, 0.5, 0.1)
		canvas2d.ctx_translate(c, 64, 64)
		canvas2d.ctx_rotate(c, 0.5)
		canvas2d.ctx_fill_rect(c, -30, -15, 60, 30)
		canvas2d.ctx_scale(c, 1.5, 0.7)
		fill(c, 0.2, 0.5, 0.9, 0.7)
		canvas2d.ctx_fill_rect(c, -20, -20, 40, 40)
		canvas2d.ctx_set_transform(c, 1, 0.3, 0.2, 1, 10, 80)   // skewed: a polygon
		fill(c, 0.3, 0.8, 0.3)
		canvas2d.ctx_fill_rect(c, 0, 0, 40, 30)
	}, bad_frac = 0.02)
}

@(test)
canvas_gpu_circles_and_arcs :: proc(t: ^testing.T) {
	compare(t, "arcs", 160, 120, proc(c: ^canvas2d.Context) {
		fill(c, 0.9, 0.7, 0.2)
		begin(c); arc(c, 40, 40, 25, 0, 2 * math.PI); nonzero(c)
		fill(c, 0.2, 0.7, 0.9)
		begin(c); arc(c, 100, 40, 20, 0.3, 4.1); close(c); nonzero(c)
		fill(c, 0.9, 0.3, 0.5)
		begin(c); canvas2d.path_ellipse(&c.path, c.state.ctm, 40, 90, 30, 14, 0.4, 0, 2 * math.PI, false); nonzero(c)
		stroke_style(c, 1, 1, 1)
		c.state.line_width = 3
		begin(c); arc(c, 110, 90, 16, 0, 5); stroke_path(c)
		begin(c); arc(c, 40, 40, 31, 0, 2 * math.PI); c.state.line_width = 1.5; stroke_path(c)
	})
}

@(test)
canvas_gpu_strokes :: proc(t: ^testing.T) {
	compare(t, "strokes", 200, 140, proc(c: ^canvas2d.Context) {
		stroke_style(c, 0.95, 0.9, 0.2)
		c.state.line_width = 10
		for join, i in ([?]canvas2d.Line_Join{.Miter, .Round, .Bevel}) {
			c.state.join = join
			c.state.cap = canvas2d.Line_Cap(i)
			begin(c)
			move(c, 15 + f64(i) * 62, 40); line(c, 40 + f64(i) * 62, 10); line(c, 55 + f64(i) * 62, 45)
			stroke_path(c)
		}
		c.state.line_width = 2
		c.state.cap = .Butt
		dash := make([]f64, 2)
		dash[0], dash[1] = 6, 4
		c.state.dash = dash
		stroke_style(c, 0.4, 0.9, 1)
		begin(c); move(c, 10, 70); line(c, 190, 80); stroke_path(c)
		delete(c.state.dash)
		c.state.dash = nil
		c.state.line_width = 1
		stroke_style(c, 1, 0.5, 0.5)
		for i in 0 ..< 8 {
			begin(c); move(c, 10, 95 + f64(i) * 5.5); line(c, 190, 95.5 + f64(i) * 5.5); stroke_path(c)
		}
		c.state.line_width = 6
		stroke_style(c, 0.6, 1, 0.6, 0.6)
		begin(c); move(c, 10, 135); cubic(c, 60, 90, 120, 180, 190, 130); stroke_path(c)
	}, bad_frac = 0.02)
}

@(test)
canvas_gpu_fill_rules :: proc(t: ^testing.T) {
	compare(t, "fill_rules", 128, 64, proc(c: ^canvas2d.Context) {
		fill(c, 0.3, 0.8, 0.9)
		star :: proc(c: ^canvas2d.Context, cx, cy: f64) {
			begin(c)
			for i in 0 ..< 5 {
				a := f64(i) * 4 * math.PI / 5 - math.PI / 2
				if i == 0 { move(c, cx + 25 * math.cos(a), cy + 25 * math.sin(a)) } else { line(c, cx + 25 * math.cos(a), cy + 25 * math.sin(a)) }
			}
			close(c)
		}
		star(c, 32, 32); canvas2d.ctx_fill(c, .Nonzero)
		fill(c, 0.9, 0.5, 0.3)
		star(c, 96, 32); canvas2d.ctx_fill(c, .Evenodd)
	}, bad_frac = 0.02)
}

@(test)
canvas_gpu_gradients :: proc(t: ^testing.T) {
	compare(t, "gradients", 192, 128, proc(c: ^canvas2d.Context) {
		lin := canvas2d.gradient_linear(0, 0, 96, 0)
		canvas2d.gradient_add_stop(lin, 0, {1, 0, 0, 1})
		canvas2d.gradient_add_stop(lin, 0.5, {1, 1, 0, 1})
		canvas2d.gradient_add_stop(lin, 1, {0, 0.3, 1, 0.5})
		canvas2d.style_set_gradient(&c.state.fill, lin)
		canvas2d.gradient_release(lin)
		canvas2d.ctx_fill_rect(c, 0, 0, 96, 64)
		rad := canvas2d.gradient_radial(144, 32, 4, 150, 36, 30)
		canvas2d.gradient_add_stop(rad, 0, {1, 1, 1, 1})
		canvas2d.gradient_add_stop(rad, 1, {0, 0, 0.6, 1})
		canvas2d.style_set_gradient(&c.state.fill, rad)
		canvas2d.gradient_release(rad)
		canvas2d.ctx_fill_rect(c, 96, 0, 96, 64)
		con := canvas2d.gradient_conic(0.5, 48, 96)
		for i in 0 ..< 6 { canvas2d.gradient_add_stop(con, f64(i) / 5, {f32(i % 2), f32((i + 1) % 3) / 2, f32(i) / 5, 1}) }
		canvas2d.style_set_gradient(&c.state.fill, con)
		canvas2d.gradient_release(con)
		canvas2d.ctx_fill_rect(c, 0, 64, 96, 64)
		canvas2d.ctx_translate(c, 96, 64)
		canvas2d.ctx_rotate(c, 0.7)
		lin2 := canvas2d.gradient_linear(0, 0, 60, 60)
		canvas2d.gradient_add_stop(lin2, 0.2, {0, 1, 0, 1})
		canvas2d.gradient_add_stop(lin2, 0.8, {1, 0, 1, 1})
		canvas2d.style_set_gradient(&c.state.fill, lin2)
		canvas2d.gradient_release(lin2)
		begin(c); arc(c, 40, 20, 28, 0, 2 * math.PI); nonzero(c)
	}, tol = 24, bad_frac = 0.02)
}

@(test)
canvas_gpu_patterns_and_images :: proc(t: ^testing.T) {
	compare(t, "images", 192, 128, proc(c: ^canvas2d.Context) {
		pic := make_picture()
		defer canvas2d.bitmap_destroy(&pic)
		pat := canvas2d.pattern_create(&pic, true, true)
		canvas2d.style_set_pattern(&c.state.fill, pat)
		canvas2d.pattern_release(pat)
		canvas2d.ctx_fill_rect(c, 0, 0, 64, 64)
		pat2 := canvas2d.pattern_create(&pic, true, false)
		pat2.transform = canvas2d.matrix_mul(canvas2d.matrix_translate(5, 70), canvas2d.matrix_scale(1.5, 1.5))
		canvas2d.style_set_pattern(&c.state.fill, pat2)
		canvas2d.pattern_release(pat2)
		canvas2d.ctx_fill_rect(c, 0, 64, 64, 64)
		// drawImage: scaled up, smoothing off, shrunk, a source rectangle, rotated
		c.state.smoothing = true
		canvas2d.ctx_draw_image(c, &pic, 0, 0, 32, 32, 70, 4, 56, 56)
		c.state.smoothing = false
		canvas2d.ctx_draw_image(c, &pic, 0, 0, 32, 32, 130, 4, 56, 56)
		c.state.smoothing = true
		canvas2d.ctx_draw_image(c, &pic, 0, 0, 32, 32, 70, 68, 12, 12)
		canvas2d.ctx_draw_image(c, &pic, 8, 8, 16, 16, 90, 68, 32, 32)
		canvas2d.ctx_translate(c, 160, 100)
		canvas2d.ctx_rotate(c, 0.6)
		canvas2d.ctx_draw_image(c, &pic, 0, 0, 32, 32, -20, -20, 40, 40)
	}, tol = 48, bad_frac = 0.04, mean = 2.5)
}

@(test)
canvas_gpu_operators :: proc(t: ^testing.T) {
	for op in canvas2d.Composite_Op {
		name := fmt.tprintf("op_%s", canvas2d.OP_NAMES[op])
		compare_op(t, name, op)
	}
}

@(private = "file")
op_global: canvas2d.Composite_Op

@(private = "file")
compare_op :: proc(t: ^testing.T, name: string, op: canvas2d.Composite_Op) {
	op_global = op
	compare(t, name, 80, 60, proc(c: ^canvas2d.Context) {
		fill(c, 0.9, 0.2, 0.2)
		canvas2d.ctx_fill_rect(c, 5, 5, 40, 40)
		fill(c, 0.2, 0.3, 0.9, 0.8)
		canvas2d.ctx_fill_rect(c, 25, 15, 40, 35)
		c.state.op = op_global
		fill(c, 0.3, 0.9, 0.4, 0.7)
		begin(c); arc(c, 40, 30, 18, 0, 2 * math.PI); nonzero(c)
	}, tol = 6, bad_frac = 0.005, mean = 0.5)
}

@(test)
canvas_gpu_clip :: proc(t: ^testing.T) {
	compare(t, "clip", 128, 96, proc(c: ^canvas2d.Context) {
		canvas2d.context_save(c)
		begin(c); arc(c, 40, 40, 30, 0, 2 * math.PI); canvas2d.ctx_clip(c, .Nonzero)
		fill(c, 0.9, 0.6, 0.1)
		canvas2d.ctx_fill_rect(c, 0, 0, 128, 96)
		canvas2d.context_save(c)
		begin(c); rect_path(c, 40, 20, 60, 40); canvas2d.ctx_clip(c, .Nonzero)
		fill(c, 0.1, 0.6, 0.9)
		canvas2d.ctx_fill_rect(c, 0, 0, 128, 96)
		canvas2d.context_restore(c)
		canvas2d.context_restore(c)
		begin(c); rect_path(c, 80, 10, 30, 30); canvas2d.ctx_clip(c, .Nonzero)
		fill(c, 0.9, 0.2, 0.6)
		canvas2d.ctx_fill_rect(c, 70, 0, 60, 96)
		begin(c); rect_path(c, 70.5, 60.5, 40, 25); canvas2d.ctx_clip(c, .Nonzero)
		fill(c, 0.4, 0.9, 0.2)
		canvas2d.ctx_fill_rect(c, 0, 50, 128, 46)
	}, bad_frac = 0.02)
}

@(test)
canvas_gpu_shadows_and_filters :: proc(t: ^testing.T) {
	compare(t, "shadows", 160, 100, proc(c: ^canvas2d.Context) {
		fill(c, 0.95, 0.95, 0.9)
		canvas2d.ctx_fill_rect(c, 0, 0, 160, 100)
		c.state.shadow = canvas2d.Shadow{color = {0, 0, 0, 0.6}, blur = 8, ox = 4, oy = 5}
		fill(c, 0.2, 0.5, 0.9)
		canvas2d.ctx_fill_rect(c, 10, 10, 40, 30)
		c.state.shadow = {}
		canvas2d.ctx_set_filter(c, "blur(2px)")
		fill(c, 0.9, 0.3, 0.2)
		begin(c); arc(c, 90, 30, 18, 0, 2 * math.PI); nonzero(c)
		canvas2d.ctx_set_filter(c, "grayscale(1) brightness(1.2)")
		fill(c, 0.2, 0.8, 0.3)
		canvas2d.ctx_fill_rect(c, 120, 10, 30, 30)
		canvas2d.ctx_set_filter(c, "sepia(0.8) contrast(1.4)")
		fill(c, 0.9, 0.6, 0.2)
		canvas2d.ctx_fill_rect(c, 10, 60, 40, 30)
		canvas2d.ctx_set_filter(c, "hue-rotate(90deg) saturate(2)")
		fill(c, 0.9, 0.2, 0.2)
		canvas2d.ctx_fill_rect(c, 60, 60, 30, 30)
		canvas2d.ctx_set_filter(c, "invert(1) opacity(0.5)")
		fill(c, 0.1, 0.1, 0.1)
		canvas2d.ctx_fill_rect(c, 105, 60, 30, 30)
	}, tol = 30, bad_frac = 0.02, mean = 1.6)
}

@(test)
canvas_gpu_pixels :: proc(t: ^testing.T) {
	compare(t, "pixels", 64, 48, proc(c: ^canvas2d.Context) {
		data := make([]u8, 16 * 12 * 4, context.temp_allocator)
		for i in 0 ..< 16 * 12 {
			data[i * 4], data[i * 4 + 1], data[i * 4 + 2], data[i * 4 + 3] = u8(i * 7), u8(255 - i), u8(i * 3), u8(60 + i)
		}
		fill(c, 0.2, 0.4, 0.8)
		canvas2d.ctx_fill_rect(c, 0, 0, 64, 48)
		canvas2d.ctx_put_image_data(c, data, 16, 12, 5, 5, 0, 0, 16, 12)
		canvas2d.ctx_put_image_data(c, data, 16, 12, 50, 40, 2, 2, 10, 10)    // cut by the edge of the canvas
		canvas2d.ctx_put_image_data(c, data, 16, 12, -4, 20, 0, 0, 16, 12)
		out: [4 * 4 * 4]u8
		canvas2d.ctx_get_image_data(c, 6, 6, 4, 4, out[:])
		canvas2d.style_set_color(&c.state.fill, {f32(out[0]) / 255, f32(out[1]) / 255, f32(out[2]) / 255, 1})
		canvas2d.ctx_fill_rect(c, 30, 30, 10, 10)
	}, tol = 3, bad_frac = 0.0, mean = 0.1)
}

@(test)
canvas_gpu_opaque :: proc(t: ^testing.T) {
	compare(t, "opaque", 64, 48, proc(c: ^canvas2d.Context) {
		fill(c, 0.9, 0.2, 0.2, 0.5)
		canvas2d.ctx_fill_rect(c, 5, 5, 30, 30)
		canvas2d.ctx_clear_rect(c, 10, 10, 10, 10)
		c.state.op = .Destination_Out
		canvas2d.ctx_fill_rect(c, 30, 20, 20, 20)
	}, opaque = true)
}

@(private = "file")
test_glyph_a: ^canvas2d.Path
@(private = "file")
test_glyph_o: ^canvas2d.Path

@(private = "file")
test_text_engine :: proc() -> canvas2d.Text_Engine {
	if test_glyph_a == nil {
		test_glyph_a = new(canvas2d.Path)
		a := test_glyph_a
		canvas2d.path_move_to(a, canvas2d.IDENTITY, 0.05, 0)
		canvas2d.path_line_to(a, canvas2d.IDENTITY, 0.55, 0)
		canvas2d.path_quad_to(a, canvas2d.IDENTITY, 0.3, 1.0, 0.05, 0)
		canvas2d.path_close(a)
		test_glyph_o = new(canvas2d.Path)
		o := test_glyph_o
		canvas2d.path_move_to(o, canvas2d.IDENTITY, 0.05, 0)
		canvas2d.path_line_to(o, canvas2d.IDENTITY, 0.55, 0)
		canvas2d.path_line_to(o, canvas2d.IDENTITY, 0.55, 0.7)
		canvas2d.path_line_to(o, canvas2d.IDENTITY, 0.05, 0.7)
		canvas2d.path_close(o)
		canvas2d.path_move_to(o, canvas2d.IDENTITY, 0.15, 0.1)
		canvas2d.path_line_to(o, canvas2d.IDENTITY, 0.15, 0.6)
		canvas2d.path_line_to(o, canvas2d.IDENTITY, 0.45, 0.6)
		canvas2d.path_line_to(o, canvas2d.IDENTITY, 0.45, 0.1)
		canvas2d.path_close(o)
	}
	return canvas2d.Text_Engine{
		font = proc(user: rawptr, spec: ^canvas2d.Font_Spec) -> u64 { return 1 },
		shape = proc(user: rawptr, font: u64, size: f32, text: string, rtl: bool, ls, ws: f32, glyphs: ^[dynamic]canvas2d.Placed_Glyph) -> f32 {
			x: f32
			for r in text {
				append(glyphs, canvas2d.Placed_Glyph{face = 1, gid = u16(r), x = x, y = 0})
				x += size * 0.65
			}
			return x
		},
		outline = proc(user: rawptr, face: u64, gid: u16) -> ^canvas2d.Path { return gid % 2 == 0 ? test_glyph_o : test_glyph_a },
		metrics = proc(user: rawptr, font: u64, size: f32) -> canvas2d.Font_Metrics {
			return {ascent = size * 0.8, descent = size * 0.2, x_height = size * 0.5, em_ascent = size * 0.8, em_descent = size * 0.2}
		},
	}
}

@(test)
canvas_gpu_text :: proc(t: ^testing.T) {
	compare(t, "text", 200, 100, proc(c: ^canvas2d.Context) {
		fill(c, 0.95, 0.95, 0.5)
		c.state.font.size = 26
		canvas2d.ctx_draw_text(c, "abcdef", 10, 30, 0, false, false)
		c.state.font.size = 11
		fill(c, 0.5, 0.9, 0.9)
		canvas2d.ctx_draw_text(c, "abababab", 10, 50, 0, false, false)
		canvas2d.ctx_translate(c, 100, 80)
		canvas2d.ctx_rotate(c, -0.4)
		c.state.font.size = 20
		canvas2d.ctx_draw_text(c, "ooaa", 0, 0, 0, false, false)
		stroke_style(c, 1, 0.6, 0.6)
		c.state.line_width = 1.5
		canvas2d.ctx_draw_text(c, "aoao", 0, 20, 0, false, true)
	}, tol = 48, bad_frac = 0.03, mean = 1.5)
}

@(test)
canvas_gpu_many_edges :: proc(t: ^testing.T) {
	compare(t, "many_edges", 256, 256, proc(c: ^canvas2d.Context) {
		fill(c, 0.2, 0.8, 0.5, 0.8)
		begin(c)
		for i in 0 ..< 3000 {
			a := f64(i) * 0.37
			r := 20 + 100 * (0.5 + 0.5 * math.sin(f64(i) * 0.011))
			x, y := 128 + r * math.cos(a), 128 + r * math.sin(a)
			if i == 0 { move(c, x, y) } else { line(c, x, y) }
		}
		close(c)
		canvas2d.ctx_fill(c, .Evenodd)
	}, tol = 60, bad_frac = 0.04, mean = 6)
}

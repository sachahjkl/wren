package canvas2d

import "core:math"
import "core:slice"

// The drawing calls of a context on the GPU path (see gpu.odin): each turns the call's geometry into a Gpu_Geom and hands it
// to gpu_draw with a paint.

@(private)
geoms_of :: proc(gm: ^Gpu_Geom) -> []Gpu_Geom { return slice.from_ptr(gm, 1) }

// Is `m` a rotation, a flip and a uniform scale (so a distance in local space is a distance in pixels times one factor)?
@(private)
matrix_is_similarity :: proc "contextless" (m: Matrix) -> bool {
	s2 := m.a * m.a + m.b * m.b
	t2 := m.c * m.c + m.d * m.d
	scale := max(s2, t2, 1e-30)
	return abs(s2 - t2) <= 1e-6 * scale && abs(m.a * m.c + m.b * m.d) <= 1e-6 * scale
}

// The canvas holds nothing the next draw needs when a draw that replaces every pixel comes: what was recorded since the last
// submit is dropped (clip masks made since must stay: the context's state names them).
@(private)
gpu_discard_pending :: proc(g: ^Gpu) {
	for c in g.cmds { if c.kind == .Clip_Make || c.kind == .Clip_Free { return } }
	if len(g.cmds) == 0 { return }
	g.stats.discarded += len(g.insts)
	gpu_drop_pending(g)
}

// A draw of a rectangle of user space.
gpu_rect :: proc(c: ^Context, x, y, w, h: f64, paint: ^Paint) {
	g := c.gpu
	gpu_begin(g)
	m := c.state.ctm
	gm: Gpu_Geom
	ok: bool
	if matrix_is_similarity(m) || (m.b == 0 && m.c == 0) {
		gm, ok = geom_rect(m, x, y, w, h)
	} else {
		cs := [4][2]f64{matrix_apply(m, {x, y}), matrix_apply(m, {x + w, y}), matrix_apply(m, {x + w, y + h}), matrix_apply(m, {x, y + h})}
		polys := [1][][2]f64{cs[:]}
		gm, ok = geom_polys(g, polys[:], .Nonzero)
	}
	if !ok { return }
	idx, src, pok := gpu_paint_of(c, paint)
	if !pok { return }
	gpu_maybe_replace(c, &gm, paint)
	gpu_draw(c, geoms_of(&gm), idx, src)
	gpu_after(c)
}

// A draw that covers the whole canvas with an opaque color and nothing under it showing makes what was recorded before it moot.
@(private)
gpu_maybe_replace :: proc(c: ^Context, gm: ^Gpu_Geom, paint: ^Paint) {
	g := c.gpu
	st := &c.state
	if gm.kind != GG_RECT || paint.kind != .Solid || paint.premul.a < 1 || st.alpha < 1 { return }
	if !(st.op == .Source_Over || st.op == .Copy) || shadow_active(c) || filter_active(c) { return }
	if st.clip != nil && (st.clip.gmask != nil || st.clip.x0 > 0 || st.clip.y0 > 0 || st.clip.x1 < g.w || st.clip.y1 < g.h) { return }
	if gm.box[0] > 0 || gm.box[1] > 0 || gm.box[2] < f64(g.w) || gm.box[3] < f64(g.h) { return }
	if abs(gm.inv[1]) > 1e-9 || abs(gm.inv[2]) > 1e-9 { return }
	gpu_discard_pending(g)
}

@(private)
gpu_after :: proc(c: ^Context) {
	g := c.gpu
	if g.flush_now { g.flush_now = false; gpu_flush(g) }
}

gpu_clear_rect :: proc(c: ^Context, x, y, w, h: f64) {
	g := c.gpu
	gpu_begin(g)
	gm, ok := geom_rect(c.state.ctm, x, y, w, h)
	if !ok { return }
	d := gpu_state(c)
	// the whole canvas, nothing clipping it: a clear
	if d.clip_id == 0 && d.bx0 == 0 && d.by0 == 0 && d.bx1 == g.w && d.by1 == g.h && gm.box[0] <= 0 && gm.box[1] <= 0 && gm.box[2] >= f64(g.w) && gm.box[3] >= f64(g.h) && abs(gm.inv[1]) < 1e-9 && abs(gm.inv[2]) < 1e-9 {
		gpu_discard_pending(g)
		append(&g.cmds, Gpu_Cmd{kind = .Clear, color = {0, 0, 0, g.opaque ? 1 : 0}})
		g.stats.cmds += 1
		return
	}
	b := [4]f64{max(gm.box[0] - 1, f64(d.bx0)), max(gm.box[1] - 1, f64(d.by0)), min(gm.box[2] + 1, f64(d.bx1)), min(gm.box[3] + 1, f64(d.by1))}
	if b[0] >= b[2] || b[1] >= b[3] { return }
	p := gpu_paint_add(g, Gpu_Paint{kind = GP_SOLID, color = {0, 0, 0, 1}})
	box := [4]f32{f32(math.floor(b[0])), f32(math.floor(b[1])), f32(math.ceil(b[2])), f32(math.ceil(b[3]))}
	inst := gpu_make_inst(g, &gm, p, u8(Composite_Op.Destination_Out), 1, false, d.clip_id != 0, box)
	gpu_add_draw(g, inst, u8(Composite_Op.Destination_Out), GPU_SRC_NONE, d.clip_id, {i32(d.bx0), i32(d.by0), i32(d.bx1), i32(d.by1)})
}

// The flattened path of the context (c.flat), filled.
gpu_fill_flat :: proc(c: ^Context, rule: Fill_Rule, paint: ^Paint) {
	g := c.gpu
	gpu_begin(g)
	polys := make([dynamic][][2]f64, 0, len(c.flat.subs), context.temp_allocator)
	for sp in c.flat.subs {
		pts := c.flat.pts[sp.start:sp.end]
		if len(pts) >= 2 { append(&polys, pts) }
	}
	if len(polys) == 0 { return }
	idx, src, pok := gpu_paint_of(c, paint)
	if !pok { return }
	gm: Gpu_Geom
	ok: bool
	if len(polys) == 1 && len(polys[0]) == 4 {
		if x0, y0, x1, y1, is_rect := device_rect_of(polys[0]); is_rect {
			gm, ok = geom_device_rect(x0, y0, x1, y1), true
		}
	}
	if !ok { gm, ok = geom_polys(g, polys[:], rule) }
	if !ok { return }
	gpu_maybe_replace(c, &gm, paint)
	gpu_draw(c, geoms_of(&gm), idx, src)
	gpu_after(c)
}

// Four points that are an axis-aligned rectangle (in either winding).
@(private)
device_rect_of :: proc(p: [][2]f64) -> (x0, y0, x1, y1: f64, ok: bool) {
	if len(p) != 4 { return }
	horizontal_first := p[0].y == p[1].y && p[1].x == p[2].x && p[2].y == p[3].y && p[3].x == p[0].x
	vertical_first := p[0].x == p[1].x && p[1].y == p[2].y && p[2].x == p[3].x && p[3].y == p[0].y
	if !horizontal_first && !vertical_first { return }
	x0, x1 = min(p[0].x, p[2].x), max(p[0].x, p[2].x)
	y0, y1 = min(p[0].y, p[2].y), max(p[0].y, p[2].y)
	return x0, y0, x1, y1, x1 > x0 && y1 > y0
}

// The path `p` (points in the space `m` takes to device space) if it is one ellipse (an arc() of a full turn), as the matrix
// that maps the unit circle onto it.
@(private)
ellipse_of_path :: proc(p: ^Path, m: Matrix) -> (em: Matrix, ok: bool) {
	// verbs: a move, four cubics, maybe a close, maybe a move (what arc() and ellipse() of a full turn leave)
	n := len(p.verbs)
	if n < 5 || n > 7 || p.verbs[0] != .Move { return }
	for i in 1 ..= 4 { if p.verbs[i] != .Cubic { return } }
	for i in 5 ..< n { if p.verbs[i] != .Close && p.verbs[i] != .Move { return } }
	if len(p.pts) < 13 { return }
	P :: proc(p: ^Path, m: Matrix, i: int) -> [2]f64 { return matrix_apply(m, p.pts[i]) }
	e: [5][2]f64
	e[0] = P(p, m, 0)
	for k in 0 ..< 4 { e[k + 1] = P(p, m, 3 + 3 * k) }
	cen := (e[0] + e[2]) * 0.5
	a, b := e[0] - cen, e[1] - cen
	size := max(abs(a.x) + abs(a.y), abs(b.x) + abs(b.y))
	if size < 1e-9 { return }
	tol := 1e-5 * size
	near :: proc(u, v: [2]f64, tol: f64) -> bool { return abs(u.x - v.x) <= tol && abs(u.y - v.y) <= tol }
	if !near(e[4], e[0], tol) || !near(e[3], cen - b, tol) { return }
	K :: 0.5522847498307936
	for k in 0 ..< 4 {
		vk, vn := e[k] - cen, e[k + 1] - cen
		c1, c2 := P(p, m, 1 + 3 * k), P(p, m, 2 + 3 * k)
		if !near(c1, e[k] + K * vn, tol) || !near(c2, e[k + 1] + K * vk, tol) { return }
	}
	em = Matrix{a.x, a.y, b.x, b.y, cen.x, cen.y}
	return em, abs(matrix_det(em)) > 1e-12
}

// Fills the current path (or a Path2D): a circle goes to the ellipse shader; the rest is flattened.
gpu_fill_path :: proc(c: ^Context, p: ^Path, m: Matrix, rule: Fill_Rule, paint: ^Paint) -> bool {
	if em, ok := ellipse_of_path(p, m); ok {
		g := c.gpu
		gpu_begin(g)
		gm, gok := geom_ellipse(em)
		if !gok { return true }
		idx, src, pok := gpu_paint_of(c, paint)
		if !pok { return true }
		gpu_draw(c, geoms_of(&gm), idx, src)
		gpu_after(c)
		return true
	}
	return false
}

// A stroke: the polygons the stroker made (device space, nonzero).
gpu_fill_polys :: proc(c: ^Context, polys: ^Polys, paint: ^Paint) {
	g := c.gpu
	gpu_begin(g)
	list := make([dynamic][][2]f64, 0, len(polys.ends), context.temp_allocator)
	start := 0
	for e in polys.ends {
		if e - start >= 2 { append(&list, polys.pts[start:e]) }
		start = e
	}
	if len(list) == 0 { return }
	idx, src, pok := gpu_paint_of(c, paint)
	if !pok { return }
	gm: Gpu_Geom
	ok: bool
	// one rectangle (a straight line with butt caps): the rect shader, in a frame turned along the line
	if len(list) == 1 && len(list[0]) == 4 {
		gm, ok = rotated_rect_geom(list[0])
	}
	if !ok { gm, ok = geom_polys(g, list[:], .Nonzero) }
	if !ok { return }
	gpu_draw(c, geoms_of(&gm), idx, src)
	gpu_after(c)
}

@(private)
rotated_rect_geom :: proc(p: [][2]f64) -> (gm: Gpu_Geom, ok: bool) {
	u, v := p[1] - p[0], p[3] - p[0]
	lu, lv := math.sqrt(u.x * u.x + u.y * u.y), math.sqrt(v.x * v.x + v.y * v.y)
	if lu < 1e-9 || lv < 1e-9 { return }
	tol := 1e-6 * max(lu, lv)
	if abs(u.x * v.x + u.y * v.y) > tol * max(lu, lv) { return }
	if abs((p[2].x - p[0].x) - (u.x + v.x)) > tol || abs((p[2].y - p[0].y) - (u.y + v.y)) > tol { return }
	if abs(u.y) < tol * 1e-3 || abs(u.x) < tol * 1e-3 {
		// axis aligned
		x0, y0, x1, y1 := min(p[0].x, p[2].x), min(p[0].y, p[2].y), max(p[0].x, p[2].x), max(p[0].y, p[2].y)
		return geom_device_rect(x0, y0, x1, y1), true
	}
	cen := (p[0] + p[2]) * 0.5
	ux, uy := u.x / lu, u.y / lu
	gm.kind = GG_RECT
	gm.geom = {0, 0, f32(lu * 0.5), f32(lv * 0.5)}
	gm.inv = {f32(ux), f32(-uy), f32(uy), f32(ux)}
	gm.inv_t = {f32(-(ux * cen.x + uy * cen.y)), f32(-(-uy * cen.x + ux * cen.y))}
	gm.scale = 1
	gm.box = box_of_points(p)
	return gm, true
}

////////////////////////////////
// Clips

gpu_mask_release :: proc(m: ^Gpu_Mask) {
	if m == nil { return }
	m.refs -= 1
	if m.refs > 0 { return }
	if m.gpu != nil && m.epoch == m.gpu.clip_epoch {
		append(&m.gpu.cmds, Gpu_Cmd{kind = .Clip_Free, id = m.id})
	}
	free(m)
}

gpu_mask_retain :: proc(m: ^Gpu_Mask) -> ^Gpu_Mask {
	if m != nil { m.refs += 1 }
	return m
}

// clip() of the flattened current path: the new region is the old one cut to the shape. A rectangle on whole pixels needs no
// mask; anything else makes a mask texture (the shape's coverage times the old mask).
gpu_clip :: proc(c: ^Context, rule: Fill_Rule) {
	g := c.gpu
	gpu_begin(g)
	old := c.state.clip
	bx0, by0, bx1, by1 := draw_bounds(c)
	polys := make([dynamic][][2]f64, 0, len(c.flat.subs), context.temp_allocator)
	for sp in c.flat.subs {
		pts := c.flat.pts[sp.start:sp.end]
		if len(pts) >= 2 { append(&polys, pts) }
	}
	nx0, ny0, nx1, ny1 := 0, 0, 0, 0   // an empty path clips everything away
	b := [4]f64{math.INF_F64, math.INF_F64, -math.INF_F64, -math.INF_F64}
	for p in polys {
		bb := box_of_points(p)
		b = {min(b[0], bb[0]), min(b[1], bb[1]), max(b[2], bb[2]), max(b[3], bb[3])}
	}
	have := b[0] <= b[2] && b[1] <= b[3]
	if have {
		nx0, ny0 = max(bx0, int(math.floor(b[0]))), max(by0, int(math.floor(b[1])))
		nx1, ny1 = min(bx1, int(math.ceil(b[2]))), min(by1, int(math.ceil(b[3])))
	}
	cl := new(Clip)
	cl.refs = 1
	if nx0 < nx1 && ny0 < ny1 {
		cl.x0, cl.y0, cl.x1, cl.y1 = nx0, ny0, nx1, ny1
		old_mask := old != nil && old.gmask != nil && old.gmask.epoch == g.clip_epoch ? old.gmask : nil
		aligned := false
		if len(polys) == 1 && len(polys[0]) == 4 {
			if x0, y0, x1, y1, is_rect := device_rect_of(polys[0]); is_rect {
				aligned = x0 == math.floor(x0) && y0 == math.floor(y0) && x1 == math.floor(x1) && y1 == math.floor(y1)
			}
		}
		if aligned {
			// a pixel-aligned rectangle: the scissor says it all, the old mask (if any) stays in force
			cl.gmask = gpu_mask_retain(old_mask)
		} else if gm, ok := geom_polys(g, polys[:], rule); ok {
			id := g.next_clip
			g.next_clip += 1
			cl.gmask = new(Gpu_Mask)
			cl.gmask^ = Gpu_Mask{refs = 1, id = id, epoch = g.clip_epoch, gpu = g}
			box := [4]f32{f32(nx0), f32(ny0), f32(nx1), f32(ny1)}
			// (the paint of a mask instance is never read, but its index must exist)
			inst := gpu_make_inst(g, &gm, gpu_paint_add(g, Gpu_Paint{kind = GP_SOLID}), 0, 1, false, old_mask != nil, box)
			inst.ids[0] |= GF_MASK_OUT
			first := len(g.insts)
			append(&g.insts, inst)
			g.stats.insts += 1
			append(&g.cmds, Gpu_Cmd{kind = .Clip_Make, id = id, clip = old_mask != nil ? old_mask.id : 0, box = {i32(nx0), i32(ny0), i32(nx1), i32(ny1)}, first = first, count = 1})
		} else {
			cl.x0, cl.y0, cl.x1, cl.y1 = 0, 0, 0, 0
		}
	}
	clip_release(old)
	c.state.clip = cl
}

////////////////////////////////
// Images

// drawImage of `src`: texels [sx, sx + sw) x [sy, sy + sh) into (dx, dy, dw, dh) of user space. The caller has normalized the
// rectangles as ctx_draw_image does.
gpu_draw_image :: proc(c: ^Context, src: Gpu_Source, sx, sy, sw, sh, dx, dy, dw, dh: f64) {
	g := c.gpu
	gpu_begin(g)
	m := c.state.ctm
	to_dev := matrix_mul(m, matrix_mul(matrix_translate(dx, dy), matrix_mul(matrix_scale(dw / sw, dh / sh), matrix_translate(-sx, -sy))))
	inv, ok := matrix_invert(to_dev)
	if !ok { return }
	self := src.kind == .Canvas && src.canvas == g
	si: i32
	size := [2]int{src.w, src.h}
	lin := false
	if self {
		// the canvas as it is now: a copy of the part drawn from (the draw cannot read what it writes)
		gpu_flush_readers(g)
		x0, y0 := int(math.floor(sx)) - 1, int(math.floor(sy)) - 1
		x1, y1 := int(math.ceil(sx + sw)) + 1, int(math.ceil(sy + sh)) + 1
		append(&g.cmds, Gpu_Cmd{kind = .Snapshot, box = {i32(x0), i32(y0), i32(x1), i32(y1)}})
		si = GPU_SRC_SNAPSHOT
		size = {g.w, g.h}
	} else {
		var_si, var_lin, var_size, sok := gpu_source_index(g, src)
		if !sok { return }
		si, lin, size = var_si, var_lin, var_size
	}
	gp := Gpu_Paint{kind = GP_IMAGE, flags = u32(CLAMP) | u32(CLAMP) << 2 | gpu_filter_of(c) << GP_FILTER_SHIFT | (lin ? GPF_LINEAR_SRC : 0)}
	gp.m = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}
	gp.t = {f32(inv.e), f32(inv.f), 0, 0}
	ix0, iy0 := math.floor(sx), math.floor(sy)
	ix1, iy1 := min(math.ceil(sx + sw), f64(src.w)), min(math.ceil(sy + sh), f64(src.h))
	// the source rectangle is the one asked for (a spritesheet frame must not bleed into its neighbours)
	gp.p = {f32(ix0), f32(iy0), f32(ix1), f32(iy1)}
	gp.q = {f32(size.x), f32(size.y), 0, 0}
	pi := gpu_paint_add(g, gp)
	gm: Gpu_Geom
	gok: bool
	if matrix_is_similarity(m) || (m.b == 0 && m.c == 0) {
		gm, gok = geom_rect(m, dx, dy, dw, dh)
	} else {
		cs := [4][2]f64{matrix_apply(m, {dx, dy}), matrix_apply(m, {dx + dw, dy}), matrix_apply(m, {dx + dw, dy + dh}), matrix_apply(m, {dx, dy + dh})}
		polys := [1][][2]f64{cs[:]}
		gm, gok = geom_polys(g, polys[:], .Nonzero)
	}
	if !gok { return }
	gpu_draw(c, geoms_of(&gm), pi, si)
	gpu_after(c)
}

@(private)
CLAMP :: Wrap.Clamp

// putImageData: the premultiplied pixels `pix` (w x h) replace the block at (x, y).
gpu_put_pixels :: proc(c: ^Context, pix: []u8, x, y, w, h: int) {
	g := c.gpu
	gpu_begin(g)
	if w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > g.w || y + h > g.h { return }
	// a block that is the whole canvas replaces everything: earlier work is moot
	if x == 0 && y == 0 && w == g.w && h == g.h { gpu_discard_pending(g) }
	off := len(g.pixels)
	append(&g.pixels, ..pix[:w * h * 4])
	append(&g.cmds, Gpu_Cmd{kind = .Put, box = {i32(x), i32(y), i32(w), i32(h)}, pix = off})
	if len(g.pixels) > 64 << 20 { gpu_flush(g) }
}

////////////////////////////////
// Reading

// What a read of the canvas costs is a wait for the GPU: reads that follow drawing every time are counted, and a canvas that
// is read too often goes back to the software rasterizer, where a read is free.
@(private)
gpu_note_read :: proc(c: ^Context) -> bool {
	g := c.gpu
	g.stats.reads += 1
	if g.draws_since_read > 0 { g.read_score += 2 }
	g.draws_since_read = 0
	if g.read_score >= g.opts.read_penalty && g.opts.read_penalty > 0 {
		gpu_to_software(c)
		return false
	}
	return true
}

// Called once per frame the canvas is shown (the score of reads fades).
gpu_frame :: proc(g: ^Gpu) {
	if g.read_score > 0 { g.read_score -= 1 }
}

// getImageData: straight RGBA8 of a block into `out`.
gpu_get_image_data :: proc(c: ^Context, x, y, w, h: int, out: []u8) {
	if !gpu_note_read(c) {
		bitmap_read_straight(c.bmp, x, y, w, h, out)
		return
	}
	g := c.gpu
	gpu_flush(g)
	buf := make([]u8, w * h * 4, context.temp_allocator)
	if g.read_cache != nil && g.read_cache_version == g.version && g.last_read == {x, y, w, h} && len(g.read_cache) == len(buf) {
		copy(buf, g.read_cache)
	} else {
		if !g.host.read(g.host.user, g, x, y, w, h, buf) { for i in 0 ..< len(out) { out[i] = 0 }; return }
		if w * h <= 1 << 22 {
			delete(g.read_cache)
			g.read_cache = make([]u8, len(buf))
			copy(g.read_cache, buf)
			g.read_cache_version, g.last_read = g.version, {x, y, w, h}
		}
	}
	view := Bitmap{w = w, h = h, pix = buf}
	bitmap_read_straight(&view, 0, 0, w, h, out)
}

// The context's bitmap holding what the canvas shows (premultiplied, allocated on first use): for what needs the pixels on the
// CPU (encoding, a software canvas drawing this one, patterns, createImageBitmap). nil: it could not be had.
gpu_bitmap :: proc(c: ^Context) -> ^Bitmap {
	g := c.gpu
	if g == nil { return c.bmp }
	if g.mirror_ok && g.mirror == g.version && len(c.bmp.pix) == g.w * g.h * 4 { return c.bmp }
	gpu_flush(g)
	if len(c.bmp.pix) != g.w * g.h * 4 {
		pix, err := make([]u8, g.w * g.h * 4)
		if err != nil { return nil }
		c.bmp.pix = pix
		c.bmp.allocator = context.allocator
	}
	if !g.host.read(g.host.user, g, 0, 0, g.w, g.h, c.bmp.pix) { return nil }
	g.mirror, g.mirror_ok = g.version, true
	return c.bmp
}

// The canvas goes back to the software rasterizer, keeping what it shows (and its clips, whose masks are read back).
gpu_to_software :: proc(c: ^Context) {
	g := c.gpu
	if g == nil { return }
	have := gpu_bitmap(c) != nil
	if !have {
		pix, err := make([]u8, g.w * g.h * 4)
		if err == nil { c.bmp.pix = pix; c.bmp.allocator = context.allocator }
		if c.bmp.opaque { bitmap_reset_contents(c.bmp) }
	}
	// clips: masks that live on the GPU become pixels
	convert :: proc(c: ^Context, cl: ^Clip) {
		if cl == nil || cl.gmask == nil { return }
		g := c.gpu
		if cl.gmask.epoch == g.clip_epoch && cl.x1 > cl.x0 && cl.y1 > cl.y0 && g.host.read_mask != nil {
			full := make([]u8, g.w * g.h, context.temp_allocator)
			if g.host.read_mask(g.host.user, g, cl.gmask.id, full) {
				w := cl.x1 - cl.x0
				cl.mask = make([]u8, w * (cl.y1 - cl.y0))
				for y in cl.y0 ..< cl.y1 { copy(cl.mask[(y - cl.y0) * w:][:w], full[y * g.w + cl.x0:][:w]) }
			}
		}
		// the mask is shared: release our reference
		gpu_mask_release(cl.gmask)
		cl.gmask = nil
	}
	seen := make([dynamic]^Clip, context.temp_allocator)
	visit :: proc(c: ^Context, cl: ^Clip, seen: ^[dynamic]^Clip) {
		if cl == nil { return }
		for s in seen { if s == cl { return } }
		append(seen, cl)
		convert(c, cl)
	}
	visit(c, c.state.clip, &seen)
	for &s in c.stack { visit(c, s.clip, &seen) }
	gpu_flush(g)
	c.gpu = nil
	gpu_destroy(g)
	bitmap_touch_all(c.bmp)
}

// A context that cannot use the GPU (its list failed to submit) is brought back to software before its next call.
gpu_check :: proc(c: ^Context) {
	if c.gpu != nil && c.gpu.failed { gpu_to_software(c) }
}

////////////////////////////////
// Text

Glyph_Key :: struct {
	face:   u64,
	gid:    u16,
	bucket: u8,
}

@(private)
glyph_shapes: map[Glyph_Key]^Shape_Blob

// Forgets the glyph shapes (the fonts changed).
gpu_glyphs_clear :: proc() {
	for _, b in glyph_shapes { delete(b.heap); free(b) }
	clear(&glyph_shapes)
}

gpu_glyphs_destroy :: proc() {
	gpu_glyphs_clear()
	delete(glyph_shapes)
	glyph_shapes = nil
}

// The shape of a glyph for sizes around `px` device pixels (half-octave buckets: the flattening error is below a twentieth of
// a pixel at the largest size of the bucket).
@(private)
glyph_blob :: proc(c: ^Context, face: u64, gid: u16, outline: ^Path, px: f64) -> ^Shape_Blob {
	g := c.gpu
	bucket := u8(clamp(int(math.ceil(math.log2(max(px, 1)) * 2)), 0, 60))
	key := Glyph_Key{face, gid, bucket}
	if b, ok := glyph_shapes[key]; ok { g.stats.glyph_hits += 1; return b }
	if len(glyph_shapes) >= g.opts.glyph_cache_entries { gpu_glyphs_clear() }
	upper := math.pow(2, f64(bucket) * 0.5)
	lower := upper * 0.70710678
	flat := Flat{}
	defer flat_destroy(&flat)
	path_flatten(outline, IDENTITY, 0.04 / upper, &flat)
	polys := make([dynamic][][2]f64, 0, len(flat.subs), context.temp_allocator)
	for sp in flat.subs {
		pts := flat.pts[sp.start:sp.end]
		if len(pts) >= 2 { append(&polys, pts) }
	}
	tmp := make([dynamic][4]u32, 0, 64, context.temp_allocator)
	_, nb, bounds, ok := shape_build(&tmp, polys[:], {}, f32(1.0 / lower), g.opts.max_shape_edges)
	blob := new(Shape_Blob)
	if ok {
		blob.heap = make([][4]u32, len(tmp))
		copy(blob.heap, tmp[:])
		blob.bands, blob.bounds = nb, bounds
	}
	glyph_shapes[key] = blob
	g.stats.glyph_builds += 1
	return blob
}

// fillText: one instance per glyph, from cached shapes. Returns false when the text engine cannot (the caller draws paths).
gpu_fill_text :: proc(c: ^Context, lo: ^Laid_Out, ox, oy, k: f64, paint: ^Paint) {
	g := c.gpu
	gpu_begin(g)
	e := &c.text
	idx, src, pok := gpu_paint_of(c, paint)
	if !pok { return }
	geoms := make([dynamic]Gpu_Geom, 0, len(lo.glyphs), context.temp_allocator)
	big, _ := matrix_scales(c.state.ctm)
	for gl in lo.glyphs {
		o := e.outline(e.user, gl.face, gl.gid)
		if o == nil || path_is_empty(o) { continue }
		gm := matrix_mul(c.state.ctm, matrix_mul(matrix_translate(ox + f64(gl.x) * k, oy + f64(gl.y)), matrix_scale(f64(lo.size) * k, -f64(lo.size))))
		inv, iok := matrix_invert(gm)
		if !iok { continue }
		px := f64(lo.size) * k * big
		blob := glyph_blob(c, gl.face, gl.gid, o, px)
		if blob == nil || len(blob.heap) == 0 { continue }
		bb := blob.bounds
		cs := [4][2]f64{matrix_apply(gm, {f64(bb[0]), f64(bb[1])}), matrix_apply(gm, {f64(bb[2]), f64(bb[1])}), matrix_apply(gm, {f64(bb[2]), f64(bb[3])}), matrix_apply(gm, {f64(bb[0]), f64(bb[3])})}
		geom := Gpu_Geom{
			kind = GG_SHAPE, geom = bb, inv = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}, inv_t = {f32(inv.e), f32(inv.f)},
			scale = 1, box = box_of_points(cs[:]), blob = blob,
		}
		append(&geoms, geom)
	}
	if len(geoms) == 0 { return }
	gpu_draw(c, geoms[:], idx, src)
	gpu_after(c)
}

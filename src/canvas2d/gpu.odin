package canvas2d

import "core:math"

// The GPU canvas: what a context records instead of rasterizing (see gpu_types.odin; the renderer is the toolkit's
// render/canvas.odin, the shaders canvas.wgsl). Every drawing call becomes instances (a quad, a geometry, a paint, an
// operator) in a list that is submitted in one go when something needs the pixels: the shell painting the canvas, a read,
// another canvas drawing this one, or a list that grew past its limit. A canvas nobody looks at costs the recording only.
//
// The software rasterizer of the rest of this package stays the reference and the fallback: a context made with
// willReadFrequently, a canvas the GPU cannot make, and a canvas that is read back so often that the reads cost more than
// the drawing saves all use it.

Gpu_Stats :: struct {
	insts:      int,
	cmds:       int,
	flushes:    int,
	discarded:  int,    // instances dropped because a full clear came after them
	glyph_hits: int,
	glyph_builds: int,
	shape_edges: int,
	reads:      int,
	layers:     int,
}

Gpu :: struct {
	host:     ^Gpu_Host,
	ctx:      ^Context,
	opts:     Gpu_Options,
	w, h:     int,
	opaque:   bool,
	target:   i64,                 // the owner's texture handle (0: none yet)
	insts:    [dynamic]Gpu_Inst,
	heap:     [dynamic][4]u32,
	paints:   [dynamic]Gpu_Paint,
	stops:    [dynamic][4]f32,
	cmds:     [dynamic]Gpu_Cmd,
	pixels:   [dynamic]u8,
	sources:  [dynamic]Gpu_Source,
	source_tex: [dynamic]i64,
	source_lin: [dynamic]bool,
	source_size: [dynamic][2]int,
	next_clip: i32,
	next_layer: i32,
	clip_epoch: u32,               // a device loss makes every mask id of an older epoch void
	version:  u64,                 // grows with every change of the canvas
	flushed:  u64,                 // the version the texture shows
	mirror:   u64,                 // the version the context's bitmap shows (valid when mirror_ok)
	mirror_ok: bool,
	readers:  [dynamic]^Gpu,       // canvases whose pending lists draw this one
	reads_from: [dynamic]^Gpu,     // canvases this one's pending list draws
	generation: u64,
	failed:   bool,
	flush_now: bool,               // a draw of a video: the list is submitted before its texture can change
	read_score: int,               // reads that followed drawing, decaying
	draws_since_read: int,
	last_read: [4]int,             // the block of the cached read
	read_cache: []u8,
	read_cache_version: u64,
	stats:    Gpu_Stats,
	temp_clip: bool,
}

// A clip mask on the GPU, shared by the clips that were made from it.
Gpu_Mask :: struct {
	refs:  int,
	id:    i32,
	epoch: u32,
	gpu:   ^Gpu,
}

gpu_create :: proc(host: ^Gpu_Host, ctx: ^Context, opts: Gpu_Options, w, h: int, opaque: bool) -> ^Gpu {
	g := new(Gpu)
	g.host, g.ctx, g.opts, g.w, g.h, g.opaque = host, ctx, opts, w, h, opaque
	g.generation = host.generation != nil ? host.generation(host.user) : 0
	g.next_clip, g.next_layer = 1, 1
	g.version = 1
	return g
}

gpu_destroy :: proc(g: ^Gpu) {
	if g == nil { return }
	// whoever still has a list that draws this canvas sees it first
	gpu_flush_readers(g)
	gpu_drop_pending(g)
	for s in g.reads_from { for r, i in s.readers { if r == g { unordered_remove(&s.readers, i); break } } }
	if g.target != 0 && g.host.destroy != nil { g.host.destroy(g.host.user, g) }
	delete(g.insts); delete(g.heap); delete(g.paints); delete(g.stops); delete(g.cmds); delete(g.pixels)
	delete(g.sources); delete(g.source_tex); delete(g.source_lin); delete(g.source_size)
	delete(g.readers); delete(g.reads_from); delete(g.read_cache)
	free(g)
}

// The lists forgotten without being submitted (the canvas was cleared, resized or is going away).
@(private)
gpu_drop_pending :: proc(g: ^Gpu) {
	for &s in g.sources { if g.host.unpin != nil { g.host.unpin(g.host.user, &s) } }
	clear(&g.insts); clear(&g.heap); clear(&g.paints); clear(&g.stops); clear(&g.cmds); clear(&g.pixels)
	clear(&g.sources); clear(&g.source_tex); clear(&g.source_lin); clear(&g.source_size)
	for s in g.reads_from { for r, i in s.readers { if r == g { unordered_remove(&s.readers, i); break } } }
	clear(&g.reads_from)
}

@(private)
gpu_flush_readers :: proc(g: ^Gpu) {
	if len(g.readers) == 0 { return }
	rs := make([dynamic]^Gpu, len(g.readers), context.temp_allocator)
	copy(rs[:], g.readers[:])
	clear(&g.readers)
	for r in rs { if r != g { gpu_flush(r) } }
}

// Submits what was recorded. false: the owner could not draw it (the canvas is then `failed` and the context goes back to
// software at its next call).
gpu_flush :: proc(g: ^Gpu) -> bool {
	if g == nil { return false }
	if len(g.cmds) == 0 && g.target != 0 { return !g.failed }
	g.stats.flushes += 1
	ok := g.host.submit(g.host.user, g)
	gpu_drop_pending(g)
	g.flushed = g.version
	if !ok { g.failed = true }
	return ok
}

// The device was recreated since the last call: the texture lost its contents (its handle stays valid), pending lists named
// textures that are gone, clip masks are void.
@(private)
gpu_device_changed :: proc(g: ^Gpu, gen: u64) {
	g.generation = gen
	gpu_drop_pending(g)
	g.clip_epoch += 1
	g.mirror_ok = g.mirror_ok && g.mirror == g.flushed
	if g.target != 0 {
		// the contents come back from the bitmap when it holds them, else the canvas starts empty
		bmp := g.ctx.bmp
		if g.mirror_ok && bmp != nil && len(bmp.pix) == g.w * g.h * 4 {
			append(&g.cmds, Gpu_Cmd{kind = .Put, box = {0, 0, i32(g.w), i32(g.h)}, pix = len(g.pixels)})
			append(&g.pixels, ..bmp.pix)
		} else {
			append(&g.cmds, Gpu_Cmd{kind = .Clear, color = {0, 0, 0, g.opaque ? 1 : 0}})
		}
	}
}

// Called before anything is recorded that changes the canvas: the lists that read this canvas go first, a changed device is
// noticed, the version grows.
@(private)
gpu_begin :: proc(g: ^Gpu) {
	gpu_flush_readers(g)
	if g.host.generation != nil {
		if gen := g.host.generation(g.host.user); gen != g.generation { gpu_device_changed(g, gen) }
	}
	g.version += 1
	g.draws_since_read += 1
}

// The canvas has a new size: contents and pending lists are dropped, the texture goes (made again at the next submit).
gpu_resize :: proc(g: ^Gpu, w, h: int) {
	gpu_flush_readers(g)
	gpu_drop_pending(g)
	if g.target != 0 && g.host.destroy != nil { g.host.destroy(g.host.user, g) }
	g.target = 0
	g.w, g.h = w, h
	g.version += 1
	g.mirror_ok = false
	g.clip_epoch += 1
	delete(g.read_cache); g.read_cache = nil
	g.failed = false
}

// reset(): everything transparent (black when opaque) again.
gpu_reset :: proc(g: ^Gpu) {
	gpu_begin(g)
	gpu_drop_pending(g)
	g.clip_epoch += 1
	append(&g.cmds, Gpu_Cmd{kind = .Clear, color = {0, 0, 0, g.opaque ? 1 : 0}})
	g.mirror_ok = false
}

////////////////////////////////
// Recording

@(private)
gpu_source_index :: proc(g: ^Gpu, src: Gpu_Source) -> (idx: i32, linear: bool, size: [2]int, ok: bool) {
	for s, i in g.sources {
		if s.kind == src.kind && s.bmp == src.bmp && s.canvas == src.canvas && s.id == src.id && (src.kind != .Bitmap || s.bmp.version == src.bmp.version) {
			return i32(i), g.source_lin[i], g.source_size[i], true
		}
	}
	s := src
	if src.kind == .Canvas {
		// the pixels it holds now, and a note to flush the lists that draw it before it changes
		if src.canvas == nil || src.canvas.failed { return }
		gpu_flush(src.canvas)
	}
	tex, lin, size2 := g.host.resolve(g.host.user, &s)
	if tex == 0 { return }
	if src.kind == .Canvas {
		found := false
		for r in src.canvas.readers { if r == g { found = true; break } }
		if !found { append(&src.canvas.readers, g); append(&g.reads_from, src.canvas) }
	}
	if src.kind == .Video { g.flush_now = true }
	append(&g.sources, s)
	append(&g.source_tex, tex)
	append(&g.source_lin, lin)
	append(&g.source_size, size2)
	return i32(len(g.sources) - 1), lin, size2, true
}

@(private)
gpu_paint_add :: proc(g: ^Gpu, p: Gpu_Paint) -> u32 {
	if n := len(g.paints); n > 0 && g.paints[n - 1] == p { return u32(n - 1) }
	append(&g.paints, p)
	return u32(len(g.paints) - 1)
}

// Appends an instance to the draw that is open when it has the same state, else opens a new one.
@(private)
gpu_add_draw :: proc(g: ^Gpu, inst: Gpu_Inst, op: u8, source: i32, clip: i32, scissor: [4]i32) {
	append(&g.insts, inst)
	g.stats.insts += 1
	if n := len(g.cmds); n > 0 {
		c := &g.cmds[n - 1]
		if c.kind == .Draw && c.op == op && c.source == source && c.clip == clip && c.box == scissor && c.first + c.count == len(g.insts) - 1 {
			c.count += 1
			return
		}
	}
	append(&g.cmds, Gpu_Cmd{kind = .Draw, op = op, source = source, clip = clip, box = scissor, first = len(g.insts) - 1, count = 1})
}

@(private)
gpu_check_limits :: proc(g: ^Gpu) {
	if len(g.insts) >= g.opts.max_insts || len(g.heap) >= g.opts.max_insts * 8 { gpu_flush(g) }
}

////////////////////////////////
// Geometry

// What a draw covers, ready to become an instance (the paint, operator and state are added at emission).
Gpu_Geom :: struct {
	kind:   u32,             // GG_*
	flags:  u32,             // GF_EVENODD
	geom:   [4]f32,
	geom2:  [4]f32,
	inv:    [4]f32,          // device -> local, a b c d
	inv_t:  [2]f32,
	scale:  f32,             // device pixels per local unit
	box:    [4]f64,          // device bounds of what it covers (no antialiasing margin)
	heap_base: int,          // GG_SHAPE: where its data lies in the heap of the list it was built into (or -1 with `blob`)
	bands:  int,
	blob:   ^Shape_Blob,     // GG_SHAPE from the glyph cache: copied into the list at emission
}

Shape_Blob :: struct {
	heap:   [][4]u32,
	bands:  int,
	bounds: [4]f32,
}

@(private)
box_of_points :: proc(pts: [][2]f64) -> (b: [4]f64) {
	b = {math.INF_F64, math.INF_F64, -math.INF_F64, -math.INF_F64}
	for p in pts { b = {min(b[0], p.x), min(b[1], p.y), max(b[2], p.x), max(b[3], p.y)} }
	return
}

// A rectangle of user space under the matrix `m`.
@(private)
geom_rect :: proc(m: Matrix, x, y, w, h: f64) -> (gm: Gpu_Geom, ok: bool) {
	inv, iok := matrix_invert(m)
	if !iok { return }
	x, y, w, h := x, y, w, h
	if w < 0 { x += w; w = -w }
	if h < 0 { y += h; h = -h }
	gm.kind = GG_RECT
	gm.geom = {f32(x + w * 0.5), f32(y + h * 0.5), f32(w * 0.5), f32(h * 0.5)}
	gm.inv = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}
	gm.inv_t = {f32(inv.e), f32(inv.f)}
	gm.scale = f32(math.sqrt(abs(matrix_det(m))))
	cs := [4][2]f64{matrix_apply(m, {x, y}), matrix_apply(m, {x + w, y}), matrix_apply(m, {x + w, y + h}), matrix_apply(m, {x, y + h})}
	gm.box = box_of_points(cs[:])
	return gm, true
}

// A device-space rectangle (a path that is one).
@(private)
geom_device_rect :: proc(x0, y0, x1, y1: f64) -> Gpu_Geom {
	return Gpu_Geom{
		kind = GG_RECT, geom = {f32((x0 + x1) * 0.5), f32((y0 + y1) * 0.5), f32((x1 - x0) * 0.5), f32((y1 - y0) * 0.5)},
		inv = {1, 0, 0, 1}, scale = 1, box = {x0, y0, x1, y1},
	}
}

// An ellipse: the image of the unit circle under `m` (device = m * unit).
@(private)
geom_ellipse :: proc(m: Matrix) -> (gm: Gpu_Geom, ok: bool) {
	inv, iok := matrix_invert(m)
	if !iok { return }
	gm.kind = GG_ELLIPSE
	gm.geom = {0, 0, 1, 1}
	gm.inv = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}
	gm.inv_t = {f32(inv.e), f32(inv.f)}
	gm.scale = f32(math.sqrt(abs(matrix_det(m))))
	ax := math.sqrt(m.a * m.a + m.c * m.c)   // half extents of the bounding box of the image
	ay := math.sqrt(m.b * m.b + m.d * m.d)
	gm.box = {m.e - ax, m.f - ay, m.e + ax, m.f + ay}
	return gm, true
}

// Polygons (device space) as a shape built into the list's heap.
@(private)
geom_polys :: proc(g: ^Gpu, polys: [][][2]f64, rule: Fill_Rule) -> (gm: Gpu_Geom, ok: bool) {
	b := [4]f64{math.INF_F64, math.INF_F64, -math.INF_F64, -math.INF_F64}
	for p in polys {
		bb := box_of_points(p)
		b = {min(b[0], bb[0]), min(b[1], bb[1]), max(b[2], bb[2]), max(b[3], bb[3])}
	}
	if !(b[0] <= b[2]) || !(b[1] <= b[3]) { return }
	origin := [2]f64{math.floor(b[0]), math.floor(b[1])}
	base, nb, bounds, sok := shape_build(&g.heap, polys, origin, 1.5, g.opts.max_shape_edges)
	if !sok { return }
	g.stats.shape_edges += len(g.heap) - base
	gm.kind = GG_SHAPE
	if rule == .Evenodd { gm.flags = GF_EVENODD }
	gm.geom = {bounds[0], bounds[1], bounds[2], bounds[3]}
	gm.inv = {1, 0, 0, 1}
	gm.inv_t = {f32(-origin.x), f32(-origin.y)}
	gm.scale = 1
	gm.box = b
	gm.heap_base, gm.bands = base, nb
	return gm, true
}

////////////////////////////////
// Paints

@(private)
gpu_filter_of :: proc(c: ^Context) -> u32 {
	if !c.state.smoothing { return GP_FILTER_NEAREST }
	switch c.state.quality {
	case .Low, .Medium: return GP_FILTER_MIPS
	case .High: return GP_FILTER_ANISO
	}
	return GP_FILTER_MIPS
}

@(private)
gpu_stops_add :: proc(g: ^Gpu, gr: ^Gradient) -> (first, n: u32) {
	n = u32(len(gr.stops))
	// the same stops as the last gradient of the list: shared
	if len(g.paints) > 0 {
		lp := g.paints[len(g.paints) - 1]
		if lp.kind >= GP_LINEAR && lp.kind <= GP_CONIC && lp.nstops == n && n > 0 {
			same := true
			for s, i in gr.stops {
				c, o := g.stops[int(lp.stops) + i * 2], g.stops[int(lp.stops) + i * 2 + 1]
				if c != s.color || o.x != f32(s.offset) { same = false; break }
			}
			if same { return lp.stops, n }
		}
	}
	first = u32(len(g.stops))
	for s in gr.stops {
		append(&g.stops, s.color)
		append(&g.stops, [4]f32{f32(s.offset), 0, 0, 0})
	}
	return first, n
}

// The paint of a style (a fill or stroke style under the current transform). Returns the index in the list; false: nothing can
// be drawn with it. `src` is filled for a pattern: the draw samples it.
@(private)
gpu_paint_of :: proc(c: ^Context, p: ^Paint) -> (idx: u32, src: i32, ok: bool) {
	g := c.gpu
	src = GPU_SRC_NONE
	switch p.kind {
	case .Solid:
		return gpu_paint_add(g, Gpu_Paint{kind = GP_SOLID, color = p.premul}), src, true
	case .Gradient:
		gr := p.grad
		first, n := gpu_stops_add(g, gr)
		if n == 0 { return gpu_paint_add(g, Gpu_Paint{kind = GP_SOLID}), src, true }
		inv := p.inv   // device -> the gradient's user space
		gp := Gpu_Paint{nstops = n, stops = first}
		switch gr.kind {
		case .Linear:
			dx, dy := gr.x1 - gr.x0, gr.y1 - gr.y0
			l2 := dx * dx + dy * dy
			if l2 == 0 { return gpu_paint_add(g, Gpu_Paint{kind = GP_SOLID}), src, true }
			gp.kind = GP_LINEAR
			gp.m = {f32((inv.a * dx + inv.b * dy) / l2), f32((inv.c * dx + inv.d * dy) / l2), 0, 0}
			gp.t = {0, 0, f32((inv.e * dx + inv.f * dy - (gr.x0 * dx + gr.y0 * dy)) / l2), 0}
		case .Radial:
			gp.kind = GP_RADIAL
			gp.m = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}
			gp.t = {f32(inv.e), f32(inv.f), 0, 0}
			gp.p = {f32(gr.x0), f32(gr.y0), f32(gr.r0), f32(gr.x1)}
			gp.q = {f32(gr.y1), f32(gr.r1), 0, 0}
		case .Conic:
			gp.kind = GP_CONIC
			gp.m = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}
			gp.t = {f32(inv.e), f32(inv.f), 0, 0}
			gp.p = {f32(gr.x0), f32(gr.y0), f32(gr.r0), 0}
		}
		return gpu_paint_add(g, gp), src, true
	case .Pattern:
		pat := p.pat
		s := Gpu_Source{kind = .Bitmap, bmp = &pat.bmp, w = pat.bmp.w, h = pat.bmp.h}
		si, lin, size, sok := gpu_source_index(g, s)
		if !sok { return }
		wrap := u32(pat.repeat_x ? 2 : 0) | u32(pat.repeat_y ? 2 : 0) << 2
		gp := Gpu_Paint{kind = GP_IMAGE, flags = wrap | gpu_filter_of(c) << GP_FILTER_SHIFT | (lin ? GPF_LINEAR_SRC : 0)}
		inv := p.inv
		gp.m = {f32(inv.a), f32(inv.b), f32(inv.c), f32(inv.d)}
		gp.t = {f32(inv.e), f32(inv.f), 0, 0}
		gp.p = {0, 0, f32(pat.bmp.w), f32(pat.bmp.h)}
		gp.q = {f32(size.x), f32(size.y), 0, 0}
		return gpu_paint_add(g, gp), si, true
	case .Image:
		return 0, src, false   // drawImage builds its own
	}
	return
}

////////////////////////////////
// Emission

// The state of a draw: what the context says now.
@(private)
Draw_State :: struct {
	op:       Composite_Op,
	alpha:    f32,
	bx0, by0, bx1, by1: int,    // where it may draw (clip rect and canvas)
	clip_id:  i32,
	unbounded: bool,
}

@(private)
gpu_state :: proc(c: ^Context) -> Draw_State {
	st := &c.state
	d := Draw_State{op = st.op, alpha = f32(clamp(st.alpha, 0, 1)), unbounded = op_is_unbounded(st.op)}
	d.bx0, d.by0, d.bx1, d.by1 = draw_bounds(c)
	if cl := st.clip; cl != nil && cl.gmask != nil && cl.gmask.epoch == c.gpu.clip_epoch { d.clip_id = cl.gmask.id }
	return d
}

@(private)
gpu_make_inst :: proc(g: ^Gpu, gm: ^Gpu_Geom, paint: u32, op: u8, alpha: f32, unbounded, clip: bool, box: [4]f32) -> Gpu_Inst {
	flags := gm.kind | gm.flags | u32(op) << GF_OP_SHIFT
	if unbounded { flags |= GF_UNBOUNDED }
	if clip { flags |= GF_CLIP }
	base := u32(gm.heap_base)
	nb := u32(gm.bands)
	if gm.blob != nil {
		base = u32(len(g.heap))
		append(&g.heap, ..gm.blob.heap)
		nb = u32(gm.blob.bands)
	}
	return Gpu_Inst{
		box = box, geom = gm.geom, geom2 = gm.geom2, inv = gm.inv,
		misc = {gm.inv_t[0], gm.inv_t[1], alpha, gm.scale},
		ids = {flags, paint, base, nb},
	}
}

@(private)
box_to_f32 :: proc(b: [4]f64) -> [4]f32 { return {f32(b[0]), f32(b[1]), f32(b[2]), f32(b[3])} }

// Draws `geoms` (one shape or the glyphs of a text) with the paint `paint` (index) and sample source `src`, under the
// context's state: operator, alpha, clip, shadow, filter.
@(private)
gpu_draw :: proc(c: ^Context, geoms: []Gpu_Geom, paint: u32, src: i32, full_coverage_ok := false) {
	g := c.gpu
	st := &c.state
	d := gpu_state(c)
	shadow, filtered := shadow_active(c), filter_active(c)
	scissor := [4]i32{i32(d.bx0), i32(d.by0), i32(d.bx1), i32(d.by1)}
	if d.bx0 >= d.bx1 || d.by0 >= d.by1 { return }
	// the part of the canvas the geometry reaches (a margin for antialiasing)
	reach := [4]f64{math.INF_F64, math.INF_F64, -math.INF_F64, -math.INF_F64}
	for gm in geoms { reach = {min(reach[0], gm.box[0]), min(reach[1], gm.box[1]), max(reach[2], gm.box[2]), max(reach[3], gm.box[3])} }
	if !(reach[0] <= reach[2]) { return }
	reach = {reach[0] - 1, reach[1] - 1, reach[2] + 1, reach[3] + 1}
	if !shadow && !filtered {
		region := [4]f64{max(reach[0], f64(d.bx0)), max(reach[1], f64(d.by0)), min(reach[2], f64(d.bx1)), min(reach[3], f64(d.by1))}
		if !d.unbounded && (region[0] >= region[2] || region[1] >= region[3]) { return }
		for &gm in geoms {
			box: [4]f32
			if d.unbounded {
				box = {f32(d.bx0), f32(d.by0), f32(d.bx1), f32(d.by1)}
			} else {
				b := [4]f64{max(gm.box[0] - 1, f64(d.bx0)), max(gm.box[1] - 1, f64(d.by0)), min(gm.box[2] + 1, f64(d.bx1)), min(gm.box[3] + 1, f64(d.by1))}
				if b[0] >= b[2] || b[1] >= b[3] { gpu_rollback_geom(g, &gm); continue }
				box = {f32(math.floor(b[0])), f32(math.floor(b[1])), f32(math.ceil(b[2])), f32(math.ceil(b[3]))}
			}
			inst := gpu_make_inst(g, &gm, paint, u8(d.op), d.alpha, d.unbounded, d.clip_id != 0, box)
			gpu_add_draw(g, inst, u8(d.op), src, d.clip_id, scissor)
		}
		gpu_check_limits(g)
		return
	}

	// a layer: the shapes alone (source-over onto transparent), filtered, shadowed, then composited with the operator
	lx0, ly0, lx1, ly1 := int(math.floor(reach[0])), int(math.floor(reach[1])), int(math.ceil(reach[2])), int(math.ceil(reach[3]))
	scale, _ := matrix_scales(st.ctm)
	freach := filtered ? filter_reach(c) : 0
	lx0, ly0, lx1, ly1 = lx0 - freach, ly0 - freach, lx1 + freach, ly1 + freach
	if shadow {
		sreach := int(math.ceil(max(st.shadow.blur, 0) * 1.5)) + 1
		lx0, ly0, lx1, ly1 = lx0 - sreach, ly0 - sreach, lx1 + sreach, ly1 + sreach
	}
	// no further than what can show (the canvas, widened by what the blurs and the shadow offset bring in)
	slack := freach + (shadow ? int(math.ceil(max(st.shadow.blur, 0) * 1.5)) + 1 : 0)
	sx, sy := shadow ? int(math.round(st.shadow.ox)) : 0, shadow ? int(math.round(st.shadow.oy)) : 0
	lx0, ly0 = max(lx0, -slack - max(sx, 0)), max(ly0, -slack - max(sy, 0))
	lx1, ly1 = min(lx1, g.w + slack + max(-sx, 0)), min(ly1, g.h + slack + max(-sy, 0))
	if !filtered {   // (a filter's reach is in the layer already)
		lx0, ly0, lx1, ly1 = max(lx0, d.bx0 - slack - max(sx, 0)), max(ly0, d.by0 - slack - max(sy, 0)), min(lx1, d.bx1 + slack + max(-sx, 0)), min(ly1, d.by1 + slack + max(-sy, 0))
	}
	// layers of a few sizes are reused: the box grows to multiples of 16
	lx0, ly0 = lx0 / 16 * 16 - (lx0 < 0 && lx0 % 16 != 0 ? 16 : 0), ly0 / 16 * 16 - (ly0 < 0 && ly0 % 16 != 0 ? 16 : 0)
	lx1, ly1 = (lx1 + 15) / 16 * 16, (ly1 + 15) / 16 * 16
	if lx0 >= lx1 || ly0 >= ly1 {
		for &gm in geoms { gpu_rollback_geom(g, &gm) }
		if d.unbounded { gpu_composite_nothing(c, d) }
		return
	}
	if (lx1 - lx0) * (ly1 - ly0) * 4 > c.opts.max_layer_bytes {
		for &gm in geoms { gpu_rollback_geom(g, &gm) }
		return
	}
	lbox := [4]i32{i32(lx0), i32(ly0), i32(lx1), i32(ly1)}
	layer := g.next_layer
	g.next_layer += 1
	g.stats.layers += 1
	append(&g.cmds, Gpu_Cmd{kind = .Layer_Begin, id = layer, box = lbox})
	for &gm in geoms {
		b := [4]f64{max(gm.box[0] - 1, f64(lx0)), max(gm.box[1] - 1, f64(ly0)), min(gm.box[2] + 1, f64(lx1)), min(gm.box[3] + 1, f64(ly1))}
		if b[0] >= b[2] || b[1] >= b[3] { gpu_rollback_geom(g, &gm); continue }
		box := [4]f32{f32(math.floor(b[0])), f32(math.floor(b[1])), f32(math.ceil(b[2])), f32(math.ceil(b[3]))}
		inst := gpu_make_inst(g, &gm, paint, 0, d.alpha, false, false, box)
		gpu_add_draw(g, inst, 0, src, 0, lbox)
	}
	append(&g.cmds, Gpu_Cmd{kind = .Layer_End, id = layer})
	cur := layer
	if filtered {
		for op in st.filter {
			switch op.kind {
			case .Blur:
				nl := g.next_layer; g.next_layer += 1
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Fx, fx = .Blur, id = nl, id2 = cur, sigma = f32(op.amount * scale)})
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Free, id = cur})
				cur = nl
			case .Drop_Shadow:
				// the blurred alpha, tinted and moved, under the shape
				bl := g.next_layer; g.next_layer += 1
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Fx, fx = .Blur, id = bl, id2 = cur, sigma = f32(op.amount * scale)})
				nl := g.next_layer; g.next_layer += 1
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Begin, id = nl, box = lbox})
				ox, oy := int(math.round(op.ox * scale)), int(math.round(op.oy * scale))
				gpu_layer_image(g, bl, lbox, {i32(ox), i32(oy)}, premultiply(op.color), true, 0, 0, lbox, 0)
				gpu_layer_image(g, cur, lbox, {}, {}, false, 0, 0, lbox, 0)
				append(&g.cmds, Gpu_Cmd{kind = .Layer_End, id = nl})
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Free, id = bl})
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Free, id = cur})
				cur = nl
			case .Brightness, .Contrast, .Grayscale, .Hue_Rotate, .Invert, .Opacity, .Saturate, .Sepia:
				nl := g.next_layer; g.next_layer += 1
				cm := Gpu_Cmd{kind = .Layer_Fx, fx = .Matrix, id = nl, id2 = cur}
				cm.color_matrix = filter_matrix(op)
				append(&g.cmds, cm)
				append(&g.cmds, Gpu_Cmd{kind = .Layer_Free, id = cur})
				cur = nl
			}
		}
	}
	cbox := [4]i32{i32(d.bx0), i32(d.by0), i32(d.bx1), i32(d.by1)}
	if shadow {
		sg := g.next_layer; g.next_layer += 1
		append(&g.cmds, Gpu_Cmd{kind = .Layer_Fx, fx = .Blur, id = sg, id2 = cur, sigma = f32(max(st.shadow.blur, 0) * 0.5)})
		gpu_layer_image(g, sg, lbox, {i32(sx), i32(sy)}, premultiply(st.shadow.color), true, u8(d.op), d.clip_id, cbox, d.unbounded ? 1 : 0)
		append(&g.cmds, Gpu_Cmd{kind = .Layer_Free, id = sg})
	}
	gpu_layer_image(g, cur, lbox, {}, {}, false, u8(d.op), d.clip_id, cbox, d.unbounded ? 1 : 0)
	append(&g.cmds, Gpu_Cmd{kind = .Layer_Free, id = cur})
	gpu_check_limits(g)
}

// An unbounded operator whose shape is out of reach still acts on the whole clip region (as a transparent source).
@(private)
gpu_composite_nothing :: proc(c: ^Context, d: Draw_State) {
	g := c.gpu
	gm := geom_device_rect(0, 0, 0, 0)
	gm.geom = {0, 0, 0, 0}
	p := gpu_paint_add(g, Gpu_Paint{kind = GP_SOLID})
	inst := gpu_make_inst(g, &gm, p, u8(d.op), 1, true, d.clip_id != 0, {f32(d.bx0), f32(d.by0), f32(d.bx1), f32(d.by1)})
	gpu_add_draw(g, inst, u8(d.op), GPU_SRC_NONE, d.clip_id, {i32(d.bx0), i32(d.by0), i32(d.bx1), i32(d.by1)})
}

// A draw of layer `id` (covering `lbox`) moved by `offset`: tinted by `tint` when `tinted` (a shadow: only its alpha counts),
// with operator `op` through the clip mask, over the region `cbox`; `unbounded` makes the whole region take part.
@(private)
gpu_layer_image :: proc(g: ^Gpu, id: i32, lbox: [4]i32, offset: [2]i32, tint: [4]f32, tinted: bool, op: u8, clip: i32, cbox: [4]i32, unbounded: u32) {
	w, h := f32(lbox[2] - lbox[0]), f32(lbox[3] - lbox[1])
	gp := Gpu_Paint{kind = GP_IMAGE, flags = u32(GP_FILTER_NEAREST) << GP_FILTER_SHIFT, color = tint}
	if tinted { gp.flags |= GPF_TINT }
	gp.m = {1, 0, 0, 1}
	gp.t = {f32(-lbox[0] - offset.x), f32(-lbox[1] - offset.y), 0, 0}
	gp.p = {0, 0, w, h}
	gp.q = {w, h, 0, 0}
	pi := gpu_paint_add(g, gp)
	gm := geom_device_rect(f64(lbox[0] + offset.x), f64(lbox[1] + offset.y), f64(lbox[2] + offset.x), f64(lbox[3] + offset.y))
	box: [4]f32
	if unbounded != 0 {
		box = {f32(cbox[0]), f32(cbox[1]), f32(cbox[2]), f32(cbox[3])}
	} else {
		box = {max(f32(lbox[0] + offset.x), f32(cbox[0])), max(f32(lbox[1] + offset.y), f32(cbox[1])), min(f32(lbox[2] + offset.x), f32(cbox[2])), min(f32(lbox[3] + offset.y), f32(cbox[3]))}
		if box[0] >= box[2] || box[1] >= box[3] { return }
	}
	inst := gpu_make_inst(g, &gm, pi, op, 1, unbounded != 0, clip != 0, box)
	gpu_add_draw(g, inst, op, GPU_SRC_LAYER0 - id, clip, cbox)
}

// Drops the data a geometry put in the heap when it ends up drawing nothing (only the last one can be taken back).
@(private)
gpu_rollback_geom :: proc(g: ^Gpu, gm: ^Gpu_Geom) {}

// The 4x5 color matrix (row-major, on straight r g b a 1) of a color filter function.
@(private)
filter_matrix :: proc(op: Filter_Op) -> (m: [20]f32) {
	v := f32(op.amount)
	set :: proc(m: ^[20]f32, row: int, r, g, b, a, k: f32) { m[row * 5], m[row * 5 + 1], m[row * 5 + 2], m[row * 5 + 3], m[row * 5 + 4] = r, g, b, a, k }
	ident :: proc(m: ^[20]f32) {
		set(m, 0, 1, 0, 0, 0, 0); set(m, 1, 0, 1, 0, 0, 0); set(m, 2, 0, 0, 1, 0, 0); set(m, 3, 0, 0, 0, 1, 0)
	}
	ident(&m)
	#partial switch op.kind {
	case .Brightness:
		set(&m, 0, v, 0, 0, 0, 0); set(&m, 1, 0, v, 0, 0, 0); set(&m, 2, 0, 0, v, 0, 0)
	case .Contrast:
		k := 0.5 - 0.5 * v
		set(&m, 0, v, 0, 0, 0, k); set(&m, 1, 0, v, 0, 0, k); set(&m, 2, 0, 0, v, 0, k)
	case .Invert:
		set(&m, 0, 1 - 2 * v, 0, 0, 0, v); set(&m, 1, 0, 1 - 2 * v, 0, 0, v); set(&m, 2, 0, 0, 1 - 2 * v, 0, v)
	case .Opacity:
		set(&m, 3, 0, 0, 0, v, 0)
	case .Grayscale:
		k := 1 - v
		set(&m, 0, 0.2126 + 0.7874 * k, 0.7152 - 0.7152 * k, 0.0722 - 0.0722 * k, 0, 0)
		set(&m, 1, 0.2126 - 0.2126 * k, 0.7152 + 0.2848 * k, 0.0722 - 0.0722 * k, 0, 0)
		set(&m, 2, 0.2126 - 0.2126 * k, 0.7152 - 0.7152 * k, 0.0722 + 0.9278 * k, 0, 0)
	case .Sepia:
		k := 1 - v
		set(&m, 0, 0.393 + 0.607 * k, 0.769 - 0.769 * k, 0.189 - 0.189 * k, 0, 0)
		set(&m, 1, 0.349 - 0.349 * k, 0.686 + 0.314 * k, 0.168 - 0.168 * k, 0, 0)
		set(&m, 2, 0.272 - 0.272 * k, 0.534 - 0.534 * k, 0.131 + 0.869 * k, 0, 0)
	case .Saturate:
		set(&m, 0, 0.213 + 0.787 * v, 0.715 - 0.715 * v, 0.072 - 0.072 * v, 0, 0)
		set(&m, 1, 0.213 - 0.213 * v, 0.715 + 0.285 * v, 0.072 - 0.072 * v, 0, 0)
		set(&m, 2, 0.213 - 0.213 * v, 0.715 - 0.715 * v, 0.072 + 0.928 * v, 0, 0)
	case .Hue_Rotate:
		ang := op.amount * math.PI / 180
		cs, sn := f32(math.cos(ang)), f32(math.sin(ang))
		set(&m, 0, 0.213 + cs * 0.787 - sn * 0.213, 0.715 - cs * 0.715 - sn * 0.715, 0.072 - cs * 0.072 + sn * 0.928, 0, 0)
		set(&m, 1, 0.213 - cs * 0.213 + sn * 0.143, 0.715 + cs * 0.285 + sn * 0.140, 0.072 - cs * 0.072 - sn * 0.283, 0, 0)
		set(&m, 2, 0.213 - cs * 0.213 - sn * 0.787, 0.715 - cs * 0.715 + sn * 0.715, 0.072 + cs * 0.928 + sn * 0.072, 0, 0)
	}
	return
}

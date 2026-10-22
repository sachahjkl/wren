package browser

import "base:runtime"
import "core:math"
import "toolkit:draw"
import "wb:base"
import "wb:config"
import "wb:host"
import lay "wb:layout"
import "wb:style"

////////////////////////////////
// 3D planes (CSS Transforms 2): offscreen layers projected by the GPU.
//
// A plane group (layout Group_Effect.Plane) draws its box and the content under it in a layer of the toolkit (draw.push_plane)
// in the plane's own frame: the layout coordinates of its space, offsets taken out (`e.origin` is minus the plane's offsets
// while the layer is open, so the drawing code below does not know the difference). When the group closes the layer is
// composited through the 4x4 matrix the view computed (View.accs: plane frame -> what receives it) as a perspective-correct
// quad. What receives it is the page, or the layer of an enclosing plane (flat parents flatten their children).
//
// The members of a preserve-3d context do not land in their parent's layer: they are all projected into the same frame (the
// one the root of the context lands in), so their composites wait (`Effects.pending`) until the root closes, then are drawn
// sorted, with the root's own layer among them (draw.draw_planes: the toolkit orders planes by the sides they lie on, and splits
// planes that cut through each other along their line of intersection, as Chromium's BSP does). A plane whose content did not
// change is kept by the toolkit between frames (cache id and key from the effects cache, `fx_cache_plane`): tilting it again
// only changes the matrix.
//
// How sharp a plane is: its layer is rasterized at the density its projection asks for where it shows (plane_plan: the most
// screen pixels per layout unit over the part of the quad that is on the page, from the Jacobian of the projection), capped by
// a memory budget (the part that shows when the whole does not fit), with mip levels and anisotropic filtering for the
// reduction. While a plane moves it keeps the scale it has; a moment after it stops it is rasterized again at the scale it
// needs (a timer asks for the frame).

PLANE_PREFS := [?]config.Def{
	{name = "paint.planes.max_raster_scale", kind = .Float, default = {f = 16}, bounded = true, min = 1, max = 64,
		description = "Largest number of texels per CSS pixel a 3D-transformed element is rasterized at. A plane that perspective brings nearer than it is drawn is rasterized as dense as the screen shows it (up to this, and within paint.planes.layer_mb) so that it stays sharp; farther or foreshortened ones use less memory."},
	{name = "paint.planes.min_raster_scale", kind = .Float, default = {f = 0.0625}, bounded = true, min = 0.0625, max = 1,
		description = "Smallest number of texels per CSS pixel a plane is rasterized at (a plane far away or seen edge-on is rasterized smaller than 1 to 1)."},
	{name = "paint.planes.anisotropic_taps", kind = .Int, default = {i = 8}, bounded = true, min = 1, max = 16,
		description = "Most texture reads per pixel along the long axis of a plane seen at a slant (anisotropic filtering of the projected layer). 1: plain bilinear."},
	{name = "paint.planes.mipmaps", kind = .Bool, default = {b = true},
		description = "Give the layer of a plane its mip levels (rebuilt when it is rasterized), so that a plane that perspective makes smaller than its layer is filtered instead of aliased. Costs a third more GPU memory per layer."},
	{name = "paint.planes.layer_mb", kind = .Int, default = {i = 96}, bounded = true, min = 4, max = 4096, unit = "MB",
		description = "GPU memory one plane's layer may use. A plane that would need more at the scale its projection asks for is rasterized for the part of it that shows, and then at a lower scale if that is still too much."},
	{name = "paint.planes.motion_tolerance", kind = .Float, default = {f = 2}, bounded = true, min = 1, max = 16,
		description = "While a plane moves (an animation, a drag) its layer keeps the scale it has, so that it is not rasterized again at every frame, until the scale it needs is this many times larger (the plane then looks that much softer). It is rasterized again at the right scale a moment after it stops."},
	{name = "paint.planes.settle_ms", kind = .Float, default = {f = 120}, bounded = true, min = 0, max = 5000, unit = "ms",
		description = "How long after a plane stopped moving it is rasterized again at the scale it needs, when it kept a smaller one while moving."},
}

@(private)
Plane_Settings :: struct {
	max_scale, min_scale: f32,
	taps:                 int,
	mips:                 bool,
	layer_bytes:          int,
	tolerance:            f32,
	settle_ms:            f64,
}

@(private) plane_settings := Plane_Settings{max_scale = 16, min_scale = 0.0625, taps = 8, mips = true, layer_bytes = 96 << 20, tolerance = 2, settle_ms = 120}
@(private) planes_watch: int

register_plane_prefs :: proc(p: ^config.Prefs) { config.register(p, PLANE_PREFS[:]) }

@(private)
plane_settings_from_prefs :: proc(p: ^config.Prefs) -> Plane_Settings {
	return Plane_Settings{
		max_scale = f32(config.float_of(p, "paint.planes.max_raster_scale")),
		min_scale = f32(config.float_of(p, "paint.planes.min_raster_scale")),
		taps = int(config.int_of(p, "paint.planes.anisotropic_taps")),
		mips = config.bool_of(p, "paint.planes.mipmaps"),
		layer_bytes = int(config.int_of(p, "paint.planes.layer_mb")) << 20,
		tolerance = f32(config.float_of(p, "paint.planes.motion_tolerance")),
		settle_ms = config.float_of(p, "paint.planes.settle_ms"),
	}
}

planes_init :: proc(app: ^App) {
	plane_settings = plane_settings_from_prefs(&app.prefs)
	planes_watch = config.watch(&app.prefs, "paint.planes.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		plane_settings = plane_settings_from_prefs(p)
		clear(&plane_mem)
		draw.layer_cache_clear(&(^App)(user).dc)   // kept planes were rasterized at the old scales
	}, app)
}

@(private)
Pending_Plane :: struct {
	item: draw.Plane_Item,   // skip: backface-visibility: hidden and seen from behind
	ctx:  i32,               // the plane space that roots its context
}

// Where layout coordinates (plus the offsets of `space`) land in the target its items are drawn in: the page's origin, or minus
// the offsets of the plane whose layer holds the space.
@(private)
fo :: proc(e: ^Effects, space: i32) -> draw.Vec2 {
	pl := e.l.spaces[space].plane
	if pl == lay.NONE { return e.page_origin }
	return -e.v.offsets[pl]
}

// The origin of the target a plane is projected into.
@(private)
dest_origin :: proc(e: ^Effects, plane_space: i32) -> draw.Vec2 {
	d := e.l.spaces[plane_space].dest
	if d == lay.NONE { return e.page_origin }
	return -e.v.offsets[d]
}

@(private)
to_mat4 :: proc(m: style.Matrix4) -> draw.Mat4 { return draw.Mat4(m) }

// The matrix that draws a plane's layer (plane frame, offsets taken out) into its destination frame.
@(private)
plane_matrix :: proc(e: ^Effects, s: i32) -> style.Matrix4 {
	acc := e.v.accs[s]
	d := dest_origin(e, s)
	return style.m4_mul(style.m4_translate(d.x, d.y, 0), style.m4_mul(acc, style.m4_translate(e.v.offsets[s].x, e.v.offsets[s].y, 0)))
}

// Bounds in the destination frame of a rect of the plane's frame, grown to the whole frame when a corner is behind the viewer.
@(private)
plane_dest_bounds :: proc(e: ^Effects, s: i32, r: lay.Rect, huge: lay.Rect) -> lay.Rect {
	m := plane_matrix(e, s)
	corners := [4]lay.Vec2{r.min, {r.max.x, r.min.y}, r.max, {r.min.x, r.max.y}}
	out: lay.Rect
	for c, i in corners {
		p, _, ok := lay.project4(m, c)
		if !ok { return huge }
		if i == 0 { out = lay.Rect{p, p} } else { out = lay.rect_union(out, lay.Rect{p, p}) }
	}
	return out
}

// Plane frame (offsets taken out) -> the page's draw space, through the planes that receive it.
@(private)
plane_total_matrix :: proc(e: ^Effects, s: i32) -> style.Matrix4 {
	m := plane_matrix(e, s)
	for d := e.l.spaces[s].dest; d != lay.NONE; d = e.l.spaces[d].dest { m = style.m4_mul(plane_matrix(e, d), m) }
	return m
}

// A corner of the polygon where a plane meets the page: its place in the plane's frame and the homogeneous screen position.
@(private)
Plane_Vert :: struct {
	p: lay.Vec2,
	h: [3]f32,   // X, Y, W
}

// The part of `r` (plane frame) that is in front of the eye and inside `screen` once projected by `m`: Sutherland-Hodgman against
// the five half-spaces, on homogeneous positions (affine in the plane's frame, so the cut points interpolate exactly).
@(private)
plane_visible_polygon :: proc(m: style.Matrix4, r: lay.Rect, screen: lay.Rect) -> []Plane_Vert {
	h_of :: proc(m: style.Matrix4, p: lay.Vec2) -> [3]f32 {
		return {m[0] * p.x + m[4] * p.y + m[12], m[1] * p.x + m[5] * p.y + m[13], m[3] * p.x + m[7] * p.y + m[15]}
	}
	Cut :: struct { a, b, c, d: f32 }   // a X + b Y + c W + d >= 0
	cuts := [5]Cut{{0, 0, 1, -1e-4}, {1, 0, -screen.min.x, 0}, {-1, 0, screen.max.x, 0}, {0, 1, -screen.min.y, 0}, {0, -1, screen.max.y, 0}}
	poly := make([dynamic]Plane_Vert, 0, 12, context.temp_allocator)
	for c in ([4]lay.Vec2{r.min, {r.max.x, r.min.y}, r.max, {r.min.x, r.max.y}}) { append(&poly, Plane_Vert{c, h_of(m, c)}) }
	for cut in cuts {
		if len(poly) == 0 { break }
		out := make([dynamic]Plane_Vert, 0, len(poly) + 2, context.temp_allocator)
		for i in 0 ..< len(poly) {
			a, b := poly[i], poly[(i + 1) % len(poly)]
			fa := cut.a * a.h[0] + cut.b * a.h[1] + cut.c * a.h[2] + cut.d
			fb := cut.a * b.h[0] + cut.b * b.h[1] + cut.c * b.h[2] + cut.d
			if fa >= 0 { append(&out, a) }
			if (fa >= 0) != (fb >= 0) {
				t := fa / (fa - fb)
				append(&out, Plane_Vert{a.p + (b.p - a.p) * t, {a.h[0] + (b.h[0] - a.h[0]) * t, a.h[1] + (b.h[1] - a.h[1]) * t, a.h[2] + (b.h[2] - a.h[2]) * t}})
			}
		}
		poly = out
	}
	return poly[:]
}

// Screen pixels per plane-frame unit at the point `v` of the plane through `m`: the larger singular value of the Jacobian of the
// projection there (the most the projection stretches anything at that point).
@(private)
plane_density_at :: proc(m: style.Matrix4, v: Plane_Vert) -> f32 {
	w := v.h[2]
	if !(w > 1e-9) { return 0 }
	sx, sy := v.h[0] / w, v.h[1] / w
	j11, j12 := (m[0] - sx * m[3]) / w, (m[4] - sx * m[7]) / w
	j21, j22 := (m[1] - sy * m[3]) / w, (m[5] - sy * m[7]) / w
	a, b, d := j11 * j11 + j21 * j21, j11 * j12 + j21 * j22, j12 * j12 + j22 * j22
	return math.sqrt(0.5 * (a + d + math.sqrt((a - d) * (a - d) + 4 * b * b)))
}

// Raster scales come in steps of a quarter octave (a plane that animates is not rasterized again for every change).
@(private)
quantize_scale :: proc(x: f32) -> f32 {
	if !(x > 0) { return 1 }
	return math.pow(2, math.ceil(math.log2(x) * 4 - 0.1) / 4)
}

// What a plane's layer was last rasterized at, to keep that while it moves.
@(private)
Plane_Mem :: struct {
	scale: f32,
	mat:   u64,
	ms:    f64,
}

@(private) plane_mem: map[u64]Plane_Mem
@(private) plane_settle: base.Handle

@(private)
matrix_signature :: proc(m: style.Matrix4) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for v in m { h = (h ~ u64(transmute(u32)(math.round(v * 64) / 64))) * 0x100000001B3 }
	return h
}

// Asks for a frame a moment from now (the planes that kept a smaller scale while moving are rasterized right then).
@(private)
plane_arm_settle :: proc() {
	if the_app == nil { return }
	if plane_settle != base.NIL_HANDLE { host.clear_timer(&the_app.loop, plane_settle) }
	plane_settle = host.set_timer(&the_app.loop, plane_settings.settle_ms, 0, proc(data: rawptr) { plane_settle = base.NIL_HANDLE }, nil)
}

@(private)
Plane_Plan :: struct {
	bounds: lay.Rect,   // what the layer holds: the plane's bounds, or the window of them that shows when the whole does not fit
	scale:  f32,        // texels per plane-frame unit
}

// How a plane group's layer is rasterized: its bounds (cut to the part that shows when the layer would be too big) and its
// scale. The scale is the density the projection asks for over the part of the quad on the page, in quarter octaves, within
// the preferences and the layer memory budget. While the plane's matrix is changing the scale it had is kept, unless the one
// it needs is `motion_tolerance` times larger (or much smaller: memory); a timer then brings the sharper frame.
@(private)
plane_plan :: proc(e: ^Effects, g, s: i32, bounds: lay.Rect) -> Plane_Plan {
	st := plane_settings
	m := plane_total_matrix(e, s)
	poly := plane_visible_polygon(m, bounds, e.screen)
	shows := len(poly) > 0
	if !shows { poly = plane_visible_polygon(m, bounds, lay.Rect{{-1e9, -1e9}, {1e9, 1e9}}) }
	density: f32
	window: lay.Rect
	for v, i in poly {
		density = max(density, plane_density_at(m, v))
		window = i == 0 ? lay.Rect{v.p, v.p} : lay.rect_union(window, lay.Rect{v.p, v.p})
	}
	plan := Plane_Plan{bounds = bounds, scale = clamp(f32(1), st.min_scale, st.max_scale)}
	if density <= 0 { return plan }
	want := clamp(quantize_scale(density), st.min_scale, st.max_scale)
	// the memory the layer may use: texels at 8 bytes (fp16), a third more for the mip levels
	max_texels := f32(st.layer_bytes) / (st.mips ? 8 * 4.0 / 3.0 : 8)
	area :: proc(r: lay.Rect) -> f32 { return max(r.max.x - r.min.x, 0) * max(r.max.y - r.min.y, 0) }
	if area(bounds) * want * want > max_texels && shows {
		// too big whole: the part that shows, with a margin, on a grid (it holds still while the plane moves a little)
		grid: f32 = 64
		win := lay.Rect{
			{math.floor((window.min.x - 32) / grid) * grid, math.floor((window.min.y - 32) / grid) * grid},
			{math.ceil((window.max.x + 32) / grid) * grid, math.ceil((window.max.y + 32) / grid) * grid},
		}
		cut := lay.rect_intersect(bounds, win)
		if !lay.rect_empty(cut) { plan.bounds = cut }
	}
	if a := area(plan.bounds); a * want * want > max_texels { want = clamp(math.sqrt(max_texels / a), st.min_scale, want) }
	// motion
	scale := want
	key := u64(uintptr(e.l)) * 0x9E3779B97F4A7C15 + u64(g)
	sig := matrix_signature(m)
	now := pacer.frame_ms
	if plane_mem.allocator.procedure == nil { plane_mem = make(map[u64]Plane_Mem, 64, runtime.default_allocator()) }   // (lives as long as the process)
	mem, known := plane_mem[key]
	stale := false
	if known && now - mem.ms < 2000 && mem.scale > 0 {
		if sig != mem.mat && mem.scale * st.tolerance >= want && mem.scale <= want * 4 {
			scale = mem.scale
			stale = mem.scale < want * 0.98
		}
	}
	if len(plane_mem) > 512 {
		for k, v in plane_mem { if now - v.ms > 5000 { delete_key(&plane_mem, k) } }
	}
	plane_mem[key] = Plane_Mem{scale = scale, mat = sig, ms = now}
	if stale { plane_arm_settle() }
	plan.scale = scale
	return plan
}

// Does a plane group's projection show on the page (its destination frame, after the planes that receive it)? Planes inside
// a plane show wherever their destination does.
@(private)
plane_group_on_screen :: proc(e: ^Effects, g: i32, bounds: lay.Rect, screen: lay.Rect) -> bool {
	s := e.l.groups[g].space
	if s == lay.NONE { return true }
	huge := lay.Rect{{-1e9, -1e9}, {1e9, 1e9}}
	r := plane_dest_bounds(e, s, bounds, huge)
	d := e.l.spaces[s].dest
	for d != lay.NONE {
		r = plane_dest_bounds(e, d, r, huge)
		d = e.l.spaces[d].dest
	}
	return !lay.rect_empty(lay.rect_intersect(r, screen))
}

// A group's bounds seen from the group that receives it (what the enclosing layer must be large enough to hold).
@(private)
group_bounds_in_dest :: proc(e: ^Effects, g: i32, bounds: lay.Rect) -> lay.Rect {
	gr := &e.l.groups[g]
	if .Plane not_in gr.effects || gr.space == lay.NONE { return bounds }
	huge := lay.Rect{{-1e9, -1e9}, {1e9, 1e9}}
	return plane_dest_bounds(e, gr.space, bounds, huge)
}

// Opens the layer of plane group `c` (box `b`, bounds `gp.bounds` in the plane's frame). Returns false when nothing of it can
// show (flattened to nothing, empty): the group then draws nothing.
@(private)
open_plane :: proc(e: ^Effects, c: i32, og: ^Open_Group, bounds: lay.Rect) -> bool {
	l := e.l
	g := &l.groups[c]
	s := g.space
	if s == lay.NONE || e.v.singular[s] || lay.rect_empty(bounds) { return false }
	// a member of a 3D context is not in its parent's layer: a kept result of the parent does not stand for it
	if l.spaces[s].ctx != s && e.fxc != nil {
		og.member, og.saved_skip = true, e.fxc.skip
		e.fxc.skip = 0
	}
	fx := draw.Plane_Fx{}
	if !fx_cache_skipping(e) { fx_cache_plane(e, c, &fx) }
	plan := plane_plan(e, c, s, bounds)
	fx.mips = plane_settings.mips
	og.saved_origin = e.origin
	drawn := draw.push_plane(e.dc, draw.Rect{plan.bounds.min, plan.bounds.max}, plan.scale, fx)
	e.origin = -e.v.offsets[s]
	og.plane = true
	if !drawn {
		og.skip = true
		e.fxc.skip += 1
	}
	return true
}

// Closes a plane group's layer: composited now, or kept for its context's root.
@(private)
close_plane :: proc(e: ^Effects, og: ^Open_Group) {
	l := e.l
	g := &l.groups[og.g]
	s := g.space
	set_xform(e, lay.NONE)   // (the transform of the last item drawn in the layer goes, then the layer's own)
	pl := draw.pop_plane(e.dc)
	e.origin = og.saved_origin
	if og.member { e.fxc.skip = og.saved_skip }
	if pl.img.tex == 0 || pl.direct { return }
	sp := &l.spaces[s]
	acc := e.v.accs[s]
	m := plane_matrix(e, s)
	alpha := plane_alpha(l, g)
	cull := sp.back_hidden && style.m4_back_facing(acc)
	o := draw.Plane_Draw{max_taps = plane_settings.taps, blend = og.blend, backdrop = og.backdrop}
	if len(og.backdrop) > 0 && !cull { o.shape = plane_shape(e, og.g, pl) }
	item := draw.plane_item(pl, to_mat4(m), alpha, o, cull)
	if sp.ctx != s {
		// a member of a 3D context: drawn with its whole context, sorted
		append(&e.pending, Pending_Plane{item = item, ctx = sp.ctx})
		return
	}
	if sp.preserve {
		// the root of a context: its members, and itself, sorted
		flush_context(e, item, s)
		return
	}
	if cull { draw.discard_plane(e.dc, pl); return }
	draw.draw_plane(e.dc, pl, to_mat4(m), alpha, o)
}

// The opacity a plane is composited with: its group's, unless the group also has a layer of its own for it.
@(private)
plane_alpha :: proc(l: ^Layout, g: ^lay.Group) -> f32 { return g.alpha }

// What a plane's backdrop-filter shows through: the shape of its border box (rounded corners, clip-path, mask) as the alpha of
// a layer in the plane's frame. (The plane's own content may spill out of the box, or be transparent: the backdrop follows the
// box, not the paint.)
@(private)
plane_shape :: proc(e: ^Effects, c: i32, pl: draw.Plane_Layer) -> draw.Plane_Layer {
	l := e.l
	g := &l.groups[c]
	b := &l.boxes[g.box]
	cs := b.cs
	saved := e.origin
	e.origin = -e.v.offsets[g.space]
	defer e.origin = saved
	off := e.v.offsets[b.space] + e.origin
	r := draw.rect_shift(draw.Rect{b.abs, b.abs + b.size}, off)
	bounds := draw.Rect{r.min - 1, r.max + 1}
	draw.push_plane(e.dc, bounds, pl.scale)
	box_xf := l.spaces[b.space].xform
	clipped := .Clip_Path in g.effects && effects_settings.clip_paths && push_clip_path(e, g, box_xf, off)
	masked := .Mask in g.effects && effects_settings.masks
	if masked { draw.push_mask(e.dc, bounds, draw.Layer_Effects{alpha = 1}) }
	set_xform(e, box_xf)
	circular := draw.set_circular_corners(e.dc, true)
	white := draw.Color{1, 1, 1, 1}
	draw.rect_corners(e.dc, r, {white, white, white, white}, lay.border_radii(cs, b.size.x, b.size.y, l.scale))
	draw.set_circular_corners(e.dc, circular)
	if masked {
		paint_mask_layers(e, b, off)
		set_xform(e, lay.NONE)
		draw.pop_mask(e.dc)
	}
	set_xform(e, lay.NONE)
	if clipped { draw.pop_clip(e.dc) }
	return draw.pop_plane(e.dc)
}

// Draws the members of the context rooted at `root` (waiting in e.pending) and the root's own layer: the toolkit sorts them, and
// splits those that cut through each other (a BSP, as Chromium does).
@(private)
flush_context :: proc(e: ^Effects, own: draw.Plane_Item, root: i32) {
	list := make([dynamic]draw.Plane_Item, 0, 8, context.temp_allocator)
	keep := 0
	for p in e.pending {
		if p.ctx == root { append(&list, p.item) } else { e.pending[keep] = p; keep += 1 }
	}
	resize(&e.pending, keep)
	append(&list, own)
	draw.draw_planes(e.dc, list[:])
}
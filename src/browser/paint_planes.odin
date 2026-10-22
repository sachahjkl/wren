package browser

import "core:math"
import "toolkit:draw"
import "wb:config"
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
// sorted by depth, far to near, with the root's own layer among them. A plane whose content did not change is kept by the
// toolkit between frames (cache id and key from the effects cache, `fx_cache_plane`): tilting it again only changes the
// matrix. Sorting is by the depth of the middle of each plane; planes that cut through each other are not split (a BSP split
// as Chromium does would be the exact answer): they are drawn in the order of their middles.

PLANE_PREFS := [?]config.Def{
	{name = "paint.planes.max_raster_scale", kind = .Float, default = {f = 3}, bounded = true, min = 1, max = 8,
		description = "Largest number of texels per CSS pixel a 3D-transformed element is rasterized at. A plane that perspective brings nearer than it is drawn is rasterized denser (up to this) so that it stays sharp; farther or foreshortened ones use less memory."},
	{name = "paint.planes.min_raster_scale", kind = .Float, default = {f = 0.5}, bounded = true, min = 0.0625, max = 1, 
		description = "Smallest number of texels per CSS pixel a plane is rasterized at (a plane far away or seen edge-on is rasterized smaller than 1 to 1)."},
	{name = "paint.planes.anisotropic_taps", kind = .Int, default = {i = 8}, bounded = true, min = 1, max = 16,
		description = "Most texture reads per pixel along the long axis of a plane seen at a slant (anisotropic filtering of the projected layer). 1: plain bilinear."},
}

@(private)
Plane_Settings :: struct {
	max_scale, min_scale: f32,
	taps:                 int,
}

@(private) plane_settings := Plane_Settings{max_scale = 3, min_scale = 0.5, taps = 8}
@(private) planes_watch: int

register_plane_prefs :: proc(p: ^config.Prefs) { config.register(p, PLANE_PREFS[:]) }

@(private)
plane_settings_from_prefs :: proc(p: ^config.Prefs) -> Plane_Settings {
	return Plane_Settings{
		max_scale = f32(config.float_of(p, "paint.planes.max_raster_scale")),
		min_scale = f32(config.float_of(p, "paint.planes.min_raster_scale")),
		taps = int(config.int_of(p, "paint.planes.anisotropic_taps")),
	}
}

planes_init :: proc(app: ^App) {
	plane_settings = plane_settings_from_prefs(&app.prefs)
	planes_watch = config.watch(&app.prefs, "paint.planes.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		plane_settings = plane_settings_from_prefs(p)
		draw.layer_cache_clear(&(^App)(user).dc)   // kept planes were rasterized at the old scales
	}, app)
}

@(private)
Pending_Plane :: struct {
	pl:    draw.Plane_Layer,
	m:     draw.Mat4,
	alpha: f32,
	z:     f32,           // depth of the middle of the plane (larger: nearer)
	ctx:   i32,           // the plane space that roots its context
	cull:  bool,          // backface-visibility: hidden and seen from behind
	seq:   int,
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

// How many texels per layout unit to rasterize a plane at: the largest stretch its projection gives an edge, in steps (a
// plane that animates does not rasterize again at every frame), within the preferences.
@(private)
raster_scale_of :: proc(e: ^Effects, s: i32, r: lay.Rect) -> f32 {
	m := plane_matrix(e, s)
	corners := [4]lay.Vec2{r.min, {r.max.x, r.min.y}, r.max, {r.min.x, r.max.y}}
	proj: [4]lay.Vec2
	for c, i in corners {
		p, _, ok := lay.project4(m, c)
		if !ok { return plane_settings.max_scale }
		proj[i] = p
	}
	stretch: f32
	for i in 0 ..< 4 {
		j := (i + 1) % 4
		dl := corners[j] - corners[i]
		dp := proj[j] - proj[i]
		ll := math.sqrt(dl.x * dl.x + dl.y * dl.y)
		if ll < 1e-3 { continue }
		stretch = max(stretch, math.sqrt(dp.x * dp.x + dp.y * dp.y) / ll)
	}
	// the page's device scale is already in layout units; the matrix may scale on top (a zoom, a scale())
	steps := [?]f32{0.0625, 0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8}
	want := stretch
	for st in steps { if st >= want * 0.98 { want = st; break } }
	return clamp(want, plane_settings.min_scale, plane_settings.max_scale)
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
	scale := raster_scale_of(e, s, bounds)
	og.saved_origin = e.origin
	drawn := draw.push_plane(e.dc, draw.Rect{bounds.min, bounds.max}, scale, fx)
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
	if sp.ctx != s {
		// a member of a 3D context: drawn with its whole context, sorted
		cx := (pl.origin.x + f32(pl.size.x) / pl.scale * 0.5)
		cy := (pl.origin.y + f32(pl.size.y) / pl.scale * 0.5)
		z := style.m4_apply(m, cx, cy, 0)[2]
		append(&e.pending, Pending_Plane{pl = pl, m = to_mat4(m), alpha = alpha, z = z, ctx = sp.ctx, cull = cull, seq = len(e.pending)})
		return
	}
	if sp.preserve {
		// the root of a context: its members, and itself, sorted by depth
		cx := (pl.origin.x + f32(pl.size.x) / pl.scale * 0.5)
		cy := (pl.origin.y + f32(pl.size.y) / pl.scale * 0.5)
		z := style.m4_apply(m, cx, cy, 0)[2]
		flush_context(e, Pending_Plane{pl = pl, m = to_mat4(m), alpha = alpha, z = z, ctx = s, cull = cull, seq = len(e.pending)}, s)
		return
	}
	if cull { draw.discard_plane(e.dc, pl); return }
	draw.draw_plane(e.dc, pl, to_mat4(m), alpha, draw.Plane_Draw{max_taps = plane_settings.taps})
}

// The opacity a plane is composited with: its group's, unless the group also has a layer of its own for it.
@(private)
plane_alpha :: proc(l: ^Layout, g: ^lay.Group) -> f32 { return g.alpha }

// Draws the members of the context rooted at `root` (waiting in e.pending) and the root's own layer, far to near.
@(private)
flush_context :: proc(e: ^Effects, own: Pending_Plane, root: i32) {
	list := make([dynamic]Pending_Plane, 0, 8, context.temp_allocator)
	keep := 0
	for p in e.pending {
		if p.ctx == root { append(&list, p) } else { e.pending[keep] = p; keep += 1 }
	}
	resize(&e.pending, keep)
	append(&list, own)
	// far to near; equal depths in paint order (stable)
	for i in 1 ..< len(list) {
		x := list[i]
		j := i
		for j > 0 && (list[j - 1].z > x.z || (list[j - 1].z == x.z && list[j - 1].seq > x.seq)) {
			list[j] = list[j - 1]
			j -= 1
		}
		list[j] = x
	}
	for p in list {
		if p.cull { draw.discard_plane(e.dc, p.pl); continue }
		draw.draw_plane(e.dc, p.pl, p.m, p.alpha, draw.Plane_Draw{max_taps = plane_settings.taps})
	}
}

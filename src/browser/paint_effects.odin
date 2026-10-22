package browser

import "core:math"
import "toolkit:draw"
import "toolkit:render"
import "wb:config"
import lay "wb:layout"
import "wb:style"

////////////////////////////////
// Effects an item is drawn under: the transform of its space, the clips around it (each one pushed under the transform
// of its own space, so a clip inside a rotated box rotates with it and keeps its rounded corners), and its effect
// groups: opacity, filter, backdrop-filter, mix-blend-mode, isolation, clip-path. Consecutive items mostly share them;
// only what differs from the previous item is popped and pushed.
//
// A group opens, in this order (CSS Filter Effects 1 §5, Masking 1 §5, Compositing 1): the clips around its box; its
// clip-path (it cuts the group's final result, so it is pushed outside the layer); the capture of its backdrop (what
// the enclosing layer or the frame holds under its border box, filtered); the layer that receives its content, composited
// through its filters, opacity and blend mode when the group closes; the filtered backdrop, drawn first inside. Inside a
// layer the toolkit restarts the clip stack, so the clips pushed before it (`Open_Group.floor`) are never popped by the
// items of the group: they apply to the composite.

@(private)
Effects_Settings :: struct {
	filters:          bool,
	backdrop_filters: bool,
	blend_modes:      bool,
	clip_paths:       bool,
	masks:            bool,
	exact_shadows:    bool,
	blur_sigma_limit: f32,
}

EFFECTS_PREFS := [?]config.Def{
	{name = "paint.effects.filters", kind = .Bool, default = {b = true},
		description = "Draw CSS filter (blur, brightness, contrast, grayscale, hue-rotate, invert, opacity, saturate, sepia, drop-shadow). Off: filtered elements are drawn unfiltered (cheaper)."},
	{name = "paint.effects.backdrop_filters", kind = .Bool, default = {b = true},
		description = "Draw CSS backdrop-filter: what lies behind an element, filtered, under its background. Off: the backdrop is left as it is."},
	{name = "paint.effects.blend_modes", kind = .Bool, default = {b = true},
		description = "Composite elements with their CSS mix-blend-mode (multiply, screen, overlay, difference, hue...). Off: every element is drawn normally over what is behind it."},
	{name = "paint.effects.clip_paths", kind = .Bool, default = {b = true},
		description = "Clip elements to their CSS clip-path shape (inset, circle, ellipse, polygon, reference box). Off: clip-path is ignored when painting (hit testing still follows it)."},
	{name = "paint.effects.masks", kind = .Bool, default = {b = true},
		description = "Draw CSS masks (mask-image and the other mask-* properties, -webkit-mask-*): an element is shown through the alpha or the luminance of its mask images and gradients (one offscreen layer per masked element). Off: masked elements are drawn unmasked (an icon drawn as a mask over a colored box shows as the box)."},
	{name = "paint.effects.exact_shadows", kind = .Bool, default = {b = true},
		description = "Blur text shadows with a true gaussian (one offscreen layer each). Off: a faded copy of the text (cheaper). Box shadows, outer and inset, are always exact (computed analytically by the shader)."},
	{name = "paint.effects.blur_full_resolution_px", kind = .Float, default = {f = 8}, bounded = true, min = 2, max = 40, unit = "px",
		description = "Standard deviation of a blur (filter, backdrop-filter, drop-shadow) above which it is computed on an image reduced by 2, 4, 8...: the cost per pixel stays bounded whatever the radius. Lower is faster and slightly softer."},
}

@(private) effects_settings: Effects_Settings
@(private) effects_watch: int

register_effects_prefs :: proc(p: ^config.Prefs) {
	config.register(p, EFFECTS_PREFS[:])
	register_fx_cache_prefs(p)
	register_plane_prefs(p)
}

@(private)
effects_settings_from_prefs :: proc(p: ^config.Prefs) -> Effects_Settings {
	return Effects_Settings{
		filters = config.bool_of(p, "paint.effects.filters"),
		backdrop_filters = config.bool_of(p, "paint.effects.backdrop_filters"),
		blend_modes = config.bool_of(p, "paint.effects.blend_modes"),
		clip_paths = config.bool_of(p, "paint.effects.clip_paths"),
		masks = config.bool_of(p, "paint.effects.masks"),
		exact_shadows = config.bool_of(p, "paint.effects.exact_shadows"),
		blur_sigma_limit = f32(config.float_of(p, "paint.effects.blur_full_resolution_px")),
	}
}

// Shell start-up: the effect preferences, applied to the renderer and followed.
effects_init :: proc(app: ^App) {
	effects_settings = effects_settings_from_prefs(&app.prefs)
	render.set_blur_sigma_limit(&app.r, effects_settings.blur_sigma_limit)
	fx_settings = fx_settings_from_prefs(&app.prefs)
	fx_settings_apply(app)
	planes_init(app)
	effects_watch = config.watch(&app.prefs, "paint.effects.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		a := (^App)(user)
		effects_settings = effects_settings_from_prefs(p)
		render.set_blur_sigma_limit(&a.r, effects_settings.blur_sigma_limit)
		fx_settings = fx_settings_from_prefs(p)
		fx_settings_apply(a)
	}, app)
	// kept text shadows were rasterized with the text settings of their time
	effects_font_watch = config.watch(&app.prefs, "font.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		draw.layer_cache_clear(&(^App)(user).dc)
	}, app)
}

@(private) effects_font_watch: int

@(private)
Effects :: struct {
	l:        ^Layout,
	v:        ^lay.View,
	dc:       ^draw.Context,
	origin:   draw.Vec2,              // where layout coordinates (plus offsets) land in the target being drawn: the page's origin,
	                                  // or minus the offsets of the plane whose layer is open (fo)
	page_origin: draw.Vec2,
	screen:   lay.Rect,               // the page area in the draw space (planes are rasterized for what shows of them)
	pending:  [dynamic]Pending_Plane, // planes of 3D contexts, waiting for their root to close (sorted by depth then)
	hide:     int,                    // open plane groups that show nothing (edge-on, empty): their content is not drawn
	xform:    i32,              // Transform space whose matrix is pushed (lay.NONE: none)
	clip:     i32,              // innermost clip of `chain` (-2: not set yet)
	chain:    [dynamic]i32,     // clips pushed, outermost first
	group:    i32,              // innermost group of `open` (-2: not set yet)
	open:     [dynamic]Open_Group,
	groups:   []Group_Paint,    // per group, for this frame
	fxc:      ^Fx_Cache,        // kept effect results (compositor only; effects_cache.odin)
}

@(private)
Open_Group :: struct {
	g:     i32,
	floor: int,      // clips of `chain` pushed before the group opened: its items never pop them
	layer: bool,     // a layer was pushed (else maybe an alpha)
	alpha: bool,
	shape: bool,     // a clip-path shape was pushed
	mask:  bool,     // the layer is masked: its mask layers are drawn when it closes
	member: bool,    // a plane in its parent's 3D context: a skip of the parent is put aside while it is open
	saved_skip: int,
	skip:  bool,     // its kept result is composited: its content (and its mask layers) are not drawn
	hidden: bool,    // a plane that shows nothing: no layer, its content is not drawn
	plane: bool,     // a plane layer was pushed (plane.odin of the toolkit): composited projected when the group closes
	saved_origin: draw.Vec2,   // e.origin outside the plane
	blend:    draw.Blend_Mode,   // plane: its mix-blend-mode, applied to the projected quad
	backdrop: []draw.Filter,     // plane: its backdrop-filter, applied to what lies under the projected quad
}

@(private)
effects_make :: proc(l: ^Layout, v: ^lay.View, dc: ^draw.Context, origin, size: draw.Vec2) -> Effects {
	e := Effects{l = l, v = v, dc = dc, origin = origin, page_origin = origin, screen = lay.Rect{origin, origin + size}, xform = lay.NONE, clip = -2, group = -2,
		chain = make([dynamic]i32, 0, 8, context.temp_allocator), open = make([dynamic]Open_Group, 0, 4, context.temp_allocator),
		pending = make([dynamic]Pending_Plane, 0, 4, context.temp_allocator)}
	e.groups = plan_groups(&e)
	return e
}

// The matrix of a Transform space as draw wants it: page coordinates are drawn offset by the page area's origin.
@(private)
space_affine :: proc(e: ^Effects, s: i32) -> draw.Affine {
	m := lay.mat_shifted(e.v.mats[s], e.origin)
	return draw.Affine{m[0], m[1], m[2], m[3], m[4], m[5]}
}

@(private)
set_xform :: proc(e: ^Effects, xf: i32) {
	if xf == e.xform { return }
	if e.xform != lay.NONE { draw.pop_transform(e.dc) }
	e.xform = xf
	if xf != lay.NONE { draw.push_transform(e.dc, space_affine(e, xf)) }
}

@(private)
clip_floor :: proc(e: ^Effects) -> int { return len(e.open) > 0 ? e.open[len(e.open) - 1].floor : 0 }

@(private)
pop_chain_to :: proc(e: ^Effects, n: int) {
	for len(e.chain) > n { draw.pop_clip(e.dc); pop(&e.chain) }
	e.clip = len(e.chain) > 0 ? e.chain[len(e.chain) - 1] : lay.NONE
}

@(private)
set_clip :: proc(e: ^Effects, ci: i32) {
	if ci == e.clip { return }
	want := make([dynamic]i32, 0, 8, context.temp_allocator)
	for c := ci; c != lay.NONE; c = e.l.clips[c].parent { append(&want, c) }
	for i, j := 0, len(want) - 1; i < j; i, j = i + 1, j - 1 { want[i], want[j] = want[j], want[i] }
	floor := clip_floor(e)
	keep := 0
	for keep < len(want) && keep < len(e.chain) && want[keep] == e.chain[keep] { keep += 1 }
	from := keep
	if keep < floor {
		// the clips under the open group are not this item's (a box positioned against an ancestor outside the
		// group): its whole chain goes on top of them
		k := 0
		for k < len(want) && floor + k < len(e.chain) && want[k] == e.chain[floor + k] { k += 1 }
		keep, from = floor + k, k
	}
	pop_chain_to(e, keep)
	for c in want[from:] {
		cl := &e.l.clips[c]
		set_xform(e, e.l.spaces[cl.space].xform)
		r := draw.rect_shift(to_rect(cl.rect), e.v.offsets[cl.space] + e.origin)
		if cl.radii == {} { draw.push_clip(e.dc, r) } else { draw.push_clip_rounded(e.dc, r, cl.radii) }
		append(&e.chain, c)
	}
	e.clip = ci
}

// Puts the draw context in the state `it` is drawn in. false: nothing of it can show (empty clip, flattened space).
@(private)
effects_for :: proc(e: ^Effects, it: ^lay.Display_Item) -> bool {
	if it.clip >= 0 && lay.rect_empty(e.v.clips[it.clip]) { return false }
	xf := e.l.spaces[it.space].xform
	if xf != lay.NONE && e.v.singular[it.space] { return false }
	if it.group != e.group { set_group(e, it.group) }
	if e.hide > 0 { return false }
	set_clip(e, it.clip)
	set_xform(e, xf)
	ctl_plane_for(e, it)
	return true
}

@(private)
effects_end :: proc(e: ^Effects) {
	set_group(e, lay.NONE)
	pop_chain_to(e, 0)
	set_xform(e, lay.NONE)
}

@(private)
Group_Paint :: struct {
	bounds: lay.Rect,   // screen pixels: what its visible items may touch (not cut by clips: a layer cuts it)
	units:  int,        // things that may overlap inside: primitives, nested groups
	seen:   bool,
}

// Screen bounds of what an item may paint: its rect with what spills out of it (shadows, outlines, glyph overhang).
// `clipped`: cut to the bounds of its clip.
@(private)
item_ink :: proc(e: ^Effects, it: ^lay.Display_Item, clipped := true) -> lay.Rect {
	o := fo(e, it.space)
	r := lay.rect_shift(item_ink_local(e.l, it), e.v.offsets[it.space] + o)
	if !lay.space_plain(e.l, it.space) { r = lay.mat_bounds(lay.mat_shifted(e.v.mats[it.space], o), r) }
	if clipped && it.clip >= 0 && e.l.spaces[e.l.clips[it.clip].space].plane == e.l.spaces[it.space].plane { r = lay.rect_intersect(r, lay.rect_shift(e.v.clips[it.clip], o)) }
	return r
}

// What an item may paint, in the layout coordinates of its space: its rect with what spills out of it.
@(private)
item_ink_local :: proc(l: ^Layout, it: ^lay.Display_Item) -> lay.Rect {
	s := l.scale
	pad: f32 = 1
	if cs := it.cs; cs != nil {
		#partial switch it.kind {
		case .Box, .Inline_Box:
			// a gaussian of half the blur radius reaches 1.5 blur radii; the shadow is drawn up to 3 standard deviations
			for sh in cs.box_shadow { if !sh.inset { pad = max(pad, (max(abs(sh.x), abs(sh.y)) + sh.blur * 1.5 + max(sh.spread, 0)) * s + 2) } }
		case .Outline:
			pad = max(pad, (cs.outline_width + max(cs.outline_offset, 0)) * s + 2)
		case .Text, .Marker:
			pad = max(pad, 4 * s)
			for sh in cs.text_shadow { pad = max(pad, (max(abs(sh.x), abs(sh.y)) + sh.blur) * s + 4 * s) }
		}
	}
	return lay.Rect{it.rect.min - pad, it.rect.max + pad}
}

// How many primitives an item draws that could overlap each other.
@(private)
item_units :: proc(it: ^lay.Display_Item) -> int {
	cs := it.cs
	if cs == nil { return 1 }
	#partial switch it.kind {
	case .Box, .Inline_Box:
		n := 1
		if len(cs.box_shadow) > 0 { n += 1 }
		for s in style.Side { if cs.border_width[s] > 0 { n += 1; break } }
		return n
	case .Text: return len(cs.text_shadow) > 0 || it.deco != {} ? 2 : 1
	case .Control, .Replaced: return 2
	}
	return 1
}

// Screen outset of a group's filters (left, top, right, bottom), through the transform of its box's space.
@(private)
group_outset :: proc(e: ^Effects, g: i32) -> [4]f32 {
	gr := &e.l.groups[g]
	if .Filter not_in gr.effects || !effects_settings.filters { return {} }
	o := lay.filter_outset(e.l.boxes[gr.box].cs.filter, e.l.scale)
	sp := e.l.boxes[gr.box].space
	if lay.space_plain(e.l, sp) { return o }
	m := e.v.mats[sp]
	k := math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))
	big := max(o[0], o[1], o[2], o[3]) * k
	return {big, big, big, big}
}

@(private)
plan_groups :: proc(e: ^Effects) -> []Group_Paint {
	gp := make([]Group_Paint, len(e.l.groups), context.temp_allocator)
	if len(gp) == 0 { return gp }
	for idx in e.v.visible {
		it := &e.l.items[idx]
		if it.group < 0 { continue }
		ink := item_ink(e, it, false)
		p := &gp[it.group]
		p.bounds = p.seen ? lay.rect_union(p.bounds, ink) : ink
		p.seen = true
		p.units += item_units(it)
	}
	// children (later in the list) into their parents, with what their filters spread
	for g := len(gp) - 1; g >= 0; g -= 1 {
		parent := e.l.groups[g].dest
		if parent == lay.NONE || !gp[g].seen { continue }
		o := group_outset(e, i32(g))
		b := lay.Rect{gp[g].bounds.min - {o[0], o[1]}, gp[g].bounds.max + {o[2], o[3]}}
		b = group_bounds_in_dest(e, i32(g), b)
		p := &gp[parent]
		p.bounds = p.seen ? lay.rect_union(p.bounds, b) : b
		p.seen = true
		p.units += 1
	}
	return gp
}

// CSS filter functions as draw filters (lengths in device px of the box's space). url() filters need SVG: skipped.
@(private)
css_filters :: proc(ops: []style.Filter_Op, scale: f32) -> []draw.Filter {
	out := make([dynamic]draw.Filter, 0, len(ops), context.temp_allocator)
	for f in ops {
		switch f.kind {
		case .Blur: append(&out, draw.filter_blur(f.v * scale))
		case .Brightness: append(&out, draw.filter_brightness(f.v))
		case .Contrast: append(&out, draw.filter_contrast(f.v))
		case .Grayscale: append(&out, draw.filter_grayscale(f.v))
		case .Hue_Rotate: append(&out, draw.filter_hue_rotate(f.v))
		case .Invert: append(&out, draw.filter_invert(f.v))
		case .Opacity: append(&out, draw.filter_opacity(f.v))
		case .Saturate: append(&out, draw.filter_saturate(f.v))
		case .Sepia: append(&out, draw.filter_sepia(f.v))
		case .Drop_Shadow:
			sh := f.shadow
			append(&out, draw.filter_drop_shadow(draw.Vec2{sh.x, sh.y} * scale, sh.blur * 0.5 * scale, to_draw(sh.color)))
		case .Url:
		}
	}
	return out[:]
}

@(private)
any_active :: proc(fs: []draw.Filter) -> bool {
	for f in fs { if !draw.filter_is_identity(f) { return true } }
	return false
}

// Pushes the clip-path of group `g`'s box (drawn under `off` and the transform space `box_xf`); false: it has none.
@(private)
push_clip_path :: proc(e: ^Effects, g: ^lay.Group, box_xf: i32, off: draw.Vec2) -> bool {
	sh := lay.clip_path_shape(e.l, g.box)
	if sh.kind == .None { return false }
	set_xform(e, box_xf)
	switch sh.kind {
	case .None:
	case .Rect: draw.push_clip_rounded(e.dc, draw.rect_shift(to_rect(sh.rect), off), sh.radii)
	case .Ellipse: draw.push_clip_ellipse(e.dc, sh.center + off, sh.radius)
	case .Polygon:
		pts := make([]draw.Vec2, len(sh.points), context.temp_allocator)
		for p, i in sh.points { pts[i] = p + off }
		draw.push_clip_polygon(e.dc, pts, sh.evenodd)
	}
	return true
}

@(private)
open_group :: proc(e: ^Effects, c: i32) {
	l := e.l
	g := &l.groups[c]
	b := &l.boxes[g.box]
	cs := b.cs
	gp := &e.groups[c]
	og := Open_Group{g = c}
	// the clips around the group's box: they cut its composite
	set_clip(e, b.clip)
	og.floor = len(e.chain)
	plane := .Plane in g.effects
	if plane {
		set_xform(e, lay.NONE)
		if !open_plane(e, c, &og, gp.bounds) {
			og.hidden = true
			e.hide += 1
			append(&e.open, og)
			return
		}
	}
	space := b.space
	off := e.v.offsets[space] + e.origin
	box_xf := l.spaces[space].xform
	if .Clip_Path in g.effects && effects_settings.clip_paths {
		og.shape = push_clip_path(e, g, box_xf, off)
	}
	bd: draw.Backdrop
	bd_rect: draw.Rect
	bd_radii: [4]f32
	has_bd := false
	if .Backdrop in g.effects && effects_settings.backdrop_filters && b.kind != .Inline {
		bfs := css_filters(cs.backdrop_filter, l.scale)
		if plane {
			// a plane's backdrop is what lies under its projection: read when it is composited (close_plane)
			if any_active(bfs) { og.backdrop = bfs }
		} else if any_active(bfs) {
			bd_rect = draw.rect_shift(draw.Rect{b.abs, b.abs + b.size}, off)
			bd_radii = lay.border_radii(cs, b.size.x, b.size.y, l.scale)
			set_xform(e, box_xf)
			id, key, anchor := fx_cache_backdrop(e, c)
			bd = draw.backdrop_capture(e.dc, bd_rect, bfs, id, key, anchor)
			has_bd = true
		}
	}
	// what this group draws lies under the backdrops still to come
	fx_cache_under(e, nil, group = c)
	filters: []draw.Filter
	if .Filter in g.effects && effects_settings.filters {
		filters = css_filters(cs.filter, l.scale)
		if !any_active(filters) { filters = nil }
	}
	blend := draw.Blend_Mode.Normal
	if .Blend in g.effects && effects_settings.blend_modes {
		// (a plane blends as a projected quad against what it lands on, not inside its own layer)
		if plane { og.blend = draw.Blend_Mode(cs.mix_blend_mode) } else { blend = draw.Blend_Mode(cs.mix_blend_mode) }
	}
	alpha := plane ? f32(1) : g.alpha   // a plane is faded when it is composited
	isolate := .Isolate in g.effects && effects_settings.blend_modes
	masked := .Mask in g.effects && effects_settings.masks
	layer := (filters != nil || blend != .Normal || isolate || masked || (alpha < 1 && page_render.settings.opacity_layers && gp.units > 1)) && gp.seen && !lay.rect_empty(gp.bounds)
	set_xform(e, lay.NONE)
	if layer {
		// a masked group is kept with its mask in the result: its key covers the mask (effects_cache.odin)
		fx := draw.Layer_Effects{alpha = alpha, filters = filters, blend = blend}
		if !fx_cache_skipping(e) { fx_cache_layer(e, c, &fx) }
		drawn := masked ? draw.push_mask(e.dc, draw.Rect{gp.bounds.min, gp.bounds.max}, fx) : draw.push_effects(e.dc, draw.Rect{gp.bounds.min, gp.bounds.max}, fx)
		if !drawn {
			og.skip = true
			e.fxc.skip += 1
		}
		og.mask = masked
		og.layer = true
	} else if alpha < 1 {
		draw.push_alpha(e.dc, alpha)
		og.alpha = true
	}
	if has_bd {
		set_xform(e, box_xf)
		draw.backdrop_draw(e.dc, bd, bd_rect, bd_radii)
	}
	append(&e.open, og)
}

@(private)
close_group :: proc(e: ^Effects) {
	og := pop(&e.open)
	if og.hidden { e.hide -= 1; pop_chain_to(e, og.floor); return }
	if og.skip { e.fxc.skip -= 1 }
	pop_chain_to(e, og.floor)
	if og.mask && !og.skip && !fx_cache_skipping(e) {
		b := &e.l.boxes[e.l.groups[og.g].box]
		set_xform(e, e.l.spaces[b.space].xform)
		paint_mask_layers(e, b, e.v.offsets[b.space] + e.origin)
		set_xform(e, lay.NONE)
	}
	if og.layer { draw.pop_layer(e.dc) } else if og.alpha { draw.pop_alpha(e.dc) }
	if og.shape { draw.pop_clip(e.dc) }
	if og.plane { close_plane(e, &og) }
}

#assert(len(draw.Blend_Mode) == len(style.Blend_Mode))

@(private = "file")
to_rect :: #force_inline proc(r: lay.Rect) -> draw.Rect { return draw.Rect{r.min, r.max} }

@(private)
set_group :: proc(e: ^Effects, g: i32) {
	if g == e.group { return }
	// the chain of groups `g` is in, outermost first
	want := make([dynamic]i32, 0, 8, context.temp_allocator)
	for c := g; c != lay.NONE; c = e.l.groups[c].parent { append(&want, c) }
	for i, j := 0, len(want) - 1; i < j; i, j = i + 1, j - 1 { want[i], want[j] = want[j], want[i] }
	keep := 0
	for keep < len(want) && keep < len(e.open) && want[keep] == e.open[keep].g { keep += 1 }
	for len(e.open) > keep { close_group(e) }
	for c in want[keep:] { open_group(e, c) }
	e.group = g
}

////////////////////////////////
// Radii

// Radii of the padding edge from those of the border edge (CSS Backgrounds §5.3), draw corner order.
@(private)
padding_radii :: proc(outer: [4]f32, border: [4]f32) -> [4]f32 {
	// border: top right bottom left
	bt, br, bb, bl := border[0], border[1], border[2], border[3]
	return {max(outer[0] - min(bl, bt), 0), max(outer[1] - min(bl, bb), 0), max(outer[2] - min(br, bt), 0), max(outer[3] - min(br, bb), 0)}
}

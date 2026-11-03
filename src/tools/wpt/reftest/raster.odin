package reftest

import "core:math"
import css_ "wb:css"
import lay "wb:layout"
import "wb:style"

// The software rasteriser of reference tests: draws a layout's display list (lay.view_make: its order, spaces, clips,
// groups) into RGBA pixels, with what src/browser/render.odin draws with the GPU, deterministically and without fonts.
// Every pixel is sampled at its centre, mapped back through the transforms of the item's space (lay.view_to_local, so
// that planes project too) and tested against the clips (lay.clip_contains: rounded and transformed ones): no
// antialiasing. Edges of boxes, as in other browsers, are snapped to whole pixels before transforms. Colours mix on sRGB
// values, premultiplied, in floats, rounded once at the end. What is not drawn: filters, backdrop filters, clip paths and
// masks (their groups composite as plain groups), font glyphs (raster_text.odin says what stands in for them).

// What one pixel holds while drawing: premultiplied, sRGB values, 0..1.
Pixel :: [4]f32

@(private)
Surface :: struct {
	w, h: int,
	px:   []Pixel,
}

// The content of a replaced element, or of a CSS image, from whoever holds the page.
Content_Kind :: enum u8 {
	Nothing,    // no picture: nothing is drawn
	Pixels,     // decoded
	Pending,    // not decoded yet: the picture is not final (Result.pending)
	Stand_In,   // no pixels to be had: a solid colour derived from `key`, so that both sides of a test agree only when they
	            // show the same thing
}

Content :: struct {
	kind:          Content_Kind,
	pixels:        []u8,      // RGBA8, sRGB; valid while the item is drawn
	width, height: int,
	stride:        int,
	natural:       [2]f32,    // CSS px
	vector:        bool,      // an SVG picture: `natural` follows default sizing...
	ratio_only:    bool,      // ... a ratio and no natural size: `natural` is only that ratio
	has_size:      [2]bool,   // ... which natural dimensions it has
	premultiplied: bool,
	key:           string,    // Stand_In: what it stands for (a URL, a control's type and value)
}

Host :: struct {
	user:      rawptr,
	// The content of a Replaced or Control item, wanted at w x h device px.
	replaced:  proc(user: rawptr, l: ^lay.Layout, it: ^lay.Display_Item, w, h: int) -> Content,
	// A CSS image by its URL as written in the computed style, for a tile of w x h device px. With w = 0: what is known of
	// it, sizes without pixels.
	css_image: proc(user: rawptr, url: string, w, h: int) -> Content,
}

Result :: struct {
	image:   Image,
	pending: int,     // pictures not decoded yet: draw again later for the final picture
}

@(private)
Open_Group :: struct {
	g:       i32,
	surface: Surface,
}

@(private)
Raster :: struct {
	l:       ^lay.Layout,
	v:       ^lay.View,
	host:    ^Host,
	w, h:    int,
	root:    Surface,
	open:    [dynamic]Open_Group,
	target:  ^Surface,
	pending: int,
	// the item being drawn
	space:   i32,
	clip:    i32,
	plain:   bool,      // no transform over its space: a pixel maps back by its offset alone
	planar:  bool,      // inside a 3D plane: bounds of a shape on screen are not known without projecting it
	exact_clip: bool,   // some clip around it is rounded or transformed: pixels are tested one by one
	offs:    lay.Vec2,
	scissor: [4]int,    // x0, y0, x1, y1: what the clips leave, in whole pixels
}

@(private)
ROOT_BACKGROUND := Pixel{1, 1, 1, 1}
// A half: a pixel's centre, the middle of a box, half up.
@(private)
HALF :: 0.5
@(private = "file")
BYTE_MAX :: 255
@(private = "file")
BYTE_ROUND :: HALF
// The bar's rounded ends are half its width.
@(private = "file")
SCROLLBAR_RADIUS_FACTOR :: HALF

////////////////////////////////
// Geometry

// Corner radii (horizontal, vertical): top-left, top-right, bottom-right, bottom-left.
@(private)
Radii :: [4][2]f32

// A pixel edge from a layout coordinate, as other browsers snap (half rounds up).
@(private)
snap :: #force_inline proc(v: f32) -> f32 { return math.floor(v + HALF) }

@(private)
snap_rect :: proc(r: lay.Rect) -> lay.Rect { return lay.Rect{{snap(r.min.x), snap(r.min.y)}, {snap(r.max.x), snap(r.max.y)}} }

@(private)
radii_zero :: #force_inline proc(r: ^Radii) -> bool { return r^ == {} }

// CSS Backgrounds §5.5: the radii of a border box of size w x h, reduced so adjacent ones fit.
@(private)
box_radii :: proc(cs: ^style.Computed, w, h, scale: f32) -> Radii {
	if cs == nil { return {} }
	one :: proc(cr: style.Corner_Radius, w, h, scale: f32) -> [2]f32 {
		hv := style.resolve(cr.h, w / scale) * scale
		vv := style.resolve(cr.v, h / scale) * scale
		if cr.v.kind == .Auto { vv = hv }
		return {max(hv, 0), max(vv, 0)}
	}
	if cs.radius[.Top_Left] == {} && cs.radius[.Top_Right] == {} && cs.radius[.Bottom_Right] == {} && cs.radius[.Bottom_Left] == {} { return {} }
	r := Radii{one(cs.radius[.Top_Left], w, h, scale), one(cs.radius[.Top_Right], w, h, scale), one(cs.radius[.Bottom_Right], w, h, scale), one(cs.radius[.Bottom_Left], w, h, scale)}
	if r[0].x <= 0 || r[0].y <= 0 { r[0] = {} }
	if r[1].x <= 0 || r[1].y <= 0 { r[1] = {} }
	if r[2].x <= 0 || r[2].y <= 0 { r[2] = {} }
	if r[3].x <= 0 || r[3].y <= 0 { r[3] = {} }
	f: f32 = 1
	if r[0].x + r[1].x > w && w > 0 { f = min(f, w / (r[0].x + r[1].x)) }
	if r[3].x + r[2].x > w && w > 0 { f = min(f, w / (r[3].x + r[2].x)) }
	if r[0].y + r[3].y > h && h > 0 { f = min(f, h / (r[0].y + r[3].y)) }
	if r[1].y + r[2].y > h && h > 0 { f = min(f, h / (r[1].y + r[2].y)) }
	for &c in r { c *= f }
	return r
}

// The radii of an edge inset by `w` (top, right, bottom, left): CSS Backgrounds §5.3.
@(private)
inner_radii :: proc(r: Radii, w: [4]f32) -> Radii {
	one :: proc(c: [2]f32, dx, dy: f32) -> [2]f32 {
		out := [2]f32{max(c.x - dx, 0), max(c.y - dy, 0)}
		if out.x <= 0 || out.y <= 0 { return {} }
		return out
	}
	return Radii{one(r[0], w[3], w[0]), one(r[1], w[1], w[0]), one(r[2], w[1], w[2]), one(r[3], w[3], w[2])}
}

// Which corner's curve `q` is under, with the corner's centre; false: none.
@(private)
corner_at :: #force_inline proc(r: lay.Rect, rad: ^Radii, q: lay.Vec2) -> (c: lay.Vec2, radius: [2]f32, ok: bool) {
	if rad[0].x > 0 && q.x < r.min.x + rad[0].x && q.y < r.min.y + rad[0].y { return r.min + rad[0], rad[0], true }
	if rad[1].x > 0 && q.x > r.max.x - rad[1].x && q.y < r.min.y + rad[1].y { return {r.max.x - rad[1].x, r.min.y + rad[1].y}, rad[1], true }
	if rad[2].x > 0 && q.x > r.max.x - rad[2].x && q.y > r.max.y - rad[2].y { return r.max - rad[2], rad[2], true }
	if rad[3].x > 0 && q.x < r.min.x + rad[3].x && q.y > r.max.y - rad[3].y { return {r.min.x + rad[3].x, r.max.y - rad[3].y}, rad[3], true }
	return {}, {}, false
}

@(private)
rounded_contains :: proc(r: lay.Rect, rad: ^Radii, q: lay.Vec2) -> bool {
	if !lay.rect_contains(r, q) { return false }
	if radii_zero(rad) { return true }
	c, radius, ok := corner_at(r, rad, q)
	if !ok { return true }
	// (a circle as lay.rounded_contains has it: a clip and a box of the same radius agree on every pixel)
	d := q - c
	if radius.x == radius.y { return d.x * d.x + d.y * d.y <= radius.x * radius.x }
	n := d / radius
	return n.x * n.x + n.y * n.y <= 1
}

// Signed distance to a rounded rect, negative inside; ellipses are approximated by their scaled distance.
@(private)
rounded_distance :: proc(r: lay.Rect, rad: ^Radii, q: lay.Vec2) -> f32 {
	if c, radius, ok := corner_at(r, rad, q); ok && !radii_zero(rad) {
		d := (q - c) / radius
		return (math.sqrt(d.x * d.x + d.y * d.y) - 1) * min(radius.x, radius.y)
	}
	dx := max(r.min.x - q.x, q.x - r.max.x)
	dy := max(r.min.y - q.y, q.y - r.max.y)
	if dx > 0 && dy > 0 { return math.sqrt(dx * dx + dy * dy) }
	return max(dx, dy)
}

////////////////////////////////
// Filling

// The region a paint fills: a rounded rect, maybe without a rounded rect inside it.
@(private)
Shape :: struct {
	rect:     lay.Rect,
	radii:    Radii,
	hole:     lay.Rect,
	hole_radii: Radii,
	has_hole: bool,
}

@(private)
Paint_Kind :: enum u8 { Solid, Gradient, Image, Border, Shadow }

@(private)
Paint :: struct {
	kind:     Paint_Kind,
	color:    Pixel,
	gradient: ^Gradient_Paint,
	tile:     Tile,
	content:  ^Content,
	border:   ^Border_Paint,
	shadow:   ^Shadow_Paint,
}

@(private)
premultiply :: #force_inline proc(c: css_.Color) -> Pixel {
	a := clamp(c.a, 0, 1)
	return Pixel{clamp(c.r, 0, 1) * a, clamp(c.g, 0, 1) * a, clamp(c.b, 0, 1) * a, a}
}

@(private)
solid :: #force_inline proc(c: css_.Color) -> Paint { return Paint{kind = .Solid, color = premultiply(c)} }

// The pixels the shape may touch, in the item's space, after the scissor.
@(private = "file")
device_bounds :: proc(rc: ^Raster, r: lay.Rect) -> [4]int {
	s := rc.scissor
	if rc.planar { return s }
	b := lay.rect_shift(r, rc.offs)
	if !rc.plain { b = lay.mat_bounds(rc.v.mats[rc.space], b) }
	return {max(s[0], int(math.floor(b.min.x))), max(s[1], int(math.floor(b.min.y))), min(s[2], int(math.ceil(b.max.x))), min(s[3], int(math.ceil(b.max.y)))}
}

@(private)
paint_at :: #force_inline proc(rc: ^Raster, p: ^Paint, q: lay.Vec2) -> Pixel {
	switch p.kind {
	case .Solid: return p.color
	case .Gradient:
		u, ok := tile_position(&p.tile, q)
		return ok ? gradient_color(p.gradient, u) : Pixel{}
	case .Image:
		u, ok := tile_position(&p.tile, q)
		return ok ? content_sample(p.content, u, p.tile.size) : Pixel{}
	case .Border: return border_pixel(p.border, q)
	case .Shadow: return p.shadow.color * shadow_coverage(p.shadow, q)
	}
	return {}
}

// Draws `paint` over the current target, in the coordinates of the current item's space.
@(private)
fill :: proc(rc: ^Raster, shape: ^Shape, paint: ^Paint) {
	if lay.rect_empty(shape.rect) { return }
	b := device_bounds(rc, shape.rect)
	if b[0] >= b[2] || b[1] >= b[3] { return }
	t := rc.target
	plain_shape := radii_zero(&shape.radii) && !shape.has_hole
	for y in b[1] ..< b[3] {
		row := t.px[y * t.w:][:t.w]
		for x in b[0] ..< b[2] {
			dev := lay.Vec2{f32(x) + HALF, f32(y) + HALF}
			q: lay.Vec2
			if rc.plain {
				q = dev - rc.offs
			} else {
				ok: bool
				q, ok = lay.view_to_local(rc.l, rc.v, rc.space, dev)
				if !ok { continue }
			}
			if plain_shape {
				if !lay.rect_contains(shape.rect, q) { continue }
			} else {
				if !rounded_contains(shape.rect, &shape.radii, q) { continue }
				if shape.has_hole && rounded_contains(shape.hole, &shape.hole_radii, q) { continue }
			}
			if rc.exact_clip && !lay.clip_contains(rc.l, rc.v, rc.clip, dev) { continue }
			src := paint_at(rc, paint, q)
			if src.a <= 0 { continue }
			row[x] = src + row[x] * (1 - src.a)
		}
	}
}

@(private)
fill_rect :: proc(rc: ^Raster, r: lay.Rect, c: css_.Color) {
	s := Shape{rect = r}
	p := solid(c)
	fill(rc, &s, &p)
}

// A colour from a key (FNV-1a): opaque, the same for the same key.
@(private)
stand_in_color :: proc(key: string) -> css_.Color {
	FNV_OFFSET :: 2166136261
	FNV_PRIME :: 16777619
	BYTE_MASK :: 0xFF
	GREEN_SHIFT :: 8
	BLUE_SHIFT :: 16
	h: u32 = FNV_OFFSET
	for i in 0 ..< len(key) { h = (h ~ u32(key[i])) * FNV_PRIME }
	return css_.Color{f32(h & BYTE_MASK) / BYTE_MAX, f32((h >> GREEN_SHIFT) & BYTE_MASK) / BYTE_MAX, f32((h >> BLUE_SHIFT) & BYTE_MASK) / BYTE_MAX, 1}
}

////////////////////////////////
// Groups

@(private = "file")
surface_make :: proc(w, h: int) -> Surface { return Surface{w, h, make([]Pixel, w * h)} }

// Separable blend functions (CSS Compositing 1 §5.1); the others composite as normal.
@(private = "file")
blend_channel :: proc(mode: style.Blend_Mode, cb, cs: f32) -> f32 {
	OVERLAY_SPLIT :: HALF
	#partial switch mode {
	case .Multiply: return cb * cs
	case .Screen: return cb + cs - cb * cs
	case .Overlay: return cb <= OVERLAY_SPLIT ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs)
	case .Darken: return min(cb, cs)
	case .Lighten: return max(cb, cs)
	case .Hard_Light: return cs <= OVERLAY_SPLIT ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs)
	case .Difference: return abs(cb - cs)
	case .Exclusion: return cb + cs - 2 * cb * cs
	}
	return cs
}

@(private = "file")
composite :: proc(src, dst: ^Surface, alpha: f32, mode: style.Blend_Mode) {
	for i in 0 ..< len(src.px) {
		s := src.px[i] * alpha
		if s.a <= 0 { continue }
		d := dst.px[i]
		if mode == .Normal {
			dst.px[i] = s + d * (1 - s.a)
			continue
		}
		cs := s.rgb / s.a
		cb := d.a > 0 ? d.rgb / d.a : [3]f32{}
		mixed := [3]f32{blend_channel(mode, cb.r, cs.r), blend_channel(mode, cb.g, cs.g), blend_channel(mode, cb.b, cs.b)}
		c := cs * (1 - d.a) + mixed * d.a
		out := c * s.a + d.rgb * (1 - s.a)
		dst.px[i] = Pixel{out.r, out.g, out.b, s.a + d.a * (1 - s.a)}
	}
}

@(private = "file")
pop_group :: proc(rc: ^Raster) {
	top := pop(&rc.open)
	rc.target = len(rc.open) > 0 ? &rc.open[len(rc.open) - 1].surface : &rc.root
	g := &rc.l.groups[top.g]
	mode := style.Blend_Mode.Normal
	if .Blend in g.effects && g.box != lay.NONE { if cs := rc.l.boxes[g.box].cs; cs != nil { mode = cs.mix_blend_mode } }
	composite(&top.surface, rc.target, g.alpha, mode)
	delete(top.surface.px)
}

// Opens and closes the layers of groups so that `g` is the innermost one.
@(private = "file")
set_group :: proc(rc: ^Raster, g: i32) {
	if len(rc.open) > 0 ? rc.open[len(rc.open) - 1].g == g : g == lay.NONE { return }
	want := make([dynamic]i32, 0, 8, context.temp_allocator)
	for x := g; x != lay.NONE; x = rc.l.groups[x].parent { append(&want, x) }
	keep := 0
	for keep < len(rc.open) && keep < len(want) && rc.open[keep].g == want[len(want) - 1 - keep] { keep += 1 }
	for len(rc.open) > keep { pop_group(rc) }
	for i := len(want) - 1 - keep; i >= 0; i -= 1 {
		append(&rc.open, Open_Group{want[i], surface_make(rc.w, rc.h)})
	}
	rc.target = len(rc.open) > 0 ? &rc.open[len(rc.open) - 1].surface : &rc.root
}

////////////////////////////////
// Items

// The state `it` is drawn in. false: nothing of it can show.
@(private = "file")
item_state :: proc(rc: ^Raster, it: ^lay.Display_Item) -> bool {
	l, v := rc.l, rc.v
	if it.clip >= 0 && lay.rect_empty(v.clips[it.clip]) { return false }
	sp := &l.spaces[it.space]
	if sp.xform != lay.NONE && v.singular[it.space] { return false }
	set_group(rc, it.group)
	return space_state(rc, it.space, it.clip)
}

@(private)
space_state :: proc(rc: ^Raster, space, clip: i32) -> bool {
	l, v := rc.l, rc.v
	sp := &l.spaces[space]
	rc.space, rc.clip = space, clip
	rc.plain = lay.space_plain(l, space)
	rc.planar = sp.plane != lay.NONE
	rc.offs = v.offsets[space]
	rc.scissor = {0, 0, rc.w, rc.h}
	rc.exact_clip = false
	in_plane := false
	for c := clip; c != lay.NONE; c = l.clips[c].parent {
		cl := &l.clips[c]
		if !lay.space_plain(l, cl.space) || cl.radii != {} { rc.exact_clip = true }
		if l.spaces[cl.space].plane != lay.NONE { in_plane = true }
	}
	if clip >= 0 && !in_plane {
		b := snap_rect(v.clips[clip])
		rc.scissor = {max(0, int(b.min.x)), max(0, int(b.min.y)), min(rc.w, int(b.max.x)), min(rc.h, int(b.max.y))}
	}
	return rc.scissor[0] < rc.scissor[2] && rc.scissor[1] < rc.scissor[3]
}

// A scroll bar as the browser draws it (render.odin paint_bar): an overlay bar rounded, a classic one square with its
// arrows (in one-pixel rows) and the corner of a box with two bars, in the light scheme's colors or scrollbar-color.
@(private = "file")
paint_scrollbar :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	l := rc.l
	overlay := l.settings.scrollbar_overlay
	thumb_c, track_c, arrow_c := l.settings.scrollbar_thumb, l.settings.scrollbar_track, l.settings.classic_arrow
	if !overlay { thumb_c, track_c = l.settings.classic_thumb, l.settings.classic_track }
	if it.cs != nil && !it.cs.scrollbar_color.auto { thumb_c, track_c, arrow_c = it.cs.scrollbar_color.thumb, it.cs.scrollbar_color.track, it.cs.scrollbar_color.thumb }
	box :: proc(rc: ^Raster, r: lay.Rect, c: css_.Color, rounded: bool) {
		if r.max.x <= r.min.x || r.max.y <= r.min.y { return }
		rad := rounded ? min(r.max.x - r.min.x, r.max.y - r.min.y) * SCROLLBAR_RADIUS_FACTOR : 0
		s := Shape{rect = r, radii = {{rad, rad}, {rad, rad}, {rad, rad}, {rad, rad}}}
		p := solid(c)
		fill(rc, &s, &p)
	}
	vertical := .Vertical in it.flags
	track := snap_rect(it.rect)
	box(rc, track, track_c, overlay)
	if !overlay {
		start, end, _ := lay.classic_parts(track, vertical)
		for button, i in ([2]lay.Rect{start, end}) {
			if button.max == button.min { continue }
			p := lay.classic_arrow(button, vertical, i == 1)
			lo_y, hi_y := min(p[0].y, p[1].y, p[2].y), max(p[0].y, p[1].y, p[2].y)
			for y := math.floor(lo_y); y < hi_y; y += 1 {
				lo, hi := max(f32), min(f32)
				for k in 0 ..< 3 {
					a, b := p[k], p[(k + 1) % 3]
					mid := y + HALF
					if (a.y <= mid) == (b.y <= mid) { continue }
					x := a.x + (mid - a.y) / (b.y - a.y) * (b.x - a.x)
					lo, hi = min(lo, x), max(hi, x)
				}
				if hi > lo { box(rc, lay.Rect{{lo, y}, {hi, y + 1}}, arrow_c, false) }
			}
		}
		if g := l.boxes[it.box].gutter; vertical && g[2] > 0 { box(rc, lay.Rect{{track.min.x, track.max.y}, {track.max.x, track.max.y + g[2]}}, track_c, false) }
	}
	// (the thumb comes in viewport coordinates of the item's space: back to layout coordinates)
	if th := lay.scrollbar_thumb(l, rc.v, it); th != {} { box(rc, snap_rect(lay.rect_shift(th, -rc.offs)), thumb_c, overlay) }
}

@(private = "file")
paint_item :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	switch it.kind {
	case .Box: paint_box(rc, it)
	case .Inline_Box: paint_inline_box(rc, it)
	case .Text: paint_text(rc, it)
	case .Marker: paint_marker(rc, it)
	case .Replaced, .Control: paint_content(rc, it)
	case .Outline: paint_outline(rc, it)
	case .Column_Rule: paint_column_rule(rc, it)
	case .Scrollbar: paint_scrollbar(rc, it)
	case:   // a kind this painter does not know yet draws nothing
	}
}

// Draws the layout for a viewport of w x h pixels, scrolled by `doc_scroll`, over `canvas`. The picture of the result is
// the caller's (`image_destroy`).
render :: proc(l: ^lay.Layout, w, h: int, doc_scroll: f32, canvas: css_.Color, host: ^Host, allocator := context.allocator) -> Result {
	v := lay.view_make(l, {f32(w), f32(h)}, doc_scroll)
	rc := Raster{l = l, v = &v, host = host, w = w, h = h, root = surface_make(w, h)}
	rc.open = make([dynamic]Open_Group, 0, 8, context.temp_allocator)
	rc.target = &rc.root
	back := premultiply(canvas)
	for &p in rc.root.px { p = back + ROOT_BACKGROUND * (1 - back.a) }
	rc.space, rc.clip, rc.plain, rc.offs, rc.scissor = lay.DOCUMENT_SPACE, lay.NONE, true, v.offsets[lay.DOCUMENT_SPACE], {0, 0, w, h}
	paint_canvas_images(&rc)
	for idx in v.visible {
		it := &l.items[idx]
		if !item_state(&rc, it) { continue }
		paint_item(&rc, it)
	}
	set_group(&rc, lay.NONE)
	out := Result{image = image_make(w, h, allocator), pending = rc.pending}
	for p, i in rc.root.px {
		o := out.image.rgba[i * CHANNELS:][:CHANNELS]
		o[0] = u8(clamp(p.r, 0, 1) * BYTE_MAX + BYTE_ROUND)
		o[1] = u8(clamp(p.g, 0, 1) * BYTE_MAX + BYTE_ROUND)
		o[2] = u8(clamp(p.b, 0, 1) * BYTE_MAX + BYTE_ROUND)
		o[3] = BYTE_MAX
	}
	delete(rc.root.px)
	return out
}

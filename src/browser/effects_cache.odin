package browser

import "core:math"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "wb:config"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:style"

////////////////////////////////
// Kept effect results (the toolkit's layer cache, draw/layer_cache.odin), for the compositor.
//
// A filtered group (a layer: filter, blend mode, isolation, opacity over overlapping content) whose content and nested
// effects did not change since the last frames is not drawn again: its filtered texture is composited, moved when only
// a whole-pixel translation separates it from when it was made (scrolling). The group's content key is a signature of
// what its layer receives, relative to the group's anchor (the screen translation of its box's space):
//   * each chunk drawn in it (visible this frame): the chunk's signature (the content of its picture), its replay
//     translation relative to the anchor, its slot matrices (scroll containers, sticky boxes, transforms inside);
//   * each item drawn directly: its hash and position, the state of its images (an animated image, a form control, a
//     scroll bar or a bare control make the group uncacheable);
//   * each nested group shown: its effects (filters, opacity, blend, clip-path, backdrop filters) and the clips pushed
//     around it, relative to the anchor;
//   * for the group itself: its backdrop (drawn first inside its layer), see below;
//   * the device scale, the selection, the effect preferences, the generation of the page's image pixels.
// Its own filters, opacity and blend mode are not in it: the toolkit keys the filters it runs by passes, and applies
// the opacity, the blend mode and the trailing color matrices when compositing (animating them keeps the result).
//
// A backdrop (backdrop-filter) is kept while what was drawn before it under its box is the same: every chunk, item and
// group drawn before it whose screen bounds (with the spread of their filters) meet the box is mixed into its key,
// relative to its anchor, as it is drawn. Scrolling the page moves both, which keeps it; scrolling a container or
// animating something under it changes it.

@(private)
Fx_Backdrop_Acc :: struct {
	g:      i32,
	region: lay.Rect,      // screen: the box's bounds
	anchor: draw.Vec2,
	h:      u64,
	done:   bool,          // its group opened: h is final
	blend:  bool,          // what lies under a blended group (its blended pixels are kept), not under a backdrop
	ok:     bool,          // nothing uncacheable under it
}

@(private)
Fx_Cache :: struct {
	salt:   u64,
	key:    []u64,         // per group: content key (relative to anchor[g])
	ok:     []bool,        // per group: content can be keyed
	anchor: []draw.Vec2,
	bds:    [dynamic]Fx_Backdrop_Acc,
	skip:   int,           // open groups whose kept result stands for their content
	page:   ^page.Page,
	screen: lay.Rect,
	lid:    u64,           // identity of the layout (tab)
	comp:   ^Comp,
}

@(private = "file")
fx_mix :: #force_inline proc(h, v: u64) -> u64 {
	x := (h ~ v) * 0x100000001B3
	return x ~ (x >> 29)
}

@(private = "file")
fx_f32 :: #force_inline proc(h: u64, v: f32) -> u64 { return fx_mix(h, u64(transmute(u32)v)) }

// A position to 1/64 device pixel (relative positions are hashed: equal moves cancel exactly).
@(private = "file")
fx_pos :: #force_inline proc(h: u64, v: draw.Vec2) -> u64 {
	return fx_mix(h, u64(u32(i32(math.round(v.x * 64)))) | u64(u32(i32(math.round(v.y * 64)))) << 32)
}

@(private = "file")
fx_rect :: proc(h: u64, r: lay.Rect, rel: draw.Vec2) -> u64 { return fx_pos(fx_pos(h, r.min - rel), r.max - rel) }

@(private = "file")
fx_bytes :: proc(h: u64, p: rawptr, n: int) -> u64 {
	x := h
	b := ([^]u8)(p)
	i := 0
	for ; i + 8 <= n; i += 8 { x = fx_mix(x, (^u64)(&b[i])^) }
	for ; i < n; i += 1 { x = fx_mix(x, u64(b[i])) }
	return x
}

@(private = "file")
fx_filters :: proc(h: u64, fs: []draw.Filter) -> u64 {
	x := fx_mix(h, u64(len(fs)))
	for f in fs {
		x = fx_mix(x, u64(f.kind))
		for v in f.cm { x = fx_f32(x, v) }
		x = fx_f32(fx_f32(fx_f32(x, f.sigma), f.offset.x), f.offset.y)
		for v in f.color { x = fx_f32(x, v) }
	}
	return x
}

// Where a group's content is keyed from: the screen translation of its box's space.
@(private = "file")
group_anchor :: proc(e: ^Effects, g: i32) -> draw.Vec2 {
	b := &e.l.boxes[e.l.groups[g].box]
	w := lay.space_world(e.v, b.space)
	return {w[4] + e.origin.x, w[5] + e.origin.y}
}

// The identity of a group's kept results (stable across layout passes: its element).
@(private = "file")
group_id :: proc(x: ^Fx_Cache, l: ^Layout, g: i32, salt: u64) -> u64 {
	b := &l.boxes[l.groups[g].box]
	pseudo: u64 = .Pseudo in b.flags ? (.Pseudo_After in b.flags ? 2 : 1) : 0
	id := fx_mix(fx_mix(fx_mix(x.lid, u64(b.node)), pseudo), salt)
	return id == 0 ? 1 : id
}

// The tab whose layout is `l` (its page: image states).
@(private = "file")
page_of :: proc(l: ^Layout) -> ^page.Page {
	if the_app == nil { return nil }
	for t in the_app.tabs { if &t.layout == l { return t.page } }
	return nil
}

// A chunk drawn from its picture, as seen from `anchor`.
@(private = "file")
chunk_sig_at :: proc(e: ^Effects, ch: ^Comp_Chunk, anchor: draw.Vec2) -> u64 {
	root := lay.space_world(e.v, ch.root)
	h := fx_mix(0x6368756e6b, ch.sig)
	h = fx_pos(h, draw.Vec2{root[4] + e.origin.x, root[5] + e.origin.y} - anchor)
	h = fx_f32(fx_f32(fx_f32(fx_f32(h, root[0]), root[1]), root[2]), root[3])
	for b in ch.slots {
		m := slot_matrix(e.v, ch.root, b.space)
		h = fx_mix(h, u64(b.slot))
		h = fx_f32(fx_f32(fx_f32(fx_f32(h, m.a), m.b), m.c), m.d)
		h = fx_pos(h, {m.e, m.f})
	}
	return h
}

// An item drawn directly, as seen from `anchor`; ok false: its pixels can change without its hash changing.
@(private = "file")
item_sig_at :: proc(e: ^Effects, x: ^Fx_Cache, c: ^Comp, idx: i32, anchor: draw.Vec2) -> (h: u64, ok: bool) {
	it := &e.l.items[idx]
	h = fx_mix(0x6974656d, idx < i32(len(c.item_hash)) ? c.item_hash[idx] : 0)
	off := e.v.offsets[it.space] + e.origin
	h = fx_pos(h, off - anchor)
	if !lay.space_plain(e.l, it.space) {
		m := e.v.mats[it.space]
		h = fx_f32(fx_f32(fx_f32(fx_f32(h, m[0]), m[1]), m[2]), m[3])
		h = fx_pos(h, {m[4], m[5]})
	}
	switch it.kind {
	case .Control, .Scrollbar: return h, false
	case .Replaced:
		if x.page == nil || c.doc == nil { return h, false }
		n := dom.get(c.doc, it.node)
		if n == nil || n.kind != .Element || n.name != "img" { return h, false }
		v := page.image_view(x.page, it.node)
		if v.animated { return h, false }
		h = fx_mix(fx_mix(h, v.id), u64(v.state))
	case .Box, .Inline_Box:
		if page_render.bare != nil && page_render.bare(page_render.content_user, c.doc, it.node) { return h, false }
		if it.cs != nil {
			images := [1]style.Image{it.cs.background_image}
			for list in ([2][]style.Image{images[:], it.cs.background_images}) {
				for im in list {
					if im.kind != .Url { continue }
					if x.page == nil { return h, false }
					v := page.css_image_view(x.page, im.url)
					if v.animated { return h, false }
					h = fx_mix(fx_mix(h, v.id), u64(v.state))
				}
			}
		}
	case .Text, .Marker, .Outline:
	}
	return h, true
}

// A nested group's effects and the clips pushed around it, as seen from `anchor`.
@(private = "file")
group_sig_at :: proc(e: ^Effects, c: ^Comp, g: i32, anchor: draw.Vec2) -> u64 {
	l := e.l
	gr := &l.groups[g]
	b := &l.boxes[gr.box]
	cs := b.cs
	off := e.v.offsets[b.space] + e.origin
	h := fx_mix(0x67726f7570, u64(transmute(u8)gr.effects))
	h = fx_f32(h, gr.alpha)
	if cs != nil {
		h = fx_filters(h, css_filters(cs.filter, l.scale))
		h = fx_filters(h, css_filters(cs.backdrop_filter, l.scale))
		h = fx_mix(h, u64(cs.mix_blend_mode))
		if .Clip_Path in gr.effects {
			sh := lay.clip_path_shape(l, gr.box)
			h = fx_mix(h, u64(sh.kind))
			h = fx_rect(h, sh.rect, anchor - off)
			h = fx_bytes(h, &sh.radii, size_of(sh.radii))
			h = fx_pos(h, sh.center + off - anchor)
			h = fx_pos(h, sh.radius)
			for p in sh.points { h = fx_pos(h, p + off - anchor) }
			h = fx_mix(h, u64(sh.evenodd))
		}
		if .Backdrop in gr.effects {
			h = fx_rect(h, lay.Rect{b.abs, b.abs + b.size}, anchor - off)
			radii := lay.border_radii(cs, b.size.x, b.size.y, l.scale)
			h = fx_bytes(h, &radii, size_of(radii))
		}
	}
	if !lay.space_plain(l, b.space) {
		m := e.v.mats[b.space]
		h = fx_f32(fx_f32(fx_f32(fx_f32(h, m[0]), m[1]), m[2]), m[3])
		h = fx_pos(h, {m[4], m[5]} + e.origin - anchor)
	}
	if int(g) < len(c.floors) {
		for ci in c.floors[g] {
			cl := &l.clips[ci]
			h = fx_rect(h, cl.rect, anchor - (e.v.offsets[cl.space] + e.origin))
			h = fx_bytes(h, &cl.radii, size_of(cl.radii))
			h = fx_mix(h, u64(e.l.spaces[cl.space].xform != lay.NONE))
		}
	}
	if gp := &e.groups[g]; gp.seen { h = fx_rect(h, gp.bounds, anchor) }
	return h
}

// Item `idx` will be drawn this frame (the compositor's tests, in the same order).
@(private = "file")
item_drawn :: proc(e: ^Effects, it: ^lay.Display_Item, screen: lay.Rect) -> bool {
	if lay.rect_empty(lay.rect_intersect(item_ink(e, it), screen)) { return false }
	if it.clip >= 0 && lay.rect_empty(e.v.clips[it.clip]) { return false }
	xf := e.l.spaces[it.space].xform
	return !(xf != lay.NONE && e.v.singular[it.space])
}

// Before a composited frame: the content keys of the groups, the backdrops to watch.
@(private)
fx_cache_begin :: proc(x: ^Fx_Cache, c: ^Comp, e: ^Effects, screen: lay.Rect) {
	l := e.l
	n := len(l.groups)
	x.key = make([]u64, n, context.temp_allocator)
	x.ok = make([]bool, n, context.temp_allocator)
	x.anchor = make([]draw.Vec2, n, context.temp_allocator)
	x.bds = make([dynamic]Fx_Backdrop_Acc, 0, 4, context.temp_allocator)
	x.page = page_of(l)
	x.screen = screen
	x.lid = u64(uintptr(l))
	x.comp = c
	s := effects_settings
	salt := fx_mix(0x73616c74, u64(s.filters) | u64(s.backdrop_filters) << 1 | u64(s.blend_modes) << 2 | u64(s.clip_paths) << 3 | u64(s.exact_shadows) << 4 | u64(page_render.settings.opacity_layers) << 5)
	salt = fx_f32(salt, s.blur_sigma_limit)
	salt = fx_f32(salt, l.scale)
	salt = fx_mix(salt, c.sel_key)
	if x.page != nil { salt = fx_mix(salt, page.images_pixels_generation(x.page)) }
	x.salt = salt
	if n == 0 || !fx_settings.enabled { return }
	for g in 0 ..< n {
		x.anchor[g] = group_anchor(e, i32(g))
		x.key[g] = salt
		x.ok[g] = true
		gr := &l.groups[g]
		if .Backdrop in gr.effects && effects_settings.backdrop_filters && e.groups[g].seen {
			b := &l.boxes[gr.box]
			r := lay.rect_shift(lay.Rect{b.abs, b.abs + b.size}, e.v.offsets[b.space] + e.origin)
			if !lay.space_plain(l, b.space) { r = lay.mat_bounds(lay.mat_shifted(e.v.mats[b.space], e.origin), lay.rect_shift(lay.Rect{b.abs, b.abs + b.size}, e.v.offsets[b.space])) }
			append(&x.bds, Fx_Backdrop_Acc{g = i32(g), region = r, anchor = x.anchor[g], h = salt, ok = true})
		}
		if .Blend in gr.effects && effects_settings.blend_modes && e.groups[g].seen {
			gp := &e.groups[g]
			o := group_outset(e, i32(g))
			r := lay.Rect{gp.bounds.min - {o[0], o[1]}, gp.bounds.max + {o[2], o[3]}}
			append(&x.bds, Fx_Backdrop_Acc{g = i32(g), region = r, anchor = x.anchor[g], h = salt, ok = true, blend = true})
		}
	}
	// what each group's layer receives, in paint order
	for &ch in c.chunks {
		if !ch.visible || ch.group == lay.NONE { continue }
		if ch.immediate {
			for i in ch.first ..< ch.end {
				it := &l.items[i]
				if !item_drawn(e, it, screen) { continue }
				for g := it.group; g != lay.NONE; g = l.groups[g].parent {
					h, ok := item_sig_at(e, x, c, i, x.anchor[g])
					x.key[g] = fx_mix(x.key[g], h)
					if !ok { x.ok[g] = false }
				}
			}
			continue
		}
		for g := ch.group; g != lay.NONE; g = l.groups[g].parent {
			x.key[g] = fx_mix(x.key[g], chunk_sig_at(e, &ch, x.anchor[g]))
		}
	}
	for g in 0 ..< n {
		if !e.groups[g].seen { continue }
		for p := l.groups[g].parent; p != lay.NONE; p = l.groups[p].parent {
			x.key[p] = fx_mix(x.key[p], group_sig_at(e, c, i32(g), x.anchor[p]))
		}
	}
}

// Mixes what is about to be drawn (a chunk, an item, or a group opening) into the backdrops still waiting for it.
@(private)
fx_cache_under :: proc(e: ^Effects, ch: ^Comp_Chunk, item: i32 = -1, group: i32 = lay.NONE) {
	x := e.fxc
	if x == nil || len(x.bds) == 0 { return }
	c := x.comp
	l := e.l
	r: lay.Rect
	switch {
	case group != lay.NONE:
		r = e.groups[group].bounds
		o := group_outset(e, group)
		r = lay.Rect{r.min - {o[0], o[1]}, r.max + {o[2], o[3]}}
	case item >= 0:
		r = item_ink(e, &l.items[item])
	case:
		reach: f32 = ch.group != lay.NONE ? l.groups[ch.group].reach : 0
		r = lay.Rect{ch.screen.min - reach, ch.screen.max + reach}
	}
	for &b in x.bds {
		if b.done || lay.rect_empty(lay.rect_intersect(r, b.region)) { continue }
		switch {
		case group != lay.NONE: b.h = fx_mix(b.h, group_sig_at(e, c, group, b.anchor))
		case item >= 0:
			h, ok := item_sig_at(e, x, c, item, b.anchor)
			b.h = fx_mix(b.h, h)
			if !ok { b.ok = false }
		case: b.h = fx_mix(b.h, chunk_sig_at(e, ch, b.anchor))
		}
	}
}

// Content of open groups is not drawn: a kept result stands for it.
@(private)
fx_cache_skipping :: proc(e: ^Effects) -> bool { return e.fxc != nil && e.fxc.skip > 0 }

// The cache parameters of group g's layer (zero: not kept).
@(private)
fx_cache_layer :: proc(e: ^Effects, g: i32, fx: ^draw.Layer_Effects) {
	x := e.fxc
	if x == nil || int(g) >= len(x.ok) || !x.ok[g] || !fx_settings.enabled { return }
	key := x.key[g]
	under: u64
	for &b in x.bds {
		if b.g != g { continue }
		if b.blend {
			// what lies under it: its blended pixels can be kept
			b.done = true
			if b.ok { under = b.h == 0 ? 1 : b.h }
			continue
		}
		// its backdrop is drawn first in its layer
		if !b.ok { return }
		key = fx_mix(key, b.h)
	}
	fx.cache_under = under
	fx.cache_id = group_id(x, e.l, g, 0x6c61796572)
	fx.cache_key = key
	fx.cache_anchor = x.anchor[g]
}

// The cache parameters of group g's backdrop (zero id: not kept). Ends what is watched for it.
@(private)
fx_cache_backdrop :: proc(e: ^Effects, g: i32) -> (id, key: u64, anchor: draw.Vec2) {
	x := e.fxc
	if x == nil { return }
	for &b in x.bds {
		if b.g != g || b.blend { continue }
		b.done = true
		if !b.ok || !fx_settings.enabled { return }
		return group_id(x, e.l, g, 0x6264), b.h, b.anchor
	}
	return
}

////////////////////////////////
// Preferences (paint.effects.cache.*, paint.effects.filter_precision)

@(private)
Fx_Settings :: struct {
	enabled:     bool,
	budget:      int,    // bytes
	whole_px:    int,
	idle_ms:     f64,
	precision:   render.Target_Format,
	text_shadows: bool,
}

@(private) fx_settings := Fx_Settings{enabled = true, budget = 128 << 20, whole_px = 4 << 20, idle_ms = 10_000, precision = .Unorm8, text_shadows = true}

FX_CACHE_PREFS := [?]config.Def{
	{name = "paint.effects.cache.enabled", kind = .Bool, default = {b = true},
		description = "Keep the result of filtered elements (filter, drop-shadow, blend modes, group opacity), of backdrop-filter and of blurred text shadows from frame to frame, and composite it again while their content, their filters and what lies under a backdrop do not change (moved by scrolling included). Off: they are filtered again every frame."},
	{name = "paint.effects.cache.memory_mb", kind = .Int, default = {i = 128}, bounded = true, min = 0, max = 16384, unit = "MB",
		description = "GPU memory the kept effect results may use. The least recently used go first past it."},
	{name = "paint.effects.cache.whole_layer_mpx", kind = .Float, default = {f = 4}, bounded = true, min = 0, max = 256, unit = "Mpx",
		description = "A filtered element up to this many megapixels is filtered whole (not only its visible part) when its result is kept, so that it stays good while it scrolls into view."},
	{name = "paint.effects.cache.idle_ms", kind = .Float, default = {f = 10_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "A kept effect result not shown for this long is let go."},
	{name = "paint.effects.cache.text_shadows", kind = .Bool, default = {b = true},
		description = "Keep blurred text shadows (text-shadow with a blur) from frame to frame too."},
	{name = "paint.effects.filter_precision", kind = .String, default = {s = "8bit"},
		description = "Storage of filter results: 8bit (sRGB-encoded 8 bits per channel, as browsers keep them: half the memory and bandwidth) or 16bit (half floats)."},
}

register_fx_cache_prefs :: proc(p: ^config.Prefs) { config.register(p, FX_CACHE_PREFS[:]) }

@(private)
fx_settings_from_prefs :: proc(p: ^config.Prefs) -> Fx_Settings {
	return Fx_Settings{
		enabled = config.bool_of(p, "paint.effects.cache.enabled"),
		budget = int(config.int_of(p, "paint.effects.cache.memory_mb")) << 20,
		whole_px = int(config.float_of(p, "paint.effects.cache.whole_layer_mpx") * 1e6),
		idle_ms = config.float_of(p, "paint.effects.cache.idle_ms"),
		precision = config.string_of(p, "paint.effects.filter_precision") == "16bit" ? .Half : .Unorm8,
		text_shadows = config.bool_of(p, "paint.effects.cache.text_shadows"),
	}
}

// Applies the settings to the toolkit (the idle time in frames at the current frame rate).
@(private)
fx_settings_apply :: proc(app: ^App) {
	s := fx_settings
	hz := pacer.hz > 0 ? pacer.hz : 60
	idle := max(int(s.idle_ms * f64(hz) / 1000), 1)
	draw.set_layer_cache(&app.dc, s.enabled ? s.budget : 0, s.whole_px, idle)
	render.set_filter_precision(&app.r, s.precision)
}

// The cache parameters of a blurred text shadow drawn through a layer (render.odin, paint_text): its text, font,
// color and offset relative to the item.
fx_cache_text_shadow :: proc(it: ^lay.Display_Item, shadow: int, fid: font.Font_Id, size: f32, col: draw.Color, pos: draw.Vec2, r: draw.Rect, opts: font.Shape_Options) -> (id, key: u64, anchor: draw.Vec2) {
	if !fx_settings.enabled || !fx_settings.text_shadows { return }
	id = fx_mix(fx_mix(fx_mix(0x7473, u64(it.node)), u64(shadow)), u64(transmute(u32)it.rect.min.x) | u64(transmute(u32)it.rect.min.y) << 32)
	key = fx_mix(fx_mix(0x74657874, u64(len(it.text))), fx_bytes(u64(fid), raw_data(it.text), len(it.text)))
	key = fx_f32(key, size)
	for v in col { key = fx_f32(key, v) }
	key = fx_pos(key, pos - r.min)
	key = fx_pos(key, r.max - r.min)
	key = fx_mix(key, u64(opts.direction) | u64(opts.one_run) << 8)
	key = fx_f32(fx_f32(fx_f32(key, opts.letter_spacing), opts.word_spacing), opts.justify)
	return id == 0 ? 1 : id, key, r.min
}


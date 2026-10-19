package browser

import "core:math"
import "toolkit:draw"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:dom"
import lay "wb:layout"
import "wb:style"

////////////////////////////////
// The compositor: the page's display list kept on the GPU.
//
// The display list is cut into paint chunks (layout/composite.odin). Each chunk is recorded once into a retained
// picture of the toolkit (draw.Picture): its instances stay in GPU heaps and every frame replays them for a few draw
// calls. In a picture every space of the page is a transform slot, so:
//   * scrolling the document only changes the replay matrix; scrolling a container or a sticky shift changes one slot;
//   * a transform animation (the paint-only refresh of the layout updates the space's matrix) changes one slot;
//   * opacity, filters, blend modes, backdrops and clip-paths are applied around replays by the effects code
//     (paint_effects.odin), with their current parameters: animating them records nothing.
// A chunk is recorded again only when its content changes: a layout pass that changes its items (other chunks keep
// their pictures: they are matched by a signature of their content), a paint value of one of its items (a color
// animation, a hover), a clip radius, or a text scale / glyph atlas the picture no longer matches. Items whose content
// changes by itself (images, which may animate or still decode; form controls; scroll bars; text with a blurred shadow,
// which needs an offscreen layer) are drawn directly every frame, in their place in the paint order.
// The per-frame cost is proportional to the number of chunks and slots, not to the number of items.

COMPOSITOR_PREFS := [?]config.Def{
	{name = "render.compositor.enabled", kind = .Bool, default = {b = true},
		description = "Keep the page's drawing on the GPU (retained pictures) and replay it each frame: scrolling and transform, opacity or filter animations cost almost nothing. Off: every item is drawn again each frame (the same pixels)."},
	{name = "render.compositor.chunk_items", kind = .Int, default = {i = 512}, bounded = true, min = 16, max = 65536, unit = "items",
		description = "Most display items recorded into one picture. Smaller: finer culling and re-recording, more draw calls."},
	{name = "render.compositor.max_chunks", kind = .Int, default = {i = 4096}, bounded = true, min = 16, max = 1_000_000,
		description = "Most pictures per page. Past it pictures hold more items; if effect groups alone need more, the page is drawn directly."},
	{name = "render.compositor.settle_ms", kind = .Float, default = {f = 50}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "After layout passes on nearby frames (a window resize, an animation of a layout property), the page is drawn directly until this long passed without one (whatever the frame rate); then what changed is recorded. 0: record after every layout pass."},
	{name = "render.compositor.memory_mb", kind = .Int, default = {i = 256}, bounded = true, min = 8, max = 16384, unit = "MB",
		description = "GPU memory the retained pictures may use before the ones not drawn recently are evicted (they are uploaded again from their recording when they come back into view)."},
}

@(private)
Compositor_Settings :: struct {
	enabled:     bool,
	chunk_items: int,
	max_chunks:  int,
	settle_ms:   f64,
	memory:      int,   // bytes
}

@(private) compositor_settings := Compositor_Settings{enabled = true, chunk_items = 512, max_chunks = 4096, settle_ms = 50, memory = 256 << 20}

@(private)
compositor_settings_from_prefs :: proc(p: ^config.Prefs) -> Compositor_Settings {
	return Compositor_Settings{
		enabled = config.bool_of(p, "render.compositor.enabled"),
		chunk_items = int(config.int_of(p, "render.compositor.chunk_items")),
		max_chunks = int(config.int_of(p, "render.compositor.max_chunks")),
		settle_ms = config.float_of(p, "render.compositor.settle_ms"),
		memory = int(config.int_of(p, "render.compositor.memory_mb")) << 20,
	}
}

// Diagnostics of the last composited frame (profiling, tests).
Composite_Stats :: struct {
	chunks, visible, replayed, recorded, immediate_items, slots_set: int,
}
// (thread-local, like the pictures of each layout: the UI thread paints; tests paint from several threads)
@(thread_local) composite_stats: Composite_Stats

@(private)
Slot_Bind :: struct {
	space: i32,
	key:   lay.Space_Key,
	slot:  u32,
}

@(private)
Space_Bounds :: struct {
	space: i32,
	r:     lay.Rect,
}

@(private)
Comp_Chunk :: struct {
	using chunk: lay.Chunk,
	pic:      ^draw.Picture,
	sig:      u64,
	recorded: bool,          // pic holds the chunk's current content
	slots:    [dynamic]Slot_Bind,
	bounds:   [dynamic]Space_Bounds,   // per space: what its items may paint (layout coordinates)
	clips:    [dynamic]i32,            // clips recorded into the picture (their radii are watched)
	screen:   lay.Rect,                // this frame: what its items paint (before the filters of their groups)
	visible:  bool,
}

@(private)
Comp :: struct {
	seen_passes, seen_refresh, seen_restyled: u64,
	sel_key:    u64,   // selection_paint_key when the pictures were recorded
	items_len:  int,
	chunk_items: int,
	direct:     bool,                    // too many chunks: drawn item by item
	chunks:     [dynamic]Comp_Chunk,
	item_hash:  [dynamic]u64,            // per item: what its picture was recorded from
	item_cs:    [dynamic]^style.Computed,
	item_chunk: [dynamic]i32,
	node_items: map[base.Handle][dynamic]i32,   // items by node, for animated elements (node_items_ok: up to date)
	node_items_ok: bool,
	clip_radii: [dynamic][4]f32,         // per clip, as recorded
	deco_colors: [dynamic]css.Color,     // per Layout.deco_items, as recorded
	floors:     [dynamic][dynamic]i32,   // per group: the clips pushed around it (paint_effects.odin, open_group)
	group_units: [dynamic]int,
	pool:       [dynamic]^draw.Picture,  // pictures of dropped chunks
	frame:      i64,                     // frames painted
	pass_ms:    f64,                     // frame time (pacer.frame_ms) of the last one with a new layout pass
	last_passes: u64,                    // layout passes seen at the last frame
	doc:        ^dom.Document,
	dc:         ^draw.Context,               // the context the pictures were recorded with
}

@(private, thread_local) comps: map[^Layout]^Comp

@(private)
comp_of :: proc(l: ^Layout) -> ^Comp {
	if c, ok := comps[l]; ok { return c }
	c := new(Comp)
	c.pass_ms = -1e18
	comps[l] = c
	return c
}

// Frees the pictures and state of a layout (layout_reset / layout_destroy).
composite_forget :: proc(l: ^Layout) {
	c, ok := comps[l]
	if !ok { return }
	delete_key(&comps, l)
	for &ch in c.chunks { chunk_free(c, &ch) }
	for p in c.pool { picture_free(c, p) }
	delete(c.chunks); delete(c.item_hash); delete(c.item_cs); delete(c.item_chunk); delete(c.clip_radii); delete(c.deco_colors)
	for _, v in c.node_items { delete(v) }
	delete(c.node_items)
	for f in c.floors { delete(f) }
	delete(c.floors); delete(c.group_units); delete(c.pool)
	free(c)
	if len(comps) == 0 { delete(comps); comps = nil }
}

@(private)
picture_free :: proc(c: ^Comp, p: ^draw.Picture) {
	if c.dc != nil { draw.picture_destroy(c.dc, p) }
	free(p)
}

@(private)
chunk_free :: proc(c: ^Comp, ch: ^Comp_Chunk) {
	if ch.pic != nil { picture_free(c, ch.pic) }
	delete(ch.slots); delete(ch.bounds); delete(ch.clips)
	ch^ = {}
}

////////////////////////////////
// Paint values recorded into pictures

// Properties the painter reads for what it records (everything else is layout, or applied around replays: transform,
// opacity, filter, backdrop-filter, clip-path, blend mode).
@(private)
RASTER_PROPS :: [?]style.Prop{
	.Color, .Text_Shadow, .Text_Decoration_Line, .Text_Decoration_Color, .Text_Decoration_Style, .Text_Decoration_Thickness,
	.Letter_Spacing, .Word_Spacing,
	.Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color,
	.Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style,
	.Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width,
	.Border_Top_Left_Radius, .Border_Top_Right_Radius, .Border_Bottom_Right_Radius, .Border_Bottom_Left_Radius,
	.Background_Color, .Background_Image, .Background_Repeat, .Background_Position, .Background_Size,
	.Background_Origin, .Background_Clip, .Background_Attachment, .Box_Shadow,
	.Outline_Width, .Outline_Style, .Outline_Color, .Outline_Offset, .List_Style_Type,
}

@(private = "file")
raster_props :: proc() -> style.Prop_Set {
	@(static) set: style.Prop_Set
	@(static) ready: bool
	if !ready {
		list := RASTER_PROPS
		set = style.ps_of(..list[:])
		ready = true
	}
	return set
}

@(private = "file")
mix :: #force_inline proc(h, v: u64) -> u64 {
	x := (h ~ v) * 0x100000001B3
	return x ~ (x >> 31)
}

@(private = "file")
hash_bytes :: proc(h: u64, p: rawptr, n: int) -> u64 {
	x := h
	b := ([^]u8)(p)
	i := 0
	for ; i + 8 <= n; i += 8 { x = mix(x, (^u64)(&b[i])^) }
	for ; i < n; i += 1 { x = mix(x, u64(b[i])) }
	return x
}

@(private = "file")
hash_of :: #force_inline proc(h: u64, v: $T) -> u64 {
	x := v
	return hash_bytes(h, &x, size_of(T))
}

@(private = "file")
hash_slice :: proc(h: u64, s: []$T) -> u64 { return hash_bytes(mix(h, u64(len(s))), raw_data(s), len(s) * size_of(T)) }

@(private = "file")
hash_string :: #force_inline proc(h: u64, s: string) -> u64 { return hash_bytes(mix(h, u64(len(s))), raw_data(s), len(s)) }

@(private = "file")
hash_length :: #force_inline proc(h: u64, l: style.Length) -> u64 {
	return mix(mix(h, u64(l.kind) | u64(transmute(u32)l.v) << 8), u64(uintptr(l.calc)))
}

@(private = "file")
hash_shadows :: proc(h: u64, list: []style.Shadow) -> u64 {
	x := mix(h, u64(len(list)))
	for s in list {
		x = hash_of(x, s.color)
		x = mix(mix(x, u64(transmute(u32)s.x) | u64(transmute(u32)s.y) << 32), u64(transmute(u32)s.blur) | u64(transmute(u32)s.spread) << 32)
		x = mix(x, u64(s.inset))
	}
	return x
}

@(private = "file")
hash_image :: proc(h: u64, im: style.Image) -> u64 {
	// a gradient by its text: the parsed one is made from it
	return hash_string(hash_string(mix(h, u64(im.kind)), im.url), im.gradient)
}

// What the painter records of a style (RASTER_PROPS), by value. Plain fields are hashed as bytes, lists by their
// elements, a length's calc() by identity (a recording made again when only the tree was copied).
@(private)
raster_hash :: proc(cs: ^style.Computed, cache: ^map[^style.Computed]u64) -> u64 {
	if cs == nil { return 0 }
	if cache != nil { if h, ok := cache[cs]; ok { return h } }
	h: u64 = 0xcbf29ce484222325
	h = hash_of(h, cs.color)
	h = hash_shadows(h, cs.text_shadow)
	h = hash_of(h, cs.text_decoration)
	h = hash_of(h, cs.text_decoration_color)
	h = hash_of(h, cs.text_decoration_style)
	h = hash_length(h, cs.text_decoration_thickness)
	h = mix(h, u64(transmute(u32)cs.letter_spacing) | u64(transmute(u32)cs.word_spacing) << 32)
	h = hash_of(h, cs.border_color)
	h = hash_of(h, cs.border_style)
	h = hash_of(h, cs.border_width)
	for r in cs.radius { h = hash_length(hash_length(h, r.h), r.v) }
	h = hash_of(h, cs.background_color)
	h = hash_image(h, cs.background_image)
	h = mix(h, u64(len(cs.background_images)))
	for im in cs.background_images { h = hash_image(h, im) }
	h = hash_slice(h, cs.background_repeats)
	h = mix(h, u64(len(cs.background_positions)))
	for p in cs.background_positions { h = hash_length(hash_length(h, p[0]), p[1]) }
	h = mix(h, u64(len(cs.background_sizes)))
	for s in cs.background_sizes { h = hash_length(hash_length(mix(h, u64(s.kind)), s.w), s.h) }
	h = hash_slice(h, cs.background_origins)
	h = hash_slice(h, cs.background_clips)
	h = hash_slice(h, cs.background_attachments)
	h = hash_shadows(h, cs.box_shadow)
	h = mix(h, u64(transmute(u32)cs.outline_width) | u64(transmute(u32)cs.outline_offset) << 32)
	h = hash_of(h, cs.outline_style)
	h = hash_of(h, cs.outline_color)
	h = hash_of(h, cs.list_style_type)
	h = hash_string(mix(h, u64(cs.list_style.style)), cs.list_style.text)
	if cache != nil { cache[cs] = h }
	return h
}
////////////////////////////////
// Clips: what a group pushes around it, what an item pushes inside

@(private = "file")
clip_chain :: proc(l: ^Layout, ci: i32, out: ^[dynamic]i32) {
	clear(out)
	for c := ci; c != lay.NONE; c = l.clips[c].parent { append(out, c) }
	for i, j := 0, len(out) - 1; i < j; i, j = i + 1, j - 1 { out[i], out[j] = out[j], out[i] }
}

@(private = "file")
has_prefix :: proc(a, p: []i32) -> bool {
	if len(p) > len(a) { return false }
	for x, i in p { if a[i] != x { return false } }
	return true
}

// The clips pushed when group g opens, in the order effects push them: the group's box's clip chain on top of the
// enclosing group's (set_clip keeps a chain that extends the floor, else stacks the whole chain on it).
@(private = "file")
compute_floors :: proc(c: ^Comp, l: ^Layout) {
	for f in c.floors { delete(f) }
	resize(&c.floors, len(l.groups))
	want := make([dynamic]i32, 0, 8, context.temp_allocator)
	for g in 0 ..< len(l.groups) {
		// groups are made in tree order: a parent before its children
		f := make([dynamic]i32, 0, 4)
		parent := l.groups[g].parent
		pf: []i32 = parent != lay.NONE ? c.floors[parent][:] : nil
		clip_chain(l, l.boxes[l.groups[g].box].clip, &want)
		if !has_prefix(want[:], pf) { append(&f, ..pf) }
		append(&f, ..want[:])
		c.floors[g] = f
	}
}

// The clips item `it` pushes inside its group (all of its chain outside any group).
@(private = "file")
local_clips :: proc(c: ^Comp, l: ^Layout, it: ^lay.Display_Item, out: ^[dynamic]i32) -> []i32 {
	clip_chain(l, it.clip, out)
	if it.group == lay.NONE { return out[:] }
	f := c.floors[it.group][:]
	return has_prefix(out[:], f) ? out[len(f):] : out[:]
}

////////////////////////////////
// Chunks

@(private = "file")
immediate_item :: proc(user: rawptr, l: ^Layout, it: ^lay.Display_Item) -> bool {
	c := (^Comp)(user)
	switch it.kind {
	case .Replaced, .Control, .Scrollbar: return true
	case .Box:
		if page_render.bare != nil && page_render.bare(page_render.content_user, c.doc, it.node) { return true }
		if it.cs != nil && background_has_url(it.cs) && .No_Background not_in it.flags { return true }
	case .Inline_Box:
		if it.cs != nil && background_has_url(it.cs) { return true }
	case .Text:
		if it.cs != nil && effects_settings.exact_shadows {
			for s in it.cs.text_shadow { if s.blur > 0 && s.color.a > 0 { return true } }
		}
	case .Marker, .Outline:
	}
	return false
}

// What an item contributes to its chunk's signature: everything its recording reads.
@(private = "file")
item_hash :: proc(c: ^Comp, l: ^Layout, it: ^lay.Display_Item, cache: ^map[^style.Computed]u64, chain: ^[dynamic]i32) -> u64 {
	h: u64 = 0x84222325cbf29ce4
	h = mix(h, u64(it.kind) | u64(transmute(u8)(it.flags - {.Hit})) << 8 | u64(it.level) << 16)   // level: the shaping direction
	h = hash_bytes(h, &it.rect, size_of(it.rect))
	h = hash_bytes(mix(h, u64(len(it.text))), raw_data(it.text), len(it.text))
	if it.fi >= 0 && int(it.fi) < len(l.fonts) {
		fi := &l.fonts[it.fi]
		h = mix(mix(h, u64(fi.font)), u64(transmute(u32)fi.size))
	}
	h = mix(h, u64(transmute(u32)it.baseline) | u64(transmute(u32)it.extra) << 32)
	h = hash_bytes(h, &it.thumb, size_of(it.thumb))
	deco := it.deco
	h = hash_bytes(h, &deco, size_of(deco))
	h = hash_bytes(h, &it.deco_color, size_of(it.deco_color))
	h = mix(h, raster_hash(it.cs, cache))
	k := lay.space_key(l, it.space)
	h = hash_bytes(h, &k, size_of(k))
	for ci in local_clips(c, l, it, chain) {
		cl := &l.clips[ci]
		h = hash_bytes(h, &cl.rect, size_of(cl.rect))
		h = hash_bytes(h, &cl.radii, size_of(cl.radii))
		ck := lay.space_key(l, cl.space)
		h = hash_bytes(h, &ck, size_of(ck))
	}
	return h
}

// After a layout pass: cut the new display list into chunks; chunks whose content did not change keep their picture.
@(private = "file")
rebuild :: proc(c: ^Comp, l: ^Layout) {
	compute_floors(c, l)
	n := len(l.items)
	settings := compositor_settings
	cap_items := max(settings.chunk_items, (n + settings.max_chunks - 1) / max(settings.max_chunks, 1))
	c.chunk_items = cap_items
	fresh := make([dynamic]lay.Chunk, 0, n / max(cap_items / 2, 1) + 8, context.temp_allocator)
	lay.build_chunks(l, &fresh, {min_items = max(cap_items / 8, 8), max_items = cap_items, boundary_mask = 63}, c, immediate_item)
	c.direct = len(fresh) > settings.max_chunks
	// item hashes, then chunk signatures
	resize(&c.item_hash, n)
	resize(&c.item_cs, n)
	resize(&c.item_chunk, n)
	cache := make(map[^style.Computed]u64, 1024, context.temp_allocator)
	chain := make([dynamic]i32, 0, 8, context.temp_allocator)
	for i in 0 ..< n {
		it := &l.items[i]
		c.item_hash[i] = item_hash(c, l, it, &cache, &chain)
		c.item_cs[i] = it.cs
	}
	// old chunks by signature
	old := make(map[u64][dynamic]int, len(c.chunks), context.temp_allocator)
	for &ch, i in c.chunks {
		if ch.immediate || !ch.recorded { continue }
		list := old[ch.sig] or_else make([dynamic]int, context.temp_allocator)
		append(&list, i)
		old[ch.sig] = list
	}
	keys := make(map[lay.Space_Key]i32, len(l.spaces), context.temp_allocator)
	for s in 0 ..< len(l.spaces) { keys[lay.space_key(l, i32(s))] = i32(s) }
	used := make([]bool, len(c.chunks), context.temp_allocator)
	next := make([dynamic]Comp_Chunk, 0, len(fresh))
	for f, k in fresh {
		nc := Comp_Chunk{chunk = f}
		for i in f.first ..< f.end { c.item_chunk[i] = i32(k) }
		sig := chunk_sig(c, f.first, f.end, f.immediate)
		nc.sig = sig
		if !f.immediate {
			if list, ok := old[sig]; ok {
				for oi in list {
					if used[oi] { continue }
					// the same content: its picture, with its slots pointed at the spaces of the new layout
					oc := &c.chunks[oi]
					reuse := true
					for b in oc.slots { if _, found := keys[b.key]; !found { reuse = false } }
					if !reuse { continue }
					used[oi] = true
					nc.pic, nc.recorded, nc.slots = oc.pic, true, oc.slots
					oc.pic, oc.slots = nil, nil
					for &b in nc.slots { b.space = keys[b.key] }
					break
				}
			}
		}
		chunk_extent(c, l, &nc, &chain)
		append(&next, nc)
	}
	for &oc in c.chunks {
		if oc.pic != nil {
			draw.picture_release(c.dc, oc.pic)
			append(&c.pool, oc.pic)
			oc.pic = nil
		}
		delete(oc.slots); delete(oc.bounds); delete(oc.clips)
	}
	for len(c.pool) > 64 { picture_free(c, pop(&c.pool)) }
	delete(c.chunks)
	c.chunks = next
	c.node_items_ok = false   // made when an animation needs it (node_items_make)
	resize(&c.clip_radii, len(l.clips))
	resize(&c.deco_colors, len(l.deco_items))
	for i, k in l.deco_items { c.deco_colors[k] = l.items[i].deco_color }
	for &cl, i in l.clips { c.clip_radii[i] = cl.radii }
	group_units(c, l)
	c.items_len = n
}

@(private = "file")
chunk_sig :: proc(c: ^Comp, first, end: i32, immediate: bool) -> u64 {
	sig: u64 = immediate ? 1 : 0x9ae16a3b2f90404f
	for i in first ..< end { sig = mix(sig, c.item_hash[i]) }
	return sig
}

// Per space, what the chunk's items may paint; the clips its picture holds.
@(private = "file")
chunk_extent :: proc(c: ^Comp, l: ^Layout, ch: ^Comp_Chunk, chain: ^[dynamic]i32) {
	clear(&ch.bounds)
	clear(&ch.clips)
	for i in ch.first ..< ch.end {
		it := &l.items[i]
		r := item_ink_local(l, it)
		found := false
		for &b in ch.bounds {
			if b.space == it.space { b.r = lay.rect_union(b.r, r); found = true; break }
		}
		if !found { append(&ch.bounds, Space_Bounds{space = it.space, r = r}) }
		if ch.immediate { continue }
		for ci in local_clips(c, l, it, chain) {
			seen := false
			for x in ch.clips { if x == ci { seen = true; break } }
			if !seen { append(&ch.clips, ci) }
		}
	}
}

@(private = "file")
node_items_make :: proc(c: ^Comp, l: ^Layout) {
	for _, v in c.node_items { delete(v) }
	clear(&c.node_items)
	for &it, i in l.items {
		if it.node == base.NIL_HANDLE { continue }
		list := c.node_items[it.node] or_else make([dynamic]i32, 0, 2)
		append(&list, i32(i))
		c.node_items[it.node] = list
	}
	c.node_items_ok = true
}

// Primitives of each group that could overlap (with its child groups), for all its items: whether opacity needs a layer.
@(private = "file")
group_units :: proc(c: ^Comp, l: ^Layout) {
	resize(&c.group_units, len(l.groups))
	for &u in c.group_units { u = 0 }
	for &it in l.items { if it.group >= 0 { c.group_units[it.group] += item_units(&it) } }
	for g := len(l.groups) - 1; g >= 0; g -= 1 {
		p := l.groups[g].parent
		if p != lay.NONE && c.group_units[g] > 0 { c.group_units[p] += 1 }
	}
}

// Between passes: paint values that changed (a refresh re-pointed styles, animated elements, decorations, the canvas
// background, clip radii) make their chunks record again.
@(private = "file")
check_paint_values :: proc(c: ^Comp, l: ^Layout) {
	chain := make([dynamic]i32, 0, 8, context.temp_allocator)
	cache := make(map[^style.Computed]u64, 64, context.temp_allocator)
	check :: proc(c: ^Comp, l: ^Layout, i: int, cache: ^map[^style.Computed]u64, chain: ^[dynamic]i32) {
		if i < 0 || i >= len(l.items) || i >= len(c.item_hash) { return }
		it := &l.items[i]
		h := item_hash(c, l, it, cache, chain)
		c.item_cs[i] = it.cs
		if h == c.item_hash[i] { return }
		c.item_hash[i] = h
		ch := &c.chunks[c.item_chunk[i]]
		ch.recorded = false
		ch.sig = chunk_sig(c, ch.first, ch.end, ch.immediate)
	}
	if l.restyled != c.seen_restyled {
		c.seen_restyled = l.restyled
		for &it, i in l.items { if it.cs != c.item_cs[i] { check(c, l, i, &cache, &chain) } }
	}
	// animation overlays are rewritten in place (same records): their items, when the timeline moved a recorded value
	if st := (^style.Styled)(l.styled); st != nil && len(st.overlaid) > 0 && !style.ps_empty(style.ps_intersect(st.animated, raster_props())) {
		if !c.node_items_ok { node_items_make(c, l) }
		for h in st.overlaid {
			if list, ok := c.node_items[h]; ok { for i in list { check(c, l, int(i), &cache, &chain) } }
		}
	}
	// decoration colors follow their box (refresh rewrites them)
	if len(c.deco_colors) == len(l.deco_items) {
		for i, k in l.deco_items {
			if l.items[i].deco_color == c.deco_colors[k] { continue }
			c.deco_colors[k] = l.items[i].deco_color
			check(c, l, int(i), &cache, &chain)
		}
	}
	for i in l.canvas_items { check(c, l, int(i), &cache, &chain) }
	// a clip radius moved (border-radius animation): the chunks that hold the clip
	changed := false
	for &cl, k in l.clips {
		if k < len(c.clip_radii) && cl.radii != c.clip_radii[k] { changed = true; break }
	}
	if !changed { return }
	for &ch in c.chunks {
		for ci in ch.clips { if l.clips[ci].radii != c.clip_radii[ci] { ch.recorded = false; break } }
	}
	for &cl, k in l.clips { if k < len(c.clip_radii) { c.clip_radii[k] = cl.radii } }
}

////////////////////////////////
// Recording and replay

// W_root^-1 * W_s: where space s lies in the picture of a chunk recorded in `root`'s coordinates.
@(private)
slot_matrix :: proc(v: ^lay.View, root, s: i32) -> draw.Affine {
	wr := lay.space_world(v, root)   // a translation (document, fixed)
	ws := lay.space_world(v, s)
	m := ws
	m[4] -= wr[4]
	m[5] -= wr[5]
	return draw.Affine{m[0], m[1], m[2], m[3], m[4], m[5]}
}

@(private = "file")
Recorder :: struct {
	c:     ^Comp,
	l:     ^Layout,
	dc:    ^draw.Context,
	v:     ^lay.View,
	ch:    ^Comp_Chunk,
	pushed: u32,              // slot pushed on the transform stack (0: the picture's own space)
	chain: [dynamic]i32,      // clips pushed
}

@(private = "file")
slot_of :: proc(r: ^Recorder, s: i32) -> u32 {
	if s == r.ch.root { return 0 }
	for b in r.ch.slots { if b.space == s { return b.slot } }
	// new slots are made at the picture's own level (all slots are relative to it)
	if r.pushed != 0 { draw.pop_transform(r.dc); r.pushed = 0 }
	draw.push_transform(r.dc, slot_matrix(r.v, r.ch.root, s))
	k := draw.current_slot(r.dc)
	draw.pop_transform(r.dc)
	append(&r.ch.slots, Slot_Bind{space = s, key = lay.space_key(r.l, s), slot = k})
	return k
}

@(private = "file")
enter :: proc(r: ^Recorder, s: i32) {
	k := slot_of(r, s)
	if k == r.pushed { return }
	if r.pushed != 0 { draw.pop_transform(r.dc) }
	if k != 0 { draw.push_slot(r.dc, k) }
	r.pushed = k
}

@(private = "file")
record_chunk :: proc(c: ^Comp, l: ^Layout, dc: ^draw.Context, d: ^dom.Document, v: ^lay.View, ch: ^Comp_Chunk, raster_scale: f32) {
	if ch.pic == nil { ch.pic = len(c.pool) > 0 ? pop(&c.pool) : new(draw.Picture) }
	clear(&ch.slots)
	r := Recorder{c = c, l = l, dc = dc, v = v, ch = ch, chain = make([dynamic]i32, 0, 8, context.temp_allocator)}
	want := make([dynamic]i32, 0, 8, context.temp_allocator)
	draw.picture_begin(dc, ch.pic, raster_scale)
	for i in ch.first ..< ch.end {
		it := &l.items[i]
		local := local_clips(c, l, it, &want)
		keep := 0
		for keep < len(local) && keep < len(r.chain) && local[keep] == r.chain[keep] { keep += 1 }
		for len(r.chain) > keep { draw.pop_clip(dc); pop(&r.chain) }
		for ci in local[keep:] {
			cl := &l.clips[ci]
			enter(&r, cl.space)
			rect := draw.Rect{cl.rect.min, cl.rect.max}
			if cl.radii == {} { draw.push_clip(dc, rect) } else { draw.push_clip_rounded(dc, rect, cl.radii) }
			append(&r.chain, ci)
		}
		enter(&r, it.space)
		paint_item(l, dc, d, v, it, draw.Rect{it.rect.min, it.rect.max}, {}, {})
	}
	for len(r.chain) > 0 { draw.pop_clip(dc); pop(&r.chain) }
	if r.pushed != 0 { draw.pop_transform(dc) }
	draw.picture_end(dc)
	ch.recorded = true
	composite_stats.recorded += 1
}

// Group bounds (screen) and units for the effects code, from the chunks of this frame.
@(private = "file")
plan :: proc(c: ^Comp, e: ^Effects) -> []Group_Paint {
	l := e.l
	gp := make([]Group_Paint, len(l.groups), context.temp_allocator)
	for &ch in c.chunks {
		if ch.group < 0 || !ch.visible { continue }
		p := &gp[ch.group]
		p.bounds = p.seen ? lay.rect_union(p.bounds, ch.screen) : ch.screen
		p.seen = true
	}
	for g := len(gp) - 1; g >= 0; g -= 1 {
		gp[g].units = c.group_units[g]
		parent := l.groups[g].parent
		if parent == lay.NONE || !gp[g].seen { continue }
		o := group_outset(e, i32(g))
		b := lay.Rect{gp[g].bounds.min - {o[0], o[1]}, gp[g].bounds.max + {o[2], o[3]}}
		p := &gp[parent]
		p.bounds = p.seen ? lay.rect_union(p.bounds, b) : b
		p.seen = true
	}
	return gp
}

// Paints the page through its retained pictures. false: not possible (too many chunks): paint directly.
composite_paint :: proc(l: ^Layout, dc: ^draw.Context, d: ^dom.Document, origin, size: draw.Vec2, scroll: f32) -> bool {
	c := comp_of(l)
	c.doc = d
	c.dc = dc
	composite_stats = {}
	draw.set_retained_budget(dc, compositor_settings.memory)
	c.frame += 1
	passes := l.passes[.Full] + l.passes[.Incremental]
	// laid out again frame after frame (a resize, an animation of a layout property): recording would cost more than
	// drawing. Drawn directly until no layout pass came for settle_ms (a time, not a number of frames: the same at any
	// frame rate), then what changed is recorded.
	now := pacer.frame_ms
	busy := now - c.pass_ms < compositor_settings.settle_ms
	if passes != c.last_passes {
		c.last_passes = passes
		c.pass_ms = now
	}
	if passes != c.seen_passes || c.items_len != len(l.items) || c.chunk_items != max(compositor_settings.chunk_items, (len(l.items) + compositor_settings.max_chunks - 1) / max(compositor_settings.max_chunks, 1)) {
		if busy { return false }
		c.seen_passes, c.seen_refresh, c.seen_restyled = passes, l.passes[.Refresh], l.restyled
		rebuild(c, l)
	} else if l.passes[.Refresh] != c.seen_refresh || l.restyled != c.seen_restyled {
		c.seen_refresh = l.passes[.Refresh]
		check_paint_values(c, l)
	}
	if c.direct { return false }
	// the selection and find highlights are recorded with the text: a change records the chunks again (lazily, as they show)
	if k := selection_paint_key(); k != c.sel_key {
		c.sel_key = k
		for &ch in c.chunks { if !ch.immediate { ch.recorded = false } }
	}
	v := lay.view_make(l, size, scroll, cull = false)
	screen := lay.Rect{origin, origin + size}
	shift := lay.Matrix{1, 0, 0, 1, origin.x, origin.y}
	composite_stats.chunks = len(c.chunks)
	for &ch in c.chunks {
		ch.visible = false
		first := true
		for b in ch.bounds {
			if v.singular[b.space] { continue }
			r := lay.mat_bounds(lay.mat_mul(shift, lay.space_world(&v, b.space)), b.r)
			ch.screen = first ? r : lay.rect_union(ch.screen, r)
			first = false
		}
		// filters of the groups around it spread what it paints (blur, drop shadows): it may show from further away
		reach: f32 = ch.group != lay.NONE ? l.groups[ch.group].reach : 0
		ch.visible = !first && !lay.rect_empty(lay.rect_intersect(lay.Rect{ch.screen.min - reach, ch.screen.max + reach}, screen))
		if ch.visible { composite_stats.visible += 1 }
	}
	e := Effects{l = l, v = &v, dc = dc, origin = origin, xform = lay.NONE, clip = -2, group = -2,
		chain = make([dynamic]i32, 0, 8, context.temp_allocator), open = make([dynamic]Open_Group, 0, 4, context.temp_allocator)}
	e.groups = plan(c, &e)
	// kept effect results: what the groups' layers and the backdrops would receive (effects_cache.odin)
	fxc: Fx_Cache
	fx_cache_begin(&fxc, c, &e, screen)
	e.fxc = &fxc
	for &ch in c.chunks {
		if !ch.visible { continue }
		if ch.immediate {
			for i in ch.first ..< ch.end {
				it := &l.items[i]
				if lay.rect_empty(lay.rect_intersect(item_ink(&e, it), screen)) { continue }
				if !effects_for(&e, it) { continue }
				fx_cache_under(&e, nil, item = i)
				if fx_cache_skipping(&e) { continue }
				off := v.offsets[it.space] + origin
				paint_item(l, dc, d, &v, it, draw.Rect{it.rect.min + off, it.rect.max + off}, off, origin)
				composite_stats.immediate_items += 1
			}
			continue
		}
		root := lay.space_world(&v, ch.root)
		m := draw.Affine{1, 0, 0, 1, root[4] + origin.x, root[5] + origin.y}
		if !ch.recorded { record_chunk(c, l, dc, d, &v, &ch, 1) }
		// the space matrices of this frame (scroll offsets, sticky shifts, transforms)
		for b in ch.slots {
			draw.picture_set_slot(ch.pic, b.slot, slot_matrix(&v, ch.root, b.space))
			composite_stats.slots_set += 1
		}
		set_group(&e, ch.group)
		pop_chain_to(&e, clip_floor(&e))
		e.clip = -2   // the next item re-pushes its own clips
		set_xform(&e, lay.NONE)
		fx_cache_under(&e, &ch)
		if fx_cache_skipping(&e) { continue }   // a kept result of its group stands for it
		res := draw.replay(dc, ch.pic, m)
		if res == .Stale {
			// glyphs at another size, or the atlas was reset: record again at this scale
			record_chunk(c, l, dc, d, &v, &ch, math.sqrt(abs(root[0] * root[3] - root[1] * root[2])))
			res = draw.replay(dc, ch.pic, m)
		}
		if res == .Drawn { composite_stats.replayed += 1 }
	}
	effects_end(&e)
	return true
}

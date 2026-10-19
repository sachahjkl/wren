package browser

import "toolkit:draw"
import "toolkit:font"
import lay "wb:layout"
import "wb:style"

////////////////////////////////
// Masks (CSS Masking 1 §7) and background-clip: text, on the toolkit's masked layers (draw.push_mask).
//
// mask-image: the element's group (a stacking context) is drawn into a layer like a filter group; when the group
// closes, its mask layers are drawn after the content, bottom layer first, each one positioned, sized, repeated and
// clipped like a background layer against the element's boxes (mask-origin, mask-clip; no-clip covers the layer), its
// coverage the alpha or the luminance (mask-mode) composited with the layers below (mask-composite). Then the layer
// goes through the group's filters, opacity and blend mode. Hit testing ignores masks, as in browsers.
//
// background-clip: text: the background layers clipped to text (and the background color when the bottom layer is),
// are drawn into a masked layer whose mask is the text of the element and of its descendants, drawn in white at the
// places and with the shaping of its display items (decorations and shadows excluded). Such a box is drawn directly
// by the compositor (its text may come from items of other chunks).

// Mask layers of a group, drawn when it closes (`og.mask`): `b` is the group's box, its space's offset `off`.
@(private)
paint_mask_layers :: proc(e: ^Effects, b: ^lay.Box, off: draw.Vec2) {
	l := e.l
	cs := b.cs
	dc := e.dc
	border := draw.Rect{b.abs + off, b.abs + b.size + off}
	radii := lay.border_radii(cs, b.size.x, b.size.y, l.scale)
	boxes := bg_boxes(border, radii, {b.border[0], b.border[1], b.border[2], b.border[3]}, b.padding)
	layers := style.mask_layers(cs)
	for i := len(layers) - 1; i >= 0; i -= 1 {
		ml := &layers[i]
		mode := draw.Mask_Mode.Alpha
		if ml.mode == .Luminance { mode = .Luminance }
		draw.mask_layer(dc, mode, draw.Mask_Op(ml.composite))
		if ml.image.kind == .None { continue }   // a transparent layer
		bg := style.Bg_Layer{image = ml.image, repeat = ml.repeat, position = ml.position, size = ml.size}
		pos_area, _ := area_of(&boxes, mask_area(ml.origin))
		clip, clip_radii := area_of(&boxes, mask_area(ml.clip))
		if ml.clip == .No_Clip {
			// the whole layer: as far as the content can reach
			clip, clip_radii = draw.rect_pad(border, max(border.max.x - border.min.x, border.max.y - border.min.y) + 4096), {}
		}
		paint_image_layer(dc, &bg, pos_area, clip, clip_radii, l.scale)
	}
}

@(private)
mask_area :: proc(m: style.Mask_Box) -> style.Box_Area {
	switch m {
	case .Border_Box, .No_Clip: return .Border_Box
	case .Padding_Box: return .Padding_Box
	case .Content_Box: return .Content_Box
	}
	return .Border_Box
}

// Whether a box clips one of its background layers to text.
background_clips_text :: proc(cs: ^style.Computed) -> bool {
	if cs == nil { return false }
	for c in cs.background_clips { if c == .Text { return true } }
	return false
}

// The backgrounds of a box with background-clip: text in some layer (paint_box, paint_inline_box). Layers are drawn
// bottom first; each run of consecutive text-clipped layers is one masked layer.
@(private)
paint_backgrounds_text :: proc(l: ^Layout, dc: ^draw.Context, v: ^lay.View, it: ^lay.Display_Item, b: ^Bg_Boxes, origin: draw.Vec2) {
	cs := it.cs
	layers := style.background_layers(cs)
	n := len(layers)
	open := false
	open_mask :: proc(dc: ^draw.Context, b: ^Bg_Boxes) {
		draw.push_mask(dc, draw.rect_pad(b.border, 2), draw.Layer_Effects{alpha = 1})
	}
	close_mask :: proc(l: ^Layout, dc: ^draw.Context, v: ^lay.View, it: ^lay.Display_Item, origin: draw.Vec2) {
		draw.mask_layer(dc, .Alpha, .Add)
		paint_text_mask(l, dc, v, it, origin)
		draw.pop_mask(dc)
	}
	if cs.background_color.a > 0 {
		bottom := layers[n - 1].clip
		col := to_draw(cs.background_color)
		if bottom == .Text {
			open_mask(dc, b)
			open = true
			draw.rect(dc, b.border, col)
		} else {
			clip, radii := area_of(b, bottom)
			draw.rect_corners(dc, clip, {col, col, col, col}, radii)
		}
	}
	for i := n - 1; i >= 0; i -= 1 {
		layer := &layers[i]
		text := layer.clip == .Text
		if text && !open { open_mask(dc, b); open = true }
		if !text && open { close_mask(l, dc, v, it, origin); open = false }
		pos_area, _ := area_of(b, layer.origin)
		clip, radii := area_of(b, text ? .Border_Box : layer.clip)
		paint_image_layer(dc, layer, pos_area, clip, radii, l.scale)
	}
	if open { close_mask(l, dc, v, it, origin) }
}

// The text of the box of `it` and of its descendants, in white, as the mask of background-clip: text.
@(private)
paint_text_mask :: proc(l: ^Layout, dc: ^draw.Context, v: ^lay.View, it: ^lay.Display_Item, origin: draw.Vec2) {
	white := draw.Color{1, 1, 1, 1}
	own_xf := l.spaces[it.space].xform
	for j in text_clip_items(l, it) {
		ti := &l.items[j]
		fi := lay.item_font(l, ti)
		if ti.cs == nil || fi == nil || ti.text == "" { continue }
		// a descendant in another transformed space would need that transform: drawn only in the box's own
		if l.spaces[ti.space].xform != own_xf { continue }
		off := v.offsets[ti.space] + origin
		opts := text_shape_options(l, ti.cs, ti.level, ti.extra)
		sh := font.shape(dc.fonts, font.Font_Id(fi.font), fi.size, ti.text, opts, context.temp_allocator)
		draw.glyph_run(dc, fi.size, {ti.rect.min.x + off.x, ti.baseline + off.y}, white, sh.glyphs)
	}
}

// The Text items of the box of `it` and of its descendants (kept per layout until its display list changes).
@(private)
Text_Clip_Cache :: struct {
	key:   [3]u64,
	boxes: map[i32][dynamic]i32,
}

@(private, thread_local) text_clip_caches: map[^Layout]^Text_Clip_Cache

@(private)
text_clip_items :: proc(l: ^Layout, it: ^lay.Display_Item) -> []i32 {
	key := [3]u64{l.passes[.Full] + l.passes[.Incremental], u64(len(l.items)), u64(l.inc.dl_gen)}
	tc := text_clip_caches[l]
	if tc == nil {
		tc = new(Text_Clip_Cache)
		text_clip_caches[l] = tc
	}
	if tc.key != key {
		for _, list in tc.boxes { delete(list) }
		clear(&tc.boxes)
		tc.key = key
	}
	if list, ok := tc.boxes[it.box]; ok { return list[:] }
	list := make([dynamic]i32)
	for &ti, j in l.items {
		if ti.kind != .Text { continue }
		for p := ti.box; p != lay.NONE; p = l.boxes[p].parent {
			if p == it.box { append(&list, i32(j)); break }
		}
	}
	tc.boxes[it.box] = list
	return list[:]
}

// Frees what text_clip_items kept for a layout (layout_reset / layout_destroy).
@(private)
text_clip_forget :: proc(l: ^Layout) {
	tc, ok := text_clip_caches[l]
	if !ok { return }
	for _, list in tc.boxes { delete(list) }
	delete(tc.boxes)
	free(tc)
	delete_key(&text_clip_caches, l)
	if len(text_clip_caches) == 0 { delete(text_clip_caches); text_clip_caches = nil }
}

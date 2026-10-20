package style

import "base:runtime"
import "core:strings"
import "wb:css"

// CSS Masking 1 §7 (mask layers) and -webkit-text-fill-color.
//
// mask-image, mask-mode, mask-repeat, mask-position, mask-size, mask-origin, mask-clip and mask-composite are lists
// like the background ones (the number of layers is the number of images; shorter lists repeat): `mask_layers`
// applies the repetition. The `mask` shorthand and every `-webkit-mask-*` alias map to them; -webkit-mask-composite's
// Porter-Duff keywords (source-over, source-in, source-out, xor) map to the standard operators. A mask applies when
// one layer has an image (`mask-image: none` everywhere = no mask); a `none` layer among others is transparent.
// -webkit-text-fill-color (inherited) paints the glyphs instead of `color` (currentcolor = follow `color`).

Mask_Mode :: enum u8 { Match_Source, Alpha, Luminance }
Mask_Composite :: enum u8 { Add, Subtract, Intersect, Exclude }
// The geometry boxes of mask-origin and mask-clip (SVG ones map as for HTML elements: fill-box to the content box,
// stroke-box and view-box to the border box); No_Clip is mask-clip only.
Mask_Box :: enum u8 { Border_Box, Padding_Box, Content_Box, No_Clip }

// One mask layer with the list repetition applied. Layer 0 is on top.
Mask_Layer :: struct {
	image:     Image,
	mode:      Mask_Mode,
	repeat:    [2]Repeat,
	position:  [2]Length,
	size:      Bg_Size,
	origin:    Mask_Box,
	clip:      Mask_Box,
	composite: Mask_Composite,
}

@(private) MASK_MODES_INITIAL := [1]Mask_Mode{.Match_Source}
@(private) MASK_BOXES_INITIAL := [1]Mask_Box{.Border_Box}
@(private) MASK_COMPOSITES_INITIAL := [1]Mask_Composite{.Add}

@(private)
masks_initial :: proc(c: ^Computed) {
	c.mask_images = NO_IMAGES[:]
	c.mask_modes = MASK_MODES_INITIAL[:]
	c.mask_repeats = REPEATS[:]
	c.mask_positions = ORIGIN_POSITIONS[:]
	c.mask_sizes = AUTO_SIZES[:]
	c.mask_origins = MASK_BOXES_INITIAL[:]
	c.mask_clips = MASK_BOXES_INITIAL[:]
	c.mask_composites = MASK_COMPOSITES_INITIAL[:]
	c.text_fill_color = Auto_Color{auto = true}
}

// Whether an element is masked: one of its mask layers has an image.
has_mask :: proc(c: ^Computed) -> bool {
	if c == nil { return false }
	for im in c.mask_images { if im.kind != .None { return true } }
	return false
}

// Every mask layer of `c` (see the package comment above). Layer 0 is on top.
mask_layers :: proc(c: ^Computed, allocator := context.temp_allocator) -> []Mask_Layer {
	n := max(len(c.mask_images), 1)
	out := make([]Mask_Layer, n, allocator)
	pick :: proc(list: []$T, i: int, fallback: T) -> T { return len(list) == 0 ? fallback : list[i % len(list)] }
	for i in 0 ..< n {
		out[i] = Mask_Layer{
			image = pick(c.mask_images, i, Image{}),
			mode = pick(c.mask_modes, i, Mask_Mode.Match_Source),
			repeat = pick(c.mask_repeats, i, [2]Repeat{.Repeat, .Repeat}),
			position = pick(c.mask_positions, i, [2]Length{pct(0), pct(0)}),
			size = pick(c.mask_sizes, i, Bg_Size{}),
			origin = pick(c.mask_origins, i, Mask_Box.Border_Box),
			clip = pick(c.mask_clips, i, Mask_Box.Border_Box),
			composite = pick(c.mask_composites, i, Mask_Composite.Add),
		}
	}
	return out
}

// The color glyphs are painted in: -webkit-text-fill-color, else `color`.
text_fill :: #force_inline proc(c: ^Computed) -> css.Color {
	return c.text_fill_color.auto ? c.color : c.text_fill_color.color
}

@(private)
mask_box_of :: proc(v: []css.Value, allow_no_clip: bool) -> (Mask_Box, bool) {
	id, ok := ident_raw(v)
	if !ok { return {}, false }
	switch css.lower_temp(id) {
	case "border-box", "stroke-box", "view-box", "border": return .Border_Box, true
	case "padding-box", "padding": return .Padding_Box, true
	case "content-box", "fill-box", "content": return .Content_Box, true
	case "no-clip": if allow_no_clip { return .No_Clip, true }
	}
	return {}, false
}

@(private)
mask_composite_of :: proc(v: []css.Value) -> (Mask_Composite, bool) {
	id, ok := ident_raw(v)
	if !ok { return {}, false }
	switch css.lower_temp(id) {
	case "add", "source-over": return .Add, true
	case "subtract", "source-out": return .Subtract, true
	case "intersect", "source-in": return .Intersect, true
	case "exclude", "xor": return .Exclude, true
	}
	return {}, false
}

// One of the mask longhands, or -webkit-text-fill-color.
@(private)
apply_mask_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
	#partial switch p {
	case .Mask_Image:
		list := make([]Image, len(parts), cx.alloc)
		for part, i in parts {
			img, ok := parse_image(cx, part)
			if !ok { return false }
			list[i] = img
		}
		c.mask_images = list
	case .Mask_Mode:
		list := make([]Mask_Mode, len(parts), cx.alloc)
		for part, i in parts { if !set_enum(part, &list[i]) { return false } }
		c.mask_modes = list
	case .Mask_Repeat:
		list := make([][2]Repeat, len(parts), cx.alloc)
		for part, i in parts {
			r, ok := parse_bg_repeat(part)
			if !ok { return false }
			list[i] = r
		}
		c.mask_repeats = list
	case .Mask_Position:
		list := make([][2]Length, len(parts), cx.alloc)
		for part, i in parts {
			pos, ok := parse_position(cx, part)
			if !ok { return false }
			list[i] = pos
		}
		c.mask_positions = list
	case .Mask_Size:
		list := make([]Bg_Size, len(parts), cx.alloc)
		for part, i in parts {
			sz, ok := parse_bg_size(cx, part)
			if !ok { return false }
			list[i] = sz
		}
		c.mask_sizes = list
	case .Mask_Origin, .Mask_Clip:
		list := make([]Mask_Box, len(parts), cx.alloc)
		for part, i in parts {
			b, ok := mask_box_of(part, p == .Mask_Clip)
			if !ok { return false }
			list[i] = b
		}
		if p == .Mask_Origin { c.mask_origins = list } else { c.mask_clips = list }
	case .Mask_Composite:
		list := make([]Mask_Composite, len(parts), cx.alloc)
		for part, i in parts {
			op, ok := mask_composite_of(part)
			if !ok { return false }
			list[i] = op
		}
		c.mask_composites = list
	case .Text_Fill_Color:
		if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "currentcolor") { c.text_fill_color = Auto_Color{auto = true}; return true }
		col, ok := parse_color(cx, vs)
		if !ok { return false }
		c.text_fill_color = Auto_Color{color = col}
		ps_add(&cx.explicit, p)
	case: return false
	}
	return true
}

// mask: <mask-layer>#, each `<image> || <position> [/ <bg-size>]? || <repeat-style> || <geometry-box> ||
// [<geometry-box> | no-clip] || <compositing-operator> || <masking-mode>` (one box: origin and clip).
@(private)
expand_mask :: proc(input: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(input), a)
	if len(layers) == 0 { return nil, false }
	n := len(layers)
	images := make([][]css.Value, n, a)
	modes := make([][]css.Value, n, a)
	repeats := make([][]css.Value, n, a)
	positions := make([][]css.Value, n, a)
	sizes := make([][]css.Value, n, a)
	origins := make([][]css.Value, n, a)
	clips := make([][]css.Value, n, a)
	composites := make([][]css.Value, n, a)
	for layer, k in layers {
		items := split_items(layer, a)
		if len(items) == 0 { return nil, false }
		image, mode, composite: []css.Value
		repeat := make([dynamic]css.Value, a)
		pos := make([dynamic]css.Value, a)
		size := make([dynamic]css.Value, a)
		boxes := make([dynamic]css.Value, a)
		in_size := false
		for it, i in items {
			if is_delim(it, "/") {
				if in_size || len(pos) == 0 { return nil, false }
				in_size = true
				continue
			}
			one := items[i:i + 1]
			#partial switch it.kind {
			case .Function:
				if css.is_math_function(it.tok.text) { append(in_size ? &size : &pos, it); continue }
				if image != nil { return nil, false }
				image = one
			case .Token:
				#partial switch it.tok.kind {
				case .Url:
					if image != nil { return nil, false }
					image = one
				case .Dimension, .Percentage, .Number: append(in_size ? &size : &pos, it)
				case .Ident:
					id := css.lower_temp(it.tok.text)
					switch id {
					case "none":
						if image != nil { return nil, false }
						image = one
					case "repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round": append(&repeat, it)
					case "border-box", "padding-box", "content-box", "fill-box", "stroke-box", "view-box", "no-clip", "border", "padding", "content": append(&boxes, it)
					case "add", "subtract", "intersect", "exclude":
						if composite != nil { return nil, false }
						composite = one
					case "alpha", "luminance", "match-source":
						if mode != nil { return nil, false }
						mode = one
					case "left", "right", "top", "bottom", "center":
						if in_size { return nil, false }
						append(&pos, it)
					case "auto", "cover", "contain":
						if !in_size { return nil, false }
						append(&size, it)
					case: return nil, false
					}
				case: return nil, false
				}
			case: return nil, false
			}
		}
		if len(boxes) > 2 || len(repeat) > 2 { return nil, false }
		images[k] = image != nil ? image : idents(a, "none")
		modes[k] = mode != nil ? mode : idents(a, "match-source")
		repeats[k] = len(repeat) > 0 ? join_items(repeat[:], a) : idents(a, "repeat")
		positions[k] = len(pos) > 0 ? join_items(pos[:], a) : join_items(([]css.Value{{kind = .Token, tok = {kind = .Percentage}}, {kind = .Token, tok = {kind = .Percentage}}}), a)
		sizes[k] = len(size) > 0 ? join_items(size[:], a) : idents(a, "auto")
		switch len(boxes) {
		case 0: origins[k], clips[k] = idents(a, "border-box"), idents(a, "border-box")
		case 1:
			origins[k], clips[k] = boxes[0:1], boxes[0:1]
			if is_ident(boxes[0], "no-clip") { origins[k] = idents(a, "border-box") }
		case:
			if is_ident(boxes[0], "no-clip") { return nil, false }
			origins[k], clips[k] = boxes[0:1], boxes[1:2]
		}
		composites[k] = composite != nil ? composite : idents(a, "add")
	}
	res := make([dynamic]Longhand, a)
	append(&res, Longhand{.Mask_Image, comma_join(images, a)})
	append(&res, Longhand{.Mask_Mode, comma_join(modes, a)})
	append(&res, Longhand{.Mask_Repeat, comma_join(repeats, a)})
	append(&res, Longhand{.Mask_Position, comma_join(positions, a)})
	append(&res, Longhand{.Mask_Size, comma_join(sizes, a)})
	append(&res, Longhand{.Mask_Origin, comma_join(origins, a)})
	append(&res, Longhand{.Mask_Clip, comma_join(clips, a)})
	append(&res, Longhand{.Mask_Composite, comma_join(composites, a)})
	return res[:], true
}

// Names: the prefixed aliases, and -webkit-text-fill-color (which has no unprefixed name).
@(private)
mask_names :: proc() {
	for name in ([?]string{"mask", "mask-image", "mask-mode", "mask-repeat", "mask-position", "mask-size", "mask-origin", "mask-clip", "mask-composite"}) {
		alias_by_name[strings.concatenate({"-webkit-", name})] = name
	}
	alias_by_name["-webkit-mask-source-type"] = "mask-mode"
	delete_key(&prop_by_name, prop_names[.Text_Fill_Color])
	prop_names[.Text_Fill_Color] = "-webkit-text-fill-color"
	prop_by_name["-webkit-text-fill-color"] = .Text_Fill_Color
}

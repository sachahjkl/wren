package layout

import "base:runtime"
import "core:math"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

// State of one layout pass. Everything allocated for the pass alone uses the temp allocator or the Layout's arena.
@(private)
Ctx :: struct {
	l:        ^Layout,
	d:        ^dom.Document,
	st:       ^style.Styled,
	set:      ^Settings,
	text:     Text_Api,
	replaced: Replaced_Api,
	scale:    f32,
	vp:       Vec2,
	sa:       runtime.Allocator,          // the layout's arena: strings that live as long as the layout
	font_cache: map[Font_Key]i32,
	last_key: Font_Key,
	last_fi:  i32,
	anon_cs:  map[Anon_Key]^style.Computed,
	counters: map[base.Handle]List_Counter,
	quote_depth: int,
	stack_base: uintptr,
	stack_limit: int,
	root_el, body_el: base.Handle,
	lb_bufs:  [dynamic]^LB_Buffers,     // line building buffers per nesting level of inline formatting contexts
	lb_depth: int,
}

@(private)
Font_Key :: struct {
	families: rawptr,
	n:        int,
	weight:   u16,
	italic:   bool,
	size:     f32,
	lh_kind:  style.Line_Height_Kind,
	lh:       f32,
}

@(private)
Anon_Key :: struct { parent: ^style.Computed, display: style.Display }

@(private)
List_Counter :: struct { next, step: i32 }

// Native stack in use by this pass; recursive steps stop descending when it nears the limit.
@(private)
stack_ok :: proc(c: ^Ctx) -> bool {
	marker: u8
	used := int(c.stack_base) - int(uintptr(&marker))
	return used < c.stack_limit
}

@(private)
box_of_idx :: #force_inline proc(c: ^Ctx, i: i32) -> ^Box { return &c.l.boxes[i] }

////////////////////////////////
// Lengths: computed values are CSS px (or percentages); layout works in device px

// `base` is the percentage base in device px; auto and the keywords resolve to `fallback`.
@(private)
px_of :: proc(c: ^Ctx, l: style.Length, base: f32, fallback: f32 = 0) -> f32 {
	#partial switch l.kind {
	case .Px: return l.v * c.scale
	case .Percent: return base < 0 ? fallback : base * l.v / 100
	case .Calc:
		b := base < 0 ? 0 : base
		return f32(css.eval_calc(l.calc, css.Length_Context{percent_base = f64(b / c.scale)})) * c.scale
	}
	return fallback
}

// A length that has a definite value against `base` (base < 0: the percentage base is indefinite).
@(private)
definite :: proc(c: ^Ctx, l: style.Length, base: f32) -> (f32, bool) {
	#partial switch l.kind {
	case .Px: return l.v * c.scale, true
	case .Percent, .Calc:
		if base < 0 { return 0, false }
		return px_of(c, l, base), true
	}
	return 0, false
}

// Border widths snap to whole device pixels (never thinner than one) like every engine does.
@(private)
border_px :: proc(c: ^Ctx, w: f32) -> f32 {
	if w <= 0 { return 0 }
	return max(1, math.floor(w * c.scale + 0.001))
}

// Margins, borders and padding against the containing block's width.
@(private)
resolve_box_model :: proc(c: ^Ctx, b: ^Box, cb_w: f32) {
	cs := b.cs
	base := max(cb_w, 0)
	for s in style.Side {
		i := int(s)
		b.margin[i] = px_of(c, cs.margin[s], base)
		b.padding[i] = max(px_of(c, cs.padding[s], base), 0)
		b.border[i] = border_px(c, cs.border_width[s])
	}
	b.auto_t = cs.margin[.Top].kind == .Auto
	b.auto_r = cs.margin[.Right].kind == .Auto
	b.auto_b = cs.margin[.Bottom].kind == .Auto
	b.auto_l = cs.margin[.Left].kind == .Auto
	if b.kind == .Table && cs.border_collapse {
		// collapsed borders: the cells draw the grid; the table keeps its outer border
		for i in 0 ..< 4 { b.padding[i] = 0 }
	}
}

@(private) pb_w :: proc(b: ^Box) -> f32 { return b.padding[1] + b.padding[3] + b.border[1] + b.border[3] }
@(private) pb_h :: proc(b: ^Box) -> f32 { return b.padding[0] + b.padding[2] + b.border[0] + b.border[2] }
@(private) mg_w :: proc(b: ^Box) -> f32 { return b.margin[1] + b.margin[3] }
@(private) mg_h :: proc(b: ^Box) -> f32 { return b.margin[0] + b.margin[2] }
@(private) content_x :: proc(b: ^Box) -> f32 { return b.border[3] + b.padding[3] }
@(private) content_y :: proc(b: ^Box) -> f32 { return b.border[0] + b.padding[0] }

// A specified size converted to a border-box size. ok = false: auto, or a percentage of an indefinite base.
@(private)
to_border_w :: proc(c: ^Ctx, b: ^Box, l: style.Length, base: f32) -> (f32, bool) {
	v, ok := definite(c, l, base)
	if !ok { return 0, false }
	if b.cs.box_sizing == .Border_Box && b.kind != .Inline { return max(v, pb_w(b)), true }
	return max(v, 0) + pb_w(b), true
}

@(private)
to_border_h :: proc(c: ^Ctx, b: ^Box, l: style.Length, base: f32) -> (f32, bool) {
	v, ok := definite(c, l, base)
	if !ok { return 0, false }
	if b.cs.box_sizing == .Border_Box { return max(v, pb_h(b)), true }
	return max(v, 0) + pb_h(b), true
}

// min-width / max-width applied to a border-box width.
@(private)
clamp_w :: proc(c: ^Ctx, b: ^Box, w: f32, cb_w: f32) -> f32 {
	r := w
	if mx, ok := to_border_w(c, b, b.cs.max_width, cb_w); ok && b.cs.max_width.kind != .None { r = min(r, mx) }
	if mn, ok := to_border_w(c, b, b.cs.min_width, cb_w); ok { r = max(r, mn) }
	#partial switch b.cs.min_width.kind {
	case .Min_Content, .Fit_Content: r = max(r, intrinsic(c, b_index(c, b))[0])
	case .Max_Content: r = max(r, intrinsic(c, b_index(c, b))[1])
	}
	return max(r, pb_w(b))
}

@(private)
clamp_h :: proc(c: ^Ctx, b: ^Box, h: f32, cb_h: f32) -> f32 {
	r := h
	if b.cs.max_height.kind != .None {
		if mx, ok := to_border_h(c, b, b.cs.max_height, cb_h); ok { r = min(r, mx) }
	}
	if mn, ok := to_border_h(c, b, b.cs.min_height, cb_h); ok { r = max(r, mn) }
	return max(r, pb_h(b))
}

@(private)
b_index :: proc(c: ^Ctx, b: ^Box) -> i32 {
	return i32((uintptr(b) - uintptr(raw_data(c.l.boxes))) / size_of(Box))
}

////////////////////////////////
// Fonts

@(private)
font_info :: proc(c: ^Ctx, cs: ^style.Computed) -> i32 {
	key := Font_Key{
		families = raw_data(cs.font_family), n = len(cs.font_family), weight = cs.font_weight,
		italic = cs.font_style != .Normal, size = cs.font_size, lh_kind = cs.line_height.kind, lh = cs.line_height.v,
	}
	if c.last_fi >= 0 && key == c.last_key { return c.last_fi }
	if fi, ok := c.font_cache[key]; ok { c.last_key, c.last_fi = key, fi; return fi }
	info: Font_Info
	info.size = cs.font_size * c.scale
	info.font = c.text.font(c.text.user, cs.font_family, cs.font_weight, key.italic)
	m := c.text.metrics(c.text.user, info.font, info.size)
	info.ascent, info.descent, info.x_height = m.ascent, m.descent, m.x_height
	if info.x_height <= 0 { info.x_height = info.size * 0.5 }
	switch cs.line_height.kind {
	case .Normal: info.line_h = info.size * c.st.line_height_normal
	case .Number: info.line_h = info.size * cs.line_height.v
	case .Length: info.line_h = cs.line_height.v * c.scale
	}
	info.space = c.text.width(c.text.user, info.font, info.size, " ")
	fi := i32(len(c.l.fonts))
	append(&c.l.fonts, info)
	c.font_cache[key] = fi
	c.last_key, c.last_fi = key, fi
	return fi
}

@(private)
measure :: #force_inline proc(c: ^Ctx, fi: i32, s: string) -> f32 {
	f := &c.l.fonts[fi]
	return c.text.width(c.text.user, f.font, f.size, s)
}

////////////////////////////////
// Anonymous boxes inherit what is inherited and take initial values for the rest

@(private)
anon_style :: proc(c: ^Ctx, parent: ^style.Computed, display: style.Display) -> ^style.Computed {
	key := Anon_Key{parent, display}
	if s, ok := c.anon_cs[key]; ok { return s }
	s := new(style.Computed, c.sa)
	s^ = parent^
	for p in style.Prop {
		if !style.is_inherited(p) { style.copy_prop(s, c.st.initial, p) }
	}
	s.display = display
	s.node = base.NIL_HANDLE
	s.before, s.after = nil, nil
	// currentcolor of the initial border colors follows the inherited color
	for side in style.Side { s.border_color[side] = s.color }
	s.border_width = {}
	s.outline_width = 0
	s.text_decoration_color = s.color
	c.anon_cs[key] = s
	return s
}

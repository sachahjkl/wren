package style

import "core:reflect"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// CSS Anchor Positioning 1: the values. anchor-name, anchor-scope, position-anchor, position-area, position-try-fallbacks,
// position-try-order, position-visibility, the @position-try rules, and the lengths that hold anchor() or anchor-size()
// (Length_Kind.Anchor: a tree layout evaluates once the anchors are laid out, layout/anchor.odin).
//
// anchor() and anchor-size() mean something only on an absolutely positioned box: on any other box the value becomes its
// fallback when computed, or, without one, acts as `auto` (a Length of kind Anchor with no tree). A box that needs the late
// layout of layout/anchor.odin is told by `anchored_style`.

// Tactics written after one <dashed-ident> in position-try-fallbacks ("--foo flip-start flip-y").
TRY_TACTIC_MAX :: 5
// Options layout tries for one box, however many are written.
TRY_OPTIONS_MAX :: 64

Position_Anchor_Kind :: enum u8 { Normal, None, Auto, Name, Match_Parent }
Position_Anchor :: struct { kind: Position_Anchor_Kind, name: string }

Anchor_Scope :: struct { all: bool, names: []string }

// The keywords of position-area. None: the value `none`, or the second keyword left out.
Area_Keyword :: enum u8 {
	None, Center, Span_All,
	Left, Right, Span_Left, Span_Right, X_Start, X_End, Span_X_Start, Span_X_End,
	Self_X_Start, Self_X_End, Span_Self_X_Start, Span_Self_X_End,
	Top, Bottom, Span_Top, Span_Bottom, Y_Start, Y_End, Span_Y_Start, Span_Y_End,
	Self_Y_Start, Self_Y_End, Span_Self_Y_Start, Span_Self_Y_End,
	Block_Start, Block_End, Span_Block_Start, Span_Block_End,
	Inline_Start, Inline_End, Span_Inline_Start, Span_Inline_End,
	Self_Block_Start, Self_Block_End, Span_Self_Block_Start, Span_Self_Block_End,
	Self_Inline_Start, Self_Inline_End, Span_Self_Inline_Start, Span_Self_Inline_End,
	Start, End, Span_Start, Span_End,
	Self_Start, Self_End, Span_Self_Start, Span_Self_End,
}

// Canonical: what is written first when serialized, `b` None when left out.
Position_Area :: struct { a, b: Area_Keyword }

Try_Tactic :: enum u8 { Flip_Block, Flip_Inline, Flip_Start, Flip_X, Flip_Y }
Try_Order :: enum u8 { Normal, Most_Width, Most_Height, Most_Block_Size, Most_Inline_Size }

// What an @position-try rule, applied over the element's style, gives the properties a rule may set.
Try_Style :: struct {
	inset, margin: [Side]Length,
	width, height, min_width, min_height, max_width, max_height: Length,
	align_self, justify_self: Content_Align,
	position_anchor: Position_Anchor,
	position_area:   Position_Area,
}

// One entry of position-try-fallbacks.
Try_Option :: struct {
	name:    string,                        // <dashed-ident>, "" none
	tactics: [TRY_TACTIC_MAX]Try_Tactic,    // in the order written
	n_tactics: u8,
	area:    Position_Area,                 // a <position-area> instead (a.None: none)
	rule:    ^Try_Style,                    // the rule called `name`, over this element (try_options_resolve)
	missing: bool,                          // no such rule: the option is skipped
}

Visibility_Flag :: enum u8 { Anchor_Valid, Anchor_Visible, No_Overflow }
Position_Visibility :: bit_set[Visibility_Flag; u8]   // {}: always

// An @position-try rule of a stylesheet: its declarations, those a rule may have.
Try_Rule :: struct {
	decls: []Pre_Decl,
	layer: u32,
}

// The declarations @position-try keeps (CSS Anchor Positioning §position-try-rule: insets, margins, sizes, self-alignment,
// position-anchor and position-area).
@(private)
try_allowed :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Top, .Right, .Bottom, .Left, .Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left,
	     .Width, .Height, .Min_Width, .Min_Height, .Max_Width, .Max_Height,
	     .Align_Self, .Justify_Self, .Position_Anchor, .Position_Area:
		return true
	}
	return false
}

// A rule of a sheet: the one named goes to the rule set being compiled (a later rule, or one of a stronger layer, wins).
@(private)
try_rule_add :: proc(e: ^Engine, r: ^css.Rule, layer: u32) {
	decls, _ := compile_declarations(e, r.declarations, e.alloc)
	kept := make([dynamic]Pre_Decl, 0, len(decls), e.alloc)
	for d in decls { if try_allowed(d.prop) && !d.important { append(&kept, d) } }
	rs := e.cur
	if old, had := rs.try_rules[r.name]; had && old.layer > layer { return }
	t := new(Try_Rule, e.alloc)
	t^ = Try_Rule{decls = kept[:], layer = layer}
	if rs.try_rules == nil { rs.try_rules = make(map[string]^Try_Rule) }
	rs.try_rules[strings.clone(r.name, e.alloc)] = t
}

// A rule's cssText: the declarations it may have, in the order written.
@(private)
try_rule_text :: proc(e: ^Engine, r: ^css.Rule) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "@position-try ")
	strings.write_string(&sb, r.name)
	strings.write_string(&sb, " { ")
	for &d in r.declarations {
		one := [1]css.Declaration{d}
		decls, _ := compile_declarations(e, one[:], context.temp_allocator)
		allowed := len(decls) > 0
		for x in decls { if !try_allowed(x.prop) { allowed = false } }
		if !allowed || d.important { continue }
		strings.write_string(&sb, d.name)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, strings.trim_space(css.serialize_values(d.value, context.temp_allocator)))
		strings.write_string(&sb, "; ")
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

// The rule called `name` for element `h`: in the sheets of its tree, then those of the trees around it.
@(private)
try_rule_of :: proc(e: ^Engine, doc: ^dom.Document, h: base.Handle, name: string) -> ^Try_Rule {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(doc, cur)
		if n == nil { break }
		if n.is_shadow {
			if rs := shadow_set_of(e, cur); rs != nil {
				if t, ok := rs.try_rules[name]; ok { return t }
			}
			cur = n.shadow
			continue
		}
		cur = n.parent
	}
	if t, ok := e.rules.try_rules[name]; ok { return t }
	return nil
}

// Copies position-try-fallbacks with what each rule makes of this element's style (it may use var(), em...).
@(private)
try_options_resolve :: proc(cx: ^Cx, env: ^Var_Env, e: ^Engine, doc: ^dom.Document, h: base.Handle) {
	c := cx.c
	opts := make([]Try_Option, len(c.position_try_fallbacks), cx.alloc)
	copy(opts, c.position_try_fallbacks)
	c.position_try_fallbacks = opts
	for &o, i in opts {
		o.rule, o.missing = nil, false
		if o.name == "" { continue }
		if i >= TRY_OPTIONS_MAX { o.missing = true; continue }   // (layout tries no more)
		rule := try_rule_of(e, doc, h, o.name)
		if rule == nil { o.missing = true; continue }
		tmp := new(Computed, context.temp_allocator)
		tmp^ = c^
		sub := cx^
		sub.c = tmp
		for &d in rule.decls {
			vals := d.value
			if d.has_var {
				v, ok := substitute(env, vals, 0)
				if !ok { continue }
				vals = v
				if d.short != .None {
					longs, ok2 := expand_shorthand(d.short, vals, context.temp_allocator)
					found := false
					if ok2 { for l in longs { if l.prop == d.prop { vals = l.vals; found = true; break } } }
					if !found { continue }
				}
			}
			switch css_wide_keyword(vals) {
			case "inherit": copy_prop(tmp, cx.parent != nil ? cx.parent : cx.initial, d.prop)
			case "initial", "unset": copy_prop(tmp, cx.initial, d.prop)
			case "revert", "revert-layer":
			case: apply_prop(&sub, d.prop, vals)
			}
		}
		s := new(Try_Style, cx.alloc)
		s^ = try_style_of(tmp)
		o.rule = s
	}
}

try_style_of :: proc(c: ^Computed) -> Try_Style {
	return Try_Style{
		inset = c.inset, margin = c.margin, width = c.width, height = c.height, min_width = c.min_width, min_height = c.min_height,
		max_width = c.max_width, max_height = c.max_height, align_self = c.align_self, justify_self = c.justify_self,
		position_anchor = c.position_anchor, position_area = c.position_area,
	}
}

try_style_apply :: proc(c: ^Computed, s: Try_Style) {
	c.inset, c.margin = s.inset, s.margin
	c.width, c.height, c.min_width, c.min_height, c.max_width, c.max_height = s.width, s.height, s.min_width, s.min_height, s.max_width, s.max_height
	c.align_self, c.justify_self = s.align_self, s.justify_self
	c.position_anchor, c.position_area = s.position_anchor, s.position_area
}

////////////////////////////////
// Parsing

@(private)
dashed_ident :: proc(v: css.Value) -> (string, bool) {
	if v.kind != .Token || v.tok.kind != .Ident || !strings.has_prefix(v.tok.text, "--") || len(v.tok.text) <= 2 { return "", false }
	return v.tok.text, true
}

// A list of <dashed-ident> separated by commas.
@(private)
dashed_list :: proc(cx: ^Cx, vs: []css.Value) -> ([]string, bool) {
	parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
	names := make([]string, len(parts), cx.alloc)
	for part, i in parts {
		items := split_items(part)
		if len(items) != 1 { return nil, false }
		name, ok := dashed_ident(items[0])
		if !ok { return nil, false }
		names[i] = strings.clone(name, cx.alloc)
	}
	return names, len(names) > 0
}

@(private)
area_keyword :: proc(v: css.Value) -> (Area_Keyword, bool) {
	if v.kind != .Token || v.tok.kind != .Ident { return .None, false }
	id := css.lower_temp(v.tok.text)
	if id == "none" { return .None, false }
	names := reflect.enum_field_names(Area_Keyword)
	for n, i in names { if names_equal(id, n) { return Area_Keyword(i), true } }
	return .None, false
}

@(private)
Area_Class :: enum u8 { Neutral, Horizontal, Vertical, Block, Inline, Self_Block, Self_Inline, Logical, Self_Logical }

@(private)
area_class :: proc(k: Area_Keyword) -> Area_Class {
	switch k {
	case .None, .Center, .Span_All: return .Neutral
	case .Left, .Right, .Span_Left, .Span_Right, .X_Start, .X_End, .Span_X_Start, .Span_X_End, .Self_X_Start, .Self_X_End, .Span_Self_X_Start, .Span_Self_X_End: return .Horizontal
	case .Top, .Bottom, .Span_Top, .Span_Bottom, .Y_Start, .Y_End, .Span_Y_Start, .Span_Y_End, .Self_Y_Start, .Self_Y_End, .Span_Self_Y_Start, .Span_Self_Y_End: return .Vertical
	case .Block_Start, .Block_End, .Span_Block_Start, .Span_Block_End: return .Block
	case .Inline_Start, .Inline_End, .Span_Inline_Start, .Span_Inline_End: return .Inline
	case .Self_Block_Start, .Self_Block_End, .Span_Self_Block_Start, .Span_Self_Block_End: return .Self_Block
	case .Self_Inline_Start, .Self_Inline_End, .Span_Self_Inline_Start, .Span_Self_Inline_End: return .Self_Inline
	case .Start, .End, .Span_Start, .Span_End: return .Logical
	case .Self_Start, .Self_End, .Span_Self_Start, .Span_Self_End: return .Self_Logical
	}
	return .Neutral
}

// One or two keywords, in their canonical order (the first of each pair of axes first; `span-all` left out beside a keyword
// that says its axis).
@(private)
parse_position_area :: proc(items: []css.Value) -> (Position_Area, bool) {
	if len(items) == 0 || len(items) > 2 { return {}, false }
	a, ok := area_keyword(items[0])
	if !ok { return {}, false }
	if len(items) == 1 { return {a, .None}, true }
	b, ok2 := area_keyword(items[1])
	if !ok2 { return {}, false }
	ca, cb := area_class(a), area_class(b)
	if a == b {
		if ca == .Neutral || ca == .Logical || ca == .Self_Logical { return {a, .None}, true }
		return {}, false
	}
	if ca == .Neutral && cb == .Neutral { return {a, b}, true }
	if ca == .Neutral || cb == .Neutral {
		kw, other := ca == .Neutral ? b : a, ca == .Neutral ? a : b
		#partial switch area_class(kw) {
		case .Logical, .Self_Logical: return {a, b}, true   // both orders mean something: as written
		case .Horizontal, .Block, .Self_Block:
			if other == .Span_All { return {kw, .None}, true }
			return {kw, other}, true
		case:   // the second axis
			if other == .Span_All { return {kw, .None}, true }
			return {other, kw}, true
		}
	}
	switch {
	case ca == .Horizontal && cb == .Vertical, ca == .Block && cb == .Inline, ca == .Self_Block && cb == .Self_Inline: return {a, b}, true
	case ca == .Vertical && cb == .Horizontal, ca == .Inline && cb == .Block, ca == .Self_Inline && cb == .Self_Block: return {b, a}, true
	case ca == .Logical && cb == .Logical, ca == .Self_Logical && cb == .Self_Logical: return {a, b}, true
	}
	return {}, false
}

@(private)
parse_try_option :: proc(cx: ^Cx, part: []css.Value) -> (o: Try_Option, ok: bool) {
	items := split_items(part)
	if len(items) == 0 { return }
	if area, is_area := parse_position_area(items); is_area {
		o.area = area
		return o, true
	}
	seen: bit_set[Try_Tactic]
	for it in items {
		if name, named := dashed_ident(it); named {
			if o.name != "" { return {}, false }
			o.name = strings.clone(name, cx.alloc)
			continue
		}
		if it.kind != .Token || it.tok.kind != .Ident { return {}, false }
		t: Try_Tactic
		switch css.lower_temp(it.tok.text) {
		case "flip-block": t = .Flip_Block
		case "flip-inline": t = .Flip_Inline
		case "flip-start": t = .Flip_Start
		case "flip-x": t = .Flip_X
		case "flip-y": t = .Flip_Y
		case: return {}, false
		}
		if t in seen || int(o.n_tactics) >= TRY_TACTIC_MAX { return {}, false }
		seen += {t}
		o.tactics[o.n_tactics] = t
		o.n_tactics += 1
	}
	return o, true
}

@(private)
parse_try_fallbacks :: proc(cx: ^Cx, vs: []css.Value) -> ([]Try_Option, bool) {
	trimmed := css.trim_values(vs)
	if id, ok := ident_raw(trimmed); ok && strings.equal_fold(id, "none") { return nil, true }
	parts := css.split_commas(trimmed, context.temp_allocator)
	if len(parts) == 0 { return nil, false }
	opts := make([]Try_Option, len(parts), cx.alloc)
	for part, i in parts {
		o, ok := parse_try_option(cx, part)
		if !ok { return nil, false }
		opts[i] = o
	}
	return opts, true
}

@(private)
apply_anchor_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	trimmed := css.trim_values(vs)
	if len(trimmed) == 0 { return false }
	id, is_id := ident_raw(trimmed)
	lid := is_id ? css.lower_temp(id) : ""
	#partial switch p {
	case .Anchor_Name:
		if lid == "none" { c.anchor_name = nil; return true }
		names, ok := dashed_list(cx, trimmed)
		if !ok { return false }
		c.anchor_name = names
	case .Anchor_Scope:
		switch lid {
		case "none": c.anchor_scope = {}; return true
		case "all": c.anchor_scope = {all = true}; return true
		}
		names, ok := dashed_list(cx, trimmed)
		if !ok { return false }
		c.anchor_scope = {names = names}
	case .Position_Anchor:
		switch lid {
		case "normal": c.position_anchor = {kind = .Normal}; return true
		case "none": c.position_anchor = {kind = .None}; return true
		case "auto": c.position_anchor = {kind = .Auto}; return true
		case "match-parent": c.position_anchor = {kind = .Match_Parent}; return true
		}
		if len(trimmed) != 1 { return false }
		name, ok := dashed_ident(trimmed[0])
		if !ok { return false }
		c.position_anchor = {kind = .Name, name = strings.clone(name, cx.alloc)}
	case .Position_Area:
		if lid == "none" { c.position_area = {}; return true }
		a, ok := parse_position_area(split_items(trimmed))
		if !ok { return false }
		c.position_area = a
	case .Position_Try_Fallbacks:
		opts, ok := parse_try_fallbacks(cx, trimmed)
		if !ok { return false }
		c.position_try_fallbacks = opts
	case .Position_Try_Order: return set_enum(trimmed, &c.position_try_order)
	case .Position_Visibility:
		if lid == "always" { c.position_visibility = {}; return true }
		v: Position_Visibility
		for it in split_items(trimmed) {
			f: Visibility_Flag
			switch ident_lower(it) {
			case "anchor-valid": f = .Anchor_Valid
			case "anchor-visible": f = .Anchor_Visible
			case "no-overflow": f = .No_Overflow
			case: return false
			}
			if f in v { return false }
			v += {f}
		}
		c.position_visibility = v
	}
	return true
}

// A length holding anchor() or anchor-size().
@(private)
anchor_length :: proc(cx: ^Cx, tree: ^css.Calc, flags: Len_Flags) -> (Length, bool) {
	if css.calc_has_anchor_position(tree) && .Anchor not_in flags { return {}, false }
	if .Anchor_Size not_in flags && .Anchor not_in flags { return {}, false }
	#partial switch css.calc_type(tree) {
	case .Length, .Length_Percent:
	case .Percent: if .Percent not_in flags { return {}, false }
	case: return {}, false
	}
	calc_resolve_units(tree, cx.lc)
	if cx.c.position == .Absolute || cx.c.position == .Fixed { return Length{kind = .Anchor, calc = tree}, true }
	// not absolutely positioned: the fallback, or as if auto
	stripped := calc_without_anchors(tree, cx.alloc)
	if stripped == nil { return Length{kind = .Anchor}, true }
	if !calc_has_percent(stripped) {
		r := css.eval_calc(stripped, cx.lc)
		if r < 0 && .Negative not_in flags { r = 0 }
		return px(f32(r)), true
	}
	return Length{kind = .Calc, calc = stripped}, true
}

// A copy of the tree with every anchor() and anchor-size() replaced by its fallback. nil: one has none.
@(private)
calc_without_anchors :: proc(n: ^css.Calc, a := context.allocator) -> ^css.Calc {
	if n == nil { return nil }
	if n.op == .Anchor || n.op == .Anchor_Size { return n.a != nil ? calc_without_anchors(n.a, a) : nil }
	out := new(css.Calc, a)
	out^ = n^
	if n.a != nil { out.a = calc_without_anchors(n.a, a); if out.a == nil { return nil } }
	if n.b != nil { out.b = calc_without_anchors(n.b, a); if out.b == nil { return nil } }
	if n.c != nil { out.c = calc_without_anchors(n.c, a); if out.c == nil { return nil } }
	return out
}

////////////////////////////////
// What layout reads

// The box is laid out late, once its anchors are (layout/anchor.odin). Read per absolutely positioned box only.
anchored_style :: proc(cs: ^Computed) -> bool {
	if cs.position_area.a != .None || len(cs.position_try_fallbacks) > 0 || cs.position_anchor.kind == .Name || cs.position_anchor.kind == .Match_Parent ||
	   cs.position_anchor.kind == .Auto || cs.align_self == .Anchor_Center || cs.justify_self == .Anchor_Center { return true }
	for s in Side {
		if cs.inset[s].kind == .Anchor || cs.margin[s].kind == .Anchor { return true }
	}
	return cs.width.kind == .Anchor || cs.height.kind == .Anchor || cs.min_width.kind == .Anchor || cs.min_height.kind == .Anchor ||
		cs.max_width.kind == .Anchor || cs.max_height.kind == .Anchor
}

// The tracks a position-area keyword takes in its axis (0: before the anchor, 1: the anchor, 2: after it), first and last.
// `rtl`: the axis runs from the right (keywords that follow a direction, in the inline axis).
@(private)
area_span :: proc(k: Area_Keyword, rtl, self_rtl: bool) -> (lo, hi: i8) {
	flip :: proc(a, b: i8, rtl: bool) -> (i8, i8) { return rtl ? 2 - b : a, rtl ? 2 - a : b }
	#partial switch k {
	case .Center: return 1, 1
	case .None, .Span_All: return 0, 2
	case .Left, .Top: return 0, 0
	case .Right, .Bottom: return 2, 2
	case .Span_Left, .Span_Top: return 0, 1
	case .Span_Right, .Span_Bottom: return 1, 2
	case .X_Start, .Inline_Start, .Start: return flip(0, 0, rtl)
	case .X_End, .Inline_End, .End: return flip(2, 2, rtl)
	case .Span_X_Start, .Span_Inline_Start, .Span_Start: return flip(0, 1, rtl)
	case .Span_X_End, .Span_Inline_End, .Span_End: return flip(1, 2, rtl)
	case .Self_X_Start, .Self_Inline_Start, .Self_Start: return flip(0, 0, self_rtl)
	case .Self_X_End, .Self_Inline_End, .Self_End: return flip(2, 2, self_rtl)
	case .Span_Self_X_Start, .Span_Self_Inline_Start, .Span_Self_Start: return flip(0, 1, self_rtl)
	case .Span_Self_X_End, .Span_Self_Inline_End, .Span_Self_End: return flip(1, 2, self_rtl)
	// (`rtl` here is whether this axis starts at its high end: area_tracks_flow)
	case .Y_Start, .Block_Start: return flip(0, 0, rtl)
	case .Y_End, .Block_End: return flip(2, 2, rtl)
	case .Span_Y_Start, .Span_Block_Start: return flip(0, 1, rtl)
	case .Span_Y_End, .Span_Block_End: return flip(1, 2, rtl)
	case .Self_Y_Start, .Self_Block_Start: return flip(0, 0, self_rtl)
	case .Self_Y_End, .Self_Block_End: return flip(2, 2, self_rtl)
	case .Span_Self_Y_Start, .Span_Self_Block_Start: return flip(0, 1, self_rtl)
	case .Span_Self_Y_End, .Span_Self_Block_End: return flip(1, 2, self_rtl)
	}
	return 0, 2
}

// The tracks a value takes per axis: x and y, first and last. `rtl`: the containing block's direction, `self_rtl`: the box's.
area_tracks :: proc(area: Position_Area, rtl, self_rtl: bool) -> (x, y: [2]i8) {
	single :: proc(k: Area_Keyword) -> bool { c := area_class(k); return c == .Logical || c == .Self_Logical || k == .Center || k == .Span_All }
	ax, ay: Area_Keyword = .Span_All, .Span_All
	x_kw :: proc(c: Area_Class) -> bool { return c == .Horizontal || c == .Inline || c == .Self_Inline }
	y_kw :: proc(c: Area_Class) -> bool { return c == .Vertical || c == .Block || c == .Self_Block }
	ca, cb := area_class(area.a), area_class(area.b)
	switch {
	case area.b == .None && single(area.a): ax, ay = area.a, area.a
	case x_kw(ca) || y_kw(cb):
		// (`center bottom`: the keyword says which axis the other one is for)
		ax = area.a
		if area.b != .None { ay = area.b }
	case:   // block first, a logical pair: block, inline
		ay = area.a
		if area.b != .None { ax = area.b }
	}
	x[0], x[1] = area_span(ax, rtl, self_rtl)
	y[0], y[1] = area_span(ay, false, false)
	return
}

// The same tree with the sides and sizes it names as a tactic moves them. `axis_x`: it is in a horizontal property, before
// the tactic is applied.
@(private)
tree_flip :: proc(n: ^css.Calc, t: Try_Tactic, axis_x: bool, a := context.allocator) -> ^css.Calc {
	if n == nil { return nil }
	out := new(css.Calc, a)
	out^ = n^
	out.a, out.b, out.c = tree_flip(n.a, t, axis_x, a), n.op == .Anchor ? n.b : tree_flip(n.b, t, axis_x, a), tree_flip(n.c, t, axis_x, a)
	if n.op != .Anchor && n.op != .Anchor_Size { return out }
	r := new(css.Anchor_Ref, a)
	r^ = n.anchor^
	out.anchor = r
	mirror := (t == .Flip_Block || t == .Flip_Y) && !axis_x || (t == .Flip_Inline || t == .Flip_X) && axis_x
	if n.op == .Anchor_Size {
		if t == .Flip_Start {
			#partial switch r.side {
			case .Width: r.side = .Height
			case .Height: r.side = .Width
			case .Block: r.side = .Inline
			case .Inline: r.side = .Block
			case .Self_Block: r.side = .Self_Inline
			case .Self_Inline: r.side = .Self_Block
			}
		}
		return out
	}
	if t == .Flip_Start {
		#partial switch r.side {
		case .Top: r.side = .Left
		case .Left: r.side = .Top
		case .Bottom: r.side = .Right
		case .Right: r.side = .Bottom
		}
		return out
	}
	if !mirror { return out }
	#partial switch r.side {
	case .Top: r.side = .Bottom
	case .Bottom: r.side = .Top
	case .Left: r.side = .Right
	case .Right: r.side = .Left
	case .Start: r.side = .End
	case .End: r.side = .Start
	case .Self_Start: r.side = .Self_End
	case .Self_End: r.side = .Self_Start
	case .Percent:
		hundred := new(css.Calc, a)
		hundred^ = css.Calc{op = .Dimension, num = 100, unit = .Percent}
		sub := new(css.Calc, a)
		sub^ = css.Calc{op = .Sub, a = hundred, b = n.b}
		out.b = sub
	}
	return out
}

@(private)
length_flip :: proc(l: Length, t: Try_Tactic, axis_x: bool, a := context.allocator) -> Length {
	if l.kind != .Anchor || l.calc == nil { return l }
	return Length{kind = .Anchor, calc = tree_flip(l.calc, t, axis_x, a)}
}

@(private)
align_mirror :: proc(x: Content_Align) -> Content_Align {
	#partial switch x {
	case .Start: return .End
	case .End: return .Start
	case .Flex_Start: return .Flex_End
	case .Flex_End: return .Flex_Start
	}
	return x
}

// Applies a <try-tactic> to the properties it moves (§try-tactic). Horizontal text only: block is y, inline is x.
try_tactic_apply :: proc(c: ^Computed, t: Try_Tactic, a := context.allocator) {
	for s in Side {
		x := s == .Left || s == .Right
		c.inset[s] = length_flip(c.inset[s], t, x, a)
		c.margin[s] = length_flip(c.margin[s], t, x, a)
	}
	c.width, c.min_width, c.max_width = length_flip(c.width, t, true, a), length_flip(c.min_width, t, true, a), length_flip(c.max_width, t, true, a)
	c.height, c.min_height, c.max_height = length_flip(c.height, t, false, a), length_flip(c.min_height, t, false, a), length_flip(c.max_height, t, false, a)
	switch t {
	case .Flip_Block, .Flip_Y:
		c.inset[.Top], c.inset[.Bottom] = c.inset[.Bottom], c.inset[.Top]
		c.margin[.Top], c.margin[.Bottom] = c.margin[.Bottom], c.margin[.Top]
		c.align_self = align_mirror(c.align_self)
	case .Flip_Inline, .Flip_X:
		c.inset[.Left], c.inset[.Right] = c.inset[.Right], c.inset[.Left]
		c.margin[.Left], c.margin[.Right] = c.margin[.Right], c.margin[.Left]
		c.justify_self = align_mirror(c.justify_self)
	case .Flip_Start:
		c.inset[.Top], c.inset[.Left] = c.inset[.Left], c.inset[.Top]
		c.inset[.Bottom], c.inset[.Right] = c.inset[.Right], c.inset[.Bottom]
		c.margin[.Top], c.margin[.Left] = c.margin[.Left], c.margin[.Top]
		c.margin[.Bottom], c.margin[.Right] = c.margin[.Right], c.margin[.Bottom]
		c.width, c.height = c.height, c.width
		c.min_width, c.min_height = c.min_height, c.min_width
		c.max_width, c.max_height = c.max_height, c.max_width
		c.align_self, c.justify_self = c.justify_self, c.align_self
	}
}

////////////////////////////////
// Serialization (getComputedStyle)

@(private)
area_keyword_text :: proc(k: Area_Keyword, a := context.temp_allocator) -> string {
	return strings.to_lower(strings.join(strings.split(reflect.enum_string(k), "_", context.temp_allocator), "-", context.temp_allocator), a)
}

@(private)
area_text :: proc(p: Position_Area) -> string {
	if p.a == .None { return "none" }
	if p.b == .None { return area_keyword_text(p.a) }
	return strings.concatenate({area_keyword_text(p.a), " ", area_keyword_text(p.b)}, context.temp_allocator)
}

@(private)
option_text :: proc(o: Try_Option) -> string {
	if o.area.a != .None { return area_text(o.area) }
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if o.name != "" { append(&parts, o.name) }
	for i in 0 ..< int(o.n_tactics) {
		switch o.tactics[i] {
		case .Flip_Block: append(&parts, "flip-block")
		case .Flip_Inline: append(&parts, "flip-inline")
		case .Flip_Start: append(&parts, "flip-start")
		case .Flip_X: append(&parts, "flip-x")
		case .Flip_Y: append(&parts, "flip-y")
		}
	}
	return strings.join(parts[:], " ", context.temp_allocator)
}

// A declared value, as CSSOM serializes it, when it differs from its tokens: the keywords of position-area and the options of
// position-try-fallbacks in their order, anchor() and anchor-size() with the name first. "": as written.
canonical_declared :: proc(p: Prop, vs: []css.Value, alloc := context.temp_allocator) -> string {
	cx := Cx{alloc = alloc}
	#partial switch p {
	case .Position_Area:
		if a, ok := parse_position_area(split_items(css.trim_values(vs))); ok { return area_text(a) }
	case .Position_Try_Fallbacks:
		if opts, ok := parse_try_fallbacks(&cx, vs); ok {
			c := Computed{position_try_fallbacks = opts}
			return try_fallbacks_text(&c)
		}
	case .Top, .Right, .Bottom, .Left, .Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left,
	     .Width, .Height, .Min_Width, .Min_Height, .Max_Width, .Max_Height:
		if has_anchor_function(vs) {
			sb := strings.builder_make(alloc)
			write_canonical(&sb, css.trim_values(vs))
			return strings.to_string(sb)
		}
	}
	return ""
}

@(private)
has_anchor_function :: proc(vs: []css.Value) -> bool {
	for v in vs {
		if v.kind == .Token { continue }
		if v.kind == .Function && (strings.equal_fold(v.tok.text, "anchor") || strings.equal_fold(v.tok.text, "anchor-size")) { return true }
		if has_anchor_function(v.children) { return true }
	}
	return false
}

@(private)
write_canonical :: proc(sb: ^strings.Builder, vs: []css.Value) {
	for v in vs {
		if v.kind == .Function && strings.equal_fold(v.tok.text, "calc") && has_anchor_function(v.children) {
			// calc() of one function is that function
			inner := css.trim_values(v.children)
			if len(inner) == 1 { write_canonical(sb, inner); continue }
		}
		if v.kind == .Function && (strings.equal_fold(v.tok.text, "anchor") || strings.equal_fold(v.tok.text, "anchor-size")) {
			parts := css.split_commas(v.children, context.temp_allocator)
			strings.write_string(sb, css.lower_temp(v.tok.text))
			strings.write_byte(sb, '(')
			if len(parts) > 0 {
				items := split_items(parts[0])
				// the name, then the side or size
				for it in items { if _, named := dashed_ident(it); named { write_canonical(sb, {it}) } }
				first := true
				for it in items {
					if _, named := dashed_ident(it); named { continue }
					if !first || len(items) > 1 { strings.write_byte(sb, ' ') }
					write_canonical(sb, {it})
					first = false
				}
			}
			if len(parts) > 1 {
				strings.write_string(sb, ", ")
				f := css.trim_values(parts[1])
				if len(f) == 1 && f[0].kind == .Token && f[0].tok.kind == .Number && f[0].tok.num == 0 { strings.write_string(sb, "0px") } else { write_canonical(sb, f) }
			}
			strings.write_byte(sb, ')')
			continue
		}
		if v.kind == .Function {
			strings.write_string(sb, css.serialize_values({css.Value{kind = .Token, tok = {kind = .Ident, text = v.tok.text}}}, context.temp_allocator))
			strings.write_byte(sb, '(')
			write_canonical(sb, css.trim_values(v.children))
			strings.write_byte(sb, ')')
			continue
		}
		strings.write_string(sb, css.serialize_values({v}, context.temp_allocator))
	}
}

// The value of an anchor positioning property, "" for any other name.
anchor_prop_text :: proc(c: ^Computed, name: string) -> string {
	switch name {
	case "anchor-name":
		if len(c.anchor_name) == 0 { return "none" }
		return strings.join(c.anchor_name, ", ", context.temp_allocator)
	case "anchor-scope":
		if c.anchor_scope.all { return "all" }
		if len(c.anchor_scope.names) == 0 { return "none" }
		return strings.join(c.anchor_scope.names, ", ", context.temp_allocator)
	case "position-anchor":
		switch c.position_anchor.kind {
		case .Normal: return "normal"
		case .None: return "none"
		case .Auto: return "auto"
		case .Match_Parent: return "match-parent"
		case .Name: return c.position_anchor.name
		}
	case "position-area":
		// computed: the axis of a pair goes without saying (block-end inline-start: end start)
		reduce :: proc(k: Area_Keyword) -> Area_Keyword {
			#partial switch k {
			case .Block_Start, .Inline_Start: return .Start
			case .Block_End, .Inline_End: return .End
			case .Span_Block_Start, .Span_Inline_Start: return .Span_Start
			case .Span_Block_End, .Span_Inline_End: return .Span_End
			case .Self_Block_Start, .Self_Inline_Start: return .Self_Start
			case .Self_Block_End, .Self_Inline_End: return .Self_End
			case .Span_Self_Block_Start, .Span_Self_Inline_Start: return .Span_Self_Start
			case .Span_Self_Block_End, .Span_Self_Inline_End: return .Span_Self_End
			}
			return k
		}
		// a logical keyword beside span-all: the axis has to be said (end span-all: block-end)
		expand :: proc(k: Area_Keyword, block: bool) -> Area_Keyword {
			#partial switch k {
			case .Start: return block ? .Block_Start : .Inline_Start
			case .End: return block ? .Block_End : .Inline_End
			case .Span_Start: return block ? .Span_Block_Start : .Span_Inline_Start
			case .Span_End: return block ? .Span_Block_End : .Span_Inline_End
			case .Self_Start: return block ? .Self_Block_Start : .Self_Inline_Start
			case .Self_End: return block ? .Self_Block_End : .Self_Inline_End
			case .Span_Self_Start: return block ? .Span_Self_Block_Start : .Span_Self_Inline_Start
			case .Span_Self_End: return block ? .Span_Self_Block_End : .Span_Self_Inline_End
			}
			return k
		}
		a := c.position_area
		if a.b == .None { return area_text(a) }
		if a.a != .Center && a.b == .Span_All { return area_text({expand(a.a, true), .None}) }
		if a.b != .Center && a.a == .Span_All { return area_text({expand(a.b, false), .None}) }
		a.a, a.b = reduce(a.a), reduce(a.b)
		if a.a == a.b { a.b = .None }
		return area_text(a)
	case "position-try-fallbacks": return try_fallbacks_text(c)
	case "position-try-order": return try_order_text(c)
	case "position-try":
		f := try_fallbacks_text(c)
		if c.position_try_order == .Normal { return f }
		return strings.concatenate({try_order_text(c), " ", f}, context.temp_allocator)
	case "position-visibility":
		if c.position_visibility == {} { return "always" }
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		if .Anchor_Valid in c.position_visibility { append(&parts, "anchor-valid") }
		if .Anchor_Visible in c.position_visibility { append(&parts, "anchor-visible") }
		if .No_Overflow in c.position_visibility { append(&parts, "no-overflow") }
		return strings.join(parts[:], " ", context.temp_allocator)
	}
	return ""
}

@(private)
try_fallbacks_text :: proc(c: ^Computed) -> string {
	if len(c.position_try_fallbacks) == 0 { return "none" }
	parts := make([]string, len(c.position_try_fallbacks), context.temp_allocator)
	for o, i in c.position_try_fallbacks { parts[i] = option_text(o) }
	return strings.join(parts, ", ", context.temp_allocator)
}

@(private)
try_order_text :: proc(c: ^Computed) -> string {
	switch c.position_try_order {
	case .Normal: return "normal"
	case .Most_Width: return "most-width"
	case .Most_Height: return "most-height"
	case .Most_Block_Size: return "most-block-size"
	case .Most_Inline_Size: return "most-inline-size"
	}
	return ""
}

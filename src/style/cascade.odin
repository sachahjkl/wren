package style

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// The cascade (CSS Cascading Level 5, without transitions and animations): origins, !important, layers, specificity, source
// order, inheritance, var() substitution, and the final computed values.

Cascade_Key :: struct {
	level: u8,
	layer: u32,
	spec:  css.Specificity,
	order: u32,
}

@(private)
key_ge :: proc(a, b: Cascade_Key) -> bool {
	if a.level != b.level { return a.level > b.level }
	if a.layer != b.layer { return a.layer > b.layer }
	if a.spec != b.spec { return css.specificity_less(b.spec, a.spec) }
	return a.order >= b.order
}

@(private)
make_key :: proc(r: ^Rule, important: bool, spec: css.Specificity) -> Cascade_Key {
	k := Cascade_Key{spec = spec, order = r.order}
	switch r.origin {
	case .UA: k.level = important ? 5 : 0
	case .User: k.level = important ? 4 : 1
	case .Author:
		k.level = important ? 3 : 2
		k.layer = important ? max(u32) - r.layer : r.layer
	}
	return k
}

@(private)
Cand :: struct {
	decl:   ^Pre_Decl,
	key:    Cascade_Key,
	origin: Origin,
	valid:  bool,
}

@(private)
Custom_Cand :: struct {
	decl:  ^Custom_Decl,
	key:   Cascade_Key,
	valid: bool,
}

// The result of a style pass.
Styled :: struct {
	arena:          virtual.Arena,
	alloc:          runtime.Allocator,
	by_node:        [dynamic]^Computed,
	initial:        ^Computed,
	root_font_size: f32,
	mutations:      u64,     // the document's mutation counter when this was computed
	serial:         u64,     // unique per pass: lets layout notice that styles changed even if nothing else did
	line_height_normal: f32, // what `line-height: normal` means (a multiple of the font size), from the preferences
	canvas:         css.Color,   // the color painted behind the whole page (root or body background, else the preference)
}

@(private) styled_serial: u64

styled_destroy :: proc(s: ^Styled) {
	if s == nil { return }
	delete(s.by_node)
	virtual.arena_destroy(&s.arena)
	free(s)
}

style_of :: proc(s: ^Styled, h: base.Handle) -> ^Computed {
	if s == nil { return nil }
	i := int(base.handle_index(h))
	if i < 0 || i >= len(s.by_node) { return nil }
	c := s.by_node[i]
	if c != nil && c.node != h { return nil }   // a recycled slot
	return c
}

@(private)
system_color :: proc(user: rawptr, name: string) -> (css.Color, bool) {
	s := (^Settings)(user)
	switch name {
	case "canvas": return s.background_color, true
	case "canvastext", "windowtext", "fieldtext", "buttontext", "marktext", "highlighttext_": return s.text_color, true
	case "linktext": return s.link_color, true
	case "visitedtext": return s.visited_color, true
	case "activetext": return s.active_link_color, true
	case "buttonface", "buttonborder", "threedface": return css.color_from_u32(0xefefef), true
	case "field", "window": return css.color_from_u32(0xffffff), true
	case "graytext": return css.color_from_u32(0x6d6d6d), true
	case "highlight", "accentcolor": return css.color_from_u32(0x0067c0), true
	case "highlighttext", "accentcolortext": return css.color_from_u32(0xffffff), true
	case "mark": return css.color_from_u32(0xffff00), true
	}
	return {}, false
}

////////////////////////////////
// var()

@(private)
Var_Env :: struct {
	engine:   ^Engine,
	alloc:    runtime.Allocator,
	// while custom properties of the element are being resolved:
	pending:  map[string]Custom_Cand,
	resolved: map[string]string,
	state:    map[string]u8,          // 1 = being resolved (a cycle if met again), 2 = done, 3 = invalid
	parent:   ^Custom_Props,
	final:    ^Custom_Props,          // set once resolution is finished
	budget:   int,
}

@(private)
var_lookup :: proc(env: ^Var_Env, name: string, depth: int) -> (string, bool) {
	if env.final != nil {
		v, ok := env.final.values[name]
		return v, ok
	}
	if cand, has := env.pending[name]; has && cand.valid {
		switch env.state[name] {
		case 1, 3: return "", false
		case 2: return env.resolved[name], true
		}
		env.state[name] = 1
		vals, ok := substitute(env, cand.decl.value, depth + 1)
		if !ok {
			env.state[name] = 3
			return "", false
		}
		text := css.serialize_values(vals, env.alloc)
		env.resolved[name] = text
		env.state[name] = 2
		return text, true
	}
	if env.parent != nil {
		v, ok := env.parent.values[name]
		return v, ok
	}
	return "", false
}

@(private)
substitute :: proc(env: ^Var_Env, vs: []css.Value, depth: int) -> ([]css.Value, bool) {
	s := &env.engine.settings
	if depth > s.max_var_depth { return nil, false }
	out := make([dynamic]css.Value, env.alloc)
	for v in vs {
		switch v.kind {
		case .Token: append(&out, v)
		case .Block:
			nv := v
			kids, ok := substitute(env, v.children, depth)
			if !ok { return nil, false }
			nv.children = kids
			append(&out, nv)
		case .Function:
			if !strings.equal_fold(v.tok.text, "var") {
				nv := v
				kids, ok := substitute(env, v.children, depth)
				if !ok { return nil, false }
				nv.children = kids
				append(&out, nv)
				continue
			}
			// var(--name [, fallback])
			args := v.children
			i := 0
			for i < len(args) && css.is_ws_value(args[i]) { i += 1 }
			if i >= len(args) || args[i].kind != .Token || args[i].tok.kind != .Ident || !strings.has_prefix(args[i].tok.text, "--") { return nil, false }
			name := args[i].tok.text
			i += 1
			for i < len(args) && css.is_ws_value(args[i]) { i += 1 }
			has_fallback := false
			fallback: []css.Value
			if i < len(args) {
				if args[i].kind != .Token || args[i].tok.kind != .Comma { return nil, false }
				has_fallback = true
				fallback = args[i + 1:]
			}
			if text, found := var_lookup(env, name, depth); found {
				env.budget -= len(text)
				if env.budget < 0 { return nil, false }
				parsed := css.parse_component_values(text, parse_options(s), env.alloc)
				sub, ok := substitute(env, parsed, depth + 1)
				if !ok { return nil, false }
				for p in css.trim_values(sub) { append(&out, p) }
			} else if has_fallback {
				sub, ok := substitute(env, css.trim_values(fallback), depth + 1)
				if !ok { return nil, false }
				for p in sub { append(&out, p) }
			} else { return nil, false }
		}
	}
	return out[:], true
}

////////////////////////////////
// One element

@(private)
Pass :: struct {
	e:      ^Engine,
	s:      ^Styled,
	mc:     Match_Ctx,
	opt:    css.Parse_Options,
}

@(private)
consider :: proc(ws: ^[Prop]Cand, cust: ^map[string]Custom_Cand, rule: ^Rule, spec: css.Specificity) {
	for &d in rule.decls {
		k := make_key(rule, d.important, spec)
		cand := &ws[d.prop]
		if !cand.valid || key_ge(k, cand.key) { cand^ = Cand{&d, k, rule.origin, true} }
	}
	for &cd in rule.customs {
		k := make_key(rule, cd.important, spec)
		old, has := cust[cd.name]
		if !has || !old.valid || key_ge(k, old.key) { cust[cd.name] = Custom_Cand{&cd, k, true} }
	}
}

@(private)
collect_entries :: proc(p: ^Pass, el: base.Handle, n: ^dom.Node, out: ^[3][dynamic]Entry) {
	check :: proc(p: ^Pass, el: base.Handle, list: []Entry, out: ^[3][dynamic]Entry) {
		for ent in list {
			slot: int
			#partial switch ent.complex.pseudo_element {
			case .None: slot = 0
			case .Before: slot = 1
			case .After: slot = 2
			case: continue
			}
			if matches_complex(&p.mc, el, ent.complex) { append(&out[slot], ent) }
		}
	}
	ix := &p.e.index
	if id, ok := attr(n, "id"); ok && id != "" {
		if l, found := ix.by_id[id]; found { check(p, el, l[:], out) }
	}
	if cls, ok := attr(n, "class"); ok {
		rest := cls
		for len(rest) > 0 {
			for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
			end := 0
			for end < len(rest) && !is_space(rest[end]) { end += 1 }
			if end > 0 {
				if l, found := ix.by_class[rest[:end]]; found { check(p, el, l[:], out) }
			}
			rest = rest[end:]
		}
	}
	if l, found := ix.by_tag[n.name]; found { check(p, el, l[:], out) }
	check(p, el, ix.universal[:], out)
}

@(private)
is_color_prop :: proc(pr: Prop) -> bool {
	#partial switch pr {
	case .Color, .Background_Color, .Background_Image, .Text_Decoration_Color, .Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color, .Outline_Color, .Box_Shadow, .Text_Shadow:
		return true
	}
	return false
}

@(private)
build_style :: proc(p: ^Pass, h: base.Handle, parent: ^Computed, entries: []Entry, inline_rule: ^Rule, pseudo: bool) -> ^Computed {
	s := p.s
	e := p.e
	a := s.alloc
	ws: [Prop]Cand
	cust := make(map[string]Custom_Cand, context.temp_allocator)
	for ent in entries { consider(&ws, &cust, ent.rule, ent.complex.specificity) }
	if inline_rule != nil { consider(&ws, &cust, inline_rule, css.Specificity{max(u32), 0, 0}) }

	c := new(Computed, a)
	c^ = s.initial^
	c.node = h
	if parent != nil {
		for pr in INHERITED { copy_prop(c, parent, pr) }
		c.custom = parent.custom
	}
	cx := Cx{settings = &e.settings, parent = parent, c = c, alloc = a}
	cx.cenv = css.Color_Env{dark = e.env.prefers_dark, system = system_color, user = &e.settings}
	cx.lc = css.Length_Context{
		font_size = f64(c.font_size), root_font_size = f64(s.root_font_size > 0 ? s.root_font_size : e.settings.default_font_size),
		x_height = f64(c.font_size) * 0.5, ch = f64(c.font_size) * 0.5, vw = e.env.width, vh = e.env.height,
	}

	// custom properties
	env := Var_Env{engine = e, alloc = a, budget = e.settings.max_var_bytes}
	env.pending = make(map[string]Custom_Cand, context.temp_allocator)
	env.resolved = make(map[string]string, context.temp_allocator)
	env.state = make(map[string]u8, context.temp_allocator)
	env.parent = c.custom
	if len(cust) > 0 {
		for k, v in cust { env.pending[k] = v }
		props := new(Custom_Props, a)
		props.values = make(map[string]string, a)
		if c.custom != nil { for k, v in c.custom.values { props.values[k] = v } }
		for name in cust {
			text, ok := var_lookup(&env, name, 0)
			if ok { props.values[name] = text } else { delete_key(&props.values, name) }
		}
		c.custom = props
	}
	env.final = c.custom != nil ? c.custom : &Custom_Props{}
	env.pending = nil

	// longhands, in dependency order (font-size and color first)
	for pr in Prop {
		cand := ws[pr]
		if !cand.valid { continue }
		if cand.origin == .Author {
			if !e.settings.author_colors && is_color_prop(pr) { continue }
			if !e.settings.author_fonts && (pr == .Font_Family || pr == .Font_Size) { continue }
		}
		vals := cand.decl.value
		if cand.decl.has_var {
			env.budget = e.settings.max_var_bytes
			sub, ok := substitute(&env, vals, 0)
			if !ok { apply_unset(&cx, pr); continue }
			vals = sub
		}
		if cand.decl.short != .None {
			longs, ok := expand_shorthand(cand.decl.short, vals, a)
			found := false
			if ok { for l in longs { if l.prop == pr { vals = l.vals; found = true; break } } }
			if !found { apply_unset(&cx, pr); continue }
		}
		switch css_wide_keyword(vals) {
		case "inherit": copy_prop(c, parent != nil ? parent : s.initial, pr); cx.explicit += {pr}
		case "initial": copy_prop(c, s.initial, pr)
		case "unset", "revert", "revert-layer": apply_unset(&cx, pr)
		case:
			if !apply_prop(&cx, pr, vals) { apply_unset(&cx, pr) }
		}
		// the element's own font-size is now known: later em units use it
		if pr == .Font_Size {
			cx.lc.font_size = f64(c.font_size)
			cx.lc.x_height = f64(c.font_size) * 0.5
			cx.lc.ch = f64(c.font_size) * 0.5
		}
	}
	finish_style(&cx, h, pseudo)
	return c
}

// `unset`: inherit when the property is inherited, otherwise its initial value.
@(private)
apply_unset :: proc(cx: ^Cx, pr: Prop) {
	if pr in INHERITED && cx.parent != nil { copy_prop(cx.c, cx.parent, pr) } else if pr in INHERITED {
		init := initial_computed(cx.settings)
		copy_prop(cx.c, &init, pr)
	} else {
		init := initial_computed(cx.settings)
		copy_prop(cx.c, &init, pr)
	}
}

@(private)
blockify :: proc(d: Display) -> Display {
	switch d {
	case .Inline, .Inline_Block: return .Block
	case .Inline_Flex: return .Flex
	case .Inline_Grid: return .Grid
	case .Inline_Table: return .Table
	case .Block, .Flow_Root, .List_Item, .Flex, .Grid, .Table, .Table_Row_Group, .Table_Header_Group, .Table_Footer_Group,
	     .Table_Row, .Table_Column_Group, .Table_Column, .Table_Cell, .Table_Caption, .Contents, .None: return d
	}
	return d
}

@(private)
finish_style :: proc(cx: ^Cx, h: base.Handle, pseudo: bool) {
	c := cx.c
	for side in Side {
		if c.border_style[side] == .None || c.border_style[side] == .Hidden { c.border_width[side] = 0 }
	}
	if c.outline_style == .None || c.outline_style == .Hidden { c.outline_width = 0 }
	for side in Side {
		pr := Prop(int(Prop.Border_Top_Color) + int(side))
		if pr not_in cx.explicit { c.border_color[side] = c.color }
	}
	if .Outline_Color not_in cx.explicit { c.outline_color = c.color }
	if .Text_Decoration_Color not_in cx.explicit { c.text_decoration_color = c.color }
	if c.position == .Absolute || c.position == .Fixed || c.float != .None { c.display = blockify(c.display) }
	// overflow: a visible axis next to a scrolling one computes to auto
	if (c.overflow_x == .Visible) != (c.overflow_y == .Visible) {
		if c.overflow_x == .Visible { c.overflow_x = .Auto } else { c.overflow_y = .Auto }
	}
	if c.min_width.kind == .Auto { c.min_width = px(0) }
	if c.min_height.kind == .Auto { c.min_height = px(0) }
}

@(private)
compute_element :: proc(p: ^Pass, h: base.Handle, n: ^dom.Node, parent: ^Computed) -> ^Computed {
	lists: [3][dynamic]Entry
	for i in 0 ..< 3 { lists[i] = make([dynamic]Entry, context.temp_allocator) }
	collect_entries(p, h, n, &lists)

	inline_rule: ^Rule
	if text, ok := attr(n, "style"); ok && p.e.settings.author_stylesheets && text != "" {
		decls := css.parse_declarations(text, p.opt, context.temp_allocator)
		pre, customs := compile_declarations(p.e, decls, p.s.alloc)
		if len(pre) > 0 || len(customs) > 0 {
			inline_rule = new(Rule, context.temp_allocator)
			inline_rule^ = Rule{decls = pre, customs = customs, origin = .Author, layer = UNLAYERED, order = max(u32)}
		}
	}
	c := build_style(p, h, parent, lists[0][:], inline_rule, false)

	for i in 1 ..< 3 {
		if len(lists[i]) == 0 { continue }
		pc := build_style(p, h, c, lists[i][:], nil, true)
		if pc.display == .None || pc.content.kind != .Items { continue }
		if i == 1 { c.before = pc } else { c.after = pc }
	}
	return c
}

// Computes the style of every element of the document.
compute_styles :: proc(e: ^Engine, doc: ^dom.Document, state: State) -> ^Styled {
	if e.dirty { engine_rebuild(e, doc) }
	s := new(Styled)
	_ = virtual.arena_init_growing(&s.arena)
	s.alloc = virtual.arena_allocator(&s.arena)
	s.initial = new(Computed, s.alloc)
	s.initial^ = initial_computed(&e.settings)
	generic := e.settings.default_generic
	s.initial.font_family = make([]string, 1, s.alloc)
	s.initial.font_family[0] = strings.clone(generic, s.alloc)
	s.mutations = doc.mutations
	styled_serial += 1
	s.serial = styled_serial
	s.line_height_normal = e.settings.line_height_normal
	s.canvas = e.settings.background_color

	p := Pass{e = e, s = s, opt = parse_options(&e.settings)}
	match_ctx_init(&p.mc, doc, state)
	defer match_ctx_destroy(&p.mc)

	Frame :: struct { h: base.Handle, parent: ^Computed }
	stack := make([dynamic]Frame, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for c := root.last_child; c != base.NIL_HANDLE; c = dom.get(doc, c).prev { append(&stack, Frame{c, nil}) }
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		c := compute_element(&p, f.h, n, f.parent)
		idx := int(base.handle_index(f.h))
		for len(s.by_node) <= idx { append(&s.by_node, nil) }
		s.by_node[idx] = c
		if f.parent == nil && s.root_font_size == 0 { s.root_font_size = c.font_size }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{ch, c}) }
	}
	// the canvas takes the root element's background, or the body's when the root has none
	if root_el := dom.find_first_by_tag(doc, "html"); root_el != base.NIL_HANDLE {
		if rc := style_of(s, root_el); rc != nil && rc.background_color.a > 0 {
			s.canvas = rc.background_color
		} else if body := dom.find_first_by_tag(doc, "body"); body != base.NIL_HANDLE {
			if bc := style_of(s, body); bc != nil && bc.background_color.a > 0 { s.canvas = bc.background_color }
		}
	}
	return s
}

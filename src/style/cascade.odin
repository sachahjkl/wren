package style

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"

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
	state:          State,       // the dynamic state these styles were computed for (target_id owned by `alloc`)
	base_used:      uint,        // arena use right after the full pass: what partial restyles add on top is waste
	thread_arenas:  [dynamic]^virtual.Arena,   // a parallel pass: the computed styles of each thread (parallel.odin)
}

@(private) styled_serial: u64

styled_destroy :: proc(s: ^Styled) {
	if s == nil { return }
	delete(s.by_node)
	for a in s.thread_arenas { virtual.arena_destroy(a); free(a) }
	delete(s.thread_arenas)
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
	e:        ^Engine,
	s:        ^Styled,
	mc:       Match_Ctx,
	opt:      css.Parse_Options,
	ws:       [Prop]Cand,      // winners of the element being styled; only `touched` entries are reset between elements
	touched:  [dynamic]Prop,
	lists:    [3][dynamic]Entry,   // matched entries: the element, ::before, ::after
	compare:  bool,            // partial restyle: keep the old computed style when nothing changed
	changed:  bool,            // ... and report whether some element really changed
	alloc:    runtime.Allocator,   // where computed styles go: the Styled's arena, or this thread's in a parallel pass
	stats:    Compile_Stats,   // merged into the engine by pass_destroy (on the thread that owns the engine)
}

@(private)
consider :: proc(p: ^Pass, cust: ^map[string]Custom_Cand, rule: ^Rule, spec: css.Specificity) {
	for &d in rule.decls {
		k := make_key(rule, d.important, spec)
		cand := &p.ws[d.prop]
		if !cand.valid {
			append(&p.touched, d.prop)
			cand^ = Cand{&d, k, rule.origin, true}
		} else if key_ge(k, cand.key) {
			cand^ = Cand{&d, k, rule.origin, true}
		}
	}
	if len(rule.customs) > 0 {
		if cust^ == nil { cust^ = make(map[string]Custom_Cand, context.temp_allocator) }
		for &cd in rule.customs {
			k := make_key(rule, cd.important, spec)
			old, has := cust[cd.name]
			if !has || !old.valid || key_ge(k, old.key) { cust[cd.name] = Custom_Cand{&cd, k, true} }
		}
	}
}

@(private)
collect_entries :: proc(p: ^Pass, el: base.Handle, n: ^dom.Node, ancestors: ^Bloom) {
	check :: proc(p: ^Pass, el: base.Handle, list: []Entry, ancestors: ^Bloom) {
		for &ent in list {
			slot: int
			#partial switch ent.complex.pseudo_element {
			case .None: slot = 0
			case .Before: slot = 1
			case .After: slot = 2
			case: continue
			}
			rejected := false
			for k in 0 ..< int(ent.n_anc) { if !bloom_has(ancestors, ent.anc[k]) { rejected = true; break } }
			if rejected { continue }
			if matches_complex(&p.mc, el, ent.complex) { append(&p.lists[slot], ent) }
		}
	}
	for i in 0 ..< 3 { clear(&p.lists[i]) }
	ix := &p.e.index
	if id, ok := attr(n, "id"); ok && id != "" {
		if l, found := ix.by_id[id]; found { check(p, el, l[:], ancestors) }
	}
	if cls, ok := attr(n, "class"); ok {
		rest := cls
		for len(rest) > 0 {
			for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
			end := 0
			for end < len(rest) && !is_space(rest[end]) { end += 1 }
			if end > 0 {
				if l, found := ix.by_class[rest[:end]]; found { check(p, el, l[:], ancestors) }
			}
			rest = rest[end:]
		}
	}
	if len(ix.by_attr) > 0 {
		for a in n.attrs {
			if a.name not_in ix.attr_names { continue }
			key := strings.concatenate({a.name, "\x00", a.value}, context.temp_allocator)
			if l, found := ix.by_attr[key]; found { check(p, el, l[:], ancestors) }
		}
	}
	if l, found := ix.by_tag[n.name]; found { check(p, el, l[:], ancestors) }
	check(p, el, ix.universal[:], ancestors)
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
build_style :: proc(p: ^Pass, h: base.Handle, parent: ^Computed, entries: []Entry, inline_rule: ^Rule) -> ^Computed {
	s := p.s
	e := p.e
	a := p.alloc
	cust: map[string]Custom_Cand
	for ent in entries { consider(p, &cust, ent.rule, ent.complex.specificity) }
	if inline_rule != nil { consider(p, &cust, inline_rule, css.Specificity{max(u32), 0, 0}) }
	slice.sort(p.touched[:])   // enum order = dependency order (font-size and color first)

	c := new(Computed, a)
	c^ = s.initial^
	c.node = h
	if parent != nil {
		for pr in INHERITED { copy_prop(c, parent, pr) }
		c.custom = parent.custom
	}
	cx := Cx{settings = &e.settings, parent = parent, initial = s.initial, c = c, alloc = a}
	cx.cenv = css.Color_Env{dark = e.env.prefers_dark, system = system_color, user = &e.settings}
	cx.lc = css.Length_Context{
		font_size = f64(c.font_size), root_font_size = f64(s.root_font_size > 0 ? s.root_font_size : e.settings.default_font_size),
		x_height = f64(c.font_size) * 0.5, ch = f64(c.font_size) * 0.5, vw = e.env.width, vh = e.env.height,
	}

	// custom properties (the maps exist only for elements that declare some)
	env := Var_Env{engine = e, alloc = a, budget = e.settings.max_var_bytes}
	env.parent = c.custom
	if len(cust) > 0 {
		env.pending = make(map[string]Custom_Cand, context.temp_allocator)
		env.resolved = make(map[string]string, context.temp_allocator)
		env.state = make(map[string]u8, context.temp_allocator)
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
	empty_props := Custom_Props{}
	env.final = c.custom != nil ? c.custom : &empty_props
	env.pending = nil

	for pr in p.touched {
		cand := p.ws[pr]
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
		if pr == .Font_Size {
			cx.lc.font_size = f64(c.font_size)
			cx.lc.x_height = f64(c.font_size) * 0.5
			cx.lc.ch = f64(c.font_size) * 0.5
		}
	}
	for pr in p.touched { p.ws[pr] = {} }
	clear(&p.touched)
	finish_style(&cx, h)
	return c
}

// `unset`: inherit when the property is inherited, otherwise its initial value.
@(private)
apply_unset :: proc(cx: ^Cx, pr: Prop) {
	if pr in INHERITED && cx.parent != nil { copy_prop(cx.c, cx.parent, pr); return }
	copy_prop(cx.c, cx.initial, pr)
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
finish_style :: proc(cx: ^Cx, h: base.Handle) {
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
	if (c.overflow_x == .Visible) != (c.overflow_y == .Visible) {
		if c.overflow_x == .Visible { c.overflow_x = .Auto } else { c.overflow_y = .Auto }
	}
	if c.min_width.kind == .Auto { c.min_width = px(0) }
	if c.min_height.kind == .Auto { c.min_height = px(0) }
}

@(private)
compute_element :: proc(p: ^Pass, h: base.Handle, n: ^dom.Node, parent: ^Computed, ancestors: ^Bloom) -> ^Computed {
	collect_entries(p, h, n, ancestors)

	inline_rule: ^Rule
	if text, ok := attr(n, "style"); ok && p.e.settings.author_stylesheets && text != "" {
		decls := css.parse_declarations(text, p.opt, context.temp_allocator)
		pre, customs := compile_declarations(p.e, decls, p.alloc, &p.stats)
		if len(pre) > 0 || len(customs) > 0 {
			inline_rule = new(Rule, context.temp_allocator)
			inline_rule^ = Rule{decls = pre, customs = customs, origin = .Author, layer = UNLAYERED, order = max(u32)}
		}
	}
	// the element's own lists are consumed before ::before / ::after reuse the buffers
	before_entries, after_entries: [dynamic]Entry
	if len(p.lists[1]) > 0 { before_entries = make([dynamic]Entry, context.temp_allocator); append(&before_entries, ..p.lists[1][:]) }
	if len(p.lists[2]) > 0 { after_entries = make([dynamic]Entry, context.temp_allocator); append(&after_entries, ..p.lists[2][:]) }
	c := build_style(p, h, parent, p.lists[0][:], inline_rule)

	for i in 1 ..< 3 {
		entries := i == 1 ? before_entries : after_entries
		if len(entries) == 0 { continue }
		pc := build_style(p, h, c, entries[:], nil)
		if pc.display == .None || pc.content.kind != .Items { continue }
		if i == 1 { c.before = pc } else { c.after = pc }
	}
	return c
}

@(private)
pass_make :: proc(e: ^Engine, s: ^Styled, doc: ^dom.Document, state: State) -> ^Pass {
	p := new(Pass)
	p.e, p.s, p.opt = e, s, parse_options(&e.settings)
	p.alloc = s.alloc
	match_ctx_init(&p.mc, doc, state)
	p.touched = make([dynamic]Prop)
	for i in 0 ..< 3 { p.lists[i] = make([dynamic]Entry) }
	return p
}

@(private)
pass_destroy :: proc(p: ^Pass) {
	stats_merge(p.e, p.stats)
	match_ctx_destroy(&p.mc)
	delete(p.touched)
	for i in 0 ..< 3 { delete(p.lists[i]) }
	free(p)
}

// Styles `root` and everything below it. `parent` is the computed style of root's parent (nil for the document element);
// `ancestors` the filter of root's ancestors.
@(private)
style_subtree :: proc(p: ^Pass, root: base.Handle, parent: ^Computed, ancestors: Bloom, descend := true) {
	doc := p.mc.doc
	s := p.s
	Frame :: struct { h: base.Handle, parent: ^Computed, bloom: Bloom }
	stack := make([dynamic]Frame, context.temp_allocator)
	append(&stack, Frame{root, parent, ancestors})
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		c := compute_element(p, f.h, n, f.parent, &f.bloom)
		idx := int(base.handle_index(f.h))
		for len(s.by_node) <= idx { append(&s.by_node, nil) }   // never in a parallel pass: sized beforehand
		if p.compare {
			if old := s.by_node[idx]; old != nil && old.node == f.h && computed_equal(old, c) { c = old } else { p.changed = true }
		}
		s.by_node[idx] = c
		if f.parent == nil && s.root_font_size == 0 { s.root_font_size = c.font_size }
		if !descend && f.h == root { break }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{ch, c, child_bloom}) }
	}
}

// Computes the style of every element of the document. With a thread pool and at least `min_nodes` nodes, the
// work is shared between threads (parallel.odin); the result is the same.
compute_styles :: proc(e: ^Engine, doc: ^dom.Document, state: State, pool: ^host.Thread_Pool = nil, min_nodes := 0) -> ^Styled {
	if e.dirty { engine_rebuild(e, doc) }
	s := styled_make(e, doc, state)
	if pool != nil && host.thread_pool_size(pool) > 1 && doc.nodes.count >= min_nodes {
		style_document_parallel(e, s, doc, state, pool)
	} else {
		p := pass_make(e, s, doc, state)
		defer pass_destroy(p)
		root := dom.get(doc, doc.root)
		for c := root.first_child; c != base.NIL_HANDLE; c = dom.get(doc, c).next {
			style_subtree(p, c, nil, Bloom{})
		}
	}
	s.base_used = s.arena.total_used
	update_canvas(s, doc)
	return s
}

@(private)
styled_make :: proc(e: ^Engine, doc: ^dom.Document, state: State) -> ^Styled {
	s := new(Styled)
	_ = virtual.arena_init_growing(&s.arena)
	s.alloc = virtual.arena_allocator(&s.arena)
	s.initial = new(Computed, s.alloc)
	s.initial^ = initial_computed(&e.settings)
	generic := e.settings.default_generic
	s.initial.font_family = make([]string, 1, s.alloc)
	s.initial.font_family[0] = strings.clone(generic, s.alloc)
	s.mutations = doc.mutations
	s.state = state
	s.state.target_id = strings.clone(state.target_id, s.alloc)
	styled_serial += 1
	s.serial = styled_serial
	s.line_height_normal = e.settings.line_height_normal
	s.canvas = e.settings.background_color
	return s
}

@(private)
update_canvas :: proc(s: ^Styled, doc: ^dom.Document) {
	if root_el := dom.find_first_by_tag(doc, "html"); root_el != base.NIL_HANDLE {
		if rc := style_of(s, root_el); rc != nil && rc.background_color.a > 0 {
			s.canvas = rc.background_color
		} else if body := dom.find_first_by_tag(doc, "body"); body != base.NIL_HANDLE {
			if bc := style_of(s, body); bc != nil && bc.background_color.a > 0 { s.canvas = bc.background_color }
		}
	}
}

////////////////////////////////
// Partial restyle after a change of dynamic state

state_equal :: proc(a, b: State) -> bool {
	return a.hover == b.hover && a.active == b.active && a.focus == b.focus && a.target_id == b.target_id
}

@(private)
changed_kinds :: proc(old, new: State) -> (k: State_Kinds) {
	if old.hover != new.hover { k += {.Hover} }
	if old.active != new.active { k += {.Active} }
	if old.focus != new.focus { k += {.Focus} }
	if old.target_id != new.target_id { k += {.Target} }
	return
}

// Elements whose :hover (or :active, :focus-within) status differs: those on exactly one of the two ancestor chains.
@(private)
chain_delta :: proc(doc: ^dom.Document, a, b: base.Handle, out: ^map[base.Handle]bool) {
	chain :: proc(doc: ^dom.Document, h: base.Handle) -> map[base.Handle]bool {
		m := make(map[base.Handle]bool, context.temp_allocator)
		for cur := h; cur != base.NIL_HANDLE; {
			n := dom.get(doc, cur)
			if n == nil || n.kind != .Element { break }
			m[cur] = true
			cur = n.parent
		}
		return m
	}
	ca, cb := chain(doc, a), chain(doc, b)
	for k in ca { if k not_in cb { out[k] = true } }
	for k in cb { if k not_in ca { out[k] = true } }
}

// Restyles only what a change from `s.state` to `new_state` can affect. Returns ok = false when the change cannot be
// scoped (a state-dependent :has(), or too much memory left behind by earlier partial restyles): the caller then does a
// full pass. `changed` tells whether any computed style really differs (layout is needed only then).
restyle_state :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, new_state: State) -> (changed: bool, ok: bool) {
	old := s.state
	kinds := changed_kinds(old, new_state)
	set_state :: proc(s: ^Styled, st: State) {
		s.state = st
		s.state.target_id = strings.clone(st.target_id, s.alloc)
	}
	if kinds == {} { return false, true }
	if kinds & e.state_deps == {} { set_state(s, new_state); return false, true }
	if e.state_uses_has { return false, false }
	if int(s.arena.total_used) > int(s.base_used) + e.settings.restyle_waste_bytes { return false, false }

	p := pass_make(e, s, doc, new_state)
	defer pass_destroy(p)
	p.compare = true

	changed_els := make(map[base.Handle]bool, context.temp_allocator)
	if .Hover in kinds { chain_delta(doc, old.hover, new_state.hover, &changed_els) }
	if .Active in kinds { chain_delta(doc, old.active, new_state.active, &changed_els) }
	if .Focus in kinds {
		chain_delta(doc, old.focus, new_state.focus, &changed_els)   // :focus-within
		if old.focus != base.NIL_HANDLE { changed_els[old.focus] = true }   // :focus and :focus-visible are exact
		if new_state.focus != base.NIL_HANDLE { changed_els[new_state.focus] = true }
	}
	if .Target in kinds {
		if old.target_id != "" { if h := dom.find_by_id(doc, old.target_id); h != base.NIL_HANDLE { changed_els[h] = true } }
		if new_state.target_id != "" { if h := dom.find_by_id(doc, new_state.target_id); h != base.NIL_HANDLE { changed_els[h] = true } }
	}

	// roots to restyle: the element itself, plus whole subtrees where a rule reaches beyond the element
	roots := make(map[base.Handle]bool, context.temp_allocator)   // value: restyle the entire subtree
	for x in changed_els {
		if x not_in roots { roots[x] = false }
		for &ent in e.state_entries {
			if ent.state & kinds == {} { continue }
			c := ent.complex
			last := len(c.compounds) - 1
			for k in 0 ..< last {
				ck, _ := compound_state(c.compounds[k])
				if ck & kinds == {} { continue }
				if !compound_could_match(&p.mc, x, c.compounds[k]) { continue }
				sibling := false
				for j in k ..< last { if c.combinators[j] != .Child && c.combinators[j] != .Descendant { sibling = true } }
				target := x
				if sibling { if par := parent_element(&p.mc, x); par != base.NIL_HANDLE { target = par } }
				roots[target] = true
			}
		}
	}

	for r, deep in roots {
		// a root inside a subtree that is restyled anyway adds nothing
		covered := false
		for anc := parent_element(&p.mc, r); anc != base.NIL_HANDLE; anc = parent_element(&p.mc, anc) {
			if roots[anc] { covered = true; break }
		}
		if covered { continue }

		par := parent_element(&p.mc, r)
		parent_style: ^Computed
		bloom: Bloom
		if par != base.NIL_HANDLE {
			parent_style = style_of(s, par)
			for anc := par; anc != base.NIL_HANDLE; anc = parent_element(&p.mc, anc) { bloom_add_element(&bloom, dom.get(doc, anc)) }
		}
		old_style := style_of(s, r)
		if deep {
			style_subtree(p, r, parent_style, bloom)
			continue
		}
		style_subtree(p, r, parent_style, bloom, descend = false)
		// the element's own change may reach its descendants through inheritance
		new_style := style_of(s, r)
		if old_style != nil && new_style != nil && !inherited_equal(old_style, new_style) {
			n := dom.get(doc, r)
			child_bloom := bloom
			bloom_add_element(&child_bloom, n)
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
				style_subtree(p, ch, new_style, child_bloom)
			}
		}
	}
	set_state(s, new_state)
	if p.changed {
		styled_serial += 1
		s.serial = styled_serial
		update_canvas(s, doc)
	}
	return p.changed, true
}

////////////////////////////////
// Comparing computed styles

@(private)
shadows_equal :: proc(a, b: []Shadow) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if a[i] != b[i] { return false } }
	return true
}

@(private)
strings_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if a[i] != b[i] { return false } }
	return true
}

@(private)
custom_equal :: proc(a, b: ^Custom_Props) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	if len(a.values) != len(b.values) { return false }
	for k, v in a.values { if w, ok := b.values[k]; !ok || w != v { return false } }
	return true
}

@(private)
inherited_equal :: proc(a, b: ^Computed) -> bool {
	return a.color == b.color && strings_equal(a.font_family, b.font_family) && a.font_size == b.font_size &&
		a.font_weight == b.font_weight && a.font_style == b.font_style && a.line_height == b.line_height &&
		a.letter_spacing == b.letter_spacing && a.word_spacing == b.word_spacing && a.text_align == b.text_align &&
		a.text_transform == b.text_transform && a.text_indent == b.text_indent && a.white_space == b.white_space &&
		a.word_break == b.word_break && a.overflow_wrap == b.overflow_wrap && a.tab_size == b.tab_size &&
		a.direction == b.direction && shadows_equal(a.text_shadow, b.text_shadow) && a.visibility == b.visibility &&
		a.list_style_type == b.list_style_type && a.list_style_position == b.list_style_position && a.cursor == b.cursor &&
		a.pointer_events == b.pointer_events && a.border_collapse == b.border_collapse && a.border_spacing == b.border_spacing &&
		custom_equal(a.custom, b.custom)
}

// Value equality. Conservative: a `false` may be spurious (calc trees are compared by pointer), never a `true`.
// The pointer-carrying fields are compared by value; the rest of the struct as raw memory (padding is zeroed everywhere
// a Computed is made), so the two structs are masked in place for the memory compare and restored right after.
computed_equal :: proc(a, b: ^Computed) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	Masked :: struct {
		font_family: []string, text_shadow, box_shadow: []Shadow, content: Content, background_image: Image,
		custom: ^Custom_Props, before, after: ^Computed,
	}
	take :: proc(c: ^Computed) -> Masked {
		m := Masked{c.font_family, c.text_shadow, c.box_shadow, c.content, c.background_image, c.custom, c.before, c.after}
		c.font_family, c.text_shadow, c.box_shadow, c.content, c.background_image, c.custom, c.before, c.after = nil, nil, nil, {}, {}, nil, nil, nil
		return m
	}
	put :: proc(c: ^Computed, m: Masked) {
		c.font_family, c.text_shadow, c.box_shadow, c.content, c.background_image, c.custom, c.before, c.after = m.font_family, m.text_shadow, m.box_shadow, m.content, m.background_image, m.custom, m.before, m.after
	}
	ma, mb := take(a), take(b)
	same := mem.compare_ptrs(a, b, size_of(Computed)) == 0
	put(a, ma); put(b, mb)
	if !same { return false }
	if !strings_equal(ma.font_family, mb.font_family) { return false }
	if !shadows_equal(ma.text_shadow, mb.text_shadow) || !shadows_equal(ma.box_shadow, mb.box_shadow) { return false }
	if ma.content.kind != mb.content.kind || len(ma.content.items) != len(mb.content.items) { return false }
	for i in 0 ..< len(ma.content.items) { if ma.content.items[i] != mb.content.items[i] { return false } }
	if ma.background_image != mb.background_image { return false }
	if !custom_equal(ma.custom, mb.custom) { return false }
	if (ma.before == nil) != (mb.before == nil) || (ma.after == nil) != (mb.after == nil) { return false }
	if ma.before != nil && !computed_equal(ma.before, mb.before) { return false }
	if ma.after != nil && !computed_equal(ma.after, mb.after) { return false }
	return true
}
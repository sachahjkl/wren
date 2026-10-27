package style

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"

// The cascade (CSS Cascading Level 5, without transitions and animations): origins, !important, layers, specificity, source
// order, inheritance, var() substitution, and the final computed values.

Cascade_Key :: struct {
	level: u8,
	ctx:   u16,   // encapsulation context (scope.odin): outer trees win for normal declarations, inner for !important
	layer: u32,
	spec:  css.Specificity,
	order: u32,
}

@(private)
key_ge :: proc(a, b: Cascade_Key) -> bool {
	if a.level != b.level { return a.level > b.level }
	if a.ctx != b.ctx { return a.ctx > b.ctx }
	if a.layer != b.layer { return a.layer > b.layer }
	if a.spec != b.spec { return css.specificity_less(b.spec, a.spec) }
	return a.order >= b.order
}

@(private)
make_key :: proc(r: ^Rule, important: bool, spec: css.Specificity, ctx: u16 = 0) -> Cascade_Key {
	k := Cascade_Key{spec = spec, order = r.order}
	switch r.origin {
	case .UA: k.level = important ? 5 : 0
	case .User: k.level = important ? 4 : 1
	case .Author:
		// layer keys are shifted by one so that presentational hints (key 0) sit below the first cascade layer
		k.level = important ? 3 : 2
		k.ctx = important ? ctx : max(u16) - ctx
		if r.hint {
			k.layer = 0
		} else if important {
			k.layer = max(u32) - r.layer
		} else {
			k.layer = r.layer == UNLAYERED ? UNLAYERED : r.layer + 1
		}
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
	root_line_height: f32,   // px: what rlh means
	mutations:      u64,     // the document's mutation counter when this was computed
	serial:         u64,     // unique per pass: lets layout notice that styles changed even if nothing else did
	layout_serial:  u64,     // the serial of the last change that was not paint-only (paint_change.odin)
	line_height_normal: f32, // what `line-height: normal` means (a multiple of the font size), from the preferences
	quirks:         bool,    // the document is in quirks mode and its quirks apply (style.quirks_mode.enabled): layout's
	                         // quirks follow it
	line_quirk:     bool,    // ... quirks or limited-quirks mode: the line height calculation quirk applies (Quirks Mode §3.3)
	canvas:         css.Color,   // the color painted behind the whole page (root or body background, else Canvas)
	canvas_default: css.Color,   // Canvas of the root element's used color scheme
	canvas_schemes: [Scheme]css.Color,   // Canvas of each scheme (the preferences)
	root_scheme:    Scheme,              // the used color scheme of the root element (canvas, document scroll bar)
	page_scheme:    Color_Scheme_Value,  // <meta name="color-scheme"> of the document ({} = none or normal)
	scheme_metas:   [dynamic]base.Handle,   // every <meta name="color-scheme" content> of the document
	state:          State,       // the dynamic state these styles were computed for (target_id owned by `alloc`)
	base_used:      uint,        // arena use right after the full pass: what partial restyles add on top is waste
	thread_arenas:  [dynamic]^virtual.Arena,   // a parallel pass: the computed styles of each thread (parallel.odin)
	// animations (timeline.odin): a node whose `by_node` entry is an animated copy maps here to its cascaded style
	overlaid:       map[base.Handle]^Computed,
	animated:       Prop_Set,              // properties the last tick of the timeline may have changed in overlay records
	                                       // (rewritten in place: a painter that keeps paint values checks these)
	track_changes:  bool,                  // record in `changes` what partial restyles change
	changes:        [dynamic]Style_Change,
	counters_used:  bool,                  // counters or quotes appear: partial restyles must keep their values right
	motion:         bool,                  // some element has a transition or an animation
	journal:        Layout_Journal,        // what changed for layout since an earlier pass (journal.odin)
	pass_id:        u64,                   // unique per full pass, kept by partial restyles (the identity of the records' owner)
	// restyle_dom (restyle_dom.odin), for the timeline: elements shown again (display: none before), elements removed
	shown:          [dynamic]base.Handle,
	removed_any:    bool,
	forms_scan:     u8,                    // restyle_dom: 0 not looked, 1 no form element in the document, 2 some
	partial_bytes:  int,                   // memory of the threads of parallel partial restyles (counted as waste)
	// compiled style attributes and CSSOM declarations by text (inline_cache.odin), in `alloc`
	inline_rules:   map[string]^Rule,
	inline_decls:   map[string]Inline_Decl,
}

// A computed style replaced by a partial restyle: `old` is what was in effect (animated values included), `new` the
// newly cascaded style.
Style_Change :: struct {
	node:     base.Handle,
	old, new: ^Computed,
}

@(private) styled_serial: u64

styled_destroy :: proc(s: ^Styled) {
	if s == nil { return }
	delete(s.by_node)
	for a in s.thread_arenas { virtual.arena_destroy(a); free(a, base.process_allocator()) }   // (made on style threads: thread_arena_make)
	delete(s.thread_arenas)
	delete(s.overlaid)
	delete(s.changes)
	delete(s.shown)
	delete(s.scheme_metas)
	inline_cache_destroy(s)
	journal_destroy(s)
	virtual.arena_destroy(&s.arena)
	free(s)
}

// Address space reserved for the computed styles of one pass: one block, committed as it fills, so a recycled arena
// keeps its pages (a growing arena only keeps its first block).
@(private)
STYLED_RESERVE :: uint(1) << 33

// Like styled_destroy, but the memory is kept for the next full pass of `e` when it is not too large
// (style.recycle_bytes): a new pass then writes into pages already mapped instead of faulting fresh ones in.
styled_recycle :: proc(e: ^Engine, s: ^Styled) {
	if s == nil { return }
	if e == nil || e.has_spare || int(s.arena.total_used) > e.settings.recycle_bytes || s.arena.curr_block == nil || s.arena.curr_block.prev != nil {
		styled_destroy(s)
		return
	}
	delete(s.by_node)
	delete(s.overlaid)
	delete(s.changes)
	delete(s.shown)
	delete(s.scheme_metas)
	inline_cache_destroy(s)
	journal_destroy(s)
	for a in s.thread_arenas { virtual.arena_destroy(a); free(a, base.process_allocator()) }
	delete(s.thread_arenas)
	virtual.arena_free_all(&s.arena)
	e.spare = s.arena
	e.has_spare = true
	free(s)
}

// The cascaded style of `h`, without the effect of running animations and transitions.
base_style_of :: proc(s: ^Styled, h: base.Handle) -> ^Computed {
	if s == nil { return nil }
	if len(s.overlaid) > 0 { if b, ok := s.overlaid[h]; ok { return b } }
	return style_of(s, h)
}

// Gives every style a new serial: layout notices that something changed (and lays out again).
styled_touch :: proc(s: ^Styled) {
	styled_serial += 1
	s.serial = styled_serial
	s.layout_serial = s.serial
	journal_stamp(s)
}

style_of :: proc(s: ^Styled, h: base.Handle) -> ^Computed {
	if s == nil { return nil }
	i := int(base.handle_index(h))
	if i < 0 || i >= len(s.by_node) { return nil }
	c := s.by_node[i]
	if c != nil && c.node != h { return nil }   // a recycled slot
	return c
}

////////////////////////////////
// var()

@(private)
Var_Env :: struct {
	engine:   ^Engine,
	alloc:    runtime.Allocator,      // what outlives the element: resolved custom property texts
	scratch:  runtime.Allocator,      // the token trees of substitution (nil: alloc), dropped after the element
	// while custom properties of the element are being resolved:
	pending:  map[string]Custom_Cand,
	resolved: map[string]string,
	state:    map[string]u8,          // 1 = being resolved (a cycle if met again), 2 = done, 3 = invalid
	parent:   ^Custom_Props,
	final:    ^Custom_Props,          // set once resolution is finished
	budget:   int,
	cx:       ^Cx,                    // the element: registered properties compute their values with it (nil: as written)
}

// What an element gets for a custom property it does not declare: its parent's value, except for a registered property
// that does not inherit; then the registered initial value, if any.
@(private)
custom_inherited :: proc(env: ^Var_Env, name: string) -> (string, bool) {
	reg := registered(env.engine, name)
	if env.parent != nil && (reg == nil || reg.inherits) {
		if v, ok := custom_get(env.parent, name); ok { return v, true }
	}
	if reg != nil && reg.has_initial { return reg.initial, true }
	return "", false
}

@(private)
var_lookup :: proc(env: ^Var_Env, name: string, depth: int) -> (string, bool) {
	if env.final != nil {
		if v, ok := custom_get(env.final, name); ok { return v, true }
		if reg := registered(env.engine, name); reg != nil && reg.has_initial { return reg.initial, true }
		return "", false
	}
	if cand, has := env.pending[name]; has && cand.valid {
		switch env.state[name] {
		case 1, 3: return "", false
		case 2: return env.resolved[name], true
		}
		env.state[name] = 1
		reg := registered(env.engine, name)
		text: string
		ok: bool
		switch css_wide_keyword(cand.decl.value) {
		case "initial":
			// the guaranteed-invalid value, or the registered initial value
			if reg != nil && reg.has_initial { text, ok = reg.initial, true }
		case "inherit":
			if env.parent != nil { text, ok = custom_get(env.parent, name) }
			if !ok && reg != nil && reg.has_initial { text, ok = reg.initial, true }
		case "unset", "revert", "revert-layer":
			text, ok = custom_inherited(env, name)
		case:
			vals: []css.Value
			vals, ok = substitute(env, cand.decl.value, depth + 1)
			if ok {
				if reg != nil && !reg.universal && env.cx != nil {
					text, ok = registered_compute(env.cx, reg, vals, env.alloc)
					// invalid at computed-value time: as if `unset`
					if !ok { text, ok = custom_inherited(env, name) }
				} else {
					text = css.serialize_values(vals, env.alloc)
				}
			} else if reg != nil {
				text, ok = custom_inherited(env, name)
			}
		}
		if !ok {
			env.state[name] = 3
			return "", false
		}
		env.resolved[name] = text
		env.state[name] = 2
		return text, true
	}
	return custom_inherited(env, name)
}

@(private)
substitute :: proc(env: ^Var_Env, vs: []css.Value, depth: int) -> ([]css.Value, bool) {
	s := &env.engine.settings
	if depth > s.max_var_depth { return nil, false }
	sa := env.scratch.procedure != nil ? env.scratch : env.alloc
	out := make([dynamic]css.Value, sa)
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
				parsed := css.parse_component_values(text, parse_options(s), sa)
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
	touched_set: Prop_Set,     // the same properties as a set: build_style puts `touched` in enum order from it
	cust_map:  map[string]Custom_Cand,   // the element's custom property candidates, resolved values and states (build_style): kept between elements
	res_map:   map[string]string,
	state_map: map[string]u8,
	lists:    [4][dynamic]Entry,   // matched entries: the element, ::before, ::after, ::selection
	gate_probe: []bool,        // media_gate.odin: the entries of the gates in it are the only ones matched, on or off (which elements a flip reaches)
	compare:  bool,            // partial restyle: keep the old computed style when nothing changed
	changed:  bool,            // ... and report whether some element really changed
	layout_changed: bool,      // ... in a way that is not paint-only (paint_change.odin)
	alloc:    runtime.Allocator,   // where computed styles go: the Styled's arena, or this thread's in a parallel pass
	scratch:  virtual.Arena,       // what styling one element needs only while it runs (var() substitution: build_style)
	stats:    Compile_Stats,   // merged into the engine by pass_destroy (on the thread that owns the engine)
	counters: ^Counter_State,  // full pass: counters and quotes, resolved in tree order
	unscoped: bool,            // partial restyle: a change reaches counters, the caller must do a full pass
	// shadow trees (scope.odin): the element being styled's encapsulation depth; contexts of trees and hosts met
	own_depth: u16,
	ctx_cache: map[base.Handle]Elem_Ctx,
	host_ctx:  map[base.Handle]Elem_Ctx,
	fs_chain:  map[base.Handle]struct{},   // the ancestors of the fullscreen element (host-including), when there is one
	made_with: runtime.Allocator,          // what allocated the Pass: a style thread's (the process heap), freed by the caller
}

@(private)
consider :: proc(p: ^Pass, cust: ^map[string]Custom_Cand, rule: ^Rule, spec: css.Specificity, parent: ^Computed, ctx: u16) {
	if rule.cq != nil && !container_conditions_hold(rule.cq, parent != nil ? parent.containers : nil, parent != nil ? parent.custom : nil) { return }
	for &d in rule.decls {
		k := make_key(rule, d.important, spec, ctx)
		cand := &p.ws[d.prop]
		if !cand.valid {
			append(&p.touched, d.prop)
			ps_add(&p.touched_set, d.prop)
			cand^ = Cand{&d, k, rule.origin, true}
		} else if key_ge(k, cand.key) {
			cand^ = Cand{&d, k, rule.origin, true}
		}
	}
	if len(rule.customs) > 0 {
		if cust^ == nil { cust^ = make(map[string]Custom_Cand, max(16, len(rule.customs) * 2)) }   // (kept by the pass: build_style)
		for &cd in rule.customs {
			k := make_key(rule, cd.important, spec, ctx)
			old, has := cust[cd.name]
			if !has || !old.valid || key_ge(k, old.key) { cust[cd.name] = Custom_Cand{&cd, k, true} }
		}
	}
}

@(private)
collect_entries :: proc(p: ^Pass, el: base.Handle, n: ^dom.Node, ancestors: ^Bloom, ctx: Elem_Ctx) {
	check :: proc(p: ^Pass, el: base.Handle, list: []Entry, ancestors: ^Bloom) {
		for &ent in list {
			if !entry_live(p, &ent) { continue }
			slot: int
			#partial switch ent.complex.pseudo_element {
			case .None: slot = 0
			case .Before: slot = 1
			case .After: slot = 2
			case .Selection: slot = 3
			case: continue
			}
			rejected := false
			for k in 0 ..< int(ent.n_anc) { if !bloom_has(ancestors, ent.anc[k]) { rejected = true; break } }
			if rejected { continue }
			if matches_complex(&p.mc, el, ent.complex) {
				x := ent
				x.ctx = p.own_depth
				append(&p.lists[slot], x)
			}
		}
	}
	for i in 0 ..< 4 { clear(&p.lists[i]) }
	p.own_depth = ctx.depth
	rs := ctx.set != nil ? ctx.set : &p.e.rules
	p.mc.featureless = ctx.host
	defer p.mc.featureless = base.NIL_HANDLE
	if dom.has_shadow_trees(p.mc.doc) { shadow_entries(p, el, n, ctx) }
	ix := &rs.index
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
	case .Color_Scheme, .Color, .Background_Color, .Background_Image, .Text_Decoration_Color, .Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color, .Outline_Color, .Box_Shadow, .Text_Shadow, .Caret_Color, .Accent_Color, .Text_Fill_Color, .Scrollbar_Color:
		return true
	}
	return false
}

@(private)
build_style :: proc(p: ^Pass, h: base.Handle, parent: ^Computed, entries: []Entry, inline_rule: ^Rule) -> ^Computed {
	s := p.s
	e := p.e
	a := p.alloc
	// the tables of custom properties are the pass's, emptied for each element: made again for every element they were 9 %
	// of a style pass on a page whose every element declares custom properties (Tailwind's `*, ::before, ::after` reset)
	cust := p.cust_map
	if cust != nil { clear(&cust) }
	defer {
		p.cust_map = cust
	}
	for ent in entries { consider(p, &cust, ent.rule, ent.complex.specificity, parent, ent.ctx) }
	if inline_rule != nil { consider(p, &cust, inline_rule, css.Specificity{max(u32), 0, 0}, parent, p.own_depth) }
	// enum order = dependency order (font-size and color first): read back from the bit set the properties went into (a sort of
	// forty values of an enum was 6 % of a style pass)
	{
		n := 0
		for word, wi in p.touched_set.bits {
			for x := word; x != 0; x &= x - 1 {
				p.touched[n] = Prop(wi * 64 + int(intrinsics.count_trailing_zeros(x)))
				n += 1
			}
		}
		p.touched_set = {}
	}

	c := new(Computed, a)
	c^ = s.initial^
	c.node = h
	c.inherits = {}
	if parent != nil {
		for pr in inherited_list { copy_prop(c, parent, pr) }
		c.custom = parent.custom
		c.inherits = inherited_set
		c.content_language = parent.content_language   // `lang` inherits; overridden below by the element's own attribute
	}
	// the content language (CSS `lang`, for a face's locale forms: the `locl` feature) comes from the element's `lang`
	// or `xml:lang`, else the parent's. Only an element that declares one clones a string (a subtree then shares the
	// parent's by copying its header), so this stays off the hot path of the ordinary element.
	if n := dom.get(p.mc.doc, h); n != nil && n.kind == .Element {
		lv, has := attr(n, "lang")
		if !has { lv, has = attr(n, "xml:lang") }
		if has {
			t := strings.trim_space(lv)
			if t != c.content_language { c.content_language = t == "" ? "" : strings.clone(t, a) }
		}
	}
	cx := Cx{settings = &e.settings, parent = parent, initial = s.initial, c = c, alloc = a}
	cx.cenv = css.Color_Env{system = system_color, user = &e.settings}
	scheme_settle(&cx, s.page_scheme, e.env.prefers_dark)
	cx.lc = css.Length_Context{
		font_size = f64(c.font_size), root_font_size = f64(s.root_font_size > 0 ? s.root_font_size : e.settings.default_font_size),
		x_height = f64(c.font_size) * css.X_HEIGHT_EM, ch = f64(c.font_size) * css.CH_EM, vw = e.env.width, vh = e.env.height,
		line_height = f64(used_line_height(c, s.line_height_normal)), root_line_height = f64(s.root_line_height),
	}
	container_units(&cx.lc, parent != nil ? parent.containers : nil)

	// custom properties (the maps exist only for elements that declare some)
	// one budget for every substitution of the element (custom properties and declarations): what var() may cost one
	// element is bounded, whatever the number of its declarations; the token trees go to the pass's scratch arena
	scratch := virtual.arena_temp_begin(&p.scratch)
	defer virtual.arena_temp_end(scratch)
	env := Var_Env{engine = e, alloc = a, scratch = virtual.arena_allocator(&p.scratch), budget = e.settings.max_var_bytes, cx = &cx}
	env.parent = c.custom
	defer {   // (a table that grew while it was used is another block of memory: the pass keeps the one it has now)
		if env.resolved != nil { p.res_map = env.resolved }
		if env.state != nil { p.state_map = env.state }
	}
	// registered properties that do not inherit stop here: the map is copied without them
	drops_noninherited := e.registered_noninherited > 0 && c.custom != nil && carries_noninherited(e, c.custom)
	if len(cust) > 0 || drops_noninherited {
		env.pending = cust   // (the element's candidates, read only from here)
		env.resolved, env.state = p.res_map, p.state_map
		if env.resolved == nil { env.resolved = make(map[string]string) } else { clear(&env.resolved) }
		if env.state == nil { env.state = make(map[string]u8) } else { clear(&env.state) }
		// resolved first: when every declared property ends as the parent has it (a universal reset such as Tailwind's
		// `*, ::before, ::after { --tw-…: initial }` on every element), the parent's table is shared, not copied
		Resolved_Custom :: struct { name, text: string, ok: bool }
		res := make([]Resolved_Custom, len(cust), context.temp_allocator)
		same := !drops_noninherited
		i := 0
		for name, cand in cust {
			text: string
			ok: bool
			// `initial` of an unregistered property: the guaranteed-invalid value, nothing to resolve
			if !(cand.valid && e.registered == nil && css_wide_keyword(cand.decl.value) == "initial") {
				text, ok = var_lookup(&env, name, 0)
			}
			res[i] = {name, text, ok}
			i += 1
			if same {
				pv, pok := "", false
				if c.custom != nil { pv, pok = custom_get(c.custom, name) }
				same = pok == ok && (!ok || pv == text)
			}
		}
		if !same {
			// a layer of the element's own names over what it inherits (custom_props.odin)
			props := custom_begin(c.custom, e.settings.custom_max_layers, a)
			if drops_noninherited {
				for name, reg in e.registered { if !reg.inherits { custom_remove(props, name, a) } }
			}
			for r in res {
				if r.ok { custom_set(props, r.name, r.text) } else { custom_remove(props, r.name, a) }
			}
			c.custom = props
		}
	}
	empty_props := Custom_Props{}
	env.final = c.custom != nil ? c.custom : &empty_props
	env.pending = nil

	var_decls: [dynamic]^Pre_Decl
	for pr in p.touched {
		cand := p.ws[pr]
		if cand.decl.has_var {
			if var_decls == nil { var_decls = make([dynamic]^Pre_Decl, context.temp_allocator) }
			append(&var_decls, cand.decl)
		}
		// `revert` and `revert-layer` go back to the declaration that would have won without the current origin or
		// layer; a chain of them is followed (bounded: every step leaves a layer or an origin behind)
		for _ in 0 ..< 64 {
			if cand.origin == .Author {
				// colors or fonts from pages off: the page's declaration is reverted, to the browser's own value (links keep
				// LinkText, headings their size) rather than the inherited or initial one
				if (!e.settings.author_colors && is_color_prop(pr)) || (!e.settings.author_fonts && (pr == .Font_Family || pr == .Font_Size)) {
					if prev, found := revert_candidate(entries, inline_rule, pr, cand.key, true, parent, p.own_depth); found { cand = prev; continue }
					apply_unset(&cx, pr)
					break
				}
			}
			vals := cand.decl.value
			if cand.decl.has_var {
				sub, ok := substitute(&env, vals, 0)
				if !ok { apply_unset(&cx, pr); break }
				vals = sub
			}
			if cand.decl.short != .None {
				longs, ok := expand_shorthand(cand.decl.short, vals, env.scratch)   // (short: only with var())
				found := false
				if ok { for l in longs { if l.prop == pr { vals = l.vals; found = true; break } } }
				if !found { apply_unset(&cx, pr); break }
			}
			switch kw := css_wide_keyword(vals); kw {
			case "inherit":
				copy_prop(c, parent != nil ? parent : s.initial, pr)
				ps_add(&cx.explicit, pr)
				if parent != nil { ps_add(&c.inherits, pr) }
			case "initial": copy_prop(c, s.initial, pr); ps_remove(&c.inherits, pr)
			case "unset": apply_unset(&cx, pr)
			case "revert", "revert-layer":
				if prev, found := revert_candidate(entries, inline_rule, pr, cand.key, kw == "revert", parent, p.own_depth); found {
					cand = prev
					continue
				}
				apply_unset(&cx, pr)
			case:
				if apply_prop(&cx, pr, vals) { ps_remove(&c.inherits, pr) } else { apply_unset(&cx, pr) }
			}
			break
		}
		if pr == .Color_Scheme || pr == .Color { scheme_settle(&cx, s.page_scheme, e.env.prefers_dark) }
		if pr == .Font_Family {
			generic_family_adjust(&cx)
			cx.lc.line_height = f64(used_line_height(c, s.line_height_normal))
		}
		if pr == .Font_Size {
			cx.lc.font_size = f64(c.font_size)
			cx.lc.x_height = f64(c.font_size) * css.X_HEIGHT_EM
			cx.lc.ch = f64(c.font_size) * css.CH_EM
		}
		if pr == .Font_Size || pr == .Line_Height { cx.lc.line_height = f64(used_line_height(c, s.line_height_normal)) }
	}
	for pr in p.touched { p.ws[pr] = {} }
	clear(&p.touched)
	// an animation may set registered custom properties: what depends on them is recomputed per keyframe
	if len(var_decls) > 0 && len(e.registered) > 0 && has_animations(c) {
		// copied with their values: the style must not point into rules that a rebuild frees
		list := make([]Pre_Decl, len(var_decls), a)
		for d, i in var_decls { list[i] = d^ }
		deep_clone(&list, type_info_of([]Pre_Decl), a)
		c.anim_vars = list
	}
	finish_style(&cx, h)
	if len(p.fs_chain) > 0 { if _, above := p.fs_chain[h]; above { fullscreen_ancestor_reset(c) } }
	if e.container_dependent || c.container_type != .Normal || (parent != nil && parent.containers != nil) {
		c.containers = container_chain(e, c, parent, a)
	}
	return c
}

// The declaration of `pr` that wins once the origin (`revert`) or the cascade layer (`revert-layer`) of `from` is left
// out: the strongest among those strictly below that boundary.
@(private)
revert_candidate :: proc(entries: []Entry, inline_rule: ^Rule, pr: Prop, from: Cascade_Key, whole_origin: bool, parent: ^Computed, own_depth: u16) -> (best: Cand, found: bool) {
	below :: proc(k, from: Cascade_Key, whole_origin: bool) -> bool {
		if whole_origin {
			// author levels are 2 (normal) and 3 (important); user 1 and 4; UA 0 and 5: leave the origin out entirely
			origin_of :: proc(level: u8) -> int { switch level { case 0, 5: return 0; case 1, 4: return 1 }; return 2 }
			return origin_of(k.level) < origin_of(from.level) && k.level < from.level
		}
		if k.level != from.level { return k.level < from.level }
		if k.ctx != from.ctx { return k.ctx < from.ctx }
		return k.layer < from.layer
	}
	consider_rule :: proc(r: ^Rule, spec: css.Specificity, ctx: u16, pr: Prop, from: Cascade_Key, whole_origin: bool, parent: ^Computed, best: ^Cand, found: ^bool) {
		if r.cq != nil && !container_conditions_hold(r.cq, parent != nil ? parent.containers : nil, parent != nil ? parent.custom : nil) { return }
		for &d in r.decls {
			if d.prop != pr { continue }
			k := make_key(r, d.important, spec, ctx)
			if !below(k, from, whole_origin) { continue }
			if !found^ || key_ge(k, best.key) { best^ = Cand{&d, k, r.origin, true}; found^ = true }
		}
	}
	for ent in entries { consider_rule(ent.rule, ent.complex.specificity, ent.ctx, pr, from, whole_origin, parent, &best, &found) }
	if inline_rule != nil { consider_rule(inline_rule, css.Specificity{max(u32), 0, 0}, own_depth, pr, from, whole_origin, parent, &best, &found) }
	return
}

@(private)
carries_noninherited :: proc(e: ^Engine, props: ^Custom_Props) -> bool {
	for name, reg in e.registered { if !reg.inherits && custom_has(props, name) { return true } }
	return false
}

// The line height in px (what lh means): `normal` is `line_height_normal` times the font size.
used_line_height :: proc(c: ^Computed, normal: f32) -> f32 {
	switch c.line_height.kind {
	case .Number: return c.line_height.v * c.font_size
	case .Length: return c.line_height.v
	case .Normal:
	}
	return (normal > 0 ? normal : 1.2) * c.font_size
}

// `unset`: inherit when the property is inherited, otherwise its initial value.
@(private)
apply_unset :: proc(cx: ^Cx, pr: Prop) {
	if is_inherited(pr) && cx.parent != nil { copy_prop(cx.c, cx.parent, pr); ps_add(&cx.c.inherits, pr); return }
	copy_prop(cx.c, cx.initial, pr)
	ps_remove(&cx.c.inherits, pr)
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

// Fields computed from others: the legacy `white_space` from white-space-collapse and text-wrap-mode. (Preserved
// breaks without wrapping has no legacy value: Pre_Line, and text_wrap_mode says nowrap.)
derive_fields :: proc(c: ^Computed) {
	wrap := c.text_wrap_mode == .Wrap
	switch c.white_space_collapse {
	case .Collapse, .Discard: c.white_space = wrap ? .Normal : .Nowrap
	case .Preserve, .Preserve_Spaces: c.white_space = wrap ? .Pre_Wrap : .Pre
	case .Preserve_Breaks: c.white_space = .Pre_Line
	case .Break_Spaces: c.white_space = .Break_Spaces
	}
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
		if !ps_has(cx.explicit, pr) { c.border_color[side] = c.color }
	}
	if !ps_has(cx.explicit, .Outline_Color) { c.outline_color = c.color }
	if !ps_has(cx.explicit, .Text_Decoration_Color) { c.text_decoration_color = c.color }
	derive_fields(c)
	// a query container has size containment in the axes it measures, layout and style containment (CSS Contain 3 §6.2)
	switch c.container_type {
	case .Normal:
	case .Size: c.contain += {.Size, .Layout, .Style}
	case .Inline_Size: c.contain += {.Inline_Size, .Layout, .Style}
	}
	if c.position == .Absolute || c.position == .Fixed || c.float != .None { c.display = blockify(c.display) }
	// CSS Overflow 3 §3.1: visible / clip become auto / hidden only when the other axis is neither (overflow-x: clip
	// alone made the box a scroll container, and broke position: sticky inside it)
	vis_or_clip :: #force_inline proc(o: Overflow) -> bool { return o == .Visible || o == .Clip }
	if vis_or_clip(c.overflow_x) != vis_or_clip(c.overflow_y) {
		o := vis_or_clip(c.overflow_x) ? &c.overflow_x : &c.overflow_y
		o^ = o^ == .Visible ? .Auto : .Hidden
	}
}

// An ancestor of the fullscreen element, as the top layer would leave it for the element: no stacking context of its own,
// and nothing that makes it the containing block of a fixed box.
@(private)
fullscreen_ancestor_reset :: proc(c: ^Computed) {
	c.z_auto = true
	c.transform, c.translate, c.rotate, c.scale = nil, {}, {}, {}
	c.perspective = 0
	c.filter, c.backdrop_filter, c.clip_path = nil, nil, nil
	c.opacity = 1
	c.isolation, c.mix_blend_mode = {}, {}
	c.will_change = nil
	c.contain = {}
	c.mask_images = nil
}

// The names of custom properties declared by text parsed into the temp allocator (a style attribute, hints) become
// keys of the element's Custom_Props, which live as long as the style pass: they are copied into the pass's memory.
@(private)
own_custom_names :: proc(customs: []Custom_Decl, a: runtime.Allocator) {
	for &cd in customs { cd.name = strings.clone(cd.name, a) }
}

@(private)
may_have_content :: proc(entries: []Entry) -> bool {
	for ent in entries {
		for d in ent.rule.decls { if d.prop == .Content || d.prop == .Animation_Name { return true } }
	}
	return false
}

@(private)
compute_element :: proc(p: ^Pass, h: base.Handle, n: ^dom.Node, parent: ^Computed, ancestors: ^Bloom, ctx: Elem_Ctx = {}) -> ^Computed {
	collect_entries(p, h, n, ancestors, ctx)
	add_hint_entry(p, h, n)

	inline_rule: ^Rule
	if text, ok := attr(n, "style"); ok && p.e.settings.author_stylesheets && text != "" { inline_rule = inline_rule_of(p, text) }
	// the element's own lists are consumed before ::before / ::after reuse the buffers
	before_entries, after_entries, selection_entries: [dynamic]Entry
	if len(p.lists[1]) > 0 { before_entries = make([dynamic]Entry, context.temp_allocator); append(&before_entries, ..p.lists[1][:]) }
	if len(p.lists[2]) > 0 { after_entries = make([dynamic]Entry, context.temp_allocator); append(&after_entries, ..p.lists[2][:]) }
	if len(p.lists[3]) > 0 { selection_entries = make([dynamic]Entry, context.temp_allocator); append(&selection_entries, ..p.lists[3][:]) }
	c := build_style(p, h, parent, p.lists[0][:], inline_rule)
	if len(p.e.forced_hidden) > 0 { if h in p.e.forced_hidden { c.display = .None } }

	for i in 1 ..< 3 {
		entries := i == 1 ? before_entries : after_entries
		// a pseudo-element has a box only when its content computes to something: no matched rule declaring content
		// (it is not inherited, and its initial value is normal) means none, whatever else the rules say (Tailwind's
		// `*, ::before, ::after { --tw-…: initial }` matches every element's pseudo-elements). An animation could set it.
		if len(entries) == 0 || !may_have_content(entries[:]) { continue }
		pc := build_style(p, h, c, entries[:], nil)
		if pc.display == .None || pc.content.kind != .Items { continue }
		if i == 1 { c.before = pc } else { c.after = pc }
	}
	// ::selection: only its colors are used (the painter looks for the nearest element that has one)
	if len(selection_entries) > 0 { c.selection = build_style(p, h, c, selection_entries[:], nil) }
	return c
}

@(private)
pass_make :: proc(e: ^Engine, s: ^Styled, doc: ^dom.Document, state: State) -> ^Pass {
	p := new(Pass)
	p.made_with = context.allocator
	p.e, p.s, p.opt = e, s, parse_options(&e.settings)
	p.alloc = s.alloc
	match_ctx_init(&p.mc, doc, state)
	// the fullscreen element is in the top layer: what its ancestors would do to it (a stacking context under a masthead,
	// a transform or filter that makes them its containing block) does not apply (fullscreen_ancestor_reset)
	if state.fullscreen != base.NIL_HANDLE && dom.get(doc, state.fullscreen) != nil {
		p.fs_chain = make(map[base.Handle]struct{})
		for cur := dom.parent_or_host(doc, state.fullscreen); cur != base.NIL_HANDLE; cur = dom.parent_or_host(doc, cur) { p.fs_chain[cur] = {} }
	}
	// the rest of the top layer (showing popovers: engine_set_top_layer) likewise
	for el in e.top_layer {
		if dom.get(doc, el) == nil { continue }
		if p.fs_chain == nil { p.fs_chain = make(map[base.Handle]struct{}) }
		for cur := dom.parent_or_host(doc, el); cur != base.NIL_HANDLE; cur = dom.parent_or_host(doc, cur) { p.fs_chain[cur] = {} }
	}
	// a popover nested in another one stays in the top layer itself (its own z-index, its own box)
	for el in e.top_layer { delete_key(&p.fs_chain, el) }
	p.touched = make([dynamic]Prop)
	for i in 0 ..< 4 { p.lists[i] = make([dynamic]Entry) }
	return p
}

@(private)
pass_destroy :: proc(p: ^Pass) {
	stats_merge(p.e, p.stats)
	match_ctx_destroy(&p.mc)
	delete(p.fs_chain)
	delete(p.touched)
	delete(p.cust_map); delete(p.res_map); delete(p.state_map)
	for i in 0 ..< 4 { delete(p.lists[i]) }
	virtual.arena_destroy(&p.scratch)
	free(p, p.made_with)
}

// Styles `root` and everything below it. `parent` is the computed style of root's parent (nil for the document element);
// `ancestors` the filter of root's ancestors.
@(private)
style_subtree :: proc(p: ^Pass, root: base.Handle, parent: ^Computed, ancestors: Bloom, descend := true, root_ctx: Maybe(Elem_Ctx) = nil) {
	doc := p.mc.doc
	s := p.s
	shadows := dom.has_shadow_trees(doc)
	// `exit` frames close an element after its subtree (counter scopes and ::after are resolved there). The walk is
	// that of the flat tree; `ctx` is the tree each element is matched in (scope.odin).
	Frame :: struct { h: base.Handle, parent: ^Computed, bloom: Bloom, hidden: bool, exit: bool, c: ^Computed, ctx: Elem_Ctx }
	stack := make([dynamic]Frame, context.temp_allocator)
	rc, has_rc := root_ctx.?
	if !has_rc && shadows { rc = node_ctx(p, root) }
	append(&stack, Frame{h = root, parent = parent, bloom = ancestors, hidden = parent != nil && hidden_above(p, root), ctx = rc})
	for len(stack) > 0 {
		f := pop(&stack)
		if f.exit {
			if p.counters != nil { counters_exit(p.counters, doc, f.h, f.c, f.hidden, p.alloc) }
			continue
		}
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		c := compute_element(p, f.h, n, f.parent, &f.bloom, f.ctx)
		hidden := f.hidden || c.display == .None
		idx := int(base.handle_index(f.h))
		for len(s.by_node) <= idx { append(&s.by_node, nil) }   // never in a parallel pass: sized beforehand
		if p.compare {
			old := s.by_node[idx]
			if old != nil && old.node != f.h { old = nil }
			old_base := old
			if old != nil && len(s.overlaid) > 0 { if b, ok := s.overlaid[f.h]; ok { old_base = b } }
			if !counters_carry_over(s, doc, f.h, old_base, c, s.alloc) { p.unscoped = true }
			if old_base != nil && computed_equal(old_base, c) {
				c = old_base
			} else {
				p.changed = true
				if !p.layout_changed && !layout_equal(old_base, c) { p.layout_changed = true }
				if s.track_changes { append(&s.changes, Style_Change{node = f.h, old = old, new = c}) }
				journal_add(s, f.h, max(layout_level(old, c), Change_Level.Paint))   // a new record: readers re-point
				delete_key(&s.overlaid, f.h)   // the animation layer is rebuilt on top of the new style
				if old_base != nil && old_base.display == .None && c.display != .None { append(&s.shown, f.h) }
				s.by_node[idx] = c
			}
		} else {
			s.by_node[idx] = c
			if p.counters != nil { counters_enter(p.counters, doc, f.h, n, c, hidden, p.alloc) } else { resolve_static(doc, f.h, c, p.alloc) }
		}
		if f.parent == nil && s.root_font_size == 0 {
			s.root_font_size = c.font_size
			s.root_line_height = used_line_height(c, s.line_height_normal)
		}
		if !sync.atomic_load(&s.motion) && (has_transitions(c) || has_animations(c)) { sync.atomic_store(&s.motion, true) }   // threads of a parallel pass may race here
		if !descend && f.h == root { break }
		if p.counters != nil { append(&stack, Frame{h = f.h, hidden = hidden, exit = true, c = c}) }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		if !shadows {
			for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev {
				append(&stack, Frame{h = ch, parent = c, bloom = child_bloom, hidden = hidden})
			}
			continue
		}
		for ch := dom.flat_last_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_prev(doc, ch) {
			append(&stack, Frame{h = ch, parent = c, bloom = child_bloom, hidden = hidden, ctx = child_ctx(p, f.h, f.ctx, ch)})
		}
	}
}

// Some ancestor of `h` has display: none (its subtree generates no boxes).
@(private)
hidden_above :: proc(p: ^Pass, h: base.Handle) -> bool {
	for anc := flat_parent_element(p.mc.doc, h); anc != base.NIL_HANDLE; anc = flat_parent_element(p.mc.doc, anc) {
		if cs := base_style_of(p.s, anc); cs != nil && cs.display == .None { return true }
	}
	return false
}

// Computes the style of every element of the document. With a thread pool and at least `min_nodes` nodes, the
// work is shared between threads (parallel.odin); the result is the same.
compute_styles :: proc(e: ^Engine, doc: ^dom.Document, state: State, pool: ^host.Thread_Pool = nil, min_nodes := 0) -> ^Styled {
	if e.dirty { engine_rebuild(e, doc) }
	shadow_prepare(e, doc)
	clear(&e.shadow.changed)   // a full pass covers whatever changed
	clear(&e.container_pending)
	clear_gates_pending(e)   // (the gates hold what the environment says now: this pass reads them so)
	s := styled_make(e, doc, state)
	if pool != nil && host.thread_pool_size(pool) > 1 && doc.nodes.count >= min_nodes {
		// counters and quotes need tree order: the threads compute everything else, then one ordered walk resolves them
		style_document_parallel(e, s, doc, state, pool)
		s.counters_used = counters_post_pass(s, doc, e.settings.counters_max_listed)
	} else {
		p := pass_make(e, s, doc, state)
		defer pass_destroy(p)
		counters := counter_state_make(e.settings.counters_max_listed)
		p.counters = &counters
		root := dom.get(doc, doc.root)
		for c := root.first_child; c != base.NIL_HANDLE; c = dom.get(doc, c).next {
			style_subtree(p, c, nil, Bloom{})
		}
		s.counters_used = counters.used
	}
	s.base_used = s.arena.total_used
	update_canvas(s, doc)
	return s
}

// Resolves counters and quotes over styles already computed (after a parallel pass), in tree order, exactly as the
// sequential pass does while it goes. Returns whether any counter or quote was used.
@(private)
counters_post_pass :: proc(s: ^Styled, doc: ^dom.Document, max_listed: int) -> bool {
	counters := counter_state_make(max_listed)
	Frame :: struct { h: base.Handle, hidden: bool, exit: bool, c: ^Computed }
	stack := make([dynamic]Frame, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for ch := root.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{h = ch}) }
	for len(stack) > 0 {
		f := pop(&stack)
		if f.exit { counters_exit(&counters, doc, f.h, f.c, f.hidden, s.alloc); continue }
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		c := style_of(s, f.h)
		if c == nil { continue }
		hidden := f.hidden || c.display == .None
		counters_enter(&counters, doc, f.h, n, c, hidden, s.alloc)
		append(&stack, Frame{h = f.h, hidden = hidden, exit = true, c = c})
		for ch := dom.flat_last_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_prev(doc, ch) { append(&stack, Frame{h = ch, hidden = hidden}) }
	}
	return counters.used
}

@(private)
styled_make :: proc(e: ^Engine, doc: ^dom.Document, state: State) -> ^Styled {
	s := new(Styled)
	if e.has_spare {
		s.arena = e.spare
		e.spare, e.has_spare = {}, false
	} else {
		_ = virtual.arena_init_growing(&s.arena, STYLED_RESERVE)
	}
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
	s.layout_serial = s.serial
	s.pass_id = s.serial
	s.line_height_normal = e.settings.line_height_normal
	s.quirks = e.settings.quirks_rules && doc.mode == .Quirks
	s.line_quirk = e.settings.quirks_rules && (doc.mode == .Quirks || doc.mode == .Limited_Quirks)
	for sc in Scheme { s.canvas_schemes[sc] = e.settings.colors[sc][.Canvas] }
	s.root_scheme = used_scheme({}, e.env.prefers_dark)
	s.canvas = s.canvas_schemes[s.root_scheme]
	s.canvas_default = s.canvas
	s.page_scheme, _ = page_color_scheme(doc, &s.scheme_metas)
	journal_init(e, s)
	return s
}

// The canvas takes the root element's background, else the body's (CSS Backgrounds 3 §2.11.2), else the preference.
@(private)
update_canvas :: proc(s: ^Styled, doc: ^dom.Document) {
	if r := dom.get(doc, doc.root); r != nil {
		for ch := r.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
			if rc := style_of(s, ch); rc != nil { s.root_scheme = rc.used_scheme; break }
		}
	}
	s.canvas_default = s.canvas_schemes[s.root_scheme]
	s.canvas = s.canvas_default
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
	return a.hover == b.hover && a.active == b.active && a.focus == b.focus && a.focus_visible == b.focus_visible && a.target_id == b.target_id && a.fullscreen == b.fullscreen && a.visited == b.visited
}

@(private)
changed_kinds :: proc(old, new: State) -> (k: State_Kinds) {
	if old.hover != new.hover { k += {.Hover} }
	if old.active != new.active { k += {.Active} }
	if old.focus != new.focus || old.focus_visible != new.focus_visible { k += {.Focus} }
	if old.target_id != new.target_id { k += {.Target} }
	if old.fullscreen != new.fullscreen { k += {.Fullscreen} }
	if old.visited != new.visited { k += {.Visited} }
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
			cur = dom.flat_parent(doc, cur)
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
	shadows := dom.has_shadow_trees(doc)
	deps := e.state_deps
	if shadows { deps += e.shadow.state_deps }
	if kinds & deps == {} { set_state(s, new_state); return false, true }
	if e.state_uses_has || (shadows && e.shadow.state_uses_has) { return false, false }
	if shadows && e.shadow.dirty { return false, false }
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
		// ... but for hosts, which match :focus while their shadow tree holds the focus
		if shadows {
			for f in ([2]base.Handle{old.focus, new_state.focus}) {
				for cur := dom.parent_or_host(doc, f); cur != base.NIL_HANDLE; cur = dom.parent_or_host(doc, cur) {
					if n := dom.get(doc, cur); n != nil && n.kind == .Element && n.shadow != base.NIL_HANDLE { changed_els[cur] = true }
				}
			}
		}
	}
	if .Fullscreen in kinds {
		if old.fullscreen != base.NIL_HANDLE { changed_els[old.fullscreen] = true }   // :fullscreen is exact
		if new_state.fullscreen != base.NIL_HANDLE { changed_els[new_state.fullscreen] = true }
		// ... and what is above it, which the top layer frees of its stacking contexts and transforms (fullscreen_ancestor_reset)
		for f in ([2]base.Handle{old.fullscreen, new_state.fullscreen}) {
			if f == base.NIL_HANDLE { continue }
			for cur := dom.parent_or_host(doc, f); cur != base.NIL_HANDLE; cur = dom.parent_or_host(doc, cur) {
				if n := dom.get(doc, cur); n != nil && n.kind == .Element { changed_els[cur] = true }
			}
		}
	}
	if .Visited in kinds {
		if old.visited != base.NIL_HANDLE { changed_els[old.visited] = true }
		if new_state.visited != base.NIL_HANDLE { changed_els[new_state.visited] = true }
	}
	if .Target in kinds {
		if old.target_id != "" { if h := dom.find_by_id(doc, old.target_id); h != base.NIL_HANDLE { changed_els[h] = true } }
		if new_state.target_id != "" { if h := dom.find_by_id(doc, new_state.target_id); h != base.NIL_HANDLE { changed_els[h] = true } }
	}

	// roots to restyle: the element itself, plus whole subtrees where a rule reaches beyond the element
	roots := make(map[base.Handle]bool, context.temp_allocator)   // value: restyle the entire subtree
	// the entries of each tree whose rules may see `x` change: its own tree's, its shadow tree's (a host), and the
	// ::slotted() / ::part() rules a slot or a host stands for
	State_Source :: struct { entries: []Entry, featureless: base.Handle }
	sources :: proc(p: ^Pass, x: base.Handle, shadows: bool) -> []State_Source {
		out := make([dynamic]State_Source, 0, 2, context.temp_allocator)
		if !shadows { append(&out, State_Source{p.e.rules.state_entries[:], base.NIL_HANDLE}); return out[:] }
		ctx := node_ctx(p, x)
		rs := ctx.set != nil ? ctx.set : &p.e.rules
		append(&out, State_Source{rs.state_entries[:], ctx.host})
		if n := dom.get(p.mc.doc, x); n != nil && n.shadow != base.NIL_HANDLE {
			sc := ctx_for_root(p, n.shadow)
			append(&out, State_Source{sc.set.state_entries[:], x})
		}
		return out[:]
	}
	for x in changed_els {
		if x not_in roots { roots[x] = false }
		for src in sources(p, x, shadows) {
			p.mc.featureless = src.featureless
			for &ent in src.entries {
				if ent.state & kinds == {} { continue }
				c := ent.complex
				last := len(c.compounds) - 1
				if c.pseudo_element == .Slotted || c.pseudo_element == .Part {
					// a slot's or a host's state reaching the elements slotted in it or its parts: its flat subtree
					for comp in c.compounds {
						ck, _ := compound_state(comp)
						if ck & kinds != {} && compound_could_match(&p.mc, x, comp) { roots[x] = true; break }
					}
					continue
				}
				for k in 0 ..< last {
					ck, _ := compound_state(c.compounds[k])
					if ck & kinds == {} { continue }
					if !compound_could_match(&p.mc, x, c.compounds[k]) { continue }
					sibling := false
					for j in k ..< last { if c.combinators[j] != .Child && c.combinators[j] != .Descendant { sibling = true } }
					target := x
					if sibling {
						if par := parent_element(&p.mc, x); par != base.NIL_HANDLE {
							target = par
						} else if r := dom.containing_shadow_root(doc, x); r != base.NIL_HANDLE {
							target = dom.host_of(doc, r)   // siblings at the top of a shadow tree: the host's flat subtree
						}
					}
					roots[target] = true
				}
			}
		}
		p.mc.featureless = base.NIL_HANDLE
	}

	for r, deep in roots {
		// a root inside a subtree that is restyled anyway adds nothing
		covered := false
		for anc := flat_parent_element(doc, r); anc != base.NIL_HANDLE; anc = flat_parent_element(doc, anc) {
			if roots[anc] { covered = true; break }
		}
		if covered { continue }
		if shadows && !dom.in_flat_tree(doc, r) { continue }   // not rendered: it has no style

		par := flat_parent_element(doc, r)
		parent_style: ^Computed
		bloom: Bloom
		if par != base.NIL_HANDLE {
			parent_style = base_style_of(s, par)
			for anc := par; anc != base.NIL_HANDLE; anc = flat_parent_element(doc, anc) { bloom_add_element(&bloom, dom.get(doc, anc)) }
		}
		old_style := base_style_of(s, r)
		rctx := node_ctx(p, r)
		// the root element's font size and line height are what rem and rlh mean everywhere: a change of them (html:hover,
		// :focus-within) needs a full pass (what was done is harmless: records replaced as a full pass would)
		root_moved :: proc(s: ^Styled, r: base.Handle, par: base.Handle) -> bool {
			if par != base.NIL_HANDLE { return false }
			ns := base_style_of(s, r)
			return ns != nil && (ns.font_size != s.root_font_size || used_line_height(ns, s.line_height_normal) != s.root_line_height)
		}
		if deep {
			style_subtree(p, r, parent_style, bloom, root_ctx = rctx)
			if p.unscoped || root_moved(s, r, par) { return false, false }
			continue
		}
		style_subtree(p, r, parent_style, bloom, descend = false, root_ctx = rctx)
		if p.unscoped || root_moved(s, r, par) { return false, false }
		// the element's own change may reach its descendants through inheritance
		new_style := base_style_of(s, r)
		if old_style != nil && new_style != nil && !inherited_equal(old_style, new_style) {
			n := dom.get(doc, r)
			child_bloom := bloom
			bloom_add_element(&child_bloom, n)
			for ch := dom.flat_first_child(doc, r); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
				style_subtree(p, ch, new_style, child_bloom, root_ctx = child_ctx(p, r, rctx, ch))
				if p.unscoped { return false, false }
			}
		}
	}
	set_state(s, new_state)
	if p.changed {
		styled_serial += 1
		s.serial = styled_serial
		if p.layout_changed { s.layout_serial = s.serial }
		journal_stamp(s)
		update_canvas(s, doc)
	}
	return p.changed, true
}

////////////////////////////////
// Comparing computed styles

@(private)
strings_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if a[i] != b[i] { return false } }
	return true
}

@(private)
inherited_equal :: proc(a, b: ^Computed) -> bool {
	for pr in inherited_list { if !prop_equal(a, b, pr) { return false } }
	return custom_equal(a.custom, b.custom)
}

// Value equality: every field of the two styles, pointers followed (see deep_equal). Fields without pointers or
// padding are compared as bytes. Calc trees are compared by structure.
computed_equal :: proc(a, b: ^Computed) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	props_init()
	for f in computed_fields {
		pa, pb := rawptr(uintptr(a) + f.offset), rawptr(uintptr(b) + f.offset)
		if f.plain {
			if mem.compare_ptrs(pa, pb, f.size) != 0 { return false }
		} else if !deep_equal(pa, pb, f.ti) {
			return false
		}
	}
	return true
}
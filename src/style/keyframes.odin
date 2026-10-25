package style

import "base:runtime"
import "core:slice"
import "core:strings"
import "wb:css"

// @keyframes (CSS Animations 1 §4): the rule of each name that wins (origin, then cascade layer, then document order),
// its keyframes merged by offset and sorted, the declarations compiled once per rebuild. Values are computed per element
// when an animation runs (they may use em, var(), currentcolor...): see `compute_keyframe`.

Keyframes_Ref :: struct {
	rule:   ^css.Rule,
	layer:  u32,
	order:  u32,
	origin: Origin,
}

Keyframe_Block :: struct {
	offset:     f32,          // 0..1
	decls:      []Pre_Decl,   // in declaration order (a later one wins); never !important, never animation-*/transition-*
	easing:     Easing,       // animation-timing-function given inside the keyframe
	has_easing: bool,
	props:      Prop_Set,
	customs:    []Custom_Decl,   // custom properties the keyframe sets: registered ones animate what uses them
}

Keyframes_Set :: struct {
	name:   string,
	frames: []Keyframe_Block,  // sorted by offset, one block per offset
	props:  Prop_Set,          // every property some keyframe sets
}

// Properties a keyframe cannot animate (CSS Animations 1 §4: they are ignored there).
not_in_keyframes :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Transition_Property, .Transition_Duration, .Transition_Timing_Function, .Transition_Delay, .Transition_Behavior,
	     .Animation_Name, .Animation_Duration, .Animation_Delay, .Animation_Iteration_Count, .Animation_Direction,
	     .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition, .Will_Change, .Direction:
		return true
	}
	return false
}

@(private)
compile_keyframes :: proc(e: ^Engine) { compile_keyframes_into(e, e.keyframes[:], &e.keyframe_sets) }

// The winning @keyframes of each name among `refs`, compiled into `out` (in e.alloc).
@(private)
compile_keyframes_into :: proc(e: ^Engine, refs: []Keyframes_Ref, out: ^map[string]^Keyframes_Set) {
	if out^ == nil { out^ = make(map[string]^Keyframes_Set) }
	winners := make(map[string]int, context.temp_allocator)
	stronger :: proc(a, b: Keyframes_Ref) -> bool {
		if a.origin != b.origin { return a.origin > b.origin }
		if a.layer != b.layer { return a.layer > b.layer }
		return a.order > b.order
	}
	for ref, i in refs {
		name := ref.rule.name
		if name == "" || strings.equal_fold(name, "none") { continue }
		if prev, ok := winners[name]; ok && !stronger(ref, refs[prev]) { continue }
		winners[name] = i
	}
	probe := probe_context(e, e.alloc)
	for name, i in winners {
		rule := refs[i].rule
		set := new(Keyframes_Set, e.alloc)
		set.name = strings.clone(name, e.alloc)
		blocks := make([dynamic]Keyframe_Block, e.alloc)
		for kf in rule.keyframes {
			compiled, customs := compile_declarations(e, kf.declarations, e.alloc)
			decls := make([dynamic]Pre_Decl, e.alloc)
			easing: Easing
			has_easing := false
			for d in compiled {
				if d.important { continue }   // !important inside a keyframe is ignored, the whole declaration
				if d.prop == .Animation_Timing_Function {
					if !d.has_var {
						if parsed, ok := parse_easing(&probe, d.value); ok { easing, has_easing = parsed, true }
					}
					continue
				}
				if not_in_keyframes(d.prop) { continue }
				append(&decls, d)
			}
			for off in kf.offsets {
				found := -1
				for b, k in blocks { if b.offset == off { found = k; break } }
				if found < 0 {
					append(&blocks, Keyframe_Block{offset = off})
					found = len(blocks) - 1
				}
				b := &blocks[found]
				merged := make([dynamic]Pre_Decl, e.alloc)
				append(&merged, ..b.decls)
				append(&merged, ..decls[:])
				b.decls = merged[:]
				if len(customs) > 0 {
					mc := make([dynamic]Custom_Decl, e.alloc)
					append(&mc, ..b.customs)
					for cd in customs { if !cd.important { append(&mc, cd) } }
					b.customs = mc[:]
				}
				if has_easing { b.easing, b.has_easing = easing, true }
				for d in decls { ps_add(&b.props, d.prop); ps_add(&set.props, d.prop) }
			}
		}
		slice.stable_sort_by(blocks[:], proc(a, b: Keyframe_Block) -> bool { return a.offset < b.offset })
		set.frames = blocks[:]
		out[set.name] = set
	}
}

// The compiled @keyframes of that name (nil when there is none).
keyframes_lookup :: proc(e: ^Engine, name: string) -> ^Keyframes_Set {
	if e == nil || name == "" { return nil }
	if k, ok := e.keyframe_sets[name]; ok { return k }
	return shadow_keyframes_lookup(e, name)
}

// The values one keyframe block gives an element: `base` is the element's style, `parent` its parent's. Only the
// properties in `block.props` and in `extra` are meaningful in the result; they are deep-copied into `alloc`. `extra`:
// the element's own properties that use registered custom properties the keyframe sets (`--angle: 90deg` animates the
// `rotate: var(--angle)` of the element: its value at each keyframe is interpolated like any other).
compute_keyframe :: proc(e: ^Engine, block: ^Keyframe_Block, base, parent, initial: ^Computed, root_font_size: f32, alloc: runtime.Allocator) -> (c: ^Computed, extra: Prop_Set) {
	c = new(Computed, alloc)
	c^ = base^
	cx := Cx{settings = &e.settings, parent = parent, initial = initial, c = c, alloc = alloc}
	cx.cenv = css.Color_Env{dark = base.used_scheme == .Dark, system = system_color, user = &e.settings}
	cx.lc = css.Length_Context{
		font_size = f64(c.font_size), root_font_size = f64(root_font_size > 0 ? root_font_size : e.settings.default_font_size),
		x_height = f64(c.font_size) * css.X_HEIGHT_EM, ch = f64(c.font_size) * css.CH_EM, vw = e.env.width, vh = e.env.height,
	}
	container_units(&cx.lc, parent != nil ? parent.containers : nil)
	env := Var_Env{engine = e, alloc = alloc, budget = e.settings.max_var_bytes}
	empty := Custom_Props{}
	env.final = base.custom != nil ? base.custom : &empty
	// registered custom properties of the keyframe, computed against the element's own values
	animated := make(map[string]bool, context.temp_allocator)
	if len(block.customs) > 0 && len(e.registered) > 0 {
		merged := custom_begin(base.custom, e.settings.custom_max_layers, alloc)
		for cd in block.customs {
			reg := registered(e, cd.name)
			if reg == nil || reg.universal { continue }   // unregistered values cannot be interpolated
			vals := cd.value
			if contains_var(vals) {
				env.budget = e.settings.max_var_bytes
				sub, ok := substitute(&env, vals, 0)
				if !ok { continue }
				vals = sub
			}
			text, ok := registered_compute(&cx, reg, vals, alloc)
			if !ok { continue }
			custom_set(merged, cd.name, text)
			animated[cd.name] = true
		}
		if len(animated) > 0 { env.final = merged }
	}
	if len(animated) > 0 && len(base.anim_vars) > 0 {
		deps := make([dynamic]Pre_Decl, context.temp_allocator)
		for d in base.anim_vars { if mentions_var(d.value, animated) { append(&deps, d) } }
		slice.stable_sort_by(deps[:], proc(a, b: Pre_Decl) -> bool { return int(a.prop) < int(b.prop) })
		for d in deps {
			env.budget = e.settings.max_var_bytes
			vals, ok := substitute(&env, d.value, 0)
			if !ok { continue }
			if d.short != .None {
				longs, good := expand_shorthand(d.short, vals, alloc)
				found := false
				if good { for l in longs { if l.prop == d.prop { vals = l.vals; found = true; break } } }
				if !found { continue }
			}
			if css_wide_keyword(vals) != "" || !apply_prop(&cx, d.prop, vals) { continue }
			ps_add(&extra, d.prop)
		}
	}
	// dependency order (font-size, then color, then the rest); among equal properties, the later declaration wins
	decls := block.decls
	sorted := make([]Pre_Decl, len(decls), context.temp_allocator)
	copy(sorted, decls)
	slice.stable_sort_by(sorted, proc(a, b: Pre_Decl) -> bool { return int(a.prop) < int(b.prop) })
	for d in sorted {
		vals := d.value
		if d.has_var {
			env.budget = e.settings.max_var_bytes
			sub, ok := substitute(&env, vals, 0)
			if !ok { continue }
			vals = sub
		}
		if d.short != .None {
			longs, ok := expand_shorthand(d.short, vals, alloc)
			found := false
			if ok { for l in longs { if l.prop == d.prop { vals = l.vals; found = true; break } } }
			if !found { continue }
		}
		switch css_wide_keyword(vals) {
		case "inherit": copy_prop(c, parent != nil ? parent : initial, d.prop)
		case "initial": copy_prop(c, initial, d.prop)
		case "unset", "revert", "revert-layer": apply_unset(&cx, d.prop)
		case: if !apply_prop(&cx, d.prop, vals) { continue }
		}
		if d.prop == .Font_Size {
			cx.lc.font_size = f64(c.font_size)
			cx.lc.x_height = f64(c.font_size) * css.X_HEIGHT_EM
			cx.lc.ch = f64(c.font_size) * css.CH_EM
		}
	}
	for p in Prop { if ps_has(block.props, p) || ps_has(extra, p) { clone_prop(c, c, p, alloc) } }
	return c, extra
}

// Some var() in `vs` names one of `names`.
@(private)
mentions_var :: proc(vs: []css.Value, names: map[string]bool) -> bool {
	for v in vs {
		switch v.kind {
		case .Token:
		case .Function:
			if strings.equal_fold(v.tok.text, "var") {
				for a in v.children {
					if a.kind == .Token && a.tok.kind == .Ident { if a.tok.text in names { return true }; break }
				}
			}
			if mentions_var(v.children, names) { return true }
		case .Block:
			if mentions_var(v.children, names) { return true }
		}
	}
	return false
}

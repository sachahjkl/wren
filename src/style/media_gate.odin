package style

import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"

// Media queries that change value without rebuilding the rules.
//
// A page whose width crosses a breakpoint (Tailwind's sm: md: lg:, which are `@media (width >= 40rem)` blocks) used to rebuild
// the rule index and compute every style again: for two thousand elements, 80 ms in a drag of the developer tools' separator,
// at each of the breakpoints. The elements whose style a breakpoint changes are those that the rules inside the @media blocks
// match: a few dozen.
//
// So an @media block of style rules is no longer left out of the index while it is false. Its rules go in with a gate
// (Entry.gate, an index into Engine.gates): a matched entry whose gate does not hold is skipped (entry_live), and a change of
// the environment flips the flags (gates_refresh) instead of marking the rules stale. restyle_media then finds the elements
// that match an entry of a gate that flipped, whichever way it flipped (a probe over the document with the same matching code
// as the cascade: Pass.gate_probe), and restyles their subtrees in place, as restyle_containers does for a container.
//
// Only blocks whose content is style rules (nested ones, @supports and @container around them too) are gated: @layer, @keyframes,
// @font-face and @property inside a block decide something when the rules are read (the order of the layers, the animations,
// the fonts), so those blocks, a media attribute on <link> or <style>, @import ... media and the rule sets of shadow trees keep
// the rebuild.

Media_Gate :: struct {
	list:   css.Media_Query_List,   // owned by the stylesheet
	parent: u32,                    // the gate around it (0: none): a nested block holds only when its parent does
}

// Whether the rules inside `r` (an @media block) can stay in the index while the block is false.
@(private)
gateable :: proc(r: ^css.Rule) -> bool {
	switch r.kind {
	case .Style:
		for n in r.nested { if !gateable(n) { return false } }
		return true
	case .Media, .Supports, .Container:
		for n in r.rules { if !gateable(n) { return false } }
		return true
	case .Namespace, .Page, .Unknown: return true
	case .Layer_Block, .Layer_Statement, .Font_Face, .Keyframes, .Property, .Import: return false
	}
	return false
}

@(private)
gates_reset :: proc(e: ^Engine) {
	clear(&e.gates)
	clear(&e.gate_on)
	clear(&e.gate_touched)
	e.gates_pending = false
}

// A gate for a block met while the rules are flattened; its value is the one of the environment now.
@(private)
gate_add :: proc(e: ^Engine, list: css.Media_Query_List, parent: u32) -> u32 {
	if len(e.gates) == 0 {
		append(&e.gates, Media_Gate{})   // (0 stands for no gate)
		append(&e.gate_on, true)
		append(&e.gate_touched, false)
	}
	append(&e.gates, Media_Gate{list = list, parent = parent})
	append(&e.gate_on, css.media_matches(list, e.env) && (parent == 0 || e.gate_on[parent]))
	append(&e.gate_touched, false)
	return u32(len(e.gates) - 1)
}

// The environment changed: the gates that now answer otherwise are flagged (a parent comes before its children).
@(private)
gates_refresh :: proc(e: ^Engine) {
	for i in 1 ..< len(e.gates) {
		g := e.gates[i]
		on := css.media_matches(g.list, e.env) && (g.parent == 0 || e.gate_on[g.parent])
		if on == e.gate_on[i] { continue }
		e.gate_on[i] = on
		e.gate_touched[i] = true
		e.gates_pending = true
	}
}

// Whether a matched entry takes part in the cascade: its gate holds, or (in the probe of restyle_media) it is one of the
// entries that a flip can add or remove.
@(private)
entry_live :: proc(p: ^Pass, ent: ^Entry) -> bool {
	if p.gate_probe != nil { return ent.gate != 0 && int(ent.gate) < len(p.gate_probe) && p.gate_probe[ent.gate] }
	return ent.gate == 0 || p.e.gate_on[ent.gate]
}

// The styles of the elements the flipped blocks reach, in place. ok = false: it cannot be scoped (the root element, a counter,
// the memory partial restyles left, rules that changed meanwhile) and the caller makes a full pass; `changed`: some computed
// style differs (s.serial changed then).
restyle_media :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, pool: ^host.Thread_Pool = nil) -> (changed: bool, ok: bool) {
	if !e.gates_pending { return false, true }
	touched := e.gate_touched[:]
	defer { clear_gates_pending(e) }
	if e.dirty { return mq_fail(e, "rules changed") }
	if e.restyle_needed { return mq_fail(e, "a full pass is due") }
	if s.mutations != doc.mutations { return mq_fail(e, "the document changed") }
	if int(s.arena.total_used) - int(s.base_used) + s.partial_bytes > e.settings.restyle_waste_bytes { return mq_fail(e, "memory left by partial restyles") }
	p := pass_make(e, s, doc, s.state)
	defer pass_destroy(p)

	// the probe: every element with a rule of a flipped gate among those that match; restyle_roots computes them again and
	// goes below one only where what it inherits changed
	Frame :: struct { h: base.Handle, bloom: Bloom, ctx: Elem_Ctx }
	hits := make([dynamic]base.Handle, context.temp_allocator)
	stack := make([dynamic]Frame, context.temp_allocator)
	shadows := dom.has_shadow_trees(doc)
	p.gate_probe = touched
	root := dom.get(doc, doc.root)
	for c := root.last_child; c != base.NIL_HANDLE; c = dom.get(doc, c).prev { append(&stack, Frame{h = c}) }
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		collect_entries(p, f.h, n, &f.bloom, f.ctx)
		hit := false
		for i in 0 ..< 4 { if len(p.lists[i]) > 0 { hit = true; break } }
		if hit { append(&hits, f.h) }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		if !shadows {
			for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{h = ch, bloom = child_bloom}) }
			continue
		}
		for ch := dom.flat_last_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_prev(doc, ch) {
			append(&stack, Frame{h = ch, bloom = child_bloom, ctx = child_ctx(p, f.h, f.ctx, ch)})
		}
	}
	p.gate_probe = nil
	return restyle_roots(e, doc, s, p, hits[:], pool)
}

@(private)
clear_gates_pending :: proc(e: ^Engine) {
	e.gates_pending = false
	for &t in e.gate_touched { t = false }
}

@(private)
mq_fail :: proc(e: ^Engine, why: string) -> (bool, bool) {
	e.last_restyle.fallback = why
	return false, false
}

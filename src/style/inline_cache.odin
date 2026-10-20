package style

import "base:runtime"
import "core:strings"
import "wb:css"

// Compiled style attributes, kept by text for the life of a Styled. Parsing and compiling a style attribute took about
// 3 µs per element at every restyle of it; an animation that writes element.style from script (CSSOM, page package)
// paid it twice per write: once to validate the value, once more when the restyle parsed the attribute it had written.
//
//   * compute_element looks the attribute's text up in `Styled.inline_rules` before parsing it, and keeps what it
//     compiles (only the pass that allocates in the Styled's own arena inserts: the style threads only read, and the
//     map is never written while they run).
//   * CSSOM compiles each declaration it validates once into `Styled.inline_decls` (inline_declaration), and gives
//     the attribute text it writes, with its declarations in order, to inline_style_prime: the restyle that follows
//     finds the rule without parsing anything.
//
// Everything lives in the Styled's arena (computed styles may point into a rule's values), so nothing is freed before
// the Styled is; the maps are emptied when they reach style.inline_cache.entries, their memory then counts with the
// waste of partial restyles (style.restyle_waste_bytes). The engine facts compiling finds (viewport or container
// units) are already in the engine for anything cached: a rebuild of the engine resets them, and is always followed by
// a full pass, which starts a new Styled with empty maps.

// One declaration of a style attribute as CSSOM wrote it: `name: value` (`!important` when `important`).
Inline_Part :: struct {
	name, value: string,
	important:   bool,
}

@(private)
Inline_Decl :: struct {
	pre:     []Pre_Decl,
	customs: []Custom_Decl,
}

@(private)
inline_cache_destroy :: proc(s: ^Styled) {
	delete(s.inline_rules)
	delete(s.inline_decls)
	s.inline_rules, s.inline_decls = nil, nil
}

// The compiled rule of a style attribute (nil when its declarations are all invalid).
@(private)
inline_rule_of :: proc(p: ^Pass, text: string) -> ^Rule {
	s := p.s
	if r, ok := s.inline_rules[text]; ok { return r }
	owner := p.alloc.data == s.alloc.data   // the pass that owns the Styled's arena (not a style thread)
	if !owner || p.e.settings.inline_cache_entries <= 0 {
		decls := css.parse_declarations(text, p.opt, context.temp_allocator)
		pre, customs := compile_declarations(p.e, decls, p.alloc, &p.stats)
		own_custom_names(customs, p.alloc)   // (parsed in temp memory)
		if len(pre) == 0 && len(customs) == 0 { return nil }
		r := new(Rule, context.temp_allocator)
		r^ = Rule{decls = pre, customs = customs, origin = .Author, layer = UNLAYERED, order = max(u32)}
		return r
	}
	// parsed into the arena: the compiled values point into what was parsed
	decls := css.parse_declarations(text, p.opt, s.alloc)
	pre, customs := compile_declarations(p.e, decls, s.alloc, &p.stats)
	r: ^Rule
	if len(pre) > 0 || len(customs) > 0 {
		r = new(Rule, s.alloc)
		r^ = Rule{decls = pre, customs = customs, origin = .Author, layer = UNLAYERED, order = max(u32)}
	}
	inline_rule_put(p.e, s, text, r)
	return r
}

@(private)
inline_rule_put :: proc(e: ^Engine, s: ^Styled, text: string, r: ^Rule) {
	if len(s.inline_rules) >= e.settings.inline_cache_entries { clear(&s.inline_rules) }
	s.inline_rules[strings.clone(text, s.alloc)] = r
}

// The compiled form of one declaration `name: value` (`name` lowercase, or a custom property), as a style attribute
// holding it compiles; kept in `s`, which owns the memory (do not keep it past `s`). ok = false: the style engine
// refuses it (unknown property, invalid value, not one declaration). For CSSOM.
inline_declaration :: proc(e: ^Engine, s: ^Styled, name, value: string) -> (pre: []Pre_Decl, customs: []Custom_Decl, ok: bool) {
	d: Inline_Decl
	d, ok = inline_decl_of(e, s, name, value)
	return d.pre, d.customs, ok
}

// Keeps compiled declarations (from inline_declaration on the same `s`) under another text: CSSOM serializes the
// values it validated, and writes `name: serialized` into the attribute; inline_style_prime then finds them.
inline_declaration_register :: proc(e: ^Engine, s: ^Styled, name, value: string, pre: []Pre_Decl, customs: []Custom_Decl) {
	if s == nil || e == nil || e.settings.inline_cache_entries <= 0 { return }
	key := inline_decl_key(name, value)
	if _, has := s.inline_decls[key]; has { return }
	if len(s.inline_decls) >= e.settings.inline_cache_entries { clear(&s.inline_decls) }
	s.inline_decls[strings.clone(key, s.alloc)] = Inline_Decl{pre = slice_in(pre, s.alloc), customs = slice_in(customs, s.alloc)}
}

@(private)
slice_in :: proc(xs: []$T, a: runtime.Allocator) -> []T {
	out := make([]T, len(xs), a)
	copy(out, xs)
	return out
}

@(private)
inline_decl_key :: proc(name, value: string) -> string {
	return strings.concatenate({name, "\x00", value}, context.temp_allocator)
}

@(private)
inline_decl_of :: proc(e: ^Engine, s: ^Styled, name, value: string) -> (d: Inline_Decl, ok: bool) {
	if s == nil || e == nil { return }
	key := inline_decl_key(name, value)
	if d, ok = s.inline_decls[key]; ok { return d, len(d.pre) > 0 || len(d.customs) > 0 }
	opt := parse_options(&e.settings)
	decls := css.parse_declarations(strings.concatenate({name, ":", value}, context.temp_allocator), opt, s.alloc)
	if len(decls) == 1 && !decls[0].important && decls[0].name == name {
		d.pre, d.customs = compile_declarations(e, decls, s.alloc)
	}
	if e.settings.inline_cache_entries > 0 {
		if len(s.inline_decls) >= e.settings.inline_cache_entries { clear(&s.inline_decls) }
		s.inline_decls[strings.clone(key, s.alloc)] = d
	}
	return d, len(d.pre) > 0 || len(d.customs) > 0
}

// CSSOM wrote `text` as the element's style attribute, made of `parts` in order, each `name: value` exactly as in the
// text (a declaration per ';'). The next restyle of an element with that attribute uses this rule instead of parsing
// the text. Parts the engine refuses are left out, as parsing the text would.
inline_style_prime :: proc(e: ^Engine, s: ^Styled, text: string, parts: []Inline_Part) {
	if s == nil || e == nil || e.settings.inline_cache_entries <= 0 || !e.settings.author_stylesheets { return }
	if _, has := s.inline_rules[text]; has { return }
	n_pre, n_cus := 0, 0
	pieces := make([]Inline_Decl, len(parts), context.temp_allocator)
	for part, i in parts {
		d, _ := inline_decl_of(e, s, part.name, part.value)
		pieces[i] = d
		n_pre += len(d.pre)
		n_cus += len(d.customs)
	}
	r: ^Rule
	if n_pre > 0 || n_cus > 0 {
		pre := make([]Pre_Decl, n_pre, s.alloc)
		customs := make([]Custom_Decl, n_cus, s.alloc)
		ip, ic := 0, 0
		for d, i in pieces {
			for x in d.pre { pre[ip] = x; pre[ip].important = parts[i].important; ip += 1 }
			for x in d.customs { customs[ic] = x; customs[ic].important = parts[i].important; ic += 1 }
		}
		r = new(Rule, s.alloc)
		r^ = Rule{decls = pre, customs = customs, origin = .Author, layer = UNLAYERED, order = max(u32)}
	}
	inline_rule_put(e, s, text, r)
}

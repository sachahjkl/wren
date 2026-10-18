package style

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// The style engine: stylesheets in, an index of rules out. `compute_styles` (cascade.odin) then turns a document into
// computed styles.

Origin :: enum u8 { UA, User, Author }

UNLAYERED :: max(u32)

Pre_Decl :: struct {
	prop:      Prop,
	short:     Short,         // not .None: this longhand comes from a shorthand whose value still has var() in it
	value:     []css.Value,
	important: bool,
	has_var:   bool,
}

Custom_Decl :: struct {
	name:      string,
	value:     []css.Value,
	important: bool,
}

Rule :: struct {
	decls:   []Pre_Decl,
	customs: []Custom_Decl,
	origin:  Origin,
	layer:   u32,
	order:   u32,
}

// Dynamic state that a rule can depend on. Which of them appear in the active rules decides what a change of state costs.
State_Kind :: enum u8 { Hover, Active, Focus, Target }
State_Kinds :: bit_set[State_Kind; u8]

Entry :: struct {
	rule:    ^Rule,
	complex: ^css.Complex,
	anc:     [4]u32,   // hashes (see bloom.odin) of simple selectors an ancestor must have: rejects most entries without matching
	n_anc:   u8,
	state:   State_Kinds,   // state the complex depends on, anywhere in it
}

Index :: struct {
	by_id, by_class, by_tag: map[string][dynamic]Entry,
	by_attr:                 map[string][dynamic]Entry,   // [name=value]: key is name, NUL, value
	attr_names:              map[string]bool,             // names used by by_attr, so elements skip the other attributes
	universal:               [dynamic]Entry,
}

Import_Slot :: struct {
	rule:      ^css.Rule,
	child:     ^Sheet,
	requested: bool,
	failed:    bool,
}

Sheet :: struct {
	sheet:   ^css.Stylesheet,
	origin:  Origin,
	owner:   base.Handle,              // the <style> or <link> element; NIL for browser and user sheets
	media:   css.Media_Query_List,     // the `media` attribute of the owner
	layer:   string,                   // @import ... layer(x): the layer this whole sheet joins ("" = none)
	in_layer: bool,
	imports: [dynamic]Import_Slot,
	depth:   int,
	order:   int,                      // position in the document, set by `engine_rebuild`
	base_url: string,                  // owned: where relative URLs in the sheet resolve from
	id:      u64,                      // never reused: lets asynchronous loads find out whether their sheet still exists
	from_link: bool,                   // came from <link rel=stylesheet>, not <style>
	media_text: string,                // owned: the owner's media attribute as written
}

Engine :: struct {
	settings:  Settings,               // owned copy
	sheets:    [dynamic]^Sheet,        // browser, user, then document sheets
	arena:     virtual.Arena,          // compiled rules and index entries
	alloc:     runtime.Allocator,
	index:     Index,
	layers:    [dynamic]string,        // layer names in cascade order (later = stronger)
	env:       css.Media_Env,
	order:     u32,
	rule_count: int,
	media_dependent: bool,             // some active condition depends on the viewport
	dirty:     bool,
	font_faces: [dynamic]Font_Face_Ref,   // @font-face rules in force, with the URL their sources resolve against
	faces:     [dynamic]Font_Face,        // ... parsed (fontface.odin); strings in `alloc`
	keyframes: [dynamic]Keyframes_Ref,    // @keyframes rules in force
	keyframe_sets: map[string]^Keyframes_Set,   // the winning rule of each name, compiled (keyframes.odin)
	rebuilds:  u64,                       // counts rebuilds: compiled keyframes and faces are stale after one
	cur_base_url: string,                 // while flattening: the URL of the sheet being read
	kf_order:  u32,
	spare:     virtual.Arena,             // the memory of a recycled style pass (see styled_recycle)
	has_spare: bool,
	ignored_properties: int,           // declarations naming a property this engine does not implement
	ua:        ^Sheet,
	user:      ^Sheet,
	anon_layers: int,
	next_sheet_id: u64,
	// what the active rules depend on (recomputed by every rebuild)
	state_deps:      State_Kinds,
	state_entries:   [dynamic]Entry,   // entries that depend on some state
	state_uses_has:  bool,             // a state-dependent :has() exists: its effect cannot be scoped
	viewport_units:  bool,             // some value uses vw/vh/vmin/vmax: a viewport change restyles
	restyle_needed:  bool,             // set by `engine_set_environment`; the page clears it after restyling
}

////////////////////////////////
// Lifecycle

engine_make :: proc(settings: Settings) -> ^Engine {
	tables_init()
	e := new(Engine)
	e.settings = clone_settings(settings)
	_ = virtual.arena_init_growing(&e.arena)
	e.alloc = virtual.arena_allocator(&e.arena)
	e.env = css.Media_Env{type = .Screen, width = 1280, height = 800, dppx = 1, hover = true, pointer_fine = true, color_bits = 24}
	engine_reset_builtin_sheets(e)
	return e
}

@(private)
clone_settings :: proc(s: Settings) -> Settings {
	c := s
	c.user_stylesheet = strings.clone(s.user_stylesheet)
	c.default_generic = strings.clone(s.default_generic)
	c.family_serif = strings.clone(s.family_serif)
	c.family_sans_serif = strings.clone(s.family_sans_serif)
	c.family_monospace = strings.clone(s.family_monospace)
	c.family_cursive = strings.clone(s.family_cursive)
	c.family_fantasy = strings.clone(s.family_fantasy)
	c.family_system_ui = strings.clone(s.family_system_ui)
	return c
}

engine_destroy :: proc(e: ^Engine) {
	for s in e.sheets { sheet_free(s) }
	delete(e.sheets)
	index_free(&e.index)
	virtual.arena_destroy(&e.arena)
	delete(e.layers)
	delete(e.font_faces)
	delete(e.faces)
	delete(e.keyframes)
	delete(e.keyframe_sets)
	delete(e.state_entries)
	if e.has_spare { virtual.arena_destroy(&e.spare) }
	settings_destroy(&e.settings)
	free(e)
}

@(private)
sheet_free :: proc(s: ^Sheet) {
	for &slot in s.imports { if slot.child != nil { sheet_free(slot.child) } }
	delete(s.imports)
	if s.sheet != nil { css.stylesheet_destroy(s.sheet); free(s.sheet) }
	delete(s.base_url)
	delete(s.layer)
	delete(s.media_text)
	free(s)
}

@(private)
index_free :: proc(ix: ^Index) {
	for _, v in ix.by_id { delete(v) }
	for _, v in ix.by_class { delete(v) }
	for _, v in ix.by_tag { delete(v) }
	for k, v in ix.by_attr { delete(k); delete(v) }
	delete(ix.by_id); delete(ix.by_class); delete(ix.by_tag); delete(ix.by_attr); delete(ix.attr_names); delete(ix.universal)
	ix^ = {}
}

// Applies a changed configuration: every sheet is compiled again with the new limits and built-in styles.
engine_configure :: proc(e: ^Engine, settings: Settings) {
	settings_destroy(&e.settings)
	e.settings = clone_settings(settings)
	engine_reset_builtin_sheets(e)
	e.dirty = true
}

@(private)
engine_reset_builtin_sheets :: proc(e: ^Engine) {
	for i := len(e.sheets) - 1; i >= 0; i -= 1 {
		if e.sheets[i].origin != .Author {
			sheet_free(e.sheets[i])
			ordered_remove(&e.sheets, i)
		}
	}
	e.ua, e.user = nil, nil
	if e.settings.ua_stylesheet {
		text := ua_stylesheet_text(&e.settings, context.temp_allocator)
		e.ua = add_sheet(e, text, .UA, base.NIL_HANDLE, "", false, "")
	}
	if e.settings.user_stylesheet != "" {
		if data, err := os.read_entire_file(e.settings.user_stylesheet, context.temp_allocator); err == nil {
			e.user = add_sheet(e, string(data), .User, base.NIL_HANDLE, "", false, "")
		}
	}
	// browser and user sheets sort before document sheets
	slice.stable_sort_by(e.sheets[:], proc(a, b: ^Sheet) -> bool { return int(a.origin) < int(b.origin) })
}

////////////////////////////////
// Adding sheets

// Parses and registers a stylesheet. `media` is the owner's media attribute. Returns nil when the sheet is too large.
engine_add_sheet :: proc(e: ^Engine, text: string, owner: base.Handle, media: string = "", base_url: string = "", from_link := false) -> ^Sheet {
	if !e.settings.author_stylesheets { return nil }
	s := add_sheet(e, text, .Author, owner, media, false, "", base_url)
	if s != nil { s.from_link = from_link }
	return s
}

@(private)
add_sheet :: proc(e: ^Engine, text: string, origin: Origin, owner: base.Handle, media: string, in_layer: bool, layer: string, base_url := "", depth := 0) -> ^Sheet {
	if len(text) > e.settings.max_sheet_bytes { return nil }
	s := new(Sheet)
	opt := parse_options(&e.settings)
	s.sheet = css.parse_stylesheet(text, opt)
	e.next_sheet_id += 1
	s.id = e.next_sheet_id
	s.origin, s.owner, s.depth = origin, owner, depth
	s.media_text = strings.clone(media)
	s.in_layer, s.layer = in_layer, strings.clone(layer)
	s.base_url = strings.clone(base_url)
	if media != "" {
		toks := css.parse_component_values(media, opt, context.temp_allocator)
		s.media = css.parse_media_query_list(toks, e.alloc)
	}
	s.imports = make([dynamic]Import_Slot)
	for r in s.sheet.rules { if r.kind == .Import { append(&s.imports, Import_Slot{rule = r}) } }
	append(&e.sheets, s)
	e.dirty = true
	return s
}

engine_remove_sheet :: proc(e: ^Engine, s: ^Sheet) {
	for x, i in e.sheets { if x == s { ordered_remove(&e.sheets, i); sheet_free(s); e.dirty = true; return } }
}

// Removes every sheet that came from the document (used when the page changes or its <style> elements do).
engine_clear_document_sheets :: proc(e: ^Engine) {
	for i := len(e.sheets) - 1; i >= 0; i -= 1 {
		if e.sheets[i].origin == .Author { sheet_free(e.sheets[i]); ordered_remove(&e.sheets, i) }
	}
	e.dirty = true
}

// The sheet with this id, wherever it is (a document sheet or something it imported); nil when it was removed.
engine_find_sheet :: proc(e: ^Engine, id: u64) -> ^Sheet {
	find :: proc(s: ^Sheet, id: u64) -> ^Sheet {
		if s.id == id { return s }
		for &slot in s.imports { if slot.child != nil { if r := find(slot.child, id); r != nil { return r } } }
		return nil
	}
	for s in e.sheets { if r := find(s, id); r != nil { return r } }
	return nil
}

// The sheet that came from this <link> or <style> element.
engine_sheet_of_owner :: proc(e: ^Engine, owner: base.Handle) -> ^Sheet {
	for s in e.sheets { if s.owner == owner && s.origin == .Author { return s } }
	return nil
}

// An @import the caller has to fetch. `url` is as written; resolve it against `base_url`.
Pending_Import :: struct {
	sheet_id: u64,
	slot:     int,
	url:      string,
	base_url: string,
}

// Every @import not yet requested, in all sheets (imported ones too). Returning an import marks it requested: the caller
// fetches it and answers with `engine_resolve_import_by_id` (or never, if the fetch fails).
engine_take_pending_imports :: proc(e: ^Engine, allocator := context.temp_allocator) -> []Pending_Import {
	out := make([dynamic]Pending_Import, allocator)
	walk :: proc(e: ^Engine, s: ^Sheet, out: ^[dynamic]Pending_Import) {
		for &slot, i in s.imports {
			if slot.child != nil { walk(e, slot.child, out); continue }
			if slot.requested || s.depth >= e.settings.max_import_depth { continue }
			slot.requested = true
			append(out, Pending_Import{s.id, i, slot.rule.url, s.base_url})
		}
	}
	for s in e.sheets { if s.origin == .Author { walk(e, s, &out) } }
	return out[:]
}

// Registers the text fetched for an import. False when the importing sheet was removed meanwhile.
engine_resolve_import_by_id :: proc(e: ^Engine, sheet_id: u64, slot: int, text: string, url: string) -> bool {
	parent := engine_find_sheet(e, sheet_id)
	if parent == nil || slot < 0 || slot >= len(parent.imports) { return false }
	return engine_resolve_import(e, parent, &parent.imports[slot], text, url)
}

// @import rules of `s` not yet answered. The caller fetches `url`, then calls `engine_resolve_import`.
pending_imports :: proc(e: ^Engine, s: ^Sheet, allocator := context.temp_allocator) -> []^Import_Slot {
	out := make([dynamic]^Import_Slot, allocator)
	if s.depth >= e.settings.max_import_depth { return out[:] }
	for &slot in s.imports { if !slot.requested && slot.child == nil { append(&out, &slot) } }
	return out[:]
}

engine_resolve_import :: proc(e: ^Engine, parent: ^Sheet, slot: ^Import_Slot, text: string, base_url: string) -> bool {
	slot.requested = true
	if parent.depth + 1 > e.settings.max_import_depth { slot.failed = true; return false }
	// imported sheets are owned by the slot, not by the engine's list
	if len(text) > e.settings.max_sheet_bytes { slot.failed = true; return false }
	opt := parse_options(&e.settings)
	s := new(Sheet)
	s.sheet = css.parse_stylesheet(text, opt)
	e.next_sheet_id += 1
	s.id = e.next_sheet_id
	s.origin, s.depth = parent.origin, parent.depth + 1
	s.base_url = strings.clone(base_url)
	s.imports = make([dynamic]Import_Slot)
	for r in s.sheet.rules { if r.kind == .Import { append(&s.imports, Import_Slot{rule = r}) } }
	slot.child = s
	e.dirty = true
	return true
}

////////////////////////////////
// Compiling rules

LayerCtx :: struct { path: string, rank: u32 }

@(private)
layer_rank :: proc(e: ^Engine, path: string) -> u32 {
	if path == "" { return UNLAYERED }
	for n, i in e.layers { if n == path { return u32(i) } }
	append(&e.layers, strings.clone(path, e.alloc))
	return u32(len(e.layers) - 1)
}

@(private)
contains_var :: proc(vs: []css.Value) -> bool {
	for v in vs {
		switch v.kind {
		case .Token:
		case .Function:
			if strings.equal_fold(v.tok.text, "var") || contains_var(v.children) { return true }
		case .Block:
			if contains_var(v.children) { return true }
		}
	}
	return false
}

@(private)
uses_viewport_units :: proc(vs: []css.Value) -> bool {
	for v in vs {
		switch v.kind {
		case .Token:
			if v.tok.kind == .Dimension {
				if u, ok := css.relative_unit(v.tok.text); ok && (u == .Vw || u == .Vh || u == .Vmin || u == .Vmax) { return true }
			}
		case .Function, .Block:
			if uses_viewport_units(v.children) { return true }
		}
	}
	return false
}

@(private)
css_wide_keyword :: proc(vs: []css.Value) -> string {
	id := css.ident_of(vs)
	switch id {
	case "initial", "inherit", "unset", "revert", "revert-layer": return id
	}
	return ""
}

// Turns parsed declarations into longhand declarations. A declaration whose value is not valid for its property is dropped
// here, as the CSS parsing rules say, so that an earlier valid declaration (a fallback) stays in force.
compile_declarations :: proc(e: ^Engine, decls: []css.Declaration, a: runtime.Allocator) -> (out: []Pre_Decl, customs: []Custom_Decl) {
	res := make([dynamic]Pre_Decl, a)
	cus := make([dynamic]Custom_Decl, a)
	probe := probe_context(e, a)
	valid :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
		if css_wide_keyword(vs) != "" { return true }
		return apply_prop(cx, p, vs)
	}
	for d in decls {
		if !e.viewport_units && uses_viewport_units(d.value) { e.viewport_units = true }
		if strings.has_prefix(d.name, "--") {
			append(&cus, Custom_Decl{name = d.name, value = d.value, important = d.important})
			continue
		}
		p, sh, known := lookup_property(d.name)
		if !known { e.ignored_properties += 1; continue }
		hv := contains_var(d.value)
		if sh == .None {
			if !hv && !valid(&probe, p, d.value) { continue }
			append(&res, Pre_Decl{prop = p, value = d.value, important = d.important, has_var = hv})
			continue
		}
		if kw := css_wide_keyword(d.value); kw != "" {
			for lp in short_longhands(sh) { append(&res, Pre_Decl{prop = lp, value = d.value, important = d.important}) }
			continue
		}
		if hv {
			for lp in short_longhands(sh) { append(&res, Pre_Decl{prop = lp, short = sh, value = d.value, important = d.important, has_var = true}) }
			continue
		}
		longs, ok := expand_shorthand(sh, d.value, a)
		if !ok { continue }
		all_valid := true
		for l in longs { if !valid(&probe, l.prop, l.vals) { all_valid = false; break } }
		if !all_valid { continue }
		for l in longs { append(&res, Pre_Decl{prop = l.prop, value = l.vals, important = d.important}) }
	}
	return res[:], cus[:]
}

@(private)
bucket_add :: proc(e: ^Engine, ent_in: Entry) {
	ent := ent_in
	compute_ancestor_hashes(&ent)
	kinds, uses_has := complex_state(ent.complex)
	ent.state = kinds
	if ent.state != {} {
		e.state_deps += ent.state
		append(&e.state_entries, ent)
		if uses_has { e.state_uses_has = true }
	}
	c := ent.complex
	last := c.compounds[len(c.compounds) - 1]
	var_id, var_class, var_tag: string
	var_attr: ^css.Simple
	for &s in last.simples {
		#partial switch s.kind {
		case .Id: if var_id == "" { var_id = s.name }
		case .Class: if var_class == "" { var_class = s.name }
		case .Type: if var_tag == "" { var_tag = s.name }
		case .Attribute: if var_attr == nil && s.op == .Equals && !s.ci { var_attr = &s }
		}
	}
	add :: proc(m: ^map[string][dynamic]Entry, key: string, ent: Entry, own_key := false) {
		list, ok := m[key]
		if !ok && own_key { m[strings.clone(key)] = {} }   // the key is a temporary: the map keeps its own copy
		if !ok { list = make([dynamic]Entry) }
		append(&list, ent)
		m[key] = list
	}
	switch {
	case var_id != "": add(&e.index.by_id, var_id, ent)
	case var_class != "": add(&e.index.by_class, var_class, ent)
	case var_attr != nil:
		add(&e.index.by_attr, strings.concatenate({var_attr.name, "\x00", var_attr.value}, context.temp_allocator), ent, own_key = true)
		e.index.attr_names[var_attr.name] = true
	case var_tag != "": add(&e.index.by_tag, var_tag, ent)
	case: append(&e.index.universal, ent)
	}
}

@(private)
compile_style_rule :: proc(e: ^Engine, r: ^css.Rule, origin: Origin, lc: LayerCtx) {
	if e.rule_count >= e.settings.max_rules_total { return }
	decls, customs := compile_declarations(e, r.declarations, e.alloc)
	if len(decls) > 0 || len(customs) > 0 {
		e.rule_count += 1
		e.order += 1
		rule := new(Rule, e.alloc)
		rule.decls, rule.customs, rule.origin, rule.layer, rule.order = decls, customs, origin, lc.rank, e.order
		for i in 0 ..< len(r.selectors) {
			c := &r.selectors[i]
			if len(c.compounds) > e.settings.max_selector_compounds { continue }
			bucket_add(e, Entry{rule = rule, complex = c})
		}
	}
	for n in r.nested { flatten_rule(e, n, origin, lc) }
}

@(private)
flatten_rule :: proc(e: ^Engine, r: ^css.Rule, origin: Origin, lc: LayerCtx) {
	switch r.kind {
	case .Style: compile_style_rule(e, r, origin, lc)
	case .Media:
		if media_depends_on_viewport(r.media) { e.media_dependent = true }
		if css.media_matches(r.media, e.env) { for n in r.rules { flatten_rule(e, n, origin, lc) } }
	case .Supports:
		if supports_condition(e, r.supports) { for n in r.rules { flatten_rule(e, n, origin, lc) } }
	case .Layer_Block:
		path := r.layer
		if path == "" { e.anon_layers += 1; path = fmt.tprintf("\x00anon%d", e.anon_layers) }
		if lc.path != "" { path = strings.concatenate({lc.path, ".", path}, context.temp_allocator) }
		sub := LayerCtx{path = path, rank = layer_rank(e, path)}
		for n in r.rules { flatten_rule(e, n, origin, sub) }
	case .Layer_Statement:
		for name in r.layer_names {
			path := lc.path != "" ? strings.concatenate({lc.path, ".", name}, context.temp_allocator) : name
			layer_rank(e, path)
		}
	case .Font_Face: append(&e.font_faces, Font_Face_Ref{rule = r, base_url = e.cur_base_url, origin = origin})
	case .Keyframes:
		e.kf_order += 1
		append(&e.keyframes, Keyframes_Ref{rule = r, layer = lc.rank, order = e.kf_order, origin = origin})
	case .Import, .Namespace, .Page, .Container, .Unknown:
	}
}

@(private)
media_depends_on_viewport :: proc(list: css.Media_Query_List) -> bool {
	return len(list) > 0   // any condition may depend on the viewport or the color scheme; cheap to rebuild, so be conservative
}

@(private)
flatten_sheet :: proc(e: ^Engine, s: ^Sheet, lc_in: LayerCtx) {
	if len(s.media) > 0 {
		e.media_dependent = true
		if !css.media_matches(s.media, e.env) { return }
	}
	saved_base := e.cur_base_url
	defer e.cur_base_url = saved_base
	e.cur_base_url = s.base_url
	lc := lc_in
	if s.in_layer {
		path := s.layer
		if path == "" { e.anon_layers += 1; path = fmt.tprintf("\x00anon%d", e.anon_layers) }
		if lc.path != "" { path = strings.concatenate({lc.path, ".", path}, context.temp_allocator) }
		lc = LayerCtx{path = path, rank = layer_rank(e, path)}
	}
	import_idx := 0
	for r in s.sheet.rules {
		if r.kind == .Import {
			slot := &s.imports[import_idx]
			import_idx += 1
			if slot.child == nil { continue }
			if len(r.supports) > 0 && !supports_condition(e, r.supports) { continue }
			if len(r.media) > 0 {
				e.media_dependent = true
				if !css.media_matches(r.media, e.env) { continue }
			}
			child_lc := lc
			if r.layer != "" || strings.has_prefix(r.layer, "\x00") {
				path := r.layer
				if path == "\x00anonymous" { e.anon_layers += 1; path = fmt.tprintf("\x00anon%d", e.anon_layers) }
				if lc.path != "" { path = strings.concatenate({lc.path, ".", path}, context.temp_allocator) }
				child_lc = LayerCtx{path = path, rank = layer_rank(e, path)}
			}
			flatten_sheet(e, slot.child, child_lc)
			continue
		}
		flatten_rule(e, r, s.origin, lc)
	}
}

// Rebuilds the rule index from every sheet. `doc` gives the order of sheets that come from the document.
engine_rebuild :: proc(e: ^Engine, doc: ^dom.Document = nil) {
	free_all(e.alloc)
	index_free(&e.index)
	clear(&e.state_entries)
	e.state_deps, e.state_uses_has, e.viewport_units = {}, false, false
	clear(&e.layers)
	clear(&e.font_faces)
	clear(&e.faces)
	clear(&e.keyframes)
	clear(&e.keyframe_sets)
	e.order, e.rule_count, e.media_dependent, e.anon_layers, e.kf_order = 0, 0, false, 0, 0

	if doc != nil {
		ordinal := make(map[base.Handle]int, context.temp_allocator)
		n := 0
		stack := make([dynamic]base.Handle, context.temp_allocator)
		append(&stack, doc.root)
		for len(stack) > 0 {
			h := pop(&stack)
			ordinal[h] = n; n += 1
			nd := dom.get(doc, h)
			c := nd.last_child
			for c != base.NIL_HANDLE { append(&stack, c); c = dom.get(doc, c).prev }
		}
		for s in e.sheets { if s.origin == .Author { s.order = ordinal[s.owner] or_else 0 } }
	}
	slice.stable_sort_by(e.sheets[:], proc(a, b: ^Sheet) -> bool {
		if a.origin != b.origin { return int(a.origin) < int(b.origin) }
		return a.order < b.order
	})
	for s in e.sheets { flatten_sheet(e, s, LayerCtx{rank = UNLAYERED}) }
	compile_keyframes(e)
	parse_font_faces(e)
	e.rebuilds += 1
	e.dirty = false
}

// Updates the rendering environment. Returns true when the index has to be rebuilt because the change can alter which
// conditional rules apply.
engine_set_environment :: proc(e: ^Engine, env: css.Media_Env) -> bool {
	changed := env != e.env
	old := e.env
	e.env = env
	if changed && e.media_dependent { e.dirty = true }
	// styles depend on the viewport only through conditional rules and viewport units, and on the color scheme through
	// light-dark() and media queries; anything else (a plain width change) needs layout only
	size_changed := old.width != env.width || old.height != env.height
	if changed && ((size_changed && (e.media_dependent || e.viewport_units)) || old.prefers_dark != env.prefers_dark ||
	   old.dppx != env.dppx || old.prefers_reduced_motion != env.prefers_reduced_motion || old.prefers_more_contrast != env.prefers_more_contrast) {
		e.restyle_needed = true
	}
	return changed
}

media_env_from :: proc(s: ^Settings, width, height, dppx: f64, os_dark: bool) -> css.Media_Env {
	dark: bool
	switch s.color_scheme {
	case .Auto: dark = os_dark
	case .Light: dark = false
	case .Dark: dark = true
	}
	return css.Media_Env{
		type = .Screen, width = width, height = height, dppx = dppx,
		prefers_dark = dark, prefers_reduced_motion = s.reduced_motion, prefers_more_contrast = s.prefers_contrast,
		hover = true, pointer_fine = true, color_bits = 24,
	}
}

////////////////////////////////
// @supports

@(private)
supports_condition :: proc(e: ^Engine, vs_in: []css.Value) -> bool {
	vs := css.trim_values(vs_in)
	if len(vs) == 0 { return false }
	// not <cond>
	if css.is_ws_value(vs[0]) { return false }
	if vs[0].kind == .Token && vs[0].tok.kind == .Ident && strings.equal_fold(vs[0].tok.text, "not") {
		return !supports_condition(e, vs[1:])
	}
	result := false
	first := true
	op := ""
	i := 0
	for i < len(vs) {
		for i < len(vs) && css.is_ws_value(vs[i]) { i += 1 }
		if i >= len(vs) { break }
		v := vs[i]
		i += 1
		if v.kind == .Token && v.tok.kind == .Ident {
			w := strings.to_lower(v.tok.text, context.temp_allocator)
			if w == "and" || w == "or" { op = w; continue }
			return false
		}
		val := false
		switch {
		case v.kind == .Function && strings.equal_fold(v.tok.text, "selector"):
			_, ok := css.parse_selector_list(css.trim_values(v.children), context.temp_allocator, nil)
			val = ok
		case v.kind == .Block && v.tok.kind == .Open_Paren:
			val = supports_block(e, v.children)
		case: return false
		}
		if first { result = val; first = false } else if op == "and" { result = result && val } else { result = result || val }
	}
	return result
}

@(private)
supports_block :: proc(e: ^Engine, children: []css.Value) -> bool {
	inner := css.trim_values(children)
	if len(inner) == 0 { return false }
	// a nested condition
	if inner[0].kind == .Block || inner[0].kind == .Function || (inner[0].kind == .Token && inner[0].tok.kind == .Ident && strings.equal_fold(inner[0].tok.text, "not")) {
		return supports_condition(e, inner)
	}
	// (property: value)
	if inner[0].kind != .Token || inner[0].tok.kind != .Ident { return false }
	i := 1
	for i < len(inner) && css.is_ws_value(inner[i]) { i += 1 }
	if i >= len(inner) || inner[i].kind != .Token || inner[i].tok.kind != .Colon { return false }
	value := css.trim_values(inner[i + 1:])
	name := inner[0].tok.text
	if strings.has_prefix(name, "--") { return true }
	p, sh, known := lookup_property(strings.to_lower(name, context.temp_allocator))
	if !known || len(value) == 0 { return false }
	if contains_var(value) { return true }
	if css_wide_keyword(value) != "" { return true }
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	cx := probe_context(e, a)
	if sh != .None {
		longs, ok := expand_shorthand(sh, value, a)
		if !ok { return false }
		for l in longs {
			if css_wide_keyword(l.vals) == "" && !apply_prop(&cx, l.prop, l.vals) { return false }
		}
		return true
	}
	return apply_prop(&cx, p, value)
}

@(private)
probe_context :: proc(e: ^Engine, a: runtime.Allocator) -> Cx {
	c := new(Computed, a)
	c^ = initial_computed(&e.settings)
	return Cx{settings = &e.settings, c = c, alloc = a, lc = css.Length_Context{font_size = 16, root_font_size = 16, vw = 1280, vh = 800}}
}

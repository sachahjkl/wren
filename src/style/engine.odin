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
	cq:      ^Cq_Cond,   // @container conditions around the rule (container.odin); nil: none
	hint:    bool,       // HTML presentational hints (hints.odin): author origin, below every layer and sheet
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
	ctx:     u16,           // matched entries (cascade.odin): the encapsulation depth of the tree the rule came from
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
	scope:   base.Handle,              // the shadow root whose tree the owner is in; NIL: the document (scope.odin)
	constructed: bool,                 // a constructable stylesheet (new CSSStyleSheet()): applies where it is adopted
	version: u64,                      // constructed: bumped by every change of its text
	disabled: bool,                    // constructed: CSSStyleSheet.disabled
}

Engine :: struct {
	settings:  Settings,               // owned copy
	sheets:    [dynamic]^Sheet,        // browser, user, then document sheets
	arena:     virtual.Arena,          // compiled rules and index entries
	alloc:     runtime.Allocator,
	// the document's rules (UA, user, author sheets of the document and its adopted sheets): index, layers, what they
	// depend on; shadow trees have rule sets of their own (scope.odin)
	using rules: Rule_Set,
	cur:       ^Rule_Set,              // while compiling: the set rules go to
	shadow:    Shadow_Styles,          // the rule sets of shadow trees, adopted sheets (scope.odin)
	env:       css.Media_Env,
	media_dependent: bool,             // some active condition depends on the viewport
	media_seen: [dynamic]Media_Seen,   // the document's media lists the last rebuild evaluated, and their results
	dirty:     bool,
	font_faces: [dynamic]Font_Face_Ref,   // @font-face rules in force, with the URL their sources resolve against
	faces:     [dynamic]Font_Face,        // ... parsed (fontface.odin); strings in `alloc`
	keyframes: [dynamic]Keyframes_Ref,    // @keyframes rules in force
	keyframe_sets: map[string]^Keyframes_Set,   // the winning rule of each name, compiled (keyframes.odin)
	registered: map[string]^Registered_Prop,    // @property registrations in force (property.odin); values in `alloc`
	registered_noninherited: int,               // how many of them do not inherit
	container_sizes: map[base.Handle][2]f32,    // content boxes of query containers from the last layout (container.odin)
	container_dependent: bool,                  // some @container rule or cq unit is in force
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
	viewport_units:  bool,             // some value uses vw/vh/vmin/vmax: a viewport change restyles
	restyle_needed:  bool,             // set by `engine_set_environment`; the page clears it after restyling
	journal_max:     int,              // > 0: passes keep a layout journal of at most this many entries (journal.odin)
	last_restyle:    Restyle_Stats,    // diagnostics of the last restyle_dom
	probe_base:      ^Computed,        // initial values for validating declarations (compile_declarations), made once per configuration
}

////////////////////////////////
// Lifecycle

engine_make :: proc(settings: Settings) -> ^Engine {
	// process-wide tables, built once whichever thread gets here first, kept for good: not the caller's memory
	{
		context.allocator = runtime.heap_allocator()
		tables_init()   // once per process (sync.Once inside)
	}
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
	free(e.probe_base, runtime.heap_allocator())
	for s in e.sheets { sheet_free(s) }
	delete(e.sheets)
	rule_set_clear(&e.rules)
	shadow_styles_destroy(e)
	virtual.arena_destroy(&e.arena)
	delete(e.font_faces)
	delete(e.faces)
	delete(e.keyframes)
	delete(e.keyframe_sets)
	delete(e.registered)
	delete(e.container_sizes)
	delete(e.media_seen)
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
	free(e.probe_base, runtime.heap_allocator())
	e.probe_base = nil
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
	shadow_sets_forget(e)   // every compiled set holds the built-in rules
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
// `scope`: the shadow root the owner is in (NIL: the document).
engine_add_sheet :: proc(e: ^Engine, text: string, owner: base.Handle, media: string = "", base_url: string = "", from_link := false, scope := base.NIL_HANDLE) -> ^Sheet {
	if !e.settings.author_stylesheets { return nil }
	if len(text) > e.settings.max_sheet_bytes { return nil }
	s := register_sheet(e, css.parse_stylesheet(text, parse_options(&e.settings)), .Author, owner, media, false, "", base_url, scope = scope)
	s.from_link = from_link
	return s
}

// Registers a stylesheet parsed elsewhere: `css.parse_stylesheet` with `parse_options(&e.settings)`, typically on another
// thread (parsing is a pure function with its own arena). The result is the same as `engine_add_sheet` on the same text.
// The engine takes ownership of `sheet`; nil, and `sheet` freed, when author sheets are disabled or it is too large.
engine_add_parsed_sheet :: proc(e: ^Engine, sheet: ^css.Stylesheet, owner: base.Handle, media: string = "", base_url: string = "", from_link := false, scope := base.NIL_HANDLE) -> ^Sheet {
	if !e.settings.author_stylesheets || len(sheet.source) > e.settings.max_sheet_bytes {
		css.stylesheet_destroy(sheet); free(sheet)
		return nil
	}
	s := register_sheet(e, sheet, .Author, owner, media, false, "", base_url, scope = scope)
	s.from_link = from_link
	return s
}

// `engine_resolve_import_by_id` for a sheet parsed elsewhere (see engine_add_parsed_sheet). Takes ownership of `sheet`.
engine_resolve_import_parsed :: proc(e: ^Engine, sheet_id: u64, slot: int, sheet: ^css.Stylesheet, url: string) -> bool {
	parent := engine_find_sheet(e, sheet_id)
	if parent == nil || slot < 0 || slot >= len(parent.imports) { css.stylesheet_destroy(sheet); free(sheet); return false }
	return resolve_import(e, parent, &parent.imports[slot], sheet, url)
}

@(private)
add_sheet :: proc(e: ^Engine, text: string, origin: Origin, owner: base.Handle, media: string, in_layer: bool, layer: string, base_url := "", depth := 0) -> ^Sheet {
	if len(text) > e.settings.max_sheet_bytes { return nil }
	return register_sheet(e, css.parse_stylesheet(text, parse_options(&e.settings)), origin, owner, media, in_layer, layer, base_url, depth)
}

@(private)
register_sheet :: proc(e: ^Engine, sheet: ^css.Stylesheet, origin: Origin, owner: base.Handle, media: string, in_layer: bool, layer: string, base_url := "", depth := 0, scope := base.NIL_HANDLE, constructed := false) -> ^Sheet {
	s := new(Sheet)
	opt := parse_options(&e.settings)
	s.sheet = sheet
	e.next_sheet_id += 1
	s.id = e.next_sheet_id
	s.origin, s.owner, s.depth = origin, owner, depth
	s.scope, s.constructed = scope, constructed
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
	sheet_changed(e, s)
	return s
}

engine_remove_sheet :: proc(e: ^Engine, s: ^Sheet) {
	for x, i in e.sheets {
		if x == s {
			sheet_changed(e, s)
			ordered_remove(&e.sheets, i)
			sheet_free(s)
			return
		}
	}
}

// What a change of sheet `s` (or of one it imports) makes stale: the document's rules, or the rule sets of shadow
// trees (scope.odin), or, for a constructed sheet, those of wherever it is adopted.
@(private)
sheet_changed :: proc(e: ^Engine, s: ^Sheet) {
	if s.constructed {
		if adopted_by_document(e, s.id) { e.dirty = true }
		e.shadow.dirty = true
		return
	}
	if s.scope != base.NIL_HANDLE { e.shadow.dirty = true } else { e.dirty = true }
}

// Removes every sheet that came from the document (used when the page changes or its <style> elements do).
engine_clear_document_sheets :: proc(e: ^Engine) {
	for i := len(e.sheets) - 1; i >= 0; i -= 1 {
		if e.sheets[i].origin == .Author { sheet_free(e.sheets[i]); ordered_remove(&e.sheets, i) }
	}
	e.dirty = true
	e.shadow.dirty = true
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
	if len(text) > e.settings.max_sheet_bytes { slot.failed = true; return false }
	return resolve_import(e, parent, slot, css.parse_stylesheet(text, parse_options(&e.settings)), base_url)
}

@(private)
resolve_import :: proc(e: ^Engine, parent: ^Sheet, slot: ^Import_Slot, sheet: ^css.Stylesheet, base_url: string) -> bool {
	slot.requested = true
	if parent.depth + 1 > e.settings.max_import_depth || len(sheet.source) > e.settings.max_sheet_bytes {
		slot.failed = true
		css.stylesheet_destroy(sheet); free(sheet)
		return false
	}
	// imported sheets are owned by the slot, not by the engine's list
	s := new(Sheet)
	s.sheet = sheet
	e.next_sheet_id += 1
	s.id = e.next_sheet_id
	s.origin, s.depth = parent.origin, parent.depth + 1
	s.scope = parent.scope
	s.base_url = strings.clone(base_url)
	s.imports = make([dynamic]Import_Slot)
	for r in s.sheet.rules { if r.kind == .Import { append(&s.imports, Import_Slot{rule = r}) } }
	slot.child = s
	sheet_changed(e, s)
	return true
}

////////////////////////////////
// Compiling rules

LayerCtx :: struct { path: string, rank: u32, cq: ^Cq_Cond }   // cq: the @container conditions around (container.odin)

@(private)
layer_rank :: proc(e: ^Engine, path: string) -> u32 {
	if path == "" { return UNLAYERED }
	rs := e.cur
	for n, i in rs.layers { if n == path { return u32(i) } }
	append(&rs.layers, strings.clone(path, e.alloc))
	return u32(len(rs.layers) - 1)
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
// What compiling declarations finds out about the engine's rules. A style pass running on several threads collects it
// per thread and merges it afterwards (`stats_merge`), so the engine is only read meanwhile.
Compile_Stats :: struct {
	viewport_units:  bool,
	container_units: bool,
	ignored:         int,
}

stats_merge :: proc(e: ^Engine, s: Compile_Stats) {
	if s.viewport_units { e.viewport_units = true }
	if s.container_units { e.container_dependent = true }
	e.ignored_properties += s.ignored
}

@(private)
uses_container_units :: proc(vs: []css.Value) -> bool {
	for v in vs {
		switch v.kind {
		case .Token:
			if v.tok.kind == .Dimension {
				if u, ok := css.relative_unit(v.tok.text); ok && (u == .Cqw || u == .Cqh || u == .Cqmin || u == .Cqmax) { return true }
			}
		case .Function, .Block:
			if uses_container_units(v.children) { return true }
		}
	}
	return false
}

compile_declarations :: proc(e: ^Engine, decls: []css.Declaration, a: runtime.Allocator, stats: ^Compile_Stats = nil) -> (out: []Pre_Decl, customs: []Custom_Decl) {
	local: Compile_Stats
	st := stats != nil ? stats : &local
	defer if stats == nil { stats_merge(e, local) }
	res := make([dynamic]Pre_Decl, a)
	cus := make([dynamic]Custom_Decl, a)
	probe := probe_context(e, a)
	valid :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
		if css_wide_keyword(vs) != "" { return true }
		return apply_prop(cx, p, vs)
	}
	for d in decls {
		if !st.viewport_units && !e.viewport_units && uses_viewport_units(d.value) { st.viewport_units = true }
		if !st.container_units && !e.container_dependent && uses_container_units(d.value) { st.container_units = true }
		if strings.has_prefix(d.name, "--") {
			append(&cus, Custom_Decl{name = d.name, value = d.value, important = d.important})
			continue
		}
		p, sh, known := lookup_property(d.name)
		if !known { st.ignored += 1; continue }
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
	rs := e.cur
	compute_ancestor_hashes(&ent)
	kinds, uses_has := complex_state(ent.complex)
	if len(ent.complex.part_state) > 0 {
		k, _ := compound_state(css.Compound{simples = ent.complex.part_state})
		kinds += k
	}
	ent.state = kinds
	if ent.state != {} {
		rs.state_deps += ent.state
		append(&rs.state_entries, ent)
		if uses_has { rs.state_uses_has = true }
	}
	c := ent.complex
	last := c.compounds[len(c.compounds) - 1]
	if complex_uses_host_context(c) { rs.uses_host_context = true }
	// shadow-tree rules apart (scope.odin): ::slotted() for slotted elements, ::part() for parts of hosts in this
	// tree, :host in the subject for the host; they are matched where those elements are styled
	#partial switch c.pseudo_element {
	case .Slotted: append(&rs.slotted_entries, ent); return
	case .Part: append(&rs.part_entries, ent); return
	}
	if host_only, has_host := compound_host(last); has_host {
		append(&rs.host_entries, ent)
		if host_only { return }
	}
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
	ix := &rs.index
	switch {
	case var_id != "": add(&ix.by_id, var_id, ent)
	case var_class != "": add(&ix.by_class, var_class, ent)
	case var_attr != nil:
		add(&ix.by_attr, strings.concatenate({var_attr.name, "\x00", var_attr.value}, context.temp_allocator), ent, own_key = true)
		ix.attr_names[var_attr.name] = true
	case var_tag != "": add(&ix.by_tag, var_tag, ent)
	case: append(&ix.universal, ent)
	}
}

@(private)
compile_style_rule :: proc(e: ^Engine, r: ^css.Rule, origin: Origin, lc: LayerCtx) {
	rs := e.cur
	if rs.rule_count >= e.settings.max_rules_total { return }
	decls, customs := compile_declarations(e, r.declarations, e.alloc)
	if len(decls) > 0 || len(customs) > 0 {
		rs.rule_count += 1
		rs.order += 1
		rule := new(Rule, e.alloc)
		rule.decls, rule.customs, rule.origin, rule.layer, rule.order, rule.cq = decls, customs, origin, lc.rank, rs.order, lc.cq
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
		if media_depends_on_viewport(r.media) { e.media_dependent = true; e.cur.conditional = true }
		if media_note(e, r.media) { for n in r.rules { flatten_rule(e, n, origin, lc) } }
	case .Supports:
		if supports_condition(e, r.supports) { for n in r.rules { flatten_rule(e, n, origin, lc) } }
	case .Layer_Block:
		path := r.layer
		if path == "" { e.anon_layers += 1; path = fmt.tprintf("\x00anon%d", e.anon_layers) }
		if lc.path != "" { path = strings.concatenate({lc.path, ".", path}, context.temp_allocator) }
		sub := LayerCtx{path = path, rank = layer_rank(e, path), cq = lc.cq}
		for n in r.rules { flatten_rule(e, n, origin, sub) }
	case .Container:
		if r.container == nil { return }
		e.container_dependent = true
		cond := new(Cq_Cond, e.alloc)
		cond^ = Cq_Cond{query = r.container, next = lc.cq}
		sub := lc
		sub.cq = cond
		for n in r.rules { flatten_rule(e, n, origin, sub) }
	case .Layer_Statement:
		for name in r.layer_names {
			path := lc.path != "" ? strings.concatenate({lc.path, ".", name}, context.temp_allocator) : name
			layer_rank(e, path)
		}
	// @font-face and @property apply from the document only (as in Blink and CSS Properties and Values: a shadow
	// tree's are ignored); @keyframes of a shadow tree go to its rule set
	case .Font_Face: if e.cur == &e.rules { append(&e.font_faces, Font_Face_Ref{rule = r, base_url = e.cur_base_url, origin = origin}) }
	case .Keyframes:
		e.kf_order += 1
		append(e.cur == &e.rules ? &e.keyframes : &e.cur.kf_refs, Keyframes_Ref{rule = r, layer = lc.rank, order = e.kf_order, origin = origin})
	case .Property: if e.cur == &e.rules { register_property(e, r) }
	case .Import, .Namespace, .Page, .Unknown:
	}
}

// A media list of the document's rules evaluated by a rebuild, and its result then.
@(private)
Media_Seen :: struct {
	list:    css.Media_Query_List,   // in e.alloc: valid until the next rebuild
	matched: bool,
}

// Evaluates a media list of the rules being flattened, remembering it (document rules only: shadow rule sets have their
// own invalidation, Shadow_Styles.media_dependent).
@(private)
media_note :: proc(e: ^Engine, list: css.Media_Query_List) -> bool {
	m := css.media_matches(list, e.env)
	if e.cur == &e.rules { append(&e.media_seen, Media_Seen{list = list, matched = m}) }
	return m
}

@(private)
media_flipped :: proc(e: ^Engine) -> bool {
	for s in e.media_seen { if css.media_matches(s.list, e.env) != s.matched { return true } }
	return false
}

@(private)
media_depends_on_viewport :: proc(list: css.Media_Query_List) -> bool {
	return len(list) > 0   // any condition may depend on the viewport or the color scheme; cheap to rebuild, so be conservative
}

@(private)
flatten_sheet :: proc(e: ^Engine, s: ^Sheet, lc_in: LayerCtx) {
	if len(s.media) > 0 {
		e.media_dependent = true
		e.cur.conditional = true
		if !media_note(e, s.media) { return }
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
				e.cur.conditional = true
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
	rule_set_clear(&e.rules)
	e.cur = &e.rules
	e.viewport_units = false
	clear(&e.font_faces)
	clear(&e.faces)
	clear(&e.keyframes)
	clear(&e.keyframe_sets)
	clear(&e.registered)
	e.registered_noninherited = 0
	e.container_dependent = false
	e.media_dependent, e.anon_layers, e.kf_order = false, 0, 0
	clear(&e.media_seen)

	if doc != nil {
		// shadow-including tree order: the sheets of a shadow tree in its own order
		ordinal := make(map[base.Handle]int, context.temp_allocator)
		n := 0
		for h := doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(doc, h, doc.root) { ordinal[h] = n; n += 1 }
		for s in e.sheets { if s.origin == .Author { s.order = ordinal[s.owner] or_else 0 } }
	}
	slice.stable_sort_by(e.sheets[:], proc(a, b: ^Sheet) -> bool {
		if a.origin != b.origin { return int(a.origin) < int(b.origin) }
		return a.order < b.order
	})
	// the media lists of the owners live in e.alloc, which was just reset: parsed again from their text
	opt := parse_options(&e.settings)
	for s in e.sheets {
		s.media = nil
		if s.media_text != "" { s.media = css.parse_media_query_list(css.parse_component_values(s.media_text, opt, context.temp_allocator), e.alloc) }
	}
	// the document's own sheets, then those it adopted (CSSOM: after the document's sheets, in their order)
	for s in e.sheets {
		if s.scope != base.NIL_HANDLE || s.constructed { continue }
		flatten_sheet(e, s, LayerCtx{rank = UNLAYERED})
	}
	for id in e.shadow.doc_adopted {
		if s := engine_find_sheet(e, id); s != nil && !s.disabled { flatten_sheet(e, s, LayerCtx{rank = UNLAYERED}) }
	}
	compile_keyframes(e)
	parse_font_faces(e)
	e.rebuilds += 1
	e.dirty = false
	e.shadow.dirty = true   // the environment may have changed: shadow rule sets are checked again (scope.odin)
}

// Updates the rendering environment. Returns true when the index has to be rebuilt because the change can alter which
// conditional rules apply.
engine_set_environment :: proc(e: ^Engine, env: css.Media_Env) -> bool {
	changed := env != e.env
	old := e.env
	e.env = env
	// the rules in force change only if some media list the last rebuild evaluated answers otherwise now (a window
	// resized between two breakpoints keeps them)
	flipped := changed && e.media_dependent && media_flipped(e)
	if flipped { e.dirty = true }
	if changed && e.shadow.media_dependent { e.shadow.dirty = true; e.restyle_needed = true }
	// styles depend on the viewport only through conditional rules and viewport units, and on the color scheme through
	// light-dark() and media queries; anything else (a plain width change) needs layout only
	size_changed := old.width != env.width || old.height != env.height
	if changed && ((size_changed && (flipped || e.shadow.media_dependent || e.viewport_units)) || old.prefers_dark != env.prefers_dark ||
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
		case v.kind == .Function && strings.equal_fold(v.tok.text, "font-format"):
			args := css.trim_values(v.children)
			val = len(args) == 1 && args[0].kind == .Token && (args[0].tok.kind == .Ident || args[0].tok.kind == .String) &&
			      font_format_supported(face_format(args[0].tok.text))
		case v.kind == .Function && strings.equal_fold(v.tok.text, "font-tech"):
			args := css.trim_values(v.children)
			val = len(args) == 1 && args[0].kind == .Token && args[0].tok.kind == .Ident && font_tech_supported(args[0].tok.text)
		case v.kind == .Function:
			val = false   // <general-enclosed>: unknown functions are false, the rest of the condition still counts
		case v.kind == .Block && v.tok.kind == .Open_Paren:
			val = supports_block(e, v.children)
		case: return false
		}
		if first { result = val; first = false } else if op == "and" { result = result && val } else { result = result || val }
	}
	return result
}

// CSS.supports(conditionText) (CSS Conditional 3 §8.1): `text` as a <supports-condition>, else wrapped in parentheses
// (so that "display: grid" works as "(display: grid)").
supports_text :: proc(e: ^Engine, text: string, opt: css.Parse_Options) -> bool {
	if supports_condition(e, css.parse_component_values(text, opt, context.temp_allocator)) { return true }
	wrapped := strings.concatenate({"(", text, ")"}, context.temp_allocator)
	return supports_condition(e, css.parse_component_values(wrapped, opt, context.temp_allocator))
}

// CSS.supports(property, value): a property the engine knows (a custom property: any value) whose value parses.
supports_declaration :: proc(e: ^Engine, property, value: string, opt: css.Parse_Options) -> bool {
	if strings.has_prefix(property, "--") { return len(property) > 2 }
	// the property is taken as it is written: "(property: value)" with an identifier that does not need escaping
	for ch in property { if !(ch == '-' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9') { return false } }
	text := strings.concatenate({"(", property, ": ", value, ")"}, context.temp_allocator)
	return supports_condition(e, css.parse_component_values(text, opt, context.temp_allocator))
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
	// the initial values are computed once per configuration and copied: every validated declaration (each
	// style.setProperty of a script) used to compute them twice. A shallow copy is enough: applying a declaration
	// replaces a field's slices, it never writes into them.
	if e.probe_base == nil {
		// on the heap whoever calls (the caller's allocator may be a temporary one); kept until the next configuration
		context.allocator = runtime.heap_allocator()
		e.probe_base = new(Computed)
		e.probe_base^ = initial_computed(&e.settings)
	}
	c := new(Computed, a)
	c^ = e.probe_base^
	// a root without a parent: what `initial`, `currentcolor` on the root and unset non-inherited values read
	init := new(Computed, a)
	init^ = c^
	return Cx{settings = &e.settings, c = c, initial = init, alloc = a, lc = css.Length_Context{font_size = 16, root_font_size = 16, vw = 1280, vh = 800},
		cenv = css.Color_Env{system = system_color, user = &e.settings}}
}

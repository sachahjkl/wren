package style

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// Style scoping (CSS Scoping 1): every shadow tree has rules of its own.
//
// Rule sets. The document's rules are the engine's own (`Engine.rules`); each shadow root whose tree has stylesheets
// (<style>, <link rel=stylesheet>, adopted constructable sheets) gets a Rule_Set compiled from those sheets, with the
// browser's and the user's rules (they apply in every tree). Sets are shared: shadow roots whose sheets have the same
// text (a thousand instances of one component) use one set, found by a key made of their sheets' contents. A set owns
// copies of its sheets (parsed again from their text), so it does not depend on any one tree staying alive; it is
// compiled once, and again only when the environment changes what its conditional rules say. A shadow tree without
// sheets uses the set of the built-in rules alone.
//
// What a set holds besides its index: the rules whose subject is the host (`:host`, `:host(...)`, matched against the
// host, featureless, from outside the tree), `::slotted()` rules (matched against the elements assigned to the tree's
// slots) and `::part()` rules (matched against the parts of hosts in the tree).
//
// The cascade (cascade.odin) adds the encapsulation context between origin and layer: every candidate declaration
// carries the depth of the tree its rule came from (the document 0, a shadow tree one more than its host's); normal
// declarations of an outer tree win over an inner one's, !important ones the other way round (CSS Cascade 5 §6.1).

Rule_Set :: struct {
	index:          Index,
	layers:         [dynamic]string,   // layer names in cascade order (later = stronger), of this set's sheets
	order:          u32,
	rule_count:     int,
	state_deps:     State_Kinds,       // dynamic state the rules depend on
	state_entries:  [dynamic]Entry,    // entries that depend on some state
	state_uses_has: bool,              // a state-dependent :has() exists: its effect cannot be scoped
	inv:            Inv_Index,         // what DOM mutations reach (invalidation.odin), built on demand
	host_entries:   [dynamic]Entry,    // subject compound with :host: matched against the host
	slotted_entries: [dynamic]Entry,   // ::slotted()
	part_entries:   [dynamic]Entry,    // ::part()
	uses_host_context: bool,
	conditional:    bool,              // has conditional rules (media, a sheet's media list)
	kf_refs:        [dynamic]Keyframes_Ref,
	// shadow sets only
	key:            string,
	set_arena:      virtual.Arena,
	set_alloc:      runtime.Allocator,
	copies:         [dynamic]^Sheet,   // the copies of the sheets it was compiled from
	set_env:        css.Media_Env,     // the environment it was compiled for
	gen:            u64,               // unique per compiled set (the invalidation index follows it)
	kf_sets:        map[string]^Keyframes_Set,
	users:          int,
}

Shadow_Styles :: struct {
	sets:        map[string]^Rule_Set,           // compiled sets by key
	of_root:     map[base.Handle]^Rule_Set,      // shadow roots with sheets -> their set
	ua_set:      ^Rule_Set,                      // the built-in rules alone (shadow trees without sheets)
	adopted:     map[base.Handle][dynamic]u64,   // adoptedStyleSheets of shadow roots (sheet ids)
	doc_adopted: [dynamic]u64,                   // ... of the document
	dirty:       bool,                           // some shadow tree's sheets may have changed: resolve again
	changed:     [dynamic]base.Handle,           // shadow roots whose set changed in the last resolve
	media_dependent: bool,                       // some set in use has conditional rules
	state_deps:  State_Kinds,                    // union over the sets in use
	state_uses_has: bool,
	uses_host_context: bool,
	keyframes:   map[string]^Keyframes_Set,      // @keyframes of shadow trees (the document's win, see keyframes_lookup)
	next_gen:    u64,
	resolved_once: bool,
}

// Frees what a set holds besides its arena (the document's set: its entries live in the engine's arena).
@(private)
rule_set_clear :: proc(rs: ^Rule_Set) {
	index_free(&rs.index)
	delete(rs.layers); rs.layers = nil
	delete(rs.state_entries); rs.state_entries = nil
	inv_free(&rs.inv)
	delete(rs.host_entries); rs.host_entries = nil
	delete(rs.slotted_entries); rs.slotted_entries = nil
	delete(rs.part_entries); rs.part_entries = nil
	delete(rs.kf_refs); rs.kf_refs = nil
	rs.order, rs.rule_count, rs.state_deps, rs.state_uses_has, rs.uses_host_context, rs.conditional = 0, 0, {}, false, false, false
}

@(private = "file")
set_free :: proc(rs: ^Rule_Set) {
	rule_set_clear(rs)
	for s in rs.copies { sheet_free(s) }
	delete(rs.copies)
	delete(rs.kf_sets)
	delete(rs.key)
	virtual.arena_destroy(&rs.set_arena)
	free(rs)
}

// Forgets every compiled set (the built-in sheets changed): they are compiled again on demand.
@(private)
shadow_sets_forget :: proc(e: ^Engine) {
	sh := &e.shadow
	for _, rs in sh.sets { set_free(rs) }
	clear(&sh.sets)
	if sh.ua_set != nil { set_free(sh.ua_set); sh.ua_set = nil }
	for root in sh.of_root { append(&sh.changed, root) }
	clear(&sh.of_root)
	sh.dirty = true
}

@(private)
shadow_styles_destroy :: proc(e: ^Engine) {
	sh := &e.shadow
	for _, rs in sh.sets { set_free(rs) }
	delete(sh.sets)
	if sh.ua_set != nil { set_free(sh.ua_set) }
	delete(sh.of_root)
	for _, l in sh.adopted { delete(l) }
	delete(sh.adopted)
	delete(sh.doc_adopted)
	delete(sh.changed)
	delete(sh.keyframes)
	sh^ = {}
}

////////////////////////////////
// Constructable stylesheets and adoption (CSSOM §6.1: new CSSStyleSheet(), replaceSync, adoptedStyleSheets)

@(private)
adopted_by_document :: proc(e: ^Engine, id: u64) -> bool {
	for x in e.shadow.doc_adopted { if x == id { return true } }
	return false
}

// A new constructed sheet with `text` (its @import rules ignored, as replaceSync says); returns its id.
engine_constructed_create :: proc(e: ^Engine, text: string, media: string = "", base_url: string = "") -> u64 {
	t := text
	if len(t) > e.settings.max_sheet_bytes { t = "" }
	s := register_sheet(e, css.parse_stylesheet(t, parse_options(&e.settings)), .Author, base.NIL_HANDLE, media, false, "", base_url, constructed = true)
	clear(&s.imports)
	return s.id
}

// replace() / replaceSync(), insertRule()... of a constructed sheet: its whole text. False: no such sheet.
engine_constructed_replace :: proc(e: ^Engine, id: u64, text: string) -> bool {
	s := engine_find_sheet(e, id)
	if s == nil || !s.constructed { return false }
	t := text
	if len(t) > e.settings.max_sheet_bytes { t = "" }
	css.stylesheet_destroy(s.sheet)
	free(s.sheet)
	s.sheet = css.parse_stylesheet(t, parse_options(&e.settings))
	clear(&s.imports)
	s.version += 1
	sheet_changed(e, s)
	return true
}

engine_constructed_set_disabled :: proc(e: ^Engine, id: u64, disabled: bool) {
	s := engine_find_sheet(e, id)
	if s == nil || !s.constructed || s.disabled == disabled { return }
	s.disabled = disabled
	s.version += 1
	sheet_changed(e, s)
}

engine_constructed_set_media :: proc(e: ^Engine, id: u64, media: string) {
	s := engine_find_sheet(e, id)
	if s == nil || !s.constructed { return }
	sheet_set_media(e, s, media)
}

// A new media list for a sheet in place (a constructed sheet's media, the media attribute of a loaded <link>): its rules
// stay parsed, only whether they apply changes.
sheet_set_media :: proc(e: ^Engine, s: ^Sheet, media: string) {
	if s.media_text == media { return }
	delete(s.media_text)
	s.media_text = strings.clone(media)
	s.media = nil
	if media != "" { s.media = css.parse_media_query_list(css.parse_component_values(media, parse_options(&e.settings), context.temp_allocator), e.alloc) }
	s.version += 1
	sheet_changed(e, s)
}

// The constructed sheet's object is gone: so is the sheet, from wherever it was adopted.
engine_constructed_destroy :: proc(e: ^Engine, id: u64) {
	s := engine_find_sheet(e, id)
	if s == nil || !s.constructed { return }
	if adopted_by_document(e, id) {
		for x, i in e.shadow.doc_adopted { if x == id { ordered_remove(&e.shadow.doc_adopted, i); break } }
		e.dirty = true
	}
	for _, &l in e.shadow.adopted {
		for i := len(l) - 1; i >= 0; i -= 1 { if l[i] == id { ordered_remove(&l, i); e.shadow.dirty = true } }
	}
	engine_remove_sheet(e, s)
}

// The current text of a constructed (or any) sheet.
engine_sheet_text :: proc(e: ^Engine, id: u64) -> string {
	s := engine_find_sheet(e, id)
	return s != nil && s.sheet != nil ? s.sheet.source : ""
}

// adoptedStyleSheets of `root` (the document node when `document`, else a shadow root) become `ids`, in order.
engine_set_adopted :: proc(e: ^Engine, root: base.Handle, ids: []u64, document: bool) {
	sh := &e.shadow
	if document {
		if slice.equal(sh.doc_adopted[:], ids) { return }
		clear(&sh.doc_adopted)
		append(&sh.doc_adopted, ..ids)
		e.dirty = true
		return
	}
	old, had := sh.adopted[root]
	if had && slice.equal(old[:], ids) { return }
	if len(ids) == 0 {
		if had { delete(old); delete_key(&sh.adopted, root) }
	} else {
		if !had { old = make([dynamic]u64) }
		clear(&old)
		append(&old, ..ids)
		sh.adopted[root] = old
	}
	sh.dirty = true
}

// The adopted sheets of a shadow root that went away.
engine_forget_shadow_root :: proc(e: ^Engine, root: base.Handle) {
	sh := &e.shadow
	if l, ok := sh.adopted[root]; ok { delete(l); delete_key(&sh.adopted, root); sh.dirty = true }
	if _, ok := sh.of_root[root]; ok { sh.dirty = true }
}

////////////////////////////////
// Resolving the sets of the shadow trees

@(private = "file")
fnv64 :: proc(s: string) -> u64 {
	h := u64(0xcbf29ce484222325)
	for i in 0 ..< len(s) { h = (h ~ u64(s[i])) * 0x100000001b3 }
	return h
}

// What a sheet contributes to a set's key: its contents and those of what it imports.
@(private = "file")
sheet_key :: proc(sb: ^strings.Builder, s: ^Sheet, depth := 0) {
	src := s.sheet != nil ? s.sheet.source : ""
	fmt.sbprintf(sb, "{%x:%d|%s|%v%s|%s", fnv64(src), len(src), s.media_text, s.in_layer, s.layer, s.base_url)
	if depth < 16 {
		for &slot in s.imports {
			if slot.child != nil { sheet_key(sb, slot.child, depth + 1) } else { strings.write_string(sb, "-") }
		}
	}
	strings.write_string(sb, "}")
}

// A copy of a sheet (and of what it imports), parsed again from its text: owned by a rule set.
@(private = "file")
sheet_copy :: proc(e: ^Engine, s: ^Sheet, depth := 0) -> ^Sheet {
	c := new(Sheet)
	src := s.sheet != nil ? s.sheet.source : ""
	c.sheet = css.parse_stylesheet(src, parse_options(&e.settings))
	c.origin, c.depth, c.order = s.origin, s.depth, s.order
	c.media_text = strings.clone(s.media_text)
	c.in_layer, c.layer = s.in_layer, strings.clone(s.layer)
	c.base_url = strings.clone(s.base_url)
	c.imports = make([dynamic]Import_Slot)
	k := 0
	for r in c.sheet.rules {
		if r.kind != .Import { continue }
		slot := Import_Slot{rule = r, requested = true}
		if k < len(s.imports) && s.imports[k].child != nil && depth < 16 { slot.child = sheet_copy(e, s.imports[k].child, depth + 1) }
		append(&c.imports, slot)
		k += 1
	}
	return c
}

@(private = "file")
set_compile :: proc(e: ^Engine, key: string, sheets: []^Sheet) -> ^Rule_Set {
	rs := new(Rule_Set)
	rs.key = strings.clone(key)
	_ = virtual.arena_init_growing(&rs.set_arena)
	rs.set_alloc = virtual.arena_allocator(&rs.set_arena)
	rs.set_env = e.env
	e.shadow.next_gen += 1
	rs.gen = e.shadow.next_gen
	saved_alloc, saved_cur := e.alloc, e.cur
	e.alloc, e.cur = rs.set_alloc, rs
	defer { e.alloc, e.cur = saved_alloc, saved_cur }
	opt := parse_options(&e.settings)
	// the browser's and the user's rules (their sheets live until engine_configure, which forgets every set)
	for s in e.sheets { if s.origin != .Author { flatten_sheet(e, s, LayerCtx{rank = UNLAYERED}) } }
	for s in sheets {
		c := sheet_copy(e, s)
		append(&rs.copies, c)
		copy_media :: proc(c: ^Sheet, opt: css.Parse_Options, a: runtime.Allocator, depth: int) {
			if c.media_text != "" { c.media = css.parse_media_query_list(css.parse_component_values(c.media_text, opt, context.temp_allocator), a) }
			if depth < 16 { for &slot in c.imports { if slot.child != nil { copy_media(slot.child, opt, a, depth + 1) } } }
		}
		copy_media(c, opt, rs.set_alloc, 0)
		flatten_sheet(e, c, LayerCtx{rank = UNLAYERED})
	}
	compile_keyframes_into(e, rs.kf_refs[:], &rs.kf_sets)
	return rs
}

// Brings the shadow roots' rule sets in line with their sheets (and the environment). Cheap when nothing changed.
// The roots whose set changed are listed in `e.shadow.changed` (until the caller clears it).
scopes_resolve :: proc(e: ^Engine, doc: ^dom.Document) {
	sh := &e.shadow
	if !sh.dirty { return }
	sh.dirty = false
	sh.resolved_once = true
	// the sheets of each shadow tree, in tree order (owners' positions in their tree)
	per_root := make(map[base.Handle][dynamic]^Sheet, 16, context.temp_allocator)
	for s in e.sheets {
		if s.origin != .Author || s.scope == base.NIL_HANDLE || s.constructed { continue }
		l := per_root[s.scope]
		if l == nil { l = make([dynamic]^Sheet, context.temp_allocator) }
		append(&l, s)
		per_root[s.scope] = l
	}
	for root, &l in per_root {
		if len(l) < 2 { continue }
		pos := make(map[base.Handle]int, len(l), context.temp_allocator)
		k := 0
		for cur := dom.next_in_tree(doc, root, root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(doc, cur, root) { pos[cur] = k; k += 1 }
		for s in l { s.order = pos[s.owner] or_else 0 }
		slice.stable_sort_by(l[:], proc(a, b: ^Sheet) -> bool { return a.order < b.order })
	}
	for root, ids in sh.adopted {
		l := per_root[root]
		if l == nil { l = make([dynamic]^Sheet, context.temp_allocator) }
		for id in ids { if s := engine_find_sheet(e, id); s != nil && !s.disabled { append(&l, s) } }
		per_root[root] = l
	}
	fresh := make(map[base.Handle]^Rule_Set, len(per_root), context.temp_allocator)
	for root, l in per_root {
		if !dom.is_shadow_root(doc, root) || len(l) == 0 { continue }
		kb := strings.builder_make(context.temp_allocator)
		for s in l {
			sheet_key(&kb, s)
		}
		key := strings.to_string(kb)
		rs, ok := sh.sets[key]
		if ok && rs.conditional && rs.set_env != e.env {
			// compiled for another environment: compiled again (the roots using it are listed as changed below)
			delete_key(&sh.sets, key)
			set_free(rs)
			ok = false
		}
		if !ok {
			rs = set_compile(e, key, l[:])
			sh.sets[rs.key] = rs
		}
		fresh[root] = rs
	}
	if sh.ua_set != nil && sh.ua_set.conditional && sh.ua_set.set_env != e.env { set_free(sh.ua_set); sh.ua_set = nil }
	// what changed
	for root, old in sh.of_root {
		if fresh[root] != old { append(&sh.changed, root) }
	}
	for root in fresh { if root not_in sh.of_root { append(&sh.changed, root) } }
	clear(&sh.of_root)
	for root, rs in fresh { sh.of_root[root] = rs }
	// sets nobody uses go
	for _, rs in sh.sets { rs.users = 0 }
	for _, rs in sh.of_root { rs.users += 1 }
	for key, rs in sh.sets {
		if rs.users == 0 { delete_key(&sh.sets, key); set_free(rs) }
	}
	shadow_summary(e)
}

// What the sets in use depend on, together.
@(private = "file")
shadow_summary :: proc(e: ^Engine) {
	sh := &e.shadow
	sh.state_deps, sh.state_uses_has, sh.uses_host_context, sh.media_dependent = {}, false, false, false
	clear(&sh.keyframes)
	add :: proc(sh: ^Shadow_Styles, rs: ^Rule_Set) {
		sh.state_deps += rs.state_deps
		sh.state_uses_has ||= rs.state_uses_has
		sh.uses_host_context ||= rs.uses_host_context
		sh.media_dependent ||= rs.conditional
		for name, kf in rs.kf_sets { if name not_in sh.keyframes { sh.keyframes[name] = kf } }
	}
	for _, rs in sh.sets { add(sh, rs) }
	if sh.ua_set != nil { add(sh, sh.ua_set) }
}

// The set of shadow root `root` (the built-in rules alone when its tree has no sheets).
shadow_set_of :: proc(e: ^Engine, root: base.Handle) -> ^Rule_Set {
	if rs, ok := e.shadow.of_root[root]; ok { return rs }
	sh := &e.shadow
	if sh.ua_set == nil {
		sh.ua_set = set_compile(e, "", nil)
		shadow_summary(e)
	}
	return sh.ua_set
}

////////////////////////////////
// Selector helpers

// Whether the compound has :host / :host() / :host-context() at its top level (`host_only`: then it can match the
// host only), or anywhere in it (`has`).
@(private)
compound_host :: proc(comp: css.Compound) -> (host_only: bool, has: bool) {
	for s in comp.simples {
		if s.kind != .Pseudo_Class { continue }
		#partial switch s.pseudo {
		case .Host, .Host_Context: return true, true
		case .Is, .Where, .Not:
			if s.list != nil && list_has_host(s.list^, 0) { has = true }
		}
	}
	return false, has
}

@(private)
list_has_host :: proc(list: css.Selector_List, depth: int) -> bool {
	if depth > 16 { return false }
	for &c in list {
		for comp in c.compounds {
			for s in comp.simples {
				if s.kind == .Pseudo_Class && (s.pseudo == .Host || s.pseudo == .Host_Context) { return true }
				if s.list != nil && list_has_host(s.list^, depth + 1) { return true }
			}
		}
	}
	return false
}

@(private)
complex_uses_host_context :: proc(c: ^css.Complex) -> bool {
	for comp in c.compounds {
		for s in comp.simples { if s.kind == .Pseudo_Class && s.pseudo == .Host_Context { return true } }
	}
	return false
}

////////////////////////////////
// The tree an element is styled in

// The rules an element is matched against and its encapsulation depth: those of its tree (the document's, or its
// shadow root's set).
Elem_Ctx :: struct {
	set:   ^Rule_Set,     // nil: the document's (Engine.rules)
	root:  base.Handle,   // the shadow root of its tree; NIL for the document's tree
	host:  base.Handle,   // that root's host (matched featureless by the set's :host)
	depth: u16,
}

// The context of shadow root `root` (or of the document's tree for anything else), cached per pass.
@(private)
ctx_for_root :: proc(p: ^Pass, root: base.Handle) -> Elem_Ctx {
	doc := p.mc.doc
	n := dom.get(doc, root)
	if n == nil || !n.is_shadow { return {} }
	if p.ctx_cache == nil { p.ctx_cache = make(map[base.Handle]Elem_Ctx, 16, context.temp_allocator) }
	if c, ok := p.ctx_cache[root]; ok { return c }
	host := n.shadow
	outer := ctx_for_root(p, dom.tree_root(doc, host))
	c := Elem_Ctx{set = shadow_set_of(p.e, root), root = root, host = host, depth = outer.depth + 1}
	p.ctx_cache[root] = c
	return c
}

// The context of any node (a walk to its root: callers that walk the flat tree derive it from the parent's instead).
@(private)
node_ctx :: proc(p: ^Pass, h: base.Handle) -> Elem_Ctx {
	doc := p.mc.doc
	if !dom.has_shadow_trees(doc) { return {} }
	return ctx_for_root(p, dom.tree_root(doc, h))
}

// The context of `child`, a flat-tree child of `parent` (whose context is `pc`).
@(private)
child_ctx :: proc(p: ^Pass, parent: base.Handle, pc: Elem_Ctx, child: base.Handle) -> Elem_Ctx {
	doc := p.mc.doc
	if !dom.has_shadow_trees(doc) { return pc }
	pn := dom.get(doc, parent)
	if pn != nil && pn.kind == .Element && pn.shadow != base.NIL_HANDLE { return ctx_for_root(p, pn.shadow) }
	cn := dom.get(doc, child)
	if cn != nil && cn.slot != base.NIL_HANDLE {
		// an assigned node: in the tree of its parent, the host
		if p.host_ctx == nil { p.host_ctx = make(map[base.Handle]Elem_Ctx, 16, context.temp_allocator) }
		if c, ok := p.host_ctx[cn.parent]; ok { return c }
		c := node_ctx(p, cn.parent)
		p.host_ctx[cn.parent] = c
		return c
	}
	return pc
}

// The flat-tree parent of `h` when it is an element (inheritance, the ancestor filter), else NIL_HANDLE.
@(private)
flat_parent_element :: proc(doc: ^dom.Document, h: base.Handle) -> base.Handle {
	p := dom.flat_parent(doc, h)
	n := dom.get(doc, p)
	if n == nil || n.kind != .Element { return base.NIL_HANDLE }
	return p
}

// @keyframes of shadow trees, for animation names the document does not define.
@(private)
shadow_keyframes_lookup :: proc(e: ^Engine, name: string) -> ^Keyframes_Set {
	return e.shadow.keyframes[name] or_else nil
}

// The `exportparts` mapping of a host applied to `names` (CSS Shadow Parts §4.2): "inner: outer" pairs and bare
// names, comma separated.
@(private)
export_parts :: proc(n: ^dom.Node, names: []string) -> []string {
	v, ok := attr(n, "exportparts")
	if !ok { return nil }
	out := make([dynamic]string, context.temp_allocator)
	for item in strings.split(v, ",", context.temp_allocator) {
		t := strings.trim_space(item)
		if t == "" { continue }
		inner, outer := t, t
		if c := strings.index_byte(t, ':'); c >= 0 {
			inner = strings.trim_space(t[:c])
			outer = strings.trim_space(t[c + 1:])
		}
		if inner == "" || outer == "" { continue }
		for nm in names { if nm == inner { append(&out, outer); break } }
	}
	return out[:]
}

////////////////////////////////
// What other trees' rules say about an element

// Appends to the pass's lists what rules of other trees match `el` (in context `ctx`): the :host rules of its shadow
// tree when it is a host, the ::slotted() rules of the trees of the slots it is assigned through, the ::part() rules of
// the trees its host is in when it is a part (forwarded by exportparts). Each with the depth of the tree it came from.
@(private)
shadow_entries :: proc(p: ^Pass, el: base.Handle, n: ^dom.Node, ctx: Elem_Ctx) {
	doc := p.mc.doc
	m := &p.mc
	defer m.featureless = ctx.host
	list_of :: proc(pe: css.Pseudo) -> int {
		#partial switch pe {
		case .None: return 0
		case .Before: return 1
		case .After: return 2
		case .Selection: return 3
		}
		return -1
	}
	add :: proc(p: ^Pass, ent: Entry, k: int, depth: u16) {
		x := ent
		x.ctx = depth
		append(&p.lists[k], x)
	}
	// The contexts' order (CSS Scoping §3.2: shadow-including tree order of the trees, earlier wins for normal
	// declarations, later for important ones) for one element: the trees of its host chain (::part), its own tree,
	// the trees of the slots it goes through (outermost first), its shadow tree (:host) last.
	n_slots := 0
	for slot := n.slot; slot != base.NIL_HANDLE && n_slots < 256; n_slots += 1 {
		sn := dom.get(doc, slot)
		if sn == nil { break }
		slot = sn.slot
	}
	if n.shadow != base.NIL_HANDLE {
		sc := ctx_for_root(p, n.shadow)
		if len(sc.set.host_entries) > 0 {
			m.featureless = el
			for &ent in sc.set.host_entries {
				k := list_of(ent.complex.pseudo_element)
				if k < 0 { continue }
				if matches_complex(m, el, ent.complex) { add(p, ent, k, ctx.depth + 1 + u16(n_slots)) }
			}
		}
	}
	// a slot assigned to a slot is flattened away: ::slotted() sees what it is assigned instead
	is_flattened_slot := n.slot != base.NIL_HANDLE && n.ns == .HTML && n.name == "slot" && ctx.root != base.NIL_HANDLE
	for slot, hops := n.slot, 0; slot != base.NIL_HANDLE && hops < 256 && !is_flattened_slot; hops += 1 {
		sc := ctx_for_root(p, dom.tree_root(doc, slot))
		if sc.set != nil {
			for &ent in sc.set.slotted_entries {
				k := list_of(ent.complex.then_pseudo)
				if k < 0 { continue }
				m.featureless = sc.host
				if !matches_complex(m, slot, ent.complex) { continue }
				if ent.complex.slotted != nil && !matches_compound_plain(m, el, ent.complex.slotted^) { continue }
				add(p, ent, k, ctx.depth + 1 + u16(hops))
			}
		}
		sn := dom.get(doc, slot)
		if sn == nil { break }
		slot = sn.slot
	}
	if ctx.root != base.NIL_HANDLE {
		names := dom.part_names(n)
		host := ctx.host
		// first its own tree's (`:host::part()`: the host seen featureless), then the trees of its host chain
		own := true
		for hops := 0; len(names) > 0 && host != base.NIL_HANDLE && hops < 256; hops += 1 {
			hc := own ? ctx : ctx_for_root(p, dom.tree_root(doc, host))
			if own && (hc.set == nil || len(hc.set.part_entries) == 0) {
				own = false
				hc = ctx_for_root(p, dom.tree_root(doc, host))
			}
			rs := hc.set != nil ? hc.set : &p.e.rules
			for &ent in rs.part_entries {
				k := list_of(ent.complex.then_pseudo)
				if k < 0 { continue }
				all := true
				for want in ent.complex.parts {
					found := false
					for nm in names { if nm == want { found = true; break } }
					if !found { all = false; break }
				}
				if !all { continue }
				m.featureless = hc.host
				if !matches_complex(m, host, ent.complex) { continue }
				m.featureless = base.NIL_HANDLE
				ok := true
				for s in ent.complex.part_state { if !matches_simple(m, el, n, s) { ok = false; break } }
				if ok { add(p, ent, k, hc.depth) }
			}
			if own { own = false; continue }
			if hc.root == base.NIL_HANDLE { break }
			names = export_parts(dom.get(doc, host), names)
			host = hc.host
		}
	}
}

// Before a style pass: the shadow trees' rule sets are up to date and the set of the built-in rules exists (threads of
// a parallel pass only read them).
@(private)
shadow_prepare :: proc(e: ^Engine, doc: ^dom.Document) {
	if !dom.has_shadow_trees(doc) && !e.shadow.resolved_once && len(e.shadow.adopted) == 0 { return }
	scopes_resolve(e, doc)
	if dom.has_shadow_trees(doc) { _ = shadow_set_of(e, base.NIL_HANDLE) }
}
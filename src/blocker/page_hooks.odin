package blocker

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import "core:strings"
import "wb:adblock"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:page"
import "wb:style"

// The blocker in the page: element hiding before the first paint, scriptlets before the page's own scripts.
//
//   * When a parsed document is adopted by the page, the cosmetic filters of its host (adblock.cosmetic_for_host) become
//     a user-origin stylesheet (`display: none !important`, which author rules cannot override), plus the generic
//     selectors keyed to the classes and ids the DOM actually contains. Nothing is painted before that: the first style
//     computation of the document already has the rules.
//   * Procedural selectors (:has-text, :upward...) are evaluated on the DOM here, in Odin; their results are hidden by
//     the style engine directly (style.engine_set_hidden), with no attribute or class added to the page.
//   * When the DOM changes, the new classes and ids are looked up and the procedural selectors run again, at most once
//     per blocker.cosmetic.debounce_ms.
//   * Scriptlets are JavaScript snippets (scriptlets.js) run in the page's realm before any script of the page.

SCRIPTLETS_JS :: #load("scriptlets.js", string)

Doc_Hooks :: struct {
	seen:       map[u32]struct{},     // class and id keys already looked up
	last_mut:   u64,
	last_run:   i64,
	procs:      [dynamic]^Proc_Selector,
	hidden:     map[base.Handle]struct{},
	computed:   bool,
	active:     bool,                 // cosmetic filtering applies to this document
	rules:      int,                  // selectors injected
	poke:       base.Handle,          // a timer that brings the next pass
	page:       ^page.Page,
	timer_data: ^Poke,
	prepared:   bool,                 // the document's scriptlets were sorted by route
	rest:       [dynamic][]string,    // the scriptlets of route .Hook and .Js (owned)
	raw:        [dynamic]string,      // raw JavaScript rules (owned)
	ops:        Dom_Ops,              // dom_ops.odin: the scriptlets that change the document
	owner:      ^Doc,
}

Poke :: struct { hs: ^Doc_Hooks }

install_page_hooks :: proc(b: ^Blocker) {
	page.embedder = page.Embedder_Hooks{
		user = b, realm_started = hook_realm_started, adopted = hook_adopted, before_styles = hook_before_styles,
		before_script = hook_before_script, parsed = hook_parsed, popup_check = popup_check,
		collapse_blocked = b.cfg.collapse,
	}
}

remove_page_hooks :: proc(b: ^Blocker) { page.embedder = {} }

@(private)
doc_of_page :: proc(b: ^Blocker, p: ^page.Page) -> ^Doc { return b.docs[&p.env] }

@(private)
hooks_of :: proc(d: ^Doc) -> ^Doc_Hooks {
	if d.hooks == nil { d.hooks = new(Doc_Hooks) }
	return (^Doc_Hooks)(d.hooks)
}

hooks_free :: proc(d: ^Doc) {
	if d.hooks == nil { return }
	hs := (^Doc_Hooks)(d.hooks)
	hooks_reset(hs)
	delete(hs.seen); delete(hs.hidden); delete(hs.procs); delete(hs.rest); delete(hs.raw)
	free(hs.timer_data)
	free(hs)
	d.hooks = nil
}

@(private)
hooks_reset :: proc(hs: ^Doc_Hooks) {
	for pr in hs.procs { proc_destroy(pr); free(pr) }
	clear(&hs.procs)
	clear(&hs.seen)
	clear(&hs.hidden)
	ops_destroy(&hs.ops, hs.page != nil ? hs.page.loop : nil)
	for r in hs.rest { for s in r { delete(s) }; delete(r) }
	clear(&hs.rest)
	for s in hs.raw { delete(s) }
	clear(&hs.raw)
	hs.prepared = false
	hs.computed, hs.active, hs.rules = false, false, 0
	hs.last_mut = 0
	if hs.poke != base.NIL_HANDLE && hs.page != nil && hs.page.loop != nil { host.clear_timer(hs.page.loop, hs.poke) }
	hs.poke = base.NIL_HANDLE
}

@(private)
cosmetic_applies :: proc(b: ^Blocker, d: ^Doc) -> bool {
	return b.cfg.enabled && b.cfg.cosmetic && !d.unfiltered && .No_Cosmetic not_in d.site && b.engine != nil
}

// The document's cosmetic filters, taken once.
@(private)
ensure_cosmetic :: proc(b: ^Blocker, d: ^Doc) {
	if d.has_cosmetic || b.engine == nil { return }
	d.cosmetic = adblock.cosmetic_for_host(b.engine.engine, d.host, d.page)
	d.has_cosmetic = true
	d.engine = b.engine
	b.engine.refs += 1
}

////////////////////////////////
// Element hiding

@(private)
write_hide_rule :: proc(sb: ^strings.Builder, e: ^adblock.Engine, id: u32) -> (procedural: bool) {
	v := adblock.cosmetic_filter(e, id)
	if v.flags & {.Scriptlet, .Html, .Js_Raw} != {} { return false }
	switch {
	case .Style_Inject in v.flags:
		strings.write_string(sb, v.selector)
		strings.write_byte(sb, '\n')
	case .Procedural in v.flags || .Remove in v.flags:
		return true
	case .Style in v.flags:
		i := strings.last_index(v.selector, ":style(")
		if i < 0 { return false }
		base_sel := v.selector[:i]
		decls := v.selector[i + len(":style("):]
		decls = strings.trim_suffix(decls, ")")
		strings.write_string(sb, base_sel)
		strings.write_byte(sb, '{')
		for d in strings.split(decls, ";", context.temp_allocator) {
			t := strings.trim_space(d)
			if t == "" { continue }
			strings.write_string(sb, t)
			if !strings.contains(t, "!important") { strings.write_string(sb, " !important") }
			strings.write_byte(sb, ';')
		}
		strings.write_string(sb, "}\n")
	case:
		strings.write_string(sb, v.selector)
		strings.write_string(sb, "{display:none!important}\n")
	}
	return false
}

@(private)
add_sheet :: proc(p: ^page.Page, text: string) {
	if text == "" || p.engine == nil { return }
	style.engine_add_injected_sheet(p.engine, text)
}

@(private)
hook_adopted :: proc(user: rawptr, p: ^page.Page) {
	b := (^Blocker)(user)
	d := doc_of_page(b, p)
	if d == nil { return }
	t_start := time.tick_now()
	hs := hooks_of(d)
	hooks_reset(hs)
	hs.page = p
	if d.has_cosmetic { adblock.cosmetic_destroy(&d.cosmetic); d.has_cosmetic = false; if d.engine != nil { engine_ref_drop(b, d.engine); d.engine = nil } }
	doc_refresh(b, d)
	prepare_scriptlets(b, d, hs, p)
	if !cosmetic_applies(b, d) { return }
	ensure_cosmetic(b, d)
	hs.active = true
	hs.computed = true
	if p.doc != nil && !p.doc.journal.on { dom.journal_enable(p.doc, DOM_JOURNAL_MAX) }
	e := d.engine.engine
	sb := strings.builder_make(context.temp_allocator)
	for id in d.cosmetic.active {
		if write_hide_rule(&sb, e, id) {
			v := adblock.cosmetic_filter(e, id)
			sel := v.selector
			if .Remove in v.flags && !strings.contains(sel, ":remove()") { sel = strings.concatenate({sel, ":remove()"}, context.temp_allocator) }
			if ps, ok := proc_parse(sel); ok { append(&hs.procs, ps) }
		}
		hs.rules += 1
		if hs.rules >= b.cfg.max_selectors { break }
	}
	t_css := time.tick_now()
	add_sheet(p, strings.to_string(sb))
	scan_dom(b, d, hs, p)
	t_scan := time.tick_now()
	run_procedurals(b, d, hs, p)
	hs.last_mut = p.doc.mutations
	hs.last_run = now_ms()
	trace("adopted %s: %d rules, css %.1f ms, scan %.1f ms, procedural (%d) %.1f ms", d.host, hs.rules, f64(time.tick_diff(t_start, t_css)) / 1e6, f64(time.tick_diff(t_css, t_scan)) / 1e6, len(hs.procs), f64(time.tick_since(t_scan)) / 1e6)
	if d.tab != nil && d.top { d.tab.hidden = hs.rules; d.tab.version += 1 }
}

// Looks up the classes and ids of the DOM that were not seen yet and injects the generic selectors they key. `scan_dom` walks the whole
// document (the first time, and when the journal lost entries); `scan_changes` only what the journal says is new since the last pass
// (inserted subtrees, class and id attributes that changed).
Scan :: struct { b: ^Blocker, d: ^Doc, hs: ^Doc_Hooks, found: [dynamic]u32 }

@(private)
scan_element :: proc(s: ^Scan, doc: ^dom.Document, h: base.Handle) {
	n := dom.get(doc, h)
	if n == nil || n.kind != .Element { return }
	e := s.d.engine.engine
	look :: proc(s: ^Scan, e: ^adblock.Engine, prefix: u8, name: string) {
		if name == "" { return }
		key := adblock.class_key(prefix, name)
		if key in s.hs.seen { return }
		s.hs.seen[key] = {}
		adblock.cosmetic_keyed(e, &s.d.cosmetic, key, &s.found)
	}
	for a in n.attrs {
		switch a.name {
		case "class":
			v := a.value
			for len(v) > 0 {
				for len(v) > 0 && (v[0] == ' ' || v[0] == '\t' || v[0] == '\n' || v[0] == '\r' || v[0] == 0x0c) { v = v[1:] }
				end := 0
				for end < len(v) && !(v[end] == ' ' || v[end] == '\t' || v[end] == '\n' || v[end] == '\r' || v[end] == 0x0c) { end += 1 }
				look(s, e, '.', v[:end])
				v = v[end:]
			}
		case "id": look(s, e, '#', a.value)
		}
	}
}

@(private)
scan_finish :: proc(s: ^Scan, p: ^page.Page) {
	if len(s.found) == 0 { return }
	e := s.d.engine.engine
	sb := strings.builder_make(context.temp_allocator)
	for id in s.found {
		if s.hs.rules >= s.b.cfg.max_selectors { break }
		if write_hide_rule(&sb, e, id) { continue }   // (keyed filters are never procedural)
		s.hs.rules += 1
	}
	add_sheet(p, strings.to_string(sb))
}

@(private)
scan_dom :: proc(b: ^Blocker, d: ^Doc, hs: ^Doc_Hooks, p: ^page.Page) {
	if !d.has_cosmetic || p.doc == nil { return }
	doc := p.doc
	if hs.seen == nil { hs.seen = make(map[u32]struct{}) }
	s := Scan{b = b, d = d, hs = hs, found = make([dynamic]u32, context.temp_allocator)}
	for h := doc.root; h != base.NIL_HANDLE; h = dom.next_in_tree(doc, h, doc.root) { scan_element(&s, doc, h) }
	scan_finish(&s, p)
}

@(private)
scan_changes :: proc(b: ^Blocker, d: ^Doc, hs: ^Doc_Hooks, p: ^page.Page, since: u64) {
	if !d.has_cosmetic || p.doc == nil { return }
	doc := p.doc
	entries, ok := dom.journal_since(doc, since)
	if !ok { scan_dom(b, d, hs, p); return }
	if hs.seen == nil { hs.seen = make(map[u32]struct{}) }
	s := Scan{b = b, d = d, hs = hs, found = make([dynamic]u32, context.temp_allocator)}
	for &e in entries {
		switch e.kind {
		case .Insert:
			if dom.get(doc, e.node) == nil { continue }
			for h := e.node; h != base.NIL_HANDLE; h = dom.next_in_tree(doc, h, e.node) { scan_element(&s, doc, h) }
		case .Attribute:
			if e.name == "class" || e.name == "id" { scan_element(&s, doc, e.node) }
		case .Text, .Remove, .Reslot:
		}
	}
	scan_finish(&s, p)
}
@(private)
run_procedurals :: proc(b: ^Blocker, d: ^Doc, hs: ^Doc_Hooks, p: ^page.Page) {
	if len(hs.procs) == 0 || p.engine == nil { return }
	now := make(map[base.Handle]struct{}, 16, context.temp_allocator)
	styles := strings.builder_make(context.temp_allocator)
	for ps in hs.procs {
		found := proc_eval(p, ps)
		for h in found {
			switch {
			case ps.remove: now[h] = {}   // removed below
			case ps.style != "":
				// an element-specific style cannot be a selector: it is applied as an inline style would be (not supported by
				// the forced-hide path), so the rule hides nothing here
			case: now[h] = {}
			}
		}
		if ps.remove { for h in found { remove_element(p, h) } }
	}
	_ = styles
	for h in now { if h not_in hs.hidden { style.engine_set_hidden(p.engine, h, true); hs.hidden[h] = {} } }
	for h in hs.hidden { if h not_in now { style.engine_set_hidden(p.engine, h, false); delete_key(&hs.hidden, h) } }
}

@(private)
remove_element :: proc(p: ^page.Page, h: base.Handle) {
	n := dom.get(p.doc, h)
	if n == nil || n.parent == base.NIL_HANDLE { return }
	dom.remove_child(p.doc, n.parent, h)
}

@(private)
hook_before_styles :: proc(user: rawptr, p: ^page.Page) {
	b := (^Blocker)(user)
	if p.doc == nil { return }
	d := doc_of_page(b, p)
	if d == nil || d.hooks == nil { return }
	hs := (^Doc_Hooks)(d.hooks)
	if hs.ops.started { ops_run(b, hs, p) }
	if !hs.active || p.doc.mutations == hs.last_mut { return }
	wait := i64(b.cfg.debounce_ms) - (now_ms() - hs.last_run)
	if wait > 0 {
		// too soon: come back when the debounce is over (the DOM change itself may be the last thing that happens)
		if hs.poke == base.NIL_HANDLE {
			if hs.timer_data == nil { hs.timer_data = new(Poke) }
			hs.timer_data.hs = hs
			hs.poke = host.set_timer(p.loop, f64(wait), 0, poke_page, hs.timer_data)
		}
		return
	}
	since := hs.last_mut
	hs.last_mut = p.doc.mutations
	hs.last_run = now_ms()
	t0 := time.tick_now()
	scan_changes(b, d, hs, p, since)
	t1 := time.tick_now()
	run_procedurals(b, d, hs, p)
	if ms := f64(time.tick_since(t0)) / 1e6; ms > 3 { trace("pass on %s: %.1f ms (scan %.1f, procedural %d: %.1f)", d.host, ms, f64(time.tick_diff(t0, t1)) / 1e6, len(hs.procs), f64(time.tick_since(t1)) / 1e6) }
	if d.tab != nil && d.top { d.tab.hidden = hs.rules + len(hs.hidden); d.tab.version += 1 }
}

@(private)
poke_page :: proc(data: rawptr) {
	k := (^Poke)(data)
	hs := k.hs
	hs.poke = base.NIL_HANDLE
	// the page restyles: the document's mutation count moves, so the next style computation runs the pass
	if hs.page != nil && hs.page.doc != nil && !hs.page.closed { hs.page.doc.mutations += 1 }
}

////////////////////////////////
// Scriptlets

@(private)
split_args :: proc(text: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	cur := strings.builder_make(context.temp_allocator)
	i := 0
	quote: u8 = 0
	for i < len(text) {
		c := text[i]
		switch {
		case c == '\\' && i + 1 < len(text) && (text[i + 1] == ',' || text[i + 1] == '"' || text[i + 1] == '\\'):
			strings.write_byte(&cur, text[i + 1]); i += 2; continue
		case quote != 0:
			if c == quote { quote = 0 } else { strings.write_byte(&cur, c) }
		case (c == '"' || c == '\'') && len(strings.trim_space(strings.to_string(cur))) == 0:
			strings.builder_reset(&cur)
			quote = c
		case c == ',':
			append(&out, strings.clone(strings.trim_space(strings.to_string(cur)), context.temp_allocator))
			strings.builder_reset(&cur)
		case:
			strings.write_byte(&cur, c)
		}
		i += 1
	}
	append(&out, strings.clone(strings.trim_space(strings.to_string(cur)), context.temp_allocator))
	return out[:]
}

@(private)
hook_before_script :: proc(user: rawptr, p: ^page.Page, script: base.Handle) {
	b := (^Blocker)(user)
	d := doc_of_page(b, p)
	if d == nil || d.hooks == nil { return }
	hs := (^Doc_Hooks)(d.hooks)
	if hs.ops.started { ops_before_script(b, hs, p, script) }
}

@(private)
hook_parsed :: proc(user: rawptr, p: ^page.Page) {
	b := (^Blocker)(user)
	d := doc_of_page(b, p)
	if d == nil || d.hooks == nil { return }
	hs := (^Doc_Hooks)(d.hooks)
	if hs.ops.started { ops_parsed(b, hs, p) }
}

// Sorts the scriptlets of the document by route (scriptlet_route.odin): the ones that change the DOM become operations of dom_ops.odin
// and start now; the rest waits for the realm (hook_realm_started).
@(private)
prepare_scriptlets :: proc(b: ^Blocker, d: ^Doc, hs: ^Doc_Hooks, p: ^page.Page) {
	hs.prepared = true
	hs.owner = d
	if !b.cfg.enabled || !b.cfg.scriptlets || d.unfiltered || .No_Scriptlets in d.site || b.engine == nil { return }
	ensure_cosmetic(b, d)
	if d.cosmetic.no_scriptlets { return }
	e := d.engine.engine
	for id in d.cosmetic.active {
		v := adblock.cosmetic_filter(e, id)
		switch {
		case .Scriptlet in v.flags:
			args := split_args(v.selector)
			if len(args) == 0 || args[0] == "" { continue }
			canon := scriptlet_canonical(args[0])
			if scriptlet_route(canon) == .Dom {
				if op, ok := ops_make(canon, args); ok { append(&hs.ops.ops, op) }
				continue
			}
			keep := make([]string, len(args))
			for a, i in args { keep[i] = strings.clone(a) }
			append(&hs.rest, keep)
		case .Js_Raw in v.flags:
			append(&hs.raw, strings.clone(v.selector))
		}
	}
	hs.ops.cursor = 0
	ops_start(b, hs, p)
}

@(private)
hook_realm_started :: proc(user: rawptr, p: ^page.Page) {
	b := (^Blocker)(user)
	d := doc_of_page(b, p)
	if d == nil { return }
	doc_refresh(b, d)
	hs := hooks_of(d)
	if !hs.prepared { hs.page = p; prepare_scriptlets(b, d, hs, p) }
	if len(hs.rest) == 0 && len(hs.raw) == 0 { return }
	// the scriptlets that change an API go to the engine as native hooks; what is left, and everything when the hooks are off, is JavaScript
	js_rules := make([dynamic][]string, context.temp_allocator)
	spec := strings.builder_make(context.temp_allocator)
	hooks := 0
	for r in hs.rest {
		canon := scriptlet_canonical(r[0])
		if b.cfg.native_hooks && scriptlet_route(canon) == .Hook {
			if hooks > 0 { strings.write_byte(&spec, 0x1e) }
			strings.write_string(&spec, canon)
			for a in r[1:] { strings.write_byte(&spec, 0x1f); strings.write_string(&spec, a) }
			hooks += 1
		} else {
			js := make([]string, len(r), context.temp_allocator)
			copy(js, r)
			js[0] = canon
			append(&js_rules, js)
		}
	}
	if hooks > 0 { page.js_hooks(p, transmute([]byte)strings.to_string(spec)) }
	sb := strings.builder_make(context.temp_allocator)
	if len(js_rules) > 0 {
		strings.write_string(&sb, "(function(rules){\n")
		strings.write_string(&sb, SCRIPTLETS_JS)
		strings.write_string(&sb, "\n})(")
		json_rules(&sb, js_rules[:])
		strings.write_string(&sb, ");\n")
	}
	if strings.builder_len(sb) == 0 { return }
	for r in hs.raw {
		strings.write_string(&sb, "try{")
		strings.write_string(&sb, r)
		strings.write_string(&sb, "\n}catch(e){}\n")
	}
	source := strings.to_string(sb)
	page.js_run(p, transmute([]byte)source, "wren-blocker:scriptlets")
}
@(private)
json_rules :: proc(sb: ^strings.Builder, rules: [][]string) {
	strings.write_byte(sb, '[')
	for r, i in rules {
		if i > 0 { strings.write_byte(sb, ',') }
		strings.write_byte(sb, '[')
		for a, j in r {
			if j > 0 { strings.write_byte(sb, ',') }
			// JSON string (the JSON encoder escapes quotes, control characters and U+2028)
			data, err := json.marshal(a, {}, context.temp_allocator)
			if err == nil { strings.write_string(sb, string(data)) } else { strings.write_string(sb, "\"\"") }
		}
		strings.write_byte(sb, ']')
	}
	strings.write_byte(sb, ']')
}

_ :: fmt

// WREN_BLOCKER_TRACE=<file>: what the page hooks cost, one line per pass (for measuring).
@(private)
trace :: proc(format: string, args: ..any) {
	path := os.get_env("WREN_BLOCKER_TRACE", context.temp_allocator)
	if path == "" { return }
	if f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
		os.write_string(f, fmt.tprintf(format, ..args))
		os.write_string(f, "\n")
		os.close(f)
	}
}
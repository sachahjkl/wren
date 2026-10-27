package browser

// The pane at the side of the Elements tree: Styles (the rules that apply to the chosen element, strongest first, each
// with its selector, where it is written, and its declarations: a box switches one off, a click on a name or a value edits it
// and the page follows as you type, a click under the last one adds one; what an element inherits is listed under it, what
// is overridden is struck through), Computed (every resolved property), Layout (the box model as nested rectangles), Event
// Listeners and Accessibility (role, name, state).
//
// The rules are the engine's (page.dev_matched_rules). Edits replace a rule's declarations in its sheet, or write the
// style attribute, and the page restyles at its next frame. A declaration switched off is not in the engine: the pane keeps its
// own copy of each edited rule's declarations (`shadow`) and shows it until the rule changes underneath.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:dom"
import "wb:page"
import "wb:style"

ELEMENTS_PREFS := [?]config.Def{
	{name = "browser.devtools.elements.split", kind = .Float, default = {f = 0.55}, bounded = true, min = 0.2, max = 0.8,
		description = "The share of the Elements tab's width (or height) the tree keeps; the rest is the Styles pane."},
	{name = "browser.devtools.elements.side_tab", kind = .String, default = {s = "styles"}, choices = {"styles", "computed", "layout", "listeners", "accessibility"},
		description = "The view at the side of the Elements tree that is shown."},
	{name = "browser.devtools.elements.show_ua", kind = .Bool, default = {b = false},
		description = "List the browser's own style rules in the Styles pane."},
	{name = "browser.devtools.elements.computed_all", kind = .Bool, default = {b = false},
		description = "The Computed view lists the properties that have their initial value too."},
}

elements_register_prefs :: proc(p: ^config.Prefs) { config.register(p, ELEMENTS_PREFS[:]) }

Sty_Kind :: enum u8 { Inline, Rule, Section }

Sty_Decl :: struct {
	name, value: string,        // owned
	important:   bool,
	enabled:     bool,
	overridden:  bool,
}

Sty_Block :: struct {
	kind:     Sty_Kind,
	rule:     ^css.Rule,
	sheet:    ^style.Sheet,
	selector: string,           // owned (a Section: its title)
	source:   string,           // owned: "dt.css:12"
	url:      string,           // owned: where the sheet came from
	media:    string,           // owned
	inherited: bool,
	decls:    [dynamic]Sty_Decl,
	key:      uintptr,
}

Dev_Styles :: struct {
	tab:       int,
	list:      Dt_List,
	filter:    Dt_Filter,
	blocks:    [dynamic]Sty_Block,
	shadow:    map[uintptr][dynamic]Sty_Decl,
	rev:       u64,                // bumped by an edit
	key_h:     base.Handle,
	key_page:  rawptr,
	key_mut:   u64,
	key_rev:   u64,
	key_pass:  u64,
	key_fs:    f32,
	// editing: block, declaration, which part (0 name, 1 value)
	edit_b, edit_d, edit_part: int,
	editing:   bool,
	focus_set: bool,
	field_n, field_v: ui.Text_Field,
	field_age: int,
	computed:  [dynamic][2]string,
	listeners: [dynamic]Lst_Item,
	ancestors: bool,
	off_classes: [dynamic]string,
	box:       [12]f32,            // margin, border, padding (t r b l each), content w h in `size`
	size:      [2]f32,
	acc:       [dynamic][2]string,
	menu_text: string,
}

Lst_Item :: struct { type: string, flags: string, node: string, id: u32 }

styles_destroy :: proc(s: ^Dev_Styles) {
	styles_reset(s)
	dt_list_destroy(&s.list)
	dt_filter_destroy(&s.filter)
	ui.field_destroy(&s.field_n)
	ui.field_destroy(&s.field_v)
	delete(s.blocks)
	for _, v in s.shadow { free_decls(v[:]); delete(v) }
	delete(s.shadow)
	delete(s.computed)
	delete(s.listeners)
	for c in s.off_classes { delete(c) }
	delete(s.off_classes)
	delete(s.acc)
	delete(s.menu_text)
}

@(private = "file")
free_decls :: proc(ds: []Sty_Decl) { for d in ds { delete(d.name); delete(d.value) } }

@(private = "file")
free_blocks :: proc(s: ^Dev_Styles) {
	for &b in s.blocks { delete(b.selector); delete(b.source); delete(b.url); delete(b.media); free_decls(b.decls[:]); delete(b.decls) }
	clear(&s.blocks)
}

styles_reset :: proc(s: ^Dev_Styles) {
	free_blocks(s)
	for k, v in s.shadow { free_decls(v[:]); delete(v); delete_key(&s.shadow, k) }
	for c in s.computed { _ = c }
	clear(&s.computed)
	clear(&s.listeners)
	s.key_h, s.key_page, s.editing = base.NIL_HANDLE, nil, false
}

@(private = "file")
dup :: proc(s: string) -> string { return strings.clone(s) }

////////////////////////////////
// Building the blocks

@(private = "file")
block_from_decls :: proc(s: ^Dev_Styles, key: uintptr, engine: []style.Dev_Decl) -> [dynamic]Sty_Decl {
	// the pane's own copy, while it is what the engine has (its enabled declarations are the engine's)
	if full, ok := s.shadow[key]; ok {
		n := 0
		same := true
		for d in full {
			if !d.enabled || d.name == "" || d.value == "" { continue }
			if n >= len(engine) || engine[n].name != strings.to_lower(d.name, context.temp_allocator) && engine[n].name != d.name { same = false; break }
			n += 1
		}
		if same && n == len(engine) {
			out := make([dynamic]Sty_Decl, 0, len(full))
			for d in full { append(&out, Sty_Decl{name = dup(d.name), value = dup(d.value), important = d.important, enabled = d.enabled}) }
			return out
		}
		free_decls(full[:]); delete(full); delete_key(&s.shadow, key)
	}
	out := make([dynamic]Sty_Decl, 0, len(engine))
	for d in engine { append(&out, Sty_Decl{name = dup(d.name), value = dup(d.value), important = d.important, enabled = true}) }
	return out
}

@(private = "file")
keep_shadow :: proc(s: ^Dev_Styles, key: uintptr, decls: []Sty_Decl) {
	if old, ok := s.shadow[key]; ok { free_decls(old[:]); delete(old) }
	out := make([dynamic]Sty_Decl, 0, len(decls))
	for d in decls { append(&out, Sty_Decl{name = dup(d.name), value = dup(d.value), important = d.important, enabled = d.enabled}) }
	s.shadow[key] = out
}

styles_refresh :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	p := t.page
	if p == nil || p.closed || e.selected == base.NIL_HANDLE {
		free_blocks(s)
		clear(&s.computed); clear(&s.listeners)
		s.key_h = base.NIL_HANDLE
		return
	}
	pass := p.engine != nil ? p.engine.rebuilds : 0
	if s.key_h == e.selected && s.key_page == rawptr(p) && s.key_mut == p.doc.mutations && s.key_rev == s.rev && s.key_pass == pass && s.key_fs == dtm.row { return }
	s.key_h, s.key_page, s.key_mut, s.key_rev, s.key_pass, s.key_fs = e.selected, rawptr(p), p.doc.mutations, s.rev, pass, dtm.row
	elements_crumbs_for(p, e)
	n := dom.get(p.doc, e.selected)
	if n == nil || n.kind != .Element {
		free_blocks(s)
		clear(&s.computed); clear(&s.listeners)
		return
	}
	free_blocks(s)
	show_ua := config.bool_of(&app.prefs, "browser.devtools.elements.show_ua")
	// element.style
	inl := page.dev_inline_decls(p, e.selected)
	ikey := uintptr(e.selected) | (1 << 62)
	blk := Sty_Block{kind = .Inline, selector = dup("element.style"), key = ikey}
	blk.decls = block_from_decls(s, ikey, inl)
	append(&s.blocks, blk)
	// the rules
	for r in page.dev_matched_rules(p, e.selected, show_ua) {
		key := uintptr(rawptr(r.rule))
		b := Sty_Block{kind = .Rule, rule = r.rule, sheet = r.sheet, selector = dup(r.selector), media = dup(r.media), key = key}
		src := r.url
		if r.origin == .UA { src = "user agent stylesheet" } else if src == "" { src = "<style>" } else { src = net_name_of(src) }
		b.source = r.origin == .UA ? dup(src) : dup(fmt.tprintf("%s:%d", src, r.line))
		b.url = dup(r.url)
		b.decls = block_from_decls(s, key, r.decls)
		append(&s.blocks, b)
	}
	// what it inherits
	cur := n.parent
	depth := 0
	for cur != base.NIL_HANDLE && depth < 20 {
		cn := dom.get(p.doc, cur)
		if cn == nil || cn.kind != .Element { break }
		rules := page.dev_matched_rules(p, cur, false)
		ainl := page.dev_inline_decls(p, cur)
		section_added := false
		add_section :: proc(s: ^Dev_Styles, p: ^page.Page, h: base.Handle) {
			label := css_label_for(p, h)
			append(&s.blocks, Sty_Block{kind = .Section, selector = dup(fmt.tprintf("Inherited from %s", label)), inherited = true})
		}
		inh_inline := make([dynamic]style.Dev_Decl, context.temp_allocator)
		for d in ainl { if style.dev_inherited_property(d.name) { append(&inh_inline, d) } }
		if len(inh_inline) > 0 {
			if !section_added { add_section(s, p, cur); section_added = true }
			b := Sty_Block{kind = .Inline, selector = dup("element.style"), inherited = true, key = uintptr(cur) | (1 << 61)}
			for d in inh_inline { append(&b.decls, Sty_Decl{name = dup(d.name), value = dup(d.value), important = d.important, enabled = true}) }
			append(&s.blocks, b)
		}
		for r in rules {
			inh := make([dynamic]style.Dev_Decl, context.temp_allocator)
			for d in r.decls { if style.dev_inherited_property(d.name) { append(&inh, d) } }
			if len(inh) == 0 { continue }
			if !section_added { add_section(s, p, cur); section_added = true }
			src := r.url == "" ? "<style>" : net_name_of(r.url)
			b := Sty_Block{kind = .Rule, rule = r.rule, sheet = r.sheet, selector = dup(r.selector), media = dup(r.media), inherited = true, key = uintptr(rawptr(r.rule)) | (1 << 60)}
			b.source = dup(fmt.tprintf("%s:%d", src, r.line))
			for d in inh { append(&b.decls, Sty_Decl{name = dup(d.name), value = dup(d.value), important = d.important, enabled = true}) }
			append(&s.blocks, b)
		}
		cur = cn.parent
		depth += 1
	}
	mark_overrides(s)
	// the other views
	computed_make(p, e, s)
	listeners_make(p, e, s)
	accessibility_make(p, e, s)
	box_make(p, t, e, s)
}

// A declaration of an inherited or weaker rule is struck when another of the element's own wins: important ones first, then
// the first of each name in the order of the blocks (the strongest comes first).
@(private = "file")
mark_overrides :: proc(s: ^Dev_Styles) {
	won := make(map[string]bool, 32, context.temp_allocator)
	won_imp := make(map[string]bool, 32, context.temp_allocator)
	for &b in s.blocks {
		if b.kind == .Section || b.inherited { continue }
		for &d in b.decls { if d.enabled && d.important && d.name != "" && !won_imp[d.name] { won_imp[d.name] = true; won[d.name] = true } else if d.enabled && d.important { d.overridden = true } }
	}
	seen := make(map[string]bool, 32, context.temp_allocator)
	for &b in s.blocks {
		if b.kind == .Section { continue }
		for &d in b.decls {
			if !d.enabled || d.name == "" { continue }
			if b.inherited {
				d.overridden = won[d.name] || seen[d.name] || d.overridden
				continue
			}
			if d.important { seen[d.name] = true; continue }
			if won_imp[d.name] || seen[d.name] { d.overridden = true } else { seen[d.name] = true; won[d.name] = true }
		}
	}
}

@(private = "file")
css_label_for :: proc(p: ^page.Page, h: base.Handle) -> string {
	n := dom.get(p.doc, h)
	if n == nil { return "" }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, n.name)
	if id, ok := dom.get_attribute(p.doc, h, "id"); ok && id != "" { fmt.sbprintf(&b, "#%s", dev_line(id, 30)) }
	if cls, ok := dom.get_attribute(p.doc, h, "class"); ok { for c in strings.fields(cls, context.temp_allocator) { fmt.sbprintf(&b, ".%s", dev_line(c, 24)) } }
	return strings.to_string(b)
}

////////////////////////////////
// Applying an edit

// Writes block `bi` back: the enabled declarations to the sheet's rule, or the style attribute.
@(private = "file")
apply_block :: proc(app: ^App, t: ^Tab, s: ^Dev_Styles, bi: int) {
	if t.page == nil || bi < 0 || bi >= len(s.blocks) { return }
	b := &s.blocks[bi]
	if b.inherited { return }
	keep_shadow(s, b.key, b.decls[:])
	switch b.kind {
	case .Inline:
		sb := strings.builder_make(context.temp_allocator)
		for d in b.decls {
			if !d.enabled || d.name == "" || d.value == "" { continue }
			fmt.sbprintf(&sb, "%s: %s%s; ", d.name, d.value, d.important ? " !important" : "")
		}
		page.dev_set_style_attribute(t.page, dev().els.selected, strings.trim_space(strings.to_string(sb)))
	case .Rule:
		ds := make([dynamic]style.Dev_Decl, context.temp_allocator)
		for d in b.decls {
			if !d.enabled || d.name == "" || d.value == "" { continue }
			append(&ds, style.Dev_Decl{name = d.name, value = d.value, important = d.important})
		}
		page.dev_set_rule_decls(t.page, b.sheet, b.rule, ds[:])
	case .Section:
	}
	s.key_mut = 0   // the page changed: the next frame builds the blocks again (what the editor holds stays)
	request_frames(app, 3)
}

////////////////////////////////
// The Styles list

Sty_Row_Kind :: enum u8 { Section, Head, Decl, Close, Media }

@(private = "file")
Sty_Row :: struct { kind: Sty_Row_Kind, b, d: int }

@(private = "file")
Sty_Draw :: struct {
	row:      Sty_Row,
	block:    ^Sty_Block,
	decl:     ^Sty_Decl,
	hot, editing: bool,
	filter:   string,
	hit:      bool,
	swatch:   draw.Color,
	has_swatch: bool,
	first_of_block: bool,
	hot_part: int,
	name_w:   f32,
}

@(private = "file")
sty_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Sty_Draw)(user)
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	left := r.min.x + dt_px(10)
	switch d.row.kind {
	case .Section:
		draw.rect(dc, r, dtc.bar)
		draw.rect(dc, {{r.min.x, r.max.y - dtm.line}, {r.max.x, r.max.y}}, dtc.border_soft)
		dt_text(dc, dtm.ui_font, dtm.fs, left, cy, dtc.weak, d.block.selector)
	case .Media:
		dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, left, cy, dtc.weak, d.block.media)
	case .Head:
		if d.hot { draw.rect(dc, r, dtc.hover) }
		if d.first_of_block { draw.rect(dc, {{r.min.x, r.min.y}, {r.max.x, r.min.y + dtm.line}}, dtc.border_soft) }
		src_w := dt_w(dtm.ui_font, dtm.fs * 0.92, d.block.source)
		sel_col := d.block.inherited ? dtc.weak : dtc.text
		runs := style_selector_runs(d.block.selector, d.block.kind == .Inline)
		end := dt_runs(dc, dtm.mono, dtm.mono_fs, left, cy, runs, r.max.x - src_w - dt_px(24))
		dt_text(dc, dtm.mono, dtm.mono_fs, end + dt_px(4), cy, sel_col, "{")
		dt_text_r(dc, dtm.ui_font, dtm.fs * 0.92, r.max.x - dt_px(8), cy, with_alpha(dtc.accent, 0.85), d.block.source)
	case .Decl:
		if d.hot && !d.editing { draw.rect(dc, r, dtc.hover) }
		x := left + dt_px(8)
		// the switch
		if d.decl.enabled || d.hot || d.editing {
			cs := dt_px(11)
			box := draw.Rect{{x, cy - cs * 0.5}, {x + cs, cy + cs * 0.5}}
			draw.rect(dc, box, d.decl.enabled ? dtc.accent : dtc.input, dt_px(2))
			draw.rect(dc, box, d.decl.enabled ? dtc.accent : dtc.faint, dt_px(2), dtm.line)
			if d.decl.enabled { dt_icon(dc, .Check, draw.rect_center(box), cs * 0.9, dtc.accent_text, dtm.sc) }
		}
		x += dt_px(16)
		if d.editing { return }
		struck := d.decl.overridden || !d.decl.enabled
		namecol := d.decl.enabled ? (d.block.inherited ? dtc.weak : syn_color(.Prop)) : dtc.faint
		valcol := d.decl.enabled ? dtc.text : dtc.faint
		nw := dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, namecol, d.decl.name)
		cw := dt_text(dc, dtm.mono, dtm.mono_fs, x + nw, cy, dtc.weak, ": ")
		vx := x + nw + cw
		if d.has_swatch {
			sw := dtm.mono_fs * 0.85
			sr := draw.Rect{{vx, cy - sw * 0.5}, {vx + sw, cy + sw * 0.5}}
			draw.rect(dc, sr, draw.Color{0.9, 0.9, 0.9, 1}, 2)
			draw.rect(dc, sr, d.swatch, 2)
			draw.rect(dc, sr, with_alpha(dtc.text, 0.4), 2, dtm.line)
			vx += sw + dt_px(5)
		}
		val := d.decl.value
		if d.decl.important { val = fmt.tprintf("%s !important", val) }
		vruns := css_value_runs(val, valcol, d.decl.enabled)
		ve := dt_runs(dc, dtm.mono, dtm.mono_fs, vx, cy, vruns, r.max.x - dt_px(14))
		dt_text(dc, dtm.mono, dtm.mono_fs, ve, cy, dtc.weak, ";")
		if struck {
			y := math.round(cy)
			draw.rect(dc, {{x, y}, {ve, y + dtm.line}}, with_alpha(dtc.text, 0.55))
		}
	case .Close:
		if d.hot { draw.rect(dc, r, with_alpha(dtc.hover, 0.5)) }
		dt_text(dc, dtm.mono, dtm.mono_fs, left, cy, dtc.text, "}")
		if d.hot && !d.block.inherited { dt_icon(dc, .Plus, {r.max.x - dt_px(14), cy}, dtm.icon * 0.8, dtc.weak, dtm.sc) }
	}
}

@(private = "file")
style_selector_runs :: proc(sel: string, inline: bool) -> []Dt_Run {
	out := make([dynamic]Dt_Run, 0, 12, context.temp_allocator)
	if inline { append(&out, Dt_Run{sel, dtc.text}); return out[:] }
	// classes, ids, tags colored; combinators and pseudo-classes plain
	i := 0
	for i < len(sel) {
		c := sel[i]
		j := i + 1
		switch {
		case c == '.' || c == '#':
			for j < len(sel) && (sel[j] == '-' || sel[j] == '_' || (sel[j] >= '0' && sel[j] <= '9') || (sel[j] >= 'a' && sel[j] <= 'z') || (sel[j] >= 'A' && sel[j] <= 'Z')) { j += 1 }
			append(&out, Dt_Run{sel[i:j], c == '.' ? syn_color(.Name) : syn_color(.Attr)})
		case c == ':':
			for j < len(sel) && (sel[j] == ':' || sel[j] == '-' || (sel[j] >= 'a' && sel[j] <= 'z') || (sel[j] >= '0' && sel[j] <= '9')) { j += 1 }
			append(&out, Dt_Run{sel[i:j], syn_color(.Keyword)})
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '*':
			for j < len(sel) && (sel[j] == '-' || (sel[j] >= 'a' && sel[j] <= 'z') || (sel[j] >= 'A' && sel[j] <= 'Z') || (sel[j] >= '0' && sel[j] <= '9')) { j += 1 }
			append(&out, Dt_Run{sel[i:j], syn_color(.Tag)})
		case:
			append(&out, Dt_Run{sel[i:j], dtc.weak})
		}
		i = j
	}
	return out[:]
}

// A value in colors: numbers and units, colors, strings, functions, keywords.
@(private = "file")
css_value_runs :: proc(v: string, base_col: draw.Color, enabled: bool) -> []Dt_Run {
	out := make([dynamic]Dt_Run, 0, 8, context.temp_allocator)
	if !enabled { append(&out, Dt_Run{v, base_col}); return out[:] }
	i := 0
	for i < len(v) {
		c := v[i]
		j := i + 1
		switch {
		case c == '"' || c == '\'':
			for j < len(v) && v[j] != c { j += 1 }
			j = min(j + 1, len(v))
			append(&out, Dt_Run{v[i:j], syn_color(.String)})
		case c == '#':
			for j < len(v) && ((v[j] >= '0' && v[j] <= '9') || (v[j] >= 'a' && v[j] <= 'f') || (v[j] >= 'A' && v[j] <= 'F')) { j += 1 }
			append(&out, Dt_Run{v[i:j], syn_color(.Number)})
		case (c >= '0' && c <= '9') || (c == '.' && i + 1 < len(v) && v[i + 1] >= '0' && v[i + 1] <= '9') || (c == '-' && i + 1 < len(v) && v[i + 1] >= '0' && v[i + 1] <= '9'):
			for j < len(v) && ((v[j] >= '0' && v[j] <= '9') || v[j] == '.' || v[j] == '%' || (v[j] >= 'a' && v[j] <= 'z')) { j += 1 }
			append(&out, Dt_Run{v[i:j], syn_color(.Number)})
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_':
			for j < len(v) && (v[j] == '-' || v[j] == '_' || (v[j] >= 'a' && v[j] <= 'z') || (v[j] >= 'A' && v[j] <= 'Z') || (v[j] >= '0' && v[j] <= '9')) { j += 1 }
			col := base_col
			if j < len(v) && v[j] == '(' { col = syn_color(.Func) }
			append(&out, Dt_Run{v[i:j], col})
		case:
			append(&out, Dt_Run{v[i:j], dtc.weak})
		}
		i = j
	}
	return out[:]
}

// The color a value stands for, when it is plain (#rgb, #rrggbb, rgb(), a few names): for the swatch beside it.
swatch_of :: proc(v: string) -> (draw.Color, bool) {
	s := strings.trim_space(v)
	hexv :: proc(c: u8) -> (int, bool) {
		switch { case c >= '0' && c <= '9': return int(c - '0'), true; case c >= 'a' && c <= 'f': return int(c - 'a') + 10, true; case c >= 'A' && c <= 'F': return int(c - 'A') + 10, true }
		return 0, false
	}
	if len(s) > 0 && s[0] == '#' && (len(s) == 4 || len(s) == 7 || len(s) == 9) {
		vals: [8]int
		n := len(s) - 1
		for i in 0 ..< n { v, ok := hexv(s[1 + i]); if !ok { return {}, false }; vals[i] = v }
		if n == 3 { return draw.srgb(f32(vals[0] * 17) / 255, f32(vals[1] * 17) / 255, f32(vals[2] * 17) / 255), true }
		a: f32 = 1
		if n == 8 { a = f32(vals[6] * 16 + vals[7]) / 255 }
		return draw.srgb(f32(vals[0] * 16 + vals[1]) / 255, f32(vals[2] * 16 + vals[3]) / 255, f32(vals[4] * 16 + vals[5]) / 255, a), true
	}
	if strings.has_prefix(s, "rgb") {
		open := strings.index_byte(s, '(')
		close := strings.index_byte(s, ')')
		if open < 0 || close < open { return {}, false }
		inner, _ := strings.replace_all(s[open + 1:close], ",", " ", context.temp_allocator)
		inner, _ = strings.replace_all(inner, "/", " ", context.temp_allocator)
		parts := strings.split(strings.trim_space(inner), " ", context.temp_allocator)
		nums := make([dynamic]f32, context.temp_allocator)
		for p in parts { if p == "" { continue }; f, _ := parse_f32(strings.trim_suffix(p, "%")); append(&nums, strings.has_suffix(p, "%") ? f * 2.55 : f) }
		if len(nums) >= 3 { return draw.srgb(nums[0] / 255, nums[1] / 255, nums[2] / 255, len(nums) > 3 ? (nums[3] > 1 ? nums[3] / 255 : nums[3]) : 1), true }
	}
	switch s {
	case "red": return draw.srgb(1, 0, 0), true
	case "green": return draw.srgb(0, 0.5, 0), true
	case "blue": return draw.srgb(0, 0, 1), true
	case "black": return draw.srgb(0, 0, 0), true
	case "white": return draw.srgb(1, 1, 1), true
	case "orange": return draw.srgb(1, 0.65, 0), true
	case "yellow": return draw.srgb(1, 1, 0), true
	case "gray", "grey": return draw.srgb(0.5, 0.5, 0.5), true
	case "crimson": return draw.srgb(0.86, 0.08, 0.24), true
	}
	return {}, false
}

@(private = "file")
parse_f32 :: proc(s: string) -> (f32, bool) {
	f, div := f32(0), f32(0)
	neg := false
	for c, i in transmute([]u8)s {
		if i == 0 && c == '-' { neg = true; continue }
		if c == '.' { div = 1; continue }
		if c < '0' || c > '9' { return 0, false }
		if div > 0 { div *= 10; f += f32(c - '0') / div } else { f = f * 10 + f32(c - '0') }
	}
	return neg ? -f : f, true
}

@(private = "file")
styles_view :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	rows := make([dynamic]Sty_Row, 0, 64, context.temp_allocator)
	q := dt_filter_text(&s.filter)
	dt_filter_prepare(&s.filter)
	for &b, bi in s.blocks {
		if b.kind == .Section { append(&rows, Sty_Row{.Section, bi, 0}); continue }
		// with a filter, only the blocks with a matching declaration, and those declarations
		any := q == ""
		if !any { for d in b.decls { if dt_filter_match(&s.filter, d.name) || dt_filter_match(&s.filter, d.value) { any = true; break } } }
		if !any { continue }
		if b.media != "" { append(&rows, Sty_Row{.Media, bi, 0}) }
		append(&rows, Sty_Row{.Head, bi, 0})
		for d, di in b.decls {
			if q != "" && !dt_filter_match(&s.filter, d.name) && !dt_filter_match(&s.filter, d.value) { continue }
			append(&rows, Sty_Row{.Decl, bi, di})
		}
		append(&rows, Sty_Row{.Close, bi, 0})
	}
	if len(rows) == 0 {
		dt_empty("###dt_sty_none", .Style, e.selected == base.NIL_HANDLE ? "Select an element" : "No style rules match", e.selected == base.NIL_HANDLE ? "Choose a node in the tree to see its styles." : "Nothing styles this node yet: click + above to add a declaration to it.")
		return
	}
	menu_key := ui.key_from_string(0, "###dt_sty_menu")
	if lst, ok := dt_list("###dt_sty_list", &s.list, len(rows), dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in lst.first ..< lst.last {
			r := rows[k]
			blk := &s.blocks[r.b]
			d := ui.frame_new(Sty_Draw)
			d.row, d.block = r, blk
			if r.kind == .Decl { d.decl = &blk.decls[r.d] }
			d.first_of_block = r.kind == .Head && k > 0
			editing_here := s.editing && r.kind == .Decl && s.edit_b == r.b && s.edit_d == r.d
			d.editing = editing_here
			if r.kind == .Decl {
				if c, sok := swatch_of(blk.decls[r.d].value); sok { d.swatch, d.has_swatch = c, true }
			}
			if editing_here { decl_editor(app, t, e, s, r.b, r.d); continue }
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###sr%d_%d_%d", r.b, r.d, int(r.kind)))
			sig := ui.signal(rb)
			d.hot = sig.hovering
			rb.custom, rb.custom_user = sty_paint, d
			styles_row_input(app, t, e, s, r, blk, sig, menu_key)
		}
	}
	if ui.ctx_menu(menu_key, dt_px(220)) {
		if ui.menu_item("Copy declaration###dt_sm_decl").clicked { clip_set(s.menu_text) }
		if ui.menu_item("Copy all declarations###dt_sm_all").clicked { clip_set(styles_all_text(s, s.edit_b)) }
	}
}

@(private = "file")
styles_all_text :: proc(s: ^Dev_Styles, bi: int) -> string {
	if bi < 0 || bi >= len(s.blocks) { return "" }
	b := &s.blocks[bi]
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s {\n", b.selector)
	for d in b.decls { fmt.sbprintf(&sb, "  %s%s: %s%s;\n", d.enabled ? "" : "/* ", d.name, d.value, d.enabled ? "" : " */") }
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

@(private = "file")
styles_row_input :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, s: ^Dev_Styles, r: Sty_Row, blk: ^Sty_Block, sig: ui.Signal, menu_key: ui.Key) {
	#partial switch r.kind {
	case .Decl:
		d := &blk.decls[r.d]
		if sig.right_clicked {
			delete(s.menu_text)
			s.menu_text = strings.clone(fmt.tprintf("%s: %s;", d.name, d.value))
			s.edit_b = r.b
			ui.ctx_menu_open(menu_key, ui.mouse_pos())
		}
		if sig.clicked && !blk.inherited {
			x := sig.mouse.x - dt_px(18)
			if x < dt_px(16) { d.enabled = !d.enabled; apply_block(app, t, s, r.b); mark_overrides(s) } else {
				nw := dt_w(dtm.mono, dtm.mono_fs, d.name) + dt_px(16)
				begin_decl_edit(s, r.b, r.d, x - dt_px(16) < nw ? 0 : 1)
			}
		}
	case .Close:
		if sig.clicked && !blk.inherited {
			append(&blk.decls, Sty_Decl{name = strings.clone(""), value = strings.clone(""), enabled = true})
			begin_decl_edit(s, r.b, len(blk.decls) - 1, 0)
		}
	case .Head:
		if sig.right_clicked { s.edit_b = r.b; delete(s.menu_text); s.menu_text = strings.clone(blk.selector); ui.ctx_menu_open(menu_key, ui.mouse_pos()) }
	}
}

@(private = "file")
begin_decl_edit :: proc(s: ^Dev_Styles, b, d, part: int) {
	blk := &s.blocks[b]
	s.editing, s.edit_b, s.edit_d, s.edit_part, s.focus_set, s.field_age = true, b, d, part, true, 0
	ui.field_set(&s.field_n, blk.decls[d].name)
	ui.field_set(&s.field_v, blk.decls[d].value)
}

// A declaration being edited: its name and value as two fields; the page follows each change.
@(private = "file")
decl_editor :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, s: ^Dev_Styles, bi, di: int) {
	blk := &s.blocks[bi]
	d := &blk.decls[di]
	ui.next({width = ui.fill(), height = ui.px(dtm.row), axis = .X, cross = .Center})
	if ui.row(.Center, {}, "###dt_sty_edit") {
		ui.spacer(ui.px(dt_px(10 + 8 + 16)))
		nw := max(dt_w(dtm.mono, dtm.mono_fs, ui.field_string(&s.field_n)) + dt_px(14), dt_px(46))
		ui.next({width = ui.px(nw), height = ui.pct(1), radius = dtm.radius, font = dtm.mono, font_size = dtm.mono_fs, text_pad = dt_px(3)})
		rn := ui.line_edit("###dt_sty_fn", &s.field_n, "property")
		ui.next({width = ui.px(dt_px(10)), height = ui.pct(1)})
		ui.custom("###dt_sty_colon", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) { dt_text(dc, dtm.mono, dtm.mono_fs, b.rect.min.x + dt_px(2), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, ":") }, nil)
		ui.next({width = ui.fill(), height = ui.pct(1), radius = dtm.radius, font = dtm.mono, font_size = dtm.mono_fs, text_pad = dt_px(3)})
		rv := ui.line_edit("###dt_sty_fv", &s.field_v, "value")
		if s.focus_set {
			if s.edit_part == 0 { if rn.box != nil { ui.set_focus(rn.box.key) } } else if rv.box != nil { ui.set_focus(rv.box.key) }
			s.focus_set = false
		}
		// a pasted "name: value;" fills both
		name := ui.field_string(&s.field_n)
		if colon := strings.index_byte(name, ':'); colon > 0 && rn.changed {
			val := strings.trim_space(strings.trim_suffix(strings.trim_space(name[colon + 1:]), ";"))
			nm := strings.trim_space(name[:colon])
			ui.field_set(&s.field_n, nm)
			ui.field_set(&s.field_v, val)
			ui.set_focus(rv.box.key)
		}
		if rn.changed || rv.changed {
			delete(d.name); delete(d.value)
			d.name, d.value = strings.clone(strings.trim_space(ui.field_string(&s.field_n))), strings.clone(strings.trim_space(strings.trim_suffix(strings.trim_space(ui.field_string(&s.field_v)), ";")))
			if strings.has_suffix(d.value, "!important") { d.important = true; d.value = strings.clone(strings.trim_space(strings.trim_suffix(d.value, "!important"))) } else { d.important = false }
			apply_block(app, t, s, bi)
		}
		// Enter / Tab: on
		if rn.focused && (ui.key_press(.Return) || ui.key_press(.Tab)) { ui.set_focus(rv.box.key) }
		if rv.committed || (rv.focused && ui.key_press(.Tab)) {
			has_name := d.name != ""
			finish_decl(s, bi, di)
			// the next declaration of the block, or a new one at its end
			if di + 1 < len(blk.decls) { begin_decl_edit(s, bi, di + 1, 0) } else if has_name {
				append(&blk.decls, Sty_Decl{name = strings.clone(""), value = strings.clone(""), enabled = true})
				begin_decl_edit(s, bi, len(blk.decls) - 1, 0)
			}
		}
		if rn.cancelled || rv.cancelled { finish_decl(s, bi, di); s.editing = false; s.key_mut = 0 }
		s.field_age += 1
		if s.field_age > 3 && !rn.focused && !rv.focused && ui.focus_key() != 0 { finish_decl(s, bi, di); s.editing = false; s.key_mut = 0 }
	}
}

@(private = "file")
finish_decl :: proc(s: ^Dev_Styles, bi, di: int) {
	blk := &s.blocks[bi]
	if di < len(blk.decls) && blk.decls[di].name == "" && blk.decls[di].value == "" {
		delete(blk.decls[di].name); delete(blk.decls[di].value)
		ordered_remove(&blk.decls, di)
	}
	s.editing = false
	s.rev += 1
}

////////////////////////////////
// The pane

SIDE_TABS := [?]string{"Styles", "Computed", "Layout", "Event Listeners", "Accessibility"}
SIDE_PREFS := [?]string{"styles", "computed", "layout", "listeners", "accessibility"}

styles_panel :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	if s.tab == 0 && config_string(app, "browser.devtools.elements.side_tab") != "styles" {
		pref := config_string(app, "browser.devtools.elements.side_tab")
		for p, i in SIDE_PREFS { if p == pref { s.tab = i } }
	}
	if dt_bar("###dt_sty_tabs", dtm.bar - dt_px(2)) {
		dt_gap(2)
		room := dev_width()
		narrow := room < dt_px(900)
		for name, i in SIDE_TABS {
			label := name
			if narrow { switch i { case 3: label = "Events"; case 4: label = "A11y" } }
			if sub_tab_btn(fmt.tprintf("###dt_stt_%d", i), label, s.tab == i).clicked {
				s.tab = i
				dev_set_pref(app, "browser.devtools.elements.side_tab", SIDE_PREFS[i])
			}
		}
	}
	switch s.tab {
	case 0:
		if dt_bar("###dt_sty_bar", dtm.bar - dt_px(4)) {
			dt_gap(3)
			dt_search("###dt_sty_filter", &s.filter, "Filter styles", 0, false)
			cls := dt_menu_btn("###dt_sty_cls", .None, ".cls", tooltip = "Toggle the classes of the element")
			if ui.ctx_menu(cls, dt_px(220)) { class_menu(app, t, e) }
			if dt_btn("###dt_sty_add", .Plus, tooltip = "New declaration for this element (element.style)", enabled = e.selected != base.NIL_HANDLE).clicked {
				if len(s.blocks) > 0 && s.blocks[0].kind == .Inline {
					append(&s.blocks[0].decls, Sty_Decl{name = strings.clone(""), value = strings.clone(""), enabled = true})
					begin_decl_edit(s, 0, len(s.blocks[0].decls) - 1, 0)
				}
			}
			ua := dt_btn("###dt_sty_ua", .Eye, tooltip = "Show the browser's own rules", on = config.bool_of(&app.prefs, "browser.devtools.elements.show_ua"))
			if ua.clicked { dev_toggle_pref(app, "browser.devtools.elements.show_ua"); s.rev += 1 }
			dt_gap(3)
		}
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {}, "###dt_sty_body") { styles_view(app, t, e) }
	case 1: computed_view(app, t, e)
	case 2: layout_view(app, t, e)
	case 3: listeners_view(app, t, e)
	case 4: accessibility_view(app, t, e)
	}
}

@(private = "file")
sub_tab_btn :: proc(id, label: string, on: bool) -> ui.Signal {
	w := dt_w(dtm.ui_font, dtm.fs, label) + dt_px(16)
	ui.next({width = ui.px(math.round(w)), height = ui.pct(1), cursor = .Arrow})
	b := ui.build_box({.Clickable, .Focusable}, id)
	sig := ui.signal(b)
	st := ui.frame_new(Dt_Chip_Draw)
	st.label, st.on, st.hot = dt_frame_str(label), on, sig.hovering
	b.custom, b.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Dt_Chip_Draw)(user)
		r := b.rect
		if d.hot && !d.on { draw.rect(dc, {{r.min.x, r.min.y + dt_px(3)}, {r.max.x, r.max.y - dt_px(3)}}, dtc.hover, dtm.radius) }
		cy := (r.min.y + r.max.y) * 0.5
		tw := dt_w(dtm.ui_font, dtm.fs, d.label)
		dt_text(dc, dtm.ui_font, dtm.fs, (r.min.x + r.max.x) * 0.5 - tw * 0.5, cy, d.on ? dtc.text : (d.hot ? dtc.text : dtc.weak), d.label)
		if d.on { draw.rect(dc, {{r.min.x + dt_px(3), r.max.y - dt_px(2)}, {r.max.x - dt_px(3), r.max.y}}, dtc.accent) }
	}, st
	return sig
}

// Classes of the element as switches: one off is taken out of the attribute, and put back when it is on again.
@(private = "file")
class_menu :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	ui.menu_heading("Classes of the element")
	if t.page == nil || e.selected == base.NIL_HANDLE { ui.menu_item("Select an element###dt_cm_none", enabled = false); return }
	cur, _ := dom.get_attribute(t.page.doc, e.selected, "class")
	active := strings.fields(cur, context.temp_allocator)
	for c in active {
		if ui.menu_item(fmt.tprintf("%s###dt_cm_%s", c, c), checked = true, keep_open = true).clicked {
			rest := make([dynamic]string, context.temp_allocator)
			for x in active { if x != c { append(&rest, x) } }
			append(&s.off_classes, strings.clone(c))
			page.dev_set_attribute(t.page, e.selected, "class", strings.join(rest[:], " ", context.temp_allocator))
			request_frames(app, 3)
		}
	}
	for c, i in s.off_classes {
		if ui.menu_item(fmt.tprintf("%s###dt_cmo_%s", c, c), checked = false, keep_open = true).clicked {
			page.dev_set_attribute(t.page, e.selected, "class", strings.concatenate({cur, cur == "" ? "" : " ", c}, context.temp_allocator))
			delete(c)
			ordered_remove(&s.off_classes, i)
			request_frames(app, 3)
			break
		}
	}
	if len(active) == 0 && len(s.off_classes) == 0 { ui.menu_item("This element has no class###dt_cm_empty", enabled = false) }
}

////////////////////////////////
// Computed

@(private = "file")
computed_make :: proc(p: ^page.Page, e: ^Dev_Elements, s: ^Dev_Styles) {
	for c in s.computed { delete(c[0]); delete(c[1]) }
	clear(&s.computed)
	for name in page.computed_property_names() {
		v := page.computed_property(p, e.selected, name)
		if v == "" { continue }
		append(&s.computed, [2]string{strings.clone(name), strings.clone(v)})
	}
}

@(private = "file")
Cmp_Draw :: struct { name, value: string, hot: bool, swatch: draw.Color, has_swatch: bool }

@(private = "file")
computed_view :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	if dt_bar("###dt_cmp_bar", dtm.bar - dt_px(4)) {
		dt_gap(3)
		dt_search("###dt_cmp_filter", &s.filter, "Filter properties", 0, false)
		all := config.bool_of(&app.prefs, "browser.devtools.elements.computed_all")
		if dt_chip("###dt_cmp_all", "Show all", all, "List the properties that have their initial value too").clicked { dev_toggle_pref(app, "browser.devtools.elements.computed_all") }
		dt_gap(3)
	}
	dt_filter_prepare(&s.filter)
	show_all := config.bool_of(&app.prefs, "browser.devtools.elements.computed_all")
	rows := make([dynamic]int, 0, 64, context.temp_allocator)
	for c, i in s.computed {
		if dt_filter_active(&s.filter) && !dt_filter_match(&s.filter, c[0]) && !dt_filter_match(&s.filter, c[1]) { continue }
		if !show_all && is_initial_value(c[0], c[1]) { continue }
		append(&rows, i)
	}
	if len(rows) == 0 {
		dt_empty("###dt_cmp_none", .Computed, e.selected == base.NIL_HANDLE ? "Select an element" : "Nothing to show", "Computed styles of the chosen element appear here.")
		return
	}
	if lst, ok := dt_list("###dt_cmp_list", &s.list, len(rows), dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in lst.first ..< lst.last {
			c := s.computed[rows[k]]
			d := ui.frame_new(Cmp_Draw)
			d.name, d.value = c[0], dt_frame_str(c[1])
			if col, ok2 := swatch_of(c[1]); ok2 { d.swatch, d.has_swatch = col, true }
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###cp%d", rows[k]))
			sig := ui.signal(rb)
			d.hot = sig.hovering
			rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Cmp_Draw)(user)
				r := b.rect
				cy := (r.min.y + r.max.y) * 0.5
				if d.hot { draw.rect(dc, r, dtc.hover) }
				w := (r.max.x - r.min.x) * 0.42
				dt_text(dc, dtm.mono, dtm.mono_fs, r.min.x + dt_px(10), cy, syn_color(.Prop), d.name, w - dt_px(12))
				x := r.min.x + w
				if d.has_swatch {
					sw := dtm.mono_fs * 0.85
					sr := draw.Rect{{x, cy - sw * 0.5}, {x + sw, cy + sw * 0.5}}
					draw.rect(dc, sr, draw.Color{0.9, 0.9, 0.9, 1}, 2)
					draw.rect(dc, sr, d.swatch, 2)
					x += sw + dt_px(5)
				}
				dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.text, d.value, r.max.x - x - dt_px(6))
			}, d
			if sig.right_clicked || sig.double_clicked { clip_set(fmt.tprintf("%s: %s;", c[0], c[1])) }
		}
	}
}

@(private = "file")
is_initial_value :: proc(name, v: string) -> bool {
	switch v {
	case "none", "normal", "auto", "0px", "0", "static", "visible", "initial": 
		switch name {
		case "display", "width", "height": return false
		}
		return true
	}
	return false
}

////////////////////////////////
// Layout: the box model

@(private = "file")
box_make :: proc(p: ^page.Page, t: ^Tab, e: ^Dev_Elements, s: ^Dev_Styles) {
	names := [?]string{"margin-top", "margin-right", "margin-bottom", "margin-left", "border-top-width", "border-right-width", "border-bottom-width", "border-left-width", "padding-top", "padding-right", "padding-bottom", "padding-left"}
	for n, i in names { s.box[i] = px_of_value(page.computed_property(p, e.selected, n)) }
	s.size = {px_of_value(page.computed_property(p, e.selected, "width")), px_of_value(page.computed_property(p, e.selected, "height"))}
}

@(private = "file")
px_of_value :: proc(v: string) -> f32 {
	f, div := f32(0), f32(0)
	neg := false
	for c, i in transmute([]u8)v {
		if i == 0 && c == '-' { neg = true; continue }
		if c == '.' { div = 1; continue }
		if c < '0' || c > '9' { break }
		if div > 0 { div *= 10; f += f32(c - '0') / div } else { f = f * 10 + f32(c - '0') }
	}
	return neg ? -f : f
}

@(private = "file")
Box_Draw :: struct { v: [12]f32, size: [2]f32 }

@(private = "file")
fmt_px :: proc(v: f32) -> string { return v == math.round(v) ? fmt.tprintf("%d", int(v)) : fmt.tprintf("%.1f", v) }

@(private = "file")
layout_view :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	if e.selected == base.NIL_HANDLE { dt_empty("###dt_lay_none", .Layout, "Select an element", "Its box model appears here."); return }
	d := ui.frame_new(Box_Draw)
	d.v, d.size = s.box, s.size
	ui.next({width = ui.fill(), height = ui.fill()})
	b := ui.build_box({}, "###dt_box")
	b.custom, b.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Box_Draw)(user)
		r := b.rect
		cx := (r.min.x + r.max.x) * 0.5
		cy := (r.min.y + r.max.y) * 0.5
		w := min(r.max.x - r.min.x - dt_px(24), dt_px(380))
		h := min(r.max.y - r.min.y - dt_px(16), dt_px(250))
		if w < dt_px(160) || h < dt_px(120) { return }
		layers := [4]struct { name: string, col: draw.Color, inset: f32, k: int }{
			{"margin", draw.Color{0.97, 0.62, 0.30, 0.55}, 0, 0}, {"border", draw.Color{0.98, 0.82, 0.30, 0.60}, 0.14, 4},
			{"padding", draw.Color{0.55, 0.78, 0.40, 0.60}, 0.28, 8}, {"", draw.Color{0.35, 0.60, 0.92, 0.65}, 0.42, 12},
		}
		x0, y0 := cx - w * 0.5, cy - h * 0.5
		for L, i in layers {
			ix, iy := w * L.inset * 0.5, h * L.inset * 0.5
			rect := draw.Rect{{x0 + ix, y0 + iy}, {x0 + w - ix, y0 + h - iy}}
			draw.rect(dc, rect, L.col, i == 0 ? dt_px(4) : 0)
			draw.rect(dc, rect, with_alpha(dtc.text, 0.35), i == 0 ? dt_px(4) : 0, dtm.line)
			if L.name != "" { dt_text(dc, dtm.ui_font, dtm.fs * 0.9, rect.min.x + dt_px(6), rect.min.y + dtm.fs * 0.8, with_alpha(dtc.text, 0.8), L.name) }
			if L.k < 12 {
				v := d.v[L.k:L.k + 4]
				inner := (i + 1 < len(layers)) ? layers[i + 1].inset : 0
				mx, my := (rect.min.x + rect.max.x) * 0.5, (rect.min.y + rect.max.y) * 0.5
				ox, oy := w * (inner - L.inset) * 0.25, h * (inner - L.inset) * 0.25
				t0 := fmt_px(v[0]); t1 := fmt_px(v[1]); t2 := fmt_px(v[2]); t3 := fmt_px(v[3])
				dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, mx - dt_w(dtm.mono, dtm.mono_fs * 0.95, t0) * 0.5, rect.min.y + oy, dtc.text, t0)
				dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, mx - dt_w(dtm.mono, dtm.mono_fs * 0.95, t2) * 0.5, rect.max.y - oy, dtc.text, t2)
				dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, rect.min.x + ox * 2 - dt_w(dtm.mono, dtm.mono_fs * 0.95, t3) * 0.5, my, dtc.text, t3)
				dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, rect.max.x - ox * 2 - dt_w(dtm.mono, dtm.mono_fs * 0.95, t1) * 0.5, my, dtc.text, t1)
			}
		}
		size := fmt.tprintf("%s \u00d7 %s", fmt_px(math.round(d.size.x * 100) / 100), fmt_px(math.round(d.size.y * 100) / 100))
		dt_text(dc, dtm.mono, dtm.mono_fs, cx - dt_w(dtm.mono, dtm.mono_fs, size) * 0.5, cy, dtc.text, size)
	}, d
}

////////////////////////////////
// Event listeners

@(private = "file")
listeners_make :: proc(p: ^page.Page, e: ^Dev_Elements, s: ^Dev_Styles) {
	for l in s.listeners { delete(l.type); delete(l.flags); delete(l.node) }
	clear(&s.listeners)
	cur := e.selected
	depth := 0
	for cur != base.NIL_HANDLE && depth < (s.ancestors ? 30 : 1) {
		n := dom.get(p.doc, cur)
		if n == nil { break }
		label := css_label_for(p, cur)
		for l in page.dev_listeners(p, cur) {
			fl := strings.builder_make(context.temp_allocator)
			if l.capture { strings.write_string(&fl, "capture ") }
			if l.passive { strings.write_string(&fl, "passive ") }
			if l.once { strings.write_string(&fl, "once ") }
			append(&s.listeners, Lst_Item{type = strings.clone(l.type), flags = strings.clone(strings.trim_space(strings.to_string(fl))), node = strings.clone(label), id = l.callback})
		}
		cur = n.parent
		depth += 1
	}
}

@(private = "file")
Lst_Draw :: struct { it: Lst_Item, hot: bool }

@(private = "file")
listeners_view :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	if dt_bar("###dt_lst_bar", dtm.bar - dt_px(4)) {
		dt_gap(3)
		if dt_chip("###dt_lst_anc", "Ancestors", s.ancestors, "Include the listeners of the elements above").clicked { s.ancestors = !s.ancestors; s.key_mut = 0 }
	}
	if len(s.listeners) == 0 {
		dt_empty("###dt_lst_none", .Event, e.selected == base.NIL_HANDLE ? "Select an element" : "No listeners", "Listeners added with addEventListener appear here (scripts of the page only).")
		return
	}
	if lst, ok := dt_list("###dt_lst_list", &s.list, len(s.listeners), dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in lst.first ..< lst.last {
			d := ui.frame_new(Lst_Draw)
			d.it = s.listeners[k]
			d.it.type, d.it.flags, d.it.node = dt_frame_str(d.it.type), dt_frame_str(d.it.flags), dt_frame_str(d.it.node)
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###ls%d", k))
			sig := ui.signal(rb)
			d.hot = sig.hovering
			rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Lst_Draw)(user)
				r := b.rect
				cy := (r.min.y + r.max.y) * 0.5
				if d.hot { draw.rect(dc, r, dtc.hover) }
				x := r.min.x + dt_px(10)
				x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, syn_color(.Keyword), d.it.type) + dt_px(10)
				if d.it.flags != "" { x += dt_text(dc, dtm.ui_font, dtm.fs * 0.9, x, cy, dtc.weak, d.it.flags) + dt_px(10) }
				dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.text, fmt.tprintf("handler #%d", d.it.id))
				dt_text_r(dc, dtm.mono, dtm.mono_fs * 0.95, r.max.x - dt_px(8), cy, dtc.weak, d.it.node)
			}, d
		}
	}
}

////////////////////////////////
// Accessibility

@(private = "file")
role_of :: proc(n: ^dom.Node, explicit: string, href: bool, level: ^int) -> string {
	if explicit != "" { return explicit }
	switch n.name {
	case "a": return href ? "link" : "generic"
	case "button": return "button"
	case "h1", "h2", "h3", "h4", "h5", "h6": level^ = int(n.name[1] - '0'); return "heading"
	case "img": return "img"
	case "input", "textarea": return "textbox"
	case "select": return "combobox"
	case "nav": return "navigation"
	case "main": return "main"
	case "header": return "banner"
	case "footer": return "contentinfo"
	case "aside": return "complementary"
	case "section", "article": return "region"
	case "ul", "ol": return "list"
	case "li": return "listitem"
	case "table": return "table"
	case "tr": return "row"
	case "td": return "cell"
	case "th": return "columnheader"
	case "form": return "form"
	case "p": return "paragraph"
	case "dialog": return "dialog"
	case "progress": return "progressbar"
	case "hr": return "separator"
	}
	return "generic"
}

@(private = "file")
accessibility_make :: proc(p: ^page.Page, e: ^Dev_Elements, s: ^Dev_Styles) {
	for a in s.acc { delete(a[0]); delete(a[1]) }
	clear(&s.acc)
	n := dom.get(p.doc, e.selected)
	if n == nil || n.kind != .Element { return }
	explicit, _ := dom.get_attribute(p.doc, e.selected, "role")
	_, has_href := dom.get_attribute(p.doc, e.selected, "href")
	level := 0
	role := role_of(n, explicit, has_href, &level)
	add :: proc(s: ^Dev_Styles, k, v: string) { append(&s.acc, [2]string{strings.clone(k), strings.clone(v)}) }
	add(s, "Role", role)
	if level > 0 { add(s, "Level", fmt.tprintf("%d", level)) }
	name := ""
	for attr in ([?]string{"aria-label", "alt", "title", "placeholder", "value"}) {
		if v, ok := dom.get_attribute(p.doc, e.selected, attr); ok && v != "" { name = v; break }
	}
	if name == "" { name = strings.trim_space(dom.text_content(p.doc, e.selected)) }
	add(s, "Name", dev_line(name, 120))
	if v, ok := dom.get_attribute(p.doc, e.selected, "aria-describedby"); ok { add(s, "Described by", v) }
	focusable := n.name == "a" && has_href || n.name == "button" || n.name == "input" || n.name == "select" || n.name == "textarea"
	if _, ok := dom.get_attribute(p.doc, e.selected, "tabindex"); ok { focusable = true }
	add(s, "Focusable", focusable ? "yes" : "no")
	_, dis := dom.get_attribute(p.doc, e.selected, "disabled")
	if dis { add(s, "Disabled", "yes") }
	if v, ok := dom.get_attribute(p.doc, e.selected, "aria-hidden"); ok { add(s, "Hidden", v) }
	for a in n.attrs { if strings.has_prefix(a.name, "aria-") && a.name != "aria-label" && a.name != "aria-hidden" && a.name != "aria-describedby" { add(s, a.name, a.value) } }
}

@(private = "file")
accessibility_view :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	s := &e.side
	if len(s.acc) == 0 { dt_empty("###dt_acc_none", .Access, "Select an element", "Its role, name and state for assistive technology appear here."); return }
	if lst, ok := dt_list("###dt_acc_list", &s.list, len(s.acc), dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in lst.first ..< lst.last {
			d := ui.frame_new(Cmp_Draw)
			d.name, d.value = dt_frame_str(s.acc[k][0]), dt_frame_str(s.acc[k][1])
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###ac%d", k))
			sig := ui.signal(rb)
			d.hot = sig.hovering
			rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Cmp_Draw)(user)
				r := b.rect
				cy := (r.min.y + r.max.y) * 0.5
				if d.hot { draw.rect(dc, r, dtc.hover) }
				w := (r.max.x - r.min.x) * 0.32
				dt_text(dc, dtm.ui_font, dtm.fs, r.min.x + dt_px(10), cy, dtc.weak, d.name, w - dt_px(12))
				dt_text(dc, dtm.mono, dtm.mono_fs, r.min.x + w, cy, dtc.text, d.value, r.max.x - r.min.x - w - dt_px(8))
			}, d
		}
	}
}

_ :: ui

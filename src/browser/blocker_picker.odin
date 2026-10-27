package browser

import "core:fmt"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:blocker"
import "wb:i18n"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:style"

// The element picker. Aim: the pointer outlines the element of the page under it, a click chooses it (Escape or a right
// click cancels). Then a bar over the bottom of the page proposes a cosmetic filter for it: a precision slider walks the
// candidate selectors from the most specific to the broadest, the selector can be edited, the number of elements it
// matches is shown and they are outlined, Preview hides them for real (undone by Cancel), Create adds `site##selector` to
// "My filters" and applies it at once.

Picker :: struct {
	active:   bool,
	tab:      u64,
	stage:    int,            // 0 aiming, 1 choosing
	hover:    base.Handle,
	picked:   base.Handle,
	cands:    [dynamic]string,
	level:    f32,
	last_level: int,
	field:    ui.Text_Field,
	field_text: string,        // the selector the matches below were computed for
	matches:  [dynamic]base.Handle,
	valid:    bool,
	preview:  ^style.Sheet,
	scope_global: bool,
}

@(private = "file") pick: Picker

blocker_picker_active :: proc() -> bool { return pick.active }

blocker_picker_begin :: proc(app: ^App, t: ^Tab) {
	picker_reset()
	pick.active, pick.stage, pick.tab = true, 0, t.id
	request_frames(app, 3)
}

// The element is already chosen (the page's context menu).
blocker_picker_target :: proc(app: ^App, t: ^Tab, el: base.Handle) {
	blocker_picker_begin(app, t)
	if el != base.NIL_HANDLE { picker_choose(t, el) }
}

@(private = "file")
picker_reset :: proc() {
	if pick.preview != nil { picker_unpreview(current_tab(the_app)) }
	for c in pick.cands { delete(c) }
	delete(pick.cands); delete(pick.matches); delete(pick.field_text)
	ui.field_destroy(&pick.field)
	pick = {}
}

blocker_picker_cancel :: proc(app: ^App) {
	if !pick.active { return }
	picker_reset()
	request_frames(app, 3)
}

@(private = "file")
picker_unpreview :: proc(t: ^Tab) {
	if pick.preview != nil && t != nil && t.page != nil && t.page.engine != nil { style.engine_remove_sheet(t.page.engine, pick.preview) }
	pick.preview = nil
}

@(private = "file")
attr :: proc(d: ^dom.Document, h: base.Handle, name: string) -> string {
	v, _ := dom.get_attribute(d, h, name)
	return v
}

@(private = "file")
css_ident_ok :: proc(s: string) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') { return false } }
	return !(s[0] >= '0' && s[0] <= '9')
}

@(private = "file")
nth_of_type :: proc(d: ^dom.Document, h: base.Handle, tag: string) -> int {
	n := 1
	for s := dom.get(d, h).prev; s != base.NIL_HANDLE; {
		sn := dom.get(d, s)
		if sn == nil { break }
		if sn.kind == .Element && sn.name == tag { n += 1 }
		s = sn.prev
	}
	return n
}

// Selectors that name the element, from the broadest to the most specific (duplicates and misses dropped).
@(private = "file")
picker_candidates :: proc(p: ^page.Page, h: base.Handle) {
	for c in pick.cands { delete(c) }
	clear(&pick.cands)
	d := p.doc
	n := dom.get(d, h)
	if n == nil { return }
	tag := n.name
	add :: proc(s: string) {
		for c in pick.cands { if c == s { return } }
		append(&pick.cands, strings.clone(s))
	}
	classes := make([dynamic]string, context.temp_allocator)
	for c in strings.fields(attr(d, h, "class"), context.temp_allocator) { if css_ident_ok(c) && len(c) < 40 { append(&classes, c) } }
	id := attr(d, h, "id")
	if len(classes) > 0 {
		add(fmt.tprintf(".%s", classes[0]))
		add(fmt.tprintf("%s.%s", tag, classes[0]))
		if len(classes) > 1 {
			sb := strings.builder_make(context.temp_allocator)
			for c in classes { strings.write_byte(&sb, '.'); strings.write_string(&sb, c) }
			add(strings.to_string(sb))
			add(fmt.tprintf("%s%s", tag, strings.to_string(sb)))
		}
	}
	for a in ([]string{"src", "href", "data-ad-slot", "data-ad-client", "name", "title", "role"}) {
		v := attr(d, h, a)
		if v == "" || len(v) > 200 { continue }
		if (a == "src" || a == "href") && (strings.has_prefix(v, "http") || strings.has_prefix(v, "//")) {
			// the part that identifies the server, up to the third slash
			cut := v
			if i := strings.index(v[min(len(v), 8):], "/"); i >= 0 { cut = v[:min(len(v), 8) + i + 1] }
			if !strings.contains_rune(cut, '"') { add(fmt.tprintf("%s[%s^=\"%s\"]", tag, a, cut)) }
		} else if !strings.contains_rune(v, '"') && !strings.contains_rune(v, '\\') {
			add(fmt.tprintf("%s[%s=\"%s\"]", tag, a, v))
		}
	}
	if css_ident_ok(id) && len(id) < 60 { add(fmt.tprintf("#%s", id)) }
	// by position: up to the nearest ancestor with an id, else three levels
	path := strings.builder_make(context.temp_allocator)
	segs := make([dynamic]string, context.temp_allocator)
	cur := h
	for depth := 0; depth < 4 && cur != base.NIL_HANDLE; depth += 1 {
		cn := dom.get(d, cur)
		if cn == nil || cn.kind != .Element || cn.name == "html" || cn.name == "body" { break }
		cid := attr(d, cur, "id")
		if css_ident_ok(cid) { inject_at(&segs, 0, fmt.tprintf("#%s", cid)); break }
		inject_at(&segs, 0, fmt.tprintf("%s:nth-of-type(%d)", cn.name, nth_of_type(d, cur, cn.name)))
		cur = cn.parent
	}
	for s, i in segs { if i > 0 { strings.write_string(&path, " > ") }; strings.write_string(&path, s) }
	if len(segs) > 0 { add(strings.to_string(path)) }
	// most specific last: order by what each matches (fewest last)
	counts := make([dynamic]int, context.temp_allocator)
	for c in pick.cands { f, ok := page.select_all(p, c); append(&counts, ok ? len(f) : 1 << 30) }
	for i in 1 ..< len(pick.cands) {
		j := i
		for j > 0 && counts[j] > counts[j - 1] {
			counts[j], counts[j - 1] = counts[j - 1], counts[j]
			pick.cands[j], pick.cands[j - 1] = pick.cands[j - 1], pick.cands[j]
			j -= 1
		}
	}
	// drop the ones that match nothing or the whole page
	w := 0
	for i in 0 ..< len(pick.cands) {
		if counts[i] == 0 || counts[i] > 1 << 20 { delete(pick.cands[i]); continue }
		pick.cands[w] = pick.cands[i]; w += 1
	}
	resize(&pick.cands, w)
}

@(private = "file")
picker_choose :: proc(t: ^Tab, target: base.Handle) {
	p := t.page
	if p == nil { return }
	el := target
	n := dom.get(p.doc, el)
	if n != nil && n.kind != .Element { el = n.parent }
	picker_candidates(p, el)
	pick.picked, pick.stage = el, 1
	// the most specific candidate that is not a positional path is the first proposal: the one that matches the fewest
	// (and it is the last of the list)
	if len(pick.cands) == 0 { ui.field_set(&pick.field, "") } else { ui.field_set(&pick.field, pick.cands[len(pick.cands) - 1]) }
	pick.level = f32(max(len(pick.cands) - 1, 0))
	pick.last_level = int(pick.level)
	delete(pick.field_text); pick.field_text = ""
}

@(private = "file")
picker_matches :: proc(p: ^page.Page) {
	sel := strings.trim_space(ui.field_string(&pick.field))
	if sel == pick.field_text { return }
	delete(pick.field_text); pick.field_text = strings.clone(sel)
	clear(&pick.matches)
	pick.valid = false
	if sel == "" { return }
	f, ok := page.select_all(p, sel)
	pick.valid = ok
	if ok { for h in f { if len(pick.matches) < 80 { append(&pick.matches, h) } } }
}

@(private = "file")
Pick_Draw :: struct { app: ^App, t: ^Tab, outline: draw.Color, fill: draw.Color }

@(private = "file")
outline_node :: proc(dc: ^draw.Context, d: ^Pick_Draw, h: base.Handle, fill, line: draw.Color) {
	t := d.t
	if t.page == nil || !t.layout.valid { return }
	area := active_window(d.app).page_rect
	r, ok := lay.box_of(&t.layout, h, draw.rect_size(area), t.scroll)
	if !ok || !r.visible { return }
	shift := draw.Vec2{area.min.x, area.min.y - t.scroll}   // (box_of: document coordinates, position: fixed boxes included)
	b := draw.Rect{r.bounds.min + shift, r.bounds.max + shift}
	draw.push_clip(dc, area)
	draw.rect(dc, b, fill)
	w := max(ui.scale(), 1.5)
	draw.rect(dc, b, line, 0, w)
	draw.pop_clip(dc)
}

@(private = "file")
pick_overlay_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Pick_Draw)(user)
	if pick.stage == 0 {
		if pick.hover != base.NIL_HANDLE { outline_node(dc, d, pick.hover, {0.2, 0.55, 0.95, 0.28}, {0.2, 0.55, 0.95, 0.95}) }
	} else {
		for h in pick.matches { outline_node(dc, d, h, {0.9, 0.25, 0.22, 0.25}, {0.9, 0.25, 0.22, 0.95}) }
	}
}

// Built every frame after the page's own box (page_view): the overlay that takes the pointer while aiming, the outlines,
// and the bar of the choice.
blocker_picker_frame :: proc(app: ^App, t: ^Tab) {
	if !pick.active { return }
	if t == nil || t.id != pick.tab || t.kind != .Web || t.page == nil { blocker_picker_cancel(app); return }
	em := ui.font_size()
	area := active_window(app).page_rect
	d := ui.frame_new(Pick_Draw)
	d.app, d.t = app, t
	if pick.stage == 0 {
		ui.next({fixed_x = area.min.x, fixed_y = area.min.y, width = ui.px(draw.rect_size(area).x), height = ui.px(draw.rect_size(area).y), cursor = .Crosshair})
		box := ui.custom("###bl_pick_overlay", pick_overlay_draw, d, {.Clickable})
		sig := ui.signal(box)
		if sig.hovering {
			pick.hover = hit_test(&t.layout, ui.mouse_pos() - area.min, draw.rect_size(area), t.scroll)
			request_frames(app, 2)
		}
		if sig.clicked && pick.hover != base.NIL_HANDLE { picker_choose(t, pick.hover); request_frames(app, 3) }
		if sig.right_clicked || ui.key_press(.Escape) { blocker_picker_cancel(app); return }
		// a hint
		ui.next({fixed_x = area.min.x + em * 0.8, fixed_y = area.min.y + em * 0.8, width = ui.px(em * 30), height = ui.px(ui.dense(em * 2.2)), radius = em * 0.4})
		if ui.row(.Center, {.Draw_Background, .Draw_Border}, "###bl_pick_hint") {
			ui.spacer(ui.px(em * 0.7))
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(tid(i18n.tr("Click the element to block · Esc: cancel"), "bl_pick_hint_l"))
		}
		return
	}
	// stage 1: outlines (drawn by a box that lets the pointer through) and the bar
	ui.next({fixed_x = area.min.x, fixed_y = area.min.y, width = ui.px(draw.rect_size(area).x), height = ui.px(draw.rect_size(area).y)})
	ui.custom("###bl_pick_outline", pick_overlay_draw, d)
	picker_matches(t.page)
	bar_h := ui.dense(em * 5.4)
	w := min(draw.rect_size(area).x - em * 2, em * 60)
	ui.next({fixed_x = area.min.x + (draw.rect_size(area).x - w) * 0.5, fixed_y = area.max.y - bar_h - em * 1.0, width = ui.px(w), height = ui.px(bar_h), radius = em * 0.5})
	if ui.column(.Start, {.Draw_Background, .Draw_Border}, "###bl_pick_bar") {
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.pct(1), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(em * 7), height = ui.pct(1)})
			if ui.tags("weak") { ui.label(tid(i18n.tr("Selector"), "pk_l")) }
			ui.next({width = ui.fill(), height = ui.pct(1)})
			res := ui.line_edit("###pk_sel", &pick.field, i18n.tr("CSS selector"))
			_ = res
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(em * 9), height = ui.pct(1)})
			count := len(pick.matches)
			label := tid(pick.valid ? fmt.tprintf(i18n.tr(count, "%d element", "%d elements"), count) : i18n.tr("invalid selector"), "pk_n")
			if ui.tags("weak") { ui.label(label) }
			ui.spacer(ui.px(em * 0.6))
		}
		ui.next({width = ui.pct(1), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(em * 7), height = ui.pct(1)})
			if ui.tags("weak") { ui.label(tid(i18n.tr("Precision"), "pk_pl")) }
			if len(pick.cands) > 1 {
				ui.next({width = ui.px(em * 14), height = ui.pct(1)})
				before := pick.level
				ui.slider("###pk_slider", &pick.level, 0, f32(len(pick.cands) - 1), 1, "")
				if pick.level != before {
					idx := clamp(int(pick.level + 0.5), 0, len(pick.cands) - 1)
					if idx != pick.last_level { pick.last_level = idx; ui.field_set(&pick.field, pick.cands[len(pick.cands) - 1 - idx]) }
				}
			} else { ui.spacer(ui.px(em * 14)) }
			ui.spacer(ui.px(em * 0.6))
			if bar_button(i18n.tr("Preview"), "pk_prev", em * 6.5) { picker_preview(t) }
			ui.spacer(ui.px(em * 0.4))
			host, _ := blocker_page_host(t)
			if ui.disabled(!pick.valid || len(pick.matches) == 0) {
				if bar_button(i18n.tr("Create"), "pk_create", em * 6.5) { picker_create(app, t, blocker_site_key(host)) }
			}
			ui.spacer(ui.px(em * 0.4))
			if bar_button(i18n.tr("Pick again"), "pk_again", em * 7.5) { picker_unpreview(t); pick.stage = 0; pick.hover = base.NIL_HANDLE }
			ui.spacer(ui.px(em * 0.4))
			if bar_button(i18n.tr("Cancel"), "pk_cancel", em * 6) { blocker_picker_cancel(app); return }
		}
	}
	if ui.key_press(.Escape) && ui.focus_key() == 0 { blocker_picker_cancel(app) }
}

@(private = "file")
bar_button :: proc(text, id: string, w: f32) -> bool {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.8)), radius = em * 0.35})
	return ui.button(fmt.aprintf("%s###%s", text, id, allocator = ui.frame_allocator())).clicked
}

@(private = "file")
picker_preview :: proc(t: ^Tab) {
	picker_unpreview(t)
	sel := strings.trim_space(ui.field_string(&pick.field))
	if sel == "" || t.page == nil || t.page.engine == nil { return }
	pick.preview = style.engine_add_injected_sheet(t.page.engine, fmt.tprintf("%s{{display:none!important}}", sel))
}

@(private = "file")
picker_create :: proc(app: ^App, t: ^Tab, site: string) {
	sel := strings.trim_space(ui.field_string(&pick.field))
	if sel == "" { return }
	picker_unpreview(t)
	// it applies to the page right now, as the saved filter will on the next ones
	if t.page != nil && t.page.engine != nil { style.engine_add_injected_sheet(t.page.engine, fmt.tprintf("%s{{display:none!important}}", sel)) }
	dash_add_filter(app, fmt.tprintf("%s##%s", site, sel))
	picker_reset_keep_sheet()
	request_frames(app, 3)
}

@(private = "file")
picker_reset_keep_sheet :: proc() {
	pick.preview = nil
	picker_reset()
}

// "Block this resource": the request URL of an image, a frame or a script, as a network filter for every site.
blocker_block_resource :: proc(app: ^App, url: string) {
	u := url
	if i := strings.index_byte(u, '#'); i >= 0 { u = u[:i] }
	for pre in ([]string{"https://", "http://"}) { if strings.has_prefix(u, pre) { u = u[len(pre):]; break } }
	if i := strings.index_byte(u, '?'); i >= 0 { u = u[:i] }
	if u == "" { return }
	dash_add_filter(app, fmt.tprintf("||%s", u))
}

_ :: blocker

package browser

// The cursor over the page: CSS `cursor` (CSS Basic User Interface 4 §5.1) applied to the window.
//   * Each frame with the pointer over the page area (so also after a scroll or a mutation under a pointer that did not
//     move), the page is hit-tested (pointer-events: none and visibility: hidden let the point through) and the
//     element's computed cursor (inherited) shows. The chrome keeps the cursor outside the page area, over its own
//     widgets and overlays, and during its own drags.
//   * `auto` as Chromium resolves it: an I-beam over editable content (text fields, textarea, contenteditable) and over
//     text that can be selected (user-select), the arrow elsewhere (scroll bars included, whatever the CSS says).
//   * `url(...) x y` / image-set(): the first image that is loaded, decodable and not larger than
//     browser.cursor.image_max_css_px CSS pixels becomes a custom cursor of the toolkit (made once and kept in a small
//     cache); while it loads, or when it cannot be used, the next one, then the keyword. Images larger than
//     browser.cursor.large_image_css_px are shown only while they lie inside the page area (Chromium's rule: a page's
//     cursor must not pass for the browser's interface).
//   * While the tab loads, the arrow is the progress cursor (the arrow with the busy sign), as in Chromium.
//   * A drag that starts on the page (a selection, a press held) keeps the cursor of where it started until the
//     button is released.
// WREN_CURSOR_LOG=path appends a line each time the window's cursor changes (e2e tests: cursor_e2e.ps1).

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:host"
import lay "wb:layout"
import "wb:page"
import "wb:style"

CURSOR_PREFS := [?]config.Def{
	{name = "browser.cursor.page_css", kind = .Bool, default = {b = true},
		description = "Pages choose the cursor over them (CSS cursor). Off: the arrow, an I-beam over text and fields (what cursor: auto shows)."},
	{name = "browser.cursor.images", kind = .Bool, default = {b = true},
		description = "Pages may use images as cursors (cursor: url(...)). Off: the keyword after the images."},
	{name = "browser.cursor.image_max_css_px", kind = .Int, default = {i = 128}, bounded = true, min = 1, max = 512, unit = "px",
		description = "Largest cursor image, in CSS pixels on each side (Chromium: 128); a larger one is not used (the next one, or the keyword, is)."},
	{name = "browser.cursor.large_image_css_px", kind = .Int, default = {i = 32}, bounded = true, min = 0, max = 512, unit = "px",
		description = "A cursor image larger than this (CSS pixels) shows only while it lies entirely inside the page area, so that a page cannot draw over the browser's interface with it (Chromium: 32). 0: no such check."},
	{name = "browser.cursor.progress_while_loading", kind = .Bool, default = {b = true},
		description = "While the tab loads, the page's arrow shows the \"working in background\" sign (as in Chromium)."},
	{name = "browser.cursor.cache_entries", kind = .Int, default = {i = 32}, bounded = true, min = 1, max = 1024,
		description = "Cursors made from page images kept ready (the least recently used ones go first)."},
}

register_cursor_prefs :: proc(p: ^config.Prefs) { config.register(p, CURSOR_PREFS[:]) }

Cursor_Settings :: struct {
	page_css:      bool,
	images:        bool,
	image_max_css: int,
	large_css:     int,
	cache_entries: int,
	progress_loading: bool,
}

cursor_settings_from_prefs :: proc(p: ^config.Prefs) -> Cursor_Settings {
	return Cursor_Settings{
		page_css = config.bool_of(p, "browser.cursor.page_css"),
		images = config.bool_of(p, "browser.cursor.images"),
		image_max_css = int(config.int_of(p, "browser.cursor.image_max_css_px")),
		large_css = int(config.int_of(p, "browser.cursor.large_image_css_px")),
		cache_entries = int(config.int_of(p, "browser.cursor.cache_entries")),
		progress_loading = config.bool_of(p, "browser.cursor.progress_while_loading"),
	}
}

ccfg: Cursor_Settings

// What the window shows: a keyword cursor, or a custom one with the keyword as its fallback.
Window_Cursor :: struct {
	keyword: platform.Cursor,
	custom:  platform.Custom_Cursor,
	scale:   f32,   // device pixels per CSS pixel the custom cursor is shown at
	node:    base.Handle,   // the page's element it comes from (NIL: the chrome's, or none)
	at:      [2]f32,        // where the page was asked (CSS pixels of the page area; the log's)
}

@(private = "file")
Cursor_Cache_Entry :: struct { key: u64, cc: platform.Custom_Cursor, used: u64 }

@(private = "file")
Page_Cursor_State :: struct {
	watch:    int,
	cache:    [dynamic]Cursor_Cache_Entry,
	clock:    u64,
	dragging: bool,            // a press on the page is held: `frozen` shows until it is released
	frozen:   Window_Cursor,
	shown:    Window_Cursor,
	shown_ok: bool,
	log_path: string,
}

@(private = "file") pcs: Page_Cursor_State

page_cursor_init :: proc(app: ^App) {
	ccfg = cursor_settings_from_prefs(&app.prefs)
	pcs.watch = config.watch(&app.prefs, "browser.cursor.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		ccfg = cursor_settings_from_prefs(p)
		(^App)(user).frames_requested = max((^App)(user).frames_requested, 2)
	}, app)
	pcs.log_path = strings.clone(os.get_env("WREN_CURSOR_LOG", context.temp_allocator))
}

page_cursor_shutdown :: proc(app: ^App) {
	config.unwatch(&app.prefs, pcs.watch)
	platform.set_cursor(app.win, .Arrow)
	for e in pcs.cache { platform.custom_cursor_release(app.win, e.cc) }
	delete(pcs.cache)
	delete(pcs.log_path)
	pcs = {}
}

////////////////////////////////
// The page's cursor at a point (pure: page_cursor_test.odin)

// What the page asks for at a point: the keyword (`auto` resolved) and the images before it.
Page_Cursor :: struct {
	keyword: platform.Cursor,
	images:  []style.Cursor_Image,
	node:    base.Handle,   // the element hit (NIL: none, the root's cursor)
	auto:    bool,          // the keyword came from `auto`
}

// The platform cursor of a CSS keyword (Auto: the arrow).
cursor_of_keyword :: proc(k: style.Cursor) -> platform.Cursor {
	if k == .Auto { return .Arrow }
	c, ok := platform.cursor_from_css(style.cursor_keyword_name(k))
	return ok ? c : .Arrow
}

// Is `h` (an element) editable: a text field, a textarea, or inside contenteditable (true / plaintext-only, up to the
// nearest contenteditable attribute)?
page_editable :: proc(d: ^dom.Document, h: base.Handle) -> bool {
	n := dom.get(d, h)
	if n == nil || n.kind != .Element { return false }
	switch n.name {
	case "textarea": return true
	case "input":
		t, _ := dom.get_attribute(d, h, "type")
		switch strings.to_lower(strings.trim_space(t), context.temp_allocator) {
		case "", "text", "search", "url", "tel", "email", "password", "number": return true
		}
		return false
	}
	for cur := h; cur != base.NIL_HANDLE; {
		cn := dom.get(d, cur)
		if cn == nil { break }
		if cn.kind == .Element {
			if v, ok := dom.get_attribute(d, cur, "contenteditable"); ok {
				return v == "" || strings.equal_fold(v, "true") || strings.equal_fold(v, "plaintext-only")
			}
		}
		cur = cn.parent
	}
	return false
}

// Is `h` the element `top` or inside it?
@(private = "file")
node_within :: proc(d: ^dom.Document, h, top: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		if cur == top { return true }
		n := dom.get(d, cur)
		if n == nil { break }
		cur = n.parent
	}
	return false
}

// Between two lines of text the text's rectangles leave a gap (the leading: they are as tall as the font, the line
// is as tall as line-height), where the hit test finds the element's box. Chromium's line boxes reach across it: the
// nearer of the text above and the text below, in the element and across `p`, counts (the line's text item).
@(private = "file")
line_gap_text :: proc(l: ^Layout, d: ^dom.Document, box: ^lay.Display_Item, p, viewport: [2]f32, scroll: f32) -> i32 {
	v := lay.view_make(l, viewport, scroll, cull = false)
	above, below := i32(lay.NONE), i32(lay.NONE)
	da, db := max(f32), max(f32)
	ha: f32
	for i in 0 ..< len(l.items) {
		it := &l.items[i]
		if it.kind != .Text || .Hit not_in it.flags || it.space != box.space || l.spaces[it.space].xform != lay.NONE { continue }
		r := lay.item_rect(l, &v, it)
		if p.x < r.min.x || p.x >= r.max.x { continue }
		if r.max.y <= p.y && p.y - r.max.y < da {
			if node_within(d, it.node, box.node) { above, da, ha = i32(i), p.y - r.max.y, r.max.y - r.min.y }
		} else if r.min.y >= p.y && r.min.y - p.y < db {
			if node_within(d, it.node, box.node) { below, db = i32(i), r.min.y - p.y }
		}
	}
	// (a gap more than 2.5 lines of text tall is no leading: line-height reaches 3.5 at most there)
	if above == lay.NONE || below == lay.NONE || da + db > 2.5 * ha { return lay.NONE }
	return da <= db ? above : below
}

// Is `p` on a scroll bar of a scroll container (drawn in the layout's display list, not transformed)?
@(private = "file")
on_scrollbar :: proc(l: ^Layout, p, viewport: [2]f32, scroll: f32) -> bool {
	v := lay.view_make(l, viewport, scroll, cull = false, allocator = context.temp_allocator)
	for i := len(l.items) - 1; i >= 0; i -= 1 {
		it := &l.items[i]
		if it.kind != .Scrollbar || l.spaces[it.space].xform != lay.NONE { continue }
		r := lay.item_rect(l, &v, it)
		if p.x < r.min.x || p.y < r.min.y || p.x >= r.max.x || p.y >= r.max.y { continue }
		if it.clip != lay.NONE && !lay.clip_contains(l, &v, it.clip, p) { continue }
		return true
	}
	return false
}

// The page's cursor at `p` (page-area device pixels; `viewport` its size, `scroll` the document's scroll).
// `css`: the page's cursor property counts (browser.cursor.page_css); without it every cursor is `auto`'s.
page_cursor_at :: proc(l: ^Layout, d: ^dom.Document, st: ^style.Styled, p, viewport: [2]f32, scroll: f32, css := true) -> (pc: Page_Cursor) {
	pc.keyword = .Arrow
	if l == nil || !l.valid || d == nil || st == nil { return }
	h := lay.hit_test(l, p, viewport, scroll)
	cs: ^style.Computed
	is_text := false
	if h.item == lay.NONE {
		// nothing hit: the canvas, whose cursor is the root element's
		if root := dom.get(d, d.root); root != nil {
			for c := root.first_child; c != base.NIL_HANDLE; {
				n := dom.get(d, c)
				if n == nil { break }
				if n.kind == .Element { pc.node = c; break }
				c = n.next
			}
		}
		if pc.node != base.NIL_HANDLE { cs = style.style_of(st, pc.node) }
	} else {
		if on_scrollbar(l, p, viewport, scroll) { return }   // the arrow over scroll bars, whatever the page says
		it := &l.items[h.item]
		if it.kind == .Scrollbar { return }
		if it.kind == .Box || it.kind == .Inline_Box {
			if gap := line_gap_text(l, d, it, p, viewport, scroll); gap != lay.NONE { it = &l.items[gap] }
		}
		pc.node = it.node
		cs = it.cs != nil ? it.cs : style.style_of(st, it.node)
		is_text = it.kind == .Text
	}
	if cs == nil { return }
	if css && cs.cursor != .Auto {
		pc.keyword = cursor_of_keyword(cs.cursor)
	} else {
		pc.auto = true
		switch {
		case pc.node != base.NIL_HANDLE && page_editable(d, pc.node): pc.keyword = .Text
		case is_text && lay.is_selectable(d, st, pc.node):           pc.keyword = .Text
		case: pc.keyword = .Arrow
		}
	}
	if css { pc.images = cs.cursor_images }
	return
}

////////////////////////////////
// Images as cursors

@(private = "file")
cache_find :: proc(key: u64) -> platform.Custom_Cursor {
	for &e in pcs.cache {
		if e.key == key { pcs.clock += 1; e.used = pcs.clock; return e.cc }
	}
	return 0
}

@(private = "file")
cache_add :: proc(app: ^App, key: u64, cc: platform.Custom_Cursor) {
	pcs.clock += 1
	append(&pcs.cache, Cursor_Cache_Entry{key = key, cc = cc, used = pcs.clock})
	for len(pcs.cache) > max(ccfg.cache_entries, 1) {
		oldest := -1
		for e, i in pcs.cache {
			if e.cc == pcs.shown.custom || e.cc == pcs.frozen.custom { continue }
			if oldest < 0 || e.used < pcs.cache[oldest].used { oldest = i }
		}
		if oldest < 0 { break }
		platform.custom_cursor_release(app.win, pcs.cache[oldest].cc)
		unordered_remove(&pcs.cache, oldest)
	}
}

// The custom cursor for the first usable image of `images` at window point `pos` (0: none usable now: loading,
// broken, too large, or a large one that would reach outside the page area).
@(private = "file")
cursor_image :: proc(app: ^App, t: ^Tab, images: []style.Cursor_Image, pos: [2]f32, scale: f32) -> platform.Custom_Cursor {
	if !ccfg.images || len(images) == 0 || t.page == nil { return 0 }
	dppx := f32(1)
	if t.page.engine != nil && t.page.engine.env.dppx > 0 { dppx = f32(t.page.engine.env.dppx) }
	for img in images {
		src, ok := style.cursor_image_pick(img, dppx)
		if !ok { continue }
		v := page.css_image_view(t.page, src.url)
		if v.state != .Ready || v.id == 0 { continue }
		css := v.natural / max(src.density, 0.01)
		if css.x <= 0 || css.y <= 0 || css.x > f32(ccfg.image_max_css) || css.y > f32(ccfg.image_max_css) { continue }
		hot := img.has_hotspot ? img.hotspot : [2]f32{}
		hot = {clamp(hot.x, 0, css.x), clamp(hot.y, 0, css.y)}
		if ccfg.large_css > 0 && (css.x > f32(ccfg.large_css) || css.y > f32(ccfg.large_css)) {
			lo := pos - hot * scale
			hi := lo + css * scale
			r := app.page_rect
			if lo.x < r.min.x || lo.y < r.min.y || hi.x > r.max.x || hi.y > r.max.y { continue }
		}
		want := [2]int{max(int(css.x * scale + 0.5), 1), max(int(css.y * scale + 0.5), 1)}
		fp := page.frame_pixels(v.id, f64(host.now_ns(&app.loop)) / 1e6, want.x, want.y, 1000)
		if !fp.ok || fp.width <= 0 || fp.height <= 0 { continue }
		density := f32(fp.width) / css.x   // image pixels per CSS pixel of what was decoded (an SVG's raster, a reduced decode)
		kb: [5]u64 = {fp.texture, fp.generation, u64(transmute(u32)hot.x) << 32 | u64(transmute(u32)hot.y), u64(transmute(u32)css.x) << 32 | u64(transmute(u32)css.y), u64(fp.width) << 32 | u64(fp.height)}
		key := hash.fnv64a(transmute([]u8)kb[:]) | 1
		if cc := cache_find(key); cc != 0 && platform.custom_cursor_valid(app.win, cc) { return cc }
		pixels := fp.pixels
		if fp.stride != fp.width * 4 {
			pixels = make([]u8, fp.width * fp.height * 4, context.temp_allocator)
			for y in 0 ..< fp.height { copy(pixels[y * fp.width * 4:][:fp.width * 4], fp.pixels[y * fp.stride:][:fp.width * 4]) }
		}
		cc, err := platform.custom_cursor_create(app.win, pixels, {fp.width, fp.height}, hot * density, density, key, ccfg.image_max_css)
		if err != .None { continue }
		cache_add(app, key, cc)
		return cc
	}
	return 0
}

////////////////////////////////
// Applying it

// The page's cursor at window point `pos` as the window would show it.
@(private = "file")
page_window_cursor :: proc(app: ^App, t: ^Tab, pos: [2]f32) -> Window_Cursor {
	scale := page_scale(app)
	p := pos - app.page_rect.min
	if _, on_bar := scrollbar_at(app, t, p); on_bar { return {keyword = .Arrow} }
	pc := page_cursor_at(&t.layout, t.page.doc, t.page.styled, p, draw.rect_size(app.page_rect), t.scroll, ccfg.page_css)
	wc := Window_Cursor{keyword = pc.keyword, scale = scale, node = pc.node, at = p / scale}
	wc.custom = cursor_image(app, t, pc.images, pos, scale)
	// while the tab loads, the arrow is the arrow with the "working in background" sign (as Chromium does)
	if ccfg.progress_loading && wc.keyword == .Arrow && wc.custom == 0 && tab_loading(t) { wc.keyword = .Progress }
	return wc
}

@(private = "file")
page_tab :: proc(app: ^App) -> ^Tab {
	t := current_tab(app)
	if t == nil || t.kind != .Web || t.page == nil || t.page.doc == nil || t.page.styled == nil || !t.layout.valid { return nil }
	return t
}

// The frame's events, before anything takes them (main.odin): a left press on the page freezes its cursor until the
// release (the chrome's widgets and overlays over the page, as the previous frame laid them out, keep theirs).
page_cursor_events :: proc(app: ^App, events: []platform.Event) {
	for ev in events {
		#partial switch ev.kind {
		case .Mouse_Press:
			if ev.button != .Left || pcs.dragging { continue }
			t := page_tab(app)
			if t == nil || !draw.rect_contains(app.page_rect, ev.pos) || hud_captures(ev.pos) || ui.ctx_menu_any_open() || ui.hot_key() != 0 { continue }
			pcs.frozen = page_window_cursor(app, t, ev.pos)
			pcs.dragging = true
		case .Mouse_Release:
			if ev.button == .Left { pcs.dragging = false }
		}
	}
}

// The window's cursor for this frame (after the chrome's build): the page's over the page area, else the chrome's.
window_cursor_apply :: proc(app: ^App) {
	st := &app.ui_state
	wc := Window_Cursor{keyword = ui.cursor(st)}
	pos := ui.mouse_pos()
	if pcs.dragging && page_tab(app) != nil {
		wc = pcs.frozen
	} else if t := page_tab(app); t != nil && st.mouse_valid && wc.keyword == .Arrow && draw.rect_contains(app.page_rect, pos) &&
	          ui.hot_key() == 0 && ui.active_key() == 0 && !ui.ctx_menu_any_open() && !hud_captures(pos) {
		wc = page_window_cursor(app, t, pos)
	} else if ct := current_tab(app); ct != nil && ct.kind == .Web && ccfg.progress_loading && tab_loading(ct) && st.mouse_valid && wc.keyword == .Arrow &&
	          draw.rect_contains(app.page_rect, pos) && ui.hot_key() == 0 && ui.active_key() == 0 && !ui.ctx_menu_any_open() && !hud_captures(pos) {
		wc.keyword = .Progress   // (nothing laid out yet: a document on its way)
	}
	if wc.custom != 0 && !platform.custom_cursor_valid(app.win, wc.custom) { wc.custom = 0 }
	if wc.custom != 0 {
		platform.set_cursor_custom(app.win, wc.custom, wc.keyword, wc.scale)
	} else {
		platform.set_cursor(app.win, wc.keyword)
	}
	if !pcs.shown_ok || wc.keyword != pcs.shown.keyword || wc.custom != pcs.shown.custom || wc.node != pcs.shown.node {
		if pcs.log_path != "" { cursor_log(app, wc) }
	}
	pcs.shown, pcs.shown_ok = wc, true
}

// A line per change: cursor=<css name> custom=<true|false> node=<tag>#<id> at=<x>,<y> (the page's point in CSS
// pixels; node=- for the chrome's cursor).
@(private = "file")
cursor_log :: proc(app: ^App, wc: Window_Cursor) {
	f, err := os.open(pcs.log_path, {.Write, .Create, .Append}, os.Permissions_Default_File)
	if err != nil { return }
	defer os.close(f)
	node := "-"
	if t := current_tab(app); t != nil && t.page != nil && wc.node != base.NIL_HANDLE {
		if n := dom.get(t.page.doc, wc.node); n != nil {
			id, _ := dom.get_attribute(t.page.doc, wc.node, "id")
			node = fmt.tprintf("%s#%s", n.name, id)
		}
	}
	os.write_string(f, fmt.tprintf("cursor=%s custom=%v node=%s at=%.0f,%.0f\n", platform.cursor_css_name(wc.keyword), wc.custom != 0, node, wc.at.x, wc.at.y))
}

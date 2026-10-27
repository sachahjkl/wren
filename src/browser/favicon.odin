package browser

// Tab icons and tab titles that follow the document.
//
// Favicons: the document's <link rel="icon"> (every rel token list containing "icon": "icon", "shortcut icon"; the
// size closest to the tab's icon at or above it when the links say `sizes`), else /favicon.ico of an http(s) origin, as
// browsers do. The icon is fetched with the page as initiator (destination image, no-cors: its CSP img-src and cookies
// apply, the bytes are never shown to the page), at most browser.tabs.favicon_max_bytes, decoded on the image threads
// (package images: ICO picks its best size, SVG is rasterised at the tab's size), and kept in a small process cache keyed
// by URL (browser.tabs.favicon_cache_entries, least recently drawn first out), so tabs of one site share one texture.
// Built-in pages show the Wren icon, file: pages a file glyph, others a neutral globe until (or unless) their icon comes.
//
// Titles: document.title semantics (the first <title>, ASCII whitespace stripped and collapsed), refreshed when the
// document changed, at most every browser.tabs.title_refresh_ms (a page that mutates every frame does not walk its tree
// every frame); a timer makes sure the last change is seen even when nothing else draws. A page without a title shows
// its address without the scheme, a file its name (default_tab_title), like Chrome.

import "core:strconv"
import "core:strings"
import "toolkit:render"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:page"
import "wb:url"

TAB_PREFS := [?]config.Def{
	{name = "browser.tabs.max_width_em", kind = .Float, default = {f = 15}, bounded = true, min = 4, max = 60, unit = "em",
		description = "Widest a tab of the tab strip gets (tabs share the strip's width up to this)."},
	{name = "browser.tabs.min_width_em", kind = .Float, default = {f = 4.5}, bounded = true, min = 2, max = 30, unit = "em",
		description = "Narrowest a tab gets when there are many. Beyond, the strip scrolls so that the current tab stays visible (mouse wheel over the tabs)."},
	{name = "browser.tabs.close_button_min_em", kind = .Float, default = {f = 7}, bounded = true, min = 0, max = 60, unit = "em",
		description = "Tabs narrower than this show their close button only when they are the current tab or under the pointer (as in Chrome)."},
	{name = "browser.tabs.middle_click_close", kind = .Bool, default = {b = true},
		description = "A middle click on a tab closes it."},
	{name = "browser.tabs.drag_reorder", kind = .Bool, default = {b = true},
		description = "Tabs can be dragged along the strip to reorder them."},
	{name = "browser.tabs.drag_threshold_px", kind = .Float, default = {f = 6}, bounded = true, min = 0, max = 100, unit = "px",
		description = "How far a tab must be dragged (in interface pixels, times the display scale) before it moves."},
	{name = "browser.tabs.drag_detach", kind = .Bool, default = {b = true},
		description = "A tab dragged away from the tab bar (below or above a row of tabs, beside a sidebar) leaves it for a window of its own, and dropped on the tab bar of another window it joins that window, with its page as it is (nothing is loaded again). The menu of a tab and `Move tab to a new window` do the same without the mouse."},
	{name = "browser.tabs.detach_distance_em", kind = .Float, default = {f = 2.5}, bounded = true, min = 0.5, max = 40, unit = "em",
		description = "How far the pointer must go from the tab bar, while a tab is dragged, before the tab leaves it for a window of its own (browser.tabs.drag_detach)."},
	{name = "browser.tabs.favicons", kind = .Bool, default = {b = true},
		description = "Show the icon of the site in its tab (<link rel=icon>, else /favicon.ico). Off: no request is made for icons."},
	{name = "browser.tabs.favicon_fallback_ico", kind = .Bool, default = {b = true},
		description = "When a page names no icon, try /favicon.ico of its origin (http and https only)."},
	{name = "browser.tabs.favicon_max_bytes", kind = .Int, default = {i = 512 << 10}, bounded = true, min = 1 << 10, max = 16 << 20, bytes = true, unit = "bytes",
		description = "Largest icon file downloaded for a tab."},
	{name = "browser.tabs.favicon_max_dimension", kind = .Int, default = {i = 1024}, bounded = true, min = 16, max = 8192, unit = "px",
		description = "Largest width or height of an icon image that is decoded (larger ones are refused)."},
	{name = "browser.tabs.favicon_cache_entries", kind = .Int, default = {i = 128}, bounded = true, min = 4, max = 100_000,
		description = "Icons kept decoded (one texture each, shared by the tabs of a site); the least recently shown go first."},
	{name = "browser.tabs.spinner_fps", kind = .Float, default = {f = 30}, bounded = true, min = 1, max = 240, unit = "Hz",
		description = "How often the loading indicator of a tab turns while the tab loads. Nothing is drawn for it once the load is over."},
	{name = "browser.tabs.spinner_max_s", kind = .Float, default = {f = 120}, bounded = true, min = 0, max = 86_400, unit = "s",
		description = "A tab still loading after this long (a resource that never ends: the load event waits for it) keeps its loading indicator but no longer animates it, so the browser stops drawing for it. 0 = always animate."},
	{name = "browser.tabs.title_refresh_ms", kind = .Int, default = {i = 250}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Tab titles and icons follow changes of the document (document.title, <link rel=icon> added by a script) at most this often."},
}

register_tab_prefs :: proc(p: ^config.Prefs) {
	config.register(p, TAB_PREFS[:])
	config.register(p, SIDEBAR_PREFS[:])   // tab_sidebar.odin
}

Tab_Settings :: struct {
	position:                         Tabs_Position,   // tab_sidebar.odin: the row of tabs, or a sidebar
	side_w, side_collapsed_w:         f32,             // the sidebar's width, wide and icons only (CSS px)
	side_collapsed:                   bool,
	side_row_em:                      f32,
	side_address_min_em:              f32,             // the address field's narrowest in the title bar (sidebar_titlebar)
	max_w_em, min_w_em, close_min_em: f32,
	middle_close, drag_reorder:       bool,
	drag_threshold:                   f32,
	drag_detach:                      bool,
	detach_distance_em:               f32,
	favicons, fallback_ico:           bool,
	icon_max_bytes, icon_max_dim:     int,
	icon_cache:                       int,
	spinner_fps:                      f32,
	spinner_max_ms:                   f64,
	title_refresh_ms:                 f64,
}

tab_settings_from_prefs :: proc(p: ^config.Prefs) -> Tab_Settings {
	return {
		position = tabs_position_of(config.string_of(p, "browser.tabs.position")),
		side_w = f32(config.int_of(p, "browser.tabs.sidebar_width")),
		side_collapsed_w = f32(config.int_of(p, "browser.tabs.sidebar_collapsed_width")),
		side_collapsed = config.bool_of(p, "browser.tabs.sidebar_collapsed"),
		side_row_em = f32(config.float_of(p, "browser.tabs.sidebar_row_em")),
		side_address_min_em = f32(config.float_of(p, "browser.tabs.sidebar_address_min_em")),
		max_w_em = f32(config.float_of(p, "browser.tabs.max_width_em")),
		min_w_em = f32(config.float_of(p, "browser.tabs.min_width_em")),
		close_min_em = f32(config.float_of(p, "browser.tabs.close_button_min_em")),
		middle_close = config.bool_of(p, "browser.tabs.middle_click_close"),
		drag_reorder = config.bool_of(p, "browser.tabs.drag_reorder"),
		drag_threshold = f32(config.float_of(p, "browser.tabs.drag_threshold_px")),
		drag_detach = config.bool_of(p, "browser.tabs.drag_detach"),
		detach_distance_em = f32(config.float_of(p, "browser.tabs.detach_distance_em")),
		favicons = config.bool_of(p, "browser.tabs.favicons"),
		fallback_ico = config.bool_of(p, "browser.tabs.favicon_fallback_ico"),
		icon_max_bytes = int(config.int_of(p, "browser.tabs.favicon_max_bytes")),
		icon_max_dim = int(config.int_of(p, "browser.tabs.favicon_max_dimension")),
		icon_cache = int(config.int_of(p, "browser.tabs.favicon_cache_entries")),
		spinner_fps = f32(config.float_of(p, "browser.tabs.spinner_fps")),
		spinner_max_ms = config.float_of(p, "browser.tabs.spinner_max_s") * 1000,
		title_refresh_ms = f64(config.int_of(p, "browser.tabs.title_refresh_ms")),
	}
}

// What a tab knows of its document's title and icon.
Tab_Icon :: struct {
	page:      rawptr,   // the page `url` and the title were read from (a new page starts over)
	doc:       rawptr,   // ... and its document (adopting a parsed document replaces it; its mutation count starts over)
	mutations: u64,      // its DOM's mutation count then
	read_ms:   f64,      // when (loop clock)
	url:       string,   // owned: the icon's URL, "" = none
	loaded:    bool,     // the page's load event had fired then (a script may have added an icon before it)
}

tab_icon_destroy :: proc(i: ^Tab_Icon) {
	delete(i.url)
	i^ = {}
}

Favicon_State :: enum u8 { Loading, Decoding, Ready, Failed }

Favicon :: struct {
	url:       string,          // owned (the cache's key)
	state:     Favicon_State,
	task:      base.Handle,     // the request while Loading
	scope:     ^base.Scope,     // the navigation scope the request belongs to (its page is the initiator)
	cleanup:   base.Cleanup_Id, // in `scope`: the page closing during the request fails the icon
	job:       images.Job_Id,   // while Decoding (0: none)
	tex:       render.Texture,
	w, h:      int,
	used:      u64,             // frame count when last drawn
}

Favicons :: struct {
	cfg:      Tab_Settings,
	watch:    int,
	entries:  map[string]^Favicon,
	port:     images.Port_Id,
	frame:    u64,
	app:      ^App,
	timer:    base.Handle,   // the title refresh's deadline
	spin:     base.Handle,   // the spinner's next turn
}

favs: Favicons

favicons_init :: proc(app: ^App) {
	favs.app = app
	favs.cfg = tab_settings_from_prefs(&app.prefs)
	favs.entries = make(map[string]^Favicon)
	favs.watch = config.watch(&app.prefs, "browser.tabs.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		favs.cfg = tab_settings_from_prefs(p)
		request_frames((^App)(user), 2)
	}, app)
}

favicons_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, favs.watch)
	if favs.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, favs.timer) }
	if favs.spin != base.NIL_HANDLE { host.clear_timer(&app.loop, favs.spin) }
	if favs.port != 0 { images.port_close(favs.port) }   // jobs not delivered are freed by the image threads
	for _, e in favs.entries { favicon_free(app, e) }
	delete(favs.entries)
	favs = {}
}

@(private = "file")
favicon_free :: proc(app: ^App, e: ^Favicon) {
	if e.task != base.NIL_HANDLE {
		base.forget_cleanup(e.scope, e.cleanup)
		fetch.cancel(&app.loader, e.task)
	}
	images.job_cancel(e.job)
	if e.state == .Ready { render.destroy_texture(&app.r, e.tex) }
	delete(e.url)
	free(e)
}

////////////////////////////////
// Titles and icon links of a document (pure: tests)

// document.title: the first <title>'s text, ASCII whitespace stripped and collapsed.
collapse_title :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	space := false
	for r in s {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\f' {
			space = strings.builder_len(sb) > 0
			continue
		}
		if space { strings.write_byte(&sb, ' '); space = false }
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

// What a tab shows for a page without a title: its address without the scheme (and without the root's "/"), a file's
// name, the address itself for the rest (about:blank, data:...). Like Chrome.
default_tab_title :: proc(address: string, allocator := context.temp_allocator) -> string {
	s := address
	if strings.has_prefix(s, VIEW_SOURCE) { return strings.clone(s, allocator) }
	if i := strings.index_any(s, "#"); i >= 0 { s = s[:i] }
	switch {
	case strings.has_prefix(s, "file:"):
		p := s[len("file:"):]
		if i := strings.index_byte(p, '?'); i >= 0 { p = p[:i] }
		p = strings.trim_left(p, "/")
		trimmed := strings.trim_right(p, "/")
		name := trimmed
		if i := strings.last_index_byte(trimmed, '/'); i >= 0 { name = trimmed[i + 1:] }
		if name == "" { name = p }
		if name == "" { return strings.clone(address, allocator) }
		// a folder keeps its trailing slash (file:///C:/dir/ -> "dir/"), a drive its colon
		if len(trimmed) < len(p) { return strings.concatenate({percent_decode_title(name), "/"}, allocator) }
		return strings.clone(percent_decode_title(name), allocator)
	case strings.has_prefix(s, "http://"), strings.has_prefix(s, "https://"):
		rest := s[strings.index(s, "://") + 3:]
		if strings.has_suffix(rest, "/") && strings.count(rest, "/") == 1 { rest = rest[:len(rest) - 1] }
		return strings.clone(rest, allocator)
	}
	return strings.clone(address, allocator)
}

@(private = "file")
percent_decode_title :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 { return s }
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok { append(&out, u8(v)); i += 2; continue }
		}
		append(&out, s[i])
	}
	return string(out[:])
}

Icon_Link :: struct { href: string, sizes: string, type: string }

// Picks the icon of the tab among the document's icon links: the one whose `sizes` is the smallest at or above `want`
// pixels (else the largest), "any" (scalable) counting as a perfect fit; links without sizes come after those that
// fit and before those too small; between equals the last link wins, as in Chrome. Returns an index into `links`, -1 when there is none.
pick_icon :: proc(links: []Icon_Link, want: int) -> int {
	best, best_score := -1, max(int)
	for l, i in links {
		if l.href == "" { continue }
		score := max(int)
		sizes := l.sizes
		for part in strings.fields_iterator(&sizes) {
			if strings.equal_fold(part, "any") { score = 0; continue }
			x := strings.index_any(part, "xX")
			if x <= 0 { continue }
			w, okw := strconv.parse_int(part[:x])
			h, okh := strconv.parse_int(part[x + 1:])
			if !okw || !okh || w <= 0 || h <= 0 { continue }
			sz := max(w, h)
			s := sz >= want ? sz - want : (1 << 16) + (want - sz)   // too small: after all those that are large enough
			score = min(score, s)
		}
		if score == max(int) { score = 1 << 15 }   // no usable size: after the links large enough, before those too small (an .ico usually has several)
		if score <= best_score { best, best_score = i, score }   // ties: the later link
	}
	return best
}

// Whether a rel attribute names an icon (its token list contains "icon", ASCII case-insensitive).
rel_is_icon :: proc(rel: string) -> bool {
	r := rel
	for tok in strings.fields_iterator(&r) { if strings.equal_fold(tok, "icon") { return true } }
	return false
}

// The icon links of `p`'s document (children of <head>, in tree order).
@(private = "file")
icon_links :: proc(p: ^page.Page) -> []Icon_Link {
	out := make([dynamic]Icon_Link, context.temp_allocator)
	d := p.doc
	head := p.head
	if head == base.NIL_HANDLE { head = dom.find_first_by_tag(d, "head") }
	hn := dom.get(d, head)
	if hn == nil { return nil }
	for c := hn.first_child; c != base.NIL_HANDLE; {
		n := dom.get(d, c)
		if n == nil { break }
		if n.kind == .Element && n.name == "link" {
			if rel, ok := dom.get_attribute(d, c, "rel"); ok && rel_is_icon(rel) {
				href, _ := dom.get_attribute(d, c, "href")
				sizes, _ := dom.get_attribute(d, c, "sizes")
				ty, _ := dom.get_attribute(d, c, "type")
				append(&out, Icon_Link{strings.trim_space(href), sizes, ty})
			}
		}
		c = n.next
	}
	return out[:]
}

// The icon URL of `t`'s page ("" = none).
@(private = "file")
icon_url_of :: proc(t: ^Tab, want: int) -> string {
	p := t.page
	scheme := p.env.location.scheme
	if scheme == "about" || scheme == "file" || scheme == "data" || strings.has_prefix(t.url, VIEW_SOURCE) { return "" }
	links := icon_links(p)
	if i := pick_icon(links, want); i >= 0 {
		if u, ok := url.parse(links[i].href, &p.env.location, context.temp_allocator); ok && (u.scheme == "http" || u.scheme == "https" || u.scheme == "data") {
			return u.href
		}
	}
	if favs.cfg.fallback_ico && (scheme == "http" || scheme == "https") {
		return strings.concatenate({url.origin_serialize(p.env.origin, context.temp_allocator), "/favicon.ico"}, context.temp_allocator)
	}
	return ""
}

////////////////////////////////
// Per frame

// The tab's title and icon from its document, when the document changed (throttled). `icon_px`: the size drawn.
tab_refresh :: proc(app: ^App, t: ^Tab, icon_px: int) {
	p := t.page
	if t.kind != .Web || p == nil || strings.has_prefix(t.url, VIEW_SOURCE) {
		if t.icon.page != nil || t.icon.url != "" { tab_icon_destroy(&t.icon) }
		return
	}
	if !p.render.adopted { return }   // no document yet (the parse runs on a thread)
	loaded := p.scripts != nil && p.scripts.loaded
	same := rawptr(p) == t.icon.page && rawptr(p.doc) == t.icon.doc
	if same && p.doc.mutations == t.icon.mutations && loaded == t.icon.loaded { return }
	now := f64(host.now_ns(&app.loop)) / 1e6
	if same && now - t.icon.read_ms < favs.cfg.title_refresh_ms {
		title_wake(app, t.icon.read_ms + favs.cfg.title_refresh_ms - now)
		return
	}
	t.icon.page, t.icon.doc, t.icon.mutations, t.icon.read_ms, t.icon.loaded = p, p.doc, p.doc.mutations, now, loaded

	title := ""
	if el := dom.find_first_by_tag(p.doc, "title"); el != base.NIL_HANDLE { title = collapse_title(dom.text_content(p.doc, el)) }
	if title == "" { title = default_tab_title(t.url) }
	if title != t.title { delete(t.title); t.title = strings.clone(title) }

	icon := favs.cfg.favicons ? icon_url_of(t, icon_px) : ""
	if icon != t.icon.url {
		delete(t.icon.url)
		t.icon.url = strings.clone(icon)
	}
	if icon != "" { favicon_request(app, t, icon) }
	history_title_seen(app, t)   // the entry and the browsing history take the title and icon (history_ui.odin)
}

@(private = "file")
title_wake :: proc(app: ^App, ms: f64) {
	if favs.timer != base.NIL_HANDLE { return }
	favs.timer = host.set_timer(&app.loop, max(ms, 1), 0, proc(data: rawptr) {
		favs.timer = base.NIL_HANDLE
		a := (^App)(data)
		request_frames(a, 1)
	}, app)
}

// The loading indicators turn: one wake per turn while a tab loads, none once it is over.
spinner_wake :: proc(app: ^App) {
	if favs.spin != base.NIL_HANDLE { return }
	favs.spin = host.set_timer(&app.loop, f64(1000 / max(favs.cfg.spinner_fps, 1)), 0, proc(data: rawptr) {
		favs.spin = base.NIL_HANDLE
		a := (^App)(data)
		request_frames(a, 1)
	}, app)
}

// The icon at `address` if it is ready to draw (marks it used).
favicon_texture :: proc(address: string) -> (tex: render.Texture, ok: bool) {
	e := favs.entries[address]
	if e == nil || e.state != .Ready { return {}, false }
	e.used = favs.frame
	return e.tex, true
}

favicon_frame :: proc() { favs.frame += 1 }

@(private = "file")
favicon_request :: proc(app: ^App, t: ^Tab, address: string) {
	if address in favs.entries { return }
	favicon_evict(app)
	e := new(Favicon)
	e.url = strings.clone(address)
	e.used = favs.frame
	favs.entries[e.url] = e
	e.scope = t.nav
	e.task = fetch.start(&app.loader, {
		request = {
			url = address, mode = .No_Cors, credentials = .Include, redirect = .Follow, destination = .Image,
			initiator = &t.page.env, max_body = favs.cfg.icon_max_bytes,
		},
		on_event = favicon_event, user = e, scope = t.nav, collect = true,
	})
	// the page going away cancels the request silently: the entry goes too (another page will ask again)
	e.cleanup = base.on_close(t.nav, proc(data: rawptr) {
		f := (^Favicon)(data)
		delete_key(&favs.entries, f.url)
		delete(f.url)
		free(f)
	}, e)
}

@(private = "file")
favicon_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	e := (^Favicon)(user)
	app := favs.app
	#partial switch ev.kind {
	case .Done:
		base.forget_cleanup(e.scope, e.cleanup)
		e.task, e.scope = base.NIL_HANDLE, nil
		if len(ev.data) == 0 { e.state = .Failed; return }
		if !images.decoder_running() {
			s := &app.page_settings.images
			n := s.decode_threads
			if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
			images.decoder_start(n, s.decode_stack_bytes > 0 ? s.decode_stack_bytes : images.DECODER_STACK_DEFAULT, s.decode_idle_ms)
		}
		if favs.port == 0 { favs.port = images.port_open(&app.loop, favicon_decoded, nil) }
		if favs.port == 0 { e.state = .Failed; return }
		bytes := make([]byte, len(ev.data))
		copy(bytes, ev.data)
		blob := images.blob_make(bytes)
		defer images.blob_release(blob)
		lim := app.page_settings.images.limits
		lim.max_dimension = min(lim.max_dimension, favs.cfg.icon_max_dim)
		lim.max_pixels = min(lim.max_pixels, i64(favs.cfg.icon_max_dim) * i64(favs.cfg.icon_max_dim))
		lim.max_encoded_bytes = min(lim.max_encoded_bytes, favs.cfg.icon_max_bytes)
		px := tab_icon_px(app)
		opts := images.Decode_Options{limits = lim, target_w = px, target_h = px, downscale_below = 0.99, first_frame_only = true}
		e.state = .Decoding
		e.job = images.submit(favs.port, images.job_make(.Decode, blob, opts, user = e))
		if e.job == 0 { e.state = .Failed }
	case .Failed:
		base.forget_cleanup(e.scope, e.cleanup)
		e.task, e.scope = base.NIL_HANDLE, nil
		e.state = .Failed
	}
}

@(private = "file")
favicon_decoded :: proc(user: rawptr, j: ^images.Job) {
	defer images.job_free(j)
	e := (^Favicon)(j.user)
	app := favs.app
	e.job = 0
	img := j.image
	if j.err != .None || img == nil || len(img.frames) == 0 || img.width <= 0 || img.height <= 0 { e.state = .Failed; return }
	e.tex = render.create_texture_rgba(&app.r, img.width, img.height)
	render.update_texture_rgba(&app.r, e.tex, 0, 0, img.width, img.height, img.frames[0].pixels, img.stride)
	e.w, e.h = img.width, img.height
	e.state = .Ready
	request_frames(app, 2)
}

// Room for one more entry: the least recently drawn ones go (never one still loading or decoding).
@(private = "file")
favicon_evict :: proc(app: ^App) {
	for len(favs.entries) >= favs.cfg.icon_cache {
		oldest: ^Favicon
		for _, e in favs.entries {
			if e.state == .Loading || e.state == .Decoding { continue }
			if oldest == nil || e.used < oldest.used { oldest = e }
		}
		if oldest == nil { return }
		delete_key(&favs.entries, oldest.url)
		favicon_free(app, oldest)
	}
}

// Size of a tab's icon in physical pixels.
tab_icon_px :: proc(app: ^App) -> int { return int(16 * ui_scale_of(app) + 0.5) }

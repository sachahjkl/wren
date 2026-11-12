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
// The icon of a site that no tab shows (the address bar's suggestions, bookmarks, the Vault) comes from
// favicon_of_url, which keeps the icons in the profile too (favicon_cache.odin).
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
	{name = "browser.tabs.close_window_with_last_tab", kind = .Bool, default = {b = true},
		description = "Closing the last tab of the last window (Ctrl+W, its close button, a middle click, the tab's menu) closes Wren. Off: a new tab opens in its place."},
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
	{name = "browser.tabs.favicon_disk_max_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 0, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Icons of sites kept in the profile (its favicons folder), so that the address bar's suggestions, the bookmarks and the Vault show them without asking the sites again. The least recently refreshed go first beyond this size. 0: none kept."},
	{name = "browser.tabs.favicon_disk_days", kind = .Int, default = {i = 30}, bounded = true, min = 1, max = 3650, unit = "days",
		description = "An icon kept in the profile and not refreshed for this long is asked from its site again. A visit of the site refreshes it."},
	{name = "browser.tabs.spinner_fps", kind = .Float, default = {f = 30}, bounded = true, min = 1, max = 240, unit = "Hz",
		description = "How often the loading indicators move while a tab loads: the icon of its tab, and the bar along the top of a page not painted yet. Nothing is drawn for them once the load is over."},
	{name = "browser.tabs.spinner_max_s", kind = .Float, default = {f = 120}, bounded = true, min = 0, max = 86_400, unit = "s",
		description = "A tab still loading after this long (a resource that never ends: the load event waits for it) keeps its loading indicator but no longer animates it, so the browser stops drawing for it. 0 = always animate."},
	{name = "browser.tabs.title_refresh_ms", kind = .Int, default = {i = 250}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Tab titles and icons follow changes of the document (document.title, <link rel=icon> added by a script) at most this often."},
}

// The tabs' preferences make the Tabs category of about:config (their names stay browser.tabs.*).
register_tab_prefs :: proc(p: ^config.Prefs) {
	config.register(p, TAB_PREFS[:], "tabs")
	config.register(p, SIDEBAR_PREFS[:], "tabs")   // tab_sidebar.odin
	config.register(p, TAB_GROUP_PREFS[:], "tabs")   // tab_groups.odin
	config.register(p, TAB_SOUND_PREFS[:], "tabs")   // tab_sound.odin
}

Tab_Settings :: struct {
	position:                         Tabs_Position,   // tab_sidebar.odin: the row of tabs, or a sidebar
	side_w, side_collapsed_w:         f32,             // the sidebar's width, wide and icons only (CSS px)
	side_collapsed:                   bool,
	side_anim_ms:                     f32,             // opening and closing the sidebar (0: at once)
	side_pins_max:                    f32,             // the share of the window's height the pinned tabs take at most
	side_row_em:                      f32,
	side_address_min_em:              f32,             // the address field's narrowest in the title bar (sidebar_titlebar)
	max_w_em, min_w_em, close_min_em: f32,
	middle_close, drag_reorder:       bool,
	close_with_last_tab:              bool,
	drag_threshold:                   f32,
	drag_detach:                      bool,
	detach_distance_em:               f32,
	favicons, fallback_ico:           bool,
	icon_max_bytes, icon_max_dim:     int,
	icon_cache:                       int,
	icon_disk_max:                    int,   // bytes of icons kept in the profile (0: none)
	icon_disk_days:                   int,
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
		side_anim_ms = f32(config.int_of(p, "browser.tabs.sidebar_animation_ms")),
		side_pins_max = f32(config.float_of(p, "browser.tabs.sidebar_pins_max")),
		side_row_em = f32(config.float_of(p, "browser.tabs.sidebar_row_em")),
		side_address_min_em = f32(config.float_of(p, "browser.tabs.sidebar_address_min_em")),
		max_w_em = f32(config.float_of(p, "browser.tabs.max_width_em")),
		min_w_em = f32(config.float_of(p, "browser.tabs.min_width_em")),
		close_min_em = f32(config.float_of(p, "browser.tabs.close_button_min_em")),
		middle_close = config.bool_of(p, "browser.tabs.middle_click_close"),
		close_with_last_tab = config.bool_of(p, "browser.tabs.close_window_with_last_tab"),
		drag_reorder = config.bool_of(p, "browser.tabs.drag_reorder"),
		drag_threshold = f32(config.float_of(p, "browser.tabs.drag_threshold_px")),
		drag_detach = config.bool_of(p, "browser.tabs.drag_detach"),
		detach_distance_em = f32(config.float_of(p, "browser.tabs.detach_distance_em")),
		favicons = config.bool_of(p, "browser.tabs.favicons"),
		fallback_ico = config.bool_of(p, "browser.tabs.favicon_fallback_ico"),
		icon_max_bytes = int(config.int_of(p, "browser.tabs.favicon_max_bytes")),
		icon_max_dim = int(config.int_of(p, "browser.tabs.favicon_max_dimension")),
		icon_cache = int(config.int_of(p, "browser.tabs.favicon_cache_entries")),
		icon_disk_max = int(config.int_of(p, "browser.tabs.favicon_disk_max_bytes")),
		icon_disk_days = int(config.int_of(p, "browser.tabs.favicon_disk_days")),
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
	title_el:  base.Handle,   // the <title> the title was read from, looked for again only once it left the document
}

tab_icon_destroy :: proc(i: ^Tab_Icon) {
	delete(i.url)
	i^ = {}
}

Favicon_State :: enum u8 { Loading, Decoding, Ready, Failed }

Favicon :: struct {
	app:       ^App,            // whose cache it is (what its request and decoding report to)
	url:       string,          // owned (the cache's key)
	state:     Favicon_State,
	task:      base.Handle,     // the request while Loading
	scope:     ^base.Scope,     // the navigation scope the request belongs to (its page is the initiator)
	cleanup:   base.Cleanup_Id, // in `scope`: the page closing during the request fails the icon
	job:       images.Job_Id,   // while Decoding (0: none)
	tex:       render.Texture,
	w, h:      int,
	used:      u64,             // frame count when last drawn
	nav:       rawptr,          // the navigation (scope) that asked for it: a Failed icon is asked for again by another one
	px:        int,             // the size it was decoded for (the largest of the windows' scales then)
	blob:      ^images.Blob,    // its bytes (small: browser.tabs.icon_max_bytes), decoded again when a window's scale grows past `px`
	origin:    string,          // owned: the site whose icon it is, stored in the profile once it decodes ("": not stored)
}

Favicons :: struct {
	cfg:      Tab_Settings,
	watch:    int,
	entries:  map[string]^Favicon,
	sites:    map[string]^Favicon_Site,   // favicon_cache.odin: the icon of each site asked for, keys its origin
	disk:     Favicon_Disk,               // favicon_cache.odin: the reads and writes of the profile's favicons folder
	port:     images.Port_Id,
	frame:    u64,
	decode_px: int,          // favicon_decode_px of this frame (favicon_frame: not counted again for every tab)
	timer:    base.Handle,   // the title refresh's deadline
	spin:     base.Handle,   // the spinner's next turn
}

favicons_init :: proc(app: ^App) {
	app.favs.cfg = tab_settings_from_prefs(&app.prefs)
	app.favs.entries = make(map[string]^Favicon)
	app.favs.sites = make(map[string]^Favicon_Site)
	app.favs.watch = config.watch(&app.prefs, "browser.tabs.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		app.favs.cfg = tab_settings_from_prefs(p)
		request_frames(app, 2)
	}, app)
}

favicons_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, app.favs.watch)
	if app.favs.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.favs.timer) }
	if app.favs.spin != base.NIL_HANDLE { host.clear_timer(&app.loop, app.favs.spin) }
	favicon_cache_destroy(app)   // (first: a disk job that ends now can still make an entry)
	if app.favs.port != 0 { images.port_close(app.favs.port) }   // jobs not delivered are freed by the image threads
	for _, e in app.favs.entries { favicon_free(app, e) }
	delete(app.favs.entries)
	app.favs = {}
}

favicon_free :: proc(app: ^App, e: ^Favicon) {
	if e.task != base.NIL_HANDLE {
		if e.scope != nil { base.forget_cleanup(e.scope, e.cleanup) }
		fetch.cancel(&app.loader, e.task)
	}
	images.job_cancel(e.job)
	if e.tex != 0 { render.destroy_texture(&app.r, e.tex) }
	if e.blob != nil { images.blob_release(e.blob) }
	delete(e.url)
	delete(e.origin)
	free(e)
}

// Takes `e` out of the cache and frees it.
favicon_forget :: proc(app: ^App, e: ^Favicon) {
	delete_key(&app.favs.entries, e.url)
	favicon_free(app, e)
}

// A new entry for the icon at `address`, in the cache (room made first), waiting for its bytes.
favicon_entry_make :: proc(app: ^App, address: string) -> ^Favicon {
	favicon_evict(app)
	e := new(Favicon)
	e.app = app
	e.url = strings.clone(address)
	e.used = app.favs.frame
	app.favs.entries[e.url] = e
	return e
}

// The request of an icon that no page asks for (a site's, favicon_cache.odin): the browser's own, without cookies, its
// page's rules (no initiator) and scope. False: no request left.
favicon_fetch :: proc(app: ^App, e: ^Favicon) -> bool {
	if app.favs.disk.offline { app.favs.disk.fetches += 1; return true }   // (unit tests: the entry stays Loading)
	e.task = fetch.start(&app.loader, {
		request = {url = e.url, mode = .No_Cors, credentials = .Omit, redirect = .Follow, destination = .Image, max_body = app.favs.cfg.icon_max_bytes},
		on_event = favicon_event, user = e, collect = true,
	})
	return e.task != base.NIL_HANDLE
}

// The icon's bytes came (from the network or from the profile; copied): decoded on the image threads.
favicon_take_bytes :: proc(app: ^App, e: ^Favicon, data: []byte) {
	if len(data) == 0 || len(data) > app.favs.cfg.icon_max_bytes { e.state = .Failed; return }
	bytes := make([]byte, len(data))
	copy(bytes, data)
	e.blob = images.blob_make(bytes)   // (kept: decoded again for a window of a larger scale)
	e.state = .Decoding
	if app.favs.disk.hold_decode { return }   // (unit tests: no image threads)
	if !images.decoder_running() {
		s := &app.page_settings.images
		n := s.decode_threads
		if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
		images.decoder_start(n, s.decode_stack_bytes > 0 ? s.decode_stack_bytes : images.DECODER_STACK_DEFAULT, s.decode_idle_ms)
	}
	if app.favs.port == 0 { app.favs.port = images.port_open(&app.loop, favicon_decoded, nil) }
	if app.favs.port == 0 { e.state = .Failed; return }
	favicon_decode(app, e, favicon_decode_px(app))
	if e.job == 0 { e.state = .Failed }
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
		if len(trimmed) < len(p) { return strings.concatenate({url.percent_decode(name), "/"}, allocator) }
		return strings.clone(url.percent_decode(name), allocator)
	case strings.has_prefix(s, "http://"), strings.has_prefix(s, "https://"):
		rest := s[strings.index(s, "://") + 3:]
		if strings.has_suffix(rest, "/") && strings.count(rest, "/") == 1 { rest = rest[:len(rest) - 1] }
		return strings.clone(rest, allocator)
	}
	return strings.clone(address, allocator)
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
			if base.ascii_equal_fold(part, "any") { score = 0; continue }
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
	for tok in strings.fields_iterator(&r) { if base.ascii_equal_fold(tok, "icon") { return true } }
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
icon_url_of :: proc(app: ^App, t: ^Tab, want: int) -> string {
	p := t.page
	scheme := p.env.location.scheme
	if scheme == "about" || scheme == "file" || scheme == "data" || strings.has_prefix(t.url, VIEW_SOURCE) { return "" }
	links := icon_links(p)
	if i := pick_icon(links, want); i >= 0 {
		if u, ok := url.parse(links[i].href, &p.env.location, context.temp_allocator); ok && (u.scheme == "http" || u.scheme == "https" || u.scheme == "data") {
			return u.href
		}
	}
	if app.favs.cfg.fallback_ico && (scheme == "http" || scheme == "https") {
		return strings.concatenate({url.origin_serialize(p.env.origin, context.temp_allocator), "/favicon.ico"}, context.temp_allocator)
	}
	return ""
}

////////////////////////////////
// Per frame

// The tab's title and icon from its document, when the document changed (throttled). `icon_px`: the size drawn. true:
// the title or the icon changed (what the tab shows).
tab_refresh :: proc(app: ^App, t: ^Tab, icon_px: int) -> (changed: bool) {
	p := t.page
	if t.kind != .Web || p == nil || strings.has_prefix(t.url, VIEW_SOURCE) {
		if t.icon.page != nil || t.icon.url != "" { tab_icon_destroy(&t.icon); return true }
		return false
	}
	if !p.render.adopted { return false }   // no document yet (the parse runs on a thread)
	loaded := p.scripts != nil && p.scripts.phase == .Complete
	same := rawptr(p) == t.icon.page && rawptr(p.doc) == t.icon.doc
	if same && p.doc.mutations == t.icon.mutations && loaded == t.icon.loaded { return false }
	now := f64(host.now_ns(&app.loop)) / 1e6
	if same && now - t.icon.read_ms < app.favs.cfg.title_refresh_ms {
		title_wake(app, t.icon.read_ms + app.favs.cfg.title_refresh_ms - now)
		return false
	}
	if !same { t.icon.title_el = base.NIL_HANDLE }
	t.icon.page, t.icon.doc, t.icon.mutations, t.icon.read_ms, t.icon.loaded = p, p.doc, p.doc.mutations, now, loaded

	// the <title> read last, while it is still one in the document: a page that mutates all the time does not walk its
	// tree for it at each refresh (a <title> put before it later is not seen until this one goes)
	el := t.icon.title_el
	if n := dom.get(p.doc, el); n == nil || n.kind != .Element || n.name != "title" || !dom.is_connected(p.doc, el) {
		el = dom.find_first_by_tag(p.doc, "title")
		t.icon.title_el = el
	}
	title := ""
	if el != base.NIL_HANDLE { title = collapse_title(dom.text_content(p.doc, el)) }
	if title == "" { title = default_tab_title(t.url) }
	if title != t.title { delete(t.title); t.title = strings.clone(title); changed = true }

	icon := app.favs.cfg.favicons ? icon_url_of(app, t, icon_px) : ""
	if icon != t.icon.url {
		delete(t.icon.url)
		t.icon.url = strings.clone(icon)
		changed = true
	}
	if icon != "" { favicon_request(app, t, icon) }
	history_title_seen(app, t)   // the entry and the browsing history take the title and icon (history_ui.odin)
	return
}

// The refresh a throttled change waits for: done here, by the timer, and a frame only for a window whose tab changed
// (a page that mutates every frame draws its own frames; one that changed something else than its title draws none).
@(private = "file")
title_wake :: proc(app: ^App, ms: f64) {
	if app.favs.timer != base.NIL_HANDLE { return }
	app.favs.timer = host.set_timer(&app.loop, max(ms, 1), 0, proc(data: rawptr) {
		app := (^App)(data)
		app.favs.timer = base.NIL_HANDLE
		host.quiet_note(&app.loop)   // (what it changes asks for its own frame)
		px := favicon_decode_px(app)
		for w in app.windows {
			for t in w.tabs { if tab_refresh(app, t, px) { window_request(app, w, 1) } }
		}
		if len(app.windows) == 0 {
			for t in app.bare.tabs { if tab_refresh(app, t, px) { window_request(app, &app.bare, 1) } }
		}
	}, app)
}

// The loading indicators turn: one wake per turn while a tab loads, none once it is over.
spinner_wake :: proc(app: ^App) {
	if app.favs.spin != base.NIL_HANDLE { return }
	app.favs.spin = host.set_timer(&app.loop, f64(1000 / max(app.favs.cfg.spinner_fps, 1)), 0, proc(data: rawptr) {
		app := (^App)(data)
		app.favs.spin = base.NIL_HANDLE
		host.quiet_note(&app.loop)   // (the one frame it asks for, not the two of a task)
		request_frames(app, 1)
	}, app)
}

// The icon at `address` if it is ready to draw (marks it used).
favicon_texture :: proc(app: ^App, address: string) -> (tex: render.Texture, ok: bool) {
	e := app.favs.entries[address]
	if e == nil || e.state != .Ready { return {}, false }
	e.used = app.favs.frame
	// a window's scale grew past what it was decoded for (it moved to another monitor): decoded again at that size, the picture it
	// has drawn meanwhile
	if e.job == 0 && e.blob != nil && app.favs.port != 0 && app.favs.decode_px > e.px { favicon_decode(app, e, app.favs.decode_px) }
	return e.tex, true
}

@(private = "file")
favicon_decode :: proc(app: ^App, e: ^Favicon, px: int) {
	lim := app.page_settings.images.limits
	lim.max_dimension = min(lim.max_dimension, app.favs.cfg.icon_max_dim)
	lim.max_pixels = min(lim.max_pixels, i64(app.favs.cfg.icon_max_dim) * i64(app.favs.cfg.icon_max_dim))
	lim.max_encoded_bytes = min(lim.max_encoded_bytes, app.favs.cfg.icon_max_bytes)
	opts := images.Decode_Options{limits = lim, target_w = px, target_h = px, downscale_below = 0.99, first_frame_only = true}
	e.px = px
	e.job = images.submit(app.favs.port, images.job_make(.Decode, e.blob, opts, user = e))
}

favicon_frame :: proc(app: ^App) {
	app.favs.frame += 1
	app.favs.decode_px = favicon_decode_px(app)
}

@(private = "file")
favicon_request :: proc(app: ^App, t: ^Tab, address: string) {
	// (the page's site takes the icon: the suggestions and the Vault show it, and the profile keeps it)
	origin := favicon_origin(t.page.env.location.href, context.temp_allocator)
	if old := app.favs.entries[address]; old != nil {
		// an icon that failed is asked for again by the next navigation that names it (the site may have been down), not
		// by every refresh of the same one
		if old.state != .Failed || old.nav == rawptr(t.nav) { favicon_site_seen(app, origin, old); return }
		favicon_forget(app, old)
	}
	e := favicon_entry_make(app, address)
	e.nav = t.nav
	if origin != "" { e.origin = strings.clone(origin) }
	favicon_site_seen(app, origin, e)
	e.scope = t.nav
	e.task = fetch.start(&app.loader, {
		request = {
			url = address, mode = .No_Cors, credentials = .Include, redirect = .Follow, destination = .Image,
			initiator = &t.page.env, max_body = app.favs.cfg.icon_max_bytes,
		},
		on_event = favicon_event, user = e, scope = t.nav, collect = true,
	})
	// the page going away cancels the request silently: the entry goes too (another page will ask again)
	e.cleanup = base.on_close(t.nav, proc(data: rawptr) {
		f := (^Favicon)(data)
		delete_key(&f.app.favs.entries, f.url)
		delete(f.url)
		delete(f.origin)
		free(f)
	}, e)
}

@(private = "file")
favicon_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	e := (^Favicon)(user)
	app := e.app
	#partial switch ev.kind {
	case .Done:
		if e.scope != nil { base.forget_cleanup(e.scope, e.cleanup) }
		e.task, e.scope = base.NIL_HANDLE, nil
		favicon_take_bytes(app, e, ev.data)
	case .Failed:
		if e.scope != nil { base.forget_cleanup(e.scope, e.cleanup) }
		e.task, e.scope = base.NIL_HANDLE, nil
		e.state = .Failed
		if e.origin != "" { request_frames(app, 1) }   // (the site's next candidate is asked by the next frame that draws it)
	}
}

@(private = "file")
favicon_decoded :: proc(user: rawptr, j: ^images.Job) {
	defer images.job_free(j)
	e := (^Favicon)(j.user)
	app := e.app
	e.job = 0
	img := j.image
	if j.err != .None || img == nil || len(img.frames) == 0 || img.width <= 0 || img.height <= 0 {
		if e.state != .Ready {
			e.state = .Failed   // (a decode again at another size that failed: the picture it had stays)
			if e.origin != "" { request_frames(app, 1) }   // (the site's next candidate)
		}
		return
	}
	if e.tex != 0 { render.destroy_texture(&app.r, e.tex) }   // (decoded again at a larger size)
	e.tex = render.create_texture_rgba(&app.r, img.width, img.height)
	render.update_texture_rgba(&app.r, e.tex, 0, 0, img.width, img.height, img.frames[0].pixels, img.stride)
	e.w, e.h = img.width, img.height
	e.state = .Ready
	// (only an icon that decodes is kept in the profile: a page that names an HTML page as its icon stores nothing)
	if e.origin != "" && e.blob != nil {
		favicon_disk_store(app, e.origin, e.url, e.blob.bytes)
		delete(e.origin)
		e.origin = ""
	}
	request_frames(app, 2)
}

// Room for one more entry: the least recently drawn ones go (never one still loading or decoding, nor one a tab shows:
// the tabs out of view are not drawn, and their icons are not marked at each frame for it).
favicon_evict :: proc(app: ^App) {
	if len(app.favs.entries) < app.favs.cfg.icon_cache { return }
	in_use := make(map[string]struct{}, len(app.tab_ids), context.temp_allocator)
	for _, t in app.tab_ids { if t.icon.url != "" { in_use[t.icon.url] = {} } }
	for len(app.favs.entries) >= app.favs.cfg.icon_cache {
		oldest: ^Favicon
		for _, e in app.favs.entries {
			if e.state == .Loading || e.state == .Decoding || e.url in in_use { continue }
			if oldest == nil || e.used < oldest.used { oldest = e }
		}
		if oldest == nil { return }
		delete_key(&app.favs.entries, oldest.url)
		favicon_free(app, oldest)
	}
}

// Size of a tab's icon in physical pixels (in the active window).
tab_icon_px :: proc(app: ^App) -> int { return int(16 * ui_scale_of(app) + 0.5) }

// The size icons are decoded at: the largest scale of the windows (an icon is the process's, drawn in any window: smaller in one
// of a lower scale rather than blurred in one of a higher).
favicon_decode_px :: proc(app: ^App) -> int {
	sc := ui_scale_of(app)
	for w in app.windows { sc = max(sc, ui_scale_of(app, w.win)) }
	return int(16 * sc + 0.5)
}

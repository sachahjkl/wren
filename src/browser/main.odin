// Wasm-first browser shell. The chrome (tabs, address bar, console strip) is built with gui_toolkit's `ui`; the page is a
// custom-draw box painted from the DOM. Everything a tab starts lives in the tab's scope: closing a tab is one call.
//
// Every load goes through the policy layer (package fetch): the main document, its Wasm modules (in document order), and
// whatever the modules fetch afterwards. The profile (cookies, HSTS) is loaded at start-up and saved as it changes.
package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:http"
import "wb:net"
import "wb:page"
import "wb:url"
import "wb:wasm"

DEBUG_INPUT :: #config(DEBUG_INPUT, false)

debug_log :: proc(s: string) {
	f, err := os.open("build/debug.log", {.Write, .Create, .Append}, os.Permissions_Default_File)
	if err != nil { return }
	defer os.close(f)
	os.write_string(f, s)
	os.write_string(f, "\n")
}

Script_State :: enum u8 { Pending, Ready, Failed, Done }

// One <script type="application/wasm">: fetched concurrently, run in document order.
Script_Slot :: struct {
	load:  ^Doc_Load,
	url:   string,
	state: Script_State,
	bytes: [dynamic]byte,
}

// The state of one navigation, from request to the last module. It lives in the navigation scope.
Doc_Load :: struct {
	tab:        ^Tab,
	initiator:  fetch.Environment,      // who asked (a clone: the old page may already be gone)
	has_initiator: bool,
	page:       ^page.Page,
	status:     int,
	mime:       string,                  // essence
	charset:    string,
	final_url:  string,
	slots:      [dynamic]^Script_Slot,
	next_run:   int,
}

Tab_Kind :: enum u8 { Web, Config }

Tab :: struct {
	kind:     Tab_Kind,      // a web page, or the about:config view
	scope:    ^base.Scope,   // lives as long as the tab
	nav:      ^base.Scope,   // lives as long as the current navigation: the page and everything it started
	page:     ^page.Page,
	load:     ^Doc_Load,
	url:      string,
	title:    string,
	status:   string,
	console:  [dynamic]string,
	layout:   Layout,
	scroll:   f32,
}

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	theme:    ui.Theme,
	ui_font:  font.Font_Id,
	icons:    font.Font_Id,

	loop:     host.Loop,
	client:   net.Client,
	blocking: host.Blocking_Pool,
	prefs:    config.Prefs,   // every tunable of the browser (about:config)
	cfg:      Settings,       // the shell's own, derived from prefs
	page_settings: page.Settings,
	config_view:   Config_View,
	autosave_timer: base.Handle,
	profile:  fetch.Profile,
	loader:   fetch.Loader,
	profile_dir: string,
	process:  ^base.Scope,

	tabs:     [dynamic]^Tab,
	current:  int,
	address:  ui.Text_Field,

	page_rect: draw.Rect,   // where the page was painted last frame (physical pixels)
	frames_requested: int,
	last_tick:        time.Tick,
}

the_app: ^App

clip_get :: proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(the_app.win, text) }

current_tab :: proc(app: ^App) -> ^Tab { return len(app.tabs) > 0 ? app.tabs[app.current] : nil }

////////////////////////////////
// Tabs

tab_open :: proc(app: ^App, address := "") -> ^Tab {
	t := new(Tab)
	t.scope = base.scope_make("tab", app.process)
	t.title = strings.clone("New tab")
	append(&app.tabs, t)
	app.current = len(app.tabs) - 1
	ui.field_set(&app.address, address)
	navigate(app, t, address)   // an empty address opens the homepage
	return t
}

tab_close :: proc(app: ^App, index: int) {
	t := app.tabs[index]
	ordered_remove(&app.tabs, index)
	base.scope_close(t.scope)   // page, instances, DOM, requests, timers: all gone
	delete(t.url); delete(t.title); delete(t.status)
	for l in t.console { delete(l) }
	delete(t.console)
	layout_destroy(&t.layout)
	free(t)
	if len(app.tabs) == 0 { tab_open(app) } else { app.current = clamp(app.current, 0, len(app.tabs) - 1) }
	if cur := current_tab(app); cur != nil { ui.field_set(&app.address, cur.url) }
}

tab_log :: proc(t: ^Tab, level: page.Log_Level, message: string) {
	prefix := level == .Error ? "error: " : level == .Warn ? "warn: " : ""
	append(&t.console, fmt.aprintf("%s%s", prefix, message))
	for len(t.console) > the_app.cfg.console_max_lines {
		delete(t.console[0])
		ordered_remove(&t.console, 0)
	}
}

console_sink :: proc(user: rawptr, level: page.Log_Level, message: string) {
	tab_log((^Tab)(user), level, message)
}

set_status :: proc(t: ^Tab, s: string) {
	delete(t.status)
	t.status = strings.clone(s)
}

// Last path segment, or the host: a stand-in until the page has a <title>.
title_from_url :: proc(u: string) -> string {
	s := u
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] }
	s = strings.trim_right(s, "/\\")
	if i := strings.last_index_any(s, "/\\"); i >= 0 && i + 1 < len(s) { s = s[i + 1:] }
	return s == "" ? "New tab" : s
}

////////////////////////////////
// Navigation

// What the user typed: a URL, a file path, or a bare host.
normalize_address :: proc(input: string) -> string {
	s := strings.trim_space(input)
	if len(s) > 2 && s[1] == ':' && (s[2] == '\\' || s[2] == '/') {   // C:\dir\page.html
		fixed, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		return strings.concatenate({"file:///", fixed}, context.temp_allocator)
	}
	if !strings.contains(s, "://") && !strings.has_prefix(s, "about:") && !strings.has_prefix(s, "data:") && s != "" {
		return strings.concatenate({"https://", s}, context.temp_allocator)
	}
	return s
}

// Starts loading `address` in `t`. `from` is the page the navigation comes from (a link click), nil for the address bar.
navigate :: proc(app: ^App, t: ^Tab, address: string, from: ^page.Page = nil, user_activation := false) {
	target := strings.clone(normalize_address(address), context.temp_allocator)
	if target == "" { target = strings.clone(app.cfg.homepage, context.temp_allocator) }
	if target == "about:config" { show_config(app, t); return }
	if target == HOME_URL { show_home(app, t); return }
	t.kind = .Web
	load := new(Doc_Load)
	load.tab = t
	if from != nil { load.initiator, load.has_initiator = fetch.environment_clone(from.env), true }

	base.scope_close(t.nav)           // closes the previous page, its modules and every request it still had
	t.nav = base.scope_make("navigation", t.scope)
	base.on_close(t.nav, load_closed, load)
	t.page = nil
	t.load = load
	layout_reset(&t.layout)
	t.scroll = 0
	for l in t.console { delete(l) }
	clear(&t.console)
	delete(t.url)
	t.url = strings.clone(target)
	delete(t.title)
	t.title = strings.clone(title_from_url(target))
	ui.field_set(&app.address, target)
	set_status(t, "loading...")

	fetch.start(&app.loader, {
		request = {
			url = target, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Document,
			initiator = load.has_initiator ? &load.initiator : nil, user_activation = user_activation,
		},
		on_event = document_event, user = load, scope = t.nav, collect = true,
	})
}

load_closed :: proc(data: rawptr) {
	load := (^Doc_Load)(data)
	if load.tab != nil && load.tab.load == load { load.tab.load = nil }
	if load.has_initiator { fetch.environment_destroy(&load.initiator) }
	for s in load.slots { delete(s.url); delete(s.bytes); free(s) }
	delete(load.slots)
	delete(load.mime); delete(load.charset); delete(load.final_url)
	free(load)
}

// about:config is a view of the browser itself, not a document: it has no page, no origin, no scripts.
show_config :: proc(app: ^App, t: ^Tab) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, .Config
	layout_reset(&t.layout)
	for l in t.console { delete(l) }
	clear(&t.console)
	delete(t.url); t.url = strings.clone("about:config")
	delete(t.title); t.title = strings.clone("Configuration")
	set_status(t, "about:config")
	ui.field_set(&app.address, "about:config")
}

// An HTML page the browser makes up when a load fails, so the tab always shows something readable.
show_error_page :: proc(app: ^App, load: ^Doc_Load, headline, detail: string) {
	t := load.tab
	if load.page == nil { load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, "about:blank", console_sink, t); t.page = load.page }
	body := fmt.tprintf("<!doctype html><title>Error</title><h1>%s</h1><p>%s</p><p>%s</p>", escape_html(headline), escape_html(detail), escape_html(t.url))
	page.load_html(load.page, transmute([]byte)body)
	delete(t.title)
	t.title = strings.clone("Error")
	set_status(t, headline)
	tab_log(t, .Error, fmt.tprintf("%s: %s", headline, detail))
}

escape_html :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	return r
}

document_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	load := (^Doc_Load)(user)
	t := load.tab
	app := the_app
	defer { app.frames_requested = max(app.frames_requested, 3) }
	switch ev.kind {
	case .Response:
		r := ev.response
		load.status = r.status
		load.final_url = strings.clone(r.url)
		if r.has_mime {
			load.mime = strings.clone(http.mime_essence(r.mime))
			if cs, ok := http.mime_param(r.mime, "charset"); ok { load.charset = strings.clone(cs) }
		}
		// the document exists from here on, with the origin of its *final* URL
		load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, r.url, console_sink, t)
		t.page = load.page
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		page.apply_response_headers(load.page, csp_h, ro_h, rp)
		set_status(t, fmt.tprintf("HTTP %d", r.status))
		delete(t.url)
		t.url = strings.clone(r.url)
		ui.field_set(&app.address, r.url)
	case .Data:
	case .Done:
		document_loaded(app, load, ev.data)
	case .Failed:
		show_error_page(app, load, "This page could not be loaded", ev.detail)
	}
}

looks_like_wasm :: proc(data: []byte) -> bool {
	return len(data) >= 4 && data[0] == 0 && data[1] == 'a' && data[2] == 's' && data[3] == 'm'
}

document_loaded :: proc(app: ^App, load: ^Doc_Load, data: []byte) {
	t := load.tab
	p := load.page
	if looks_like_wasm(data) || load.mime == "application/wasm" {
		// the document is a module
		_, ok, err := page.load_module(p, data, t.url)
		if ok { set_status(t, fmt.tprintf("%s: running", t.url)) } else { set_status(t, err); tab_log(t, .Error, err) }
		return
	}
	if load.mime != "" && load.mime != "text/html" && load.mime != "application/xhtml+xml" {
		if strings.has_prefix(load.mime, "text/") {
			show_text(app, load, data)
		} else {
			show_error_page(app, load, "Cannot display this content", fmt.tprintf("type %s", load.mime))
		}
		return
	}

	d, ok := html.decode_document(data, load.charset, app.page_settings.html.default_encoding)
	if !ok { show_error_page(app, load, "Cannot decode the document", load.charset); return }
	defer delete(d.text)
	r := page.load_html(p, d.text)
	if !r.ok { tab_log(t, .Error, fmt.tprintf("HTML parse failed (%d)", r.status)) }
	if r.truncated { tab_log(t, .Warn, "document truncated: too many nodes") }
	if title := html.title(p.doc); title != "" {
		delete(t.title)
		t.title = strings.clone(title)
	}
	set_status(t, fmt.tprintf("HTTP %d, %d bytes (%s), %d nodes", load.status, len(data), d.encoding, r.nodes))
	start_scripts(app, load)
}

show_text :: proc(app: ^App, load: ^Doc_Load, data: []byte) {
	d, ok := html.decode_document(data, load.charset, app.page_settings.html.default_encoding)
	if !ok { return }
	defer delete(d.text)
	p := load.page
	pre := dom.create_element(p.doc, "pre")
	dom.set_text_content(p.doc, pre, string(d.text[:min(len(d.text), 1 << 20)]))
	dom.append_child(p.doc, p.body, pre)
	set_status(load.tab, fmt.tprintf("HTTP %d, %d bytes of text", load.status, len(data)))
}

////////////////////////////////
// Wasm modules: fetched concurrently, run in document order

start_scripts :: proc(app: ^App, load: ^Doc_Load) {
	p := load.page
	t := load.tab
	for sh in html.wasm_scripts(p.doc, app.page_settings.html.module_script_type) {
		src, has := dom.get_attribute(p.doc, sh, "src")
		if !has || src == "" { tab_log(t, .Error, "an inline Wasm script needs a src (use a data: URL)"); continue }
		resolved, ok := url.parse(src, &p.env.location, context.temp_allocator)
		if !ok { tab_log(t, .Error, fmt.tprintf("invalid script URL %q", src)); continue }
		nonce, _ := dom.get_attribute(p.doc, sh, "nonce")
		slot := new(Script_Slot)
		slot.load = load
		slot.url = strings.clone(resolved.href)
		append(&load.slots, slot)
		fetch.start(&app.loader, {
			request = {url = resolved.href, mode = .Cors, credentials = .Same_Origin, destination = .Script, initiator = &p.env, nonce = nonce},
			on_event = script_event, user = slot, scope = t.nav, collect = true,
		})
	}
	run_ready_scripts(load)
}

script_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	slot := (^Script_Slot)(user)
	load := slot.load
	#partial switch ev.kind {
	case .Done:
		append(&slot.bytes, ..ev.data)
		slot.state = .Ready
	case .Failed:
		tab_log(load.tab, .Error, fmt.tprintf("module %s: %s", slot.url, ev.detail))
		slot.state = .Failed
	case .Response:
		if ev.response.status != 200 && ev.response.type != .Opaque {
			tab_log(load.tab, .Error, fmt.tprintf("module %s: HTTP %d", slot.url, ev.response.status))
		}
	}
	run_ready_scripts(load)
	the_app.frames_requested = max(the_app.frames_requested, 3)
}

// Runs modules in order: a later module waits for an earlier one that is still loading.
run_ready_scripts :: proc(load: ^Doc_Load) {
	for load.next_run < len(load.slots) {
		s := load.slots[load.next_run]
		switch s.state {
		case .Pending: return
		case .Failed, .Done: load.next_run += 1
		case .Ready:
			s.state = .Done
			load.next_run += 1
			_, ok, err := page.load_module(load.page, s.bytes[:], s.url)
			if !ok { tab_log(load.tab, .Error, fmt.tprintf("module %s: %s", s.url, err)) }
			if load.next_run >= len(load.slots) { set_status(load.tab, fmt.tprintf("%d module(s) running", len(load.slots))) }
		}
	}
}

////////////////////////////////
// UI

page_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := the_app
	app.page_rect = b.rect
	t := current_tab(app)
	if t == nil || t.page == nil || t.kind != .Web {
		draw.rect(dc, b.rect, draw.hex(0xffffffff))
		return
	}
	scale := ui.scale()
	size := draw.rect_size(b.rect)
	styled := page.styles(t.page, size.x / scale, size.y / scale, f64(scale))
	draw.rect(dc, b.rect, to_draw(styled.canvas))
	if !t.layout.valid || t.layout.mutations != t.page.doc.mutations || t.layout.serial != styled.serial || t.layout.width != size.x || t.layout.scale != scale {
		layout_document(&t.layout, t.page.doc, styled, &app.fonts, app.ui_font, size.x, scale)
	}
	t.scroll = clamp(t.scroll, 0, max(0, t.layout.height - size.y))
	draw.push_clip(dc, b.rect)
	paint(&t.layout, dc, &app.fonts, app.ui_font, b.rect.min - {0, t.scroll}, b.rect)
	draw.pop_clip(dc)
}

security_label :: proc(t: ^Tab) -> string {
	if t == nil || t.page == nil { return "" }
	e := &t.page.env
	switch {
	case e.location.scheme == "about": return APP_NAME
	case e.location.scheme == "file":  return "File"
	case e.location.scheme == "https": return "Secure"
	case e.secure_context && (e.location.scheme == "http"): return "Local"
	case e.location.scheme == "http":  return "Not secure"
	}
	return "Page"
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	t := current_tab(app)
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###window")
		if ui.parent(root) {
			// tab strip
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center) {
				labels := make([]string, len(app.tabs), ui.frame_allocator())
				for tab, i in app.tabs { labels[i] = fmt.aprintf("%s###tab%d", tab.title, i, allocator = ui.frame_allocator()) }
				sel := app.current
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
				if ui.tabs("tabs", labels, nil, &sel) && sel != app.current {
					app.current = sel
					ui.field_set(&app.address, app.tabs[sel].url)
				}
				ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.2)})
				if ui.button("+###newtab").clicked { tab_open(app) }
				ui.next({width = ui.px(em * 2.4), height = ui.px(em * 2.2)})
				if ui.button("x###closetab").clicked { tab_close(app, app.current); return }
			}
			// address bar with the security state of the page
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.5))
				if label := security_label(t); label != "" {
					ui.next({width = ui.text_size(em * 0.5), height = ui.px(ui.dense(em * 2))})
					if ui.tags("weak") { ui.label(fmt.aprintf("%s###sec", label, allocator = ui.frame_allocator())) }
					ui.spacer(ui.px(em * 0.4))
				}
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
				res := ui.line_edit("###address", &app.address, "Enter a URL (https://..., file:///..., C:\\...\\page.html) and press Enter")
				if res.committed && t != nil {
					address := strings.clone(strings.trim_space(ui.field_string(&app.address)), context.temp_allocator)
					if address != "" { navigate(app, t, address) }
				}
				ui.spacer(ui.px(em * 0.5))
			}
			// page
			ui.next({width = ui.fill(), height = ui.fill()})
			if t != nil && t.kind == .Config {
				config_page(&app.config_view, &app.prefs)
			} else {
				ui.custom("###page_area", page_draw, nil)
			}
			// console strip + status
			if t != nil {
				lines := min(len(t.console), 3)
				if lines > 0 {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5 * f32(lines) + em * 0.4))})
					if ui.column() {
						for i in len(t.console) - lines ..< len(t.console) {
							ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
							ui.label(fmt.aprintf("%s###cl%d", t.console[i], i, allocator = ui.frame_allocator()))
						}
					}
				}
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
				if ui.row(.Center) {
					ui.spacer(ui.px(em * 0.5))
					if ui.tags("weak") {
						origin := ""
						if t.page != nil { origin = url.origin_serialize(t.page.env.origin, context.temp_allocator) }
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
						ui.label(fmt.aprintf("%s   |   origin %s   |   %d request(s)   |   %d cookie(s)   |   %d DOM node(s)###status", t.status, origin, fetch.in_flight(&app.loader), cookies.count(&app.profile.jar), t.page != nil ? t.page.doc.nodes.count : 0, allocator = ui.frame_allocator()))
					}
				}
			}
		}
	}
}

// href of the nearest <a> at or above `h`.
anchor_href :: proc(d: ^dom.Document, h: base.Handle) -> (string, bool) {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element && n.name == "a" {
			if v, ok := dom.get_attribute(d, cur, "href"); ok { return v, true }
		}
		cur = n.parent
	}
	return "", false
}

// Mouse and wheel events that land on the page become DOM events / scrolling.
route_page_input :: proc(app: ^App, events: []platform.Event) {
	t := current_tab(app)
	if t == nil || t.page == nil || t.kind != .Web { return }
	scale := ui.scale()
	for ev in events {
		inside := draw.rect_contains(app.page_rect, ev.pos)
		if DEBUG_INPUT && ev.kind != .Mouse_Move { debug_log(fmt.tprintf("event %v at %v inside=%v rect=%v", ev.kind, ev.pos, inside, app.page_rect)) }
		#partial switch ev.kind {
		case .Mouse_Move:
			hovered := base.NIL_HANDLE
			if inside && t.layout.valid { hovered = hit_test(&t.layout, ev.pos - app.page_rect.min + {0, t.scroll}) }
			st := t.page.style_state
			st.hover = hovered
			page.set_style_state(t.page, st)
		case .Scroll:
			if inside { t.scroll -= ev.delta.y * app.cfg.scroll_step * scale }
		case .Mouse_Press:
			if !inside || !t.layout.valid { continue }
			local := ev.pos - app.page_rect.min + {0, t.scroll}
			target := hit_test(&t.layout, local)
			if target == base.NIL_HANDLE { continue }
			not_prevented := page.dispatch_event(t.page, target, dom.Event{
				type = "click", bubbles = true, cancelable = true,
				x = f64(local.x / scale), y = f64(local.y / scale), button = i32(ev.button),
			})
			// default action: following a link, unless a listener called preventDefault
			if not_prevented && ev.button == .Left {
				if href, ok := anchor_href(t.page.doc, target); ok {
					resolved, rok := url.parse(href, &t.page.env.location, context.temp_allocator)
					if !rok { tab_log(t, .Error, fmt.tprintf("invalid link %q", href)); continue }
					navigate(app, t, resolved.href, t.page, user_activation = true)
					return   // the page is gone: the rest of this frame's events belong to the old one
				}
			}
		}
	}
}

////////////////////////////////
// Preferences and profile

profile_paths :: proc(app: ^App) -> (cookie_file, hsts_file, prefs_file: string) {
	return strings.concatenate({app.profile_dir, "/cookies.tsv"}, context.temp_allocator),
	       strings.concatenate({app.profile_dir, "/hsts.txt"}, context.temp_allocator),
	       strings.concatenate({app.profile_dir, "/prefs.txt"}, context.temp_allocator)
}

profile_load :: proc(app: ^App) {
	c, h, _ := profile_paths(app)
	if !app.cfg.persist_profile { return }
	cookies.load(&app.profile.jar, c)
	fetch.hsts_load(&app.profile.hsts, h, fetch.now_ms())
}

profile_save :: proc(app: ^App, force := false) {
	c, h, pf := profile_paths(app)
	if app.prefs.dirty || force { config.save_user(&app.prefs, pf) }
	if !app.cfg.persist_profile { return }
	if force || app.profile.jar.dirty { cookies.save(&app.profile.jar, c) }
	if force || app.profile.hsts.dirty { fetch.hsts_save(&app.profile.hsts, h, fetch.now_ms()) }
}

autosave :: proc(data: rawptr) { profile_save((^App)(data)) }

// (Re)arms the autosave timer from the current preference.
arm_autosave :: proc(app: ^App) {
	if app.autosave_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.autosave_timer); app.autosave_timer = base.NIL_HANDLE }
	if app.cfg.autosave_ms > 0 {
		app.autosave_timer = host.set_timer(&app.loop, f64(app.cfg.autosave_ms), f64(app.cfg.autosave_ms), autosave, app)
	}
}

// Every setting struct is derived from the registry; when any preference changes they are all refreshed and handed to
// their subsystems. Preferences marked "restart" are read again at the next start (the subsystem keeps what it opened with).
apply_prefs :: proc(app: ^App) {
	ns := net.settings_from_prefs(&app.prefs)
	net.client_apply(&app.client, ns)
	net.settings_destroy(&ns)

	fetch.settings_destroy(&app.profile.settings)
	app.profile.settings = fetch.settings_from_prefs(&app.prefs)
	app.profile.jar.settings = cookies.settings_from_prefs(&app.prefs)

	page.settings_destroy(&app.page_settings)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	for tab in app.tabs { if tab.page != nil { page.configure_styles(tab.page) } }

	delete(app.cfg.homepage)
	app.cfg = settings_from_prefs(&app.prefs)
	arm_autosave(app)
	app.frames_requested = max(app.frames_requested, 3)
}

on_pref_change :: proc(user: rawptr, name: string, p: ^config.Prefs) { apply_prefs((^App)(user)) }
////////////////////////////////
// Loop

frame :: proc(app: ^App) {
	render.wait_for_frame(&app.r)
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 4) }

	// network completions, timers and posted tasks run here, on the UI thread
	if host.run_ready(&app.loop) > 0 { app.frames_requested = max(app.frames_requested, 2) }
	route_page_input(app, events)

	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), 0.0005, 0.1)
	app.last_tick = now

	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT)
	platform.set_dark_title(app.win, true)
	base_style := ui.Style{
		pref = {.X = ui.text_size(), .Y = ui.px(36)},
		font = app.ui_font, font_size = app.cfg.ui_font_size, text_pad = 7,
		cursor = .Arrow,
	}
	ui.begin_build(&app.ui_state, {
		window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(),
		dpi_scale = app.win.dpi_scale, base = base_style, clipboard_get = clip_get, clipboard_set = clip_set,
	})
	build_ui(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	if ui.needs_frame(&app.ui_state) { app.frames_requested = max(app.frames_requested, 2) }
	if t := current_tab(app); t != nil && t.page != nil && t.layout.mutations != t.page.doc.mutations { app.frames_requested = max(app.frames_requested, 2) }

	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r)
	free_all(context.temp_allocator)
}

wake_window :: proc(user: rawptr) { platform.wake((^platform.Window)(user)) }

// `--profile DIR` and `--policy FILE` are the shell's own flags; every other `--pref name=value` is a preference.
extract_flag :: proc(args: []string, flag: string) -> (value: string, rest: [dynamic]string) {
	rest = make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		if args[i] == flag && i + 1 < len(args) { value = args[i + 1]; i += 1; continue }
		append(&rest, args[i])
	}
	return
}

main :: proc() {
	app := new(App)
	the_app = app

	// --- configuration: defaults < profile file < command line < policy file ---
	args := os.args[1:]
	profile_override, a1 := extract_flag(args, "--profile")
	policy_file, a2 := extract_flag(a1[:], "--policy")
	app.prefs = config.prefs_make()
	rest, arg_errors := config.apply_args(&app.prefs, a2[:])
	cfg_dir := platform.config_dir(context.temp_allocator)
	app.profile_dir = strings.clone(profile_override != "" ? profile_override : (cfg_dir == "" ? "build/profile" : strings.concatenate({cfg_dir, "/", APP_NAME}, context.temp_allocator)))
	_ = os.make_directory_all(app.profile_dir)
	_, _, prefs_file := profile_paths(app)
	config.load_file(&app.prefs, prefs_file, .User)
	if policy_file == "" { policy_file = "policies.txt" }
	config.load_file(&app.prefs, policy_file, .Policy)
	register_all_prefs(&app.prefs)
	app.cfg = settings_from_prefs(&app.prefs)

	font.init(&app.fonts)
	app.win = platform.open_window(APP_NAME, {1280, 800})
	if !render.init(&app.r, app.win.hwnd, app.win.size) { fmt.eprintln("renderer init failed"); return }
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	app.icons, ok = font.load_embedded(&app.fonts, ui.ICON_FONT_DATA)
	if !ok { fmt.eprintln("cannot load the icon font"); return }
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.icons

	host.loop_init(&app.loop, wake_window, app.win)
	ns := net.settings_from_prefs(&app.prefs)
	if !net.client_init(&app.client, &app.loop, ns) { fmt.eprintln("network init failed"); return }
	net.settings_destroy(&ns)
	host.blocking_init(&app.blocking, &app.loop, 4)
	app.profile = fetch.profile_make(fetch.settings_from_prefs(&app.prefs), cookies.settings_from_prefs(&app.prefs))
	fetch.loader_init(&app.loader, &app.loop, &app.client, &app.blocking, &app.profile)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	if !page.register_imports() { fmt.eprintln("wasm runtime init failed"); return }
	app.process = base.scope_make("process")
	app.config_view.rows = make(map[string]^Row_State)

	profile_load(app)
	config.watch(&app.prefs, "", on_pref_change, app)
	arm_autosave(app)

	// the first tab: the address given on the command line, else the homepage
	address := len(rest) > 0 ? rest[0] : ""
	tab_open(app, address)
	for e in arg_errors { tab_log(current_tab(app), .Warn, e) }

	app.last_tick = time.tick_now()
	app.frames_requested = 4
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)

	for !platform.is_closed(app.win) {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) {
			timeout := ui.wake_ms(&app.ui_state)
			if t := host.next_timeout_ms(&app.loop); t >= 0 && (timeout <= 0 || t < timeout) { timeout = max(t, 1) }
			platform.wait_event(app.win, timeout)
		}
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}

	profile_save(app, force = true)
	base.scope_close(app.process)   // every tab, page and request
	fetch.loader_destroy(&app.loader)
	host.blocking_destroy(&app.blocking)
	net.client_destroy(&app.client)
	fetch.profile_destroy(&app.profile)
	host.loop_destroy(&app.loop)
	wasm.runtime_destroy()
	config_view_destroy(&app.config_view)
	config.prefs_destroy(&app.prefs)
}
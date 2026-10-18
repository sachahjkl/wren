// Wasm-first browser shell. The chrome (tabs, address bar, console strip) is built with gui_toolkit's `ui`; the page is a
// custom-draw box painted from the DOM. Everything a tab starts lives in the tab's scope: closing a tab is one call.
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
import "wb:dom"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:wasm"

MAX_CONSOLE_LINES :: 500
DEBUG_INPUT :: #config(DEBUG_INPUT, false)

Tab :: struct {
	scope:    ^base.Scope,   // lives as long as the tab
	nav:      ^base.Scope,   // lives as long as the current navigation: the page and its main request
	page:     ^page.Page,
	url:      string,
	title:    string,
	status:   string,
	console:  [dynamic]string,
	layout:   Layout,
	scroll:   f32,
	load:     base.Handle,
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
// Tabs and navigation

tab_open :: proc(app: ^App, url := "") -> ^Tab {
	t := new(Tab)
	t.scope = base.scope_make("tab", app.process)
	t.title = strings.clone("New tab")
	append(&app.tabs, t)
	app.current = len(app.tabs) - 1
	ui.field_set(&app.address, url)
	if url != "" { navigate(app, t, url) }
	return t
}

tab_close :: proc(app: ^App, index: int) {
	t := app.tabs[index]
	ordered_remove(&app.tabs, index)
	base.scope_close(t.scope)   // page, instance, DOM, requests, timers: all gone
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
	if len(t.console) > MAX_CONSOLE_LINES {
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

// A path or file:// URL is read synchronously (local files are fast and this keeps the first version simple).
local_path :: proc(url: string) -> (path: string, ok: bool) {
	if strings.has_prefix(url, "file:///") { return url[8:], true }
	if len(url) > 2 && url[1] == ':' && (url[2] == '\\' || url[2] == '/') { return url, true }
	return "", false
}

// Last path segment, or the host: a stand-in until pages have a <title>.
title_from_url :: proc(url: string) -> string {
	u := url
	if i := strings.index(u, "://"); i >= 0 { u = u[i + 3:] }
	u = strings.trim_right(u, "/\\")
	if i := strings.last_index_any(u, "/\\"); i >= 0 && i + 1 < len(u) { u = u[i + 1:] }
	return u == "" ? "New tab" : u
}

navigate :: proc(app: ^App, t: ^Tab, url: string) {
	base.scope_close(t.nav)           // cancels the previous page and its request
	t.nav = base.scope_make("navigation", t.scope)
	t.page = nil
	t.load = base.NIL_HANDLE
	layout_reset(&t.layout)
	t.scroll = 0
	delete(t.url)
	t.url = strings.clone(url)
	delete(t.title)
	t.title = strings.clone(title_from_url(url))
	for l in t.console { delete(l) }
	clear(&t.console)
	t.page = page.page_create(&app.loop, &app.client, t.nav, console_sink, t)

	if path, ok := local_path(url); ok {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { set_status(t, fmt.tprintf("cannot read %s", path)); return }
		loaded(app, t, data, url, 200)
		return
	}
	set_status(t, "loading...")
	t.load = net.fetch(&app.client, {
		url = url, on_event = main_resource_event, user = t, collect = true, scope = t.nav, priority = .High,
		headers = "Accept: application/wasm, text/html;q=0.8, */*;q=0.5",
	})
}

main_resource_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	t := (^Tab)(user)
	app := the_app
	#partial switch ev.kind {
	case .Headers:
		set_status(t, fmt.tprintf("HTTP %d", ev.status))
	case .Done:
		t.load = base.NIL_HANDLE
		loaded(app, t, ev.data, t.url, ev.status)
	case .Failed:
		t.load = base.NIL_HANDLE
		set_status(t, net.error_text(ev.error, ev.secure_flags))
		tab_log(t, .Error, net.error_text(ev.error, ev.secure_flags))
	}
	app.frames_requested = max(app.frames_requested, 3)
}

// Wasm modules run; anything else is shown as text until the HTML pipeline lands.
loaded :: proc(app: ^App, t: ^Tab, data: []byte, url: string, status: int) {
	if len(data) >= 4 && data[0] == 0 && data[1] == 'a' && data[2] == 's' && data[3] == 'm' {
		ok, err := page.load_module(t.page, data, url)
		if ok { set_status(t, fmt.tprintf("%s: running", url)) } else { set_status(t, err); tab_log(t, .Error, err) }
		return
	}
	pre := dom.create_element(t.page.doc, "pre")
	dom.set_text_content(t.page.doc, pre, string(data[:min(len(data), 1 << 20)]))
	dom.append_child(t.page.doc, t.page.body, pre)
	set_status(t, fmt.tprintf("HTTP %d, %d bytes (shown as text: HTML is not supported yet)", status, len(data)))
}

////////////////////////////////
// UI

page_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := the_app
	app.page_rect = b.rect
	draw.rect(dc, b.rect, draw.hex(0xffffffff))
	t := current_tab(app)
	if t == nil || t.page == nil { return }
	scale := ui.scale()
	size := draw.rect_size(b.rect)
	if !t.layout.valid || t.layout.mutations != t.page.doc.mutations || t.layout.width != size.x || t.layout.scale != scale {
		layout_document(&t.layout, t.page.doc, &app.fonts, app.ui_font, size.x, scale)
	}
	t.scroll = clamp(t.scroll, 0, max(0, t.layout.height - size.y))
	draw.push_clip(dc, b.rect)
	paint(&t.layout, dc, &app.fonts, app.ui_font, b.rect.min - {0, t.scroll}, b.rect)
	draw.pop_clip(dc)
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
			// address bar
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
				res := ui.line_edit("###address", &app.address, "Enter a URL (https://..., file:///..., C:\\...\\page.wasm) and press Enter")
				if res.committed && t != nil {
					url := strings.clone(strings.trim_space(ui.field_string(&app.address)), context.temp_allocator)
					if url != "" { navigate(app, t, url) }
				}
				ui.spacer(ui.px(em * 0.5))
			}
			// page
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.custom("###page_area", page_draw, nil)
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
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
						ui.label(fmt.aprintf("%s   |   %d request(s) in flight   |   %d DOM node(s)###status", t.status, net.in_flight(&app.client), t.page != nil ? t.page.doc.nodes.count : 0, allocator = ui.frame_allocator()))
					}
				}
			}
		}
	}
}

// Mouse and wheel events that land on the page become DOM events / scrolling.
route_page_input :: proc(app: ^App, events: []platform.Event) {
	t := current_tab(app)
	if t == nil || t.page == nil { return }
	scale := ui.scale()
	for ev in events {
		inside := draw.rect_contains(app.page_rect, ev.pos)
		#partial switch ev.kind {
		case .Scroll:
			if inside { t.scroll -= ev.delta.y * 48 * scale }
		case .Mouse_Press:
			if !inside || !t.layout.valid { continue }
			local := ev.pos - app.page_rect.min + {0, t.scroll}
			target := hit_test(&t.layout, local)
			if DEBUG_INPUT { tab_log(t, .Log, fmt.tprintf("press at %v (page %v, local %v) -> node %v", ev.pos, app.page_rect.min, local, target)) }
			if target == base.NIL_HANDLE { continue }
			page.dispatch_event(t.page, target, dom.Event{
				type = "click", bubbles = true, cancelable = true,
				x = f64(local.x / scale), y = f64(local.y / scale), button = i32(ev.button),
			})
		}
	}
}

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
		font = app.ui_font, font_size = 15, text_pad = 7,
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

main :: proc() {
	app := new(App)
	the_app = app
	font.init(&app.fonts)
	app.win = platform.open_window("wasm browser", {1280, 800})
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
	if !net.client_init(&app.client, &app.loop) { fmt.eprintln("network init failed"); return }
	if !page.register_imports() { fmt.eprintln("wasm runtime init failed"); return }
	app.process = base.scope_make("process")

	url := len(os.args) > 1 ? os.args[1] : ""
	tab_open(app, url)

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

	base.scope_close(app.process)   // every tab, page and request
	net.client_destroy(&app.client)
	host.loop_destroy(&app.loop)
	wasm.runtime_destroy()
}

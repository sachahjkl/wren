// Wasm-first browser: shell. The chrome (tabs, address bar) is built with gui_toolkit's `ui`; the page area is a
// custom-draw box where the page painter will use `draw` directly.
package browser

import "core:fmt"
import "core:time"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	theme:    ui.Theme,
	ui_font:  font.Font_Id,
	icons:    font.Font_Id,

	tabs:     [dynamic]string,
	tab:      int,
	address:  ui.Text_Field,

	frames_requested: int,
	last_tick:        time.Tick,
}

the_app: ^App

clip_get :: proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(the_app.win, text) }

page_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	draw.rect(dc, b.rect, draw.hex(0xffffffff))
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		page := ui.build_box({.Draw_Background}, "###window")
		if ui.parent(page) {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center) {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
				labels := make([]string, len(app.tabs), ui.frame_allocator())
				copy(labels, app.tabs[:])
				ui.tabs("tabs", labels, nil, &app.tab)
			}
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
				res := ui.line_edit("###address", &app.address, "Address")
				if res.committed { app.tabs[app.tab] = fmt.aprintf("%s", ui.field_string(&app.address)) }
				ui.spacer(ui.px(em * 0.5))
			}
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.custom("###page_area", page_draw, nil)
		}
	}
}

frame :: proc(app: ^App) {
	render.wait_for_frame(&app.r)
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 4) }
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}

	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), 0.0005, 0.1)
	app.last_tick = now

	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT)
	platform.set_dark_title(app.win, true)
	base := ui.Style{
		pref = {.X = ui.text_size(), .Y = ui.px(36)},
		font = app.ui_font, font_size = 15, text_pad = 7,
		cursor = .Arrow,
	}
	ui.begin_build(&app.ui_state, {
		window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(),
		dpi_scale = app.win.dpi_scale, base = base, clipboard_get = clip_get, clipboard_set = clip_set,
	})
	build_ui(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	if ui.needs_frame(&app.ui_state) { app.frames_requested = max(app.frames_requested, 2) }

	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r)
	free_all(context.temp_allocator)
}

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
	append(&app.tabs, "New tab")
	app.last_tick = time.tick_now()
	app.frames_requested = 4
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)

	for !platform.is_closed(app.win) {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_ms(&app.ui_state)) }
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}
}

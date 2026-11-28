package browser

// The toolkit's shared About modal (gui_toolkit docs/about.md) wired to Wren's identity, licence status, built-in
// What's new page, and about:wren / about:licenses pages. Clicking any link opens a tab inside Wren rather than asking
// the operating system for another browser.

import "core:fmt"
import i18n "toolkit:i18n"
import licence "toolkit:licence"
import lucide "toolkit:lucide"
import setup "toolkit:setup"
import "toolkit:ui"
import "wb:license"
import "wb:wasm"

WREN_WEBSITE_URL  :: "https://wren.froment.software/"
WREN_RELEASES_URL :: "https://wren.froment.software/changelog/"

// Opens the About modal on the active window (browser.about, from the main menu or the command palette).
about_modal_open :: proc(app: ^App) {
	if ui.building() {
		ui.menu_close()
		palette_hide(app)
	}
	window_own(app).about_open = true
	request_frames(app, 2)
}

@(private)
about_modal_licence_text :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	s := app.licence.status
	if s.registered {
		return fmt.aprintf("%s (%s)", s.licence.name, licence.edition_title(license.WREN, s.licence.edition), allocator = allocator)
	}
	if !app.licence.read { return i18n.tr("Reading the license…") }
	return i18n.tr("Beta (unregistered)")
}

@(private)
about_modal_diagnostics :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	_ = app
	return fmt.aprintf("Channel: %s\nBuild: %s\nBuilt: %s\nWasmtime: %s\nJavaScript: Wren (after QuickJS-ng %s)",
		channel_name(), build_description(), build_date_text(), wasm.WASMTIME_VERSION, QUICKJS_VERSION, allocator = allocator)
}

// Metadata for ui.about_modal; pure so tests can check the version and diagnostics strings directly.
about_modal_info :: proc(app: ^App, allocator := context.temp_allocator) -> ui.About_Info {
	links := make([]ui.About_Link, 2, allocator)
	links[0] = {label = i18n.tr("Build & licenses"), url = WREN_URL, icon = lucide.INFO}
	links[1] = {label = i18n.tr("Licenses"), url = LICENSES_URL, icon = lucide.SCROLL_TEXT}
	info := ui.About_Info{
		name         = APP_NAME,
		version      = version_long(),
		tagline      = APP_TAGLINE,
		licence      = about_modal_licence_text(app, allocator),
		copyright    = "© 2026 Froment Software",
		icon         = lucide.GLOBE,
		on_whats_new = proc(user: rawptr) {
			a := (^App)(user)
			tab_open(a, SETTINGS_WHATS_NEW_URL, origin = .User)
		},
		website_url  = WREN_WEBSITE_URL,
		releases_url = WREN_RELEASES_URL,
		links        = links,
		diagnostics  = about_modal_diagnostics(app, allocator),
		on_link      = proc(u: string, user: rawptr) {
			a := (^App)(user)
			tab_open(a, u, origin = .User)
		},
		user         = app,
	}
	if l, has := app.install.logo.?; has { info.logo = l.texture }
	return info
}

// Renders the About modal on the active window while open.
about_modal_build :: proc(app: ^App) {
	own := window_own(app)
	if !own.about_open { return }
	// Reuse the 256 px channel logo texture owned by app.install (freed at setup_end).
	if .Renderer in app.made && app.install.logo == nil {
		if l, ok := setup.logo_make(&app.r, APP_LOGO_PNG); ok { app.install.logo = l }
	}
	ui.about_modal("about", &own.about_open, about_modal_info(app, ui.frame_allocator()))
}

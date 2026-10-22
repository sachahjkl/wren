package desktop

import "core:strings"
import "wb:config"

// Preferences of the integration itself. The shell's own policy (when to integrate, whether to offer an update) is in
// src/browser/desktop_shell.odin: it depends on the build's channel, which this package does not know.

PREFS := [?]config.Def{
	{name = "browser.desktop_integration.register_browser", kind = .Bool, default = {b = true},
		description = "Integrating with the desktop also registers Wren as a program that can open web addresses (http, https) and the file types below: Windows lists it in Settings > Apps > Default apps (it never makes itself the default: the user picks), a freedesktop.org desktop lists it in the default browser setting. Off: only the menu entry and its icon. Applied the next time the integration is installed or repaired."},
	{name = "browser.desktop_integration.start_menu", kind = .Bool, default = {b = true},
		description = "Integrating with the desktop adds the launcher to the application menu (the Start menu on Windows). Setup's \"Add to Start menu\" option sets it; the box in about:config and --desktop-integration=install apply it."},
	{name = "browser.desktop_integration.desktop_shortcut", kind = .Bool, default = {b = false},
		description = "Integrating with the desktop also puts a launcher on the desktop (Windows). Setup's \"Create desktop shortcut\" option sets it."},
	{name = "browser.desktop_integration.add_to_path", kind = .Bool, default = {b = false},
		description = "Integrating with the desktop also adds the folder of wren.exe to your user PATH, so that `wren` runs from any terminal (Windows; no administrator rights: it is HKEY_CURRENT_USER\\Environment). Setup's \"Add Wren to PATH\" option sets it."},
	{name = "browser.desktop_integration.file_types", kind = .String, default = {s = DEFAULT_FILE_TYPES},
		description = "File extensions Wren is registered as able to open, separated by commas (with or without the dot). Used when the integration is installed or repaired and register_browser is on. Known types: .htm .html .shtml .xhtml .xht .svg .webp .avif .png .jpg .jpeg .gif .pdf .txt .xml."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

// Takes what the preferences decide into `o` (the file types are in the temporary allocator).
options_apply_prefs :: proc(o: ^Options, p: ^config.Prefs) {
	o.register_browser = config.bool_of(p, "browser.desktop_integration.register_browser")
	o.start_menu = config.bool_of(p, "browser.desktop_integration.start_menu")
	o.desktop_shortcut = config.bool_of(p, "browser.desktop_integration.desktop_shortcut")
	o.add_to_path = config.bool_of(p, "browser.desktop_integration.add_to_path")
	exts := split_list(config.string_of(p, "browser.desktop_integration.file_types"))
	norm := make([dynamic]string, context.temp_allocator)
	for e in exts {
		n := normalize_extension(e)
		if n == "" || strings.contains_any(n, "\\/:*?\"<>|") { continue }
		append(&norm, n)
	}
	o.file_types = norm[:]
}

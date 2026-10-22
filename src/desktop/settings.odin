package desktop

import "core:strings"
import "wb:config"

// Preferences of the integration itself. The shell's own policy (when to integrate, whether to offer an update) is in
// src/browser/desktop_shell.odin: it depends on the build's channel, which this package does not know.

PREFS := [?]config.Def{
	{name = "browser.desktop_integration.register_browser", kind = .Bool, default = {b = true},
		description = "Integrating with the desktop also registers Wren as a program that can open web addresses (http, https) and the file types below: Windows lists it in Settings > Apps > Default apps (it never makes itself the default: the user picks), a freedesktop.org desktop lists it in the default browser setting. Off: only the menu entry and its icon. Applied the next time the integration is installed or repaired."},
	{name = "browser.desktop_integration.file_types", kind = .String, default = {s = DEFAULT_FILE_TYPES},
		description = "File extensions Wren is registered as able to open, separated by commas (with or without the dot). Used when the integration is installed or repaired and register_browser is on. Known types: .htm .html .shtml .xhtml .xht .svg .webp .avif .png .jpg .jpeg .gif .pdf .txt .xml."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

// Takes what the preferences decide into `o` (the file types are in the temporary allocator).
options_apply_prefs :: proc(o: ^Options, p: ^config.Prefs) {
	o.register_browser = config.bool_of(p, "browser.desktop_integration.register_browser")
	exts := split_list(config.string_of(p, "browser.desktop_integration.file_types"))
	norm := make([dynamic]string, context.temp_allocator)
	for e in exts {
		n := normalize_extension(e)
		if n == "" || strings.contains_any(n, "\\/:*?\"<>|") { continue }
		append(&norm, n)
	}
	o.file_types = norm[:]
}

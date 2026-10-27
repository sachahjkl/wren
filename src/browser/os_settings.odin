package browser

import "core:time"
import "toolkit:platform"
import "wb:config"

// Windows settings the shell follows every frame, asked again only now and then. SystemParametersInfo costs a few
// microseconds at rest but waits on the window manager while the window is being resized or moved: up to 2-3 ms per
// frame, more than the layout of a large page gets at 180 Hz.

OS_SETTINGS_PREFS := [?]config.Def{
	{name = "browser.ui.os_settings_refresh_ms", kind = .Int, default = {i = 500}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "How often the browser asks Windows again for the settings it follows on every frame (Settings > Accessibility > Visual effects > Animation effects). A change shows up within this delay. 0 = asked at every frame (slow while the window is being resized)."},
	{name = "browser.ui.animations", kind = .String, default = {s = "system"}, choices = {"system", "on", "off"},
		description = "Whether the interface animates (the tab sidebar opening, tabs sliding, scrolling, fades): system follows Windows (Settings > Accessibility > Visual effects > Animation effects), on and off decide whatever it says."},
}

register_os_settings_prefs :: proc(p: ^config.Prefs) { config.register(p, OS_SETTINGS_PREFS[:]) }

@(private = "file")
os_anim: struct {
	value: bool,
	known: bool,
	at:    time.Tick,
}

// platform.os_animations_enabled, at most browser.ui.os_settings_refresh_ms old.
os_animations_enabled :: proc(app: ^App) -> bool {
	switch config.string_of(&app.prefs, "browser.ui.animations") {
	case "on": return true
	case "off": return false
	}
	every := config.int_of(&app.prefs, "browser.ui.os_settings_refresh_ms")
	if !os_anim.known || every <= 0 || time.duration_milliseconds(time.tick_since(os_anim.at)) >= f64(every) {
		os_anim.value = platform.os_animations_enabled()
		os_anim.known = true
		os_anim.at = time.tick_now()
	}
	return os_anim.value
}

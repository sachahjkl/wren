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
	every := config.int_of(&app.prefs, "browser.ui.os_settings_refresh_ms")
	if !os_anim.known || every <= 0 || time.duration_milliseconds(time.tick_since(os_anim.at)) >= f64(every) {
		os_anim.value = platform.os_animations_enabled()
		os_anim.known = true
		os_anim.at = time.tick_now()
	}
	return os_anim.value
}

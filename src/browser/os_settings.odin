package browser

import "core:time"
import "toolkit:platform"
import config "toolkit:config"

// Windows settings the shell follows every frame, asked again only now and then. SystemParametersInfo costs a few
// microseconds at rest but waits on the window manager while the window is being resized or moved: up to 2-3 ms per
// frame, more than the layout of a large page gets at 180 Hz.

OS_SETTINGS_PREFS := [?]config.Def{
	{name = "browser.ui.os_settings_refresh_ms", kind = .Int, default = {i = 500}, bounded = true, min = 0, max = 60_000, value_kind = .Duration,
		description = "How often the browser asks Windows again for the settings it follows on every frame (Settings > Accessibility > Visual effects > Animation effects). A change shows up within this delay. 0 = asked at every frame (slow while the window is being resized)."},
}

register_os_settings_prefs :: proc(p: ^config.Prefs) { config.register(p, OS_SETTINGS_PREFS[:]) }

Os_Anim_Mode :: enum u8 { System, On, Off }

Os_Anim_Settings :: struct {
	mode:       Os_Anim_Mode,
	refresh_ms: i64,
}

os_anim_settings_from_prefs :: proc(p: ^config.Prefs) -> Os_Anim_Settings {
	mode := Os_Anim_Mode.System
	if config.ref_of(p, "appearance.animations") != config.NO_REF {
		switch config.string_of(p, "appearance.animations") {
		case "on":  mode = .On
		case "off": mode = .Off
		}
	}
	return {
		mode = mode,
		refresh_ms = config.int_of(p, "browser.ui.os_settings_refresh_ms"),
	}
}

// The system's animation setting as last read (App.os_anim).
Os_Anim :: struct {
	cfg:   Os_Anim_Settings,
	value: bool,
	known: bool,
	at:    time.Tick,
}

// Whether the interface animates: the standard appearance.animations, and for `system` platform.os_animations_enabled, at
// most browser.ui.os_settings_refresh_ms old.
os_animations_enabled :: proc(app: ^App) -> bool {
	switch app.os_anim.cfg.mode {
	case .On:  return true
	case .Off: return false
	case .System:
	}
	every := app.os_anim.cfg.refresh_ms
	if !app.os_anim.known || every <= 0 || time.duration_milliseconds(time.tick_since(app.os_anim.at)) >= f64(every) {
		app.os_anim.value = platform.os_animations_enabled()
		app.os_anim.known = true
		app.os_anim.at = time.tick_now()
	}
	return app.os_anim.value
}

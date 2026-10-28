package browser

import "wb:host"
import "wb:style"

// The look of the desktop that pages see: the apps theme (light or dark: style.color_scheme = auto,
// prefers-color-scheme, the used color scheme of `color-scheme: light dark` pages), the accent color (the `system` value
// of page.color.accent) and the selection colors. Where the values come from, and the watch that notices a change, are
// the system's: Windows reads the registry and GetSysColor (appearance_windows.odin); other systems read the toolkit's
// neutral light/dark preference and watch it (appearance_other.odin), with the accent and selection colors left to the
// browser's own defaults until the platform layer reports them. This file holds what every system shares: reading once,
// deriving the settings and restyling the pages when the values change.

// read_os_appearance / appearance_watch_start / appearance_watch_stop are in appearance_<os>.odin. The watch posts
// appearance_changed to the UI thread when the desktop's look may have changed.

// Reads the appearance once (before the settings are derived) and starts watching it.
appearance_init :: proc(app: ^App) {
	style.set_os_appearance(read_os_appearance())
	touch_devices_apply(app)   // touch_shell.odin: the pointing devices pages are told about, before the settings too
	appearance_watch_start(app)
}

appearance_destroy :: proc() {
	appearance_watch_stop()
}

// Any thread (the watch): the desktop's look may have changed; the UI thread reads the values again.
appearance_post :: proc(app: ^App) {
	if app == nil { return }
	host.post(&app.loop, appearance_changed, app)
}

// UI thread: the look changed; the values may not have.
@(private)
appearance_changed :: proc(data: rawptr) {
	app := (^App)(data)
	if !style.set_os_appearance(read_os_appearance()) { return }
	apply_prefs(app, "browser.appearance")   // derives every setting again (`system` colors) and restyles every page (auto color scheme); nothing of the network
}

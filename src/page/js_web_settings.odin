package page

// Preferences of the web APIs of JavaScript that the page answers (api/js_web.widl: navigator, beacons). Registered by
// register_prefs; copied into Settings.js_web by settings_from_prefs.

import "core:strings"
import "wb:config"

Js_Web_Settings :: struct {
	platform:             string,   // owned
	vendor:               string,   // owned
	hardware_concurrency: int,      // 0: the machine's logical processors
	beacon_max_bytes:     int,
	do_not_track:         bool,
	clipboard_read:       bool,
	clipboard_write:      bool,
}

JS_WEB_PREFS := [?]config.Def{
	{name = "navigator.platform", kind = .String, default = {s = "Win32"},
		description = "What navigator.platform says. Scripts use it to tell operating systems apart; browsers on Windows say Win32."},
	{name = "navigator.vendor", kind = .String, default = {s = ""},
		description = "What navigator.vendor says (Chromium-based browsers say \"Google Inc.\", Firefox nothing)."},
	{name = "navigator.hardware_concurrency", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 1024,
		description = "What navigator.hardwareConcurrency says, the number of threads scripts may plan for. 0 = the machine's logical processors; a fixed value hides it (fingerprinting)."},
	{name = "navigator.beacon_max_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 0, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest body navigator.sendBeacon accepts (browsers allow 64 KiB). Larger beacons are refused (sendBeacon returns false)."},
	{name = "navigator.clipboard_write", kind = .Bool, default = {b = true},
		description = "navigator.clipboard.writeText and write put text on the system clipboard, from a focused page or after a click or key press in it. Off: they reject with NotAllowedError."},
	{name = "navigator.clipboard_read", kind = .Bool, default = {b = true},
		description = "navigator.clipboard.readText and read give a focused page the system clipboard's text after a click or key press in it (there is no permission prompt: the gesture is the consent). Off: they reject with NotAllowedError."},
	{name = "privacy.do_not_track", kind = .Bool, default = {b = false},
		description = "navigator.doNotTrack says \"1\" (the user asks not to be tracked) instead of null."},
}

js_web_settings_from_prefs :: proc(p: ^config.Prefs) -> Js_Web_Settings {
	return Js_Web_Settings{
		platform = strings.clone(config.string_of(p, "navigator.platform")),
		vendor = strings.clone(config.string_of(p, "navigator.vendor")),
		hardware_concurrency = int(config.int_of(p, "navigator.hardware_concurrency")),
		beacon_max_bytes = int(config.int_of(p, "navigator.beacon_max_bytes")),
		do_not_track = config.bool_of(p, "privacy.do_not_track"),
		clipboard_read = config.bool_of(p, "navigator.clipboard_read"),
		clipboard_write = config.bool_of(p, "navigator.clipboard_write"),
	}
}

js_web_settings_destroy :: proc(s: ^Js_Web_Settings) {
	delete(s.platform)
	delete(s.vendor)
	s.platform, s.vendor = "", ""
}

package page

import "wb:config"
import "wb:html"
import "wb:style"
import "wb:wasm"

// Shared by every page of a profile. The shell owns one and keeps it current when preferences change.
Settings :: struct {
	max_fetch_bytes: int,
	max_microtasks:  int,
	wasm:            wasm.Options,
	html:            html.Options,
	style:           style.Settings,
	web:             Web_Settings,     // web_settings.odin
}

PREFS := [?]config.Def{
	{name = "page.max_fetch_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most bytes one page's scripts may keep alive in browser memory (fetch bodies, buffers, messages). Past it, further data is refused."},
	{name = "page.max_microtasks_per_checkpoint", kind = .Int, default = {i = 100_000}, bounded = true, min = 100, max = 100_000_000,
		description = "Microtasks (promise reactions, queueMicrotask) run in one go. A page that keeps queueing more is cut there and resumes on the next turn of the event loop, so it cannot freeze the browser."},
}

register_prefs :: proc(p: ^config.Prefs) {
	config.register(p, PREFS[:])
	config.register(p, WEB_PREFS[:])
	wasm.register_prefs(p)
	html.register_prefs(p)
	style.register_prefs(p)
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		max_fetch_bytes = int(config.int_of(p, "page.max_fetch_bytes")),
		max_microtasks = int(config.int_of(p, "page.max_microtasks_per_checkpoint")),
		wasm = wasm.options_from_prefs(p),
		html = html.options_from_prefs(p),
		style = style.settings_from_prefs(p),
		web = web_settings_from_prefs(p),
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) {
	html.options_destroy(&s.html)
	style.settings_destroy(&s.style)
}

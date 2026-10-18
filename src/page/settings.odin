package page

import "wb:config"
import "wb:html"
import "wb:wasm"

// Shared by every page of a profile. The shell owns one and keeps it current when preferences change.
Settings :: struct {
	max_fetch_bytes: int,
	wasm:            wasm.Options,
	html:            html.Options,
}

PREFS := [?]config.Def{
	{name = "page.max_fetch_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most response data one page's scripts may keep alive through fetch records. Past it, further data is refused."},
}

register_prefs :: proc(p: ^config.Prefs) {
	config.register(p, PREFS[:])
	wasm.register_prefs(p)
	html.register_prefs(p)
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		max_fetch_bytes = int(config.int_of(p, "page.max_fetch_bytes")),
		wasm = wasm.options_from_prefs(p),
		html = html.options_from_prefs(p),
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) { html.options_destroy(&s.html) }

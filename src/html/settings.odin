package html

import "core:strings"
import "wb:config"

Options :: struct {
	max_nodes:          int,
	default_encoding:   string,   // owned
	module_script_type: string,   // owned: the `type` of a <script> that names a Wasm module
	preload_scanner:      bool,   // requests leave as a document's bytes arrive (page/preload_scan.odin)
	preload_max_requests: int,
	preload_max_images:   int,
}

PREFS := [?]config.Def{
	{name = "html.max_nodes", kind = .Int, default = {i = 2_000_000}, bounded = true, min = 1000, max = 1 << 30,
		description = "Most nodes built from one document; the rest is dropped (a hostile page cannot exhaust memory)."},
	{name = "html.default_encoding", kind = .String, default = {s = "windows-1252"},
		description = "Encoding assumed when neither the byte-order mark, the Content-Type charset nor a <meta> says (any WHATWG label)."},
	{name = "html.module_script_type", kind = .String, default = {s = "application/wasm"},
		description = "The type attribute that makes a <script> element name a WebAssembly module (<script type=... src=...>)."},
	{name = "html.preload.enabled", kind = .Bool, default = {b = true},
		description = "Requests for the scripts, stylesheets, images and fonts a document names leave while its bytes arrive, before it is parsed; the elements then take these requests over. Off: nothing is asked before the document is parsed."},
	{name = "html.preload.max_requests", kind = .Int, default = {i = 256}, bounded = true, min = 0, max = 100_000,
		description = "Most requests asked ahead of the parser for one document."},
	{name = "html.preload.max_images", kind = .Int, default = {i = 16}, bounded = true, min = 0, max = 100_000,
		description = "Of those, how many images: the first of a document are the likely ones on screen; the rest wait for the page's own order, nearest the viewport first."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

options_from_prefs :: proc(p: ^config.Prefs) -> Options {
	return Options{
		max_nodes = int(config.int_of(p, "html.max_nodes")),
		default_encoding = strings.clone(config.string_of(p, "html.default_encoding")),
		module_script_type = strings.clone(config.string_of(p, "html.module_script_type")),
		preload_scanner = config.bool_of(p, "html.preload.enabled"),
		preload_max_requests = int(config.int_of(p, "html.preload.max_requests")),
		preload_max_images = int(config.int_of(p, "html.preload.max_images")),
	}
}

options_default :: proc() -> Options {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return options_from_prefs(&p)
}

options_destroy :: proc(o: ^Options) {
	delete(o.default_encoding)
	delete(o.module_script_type)
	o^ = {}
}

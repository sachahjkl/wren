package html

import "core:strings"
import "wb:config"

Options :: struct {
	max_nodes:          int,
	default_encoding:   string,   // owned
	module_script_type: string,   // owned: the `type` of a <script> that names a Wasm module
}

PREFS := [?]config.Def{
	{name = "html.max_nodes", kind = .Int, default = {i = 2_000_000}, bounded = true, min = 1000, max = 1 << 30,
		description = "Most nodes built from one document; the rest is dropped (a hostile page cannot exhaust memory)."},
	{name = "html.default_encoding", kind = .String, default = {s = "windows-1252"},
		description = "Encoding assumed when neither the byte-order mark, the Content-Type charset nor a <meta> says (any WHATWG label)."},
	{name = "html.module_script_type", kind = .String, default = {s = "application/wasm"},
		description = "The type attribute that makes a <script> element name a WebAssembly module (<script type=... src=...>)."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

options_from_prefs :: proc(p: ^config.Prefs) -> Options {
	return Options{
		max_nodes = int(config.int_of(p, "html.max_nodes")),
		default_encoding = strings.clone(config.string_of(p, "html.default_encoding")),
		module_script_type = strings.clone(config.string_of(p, "html.module_script_type")),
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

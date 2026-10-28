#+build windows, linux, darwin
package frontend

// Preferences for the front-end. Only hosted targets build this file; the freestanding_wasm32 build never pulls
// in the preference registry (it has no OS) and the caller passes options directly. The limits guard the parser
// against hostile input: a page cannot make the parser recurse without bound or allocate a huge AST, because the
// parser charges a nesting level per recursion and stops at the cap.

import "wb:config"

DEFAULT_MAX_NESTING :: 2000
DEFAULT_MAX_SOURCE_BYTES :: 64 << 20 // 64 MiB

PREFS := [?]config.Def{
	{name = "frontend.parser.max_nesting", kind = .Int, default = {i = DEFAULT_MAX_NESTING}, bounded = true,
		min = 16, max = 1 << 20,
		description = "Deepest nesting of expressions, statements and functions the parser accepts before it reports a syntax error. Bounds parser recursion so a pathological input (thousands of nested parentheses) cannot overflow the stack."},
	{name = "frontend.parser.max_source_bytes", kind = .Int, default = {i = DEFAULT_MAX_SOURCE_BYTES}, bounded = true,
		min = 1 << 10, max = 1 << 32,
		description = "Largest source, in bytes, the front-end will parse in one call. A larger input is rejected before scanning so a single script cannot exhaust memory."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

Parse_Limits :: struct {
	max_nesting:      int,
	max_source_bytes: int,
}

limits_from_prefs :: proc(p: ^config.Prefs) -> Parse_Limits {
	return Parse_Limits{
		max_nesting = int(config.int_of(p, "frontend.parser.max_nesting")),
		max_source_bytes = int(config.int_of(p, "frontend.parser.max_source_bytes")),
	}
}

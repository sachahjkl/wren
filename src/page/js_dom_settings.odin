package page

import "wb:config"

// Limits of the DOM as JavaScript reaches it (preferences `javascript.dom.*`).
Js_Dom_Settings :: struct {
	max_fragment_nodes:     int,    // innerHTML / insertAdjacentHTML / outerHTML: nodes one parse may build
	selector_cache_entries: int,    // parsed selector lists kept for querySelector & co
	max_mutation_records:   int,    // records one MutationObserver may have waiting
	max_rects:              int,    // getClientRects: rectangles of one element or range
}

JS_DOM_PREFS := [?]config.Def{
	{name = "javascript.dom.max_fragment_nodes", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 1_000, max = 100_000_000, unit = "nodes",
		description = "Most nodes one assignment of innerHTML / outerHTML or one insertAdjacentHTML may create. The rest of the markup is dropped (with a warning in the console), so a script cannot exhaust memory in one call."},
	{name = "javascript.dom.selector_cache_entries", kind = .Int, default = {i = 128}, bounded = true, min = 0, max = 100_000, unit = "selector lists",
		description = "Parsed selector lists kept per page for querySelector, querySelectorAll, matches and closest: a selector used again (in a loop) is not parsed again. 0 parses every time."},
	{name = "javascript.dom.max_mutation_records", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 100, max = 1 << 30, unit = "records",
		description = "Most records one MutationObserver may have waiting for delivery. Past it the oldest are dropped (with a warning in the console): a page that mutates without ever yielding cannot grow the queue without bound."},
	{name = "javascript.dom.max_client_rects", kind = .Int, default = {i = 100_000}, bounded = true, min = 1, max = 10_000_000, unit = "rectangles",
		description = "Most rectangles getClientRects returns for one element or range."},
}

js_dom_settings_from_prefs :: proc(p: ^config.Prefs) -> Js_Dom_Settings {
	return Js_Dom_Settings{
		max_fragment_nodes = int(config.int_of(p, "javascript.dom.max_fragment_nodes")),
		selector_cache_entries = int(config.int_of(p, "javascript.dom.selector_cache_entries")),
		max_mutation_records = int(config.int_of(p, "javascript.dom.max_mutation_records")),
		max_rects = int(config.int_of(p, "javascript.dom.max_client_rects")),
	}
}

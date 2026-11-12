package page

import "wb:config"
import "wb:dom"

// Limits of the DOM as JavaScript reaches it (preferences `javascript.dom.*`).
Js_Dom_Settings :: struct {
	max_fragment_nodes:     int,    // innerHTML / insertAdjacentHTML / outerHTML: nodes one parse may build
	selector_cache_entries: int,    // parsed selector lists kept for querySelector & co
	max_mutation_records:   int,    // records one MutationObserver may have waiting
	max_rects:              int,    // getClientRects: rectangles of one element or range
	style_cache_entries:    int,    // parsed style attributes (and setProperty values) kept for element.style
	max_resize_passes:      int,    // times one rendering update delivers resize observations again for what the callbacks changed
	max_nodes:              int,    // nodes of one document (dom.Limits)
	max_bytes:              int,    // bytes of the text, names and attributes of one document's nodes (dom.Limits)
	max_listeners:          int,    // event listeners of one target: a node, a host object, the Window (dom.Limits)
}

// The bounds the page's document applies to what scripts build in it.
js_dom_limits :: proc(s: Js_Dom_Settings) -> dom.Limits {
	return dom.Limits{max_nodes = s.max_nodes, max_bytes = s.max_bytes, max_listeners = s.max_listeners}
}

JS_DOM_PREFS := [?]config.Def{
	{name = "javascript.dom.max_fragment_nodes", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 1_000, max = 100_000_000, unit = "nodes",
		description = "Most nodes one HTML fragment parse (innerHTML, outerHTML, insertAdjacentHTML, setHTMLUnsafe, Document.parseHTMLUnsafe) may create. The rest of the markup is dropped (with a warning in the console), so a script cannot exhaust memory in one call."},
	{name = "javascript.dom.selector_cache_entries", kind = .Int, default = {i = 128}, bounded = true, min = 0, max = 100_000, unit = "selector lists",
		description = "Parsed selector lists kept per page for querySelector, querySelectorAll, matches and closest: a selector used again (in a loop) is not parsed again. 0 parses every time."},
	{name = "javascript.dom.max_mutation_records", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 100, max = 1 << 30, unit = "records",
		description = "Most records one MutationObserver may have waiting for delivery. Past it the oldest are dropped (during a delivery, the newest), with a warning in the console: a page that mutates without ever yielding cannot grow the queue without bound."},
	{name = "javascript.dom.max_client_rects", kind = .Int, default = {i = 100_000}, bounded = true, min = 1, max = 10_000_000, unit = "rectangles",
		description = "Most rectangles Range.getClientRects returns (and Range.getBoundingClientRect unites). An element has at most one."},
	{name = "javascript.dom.style_cache_entries", kind = .Int, default = {i = 4096}, bounded = true, min = 0, max = 100_000, unit = "style attributes",
		description = "Parsed style attributes, and validated style.setProperty values, kept per page for element.style (each): reading or changing a declaration in a loop does not parse again. Enough for the elements a script animates (each element's current text is one entry: fewer, and an animation of more elements parses every attribute again). 0 parses every time."},
	{name = "javascript.dom.max_resize_passes", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 100, unit = "passes",
		description = "Times one rendering update delivers ResizeObserver entries again for what the callbacks changed (Resize Observer: the loop of \"gather active observations\"). What is still changing after that waits for the next frame, as browsers do (\"ResizeObserver loop completed with undelivered notifications\"), so a callback that always resizes its target cannot stall the page."},
	{name = "javascript.dom.max_nodes", kind = .Int, default = {i = 4_000_000}, bounded = true, min = 10_000, max = 1 << 30, unit = "nodes",
		description = "Most nodes one document may hold (in its tree or not). Past it, inserting a new node fails with QuotaExceededError, so a script that loops creating nodes cannot exhaust the browser's memory (a node takes about 200 bytes). The largest real pages have about 100,000."},
	{name = "javascript.dom.max_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most bytes of text, element names and attributes one document's nodes may hold. Past it, a write that adds bytes (text, attribute values, textContent) fails with QuotaExceededError."},
	{name = "javascript.dom.max_listeners_per_target", kind = .Int, default = {i = 20_000}, bounded = true, min = 100, max = 10_000_000, unit = "listeners",
		description = "Most event listeners one target (an element, the document, the Window, any other EventTarget) may have. Past it, addEventListener fails with QuotaExceededError. Each addition compares with the target's listeners, so this also bounds the time one takes."},
}

js_dom_settings_from_prefs :: proc(p: ^config.Prefs) -> Js_Dom_Settings {
	return Js_Dom_Settings{
		max_fragment_nodes = int(config.int_of(p, "javascript.dom.max_fragment_nodes")),
		selector_cache_entries = int(config.int_of(p, "javascript.dom.selector_cache_entries")),
		max_mutation_records = int(config.int_of(p, "javascript.dom.max_mutation_records")),
		max_rects = int(config.int_of(p, "javascript.dom.max_client_rects")),
		style_cache_entries = int(config.int_of(p, "javascript.dom.style_cache_entries")),
		max_resize_passes = int(config.int_of(p, "javascript.dom.max_resize_passes")),
		max_nodes = int(config.int_of(p, "javascript.dom.max_nodes")),
		max_bytes = int(config.int_of(p, "javascript.dom.max_bytes")),
		max_listeners = int(config.int_of(p, "javascript.dom.max_listeners_per_target")),
	}
}

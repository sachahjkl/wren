package a11y

import "wb:config"

// The accessibility tree of pages (about:config, `accessibility.page.*`). The chrome's own tree is the toolkit's.

Settings :: struct {
	enabled:     bool,   // false: pages show no tree to assistive technologies (the chrome's stays)
	incremental: bool,   // false: every change makes a whole tree (then diffed): for comparisons
	verify:      bool,   // every patch compared with a whole tree, a difference logged (slow: for debugging)
	max_nodes:   int,    // nodes of one document's tree at most
	frames:      bool,   // the documents of frames (iframes) grafted under their element
}

PREFS := [?]config.Def{
	{name = "accessibility.page.enabled", kind = .Bool, default = {b = true},
		description = "Show the content of pages to screen readers and other assistive technologies. Off, only the browser's own interface is read."},
	{name = "accessibility.page.incremental", kind = .Bool, default = {b = true},
		description = "Update a page's accessibility tree node by node from the changes of its document. Off, any change builds the whole tree again (only the differences are sent)."},
	{name = "accessibility.page.verify", kind = .Bool, default = {b = false},
		description = "Compare every node-by-node update of a page's accessibility tree with a whole tree and log a difference (slow; for debugging)."},
	{name = "accessibility.page.max_nodes", kind = .Int, default = {i = 50_000}, bounded = true, min = 100, max = 10_000_000, unit = "nodes",
		description = "Most nodes of one document's accessibility tree; what comes after is left out."},
	{name = "accessibility.page.frames", kind = .Bool, default = {b = true},
		description = "Show the documents of frames (iframes) to assistive technologies, under their frame element."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "accessibility.page.enabled"),
		incremental = config.bool_of(p, "accessibility.page.incremental"),
		verify = config.bool_of(p, "accessibility.page.verify"),
		max_nodes = int(config.int_of(p, "accessibility.page.max_nodes")),
		frames = config.bool_of(p, "accessibility.page.frames"),
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

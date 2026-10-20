package page

import "wb:config"

// Preferences of script loading and of the event loop's JavaScript side (js_load*.odin, js_workers.odin).
Js_Load_Settings :: struct {
	poll_ms:              f64,    // how often a waiting page looks again (load event, scripts waiting for stylesheets)
	scripts_wait_styles:  bool,   // parser-blocking scripts wait for the stylesheets that block scripts
	load_waits_resources: bool,   // the load event waits for images, stylesheets and fonts
	load_timeout_ms:      f64,    // ... at most this long after DOMContentLoaded (-1 = no limit)
	write_max_bytes:      int,    // document.write: total markup one document may write
	write_max_depth:      int,    // document.write: nested writes (a written script writing...)
	module_max_count:     int,    // modules in one page's module map
	import_maps:          bool,
	content_handlers:     bool,   // onclick="..." attributes
	javascript_urls:      bool,   // <a href="javascript:..."> and location = "javascript:..."
	compile_threads:      int,    // off-thread compilation of large scripts (-1 = automatic, 0 = none)
	import_scripts_ms:    i64,    // importScripts: longest wait for one script (-1 = no limit)
}

JS_LOAD_PREFS := [?]config.Def{
	{name = "javascript.load.poll_ms", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 10_000, unit = "ms",
		description = "How often a loading page looks again whether something it waits for is there (the load event waiting for images, stylesheets and fonts; a script waiting for a stylesheet)."},
	{name = "javascript.load.scripts_wait_for_stylesheets", kind = .Bool, default = {b = true},
		description = "A script of the parser waits for the stylesheets before it that are still loading (HTML \"a style sheet that is blocking scripts\"), so it sees the page's styles. At most style.render_blocking.timeout_ms."},
	{name = "javascript.load.event_waits_for_resources", kind = .Bool, default = {b = true},
		description = "The load event of the window waits for the document's images, stylesheets and fonts, as HTML says. Off: it fires right after DOMContentLoaded and the async scripts."},
	{name = "javascript.load.event_timeout_ms", kind = .Int, default = {i = -1}, bounded = true, min = -1, max = 3_600_000, unit = "ms",
		description = "Longest wait of the load event for the document's resources after DOMContentLoaded. -1 = as long as they load (a resource that never finishes delays it until the network gives up)."},
	{name = "javascript.document_write.max_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 0, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Most markup one document may write with document.write. Past it, further writes are ignored (the console says so)."},
	{name = "javascript.document_write.max_depth", kind = .Int, default = {i = 20}, bounded = true, min = 1, max = 1000,
		description = "Most nested document.write calls (a written script that writes, and so on). Deeper ones are ignored, as in other browsers."},
	{name = "javascript.modules.max_count", kind = .Int, default = {i = 10_000}, bounded = true, min = 1, max = 1_000_000, unit = "modules",
		description = "Most ES modules one page may load. A graph that needs more fails with an error in the console."},
	{name = "javascript.modules.import_maps", kind = .Bool, default = {b = true},
		description = "Apply <script type=importmap> (bare specifiers like \"lodash\" mapped to URLs). Off: import maps are ignored."},
	{name = "javascript.handlers.content_attributes", kind = .Bool, default = {b = true},
		description = "Run event handlers written as attributes (onclick=\"...\", <body onload=\"...\">). Off: those attributes do nothing; handlers set from scripts still work."},
	{name = "javascript.urls.enabled", kind = .Bool, default = {b = true},
		description = "Run javascript: URLs (links, location = \"javascript:...\"). Off: they do nothing."},
	{name = "javascript.compile.offthread_threads", kind = .Int, default = {i = -1}, bounded = true, min = -1, max = 64, unit = "threads",
		description = "Threads that compile large scripts (javascript.compile.offthread_min_bytes) to bytecode while the page does other work. -1 = one per two logical processors, at most 4; 0 = compile on the interface thread. Raising it takes effect at once; lowering it (other than to 0) at the next start."},
	{name = "javascript.workers.import_scripts_timeout_ms", kind = .Int, default = {i = 60_000}, bounded = true, min = -1, max = 3_600_000, unit = "ms",
		description = "Longest wait of a worker's importScripts() for one script (it blocks the worker until the script arrives). -1 = no limit."},
}

js_load_settings_from_prefs :: proc(p: ^config.Prefs) -> Js_Load_Settings {
	return Js_Load_Settings{
		poll_ms = f64(config.int_of(p, "javascript.load.poll_ms")),
		scripts_wait_styles = config.bool_of(p, "javascript.load.scripts_wait_for_stylesheets"),
		load_waits_resources = config.bool_of(p, "javascript.load.event_waits_for_resources"),
		load_timeout_ms = f64(config.int_of(p, "javascript.load.event_timeout_ms")),
		write_max_bytes = int(config.int_of(p, "javascript.document_write.max_bytes")),
		write_max_depth = int(config.int_of(p, "javascript.document_write.max_depth")),
		module_max_count = int(config.int_of(p, "javascript.modules.max_count")),
		import_maps = config.bool_of(p, "javascript.modules.import_maps"),
		content_handlers = config.bool_of(p, "javascript.handlers.content_attributes"),
		javascript_urls = config.bool_of(p, "javascript.urls.enabled"),
		compile_threads = int(config.int_of(p, "javascript.compile.offthread_threads")),
		import_scripts_ms = config.int_of(p, "javascript.workers.import_scripts_timeout_ms"),
	}
}

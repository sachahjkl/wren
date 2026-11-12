package extensions

import "wb:config"

// The preferences of browser extensions (docs/extensions.md, section 3.11 rule 13). Every limit has a reason: a hostile
// package, the cost of matching per document, Chrome's own numbers where an extension counts on them.
Settings :: struct {
	enabled:                bool,
	max_installed:          int,
	manifest_max_bytes:     int,
	package_max_files:      int,
	package_max_bytes:      i64,
	content_scripts_max:    int,
	background_idle_ms:     int,
	port_keepalive_ms:      int,
	background_failed_starts_max: int,   // starts in a row whose script did not run before the background is left stopped
	storage_local_max:      int,
	storage_session_max:    int,
	storage_sync_max:       int,
	storage_sync_item_max:  int,
	storage_sync_max_items: int,
	message_max_bytes:      int,
	ports_max:              int,
	events_max_queued:      int,
	calls_max_pending:      int,
	alarms_min_period_ms:   int,
	alarms_max:             int,
	toolbar_max_buttons:    int,
	offscreen_max_ms:       int,      // the lifetime of an offscreen document whose only reason is CLIPBOARD
	restricted_hosts:       string,   // space-separated hosts no extension acts on
	worlds_max:             int,      // isolated worlds in one document (one engine instance each)
	scripting_max_registered: int,    // scripting.registerContentScripts entries of one extension
	idle_after_parsed_ms:   int,      // document_idle comes at the load event, or this long after the parse
}

PREFS := [?]config.Def{
	{name = "extensions.enabled", kind = .Bool, default = {b = true},
		description = "Run browser extensions (WebExtensions, Manifest V3). Off: no extension loads, no toolbar button shows, and the pages cost nothing more. The installed extensions stay in the profile."},
	{name = "extensions.max_installed", kind = .Int, default = {i = 64}, bounded = true, min = 1, max = 1000,
		description = "Most extensions installed at once. Each one costs a toolbar button and a match test per document."},
	{name = "extensions.manifest.max_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 4096, max = 64 << 20, bytes = true, unit = "bytes",
		description = "Largest manifest.json (and largest messages.json of a locale) read. A larger file refuses the extension."},
	{name = "extensions.package.max_files", kind = .Int, default = {i = 20_000}, bounded = true, min = 10, max = 1_000_000,
		description = "Most files in one extension package. A package with more is refused: a hostile archive or a wrong folder."},
	{name = "extensions.package.max_bytes", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 1 << 20, max = 1 << 34, bytes = true, unit = "bytes",
		description = "Largest total size of the files of one extension package. A larger package is refused."},
	{name = "extensions.content_scripts.max_entries", kind = .Int, default = {i = 100}, bounded = true, min = 1, max = 10_000,
		description = "Most content_scripts entries in one manifest. Each one is matched against every document."},
	{name = "extensions.background.idle_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "An extension's background service worker stops after this long with no event, no pending call and no open port (Chrome's value). It starts again for its next event."},
	{name = "extensions.background.port_keepalive_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "An open port keeps the background alive this long after its last message."},
	{name = "extensions.background.failed_starts_max", kind = .Int, default = {i = 3}, bounded = true, min = 1, max = 1000,
		description = "An extension's background whose script fails this many times in a row before it runs is not started again until the extension is reloaded: what is sent to it fails at once, instead of a new start for each event."},
	{name = "extensions.storage.local.max_bytes", kind = .Int, default = {i = 10 << 20}, bounded = true, min = 1 << 16, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Most bytes of storage.local for one extension (Chrome's value). An extension with the unlimitedStorage permission has no limit."},
	{name = "extensions.storage.session.max_bytes", kind = .Int, default = {i = 10 << 20}, bounded = true, min = 1 << 16, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Most bytes of storage.session for one extension (Chrome's value). It is kept in memory only."},
	{name = "extensions.storage.sync.max_bytes", kind = .Int, default = {i = 102_400}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Most bytes of storage.sync for one extension (Chrome's value). storage.sync stays on this computer."},
	{name = "extensions.storage.sync.max_item_bytes", kind = .Int, default = {i = 8192}, bounded = true, min = 64, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest item of storage.sync: its key and its JSON value (Chrome's value)."},
	{name = "extensions.storage.sync.max_items", kind = .Int, default = {i = 512}, bounded = true, min = 1, max = 1 << 20,
		description = "Most items of storage.sync for one extension (Chrome's value)."},
	{name = "extensions.message.max_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest message, call argument or answer between the parts of an extension, as JSON text (Chrome's value). A larger one fails with an error."},
	{name = "extensions.ports.max_per_extension", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 100_000,
		description = "Most ports (runtime.connect) open at once for one extension. One more fails with an error."},
	{name = "extensions.events.max_queued", kind = .Int, default = {i = 10_000}, bounded = true, min = 10, max = 1_000_000,
		description = "Most events waiting for one context of an extension (a background that starts, a page that is busy). One more fails its sender with an error."},
	{name = "extensions.calls.max_pending", kind = .Int, default = {i = 10_000}, bounded = true, min = 10, max = 1_000_000,
		description = "Most API calls of one context of an extension waiting for their answer. One more fails with an error."},
	{name = "extensions.alarms.min_period_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 0, max = 86_400_000, unit = "ms",
		description = "Shortest delay and period of an extension's alarm (Chrome's value). A shorter one is raised to this."},
	{name = "extensions.alarms.max_per_extension", kind = .Int, default = {i = 500}, bounded = true, min = 1, max = 100_000,
		description = "Most alarms of one extension (Chrome's value). One more fails with an error."},
	{name = "browser.extensions.toolbar.max_buttons", kind = .Int, default = {i = 8}, bounded = true, min = 0, max = 100,
		description = "Most extension buttons in the toolbar. The others go into the extensions menu."},
	{name = "extensions.offscreen.max_lifetime_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "An extension's offscreen document made only to use the clipboard closes after this long. Other offscreen documents stay until the extension closes them."},
	{name = "extensions.restricted_hosts", kind = .String, default = {s = ""},
		description = "Hosts no extension acts on (no content script, no tab data), separated by spaces."},
	{name = "extensions.worlds.max_per_document", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 256,
		description = "Most extensions whose content scripts run in one document. Each one runs in a JavaScript engine of its own beside the page's (an isolated world); the extensions past this number get no content script there."},
	{name = "extensions.scripting.max_registered", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 100_000,
		description = "Most content scripts one extension registers with scripting.registerContentScripts. Each one is matched against every document."},
	{name = "extensions.content_scripts.idle_ms", kind = .Int, default = {i = 200}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Content scripts that run at document_idle run at the document's load event, or this long after the document was parsed if that comes first (Chrome's value)."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

// The strings of the result are the preferences' (valid until they change).
settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "extensions.enabled"),
		max_installed = int(config.int_of(p, "extensions.max_installed")),
		manifest_max_bytes = int(config.int_of(p, "extensions.manifest.max_bytes")),
		package_max_files = int(config.int_of(p, "extensions.package.max_files")),
		package_max_bytes = config.int_of(p, "extensions.package.max_bytes"),
		content_scripts_max = int(config.int_of(p, "extensions.content_scripts.max_entries")),
		background_idle_ms = int(config.int_of(p, "extensions.background.idle_ms")),
		port_keepalive_ms = int(config.int_of(p, "extensions.background.port_keepalive_ms")),
		background_failed_starts_max = int(config.int_of(p, "extensions.background.failed_starts_max")),
		storage_local_max = int(config.int_of(p, "extensions.storage.local.max_bytes")),
		storage_session_max = int(config.int_of(p, "extensions.storage.session.max_bytes")),
		storage_sync_max = int(config.int_of(p, "extensions.storage.sync.max_bytes")),
		storage_sync_item_max = int(config.int_of(p, "extensions.storage.sync.max_item_bytes")),
		storage_sync_max_items = int(config.int_of(p, "extensions.storage.sync.max_items")),
		message_max_bytes = int(config.int_of(p, "extensions.message.max_bytes")),
		ports_max = int(config.int_of(p, "extensions.ports.max_per_extension")),
		events_max_queued = int(config.int_of(p, "extensions.events.max_queued")),
		calls_max_pending = int(config.int_of(p, "extensions.calls.max_pending")),
		alarms_min_period_ms = int(config.int_of(p, "extensions.alarms.min_period_ms")),
		alarms_max = int(config.int_of(p, "extensions.alarms.max_per_extension")),
		toolbar_max_buttons = int(config.int_of(p, "browser.extensions.toolbar.max_buttons")),
		offscreen_max_ms = int(config.int_of(p, "extensions.offscreen.max_lifetime_ms")),
		restricted_hosts = config.string_of(p, "extensions.restricted_hosts"),
		worlds_max = int(config.int_of(p, "extensions.worlds.max_per_document")),
		scripting_max_registered = int(config.int_of(p, "extensions.scripting.max_registered")),
		idle_after_parsed_ms = int(config.int_of(p, "extensions.content_scripts.idle_ms")),
	}
}

// The defaults, without a preference store (unit tests, tools).
settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

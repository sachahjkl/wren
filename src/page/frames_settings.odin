package page

import "wb:config"

// Nested browsing contexts (preferences `frames.*`, frames.odin).
Frame_Settings :: struct {
	enabled:            bool,
	max_per_page:       int,
	max_depth:          int,
	max_total:          int,
	lazy_margin_px:     f32,
	x_frame_options:    bool,
	frame_ancestors:    bool,
	max_message_bytes:  int,
	storage_partition:  bool,
	error_pages:        bool,
	access_requests:    Storage_Access_Policy,   // storage.access_requests (storage_access.odin)
	access_activation_ms: int,
}

Storage_Access_Policy :: enum u8 { Ask, Allow, Deny }

FRAME_PREFS := [?]config.Def{
	{name = "frames.enabled", kind = .Bool, default = {b = true},
		description = "Show the documents of <iframe> and <frame> elements (each one a document of its own, with its own origin, scripts and history). Off: they stay empty boxes."},
	{name = "frames.max_per_page", kind = .Int, default = {i = 1000}, bounded = true, min = 0, max = 100_000,
		description = "Most nested documents one document may contain at the same time (its own frames, not its frames' frames). Past it, more frame elements stay empty."},
	{name = "frames.max_depth", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 256,
		description = "Deepest nesting of frames in a tab (a frame in a frame in a frame...). Deeper frame elements stay empty."},
	{name = "frames.max_total", kind = .Int, default = {i = 4000}, bounded = true, min = 1, max = 1_000_000,
		description = "Most nested documents in the whole browser at the same time. Each one is a document with its own JavaScript engine instance when it runs scripts."},
	{name = "frames.lazy_margin_px", kind = .Float, default = {f = 1250}, bounded = true, min = 0, max = 100_000, unit = "CSS px",
		description = "An <iframe loading=lazy> starts loading when it comes this close to the viewport."},
	{name = "frames.x_frame_options", kind = .Bool, default = {b = true},
		description = "Honour X-Frame-Options: a document that says DENY or SAMEORIGIN is not shown in a frame of another origin (protection against clickjacking). Off only to debug."},
	{name = "frames.frame_ancestors", kind = .Bool, default = {b = true},
		description = "Honour Content-Security-Policy frame-ancestors of framed documents (who may embed them). Off only to debug; security.csp.enabled off turns it off too."},
	{name = "frames.max_message_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 10, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Largest message window.postMessage may send to another document (a frame, the parent). Larger ones throw DataCloneError."},
	{name = "storage.access_requests", kind = .String, default = {s = "ask"}, choices = {"ask", "allow", "deny"},
		description = "What happens when a frame of another site asks for its own cookies and storage (document.requestStorageAccess(), after a click in it): ask shows a prompt over the page (Allow / Block, remembered for the session per frame site and page site); allow grants it without asking; deny refuses it. Only meaningful with storage.partitioned or privacy.third_party_cookies = block."},
	{name = "storage.access_activation_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 0, max = 600_000, unit = "ms",
		description = "How long after a click or a key press in a frame document.requestStorageAccess() may still ask (HTML's transient user activation)."},
	{name = "frames.error_pages", kind = .Bool, default = {b = true},
		description = "A frame whose document cannot be shown (refused by X-Frame-Options or frame-ancestors, network error) shows a short explanation, as Chromium does. Off: it stays blank."},
}

frame_settings_from_prefs :: proc(p: ^config.Prefs) -> Frame_Settings {
	return Frame_Settings{
		enabled = config.bool_of(p, "frames.enabled"),
		max_per_page = int(config.int_of(p, "frames.max_per_page")),
		max_depth = int(config.int_of(p, "frames.max_depth")),
		max_total = int(config.int_of(p, "frames.max_total")),
		lazy_margin_px = f32(config.float_of(p, "frames.lazy_margin_px")),
		x_frame_options = config.bool_of(p, "frames.x_frame_options"),
		frame_ancestors = config.bool_of(p, "frames.frame_ancestors"),
		max_message_bytes = int(config.int_of(p, "frames.max_message_bytes")),
		storage_partition = config.bool_of(p, "storage.partitioned"),   // (declared with the network's: fetch/settings.odin)
		error_pages = config.bool_of(p, "frames.error_pages"),
		access_requests = config.string_of(p, "storage.access_requests") == "allow" ? .Allow : config.string_of(p, "storage.access_requests") == "deny" ? .Deny : .Ask,
		access_activation_ms = int(config.int_of(p, "storage.access_activation_ms")),
	}
}

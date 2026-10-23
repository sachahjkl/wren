package blocker

import "wb:config"

// Everything the content blocker lets a user or administrator tune (about:config: `blocker.*`). Per-site choices, lists,
// rules and filters are not preferences: they live in the blocker's own configuration file (config_file.odin), which the
// native dashboard (about:blocker) edits and can export and import as one file.

Settings :: struct {
	enabled:          bool,
	cosmetic:         bool,
	scriptlets:       bool,
	collapse:         bool,
	redirects:        bool,
	removeparam:      bool,
	update:           bool,
	update_hours:     int,
	update_delay_s:   int,
	max_list_bytes:   int,
	log_capacity:     int,
	log_always:       bool,
	large_media_kb:   int,
	hard_mode:        bool,
	remote_fonts:     bool,    // block remote fonts everywhere
	debounce_ms:      int,
	max_selectors:    int,
	engine_cache:     bool,
	badge:            bool,
	max_hosts_per_tab: int,
	graph_points:     int,
}

PREFS := [?]config.Def{
	{name = "blocker.enabled", kind = .Bool, default = {b = true},
		description = "The content blocker: requests to advertising, tracking and malware servers are stopped before they leave the machine, and the page elements they leave behind are hidden. Off: no request is looked at (no cost at all)."},
	{name = "blocker.cosmetic.enabled", kind = .Bool, default = {b = true},
		description = "Hide page elements named by cosmetic filters (the empty boxes of blocked ads, banners, cookie notices), before the first paint."},
	{name = "blocker.scriptlets.enabled", kind = .Bool, default = {b = true},
		description = "Run the scriptlet rules (##+js(...)) of the filter lists in the page before its own scripts: they neutralize anti-blocker scripts and in-page ads (YouTube's included)."},
	{name = "blocker.collapse.enabled", kind = .Bool, default = {b = true},
		description = "Collapse the frames and images whose request was blocked, so they leave no empty box."},
	{name = "blocker.redirects.enabled", kind = .Bool, default = {b = true},
		description = "Answer blocked scripts, images and frames with a neutral stand-in ($redirect rules) instead of an error, so pages that wait for them keep working."},
	{name = "blocker.removeparam.enabled", kind = .Bool, default = {b = true},
		description = "Strip tracking parameters from URLs ($removeparam rules)."},
	{name = "blocker.update.enabled", kind = .Bool, default = {b = true},
		description = "Download the filter lists in the background and keep them up to date. Off: only the lists already downloaded (and the built-in base list) are used, and nothing is ever fetched."},
	{name = "blocker.update.interval_hours", kind = .Int, default = {i = 24}, bounded = true, min = 1, max = 24 * 90, unit = "h",
		description = "How often the lists are checked for a newer version (conditional requests: an unchanged list costs a few hundred bytes)."},
	{name = "blocker.update.start_delay_s", kind = .Int, default = {i = 15}, bounded = true, min = 0, max = 3600, unit = "s",
		description = "Seconds after start-up before the first list check, so the first pages load undisturbed."},
	{name = "blocker.update.max_list_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1 << 20, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest list accepted from a download; a bigger answer is refused and the previous copy is kept."},
	{name = "blocker.log.capacity", kind = .Int, default = {i = 5000}, bounded = true, min = 100, max = 1_000_000,
		description = "Entries kept by the request log of the dashboard (Journal)."},
	{name = "blocker.log.always", kind = .Bool, default = {b = false},
		description = "Record requests in the log even when no dashboard shows it (the log costs a few allocations per request)."},
	{name = "blocker.large_media_kb", kind = .Int, default = {i = 2048}, bounded = true, min = 1, max = 1 << 24, unit = "KB",
		description = "Media larger than this are blocked on sites where 'block large media' is on (decided from Content-Length, before the body is read)."},
	{name = "blocker.hard_mode", kind = .Bool, default = {b = false},
		description = "Hard mode for every site: all third-party scripts and frames are blocked unless a rule allows them (per-site switches override this)."},
	{name = "blocker.remote_fonts", kind = .Bool, default = {b = false},
		description = "Block remote web fonts on every site (per-site switches override this)."},
	{name = "blocker.cosmetic.debounce_ms", kind = .Int, default = {i = 30}, bounded = true, min = 0, max = 2000, unit = "ms",
		description = "Elements added to a page after it loaded are checked against the cosmetic filters at most this often."},
	{name = "blocker.cosmetic.max_selectors", kind = .Int, default = {i = 20000}, bounded = true, min = 100, max = 1_000_000,
		description = "Most cosmetic selectors applied to one page (a guard against pathological pages)."},
	{name = "blocker.engine.cache", kind = .Bool, default = {b = true},
		description = "Keep the compiled filter index in the profile so that start-up loads it in a few milliseconds instead of compiling the lists."},
	{name = "blocker.badge.enabled", kind = .Bool, default = {b = true},
		description = "Show the number of blocked requests on the blocker icon of the address row."},
	{name = "blocker.matrix.max_hosts", kind = .Int, default = {i = 1500}, bounded = true, min = 50, max = 100_000,
		description = "Most distinct hosts the matrix of a tab remembers."},
	{name = "blocker.graph.points", kind = .Int, default = {i = 2048}, bounded = true, min = 64, max = 100_000,
		description = "Blocked requests of a page kept for the time graph of the panel."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "blocker.enabled"),
		cosmetic = config.bool_of(p, "blocker.cosmetic.enabled"),
		scriptlets = config.bool_of(p, "blocker.scriptlets.enabled"),
		collapse = config.bool_of(p, "blocker.collapse.enabled"),
		redirects = config.bool_of(p, "blocker.redirects.enabled"),
		removeparam = config.bool_of(p, "blocker.removeparam.enabled"),
		update = config.bool_of(p, "blocker.update.enabled"),
		update_hours = int(config.int_of(p, "blocker.update.interval_hours")),
		update_delay_s = int(config.int_of(p, "blocker.update.start_delay_s")),
		max_list_bytes = int(config.int_of(p, "blocker.update.max_list_bytes")),
		log_capacity = int(config.int_of(p, "blocker.log.capacity")),
		log_always = config.bool_of(p, "blocker.log.always"),
		large_media_kb = int(config.int_of(p, "blocker.large_media_kb")),
		hard_mode = config.bool_of(p, "blocker.hard_mode"),
		remote_fonts = config.bool_of(p, "blocker.remote_fonts"),
		debounce_ms = int(config.int_of(p, "blocker.cosmetic.debounce_ms")),
		max_selectors = int(config.int_of(p, "blocker.cosmetic.max_selectors")),
		engine_cache = config.bool_of(p, "blocker.engine.cache"),
		badge = config.bool_of(p, "blocker.badge.enabled"),
		max_hosts_per_tab = int(config.int_of(p, "blocker.matrix.max_hosts")),
		graph_points = int(config.int_of(p, "blocker.graph.points")),
	}
}

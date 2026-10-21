package httpcache

import "core:strings"
import "wb:config"

// The HTTP cache's preferences (about:config: `network.cache.*`).

Settings :: struct {
	enabled:                 bool,
	memory_max_bytes:        i64,
	disk_enabled:            bool,
	disk_max_bytes:          i64,
	directory:               string,   // owned; "" = <profile>/cache
	max_entry_bytes:         i64,
	max_entries:             int,
	heuristic:               Freshness_Settings,
	stale_while_revalidate:  bool,
	partition:               bool,
	keep_unvalidated_documents: bool,
	history_prefer_cache:    bool,
	index_flush_ms:          int,
	read_threads:            int,
}

PREFS := [?]config.Def{
	{name = "network.cache.enabled", kind = .Bool, default = {b = true},
		description = "Keep responses in the HTTP cache (RFC 9111) and reuse them while they are fresh, revalidating them with the server (If-None-Match / If-Modified-Since) when they are not. Off: every request goes to the network, nothing is stored."},
	{name = "network.cache.memory.max_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Responses kept in memory, least recently used out first. With the disk cache, what leaves memory stays on disk; without it, it is gone."},
	{name = "network.cache.disk.enabled", kind = .Bool, default = {b = true}, restart = true,
		description = "Keep the cache in the profile between runs (only when the profile is kept: browser.profile.persist)."},
	{name = "network.cache.disk.max_bytes", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 0, max = 1 << 44, bytes = true, unit = "bytes",
		description = "Size of the cache on disk; the least recently used responses go first."},
	{name = "network.cache.disk.directory", kind = .String, default = {s = ""}, restart = true,
		description = "Folder of the disk cache. Empty: the cache folder of the profile. The cache only ever deletes its own files there."},
	{name = "network.cache.disk.index_flush_ms", kind = .Int, default = {i = 10_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "How soon after a change the index of the disk cache is written again (it is always written when the browser closes; a damaged or old index is rebuilt from the files). 0: only when the browser closes."},
	{name = "network.cache.disk.read_threads", kind = .Int, default = {i = 2}, bounded = true, min = 1, max = 64, restart = true,
		description = "Threads reading responses back from the disk cache."},
	{name = "network.cache.max_entry_bytes", kind = .Int, default = {i = 32 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Largest response the cache stores."},
	{name = "network.cache.max_entries", kind = .Int, default = {i = 100_000}, bounded = true, min = 1, max = 10_000_000,
		description = "Most responses the cache holds."},
	{name = "network.cache.heuristic.fraction", kind = .Float, default = {f = 0.1}, bounded = true, min = 0, max = 1,
		description = "A response without max-age or Expires but with Last-Modified stays fresh for this share of its age when it was received (RFC 9111 §4.2.2 suggests 10 %)."},
	{name = "network.cache.heuristic.max_s", kind = .Int, default = {i = 7 * 86_400}, bounded = true, min = 0, max = 365 * 86_400, unit = "s",
		description = "Longest heuristic freshness."},
	{name = "network.cache.stale_while_revalidate", kind = .Bool, default = {b = true},
		description = "Honor Cache-Control: stale-while-revalidate (RFC 5861): within that window a stale response is used at once and refreshed in the background."},
	{name = "network.cache.partition", kind = .Bool, default = {b = true},
		description = "Key the cache by the site of the page as well as the URL (top-level site, frame site), as Chromium and Firefox do: a site cannot tell from timing whether you visited another. Off: one entry per URL for every site."},
	{name = "network.cache.keep_unvalidated_documents", kind = .Bool, default = {b = true},
		description = "Store documents that have neither freshness nor a validator, for back and forward only (they are never reused otherwise)."},
	{name = "network.cache.history_prefer_cache", kind = .Bool, default = {b = true},
		description = "Back and forward show a page from the cache even when it is stale, without asking the server (as other browsers do). Reload always asks."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.enabled = config.bool_of(p, "network.cache.enabled")
	s.memory_max_bytes = config.int_of(p, "network.cache.memory.max_bytes")
	s.disk_enabled = config.bool_of(p, "network.cache.disk.enabled")
	s.disk_max_bytes = config.int_of(p, "network.cache.disk.max_bytes")
	s.directory = strings.clone(config.string_of(p, "network.cache.disk.directory"))
	s.index_flush_ms = int(config.int_of(p, "network.cache.disk.index_flush_ms"))
	s.read_threads = int(config.int_of(p, "network.cache.disk.read_threads"))
	s.max_entry_bytes = config.int_of(p, "network.cache.max_entry_bytes")
	s.max_entries = int(config.int_of(p, "network.cache.max_entries"))
	s.heuristic = Freshness_Settings{
		heuristic_fraction = config.float_of(p, "network.cache.heuristic.fraction"),
		heuristic_max_s = config.int_of(p, "network.cache.heuristic.max_s"),
	}
	s.stale_while_revalidate = config.bool_of(p, "network.cache.stale_while_revalidate")
	s.partition = config.bool_of(p, "network.cache.partition")
	s.keep_unvalidated_documents = config.bool_of(p, "network.cache.keep_unvalidated_documents")
	s.history_prefer_cache = config.bool_of(p, "network.cache.history_prefer_cache")
	return s
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_clone :: proc(s: Settings) -> Settings {
	r := s
	r.directory = strings.clone(s.directory)
	return r
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.directory)
	s^ = {}
}

package page

import "wb:config"

// Service workers, the Cache API and the origin private file system (preferences `service_workers.*`, `caches.*`,
// `opfs.*`).
Sw_Settings :: struct {
	enabled:          bool,
	fetch_timeout_ms: int,
	cache_max_bytes:  i64,
	opfs_max_bytes:   i64,
}

SW_PREFS := [?]config.Def{
	{name = "service_workers.enabled", kind = .Bool, default = {b = true},
		description = "Let pages register service workers (navigator.serviceWorker): scripts that intercept the requests of the pages in their scope (offline pages, caches). Off: register() is refused and no request is intercepted; registrations already made stay on disk."},
	{name = "service_workers.fetch_timeout_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "How long a request waits for the service worker's answer (respondWith) before it goes to the network as if the worker had not intercepted it. A safety for a worker that never answers, not a measure of speed."},
	{name = "caches.max_bytes_per_origin", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most bytes the Cache API (caches.open, cache.put) keeps for one origin. A put that would go past it is refused with a QuotaExceededError."},
	{name = "opfs.max_bytes_per_origin", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most bytes the origin private file system (navigator.storage.getDirectory) keeps for one origin. A write past it is refused with a QuotaExceededError."},
}

sw_settings_from_prefs :: proc(p: ^config.Prefs) -> Sw_Settings {
	return Sw_Settings{
		enabled = config.bool_of(p, "service_workers.enabled"),
		fetch_timeout_ms = int(config.int_of(p, "service_workers.fetch_timeout_ms")),
		cache_max_bytes = config.int_of(p, "caches.max_bytes_per_origin"),
		opfs_max_bytes = config.int_of(p, "opfs.max_bytes_per_origin"),
	}
}

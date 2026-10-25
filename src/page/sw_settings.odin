package page

import "wb:config"

// Service workers, shared workers, the Cache API and the origin private file system (preferences `service_workers.*`,
// `shared_workers.*`, `caches.*`, `opfs.*`).
Sw_Settings :: struct {
	enabled:          bool,
	fetch_timeout_ms: int,
	idle_ms:          int,      // an idle service worker stops after this (0: never)
	update_hours:     int,      // a navigation checks the worker's script when the last check is older
	cache_max_bytes:  i64,
	opfs_max_bytes:   i64,
	shared_enabled:   bool,
	shared_linger_ms: int,      // extendedLifetime: how long a shared worker outlives its last document
}

SW_PREFS := [?]config.Def{
	{name = "service_workers.enabled", kind = .Bool, default = {b = true},
		description = "Let pages register service workers (navigator.serviceWorker): scripts that intercept the requests of the pages in their scope (offline pages, caches). Off: register() is refused and no request is intercepted; registrations already made stay on disk."},
	{name = "service_workers.fetch_timeout_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "How long a request waits for the service worker's answer (respondWith) before it goes to the network as if the worker had not intercepted it. A safety for a worker that never answers, not a measure of speed."},
	{name = "service_workers.idle_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "A service worker that has had no event to handle (and none pending) for this long is stopped to free its memory and thread; it starts again with the next event. 0: never stopped while the profile is open."},
	{name = "service_workers.update_check_hours", kind = .Int, default = {i = 24}, bounded = true, min = 0, max = 8760, unit = "h",
		description = "A navigation in a service worker's scope checks whether its script changed when the last check is older than this (Service Workers: 24 hours). 0: at every navigation."},
	{name = "shared_workers.enabled", kind = .Bool, default = {b = true},
		description = "Let pages start shared workers (new SharedWorker): one worker that every document of the same origin naming it shares. Off: the constructor is refused."},
	{name = "shared_workers.extended_lifetime_ms", kind = .Int, default = {i = 5_000}, bounded = true, min = 0, max = 600_000, unit = "ms",
		description = "How long a shared worker created with {extendedLifetime: true} keeps running after the last document using it closed (a navigation to a page that connects again finds it). Without the option it stops at once."},
	{name = "caches.max_bytes_per_origin", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most bytes the Cache API (caches.open, cache.put) keeps for one origin. A put that would go past it is refused with a QuotaExceededError."},
	{name = "opfs.max_bytes_per_origin", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most bytes the origin private file system (navigator.storage.getDirectory) keeps for one origin. A write past it is refused with a QuotaExceededError."},
}

sw_settings_from_prefs :: proc(p: ^config.Prefs) -> Sw_Settings {
	return Sw_Settings{
		enabled = config.bool_of(p, "service_workers.enabled"),
		fetch_timeout_ms = int(config.int_of(p, "service_workers.fetch_timeout_ms")),
		idle_ms = int(config.int_of(p, "service_workers.idle_ms")),
		update_hours = int(config.int_of(p, "service_workers.update_check_hours")),
		shared_enabled = config.bool_of(p, "shared_workers.enabled"),
		shared_linger_ms = int(config.int_of(p, "shared_workers.extended_lifetime_ms")),
		cache_max_bytes = config.int_of(p, "caches.max_bytes_per_origin"),
		opfs_max_bytes = config.int_of(p, "opfs.max_bytes_per_origin"),
	}
}

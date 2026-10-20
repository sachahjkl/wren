// Package js: the browser side of JavaScript that does not depend on a document: the engine's preferences, the
// bytecode cache, the local time zone. The realm itself (an instance of the engine module per page or worker, its
// imports, script loading) is in package page (js_*.odin); the engine is native/js, a WebAssembly module.
package js

import "core:strings"
import "wb:config"

Settings :: struct {
	enabled:              bool,
	sites_disabled:       []string,   // hosts (or *.domain) where scripts never run (owned)
	sites_enabled:        []string,   // hosts where they run even when javascript.enabled is off (owned)
	slow_script_ms:       i64,        // a task past this is interrupted cleanly ("slow script"); -1 = never
	max_heap_bytes:       i64,
	gc_threshold_bytes:   i64,
	expose_unimplemented: bool,
	unimplemented_throw:  bool,       // javascript.bindings.unimplemented = throw
	console_eval:         bool,
	workers:              bool,
	offthread_min_bytes:  int,        // scripts at least this large are compiled on a background thread
	cache:                Cache_Settings,
}

PREFS := [?]config.Def{
	{name = "javascript.enabled", kind = .Bool, default = {b = true},
		description = "Run the JavaScript of pages (scripts, event handler attributes, javascript: URLs). Off, pages run only their WebAssembly modules and <noscript> content is shown, as in Wren without JavaScript."},
	{name = "javascript.sites.disabled", kind = .String, default = {s = ""},
		description = "Sites where JavaScript never runs, whatever javascript.enabled says: host names separated by commas or spaces; *.example.com covers every subdomain."},
	{name = "javascript.sites.enabled", kind = .String, default = {s = ""},
		description = "Sites where JavaScript runs even when javascript.enabled is off (same syntax as javascript.sites.disabled, which wins when a host is in both)."},
	{name = "javascript.slow_script_ms", kind = .Int, default = {i = 10_000}, bounded = true, min = -1, max = 3_600_000, unit = "ms",
		description = "Wall-clock time one task of a page's JavaScript (a script, an event handler, a timer) may take. Past it the script is stopped cleanly with an uncatchable error, the console says which, and the page stays usable. -1 = never (wasm.max_call_ms still applies)."},
	{name = "javascript.max_heap_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 16 << 20, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Largest JavaScript heap of one page or worker. An allocation past it throws an out-of-memory error in the script (the Wasm memory limit, wasm.max_memory_pages, also bounds it)."},
	{name = "javascript.gc_threshold_bytes", kind = .Int, default = {i = 8 << 20}, bounded = true, min = 256 << 10, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Allocation between two cycle collections of a realm: at least this much, or half the live heap when that is more. Larger: fewer pauses, more memory."},
	{name = "javascript.bindings.expose_unimplemented", kind = .Bool, default = {b = false},
		description = "Also expose the interfaces of the web platform this browser does not implement at all (their members throw NotSupportedError). Off, they are absent, so feature detection (\"IntersectionObserver\" in window) sees the truth."},
	{name = "javascript.bindings.unimplemented", kind = .String, default = {s = "absent"}, choices = {"absent", "throw"},
		description = "Members of the web platform this browser does not implement on interfaces it does: absent (scripts that test for them, if (\"x\" in el), take their fallback) or present and throwing NotSupportedError when used (what the bindings' coverage says, visible to scripts)."},
	{name = "javascript.console_eval", kind = .Bool, default = {b = true},
		description = "Let the tab's console run JavaScript typed by the user in the page's realm."},
	{name = "javascript.workers.enabled", kind = .Bool, default = {b = true},
		description = "Let pages start workers whose script is JavaScript (new Worker(url)), each with its own realm on its own thread."},
	{name = "javascript.compile.offthread_min_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 0, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Scripts at least this large are compiled to bytecode on a background thread while the page does other work (0 = all of them, the maximum = none)."},
	{name = "javascript.bytecode_cache.memory_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 0, max = 1 << 34, bytes = true, unit = "bytes",
		description = "Compiled scripts (bytecode) kept in memory, shared by every page and tab: a script loaded again is not parsed again. 0 = no memory cache."},
	{name = "javascript.bytecode_cache.disk", kind = .Bool, default = {b = true}, restart = true,
		description = "Keep compiled scripts in the profile (folder js-cache), authenticated with a key of this profile, so the next start does not parse them again."},
	{name = "javascript.bytecode_cache.disk_max_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 20, max = 1 << 40, bytes = true, unit = "bytes", restart = true,
		description = "Largest size of the bytecode cache of the profile. The least recently used entries are deleted past it."},
	{name = "javascript.bytecode_cache.min_source_bytes", kind = .Int, default = {i = 1024}, bounded = true, min = 0, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Scripts smaller than this are not cached (parsing them costs less than a lookup)."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs, profile_dir := "") -> Settings {
	s := Settings{
		enabled = config.bool_of(p, "javascript.enabled"),
		sites_disabled = split_sites(config.string_of(p, "javascript.sites.disabled")),
		sites_enabled = split_sites(config.string_of(p, "javascript.sites.enabled")),
		slow_script_ms = config.int_of(p, "javascript.slow_script_ms"),
		max_heap_bytes = config.int_of(p, "javascript.max_heap_bytes"),
		gc_threshold_bytes = config.int_of(p, "javascript.gc_threshold_bytes"),
		expose_unimplemented = config.bool_of(p, "javascript.bindings.expose_unimplemented"),
		unimplemented_throw = config.string_of(p, "javascript.bindings.unimplemented") == "throw",
		console_eval = config.bool_of(p, "javascript.console_eval"),
		workers = config.bool_of(p, "javascript.workers.enabled"),
		offthread_min_bytes = int(config.int_of(p, "javascript.compile.offthread_min_bytes")),
	}
	s.cache = Cache_Settings{
		memory_bytes = config.int_of(p, "javascript.bytecode_cache.memory_bytes"),
		disk = config.bool_of(p, "javascript.bytecode_cache.disk") && profile_dir != "",
		disk_max_bytes = config.int_of(p, "javascript.bytecode_cache.disk_max_bytes"),
		min_source_bytes = int(config.int_of(p, "javascript.bytecode_cache.min_source_bytes")),
		profile_dir = strings.clone(profile_dir),
	}
	return s
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) {
	for h in s.sites_disabled { delete(h) }
	for h in s.sites_enabled { delete(h) }
	delete(s.sites_disabled)
	delete(s.sites_enabled)
	delete(s.cache.profile_dir)
	s^ = {}
}

settings_clone :: proc(s: Settings) -> Settings {
	c := s
	c.sites_disabled = clone_list(s.sites_disabled)
	c.sites_enabled = clone_list(s.sites_enabled)
	c.cache.profile_dir = strings.clone(s.cache.profile_dir)
	return c
}

@(private)
clone_list :: proc(l: []string) -> []string {
	out := make([]string, len(l))
	for h, i in l { out[i] = strings.clone(h) }
	return out
}

@(private)
split_sites :: proc(v: string) -> []string {
	out := make([dynamic]string)
	rest := v
	for len(rest) > 0 {
		i := strings.index_any(rest, ", \t;")
		item := i < 0 ? rest : rest[:i]
		rest = i < 0 ? "" : rest[i + 1:]
		item = strings.trim_space(item)
		if item != "" { append(&out, strings.to_lower(item)) }
	}
	return out[:]
}

@(private)
host_matches :: proc(host, pattern: string) -> bool {
	if strings.has_prefix(pattern, "*.") {
		base := pattern[2:]
		return host == base || strings.has_suffix(host, strings.concatenate({".", base}, context.temp_allocator))
	}
	return host == pattern
}

// Whether scripts run on a document of `host` (lower case; "" for documents without one: file:, about:, data:).
enabled_for :: proc(s: ^Settings, host: string) -> bool {
	h := strings.to_lower(host, context.temp_allocator)
	for p in s.sites_disabled { if host_matches(h, p) { return false } }
	if s.enabled { return true }
	for p in s.sites_enabled { if host_matches(h, p) { return true } }
	return false
}

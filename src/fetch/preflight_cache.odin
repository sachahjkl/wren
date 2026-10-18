package fetch

import "core:strings"
import "wb:http"

// CORS-preflight cache (Fetch Standard §4.9): remembers what a server allowed, so a repeated cross-origin request does
// not pay an OPTIONS round trip each time.

Preflight_Entry :: struct {
	origin:      string,   // serialized request origin
	url:         string,   // request URL without fragment
	credentials: bool,
	methods:     [dynamic]string,   // allowed methods (case-sensitive); "*" allowed only without credentials
	headers:     [dynamic]string,   // allowed header names, lower case; "*" only without credentials
	expires_ms:  i64,
	used_ms:     i64,
}

Preflight_Cache :: struct {
	entries: [dynamic]Preflight_Entry,
}

preflight_cache_make :: proc() -> Preflight_Cache { return {entries = make([dynamic]Preflight_Entry)} }

@(private)
free_entry :: proc(e: ^Preflight_Entry) {
	delete(e.origin); delete(e.url)
	for m in e.methods { delete(m) }
	for h in e.headers { delete(h) }
	delete(e.methods); delete(e.headers)
	e^ = {}
}

preflight_cache_destroy :: proc(c: ^Preflight_Cache) {
	for &e in c.entries { free_entry(&e) }
	delete(c.entries)
	c^ = {}
}

// Is this method + set of unsafe header names already authorised?
preflight_cache_allows :: proc(c: ^Preflight_Cache, origin, request_url: string, credentials: bool, method: string, unsafe_headers: []string, now: i64) -> bool {
	for i := len(c.entries) - 1; i >= 0; i -= 1 {
		e := &c.entries[i]
		if e.expires_ms <= now { free_entry(e); ordered_remove(&c.entries, i); continue }
		if e.origin != origin || e.url != request_url || e.credentials != credentials { continue }
		method_ok := http.is_safelisted_method(method)
		for m in e.methods { if m == method || (m == "*" && !credentials) { method_ok = true } }
		if !method_ok { continue }
		all_headers := true
		for h in unsafe_headers {
			found := false
			for a in e.headers { if a == h || (a == "*" && !credentials && h != "authorization") { found = true; break } }
			if !found { all_headers = false; break }
		}
		if !all_headers { continue }
		e.used_ms = now
		return true
	}
	return false
}

// `age_cap_s` and `max_entries` come from the settings (network.preflight.*).
preflight_cache_store :: proc(c: ^Preflight_Cache, origin, request_url: string, credentials: bool, methods, headers: []string, max_age_s: int, now: i64, age_cap_s, max_entries: int) {
	if max_age_s <= 0 || max_entries <= 0 { return }
	// replace an entry for the same key
	for i := len(c.entries) - 1; i >= 0; i -= 1 {
		e := &c.entries[i]
		if e.origin == origin && e.url == request_url && e.credentials == credentials { free_entry(e); ordered_remove(&c.entries, i) }
	}
	for len(c.entries) >= max_entries {
		oldest := 0
		for e, i in c.entries { if e.used_ms < c.entries[oldest].used_ms { oldest = i } }
		free_entry(&c.entries[oldest])
		ordered_remove(&c.entries, oldest)
	}
	e := Preflight_Entry{
		origin = strings.clone(origin), url = strings.clone(request_url), credentials = credentials,
		expires_ms = now + i64(min(max_age_s, age_cap_s)) * 1000, used_ms = now,
	}
	for m in methods { append(&e.methods, strings.clone(m)) }
	for h in headers { append(&e.headers, strings.clone(strings.to_lower(h, context.temp_allocator))) }
	append(&c.entries, e)
}


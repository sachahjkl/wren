package page

// Module "caches" (api/caches.widl): the Cache API's browser functions over cache_store.odin, for the engine's
// CacheStorage / Cache (native/js/runtime/web_cache.c). Any realm: documents, workers, service workers (the store is
// thread-safe; the profile directory comes from the realm's embedder).

import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:url"

@(private)
cache_realm :: proc(c: ^Call) -> (dir, origin: string, err: Api_Error) {
	p := c.page
	if !p.env.secure_context { return "", "", fail(c, .Security, "SecurityError: the Cache API needs a secure context") }
	origin = url.origin_serialize(p.env.origin, context.temp_allocator)
	if origin == "null" || origin == "" { return "", "", fail(c, .Security, "SecurityError: an opaque origin has no caches") }
	if sm := p.web.embedder.storage; sm != nil && sm.ready { dir = sm.dir }
	return dir, origin, .None
}

CacheStorage_check :: proc(c: ^Call) -> Api_Error {
	_, _, err := cache_realm(c)
	return err
}

CacheStorage_openName :: proc(c: ^Call, name: string) -> Api_Error {
	dir, origin := cache_realm(c) or_return
	cache_open(dir, origin, name)
	return .None
}

CacheStorage_hasName :: proc(c: ^Call, name: string) -> (bool, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return false, err }
	return cache_has(dir, origin, name), .None
}

CacheStorage_deleteName :: proc(c: ^Call, name: string) -> (bool, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return false, err }
	return cache_delete_named(dir, origin, name), .None
}

CacheStorage_names :: proc(c: ^Call) -> (string, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return "", err }
	return cache_names(dir, origin), .None
}

Cache_matchIds :: proc(c: ^Call, cache, u, method: string, ignore_search, ignore_method: bool) -> (string, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return "", err }
	ids := cache_match_ids(dir, origin, cache, u, method, {ignore_search = ignore_search, ignore_method = ignore_method})
	b := strings.builder_make(context.temp_allocator)
	for id, i in ids {
		if i > 0 { strings.write_byte(&b, '\n') }
		buf: [24]byte
		strings.write_string(&b, strconv.write_uint(buf[:], id, 10))
	}
	return strings.to_string(b), .None
}

Cache_entryHead :: proc(c: ^Call, cache: string, id: u64) -> (string, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return "", err }
	e, ok := cache_entry_head(dir, origin, cache, id)
	if !ok { return "", fail(c, .Not_Found, "the entry is gone") }
	return fmt.tprintf("%d\n%s\n%s\n%s\n%s\n%s", e.status, e.status_text, e.response_url, e.method, e.url, e.headers), .None
}

Cache_entryBody :: proc(c: ^Call, cache: string, id: u64) -> ([]byte, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return nil, err }
	body, ok := cache_entry_body(dir, origin, cache, id, context.temp_allocator)
	if !ok { return nil, fail(c, .Not_Found, "the entry is gone") }
	return body, .None
}

Cache_putEntry :: proc(c: ^Call, cache, u: string, status: i32, status_text, response_url, headers: string, body: []byte) -> Api_Error {
	dir, origin := cache_realm(c) or_return
	switch cache_put(dir, origin, cache, Cached_Response{url = u, status = int(status), status_text = status_text, response_url = response_url, headers = headers}, body, c.page.settings.sw.cache_max_bytes) {
	case .None:
	case .No_Cache: return fail(c, .Invalid_State, "InvalidStateError: the cache is gone")
	case .Quota: return fail(c, .Quota, "QuotaExceededError: caches.max_bytes_per_origin")
	}
	return .None
}

Cache_deleteEntries :: proc(c: ^Call, cache, u, method: string, ignore_search, ignore_method: bool) -> (bool, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return false, err }
	return cache_delete_entries(dir, origin, cache, u, method, {ignore_search = ignore_search, ignore_method = ignore_method}), .None
}

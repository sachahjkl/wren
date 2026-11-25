package page

// Module "caches" (api/caches.widl): the Cache API's browser functions over cache_store.odin, for the engine's
// CacheStorage / Cache (native/js/odin/web_cache.odin). Any realm: documents, workers, service workers (the store is
// thread-safe; the profile directory comes from the realm's embedder).
//
// Concurrency and I/O design:
//   * Warm in-memory operations (origin already loaded in RAM, and for `match`, matched bodies resident in RAM or
//     memory-only profile) complete immediately with zero disk I/O (mutations still write asynchronously on Cache_Writer).
//   * Cold `index.wcs` loads and cold `<id>.body` reads on UI-thread pages (`p.worker == nil`) run on the blocking
//     pool and resolve their host Promises via `p.loop`, with `base.on_close(p.scope, ...)` cancellation on page close.
//   * Worker realms (`p.worker != nil`) already run off the UI thread and execute directly on the worker thread.

import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:host"
import "wb:url"

@(private)
cache_realm :: proc(c: ^Call) -> (dir, origin: string, err: Api_Error) {
	p := c.page
	if !p.env.secure_context { return "", "", fail(c, .Security, "SecurityError: the Cache API needs a secure context") }
	if p.env.origin.opaque { return "", "", fail(c, .Security, "SecurityError: an opaque origin has no caches") }
	// (the storage key: the origin, partitioned by the top-level site in a third-party frame and its workers)
	origin = realm_storage_key(p)
	if origin == "" { origin = url.origin_serialize(p.env.origin, context.temp_allocator) }
	if sm := p.web.embedder.storage; sm != nil && sm.ready { dir = sm.dir }
	return dir, origin, .None
}

////////////////////////////////
// Async cold-read job engine (off UI thread with scope cancellation)

@(private = "file")
Cache_Api_Job_Kind :: enum u8 {
	Open_Name,
	Has_Name,
	Delete_Name,
	Names,
	Match,
	Keys,
	Put_Entry,
	Delete_Entries,
}

@(private = "file")
Cache_Api_Job :: struct {
	pages:       ^Pages,
	page:        u64,
	promise:     u64,
	owner:       u32,
	kind:        Cache_Api_Job_Kind,
	cleanup:     base.Cleanup_Id,
	has_cleanup: bool,
	cancelled:   b32,             // atomic: set by base.on_close(p.scope) on UI thread

	// Inputs (owned with base.process_allocator())
	dir:          string,
	origin:       string,
	cache:        string,
	url:          string,
	method:       string,
	req_headers:  string,
	query:        Cache_Query,
	all_caches:   bool,
	multiple:     bool,
	status:       int,
	status_text:  string,
	response_url: string,
	headers:      string,
	body:         []byte,
	max_bytes:    i64,

	// Outputs (owned with base.process_allocator())
	result_bool:  bool,
	result_str:   string,
	put_err:      Cache_Put_Error,
	found:        bool,
	packed:       [dynamic]byte,
}

@(private = "file")
cache_api_job_free :: proc(j: ^Cache_Api_Job) {
	pa := base.process_allocator()
	delete(j.dir, pa)
	delete(j.origin, pa)
	delete(j.cache, pa)
	delete(j.url, pa)
	delete(j.method, pa)
	delete(j.req_headers, pa)
	delete(j.status_text, pa)
	delete(j.response_url, pa)
	delete(j.headers, pa)
	delete(j.body, pa)
	delete(j.result_str, pa)
	delete(j.packed)
	free(j, pa)
}

@(private = "file")
cache_api_job_cancel :: proc(data: rawptr) {
	j := (^Cache_Api_Job)(data)
	sync.atomic_store(&j.cancelled, true)
}

@(private = "file")
cache_api_job_work :: proc(data: rawptr) {
	j := (^Cache_Api_Job)(data)
	if sync.atomic_load(&j.cancelled) { return }
	pa := base.process_allocator()
	prev_pages := the_pages
	the_pages = j.pages
	prev_alloc := context.allocator
	context.allocator = pa
	defer {
		context.allocator = prev_alloc
		the_pages = prev_pages
	}

	switch j.kind {
	case .Open_Name:
		cache_open(j.dir, j.origin, j.cache)
	case .Has_Name:
		j.result_bool = cache_has(j.dir, j.origin, j.cache)
	case .Delete_Name:
		j.result_bool = cache_delete_named(j.dir, j.origin, j.cache)
	case .Names:
		j.result_str = strings.clone(cache_names(j.dir, j.origin), pa)
	case .Match:
		j.packed, j.found, _ = cache_match_pack(j.dir, j.origin, j.cache, j.all_caches, j.url, j.method, j.query, j.req_headers, j.multiple, allow_disk = true, allocator = pa)
	case .Keys:
		j.packed, j.found, _ = cache_keys_pack(j.dir, j.origin, j.cache, j.url, j.method, j.query, j.req_headers, allow_disk = true, allocator = pa)
	case .Put_Entry:
		e := Cached_Response{
			url = j.url, req_headers = j.req_headers, status = j.status,
			status_text = j.status_text, response_url = j.response_url, headers = j.headers,
		}
		j.put_err = cache_put(j.dir, j.origin, j.cache, e, j.body, j.max_bytes)
	case .Delete_Entries:
		j.result_bool = cache_delete_entries(j.dir, j.origin, j.cache, j.url, j.method, j.query, j.req_headers)
	}
}

@(private = "file")
cache_api_job_settle :: proc(pg: ^Page, j: ^Cache_Api_Job) {
	defer cache_api_job_free(j)
	cancelled := sync.atomic_load(&j.cancelled)
	if pg != nil && !pg.closed && !cancelled && j.has_cleanup {
		base.forget_cleanup(pg.scope, j.cleanup)
		j.has_cleanup = false
	}
	if pg == nil || pg.closed || cancelled { return }

	switch j.kind {
	case .Open_Name:
		promise_resolve(pg, j.promise, 0)
	case .Has_Name, .Delete_Name, .Delete_Entries:
		promise_resolve(pg, j.promise, j.result_bool ? 1 : 0)
	case .Names:
		promise_resolve(pg, j.promise, 0, j.result_str)
	case .Match, .Keys:
		if !j.found {
			promise_resolve(pg, j.promise, 0)
			return
		}
		buf := buffer_adopt(pg, j.packed, j.owner)
		j.packed = nil   // ownership transferred to buffer_adopt (or freed by it on quota failure)
		if buf == 0 {
			promise_reject(pg, j.promise, i64(Api_Error.Quota), "QuotaExceededError: page memory limit")
			return
		}
		promise_resolve_object(pg, j.promise, buf)
	case .Put_Entry:
		switch j.put_err {
		case .None:
			promise_resolve(pg, j.promise, 0)
		case .No_Cache:
			promise_reject(pg, j.promise, i64(Api_Error.Invalid_State), "InvalidStateError: the cache is gone")
		case .Quota:
			promise_reject(pg, j.promise, i64(Api_Error.Quota), "QuotaExceededError: caches.max_bytes_per_origin")
		}
	}
}

@(private = "file")
cache_api_job_done :: proc(data: rawptr) {
	j := (^Cache_Api_Job)(data)
	pg := sync.atomic_load(&j.cancelled) ? nil : page_by_id(j.page)
	cache_api_job_settle(pg, j)
}

@(private = "file")
cache_api_job_discard :: proc(data: rawptr) {
	j := (^Cache_Api_Job)(data)
	if !sync.atomic_load(&j.cancelled) && j.has_cleanup {
		if pg := page_by_id(j.page); pg != nil && !pg.closed {
			base.forget_cleanup(pg.scope, j.cleanup)
		}
	}
	cache_api_job_free(j)
}

@(private = "file")
cache_api_job_submit :: proc(c: ^Call, pool: ^host.Blocking_Pool, j: ^Cache_Api_Job) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	j.pages = the_pages
	j.page = page_id(p)
	j.promise = pr
	j.owner = c.owner
	j.cleanup = base.on_close(p.scope, cache_api_job_cancel, j)
	j.has_cleanup = true
	host.run_blocking(pool, cache_api_job_work, cache_api_job_done, j, cache_api_job_discard)
	return pr
}

@(private = "file")
cache_need_offload :: proc(p: ^Page, dir, origin: string) -> ^host.Blocking_Pool {
	pool := page_blocking_pool(p)
	if pool == nil || p.web == nil || p.web.id == 0 { return nil }
	if cache_origin_loaded(dir, origin) { return nil }
	return pool
}

////////////////////////////////
// Module "caches" host imports

CacheStorage_check :: proc(c: ^Call) -> Api_Error {
	_, _, err := cache_realm(c)
	return err
}

CacheStorage_openName :: proc(c: ^Call, name: string) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	if pool := cache_need_offload(c.page, dir, origin); pool != nil {
		pa := base.process_allocator()
		j := new(Cache_Api_Job, pa)
		j.kind = .Open_Name
		j.dir, j.origin, j.cache = strings.clone(dir, pa), strings.clone(origin, pa), strings.clone(name, pa)
		return cache_api_job_submit(c, pool, j), .None
	}
	cache_open(dir, origin, name)
	pr := promise_create(c.page, c.owner)
	promise_resolve(c.page, pr, 0)
	return pr, .None
}

CacheStorage_hasName :: proc(c: ^Call, name: string) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	if pool := cache_need_offload(c.page, dir, origin); pool != nil {
		pa := base.process_allocator()
		j := new(Cache_Api_Job, pa)
		j.kind = .Has_Name
		j.dir, j.origin, j.cache = strings.clone(dir, pa), strings.clone(origin, pa), strings.clone(name, pa)
		return cache_api_job_submit(c, pool, j), .None
	}
	has := cache_has(dir, origin, name)
	pr := promise_create(c.page, c.owner)
	promise_resolve(c.page, pr, has ? 1 : 0)
	return pr, .None
}

CacheStorage_deleteName :: proc(c: ^Call, name: string) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	if pool := cache_need_offload(c.page, dir, origin); pool != nil {
		pa := base.process_allocator()
		j := new(Cache_Api_Job, pa)
		j.kind = .Delete_Name
		j.dir, j.origin, j.cache = strings.clone(dir, pa), strings.clone(origin, pa), strings.clone(name, pa)
		return cache_api_job_submit(c, pool, j), .None
	}
	deleted := cache_delete_named(dir, origin, name)
	pr := promise_create(c.page, c.owner)
	promise_resolve(c.page, pr, deleted ? 1 : 0)
	return pr, .None
}

CacheStorage_names :: proc(c: ^Call) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	if pool := cache_need_offload(c.page, dir, origin); pool != nil {
		pa := base.process_allocator()
		j := new(Cache_Api_Job, pa)
		j.kind = .Names
		j.dir, j.origin = strings.clone(dir, pa), strings.clone(origin, pa)
		return cache_api_job_submit(c, pool, j), .None
	}
	names := cache_names(dir, origin)
	pr := promise_create(c.page, c.owner)
	promise_resolve(c.page, pr, 0, names)
	return pr, .None
}

Cache_match :: proc(c: ^Call, cache: string, all_caches: bool, u, method, request_headers: string, ignore_search, ignore_method, ignore_vary, multiple: bool) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	q := Cache_Query{ignore_search = ignore_search, ignore_method = ignore_method, ignore_vary = ignore_vary}
	pa := base.process_allocator()
	pool := page_blocking_pool(c.page)
	can_offload := pool != nil && c.page.web != nil && c.page.web.id != 0

	packed, found, need_disk := cache_match_pack(dir, origin, cache, all_caches, u, method, q, request_headers, multiple, allow_disk = !can_offload, allocator = pa)
	if need_disk && can_offload {
		j := new(Cache_Api_Job, pa)
		j.kind = .Match
		j.dir, j.origin = strings.clone(dir, pa), strings.clone(origin, pa)
		j.cache = strings.clone(cache, pa)
		j.all_caches, j.multiple = all_caches, multiple
		j.url, j.method, j.req_headers = strings.clone(u, pa), strings.clone(method, pa), strings.clone(request_headers, pa)
		j.query = q
		return cache_api_job_submit(c, pool, j), .None
	}

	pr := promise_create(c.page, c.owner)
	if !found {
		promise_resolve(c.page, pr, 0)
		return pr, .None
	}
	buf := buffer_adopt(c.page, packed, c.owner)
	if buf == 0 {
		promise_reject(c.page, pr, i64(Api_Error.Quota), "QuotaExceededError: page memory limit")
		return pr, .None
	}
	promise_resolve_object(c.page, pr, buf)
	return pr, .None
}

Cache_keys :: proc(c: ^Call, cache, u, method, request_headers: string, ignore_search, ignore_method, ignore_vary: bool) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	q := Cache_Query{ignore_search = ignore_search, ignore_method = ignore_method, ignore_vary = ignore_vary}
	pa := base.process_allocator()
	pool := page_blocking_pool(c.page)
	can_offload := pool != nil && c.page.web != nil && c.page.web.id != 0

	packed, found, need_disk := cache_keys_pack(dir, origin, cache, u, method, q, request_headers, allow_disk = !can_offload, allocator = pa)
	if need_disk && can_offload {
		j := new(Cache_Api_Job, pa)
		j.kind = .Keys
		j.dir, j.origin = strings.clone(dir, pa), strings.clone(origin, pa)
		j.cache = strings.clone(cache, pa)
		j.url, j.method, j.req_headers = strings.clone(u, pa), strings.clone(method, pa), strings.clone(request_headers, pa)
		j.query = q
		return cache_api_job_submit(c, pool, j), .None
	}

	pr := promise_create(c.page, c.owner)
	if !found {
		promise_resolve(c.page, pr, 0)
		return pr, .None
	}
	buf := buffer_adopt(c.page, packed, c.owner)
	if buf == 0 {
		promise_reject(c.page, pr, i64(Api_Error.Quota), "QuotaExceededError: page memory limit")
		return pr, .None
	}
	promise_resolve_object(c.page, pr, buf)
	return pr, .None
}

Cache_putEntry :: proc(c: ^Call, cache, u, request_headers: string, status: i32, status_text, response_url, headers: string, body: []byte) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	if pool := cache_need_offload(c.page, dir, origin); pool != nil {
		pa := base.process_allocator()
		j := new(Cache_Api_Job, pa)
		j.kind = .Put_Entry
		j.dir, j.origin = strings.clone(dir, pa), strings.clone(origin, pa)
		j.cache = strings.clone(cache, pa)
		j.url, j.req_headers = strings.clone(u, pa), strings.clone(request_headers, pa)
		j.status = int(status)
		j.status_text, j.response_url, j.headers = strings.clone(status_text, pa), strings.clone(response_url, pa), strings.clone(headers, pa)
		if len(body) > 0 { j.body = slice.clone(body, pa) }
		j.max_bytes = c.page.settings.sw.cache_max_bytes
		return cache_api_job_submit(c, pool, j), .None
	}
	e := Cached_Response{url = u, req_headers = request_headers, status = int(status), status_text = status_text, response_url = response_url, headers = headers}
	pr := promise_create(c.page, c.owner)
	switch cache_put(dir, origin, cache, e, body, c.page.settings.sw.cache_max_bytes) {
	case .None:
		promise_resolve(c.page, pr, 0)
	case .No_Cache:
		promise_reject(c.page, pr, i64(Api_Error.Invalid_State), "InvalidStateError: the cache is gone")
	case .Quota:
		promise_reject(c.page, pr, i64(Api_Error.Quota), "QuotaExceededError: caches.max_bytes_per_origin")
	}
	return pr, .None
}

Cache_deleteEntries :: proc(c: ^Call, cache, u, method, request_headers: string, ignore_search, ignore_method, ignore_vary: bool) -> (u64, Api_Error) {
	dir, origin, err := cache_realm(c)
	if err != .None { return 0, err }
	q := Cache_Query{ignore_search = ignore_search, ignore_method = ignore_method, ignore_vary = ignore_vary}
	if pool := cache_need_offload(c.page, dir, origin); pool != nil {
		pa := base.process_allocator()
		j := new(Cache_Api_Job, pa)
		j.kind = .Delete_Entries
		j.dir, j.origin = strings.clone(dir, pa), strings.clone(origin, pa)
		j.cache = strings.clone(cache, pa)
		j.url, j.method, j.req_headers = strings.clone(u, pa), strings.clone(method, pa), strings.clone(request_headers, pa)
		j.query = q
		return cache_api_job_submit(c, pool, j), .None
	}
	deleted := cache_delete_entries(dir, origin, cache, u, method, q, request_headers)
	pr := promise_create(c.page, c.owner)
	promise_resolve(c.page, pr, deleted ? 1 : 0)
	return pr, .None
}

// The Cache API's storage (module caches, api/caches.odin; the engine side is native/js/odin/web_cache.odin): named
// caches of request -> response entries per origin, kept in the profile and shared by every realm of the origin. These
// functions are synchronous; the engine makes the promises, the Request and Response objects. Security for a realm
// that is not a secure context or has an opaque origin.
package api_decl

import "../abi"

// caches.open(name): the cache exists afterwards.
CacheStorage_openName   :: #type proc(name: string) -> abi.Api_Error
// caches.has(name) / caches.delete(name)
CacheStorage_hasName    :: #type proc(name: string) -> (bool, abi.Api_Error)
CacheStorage_deleteName :: #type proc(name: string) -> (bool, abi.Api_Error)
// caches.keys(): the names in creation order, "\n"-separated.
CacheStorage_names      :: #type proc() -> (string, abi.Api_Error)
// The ids of the entries of `cache` matching the request (url "" = every entry), decimal, "\n"-separated; Vary is
// matched against `request_headers` ("Name: value" lines) unless ignore_vary.
Cache_matchIds :: #type proc(cache: string, url: string, method: string, request_headers: string, ignore_search: bool,
	ignore_method: bool, ignore_vary: bool) -> (string, abi.Api_Error)
// The header lines of an entry's request.
Cache_entryRequestHeaders :: #type proc(cache: string, id: u64) -> (string, abi.Api_Error)
// An entry's head: status, statusText, the response's URL, the request's method, the request's URL, then the
// response's header lines, "\n"-separated.
Cache_entryHead :: #type proc(cache: string, id: u64) -> (string, abi.Api_Error)
// An entry's body.
Cache_entryBody :: #type proc(cache: string, id: u64) -> ([]u8, abi.Api_Error)
// cache.put(request, response) with the response's body read: replaces the entries the request matches.
Cache_putEntry :: #type proc(cache: string, url: string, request_headers: string, status: i32, status_text: string,
	response_url: string, headers: string, body: []u8) -> abi.Api_Error
// cache.delete(request, options): whether an entry went.
Cache_deleteEntries :: #type proc(cache: string, url: string, method: string, request_headers: string, ignore_search: bool,
	ignore_method: bool, ignore_vary: bool) -> (bool, abi.Api_Error)

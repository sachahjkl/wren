// The Cache API's storage (module caches, api/caches.widl; the engine side is native/js/odin/web_cache.odin): named
// caches of request -> response entries per origin, kept in the profile and shared by every realm of the origin. Cold
// index.wcs and body disk reads run off the UI thread; operations return host promises settled when ready. Security
// for a realm that is not a secure context or has an opaque origin.
package api_decl

import "../abi"

// caches.open(name): promise settling undefined once the cache exists.
CacheStorage_openName   :: #type proc(name: string) -> (abi.Handle, abi.Api_Error)
// caches.has(name) / caches.delete(name): promise of bool (value 0/1).
CacheStorage_hasName    :: #type proc(name: string) -> (abi.Handle, abi.Api_Error)
CacheStorage_deleteName :: #type proc(name: string) -> (abi.Handle, abi.Api_Error)
// caches.keys(): promise whose text is the names in creation order, "\n"-separated.
CacheStorage_names      :: #type proc() -> (abi.Handle, abi.Api_Error)
// cache.match / cache.matchAll / caches.match: promise of a packed Buffer handle (0 when none matched).
Cache_match :: #type proc(cache: string, all_caches: bool, url: string, method: string, request_headers: string,
	ignore_search: bool, ignore_method: bool, ignore_vary: bool, multiple: bool) -> (abi.Handle, abi.Api_Error)
// cache.keys(request, options): promise of a packed Buffer handle (0 when none matched).
Cache_keys :: #type proc(cache: string, url: string, method: string, request_headers: string,
	ignore_search: bool, ignore_method: bool, ignore_vary: bool) -> (abi.Handle, abi.Api_Error)
// cache.put(request, response) with the response's body read: promise settling undefined.
Cache_putEntry :: #type proc(cache: string, url: string, request_headers: string, status: i32, status_text: string,
	response_url: string, headers: string, body: []u8) -> (abi.Handle, abi.Api_Error)
// cache.delete(request, options): promise of bool (value 0/1).
Cache_deleteEntries :: #type proc(cache: string, url: string, method: string, request_headers: string, ignore_search: bool,
	ignore_method: bool, ignore_vary: bool) -> (abi.Handle, abi.Api_Error)

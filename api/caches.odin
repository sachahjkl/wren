// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=caches order=3 exposed=(Window,Worker)
/// The Cache API (Service Workers §5: CacheStorage, Cache) on the browser's storage (src/page/cache_store.odin): named
/// caches of request -> response entries per origin, kept in the profile and shared by every realm of the origin (pages,
/// workers, service workers). The engine (native/js/runtime/web_cache.c) makes the promises, the Request and Response
/// objects; these functions are synchronous. Security for a realm that is not a secure context or has an opaque origin.
package api_caches

/// Whether the calling realm may use caches.
//@wb fn raises
CacheStorage_check :: proc()

/// caches.open(name): the cache exists afterwards.
//@wb fn raises
CacheStorage_openName :: proc(name: string)

/// caches.has(name)
//@wb fn raises
CacheStorage_hasName :: proc(name: string) -> bool

/// caches.delete(name)
//@wb fn raises
CacheStorage_deleteName :: proc(name: string) -> bool

/// caches.keys(): the names in creation order, "\n"-separated.
//@wb fn raises
CacheStorage_names :: proc() -> string

/// The ids of the entries of `cache` matching the request (url "" = every entry), decimal, "\n"-separated. Unless
/// ignore_vary, an entry whose response has a Vary header matches only when the named request headers are the same
/// in `request_headers` ("Name: value" lines) as in its stored request (Vary: * never matches).
//@wb fn raises
Cache_matchIds :: proc(cache: string, url: string, method: string, request_headers: string, ignore_search: bool, ignore_method: bool, ignore_vary: bool) -> string

/// The header lines of an entry's request (Not_Found when it is gone).
//@wb fn raises
Cache_entryRequestHeaders :: proc(cache: string, id: u64) -> string

/// An entry's head: status, statusText, the response's URL, the request's method, the request's URL, then the
/// response's header lines, "\n"-separated (Not_Found when it is gone).
//@wb fn raises
Cache_entryHead :: proc(cache: string, id: u64) -> string

/// An entry's body (Not_Found when it is gone).
//@wb fn raises
Cache_entryBody :: proc(cache: string, id: u64) -> bytes

/// cache.put(request, response) with the response's body read: replaces the entries the request matches (Vary
/// considered). Quota past caches.max_bytes_per_origin.
//@wb fn raises
Cache_putEntry :: proc(cache: string, url: string, request_headers: string, status: i32, status_text: string, response_url: string, headers: string, body: bytes)

/// cache.delete(request, options)
//@wb fn raises
Cache_deleteEntries :: proc(cache: string, url: string, method: string, request_headers: string, ignore_search: bool, ignore_method: bool, ignore_vary: bool) -> bool


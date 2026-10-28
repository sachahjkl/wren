// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=url order=66 exposed=(Window,Worker)
/// URL and URLSearchParams (WHATWG URL Standard) as host objects. A URL's searchParams is linked to it both ways:
/// changing the URL's search re-parses the list, changing the list rewrites the URL's query. Either may be released
/// first.
package api_url

//@wb handle parent=Object host=Url_Object lookup=lookup_URL
URL :: distinct Handle

//@wb handle parent=Object host=Params_Object lookup=lookup_URLSearchParams
URLSearchParams :: distinct Handle

//@wb handle parent=Object host=Pattern_Object lookup=lookup_URLPattern
URLPattern :: distinct Handle

/// A component of a URL (also used by Location).
URLComponent :: enum i32 {
	Href,
	Protocol,
	Username,
	Password,
	Host,
	Hostname,
	Port,
	Pathname,
	Search,
	Hash,
	Origin,
}

/// A component of a URLPattern (the eight pattern components, in the spec's order).
URLPatternComponent :: enum i32 {
	Protocol,
	Username,
	Password,
	Hostname,
	Port,
	Pathname,
	Search,
	Hash,
}

/// new URL(input, base): Type when the input (or the base) is not a valid URL or too long (web.url_max_length).
//@wb fn raises optional=base
URL_parse :: proc(input: string, base: string) -> URL

/// URL.canParse(input, base)
//@wb fn optional=base
URL_canParse :: proc(input: string, base: string) -> bool

/// A getter: url.href, url.protocol...
//@wb fn
URL_get :: proc(url: URL, component: URLComponent) -> string

/// A setter. Only href can fail (Type); values the standard ignores leave the URL unchanged. Origin is read-only
/// (Invalid_Argument).
//@wb fn raises
URL_set :: proc(url: URL, component: URLComponent, value: string)

/// url.searchParams: the same object every time.
//@wb fn
URL_searchParams :: proc(url: URL) -> URLSearchParams

/// new URLSearchParams(init): a query string, with or without its "?". Type when too long.
//@wb fn raises
URLSearchParams_create :: proc(init: string = "") -> URLSearchParams

/// params.size
//@wb fn
URLSearchParams_size :: proc(params: URLSearchParams) -> i32

/// params.append(name, value)
//@wb fn
URLSearchParams_append :: proc(params: URLSearchParams, name: usvstring, value: usvstring)

/// params.delete(name, value)
//@wb fn optional=value
URLSearchParams_delete :: proc(params: URLSearchParams, name: string, value: string)

/// params.get(name): Not_Found when absent.
//@wb fn raises
URLSearchParams_get :: proc(params: URLSearchParams, name: string) -> string

/// params.getAll(name).length
//@wb fn
URLSearchParams_count :: proc(params: URLSearchParams, name: string) -> i32

/// params.getAll(name)[index]: Not_Found past the end.
//@wb fn raises
URLSearchParams_getNth :: proc(params: URLSearchParams, name: string, index: i32) -> string

/// params.has(name, value)
//@wb fn optional=value
URLSearchParams_has :: proc(params: URLSearchParams, name: string, value: string) -> bool

/// params.set(name, value)
//@wb fn
URLSearchParams_set :: proc(params: URLSearchParams, name: usvstring, value: usvstring)

/// params.sort()
//@wb fn
URLSearchParams_sort :: proc(params: URLSearchParams)

/// params.toString()
//@wb fn
URLSearchParams_toString :: proc(params: URLSearchParams) -> string

/// The name of the pair at `index` (iteration): Not_Found past the end.
//@wb fn raises
URLSearchParams_nameAt :: proc(params: URLSearchParams, index: i32) -> string

/// The value of the pair at `index`: Not_Found past the end.
//@wb fn raises
URLSearchParams_valueAt :: proc(params: URLSearchParams, index: i32) -> string

/// /////////////////////////////
/// new URLPattern(patternString, baseURL?, {ignoreCase}): Type on a malformed pattern or missing protocol with no
/// base. `has_base` and `has_options` distinguish an absent argument from an empty string / default.
//@wb fn raises
URLPattern_createString :: proc(input: string, base: string, has_base: bool, ignore_case: bool) -> URLPattern

/// new URLPattern(init, {ignoreCase}): the eight optional component strings plus an optional baseURL. A component's
/// `has_*` flag is false when the property was absent (defaults to the wildcard pattern).
//@wb fn raises
URLPattern_createInit :: proc(protocol: string, has_protocol: bool, username: string, has_username: bool, password: string, has_password: bool, hostname: string, has_hostname: bool, port: string, has_port: bool, pathname: string, has_pathname: bool, search: string, has_search: bool, hash: string, has_hash: bool, base: string, has_base: bool, ignore_case: bool) -> URLPattern

/// A component's normalized pattern string (the getters protocol, username, ...).
//@wb fn
URLPattern_component :: proc(pattern: URLPattern, component: URLPatternComponent) -> string

/// pattern.hasRegExpGroups
//@wb fn
URLPattern_hasRegExpGroups :: proc(pattern: URLPattern) -> bool

/// Run exec()/test() against a URL string (resolved against base when has_base). Stores the result in the object.
/// Returns 1 when it matched, 0 when it did not (exec returns null, test returns false).
//@wb fn
URLPattern_execString :: proc(pattern: URLPattern, input: string, base: string, has_base: bool) -> i32

/// Run exec()/test() against a per-component init. Returns 1/0 as execString.
//@wb fn
URLPattern_execInit :: proc(pattern: URLPattern, protocol: string, has_protocol: bool, username: string, has_username: bool, password: string, has_password: bool, hostname: string, has_hostname: bool, port: string, has_port: bool, pathname: string, has_pathname: bool, search: string, has_search: bool, hash: string, has_hash: bool) -> i32

/// After a successful exec: the number of `inputs` entries, and the i-th input string.
//@wb fn
URLPattern_resultInputCount :: proc(pattern: URLPattern) -> i32

//@wb fn raises
URLPattern_resultInput :: proc(pattern: URLPattern, index: i32) -> string

/// The matched input value of a component (URLPatternComponentResult.input).
//@wb fn
URLPattern_componentInput :: proc(pattern: URLPattern, component: URLPatternComponent) -> string

/// The number of named groups of a component, and the i-th group's name.
//@wb fn
URLPattern_groupCount :: proc(pattern: URLPattern, component: URLPatternComponent) -> i32

//@wb fn raises
URLPattern_groupName :: proc(pattern: URLPattern, component: URLPatternComponent, index: i32) -> string

/// The i-th group's captured value: Not_Found when the group did not participate (its value is undefined).
//@wb fn raises
URLPattern_groupValue :: proc(pattern: URLPattern, component: URLPatternComponent, index: i32) -> string


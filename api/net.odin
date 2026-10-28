// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=net order=58 exposed=(Window,Worker)
/// Fetch with a callback (Fetch Standard through the browser's loader: origin, CORS, cookies, referrer, CSP and mixed
/// content are the browser's business, never the module's). The callback learns each step; the response is read from
/// the request record until Fetch_release. A Response (module fetch) is the same record.
package api_net

//@wb handle host=Fetch lookup=lookup_Fetch
/// A request and, once it arrived, its response.
Fetch :: distinct Handle

//@wb handle parent=Fetch
/// The response of a fetch (what Fetch_promise settles with): the same record as its Fetch.
Response :: distinct Handle

/// Where a request is.
FetchState :: enum i32 {
	Pending,
	Response,
	Done,
	Failed,
}

/// Response.type
ResponseType :: enum i32 {
	Basic,
	Cors,
	Opaque,
	Opaque_Redirect,
}

/// RequestInit.mode
FetchMode :: enum u32 {
	Cors,
	Same_Origin,
	No_Cors,
}

/// RequestInit.credentials
Credentials :: enum u32 {
	Same_Origin,
	Omit,
	Include,
}

/// RequestInit.redirect
RedirectMode :: enum u32 {
	Follow,
	Error,
	Manual,
}

/// RequestInit.referrerPolicy (Default: the document's policy).
ReferrerPolicy :: enum u32 {
	Default,
	No_Referrer,
	No_Referrer_When_Downgrade,
	Same_Origin,
	Origin,
	Strict_Origin,
	Origin_When_Cross_Origin,
	Strict_Origin_When_Cross_Origin,
	Unsafe_Url,
}

/// RequestInit.cache: how the request uses the browser's HTTP cache (Fetch Standard cache modes).
RequestCache :: enum u32 {
	Default,
	No_Store,
	Reload,
	No_Cache,
	Force_Cache,
	Only_If_Cached,
}

/// RequestInit beyond method, headers and body. The zero value is the Fetch API default.
FetchOptions :: struct {
	mode: FetchMode,
	credentials: Credentials,
	redirect: RedirectMode,
	referrer_policy: ReferrerPolicy,
	/// referrer: "" (send none).
	no_referrer: bool,
	/// only-if-cached needs mode Same_Origin.
	cache: RequestCache,
}

/// Called when the response arrives (Response), when the body is complete (Done) or on failure (Failed).
//@wb callback
FetchCallback :: #type proc "contextless" (user: i32, request: Fetch, state: FetchState)

/// fetch(url, {method, headers, body, ...}) with a callback. `headers` are "Name: value" lines (CR LF or LF). A
/// relative URL resolves against the document (or the worker's script).
//@wb fn optional=body
Fetch_start :: proc(url: string, callback: FetchCallback, user: i32 = 0, method: string = "GET", headers: string = "", body: bytes, options: FetchOptions = none) -> Fetch

//@wb fn
Fetch_state :: proc(request: Fetch) -> FetchState

/// The HTTP status (0 for an opaque response).
//@wb fn
Fetch_status :: proc(request: Fetch) -> i32

//@wb fn
Fetch_type :: proc(request: Fetch) -> ResponseType

//@wb fn
Fetch_redirected :: proc(request: Fetch) -> bool

/// The response headers the module may see: "Name: value" lines, CR LF terminated.
//@wb fn
Fetch_headers :: proc(request: Fetch) -> string

/// The final URL (after redirects).
//@wb fn
Fetch_url :: proc(request: Fetch) -> string

/// Why it failed ("" before a failure).
//@wb fn
Fetch_error :: proc(request: Fetch) -> string

/// The fetch.Error_Kind of a failure (0 none, then Bad_URL, Bad_Scheme... in the browser's order).
//@wb fn
Fetch_errorKind :: proc(request: Fetch) -> i32

/// The bytes of the body received so far.
//@wb fn
Fetch_bodyLength :: proc(request: Fetch) -> u64

/// Copies the body from `offset` into `buffer`; returns how many bytes were copied.
//@wb fn out=buffer
Fetch_readBody :: proc(request: Fetch, offset: u64, buffer: bytes) -> i32

/// Cancels the request if needed and frees the record.
//@wb fn raises
Fetch_release :: proc(request: Fetch)


// Modules fetch and net (api/fetch.widl, api/net.widl): the browser's requests behind fetch() and XMLHttpRequest, and
// their response records. The request's options travel flattened, as the generated imports carry them.
package api_decl

import "../abi"

// A request and, once it arrived, its response (module net: Fetch; module fetch's Response is the same record).
Fetch :: distinct abi.Handle

// Where a request is (what a callback reports).
FetchState :: enum i32 { Pending, Response, Done, Failed }
// Response.type
ResponseType :: enum i32 { Basic, Cors, Opaque, Opaque_Redirect }
// RequestInit.mode
FetchMode :: enum i32 { Cors, Same_Origin, No_Cors }
// RequestInit.credentials
Credentials :: enum i32 { Same_Origin, Omit, Include }
// RequestInit.redirect
RedirectMode :: enum i32 { Follow, Error, Manual }
// RequestInit.referrerPolicy (Default: the document's policy).
ReferrerPolicy :: enum i32 {
	Default, No_Referrer, No_Referrer_When_Downgrade, Same_Origin, Origin, Strict_Origin, Origin_When_Cross_Origin,
	Strict_Origin_When_Cross_Origin, Unsafe_Url,
}
// RequestInit.cache
RequestCache :: enum i32 { Default, No_Store, Reload, No_Cache, Force_Cache, Only_If_Cached }

// fetch(url, init): `headers` are "Name: value" lines; the body is `body` (absent: none) or the bytes of
// `body_buffer` when given. A promise settled with the Fetch record when the headers arrive. Type when the signal is not
// an AbortSignal or the buffer not a buffer.
Fetch_promise :: #type proc(url: string, method: string, headers: string, body: Maybe(string), body_buffer: Buffer,
	signal: AbortSignal, mode: FetchMode, credentials: Credentials, redirect: RedirectMode, referrer_policy: ReferrerPolicy,
	no_referrer: bool, cache: RequestCache) -> (Promise, abi.Api_Error)
// The same with a callback (a function-table index and its `user` word) told of the headers, the end and failures.
Fetch_startWithSignal :: #type proc(url: string, callback: i32, user: i32, method: string, headers: string, body: Maybe(string),
	body_buffer: Buffer, signal: AbortSignal, mode: FetchMode, credentials: Credentials, redirect: RedirectMode,
	referrer_policy: ReferrerPolicy, no_referrer: bool, cache: RequestCache) -> (Fetch, abi.Api_Error)
// A worker's synchronous request, waited for: the finished record. Not_Supported in a document, Timeout past
// `timeout_ms` (0: none), Network on a failure.
Fetch_sync :: #type proc(url: string, method: string, headers: string, body: Maybe(string), mode: FetchMode,
	credentials: Credentials, redirect: RedirectMode, referrer_policy: ReferrerPolicy, no_referrer: bool, cache: RequestCache,
	timeout_ms: u32) -> (Fetch, abi.Api_Error)

// The record once the headers arrived.
Fetch_type :: #type proc(request: Fetch) -> ResponseType
// The HTTP status (0 for an opaque response).
Fetch_status :: #type proc(request: Fetch) -> i32
Fetch_redirected :: #type proc(request: Fetch) -> bool
// The response headers the page may see: "Name: value" lines, CR LF terminated.
Fetch_headers :: #type proc(request: Fetch) -> string
// The final URL (after redirects).
Fetch_url :: #type proc(request: Fetch) -> string
// The bytes of the body received so far; a copy of them from `offset` (the count copied).
Fetch_bodyLength :: #type proc(request: Fetch) -> u64
Fetch_readBody :: #type proc(request: Fetch, offset: u64, into: []u8) -> i32
// Cancels the request if needed and frees the record.
Fetch_release :: #type proc(request: Fetch) -> abi.Api_Error

// response.arrayBuffer(): a promise settled with a buffer.
Response_arrayBuffer :: #type proc(response: Fetch) -> Promise
// response.body: the body as a stream of the browser. Type when the body was used already.
Response_body :: #type proc(response: Fetch) -> (Stream, abi.Api_Error)

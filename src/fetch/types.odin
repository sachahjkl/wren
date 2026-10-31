// Package fetch: the browser's network policy layer, an implementation of the Fetch Standard on top of the raw
// transport in package net. Everything that decides whether a request may happen, what it carries and what the caller
// is allowed to see of the answer lives here, once:
//
//   * request modes and the CORS protocol (including preflights and the preflight cache),
//   * cookies (the jar, SameSite contexts, third-party policy), HSTS, referrer policy,
//   * redirects (followed one hop at a time, each hop re-checked),
//   * mixed content, bad ports, scheme handling (http/https, file, data), MIME / nosniff checks per destination,
//   * response tainting and filtering (basic / cors / opaque).
//
// The transport (net) never follows redirects, never touches cookies and never adds credentials: every decision is made
// here, on the UI thread, with the document's Environment in hand.
package fetch

import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:csp"
import "wb:http"
import "wb:httpcache"
import "wb:url"

Mode :: enum u8 {
	Navigate,      // top-level document loads
	Same_Origin,   // fetch() that must stay on the origin
	No_Cors,       // cross-origin allowed, response is opaque
	Cors,          // cross-origin allowed, only if the server opts in
}

Credentials :: enum u8 {
	Omit,          // never send or store cookies
	Same_Origin,   // only for same-origin requests
	Include,       // always (cross-origin responses must then opt in with Access-Control-Allow-Credentials)
}

Redirect_Mode :: enum u8 { Follow, Error, Manual }

Destination :: enum u8 {
	Empty,         // fetch() / XHR-like
	Document,
	Script,        // a Wasm module
	Style,
	Image,
	Font,
	Audio,
	Video,
	Manifest,
	Report,
	Worker,        // a dedicated worker's Wasm module: application/wasm, CSP worker-src
	Iframe,        // a nested document (<iframe>): mode Navigate, CSP frame-src, not a top-level site
	Frame,         // the same for a <frame> (Request.destination "frame", Sec-Fetch-Dest: frame)
}

// A nested document's navigation (<iframe> or <frame>): what the policies treat alike.
is_frame_destination :: #force_inline proc(d: Destination) -> bool { return d == .Iframe || d == .Frame }

Referrer_Policy :: enum u8 {
	Default,       // "not set": use the document's policy, then the profile default
	No_Referrer,
	No_Referrer_When_Downgrade,
	Same_Origin,
	Origin,
	Strict_Origin,
	Origin_When_Cross_Origin,
	Strict_Origin_When_Cross_Origin,
	Unsafe_Url,
}

Header_Guard :: enum u8 {
	None,          // browser-internal: any header
	Request,        // script-supplied: forbidden header names are refused
}

Header_Pair :: struct { name, value: string }

// What the caller asks for. All strings are copied.
Request_Desc :: struct {
	url:             string,
	method:          string,            // default "GET"
	headers:         []Header_Pair,
	body:            []byte,
	mode:            Mode,
	credentials:     Credentials,
	redirect:        Redirect_Mode,
	destination:     Destination,
	referrer_policy: Referrer_Policy,
	no_referrer:     bool,              // referrer = "no-referrer" regardless of policy
	initiator:       ^Environment,      // the document making the request; nil = the browser UI (address bar, bookmarks)
	user_activation: bool,              // navigation started by a user gesture (Sec-Fetch-User)
	guard:           Header_Guard,
	max_body:        int,               // 0 = net.DEFAULT_MAX_BODY
	nonce:           string,            // the nonce attribute of the element that caused the request (CSP)
	script:          Script_Type,       // destination Script / Worker: a Wasm module (default) or JavaScript (script_type.odin)
	parser_inserted: bool,              // a script the parser inserted (CSP 'strict-dynamic' trusts only the others)
	cache:           Cache_Mode,        // Request.cache (http_cache.odin)
	ping:            bool,              // a beacon: filters see it as ping, not as a fetch
	skip_service_worker: bool,          // service-workers mode "none": no service worker may answer it
}

// The "environment settings object" of a document: who is asking.
Environment :: struct {
	location:        url.URL,
	origin:          url.Origin,
	site:            url.Site,
	top_level_site:  url.Site,          // for a top-level document: its own site
	secure_context:  bool,
	referrer_policy: Referrer_Policy,   // from the document's Referrer-Policy header / meta
	file_root:       string,            // for file: documents: the directory tree they may read (see local_schemes.odin)
	policies:        csp.Policy_List,   // the document's CSP (headers + <meta>)
	on_violation:    proc(user: rawptr, v: csp.Violation),
	violation_user:  rawptr,
	cache_override:  Cache_Mode,        // the mode of this document's requests that ask for the default (a reload without the cache)
	counts:          Fetch_Counts,      // what this document's requests cost (status bar, measurements)
	tag:             u64,               // the content blocker's handle for the document's tab (copied by environment_clone; intercept.odin)
	storage_access:  Storage_Access,    // a cross-site frame's unpartitioned storage and cookies (Storage Access API)
	embedder_policy: Embedder_Policy,   // Cross-Origin-Embedder-Policy of the document, or what a worker has of its creator
	cross_origin_isolated: bool,        // HTML's capability (apply_isolation_headers in src/page/page.odin)
	agent_cluster:   u64,               // the wasm package's number of its agent cluster: 0 until something needs one
}

// Cross-Origin-Embedder-Policy.
Embedder_Policy :: enum u8 { Unsafe_None, Require_Corp, Credentialless }

// The Storage Access API's state of a document (Sec-Fetch-Storage-Access): no permission for its site under the
// top-level site; permission granted but not used by this document yet; in use (document.requestStorageAccess()
// resolved): its requests carry its first-party cookies, its storage is its origin's.
Storage_Access :: enum u8 { None, Inactive, Active }

// The requests of a document by where their responses came from (http_cache.odin), and the body bytes the network
// brought for them.
Fetch_Counts :: struct {
	network:       int,
	cache:         int,   // served without the network (fresh, or stale-while-revalidate)
	revalidated:   int,   // 304: the stored body served
	network_bytes: i64,
}

environment_make :: proc(document_url: url.URL, referrer_policy := Referrer_Policy.Default) -> Environment {
	e: Environment
	e.location = url.clone(document_url)
	e.origin = url.origin_of(e.location)
	e.site = url.site_of(e.origin)
	e.top_level_site = url.site_of(e.origin)
	e.secure_context = url.is_potentially_trustworthy(e.location)
	e.referrer_policy = referrer_policy
	if e.location.scheme == "file" { e.file_root = file_directory(e.location) }
	return e
}

// A copy that can outlive the document it describes (a navigation keeps its initiator after the old page is gone).
// The policies are not copied: an initiator only supplies who is asking, not what it may load.
environment_clone :: proc(e: Environment) -> Environment {
	c: Environment
	c.location = url.clone(e.location)
	c.origin = url.origin_clone(e.origin)
	c.site = url.site_of(c.origin)
	c.top_level_site = url.site_of(c.origin)
	c.secure_context = e.secure_context
	c.referrer_policy = e.referrer_policy
	c.file_root = strings.clone(e.file_root)
	c.tag = e.tag
	c.storage_access = e.storage_access
	c.embedder_policy = e.embedder_policy
	return c
}

environment_destroy :: proc(e: ^Environment) {
	url.destroy(&e.location)
	url.origin_destroy(&e.origin)
	url.site_destroy(&e.site)
	url.site_destroy(&e.top_level_site)
	delete(e.file_root)
	csp.list_destroy(&e.policies)
	e^ = {}
}

Third_Party_Cookies :: enum u8 {
	Block,   // cookies are neither sent nor stored for requests that are cross-site to the top-level document
	Allow,
}

// State shared by every document of a profile.
Profile :: struct {
	settings:   Settings,    // see settings.odin: every tunable of this layer
	jar:        cookies.Jar,
	hsts:       Hsts,
	preflights: Preflight_Cache,
	cache:      ^httpcache.Cache,   // the HTTP cache (nil: none); created and destroyed by its owner (http_cache.odin)
}

// Zero settings = the defaults (what about:config shows).
profile_make :: proc(fetch_settings: Settings = {}, cookie_settings: cookies.Settings = {}) -> Profile {
	fs := fetch_settings
	if fs.max_redirects == 0 && fs.accept_language == "" { fs = settings_default() }
	return Profile{settings = fs, jar = cookies.jar_make(cookie_settings), hsts = hsts_make(), preflights = preflight_cache_make()}
}

profile_destroy :: proc(p: ^Profile) {
	settings_destroy(&p.settings)
	cookies.jar_destroy(&p.jar)
	hsts_destroy(&p.hsts)
	preflight_cache_destroy(&p.preflights)
	p^ = {}
}

Response_Type :: enum u8 {
	Basic,           // same-origin: all headers except Set-Cookie
	Cors,            // cross-origin with CORS: safelisted + exposed headers
	Opaque,          // cross-origin no-cors: nothing readable
	Opaque_Redirect, // redirect: manual
}

// Delivered with the Response event; every pointer is valid only during the callback.
Response :: struct {
	type:       Response_Type,
	status:     int,                 // 0 for opaque
	url:        string,              // the final URL (after redirects)
	redirected: bool,
	headers:    http.Headers,        // filtered according to `type`
	mime:       http.Mime,           // from the *unfiltered* Content-Type, always available to the browser
	has_mime:   bool,
	body_usable: bool,               // false for opaque responses: only internal consumers (images) may use the bytes
	cache:      Cache_Outcome,       // from the network, the cache, or the cache after a 304
}

Event_Kind :: enum u8 { Response, Data, Done, Failed }

Error_Kind :: enum u8 {
	None,
	Bad_URL,
	Bad_Scheme,
	Bad_Port,
	Bad_Method,
	Bad_Header,
	Credentials_In_URL,
	Blocked_Mixed_Content,
	Blocked_Csp,
	Blocked_Same_Origin,    // mode same-origin and the URL is cross-origin
	Blocked_Cors,
	Blocked_Preflight,
	Blocked_File,           // a file: URL outside what the document may read
	Redirect_Error,         // redirect mode "error"
	Redirect_Loop,          // more than 20 redirects
	Bad_Redirect,           // unparseable / forbidden Location
	Bad_Mime,               // Content-Type does not fit the destination (or nosniff)
	Bad_Data_URL,
	Body_Too_Large,
	Transport,              // `net_code` has the WinHTTP / net error
	Unsupported,
	Aborted,
	Not_Cached,             // cache mode only-if-cached and nothing stored
	Blocked_By_Client,      // the content blocker refused it (net::ERR_BLOCKED_BY_CLIENT; detail names the rule), or the developer tools' request blocking (or their offline mode) stopped it
}

Event :: struct {
	kind:     Event_Kind,
	response: ^Response,    // Response event
	data:     []byte,       // Data chunk, or the whole body in collect mode on Done
	error:    Error_Kind,
	detail:   string,       // human readable, for the console
	net_code: u32,
	net_flags: u32,
}

Event_Proc :: #type proc(user: rawptr, task: base.Handle, ev: ^Event)

Start_Desc :: struct {
	request:  Request_Desc,
	on_event: Event_Proc,
	user:     rawptr,
	scope:    ^base.Scope,   // closing it cancels the task silently
	collect:  bool,          // one Done event carrying the whole body instead of Data chunks
}

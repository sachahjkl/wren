package adblock

// What a request is, as filters name it (`$script`, `$image`...). The browser maps its own destinations to these; the
// last ones are not requests but page-level switches that only exceptions use (`@@||site^$generichide`).
Resource :: enum u8 {
	Document,      // top-level navigation (`document`)
	Subdocument,   // <iframe>, <frame> (`subdocument`)
	Stylesheet,
	Script,
	Image,
	Font,
	Object,
	Xhr,           // fetch() and XMLHttpRequest (`xmlhttprequest`)
	Ping,          // beacons, <a ping>
	Media,
	Websocket,
	Other,
	Csp_Report,
	Popup,         // a new window opened by the page (`popup`)
	Webrtc,
	Inline_Script, // `$inline-script`: becomes a CSP
	Inline_Font,
	Elemhide,      // exceptions only: no cosmetic filtering at all
	Generichide,   // exceptions only: no generic cosmetic filters
	Specifichide,  // exceptions only: no site-specific cosmetic filters
	Cname,         // accepted and ignored
}

Resource_Set :: bit_set[Resource; u32]

// What a filter without a type option applies to.
DEFAULT_TYPES :: Resource_Set{.Subdocument, .Stylesheet, .Script, .Image, .Font, .Object, .Xhr, .Ping, .Media, .Websocket, .Other, .Webrtc}
// `$all`: everything.
ALL_TYPES :: Resource_Set{.Document, .Subdocument, .Stylesheet, .Script, .Image, .Font, .Object, .Xhr, .Ping, .Media, .Websocket, .Other, .Csp_Report, .Popup, .Webrtc, .Inline_Script, .Inline_Font}
// What a `$csp` filter applies to by default.
FRAME_TYPES :: Resource_Set{.Document, .Subdocument}
PAGE_SWITCHES :: Resource_Set{.Elemhide, .Generichide, .Specifichide}

resource_name :: proc(r: Resource) -> string {
	switch r {
	case .Document: return "document"
	case .Subdocument: return "subdocument"
	case .Stylesheet: return "stylesheet"
	case .Script: return "script"
	case .Image: return "image"
	case .Font: return "font"
	case .Object: return "object"
	case .Xhr: return "xmlhttprequest"
	case .Ping: return "ping"
	case .Media: return "media"
	case .Websocket: return "websocket"
	case .Other: return "other"
	case .Csp_Report: return "csp_report"
	case .Popup: return "popup"
	case .Webrtc: return "webrtc"
	case .Inline_Script: return "inline-script"
	case .Inline_Font: return "inline-font"
	case .Elemhide: return "elemhide"
	case .Generichide: return "generichide"
	case .Specifichide: return "specifichide"
	case .Cname: return "cname"
	}
	return "other"
}

Method :: enum u8 { Get, Post, Put, Delete, Head, Options, Patch, Connect, Trace }
Method_Set :: bit_set[Method; u16]

method_from_string :: proc(s: string) -> Method {
	switch s {
	case "POST", "post": return .Post
	case "PUT", "put": return .Put
	case "DELETE", "delete": return .Delete
	case "HEAD", "head": return .Head
	case "OPTIONS", "options": return .Options
	case "PATCH", "patch": return .Patch
	case "CONNECT", "connect": return .Connect
	case "TRACE", "trace": return .Trace
	}
	return .Get
}

// Filter record flags.
Filter_Flag :: enum u16 {
	Host_Anchor,     // `||`
	Left_Anchor,     // `|` at the start
	Right_Anchor,    // `|` at the end
	Regex,           // the pattern is a regular expression
	Match_Case,
	Important,
	Third_Party,     // only third-party requests
	First_Party,     // only first-party requests
	Exception,       // `@@`
	Host_Only,       // `||host^`: indexed by host
	Redirect_Rule,   // `$redirect-rule`: redirects without blocking
	Empty_Pattern,   // matches every URL
	Needs_Original,  // the pattern has upper case or is a regex: matched against the URL as given
}
Filter_Flags :: bit_set[Filter_Flag; u16]

// The compiled form of a network filter (28 bytes).
Filter :: struct {
	pat_off:  u32,           // pattern in the string pool
	pat_len:  u16,
	flags:    Filter_Flags,
	types:    Resource_Set,
	methods:  Method_Set,    // 0 = any
	list:     u8,            // the source (list) it came from
	src_off:  u32,           // `domain=` / `from=` list (domain_list), 0 = none
	to_off:   u32,           // `to=` / `denyallow=` list, 0 = none
	arg_off:  u32,           // redirect resource / csp / removeparam / header argument (pool, NUL terminated), 0 = none
	text_off: u32,           // where the line starts in its source text
}

// Where a filter lives, for the logger: the list it came from and where its text starts in it.
Filter_Ref :: struct { list: u8, offset: u32 }

NO_FILTER :: u32(0xFFFFFFFF)

// The filter's argument (redirect resource name, csp policy, removeparam name...).
Action :: enum u8 {
	Allow,       // nothing matched
	Block,       // a blocking filter matched
	Redirect,    // blocked, and answered with a neutral resource instead (`resource`)
	Exception,   // an exception filter matched a request that a blocking filter would have blocked
}

Verdict :: struct {
	action:    Action,
	filter:    u32,        // the filter that decided (Block / Redirect: the blocker; Exception: the exception), NO_FILTER if none
	blocker:   u32,        // Exception: the filter that would have blocked
	redirect:  u32,        // Redirect: the redirect filter that chose the resource (NO_FILTER if none)
	resource:  string,     // Redirect: resource name ("noop.js"); valid as long as the engine
}

// One request to judge. Fill with `make_request`; the strings must stay valid during the call.
Request :: struct {
	url:         string,       // as given (original case)
	host:        string,       // lower-case request host
	source_url:  string,       // the document the request comes from ("" for a top-level navigation)
	source_host: string,       // lower-case host of that document
	source_domain: string,     // its registrable domain
	type:        Resource,
	method:      Method,
	third_party: bool,
}

// Fills a request from URLs. `source_url` = "" for the navigation itself (the document); then it is first party.
make_request :: proc(url, source_url: string, type: Resource, method := Method.Get) -> Request {
	r := Request{url = url, source_url = source_url, type = type, method = method}
	r.host = url_host(url)
	if source_url != "" { r.source_host = url_host(source_url) } else { r.source_host = r.host }
	if r.source_host != "" { r.source_domain = registrable_domain(r.source_host) }
	if r.host != "" && r.source_host != "" && source_url != "" {
		r.third_party = registrable_domain(r.host) != r.source_domain
	}
	return r
}

// Which list texts a filter can be shown from: the engine only keeps (list, offset).
Source :: struct {
	id:   u8,
	name: string,
	text: string,
}

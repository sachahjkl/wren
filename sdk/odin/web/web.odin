// Guest-side bindings of the browser's web platform for Odin (freestanding_wasm32). Hand-written for now; they are the
// mechanical translation of the host's import tables, which a Web IDL generator will produce for every language.
//
// Nothing here is glue: each foreign procedure is a Wasm import resolved by the browser.
package web

Handle :: distinct i64
NIL :: Handle(0)

Error :: enum i32 {
	None             = 0,
	Invalid_Handle   = -1,
	Hierarchy        = -2,
	Not_Found        = -3,
	Invalid_Argument = -4,
	Attached         = -5,
}

// A listener / timer callback is a plain function pointer plus a user value.
Event_Callback :: #type proc "contextless" (user: i32, event: Handle)
Timer_Callback :: #type proc "contextless" (user: i32)
Fetch_Callback :: #type proc "contextless" (user: i32, request: Handle, state: Fetch_State)

Fetch_State :: enum i32 { Pending, Response, Done, Failed }

Response_Type :: enum i32 { Basic, Cors, Opaque, Opaque_Redirect }

Fetch_Mode :: enum u32 { Cors, Same_Origin, No_Cors }
Credentials :: enum u32 { Same_Origin, Omit, Include }
Redirect_Mode :: enum u32 { Follow, Error, Manual }

// Fetch API options; the zero value is the specification default (cors, same-origin credentials, follow).
Fetch_Options :: struct {
	mode:        Fetch_Mode,
	credentials: Credentials,
	redirect:    Redirect_Mode,
	referrer_policy: u32,   // 0 default, then fetch.Referrer_Policy order
	no_referrer: bool,
}

foreign import dom "dom"
foreign import events "events"
foreign import timers "timers"
foreign import net "net"
foreign import console "console"
foreign import document "document"

@(default_calling_convention = "contextless")
foreign dom {
	Document_documentElement :: proc() -> Handle ---
	Document_head :: proc() -> Handle ---
	Document_body :: proc() -> Handle ---
	@(link_name = "Document_createElement") raw_createElement :: proc(tag: [^]u8, len: i32) -> Handle ---
	@(link_name = "Document_createTextNode") raw_createTextNode :: proc(s: [^]u8, len: i32) -> Handle ---
	@(link_name = "Document_getElementById") raw_getElementById :: proc(id: [^]u8, len: i32) -> Handle ---
	Node_appendChild :: proc(parent, child: Handle) -> Error ---
	Node_insertBefore :: proc(parent, child, ref: Handle) -> Error ---
	Node_removeChild :: proc(parent, child: Handle) -> Error ---
	Node_release :: proc(node: Handle) -> Error ---
	Node_parentNode :: proc(node: Handle) -> Handle ---
	Node_firstChild :: proc(node: Handle) -> Handle ---
	Node_lastChild :: proc(node: Handle) -> Handle ---
	Node_previousSibling :: proc(node: Handle) -> Handle ---
	Node_nextSibling :: proc(node: Handle) -> Handle ---
	Node_nodeType :: proc(node: Handle) -> i32 ---
	@(link_name = "Node_setTextContent") raw_setTextContent :: proc(node: Handle, s: [^]u8, len: i32) -> Error ---
	@(link_name = "Node_getTextContent") raw_getTextContent :: proc(node: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Element_tagName") raw_tagName :: proc(node: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Element_setAttribute") raw_setAttribute :: proc(node: Handle, n: [^]u8, nl: i32, v: [^]u8, vl: i32) -> Error ---
	@(link_name = "Element_getAttribute") raw_getAttribute :: proc(node: Handle, n: [^]u8, nl: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Element_removeAttribute") raw_removeAttribute :: proc(node: Handle, n: [^]u8, nl: i32) -> Error ---
}

@(default_calling_convention = "contextless")
foreign events {
	@(link_name = "EventTarget_addEventListener") raw_addEventListener :: proc(target: Handle, type: [^]u8, tl: i32, callback: Event_Callback, user: i32, flags: i32) -> i32 ---
	EventTarget_removeEventListener :: proc(target: Handle, id: i32) -> Error ---
	@(link_name = "EventTarget_dispatchEvent") raw_dispatchEvent :: proc(target: Handle, type: [^]u8, tl: i32, flags: i32) -> i32 ---
	Event_preventDefault :: proc(ev: Handle) ---
	Event_stopPropagation :: proc(ev: Handle) ---
	Event_stopImmediatePropagation :: proc(ev: Handle) ---
	Event_target :: proc(ev: Handle) -> Handle ---
	Event_currentTarget :: proc(ev: Handle) -> Handle ---
	@(link_name = "Event_type") raw_eventType :: proc(ev: Handle, buf: [^]u8, cap: i32) -> i32 ---
	MouseEvent_clientX :: proc(ev: Handle) -> f64 ---
	MouseEvent_clientY :: proc(ev: Handle) -> f64 ---
	MouseEvent_button :: proc(ev: Handle) -> i32 ---
	KeyboardEvent_keyCode :: proc(ev: Handle) -> i32 ---
}

@(default_calling_convention = "contextless")
foreign timers {
	Timers_setTimeout :: proc(callback: Timer_Callback, user: i32, delay_ms: f64) -> Handle ---
	Timers_setInterval :: proc(callback: Timer_Callback, user: i32, delay_ms: f64) -> Handle ---
	Timers_clear :: proc(timer: Handle) -> Error ---
	Timers_now :: proc() -> f64 ---
}

@(default_calling_convention = "contextless")
foreign net {
	@(link_name = "Fetch_start") raw_fetch :: proc(url: [^]u8, ul: i32, method: [^]u8, ml: i32, headers: [^]u8, hl: i32, body: [^]u8, bl: i32, options: i32, callback: Fetch_Callback, user: i32) -> Handle ---
	Fetch_state :: proc(f: Handle) -> Fetch_State ---
	Fetch_status :: proc(f: Handle) -> i32 ---
	Fetch_type :: proc(f: Handle) -> Response_Type ---
	Fetch_redirected :: proc(f: Handle) -> i32 ---
	@(link_name = "Fetch_headers") raw_fetchHeaders :: proc(f: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Fetch_url") raw_fetchUrl :: proc(f: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Fetch_error") raw_fetchError :: proc(f: Handle, buf: [^]u8, cap: i32) -> i32 ---
	Fetch_errorKind :: proc(f: Handle) -> i32 ---
	Fetch_bodyLength :: proc(f: Handle) -> i64 ---
	@(link_name = "Fetch_readBody") raw_readBody :: proc(f: Handle, offset: i64, buf: [^]u8, cap: i32) -> i32 ---
	Fetch_release :: proc(f: Handle) -> Error ---
}

@(default_calling_convention = "contextless")
foreign document {
	@(link_name = "Document_URL") raw_documentURL :: proc(buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Window_origin") raw_origin :: proc(buf: [^]u8, cap: i32) -> i32 ---
	Window_isSecureContext :: proc() -> i32 ---
	@(link_name = "Document_cookie_get") raw_cookieGet :: proc(buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Document_cookie_set") raw_cookieSet :: proc(s: [^]u8, n: i32) -> i32 ---
}
@(default_calling_convention = "contextless")
foreign console {
	@(link_name = "log") raw_log :: proc(p: [^]u8, n: i32) ---
	@(link_name = "warn") raw_warn :: proc(p: [^]u8, n: i32) ---
	@(link_name = "error") raw_error :: proc(p: [^]u8, n: i32) ---
}

////////////////////////////////
// Ergonomic layer

log :: proc "contextless" (s: string) { raw_log(raw_data(s), i32(len(s))) }
warn :: proc "contextless" (s: string) { raw_warn(raw_data(s), i32(len(s))) }
error :: proc "contextless" (s: string) { raw_error(raw_data(s), i32(len(s))) }

create_element :: proc "contextless" (tag: string) -> Handle { return raw_createElement(raw_data(tag), i32(len(tag))) }
create_text :: proc "contextless" (s: string) -> Handle { return raw_createTextNode(raw_data(s), i32(len(s))) }
get_element_by_id :: proc "contextless" (id: string) -> Handle { return raw_getElementById(raw_data(id), i32(len(id))) }
set_text :: proc "contextless" (node: Handle, s: string) -> Error { return raw_setTextContent(node, raw_data(s), i32(len(s))) }
set_attribute :: proc "contextless" (node: Handle, name, value: string) -> Error {
	return raw_setAttribute(node, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)))
}

// Reads a host string into `buf` and returns the part that fit (call again with a bigger buffer if `n > len(buf)`).
get_text :: proc "contextless" (node: Handle, buf: []u8) -> (s: string, needed: int) {
	n := raw_getTextContent(node, raw_data(buf), i32(len(buf)))
	if n < 0 { return "", 0 }
	return string(buf[:min(int(n), len(buf))]), int(n)
}

get_attribute :: proc "contextless" (node: Handle, name: string, buf: []u8) -> (s: string, found: bool) {
	n := raw_getAttribute(node, raw_data(name), i32(len(name)), raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return string(buf[:min(int(n), len(buf))]), true
}

add_listener :: proc "contextless" (target: Handle, type: string, cb: Event_Callback, user: i32 = 0, capture := false, once := false) -> i32 {
	flags: i32
	if capture { flags |= 1 }
	if once { flags |= 2 }
	return raw_addEventListener(target, raw_data(type), i32(len(type)), cb, user, flags)
}

dispatch :: proc "contextless" (target: Handle, type: string, bubbles := true, cancelable := true) -> bool {
	flags: i32
	if bubbles { flags |= 1 }
	if cancelable { flags |= 2 }
	return raw_dispatchEvent(target, raw_data(type), i32(len(type)), flags) != 0
}

fetch :: proc "contextless" (url: string, cb: Fetch_Callback, user: i32 = 0, method := "GET", headers := "", body: []u8 = nil, opt := Fetch_Options{}) -> Handle {
	o := u32(opt.mode) | u32(opt.credentials) << 2 | u32(opt.redirect) << 4 | (opt.referrer_policy & 0xF) << 6
	if opt.no_referrer { o |= 1 << 10 }
	return raw_fetch(raw_data(url), i32(len(url)), raw_data(method), i32(len(method)), raw_data(headers), i32(len(headers)),
		raw_data(body), i32(len(body)), i32(o), cb, user)
}

// document.cookie: the non-HttpOnly cookies, or ok = false when the document may not use cookies (opaque origin).
cookie :: proc "contextless" (buf: []u8) -> (s: string, ok: bool) {
	n := raw_cookieGet(raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return string(buf[:min(int(n), len(buf))]), true
}

// Returns 0 when the cookie was applied, a negative value for a SecurityError, a positive value when refused.
set_cookie :: proc "contextless" (s: string) -> i32 { return raw_cookieSet(raw_data(s), i32(len(s))) }

origin :: proc "contextless" (buf: []u8) -> string {
	n := raw_origin(raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}
// Copies the body (as received so far) into `buf`.
read_body :: proc "contextless" (f: Handle, buf: []u8, offset: i64 = 0) -> []u8 {
	n := raw_readBody(f, offset, raw_data(buf), i32(len(buf)))
	return buf[:max(n, 0)]
}

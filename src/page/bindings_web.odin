package page

// Modules "net" (fetch with a callback) and "document" (URL, origin, cookies).
//
// Fetch from a guest is the Fetch Standard through package fetch: the request carries the document's Environment, so
// origin, CORS, cookies, referrer, CSP and mixed-content rules are applied by the browser, never by the guest. The
// guest's FetchOptions travel packed in a u32 (fetch_options_pack), the form a worker's request is relayed in.

import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:fetch"
import "wb:http"
import "wb:url"

////////////////////////////////
// net

// What a request record learns about its response. Pages get it from the loader; workers get it relayed from the UI
// thread, where their requests run (worker.odin).
Fetch_Update :: struct {
	kind:       fetch.Event_Kind,
	status:     int,
	type:       fetch.Response_Type,
	redirected: bool,
	usable:     bool,
	url:        string,
	headers:    string,     // "Name: value" lines, CR LF terminated
	data:       []byte,
	error:      fetch.Error_Kind,
	detail:     string,
}

// "Name: value\r\n" for each header, the form the guest reads (Fetch_headers).
@(private)
serialize_headers :: proc(list: []http.Header, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for h in list { strings.write_string(&sb, h.name); strings.write_string(&sb, ": "); strings.write_string(&sb, h.value); strings.write_string(&sb, "\r\n") }
	return strings.to_string(sb)
}

@(private)
fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	f := (^Fetch)(user)
	// `user` is the record's slot: an event the loader queued before the record was released (and its task
	// cancelled) may arrive after another request took the slot. Only the record's own task speaks for it.
	if f.task != task { return }
	if f.ext != nil { fetch_ext_event(f, ev); return }   // promise / stream / abort signal (bindings_fetch.odin)
	u := Fetch_Update{kind = ev.kind, data = ev.data, error = ev.error, detail = ev.detail}
	if ev.kind == .Response {
		r := ev.response
		u.status, u.type, u.redirected, u.usable, u.url = r.status, r.type, r.redirected, r.body_usable, r.url
		u.headers = serialize_headers(r.headers.list[:])
	}
	fetch_update(f, u)
}

// Stops a request still in flight (silently: no further update).
@(private)
fetch_abort :: proc(p: ^Page, f: ^Fetch) {
	if f.task == base.NIL_HANDLE { return }
	if p.worker != nil { worker_fetch_cancel(p, f) } else { fetch.cancel(p.loader, f.task) }
	f.task = base.NIL_HANDLE
}

@(private)
fetch_note_response :: proc(f: ^Fetch, r: ^fetch.Response) {
	f.state, f.status, f.type, f.redirected, f.usable = 1, r.status, r.type, r.redirected, r.body_usable
	f.final_url = strings.clone(r.url)
	f.headers = strings.clone(serialize_headers(r.headers.list[:]))
}

@(private)
fetch_update :: proc(f: ^Fetch, ev: Fetch_Update) {
	p := f.page
	switch ev.kind {
	case .Response:
		f.state, f.status, f.type, f.redirected, f.usable = 1, ev.status, ev.type, ev.redirected, ev.usable
		f.final_url = strings.clone(ev.url)
		f.headers = strings.clone(ev.headers)
	case .Data:
		if !f.usable { return }   // opaque: scripts never see the bytes
		if p.held + len(ev.data) > p.settings.max_fetch_bytes {
			f.state, f.error, f.error_kind = 3, strings.clone("page fetch memory limit reached"), .Body_Too_Large
			fetch_abort(p, f)
			break
		}
		p.held += len(ev.data)
		append(&f.body, ..ev.data)
		return
	case .Done:
		f.state, f.task = 2, base.NIL_HANDLE
		if len(ev.data) > 0 && len(f.body) == 0 && f.usable {
			p.held += len(ev.data)
			append(&f.body, ..ev.data)
		}
	case .Failed:
		f.state, f.task = 3, base.NIL_HANDLE
		f.error = strings.clone(ev.detail)
		f.error_kind = ev.error
		if ev.error != .Transport { log(p, .Error, ev.detail) }
	}
	inst := instance_by_index(p, f.instance)
	if inst == nil { return }
	// the guest learns about it through its callback: (user: i32, fetch: i64, state: i32)
	h := f.self
	argv := [4]u32{f.user, u32(u64(h)), u32(u64(h) >> 32), u32(f.state)}
	call_guest(p, inst, f.callback, argv[:])
}

// "Name: value" lines separated by CR LF or LF.
@(private)
parse_header_lines :: proc(s: string, out: ^[dynamic]fetch.Header_Pair) {
	text := s
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_right(line, "\r")
		if l == "" { continue }
		colon := strings.index_byte(l, ':')
		if colon <= 0 { append(out, fetch.Header_Pair{l, ""}); continue }   // an invalid pair: fetch.start rejects it
		append(out, fetch.Header_Pair{strings.trim_space(l[:colon]), strings.trim_space(l[colon + 1:])})
	}
}

Fetch_start :: proc(c: ^Call, url: string, callback: u32, user: i32, method: string, headers: string, body: Maybe([]u8), options: Api_FetchOptions) -> u64 {
	return fetch_begin(c.page, c.owner, url, method, headers, body.? or_else nil, fetch_options_pack(options), callback, u32(user), nil)
}

// The options as the request code keeps them (bits 0-1 mode, 2-3 credentials, 4-5 redirect, 6-9 referrer policy,
// 10 no referrer): what a worker's request relays to the UI thread.
@(private)
fetch_options_pack :: proc(o: Api_FetchOptions) -> u32 {
	v := u32(o.mode) | u32(o.credentials) << 2 | u32(o.redirect) << 4 | u32(o.referrer_policy) << 6
	if o.no_referrer { v |= 1 << 10 }
	return v
}

// Starts a fetch for a guest. `ext` (promise, stream, abort signal) is owned by the record from here on. In a worker the
// request is relayed to the UI thread, where the loader lives (worker.odin); the extended forms are page-only.
@(private)
fetch_begin :: proc(p: ^Page, owner: u32, target, method, headers: string, body: []byte, options: u32, callback, user: u32, ext: ^Fetch_Ext) -> u64 {
	h, f := base.pool_insert(&p.fetches, Fetch{page = p, instance = owner, callback = callback, user = user, ext = ext})
	f.self = h
	if ext != nil && !fetch_ext_attach(p, f) { return u64(h) }   // its signal is already aborted: the failure is on its way

	// relative URLs resolve against the document (or the worker's script)
	abs := target
	if u, ok := url.parse(abs, &p.env.location, context.temp_allocator); ok { abs = u.href }

	if p.worker != nil {
		worker_fetch_start(p, f, abs, method, headers, body, options)
		return u64(h)
	}
	f.task = fetch.start(p.loader, {
		request = guest_request(abs, method, headers, body, options, &p.env),
		on_event = fetch_event, user = f, scope = p.scope, collect = false,
	})
	return u64(h)
}

// The request a guest asks for with Fetch_start (strings are borrowed; fetch.start copies them).
@(private)
guest_request :: proc(abs, method, headers: string, body: []byte, o: u32, initiator: ^fetch.Environment) -> fetch.Request_Desc {
	pairs := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	parse_header_lines(headers, &pairs)
	mode := fetch.Mode.Cors
	switch o & 3 { case 1: mode = .Same_Origin; case 2: mode = .No_Cors }
	creds := fetch.Credentials.Same_Origin
	switch (o >> 2) & 3 { case 1: creds = .Omit; case 2: creds = .Include }
	redirect := fetch.Redirect_Mode.Follow
	switch (o >> 4) & 3 { case 1: redirect = .Error; case 2: redirect = .Manual }
	policy := fetch.Referrer_Policy((o >> 6) & 0xF)
	if policy > .Unsafe_Url { policy = .Default }
	return fetch.Request_Desc{
		url = abs, method = method, headers = pairs[:], body = body,
		mode = mode, credentials = creds, redirect = redirect, destination = .Empty,
		referrer_policy = policy, no_referrer = o & (1 << 10) != 0,
		initiator = initiator, guard = .Request,
	}
}

Fetch_state :: proc(c: ^Call, request: Api_Fetch) -> Api_FetchState { return Api_FetchState(request.data.state) }
Fetch_status :: proc(c: ^Call, request: Api_Fetch) -> i32 { return i32(request.data.status) }
// 0 basic, 1 cors, 2 opaque, 3 opaque-redirect
Fetch_type :: proc(c: ^Call, request: Api_Fetch) -> Api_ResponseType { return Api_ResponseType(request.data.type) }
Fetch_redirected :: proc(c: ^Call, request: Api_Fetch) -> bool { return request.data.redirected }
Fetch_headers :: proc(c: ^Call, request: Api_Fetch) -> string { return request.data.headers }
Fetch_url :: proc(c: ^Call, request: Api_Fetch) -> string { return request.data.final_url }
Fetch_error :: proc(c: ^Call, request: Api_Fetch) -> string { return request.data.error }
Fetch_errorKind :: proc(c: ^Call, request: Api_Fetch) -> i32 { return i32(request.data.error_kind) }
Fetch_bodyLength :: proc(c: ^Call, request: Api_Fetch) -> u64 { return u64(len(request.data.body)) }

// Copies what fits from `offset`; returns the number copied.
Fetch_readBody :: proc(c: ^Call, request: Api_Fetch, offset: u64, buffer: []u8) -> i32 {
	f := request.data
	if offset >= u64(len(f.body)) { return 0 }
	return i32(copy(buffer, f.body[offset:]))
}

Fetch_release :: proc(c: ^Call, request: Api_Fetch) -> Api_Error {
	p := c.page
	fetch_abort(p, request.data)
	f, _ := base.pool_remove(&p.fetches, H(request.handle))
	p.held -= len(f.body)
	free_fetch(&f)
	return .None
}

////////////////////////////////
// document: location, origin, cookies

Document_URL :: proc(c: ^Call) -> (string, Api_Error) {
	p := c.page
	if p.worker != nil { return "", fail(c, .Invalid_Handle, "no document in a worker (see WorkerGlobalScope_location)") }
	return p.env.location.href, .None
}

// Window_origin and Window_isSecureContext belong to WindowOrWorkerGlobalScope: in a worker they describe the worker.

Window_origin :: proc(c: ^Call) -> string { return url.origin_serialize(c.page.env.origin, context.temp_allocator) }
Window_isSecureContext :: proc(c: ^Call) -> bool { return c.page.env.secure_context }

// Cookies are only for documents with a tuple origin on http(s): opaque origins (file:, data:) get a SecurityError.
@(private)
cookie_context :: proc(p: ^Page) -> (cc: cookies.Context, ok: bool) {
	if p.worker != nil || p.env.origin.opaque || (p.env.location.scheme != "http" && p.env.location.scheme != "https") { return {}, false }
	return cookies.Context{url = p.env.location, site_context = .Same_Site, http_api = false, now_ms = fetch.now_ms()}, true
}

// document.cookie getter: the non-HttpOnly cookies of this document, "name=value; ...".
Document_cookie_get :: proc(c: ^Call) -> (string, Api_Error) {
	p := c.page
	cc, ok := cookie_context(p)
	if !ok { return "", fail(c, .Security, "SecurityError: this document cannot use cookies") }
	return cookies.header_for(&p.loader.profile.jar, cc, context.temp_allocator), .None
}

// document.cookie setter: 0 when applied, else 1 + the cookies.Store_Result that refused it.
Document_cookie_set :: proc(c: ^Call, cookie: string) -> (i32, Api_Error) {
	p := c.page
	cc, ok := cookie_context(p)
	if !ok { return 0, fail(c, .Security, "SecurityError: this document cannot use cookies") }
	r := cookies.store(&p.loader.profile.jar, cookie, cc)
	#partial switch r {
	case .Stored, .Replaced, .Deleted: return 0, .None
	}
	return 1 + i32(r), .None
}
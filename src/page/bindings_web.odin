package page

// timers, network and document-level imports.
//
// Fetch from a guest is the Fetch Standard through package fetch: the request carries the document's Environment, so
// origin, CORS, cookies, referrer, CSP and mixed-content rules are applied by the browser, never by the guest. Options are
// packed in one i32 (zero is the Fetch API default for every field):
//
//   bits 0-1  mode            0 cors, 1 same-origin, 2 no-cors
//   bits 2-3  credentials     0 same-origin, 1 omit, 2 include
//   bits 4-5  redirect        0 follow, 1 error, 2 manual
//   bits 6-9  referrer policy 0 default, then fetch.Referrer_Policy order
//   bit  10   no referrer

import "base:runtime"
import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:url"
import "wb:wasm"

////////////////////////////////
// timers: see bindings_timers.odin

////////////////////////////////
// net

@(private)
fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	f := (^Fetch)(user)
	p := f.page
	if f.ext != nil { fetch_ext_event(f, ev); return }   // promise / stream / abort signal (bindings_fetch.odin)
	switch ev.kind {
	case .Response:
		fetch_note_response(f, ev.response)
	case .Data:
		if !f.usable { return }   // opaque: scripts never see the bytes
		if p.held + len(ev.data) > p.settings.max_fetch_bytes {
			f.state, f.error, f.error_kind = 3, strings.clone("page fetch memory limit reached"), .Body_Too_Large
			if f.task != base.NIL_HANDLE { fetch.cancel(p.loader, f.task); f.task = base.NIL_HANDLE }
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

@(private)
fetch_note_response :: proc(f: ^Fetch, r: ^fetch.Response) {
	f.state, f.status, f.type, f.redirected, f.usable = 1, r.status, r.type, r.redirected, r.body_usable
	f.final_url = strings.clone(r.url)
	sb := strings.builder_make(context.temp_allocator)
	for h in r.headers.list { strings.write_string(&sb, h.name); strings.write_string(&sb, ": "); strings.write_string(&sb, h.value); strings.write_string(&sb, "\r\n") }
	f.headers = strings.clone(strings.to_string(sb))
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

n_Fetch_start :: proc "c" (env: wasm.Exec_Env, target: [^]u8, tl: i32, method: [^]u8, ml: i32, headers: [^]u8, hl: i32, body: [^]u8, bl: i32, options, callback, user: i32) -> u64 {
	context = ctx()
	return fetch_begin(page_of(env), inst_of(env).index, str(target, tl), str(method, ml), str(headers, hl), body[:max(bl, 0)], options, u32(callback), u32(user), nil)
}

// Starts a fetch for a guest. `ext` (promise, stream, abort signal) is owned by the record from here on.
@(private)
fetch_begin :: proc(p: ^Page, owner: u32, target, method, headers: string, body: []byte, options: i32, callback, user: u32, ext: ^Fetch_Ext) -> u64 {
	h, f := base.pool_insert(&p.fetches, Fetch{page = p, instance = owner, callback = callback, user = user, ext = ext})
	f.self = h
	if ext != nil && !fetch_ext_attach(p, f) { return u64(h) }   // its signal is already aborted: the failure is on its way

	// relative URLs resolve against the document
	abs := target
	if u, ok := url.parse(abs, &p.env.location, context.temp_allocator); ok { abs = u.href }

	pairs := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	parse_header_lines(headers, &pairs)

	o := u32(options)
	mode := fetch.Mode.Cors
	switch o & 3 { case 1: mode = .Same_Origin; case 2: mode = .No_Cors }
	creds := fetch.Credentials.Same_Origin
	switch (o >> 2) & 3 { case 1: creds = .Omit; case 2: creds = .Include }
	redirect := fetch.Redirect_Mode.Follow
	switch (o >> 4) & 3 { case 1: redirect = .Error; case 2: redirect = .Manual }
	policy := fetch.Referrer_Policy((o >> 6) & 0xF)
	if policy > .Unsafe_Url { policy = .Default }

	f.task = fetch.start(p.loader, {
		request = {
			url = abs, method = method, headers = pairs[:], body = body,
			mode = mode, credentials = creds, redirect = redirect, destination = .Empty,
			referrer_policy = policy, no_referrer = o & (1 << 10) != 0,
			initiator = &p.env, guard = .Request,
		},
		on_event = fetch_event, user = f, scope = p.scope, collect = false,
	})
	return u64(h)
}

@(private)
get_fetch :: proc "contextless" (env: wasm.Exec_Env, h: u64) -> ^Fetch {
	context = ctx()
	return base.pool_get(&page_of(env).fetches, H(h))
}

n_Fetch_state :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	if f := get_fetch(env, h); f != nil { return f.state }
	return -1
}
n_Fetch_status :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	if f := get_fetch(env, h); f != nil { return i32(f.status) }
	return -1
}
// 0 basic, 1 cors, 2 opaque, 3 opaque-redirect
n_Fetch_type :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	if f := get_fetch(env, h); f != nil { return i32(f.type) }
	return -1
}
n_Fetch_redirected :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	if f := get_fetch(env, h); f != nil { return f.redirected ? 1 : 0 }
	return -1
}
n_Fetch_headers :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	if f := get_fetch(env, h); f != nil { return out_string(f.headers, buf, cap) }
	return -1
}
n_Fetch_url :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	if f := get_fetch(env, h); f != nil { return out_string(f.final_url, buf, cap) }
	return -1
}
n_Fetch_error :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	if f := get_fetch(env, h); f != nil { return out_string(f.error, buf, cap) }
	return -1
}
n_Fetch_errorKind :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	if f := get_fetch(env, h); f != nil { return i32(f.error_kind) }
	return -1
}
n_Fetch_bodyLength :: proc "c" (env: wasm.Exec_Env, h: u64) -> u64 {
	if f := get_fetch(env, h); f != nil { return u64(len(f.body)) }
	return 0
}
// Copies up to `cap` bytes starting at `offset`; returns the number copied.
n_Fetch_readBody :: proc "c" (env: wasm.Exec_Env, h: u64, offset: u64, buf: [^]u8, cap: i32) -> i32 {
	f := get_fetch(env, h)
	if f == nil || offset >= u64(len(f.body)) { return 0 }
	n := min(int(max(cap, 0)), len(f.body) - int(offset))
	copy(buf[:n], f.body[offset:][:n])
	return i32(n)
}
n_Fetch_release :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	p := page_of(env)
	f, ok := base.pool_remove(&p.fetches, H(h))
	if !ok { return i32(dom.Error.Invalid_Handle) }
	if f.task != base.NIL_HANDLE { fetch.cancel(p.loader, f.task) }
	p.held -= len(f.body)
	free_fetch(&f)
	return 0
}

net_symbols := [?]wasm.Native_Symbol{
	{"Fetch_start", rawptr(n_Fetch_start), "(*~*~*~*~iii)I", nil},
	{"Fetch_state", rawptr(n_Fetch_state), "(I)i", nil},
	{"Fetch_status", rawptr(n_Fetch_status), "(I)i", nil},
	{"Fetch_type", rawptr(n_Fetch_type), "(I)i", nil},
	{"Fetch_redirected", rawptr(n_Fetch_redirected), "(I)i", nil},
	{"Fetch_headers", rawptr(n_Fetch_headers), "(I*~)i", nil},
	{"Fetch_url", rawptr(n_Fetch_url), "(I*~)i", nil},
	{"Fetch_error", rawptr(n_Fetch_error), "(I*~)i", nil},
	{"Fetch_errorKind", rawptr(n_Fetch_errorKind), "(I)i", nil},
	{"Fetch_bodyLength", rawptr(n_Fetch_bodyLength), "(I)I", nil},
	{"Fetch_readBody", rawptr(n_Fetch_readBody), "(II*~)i", nil},
	{"Fetch_release", rawptr(n_Fetch_release), "(I)i", nil},
}

////////////////////////////////
// document: location, origin, cookies

n_Document_URL :: proc "c" (env: wasm.Exec_Env, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	return out_string(page_of(env).env.location.href, buf, cap)
}

n_Window_origin :: proc "c" (env: wasm.Exec_Env, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	return out_string(url.origin_serialize(page_of(env).env.origin, context.temp_allocator), buf, cap)
}

n_Window_isSecureContext :: proc "c" (env: wasm.Exec_Env) -> i32 {
	context = ctx()
	return page_of(env).env.secure_context ? 1 : 0
}

// Cookies are only for documents with a tuple origin on http(s): opaque origins (file:, data:) get -1 (SecurityError).
@(private)
cookie_context :: proc(p: ^Page) -> (c: cookies.Context, ok: bool) {
	if p.env.origin.opaque || (p.env.location.scheme != "http" && p.env.location.scheme != "https") { return {}, false }
	return cookies.Context{url = p.env.location, site_context = .Same_Site, http_api = false, now_ms = fetch.now_ms()}, true
}

// document.cookie getter: the non-HttpOnly cookies of this document, "name=value; ...".
n_Document_cookie_get :: proc "c" (env: wasm.Exec_Env, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	c, ok := cookie_context(p)
	if !ok { return -1 }
	return out_string(cookies.header_for(&p.loader.profile.jar, c, context.temp_allocator), buf, cap)
}

// document.cookie setter: one cookie string. Returns 0 when applied, -1 for a SecurityError, or 1 + the cookies.Store_Result
// when the cookie was refused (so scripts can tell why).
n_Document_cookie_set :: proc "c" (env: wasm.Exec_Env, s: [^]u8, n: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	c, ok := cookie_context(p)
	if !ok { return -1 }
	r := cookies.store(&p.loader.profile.jar, str(s, n), c)
	#partial switch r {
	case .Stored, .Replaced, .Deleted: return 0
	}
	return 1 + i32(r)
}

document_symbols := [?]wasm.Native_Symbol{
	{"Document_URL", rawptr(n_Document_URL), "(*~)i", nil},
	{"Window_origin", rawptr(n_Window_origin), "(*~)i", nil},
	{"Window_isSecureContext", rawptr(n_Window_isSecureContext), "()i", nil},
	{"Document_cookie_get", rawptr(n_Document_cookie_get), "(*~)i", nil},
	{"Document_cookie_set", rawptr(n_Document_cookie_set), "(*~)i", nil},
}

_ :: runtime

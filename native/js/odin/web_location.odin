// web_location.odin: Location and History (HTML) on the page's session history, PopStateEvent, HashChangeEvent and
// PageTransitionEvent (pageshow / pagehide, persisted: the back/forward cache). window.location / document.location is
// one Location object per realm; its members are [LegacyUnforgeable]. Setting href (or assign / replace / a component)
// navigates. history.state is any value: pushState / replaceState store its structured serialization in the session
// history entry as text ("wjs1:" then base64), so history.state === history.state. Ported from
// native/js/runtime/web_location.c; same wjr_* symbols and behaviour.
package odin_glue

import "../odin/wj"

// web_location.c used libc malloc/free (not the engine's) for its state text and history impl; web_strndup returns
// libc memory freed with libc free. Keep the same allocator here so frees pair the way the C's did.
@(private = "file") _malloc :: #force_inline proc "contextless" (n: uint) -> rawptr { return wj.libc_malloc(n) }
@(private = "file") _free   :: #force_inline proc "contextless" (p: rawptr) { wj.libc_free(p) }
@(private = "file") empty_byte: u8
@(private = "file") raw_empty :: #force_inline proc "contextless" () -> [^]u8 { return &empty_byte }





// enum wj.wr_URLComponent
URL_Href :: i32(0); URL_Protocol :: i32(1); URL_Host :: i32(4); URL_Hostname :: i32(5)
URL_Port :: i32(6); URL_Pathname :: i32(7); URL_Search :: i32(8); URL_Hash :: i32(9); URL_Origin :: i32(10)
// enum wj.wr_ScrollRestoration
SCROLL_AUTO :: i32(0); SCROLL_MANUAL :: i32(1)
// enum wj.wr_Error (the subset used here). File-private: the odin_glue package is shared, and other domains name their
// own error subsets (web_storage.odin's ERR_NOT_FOUND, ...).
@(private = "file") ERR_NOT_FOUND :: i32(-3)
@(private = "file") ERR_SECURITY :: i32(-12)
@(private = "file") ERR_SYNTAX :: i32(-15)
@(private = "file") ERR_DATA_CLONE :: i32(-19)

@(private = "file") iface_location := i32(-2)
@(private = "file") iface_document := i32(-2)
@(private = "file") iface_domstringlist := i32(-2)
@(private = "file") iface_history := i32(-2)
@(private = "file") iface_pagetransition := i32(-2)
@(private = "file") iface_popstate := i32(-2)
@(private = "file") iface_hashchange := i32(-2)

@(private = "file") resolve :: proc "c" (cache: ^i32, name: cstring) -> i32 {
	if cache^ == -2 { cache^ = wj.iface(name) }
	return cache^
}
@(private = "file") location_iface      :: proc "c" () -> i32 { return resolve(&iface_location, "Location") }
@(private = "file") document_iface      :: proc "c" () -> i32 { return resolve(&iface_document, "Document") }
@(private = "file") domstringlist_iface :: proc "c" () -> i32 { return resolve(&iface_domstringlist, "DOMStringList") }
@(private = "file") history_iface       :: proc "c" () -> i32 { return resolve(&iface_history, "History") }
@(private = "file") pagetransition_iface :: proc "c" () -> i32 { return resolve(&iface_pagetransition, "PageTransitionEvent") }
@(private = "file") popstate_iface      :: proc "c" () -> i32 { return resolve(&iface_popstate, "PopStateEvent") }
@(private = "file") hashchange_iface    :: proc "c" () -> i32 { return resolve(&iface_hashchange, "HashChangeEvent") }

// ---- Location ----

@(private = "file") make_location :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.wj_new_object(ctx, location_iface(), nil, nil)
}

@(export, link_name = "wjr_Window_get_location")
wjr_Window_get_location :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_LOCATION, make_location)
}

// wjr_Document_get_location is __attribute__((weak)) in web_location.c: the DOM glue (dom_core) defines the strong one
// (the same object either way), so it is NOT exported here — a strong Odin export would collide with dom_core's. The
// setter below is only in this file, so it stays.
@(export, link_name = "wjr_Document_set_location")
wjr_Document_set_location :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, document_iface()) == nil { return wj.EXCEPTION }
	loc := wj.web_singleton(ctx, wj.SINGLE_LOCATION, make_location)
	if wj.is_exception(loc) { return loc }
	r := wj.JS_SetPropertyStr(ctx, loc, "href", wj.JS_DupValue(ctx, v))
	wj.JS_FreeValue(ctx, loc)
	return r < 0 ? wj.EXCEPTION : wj.UNDEFINED
}

// The component getter fetches the component's string with an explicit grow-and-refetch against the scratch buffer
// (fetch_string's closure form cannot carry the `component` argument: a "c" proc has no captures).
@(private = "file") location_component :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: i32) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, location_iface()) == nil { return wj.EXCEPTION }
	n := wj.wr_Location_get(component, wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() {
		if !wj.wj_scratch_grow(u32(n)) { return wj.JS_ThrowOutOfMemory(ctx) }
		n = wj.wr_Location_get(component, wj.scratch_data(), wj.scratch_cap())
	}
	return wj.scratch_string(ctx, n)
}

@(private = "file") location_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: i32, v: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, location_iface()) == nil { return wj.EXCEPTION }
	s: wj.Str
	if !wj.web_to_usv(ctx, v, &s) { return wj.EXCEPTION }
	st := wj.wr_Location_set(component, s.ptr, u32(s.len))
	wj.wj_str_free(ctx, &s)
	if st < 0 {
		if st == ERR_SYNTAX { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to set a property on 'Location': the URL is invalid.") }
		return wj.wj_throw_status(ctx, st, "Location")
	}
	return wj.UNDEFINED
}

// The eight read/write components. A small table keeps one getter/setter pair per component without the C macro.
@(private = "file") LOCATION_COMPONENT :: struct { get, set: wj.Native, comp: i32 }

@(export, link_name = "wjr_Location_get_href")     wjr_Location_get_href     :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Href) }
@(export, link_name = "wjr_Location_set_href")     wjr_Location_set_href     :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Href, v) }
@(export, link_name = "wjr_Location_get_protocol") wjr_Location_get_protocol :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Protocol) }
@(export, link_name = "wjr_Location_set_protocol") wjr_Location_set_protocol :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Protocol, v) }
@(export, link_name = "wjr_Location_get_host")     wjr_Location_get_host     :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Host) }
@(export, link_name = "wjr_Location_set_host")     wjr_Location_set_host     :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Host, v) }
@(export, link_name = "wjr_Location_get_hostname") wjr_Location_get_hostname :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Hostname) }
@(export, link_name = "wjr_Location_set_hostname") wjr_Location_set_hostname :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Hostname, v) }
@(export, link_name = "wjr_Location_get_port")     wjr_Location_get_port     :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Port) }
@(export, link_name = "wjr_Location_set_port")     wjr_Location_set_port     :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Port, v) }
@(export, link_name = "wjr_Location_get_pathname") wjr_Location_get_pathname :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Pathname) }
@(export, link_name = "wjr_Location_set_pathname") wjr_Location_set_pathname :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Pathname, v) }
@(export, link_name = "wjr_Location_get_search")   wjr_Location_get_search   :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Search) }
@(export, link_name = "wjr_Location_set_search")   wjr_Location_set_search   :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Search, v) }
@(export, link_name = "wjr_Location_get_hash")     wjr_Location_get_hash     :: proc "c" (c: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return location_component(c, t, URL_Hash) }
@(export, link_name = "wjr_Location_set_hash")     wjr_Location_set_hash     :: proc "c" (c: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return location_set(c, t, URL_Hash, v) }

@(export, link_name = "wjr_Location_get_origin")
wjr_Location_get_origin :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return location_component(ctx, this_val, URL_Origin) }

// location.ancestorOrigins: a document without frames has no ancestors (an empty DOMStringList, the same object)
@(private = "file") ancestor_origins := wj.UNDEFINED

@(export, link_name = "wjr_Location_get_ancestorOrigins")
wjr_Location_get_ancestorOrigins :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, location_iface()) == nil { return wj.EXCEPTION }
	if wj.is_undefined(ancestor_origins) {
		ancestor_origins = wj.wj_new_object(ctx, domstringlist_iface(), nil, nil)
		if wj.is_exception(ancestor_origins) { ancestor_origins = wj.UNDEFINED; return wj.EXCEPTION }
	}
	return wj.JS_DupValue(ctx, ancestor_origins)
}

// DOMStringList: the lists this browser makes are empty
@(export, link_name = "wjr_DOMStringList_get_length")
wjr_DOMStringList_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.wj_this(ctx, this_val, domstringlist_iface()) != nil ? wj.new_int32(0) : wj.EXCEPTION }
@(export, link_name = "wjr_DOMStringList_item")
wjr_DOMStringList_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.wj_this(ctx, this_val, domstringlist_iface()) != nil ? wj.NULL : wj.EXCEPTION }
@(export, link_name = "wjr_DOMStringList_contains")
wjr_DOMStringList_contains :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.wj_this(ctx, this_val, domstringlist_iface()) != nil ? wj.FALSE : wj.EXCEPTION }
@(export, link_name = "wjr_DOMStringList_index_get")
wjr_DOMStringList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue { found^ = false; return wj.UNDEFINED }
@(export, link_name = "wjr_DOMStringList_length_hook")
wjr_DOMStringList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return 0 }

@(private = "file") location_go :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, replace: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, location_iface()) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, replace ? "Location.replace" : "Location.assign", 1, argc) }
	s: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &s) { return wj.EXCEPTION }
	st := replace ? wj.wr_Location_replace(s.ptr, u32(s.len)) : wj.wr_Location_assign(s.ptr, u32(s.len))
	wj.wj_str_free(ctx, &s)
	if st < 0 {
		if st == ERR_SYNTAX { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute on 'Location': the URL is invalid.") }
		return wj.wj_throw_status(ctx, st, "Location")
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Location_assign")
wjr_Location_assign :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return location_go(ctx, this_val, argc, argv, false) }
@(export, link_name = "wjr_Location_replace")
wjr_Location_replace :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return location_go(ctx, this_val, argc, argv, true) }

@(export, link_name = "wjr_Location_reload")
wjr_Location_reload :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, location_iface()) == nil { return wj.EXCEPTION }
	wj.wr_Location_reload()
	return wj.UNDEFINED
}

// ---- states as text ----

@(private = "file") STATE_PREFIX :: "wjs1:"
@(private = "file") B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// the serialized state as text (malloc'ed, NUL-terminated); nil with a DataCloneError pending
@(private = "file") state_encode :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out_len: ^uint) -> [^]u8 {
	n: uint
	p := web_clone_serialize(ctx, v, &n)
	if p == nil { return nil }
	defer web_clone_free(ctx, p)
	prefix := transmute([]u8)string(STATE_PREFIX)
	pl := uint(len(prefix))
	s := ([^]u8)(_malloc(pl + (n + 2) / 3 * 4 + 1))
	if s == nil { wj.JS_ThrowOutOfMemory(ctx); return nil }
	for i in 0 ..< pl { s[i] = prefix[i] }
	w := pl
	b64 := transmute([]u8)B64
	for i := uint(0); i < n; i += 3 {
		x := u32(p[i]) << 16 | (i + 1 < n ? u32(p[i + 1]) << 8 : 0) | (i + 2 < n ? u32(p[i + 2]) : 0)
		s[w] = b64[x >> 18]; w += 1
		s[w] = b64[(x >> 12) & 63]; w += 1
		s[w] = i + 1 < n ? b64[(x >> 6) & 63] : '='; w += 1
		s[w] = i + 2 < n ? b64[x & 63] : '='; w += 1
	}
	s[w] = 0
	out_len^ = w
	return s
}

@(private = "file") b64v :: proc "contextless" (c: u8) -> i32 {
	switch {
	case c >= 'A' && c <= 'Z': return i32(c - 'A')
	case c >= 'a' && c <= 'z': return i32(c - 'a') + 26
	case c >= '0' && c <= '9': return i32(c - '0') + 52
	case c == '+': return 62
	case c == '/': return 63
	}
	return -1
}

// the value of a stored state: deserialized when it is ours, the text itself otherwise
@(private = "file") state_decode :: proc "c" (ctx: ^wj.Context, s: [^]u8, n: uint) -> wj.JSValue {
	pl := uint(len(STATE_PREFIX))
	if n < pl || string(s[:pl]) != STATE_PREFIX { return wj.JS_NewStringLen(ctx, s, n) }
	body := s[pl:]
	bn := n - pl
	p := ([^]u8)(_malloc(bn / 4 * 3 + 3))
	if p == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer _free(p)
	w := uint(0)
	acc := u32(0)
	bits := 0
	for i := uint(0); i < bn; i += 1 {
		v := b64v(body[i])
		if v < 0 { continue }
		acc = (acc << 6) | u32(v)
		bits += 6
		if bits >= 8 { bits -= 8; p[w] = u8(acc >> u32(bits)); w += 1 }
	}
	return web_clone_deserialize(ctx, p, w)
}

@(export, link_name = "web_state_encode")
web_state_encode :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out_len: ^uint) -> [^]u8 { return state_encode(ctx, v, out_len) }
@(export, link_name = "web_state_decode")
web_state_decode :: proc "c" (ctx: ^wj.Context, s: [^]u8, n: uint) -> wj.JSValue { return state_decode(ctx, s, n) }

// ---- History ----

@(private = "file")
History_Impl :: struct {
	state:    wj.JSValue,   // the deserialized history.state, for `text`
	text:     [^]u8,        // the browser's state it was made from (nil: null state)
	text_len: uint,
	known:    bool,
}

@(private = "file") history_free :: proc "c" (p: rawptr) {
	h := (^History_Impl)(p)
	wj.JS_FreeValueRT(wj.web_rt(), h.state)
	_free(h.text)
	_free(p)
}
@(private = "file") history_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^History_Impl)(p).state, mark_func) }

@(private = "file") make_history :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	h := (^History_Impl)(wj.libc_calloc(1, size_of(History_Impl)))
	if h == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	h.state = wj.NULL
	obj := wj.wj_new_object(ctx, history_iface(), nil, nil)
	if wj.is_exception(obj) { _free(h); return obj }
	wj.web_set_impl(obj, h, history_free, history_mark)
	return obj
}

@(export, link_name = "wjr_Window_get_history")
wjr_Window_get_history :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_HISTORY, make_history)
}

@(private = "file") history_this :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^History_Impl {
	return (^History_Impl)(wj.web_this_impl(ctx, this_val, history_iface()))
}

@(export, link_name = "wjr_History_get_state")
wjr_History_get_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h := history_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	n := wj.wr_History_state(wj.scratch_data(), wj.scratch_cap())
	if n > 0 && u32(n) > wj.scratch_cap() {
		if !wj.wj_scratch_grow(u32(n)) { return wj.JS_ThrowOutOfMemory(ctx) }
		n = wj.wr_History_state(wj.scratch_data(), wj.scratch_cap())
	}
	null_state := n == ERR_NOT_FOUND
	if n < 0 && !null_state { return wj.wj_throw_status(ctx, n, "History.state") }
	// the same value while the entry's state stays the same
	if h.known && ((null_state && h.text == nil) || (!null_state && h.text != nil && h.text_len == uint(n) && wj.memcmp(h.text, wj.scratch_data(), uint(n)) == 0)) {
		return wj.JS_DupValue(ctx, h.state)
	}
	_free(h.text); h.text = nil; h.text_len = 0
	wj.JS_FreeValue(ctx, h.state)
	h.state = wj.NULL
	if !null_state {
		h.text = wj.web_strndup(wj.scratch_data(), uint(n))
		h.text_len = uint(n)
		h.state = state_decode(ctx, h.text != nil ? h.text : raw_empty(), h.text != nil ? uint(n) : 0)
		if wj.is_exception(h.state) { h.state = wj.NULL; h.known = false; return wj.EXCEPTION }
	}
	h.known = true
	return wj.JS_DupValue(ctx, h.state)
}

@(private = "file") history_change :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, replace: bool) -> wj.JSValue {
	h := history_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, replace ? "History.replaceState" : "History.pushState", 2, argc) }
	sl: uint
	s := state_encode(ctx, argv[0], &sl)
	if s == nil { return wj.EXCEPTION }
	urlv := wj.arg(argc, argv, 2)
	u := wj.Str{}
	if !wj.is_undefined(urlv) && !wj.is_null(urlv) && !wj.web_to_usv(ctx, urlv, &u) { _free(s); return wj.EXCEPTION }
	ulen := u.ptr != nil ? u32(u.len) : wj.WR_ABSENT
	st := replace ? wj.wr_History_replaceState(s, u32(sl), u.ptr, ulen) : wj.wr_History_pushState(s, u32(sl), u.ptr, ulen)
	wj.wj_str_free(ctx, &u)
	if st < 0 {
		_free(s)
		switch st {
		case ERR_SYNTAX:     return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute on 'History': the URL is invalid.")
		case ERR_SECURITY:   return wj.wj_throw_dom(ctx, "SecurityError", "Failed to execute on 'History': the document's URL cannot be rewritten to this one.")
		case ERR_DATA_CLONE: return wj.wj_throw_dom(ctx, "DataCloneError", "Failed to execute on 'History': the state is over history.max_state_bytes.")
		}
		return wj.wj_throw_status(ctx, st, "History")
	}
	// the state is the deserialized copy (a structured clone, not the object given)
	_free(h.text)
	h.text = s
	h.text_len = sl
	wj.JS_FreeValue(ctx, h.state)
	h.state = state_decode(ctx, s, sl)
	if wj.is_exception(h.state) { h.state = wj.NULL; h.known = false; return wj.EXCEPTION }
	h.known = true
	return wj.UNDEFINED
}

@(export, link_name = "wjr_History_pushState")
wjr_History_pushState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return history_change(ctx, this_val, argc, argv, false) }
@(export, link_name = "wjr_History_replaceState")
wjr_History_replaceState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return history_change(ctx, this_val, argc, argv, true) }

@(export, link_name = "wjr_History_back")
wjr_History_back :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if history_this(ctx, this_val) == nil { return wj.EXCEPTION }
	wj.wr_History_go(-1)
	return wj.UNDEFINED
}
@(export, link_name = "wjr_History_forward")
wjr_History_forward :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if history_this(ctx, this_val) == nil { return wj.EXCEPTION }
	wj.wr_History_go(1)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_History_get_scrollRestoration")
wjr_History_get_scrollRestoration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if history_this(ctx, this_val) == nil { return wj.EXCEPTION }
	return wj.JS_NewString(ctx, wj.wr_History_scrollRestoration() == SCROLL_MANUAL ? "manual" : "auto")
}

@(export, link_name = "wjr_History_set_scrollRestoration")
wjr_History_set_scrollRestoration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if history_this(ctx, this_val) == nil { return wj.EXCEPTION }
	s := wj.to_cstring(ctx, v)
	if s == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, s)
	// an enum attribute: other values are ignored
	switch string(s) {
	case "manual": wj.wr_History_set_scrollRestoration(SCROLL_MANUAL)
	case "auto":   wj.wr_History_set_scrollRestoration(SCROLL_AUTO)
	}
	return wj.UNDEFINED
}

// ---- PageTransitionEvent ----


@(export, link_name = "wjr_PageTransitionEvent_get_persisted")
wjr_PageTransitionEvent_get_persisted :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, pagetransition_iface()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "persisted")
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	// the browser's pageshow / pagehide: Event_code 1 when the document comes from (or goes into) the bf-cache
	return wj.new_bool(h != 0 && wj.wr_Event_code(h) != 0)
}

@(export, link_name = "wjr_PageTransitionEvent_constructor")
wjr_PageTransitionEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, new_target, argc, argv, pagetransition_iface(), "PageTransitionEvent")
	if wj.is_exception(ev) { return ev }
	init := wjd_PageTransitionEventInit{}
	if !wjd_PageTransitionEventInit_from(ctx, wj.arg(argc, argv, 1), &init) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	wj.web_extra_set(ctx, ev, "persisted", wj.new_bool(init.persisted))
	wjd_PageTransitionEventInit_free(ctx, &init)
	return ev
}

// ---- PopStateEvent, HashChangeEvent ----

@(export, link_name = "wjr_PopStateEvent_get_state")
wjr_PopStateEvent_get_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, popstate_iface()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "state")
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 { return wj.NULL }
	// the browser's popstate: the entry's state as text (Event_code 0 for a null state)
	st := wj.NULL
	if wj.wr_Event_code(h) != 0 {
		n := wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap())
		if n > 0 && u32(n) > wj.scratch_cap() {
			if !wj.wj_scratch_grow(u32(n)) { return wj.JS_ThrowOutOfMemory(ctx) }
			n = wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap())
		}
		text := wj.web_strndup(wj.scratch_data(), uint(n > 0 ? n : 0))
		if text == nil { return wj.JS_ThrowOutOfMemory(ctx) }
		st = state_decode(ctx, text, uint(n > 0 ? n : 0))
		_free(text)
		if wj.is_exception(st) { return st }
	}
	wj.web_extra_set(ctx, this_val, "state", wj.JS_DupValue(ctx, st))
	return st
}

@(export, link_name = "wjr_PopStateEvent_get_hasUAVisualTransition")
wjr_PopStateEvent_get_hasUAVisualTransition :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, popstate_iface()) != nil ? wj.FALSE : wj.EXCEPTION
}

@(export, link_name = "wjr_PopStateEvent_constructor")
wjr_PopStateEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, new_target, argc, argv, popstate_iface(), "PopStateEvent")
	if wj.is_exception(ev) { return ev }
	st: wj.JSValue
	if !wj.web_dict_get(ctx, wj.arg(argc, argv, 1), "state", &st) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	wj.web_extra_set(ctx, ev, "state", wj.is_undefined(st) ? wj.NULL : st)
	return ev
}

@(private = "file") hash_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, old: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, hashchange_iface()) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 { return wj.JS_NewString(ctx, "") }
	// the browser's hashchange: the new URL in Event_data, the old one in Event_text
	n: i32
	if old {
		n = wj.wr_Event_text(h, wj.scratch_data(), wj.scratch_cap())
		if n > 0 && u32(n) > wj.scratch_cap() { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_Event_text(h, wj.scratch_data(), wj.scratch_cap()) } }
	} else {
		n = wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap())
		if n > 0 && u32(n) > wj.scratch_cap() { if wj.wj_scratch_grow(u32(n)) { n = wj.wr_Event_data(h, wj.scratch_data(), wj.scratch_cap()) } }
	}
	v = wj.scratch_string(ctx, n)
	wj.web_extra_set(ctx, this_val, name, wj.JS_DupValue(ctx, v))
	return v
}

@(export, link_name = "wjr_HashChangeEvent_get_oldURL")
wjr_HashChangeEvent_get_oldURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return hash_field(ctx, this_val, "oldURL", true) }
@(export, link_name = "wjr_HashChangeEvent_get_newURL")
wjr_HashChangeEvent_get_newURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return hash_field(ctx, this_val, "newURL", false) }

@(export, link_name = "wjr_HashChangeEvent_constructor")
wjr_HashChangeEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj_event_construct(ctx, new_target, argc, argv, hashchange_iface(), "HashChangeEvent")
	if wj.is_exception(ev) { return ev }
	names := [2]cstring{ "oldURL", "newURL" }
	for i in 0 ..< 2 {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, wj.arg(argc, argv, 1), names[i], &v) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
		s := wj.is_undefined(v) ? wj.JS_NewString(ctx, "") : wj.JS_ToString(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(s) { wj.JS_FreeValue(ctx, ev); return s }
		wj.web_extra_set(ctx, ev, names[i], s)
	}
	return ev
}

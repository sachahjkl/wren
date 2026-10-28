// web_navigation.odin: the Navigation API (HTML) for JavaScript (module navigation, src/page/navigation.odin). Ported
// from native/js/runtime/web_navigation.c: same wjr_* symbols and exports (wj_nav_fire, wj_nav_commit).
//
// The browser keeps the session history, the state of each entry and every navigation; before it commits one it calls
// wj_nav_fire, which reads the navigation (Navigation_pending) and fires `navigate` at window.navigation; after a
// same-document commit it calls wj_nav_commit: currententrychange, the handlers given to intercept(), then
// navigatesuccess / navigateerror when their promises settle. Here are the JavaScript objects: the Navigation
// singleton, one NavigationHistoryEntry per entry (the same object while the entry lives: identity is kept by
// key + id), the NavigateEvent and its NavigationDestination, navigation.transition, and the promises of navigate(),
// reload() and traverseTo() ("navigation API method trackers").
//
// One navigation is "ongoing" at a time: the next one aborts it (its signal aborts, navigateerror, its promises
// reject). States are the structured serialization as text (web_state_encode), as history.state's.
//
// Every call into the browser is a declaration of api_decl/navigation.odin through jsb.host.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") none: abi.Nothing

@(private = "file") Nav_Type :: enum { Push, Replace, Reload, Traverse }
@(private = "file") NAV_TYPES := [Nav_Type]cstring{.Push = "push", .Replace = "replace", .Reload = "reload", .Traverse = "traverse"}
// The same, NULL-terminated, for the enum checks of Web IDL.
@(private = "file") NAV_TYPES_Z := [5]cstring{"push", "replace", "reload", "traverse", nil}

// What the browser says about a navigation (Navigation_pending's flags).
@(private = "file") Nav_Flag :: enum { Same_Doc, User, Hash, Can_Intercept, Cancelable, Has_State }
@(private = "file") Nav_Flags :: bit_set[Nav_Flag; u32]

// A cursor over the browser's text: the numbers are read as strtoll did (leading white space skipped).
@(private = "file")
Scan :: struct {
	text: string,
	at:   int,
}

@(private = "file")
scan_int :: proc "contextless" (s: ^Scan) -> i64 {
	for s.at < len(s.text) && (s.text[s.at] == ' ' || (s.text[s.at] >= '\t' && s.text[s.at] <= '\r')) { s.at += 1 }
	neg := false
	if s.at < len(s.text) && (s.text[s.at] == '-' || s.text[s.at] == '+') { neg = s.text[s.at] == '-'; s.at += 1 }
	v: i64
	for s.at < len(s.text) && s.text[s.at] >= '0' && s.text[s.at] <= '9' {
		v = v * 10 + i64(s.text[s.at] - '0')
		s.at += 1
	}
	return neg ? -v : v
}

// ---- entries ----

@(private = "file")
Entry :: struct {
	key, id:  i64,
	index:    i64,   // in navigation.entries(), -1 once the entry is gone
	same_doc: bool,
	url:      wj.JSValue,
}

@(private = "file")
entry_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Entry)(p).url)
	wj.libc_free(p)
}
@(private = "file")
entry_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Entry)(p).url, mark_func) }

@(private = "file") nav_obj := wj.UNDEFINED                // window.navigation (counted, made on first use)
@(private = "file") entries: [dynamic]wj.JSValue           // the wrappers of navigation.entries(), in order (counted)
@(private = "file") current := i64(-1)                     // index of the current entry in `entries`
@(private = "file") synced_serial := i64(-1)
@(private = "file") transition := wj.UNDEFINED             // navigation.transition (counted), undefined: null

@(private = "file")
entry_of :: proc "contextless" (v: wj.JSValue) -> ^Entry {
	o := wj.wj_unwrap(v, ifc("NavigationHistoryEntry"))
	return o != nil && o.impl_free == entry_free ? (^Entry)(o.impl) : nil
}

@(private = "file")
find_cached :: proc "contextless" (key, id: i64) -> wj.JSValue {
	for w in entries {
		if e := entry_of(w); e != nil && e.key == key && e.id == id { return w }
	}
	return wj.UNDEFINED
}

// Reads the entries again when the session history changed: an entry still there keeps its wrapper; those gone get
// index -1 and their dispose event.
@(private = "file")
nav_sync :: proc(ctx: ^wj.Context) {
	serial: i64
	jsb.host(&serial, api_decl.Navigation_serial, wj.wr_Navigation_serial)
	if serial == synced_serial { return }
	listing: string
	jsb.host(&listing, api_decl.Navigation_entries, wj.wr_Navigation_entries)
	text := clone_text(listing)   // the scratch buffer is reused by every host call below
	defer delete(text, wj.libc_allocator())
	synced_serial = serial
	next: [dynamic]wj.JSValue
	s := Scan{text = text}
	cur := scan_int(&s)
	for s.at < len(text) && text[s.at] == '\n' { s.at += 1 }
	for s.at < len(text) {
		line_end := s.at
		for line_end < len(text) && text[line_end] != '\n' { line_end += 1 }
		key := scan_int(&s)
		id := scan_int(&s)
		same := scan_int(&s)
		if s.at < len(text) && text[s.at] == ' ' { s.at += 1 }
		url := s.at <= line_end ? text[s.at:line_end] : ""
		w := find_cached(key, id)
		if wj.is_undefined(w) {
			e := (^Entry)(wj.libc_calloc(1, size_of(Entry)))
			if e == nil { break }
			e.key, e.id = key, id
			e.url = wj.new_string_len(ctx, url)
			w = wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("NavigationHistoryEntry"), wj.UNDEFINED)
			if wj.is_exception(w) { entry_free(e); wj.wj_report_pending(ctx); break }
			wj.web_set_impl(w, e, entry_free, entry_mark)
		} else {
			w = wj.JS_DupValue(ctx, w)
		}
		e := entry_of(w)
		e.index = i64(len(next))
		e.same_doc = same != 0
		if append(&next, w) != 1 { wj.JS_FreeValue(ctx, w); break }
		s.at = line_end < len(text) ? line_end + 1 : line_end
	}
	// the wrappers no longer listed: gone from the history (dispose), after the list changed
	old := entries
	entries = next
	current = cur >= 0 && cur < i64(len(next)) ? cur : -1
	for w in old {
		kept := false
		for k in next { if wj.same_ptr(k, w) { kept = true; break } }
		if !kept {
			if e := entry_of(w); e != nil { e.index = -1 }
			wj.web_fire_simple(ctx, w, "dispose")
		}
		wj.JS_FreeValue(ctx, w)
	}
	delete(old)
}

// A copy of a host string on the libc heap.
@(private = "file")
clone_text :: proc(s: string) -> string {
	b := make([]u8, len(s), wj.libc_allocator())
	copy(b, s)
	return string(b)
}

// The current entry's wrapper (counted) or null.
@(private = "file")
current_entry :: proc(ctx: ^wj.Context) -> wj.JSValue {
	nav_sync(ctx)
	return current >= 0 ? wj.JS_DupValue(ctx, entries[current]) : wj.NULL
}

// The value of a state the browser handed over (undefined for none).
@(private = "file")
state_value :: proc(ctx: ^wj.Context, text: string, st: abi.Api_Error) -> wj.JSValue {
	if st == .Not_Found { return wj.UNDEFINED }
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "getState") }
	copy := wj.web_strndup(raw_data(text), uint(len(text)))   // the scratch buffer may move while decoding
	if copy == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(copy)
	return web_state_decode(ctx, copy, uint(len(text)))
}

// ---- trackers: the promises of navigate() / reload() / traverseTo() ----

@(private = "file")
Tracker :: struct {
	info:      wj.JSValue,
	committed: Prom,
	finished:  Prom,
	key:       i64,         // traverseTo(): the destination's key; 0 otherwise
	next:      ^Tracker,
}

@(private = "file") upcoming: ^Tracker     // the one the next navigate event takes (navigate(), reload())
@(private = "file") traversals: ^Tracker   // traverseTo() calls waiting for their traversal

@(private = "file")
tracker_new :: proc(ctx: ^wj.Context, info: wj.JSValue) -> ^Tracker {
	t := new(Tracker)
	if t == nil { return nil }
	t.info = wj.JS_DupValue(ctx, info)
	t.committed, t.finished = PROM_NONE, PROM_NONE
	prom_new(ctx, &t.committed)
	prom_new(ctx, &t.finished)
	mark_handled(ctx, t.committed.p)   // [[PromiseIsHandled]]: a rejection nobody waits for is not reported
	mark_handled(ctx, t.finished.p)
	return t
}

@(private = "file")
tracker_free :: proc(ctx: ^wj.Context, t: ^Tracker) {
	if t == nil { return }
	wj.JS_FreeValue(ctx, t.info)
	prom_clear(ctx, &t.committed)
	prom_clear(ctx, &t.finished)
	free(t)
}

// {committed, finished}
@(private = "file")
tracker_result :: proc "contextless" (ctx: ^wj.Context, t: ^Tracker) -> wj.JSValue {
	r := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, r, "committed", wj.JS_DupValue(ctx, t.committed.p), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, r, "finished", wj.JS_DupValue(ctx, t.finished.p), wj.PROP_C_W_E)
	return r
}

// Web IDL "early error result": both promises rejected with the pending exception.
@(private = "file")
early_error :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	e := wj.JS_GetException(ctx)
	r := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, r, "committed", wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, e)), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, r, "finished", wj.web_promise_rejected(ctx, e), wj.PROP_C_W_E)
	return r
}

@(private = "file")
early_dom_error :: proc "contextless" (ctx: ^wj.Context, name, message: cstring) -> wj.JSValue {
	wj.wj_throw_dom(ctx, name, message)
	return early_error(ctx)
}

// ---- the ongoing navigation ----

@(private = "file")
Ongoing :: struct {
	serial:                                                   u32,
	pending:                                                  u32,   // handler promises (plus one) not fulfilled yet
	type:                                                     Nav_Type,
	flags:                                                    Nav_Flags,
	firing, intercepted, aborted, committed, scrolled:        bool,
	focus_manual, scroll_manual:                              bool,
	event, destination, controller, from, handlers, focus_before: wj.JSValue,
	tracker:                                                  ^Tracker,
}

@(private = "file") ongoing: ^Ongoing
@(private = "file") ongoing_serial: u32

@(private = "file")
ongoing_free :: proc(ctx: ^wj.Context, n: ^Ongoing) {
	wj.free_values(ctx, n.event, n.destination, n.controller, n.from, n.handlers, n.focus_before)
	tracker_free(ctx, n.tracker)
	free(n)
}

@(private = "file")
set_transition :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) {
	wj.JS_FreeValue(ctx, transition)
	transition = t
}

@(private = "file")
Transition :: struct {
	type:     Nav_Type,
	from, to: wj.JSValue,
	committed: wj.JSValue,
	finished:  Prom,
}

@(private = "file")
transition_free :: proc "c" (p: rawptr) {
	t := (^Transition)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, t.from)
	wj.JS_FreeValueRT(rt, t.to)
	wj.JS_FreeValueRT(rt, t.committed)
	prom_free_rt(rt, &t.finished)
	wj.libc_free(t)
}

@(private = "file")
transition_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	t := (^Transition)(p)
	wj.wj_mark(rt, t.from, mark_func)
	wj.wj_mark(rt, t.to, mark_func)
	wj.wj_mark(rt, t.committed, mark_func)
	prom_mark(rt, &t.finished, mark_func)
}

@(private = "file")
transition_of :: proc "contextless" (v: wj.JSValue) -> ^Transition {
	o := wj.wj_unwrap(v, ifc("NavigationTransition"))
	return o != nil && o.impl_free == transition_free ? (^Transition)(o.impl) : nil
}

// navigation.transition.finished settles and the transition is over.
@(private = "file")
transition_end :: proc "contextless" (ctx: ^wj.Context, ok: bool, error: wj.JSValue) {
	if t := transition_of(transition); t != nil {
		if ok { prom_resolve(ctx, &t.finished, wj.UNDEFINED) } else { prom_reject(ctx, &t.finished, error) }
	}
	set_transition(ctx, wj.UNDEFINED)
}

@(private = "file")
fire_navigateerror :: proc(ctx: ^wj.Context, error: wj.JSValue) {
	if wj.is_undefined(nav_obj) { return }
	ev := wj_error_event_for(ctx, "navigateerror", error)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_event_fire(ctx, nav_obj, ev)
	wj.JS_FreeValue(ctx, ev)
}

// HTML "abort the ongoing navigation": the event is cancelled if it is still being fired, its signal aborts,
// navigateerror, the promises reject. `n` is freed unless it is being fired (its firing frees it). Takes `error`.
@(private = "file")
nav_abort :: proc(ctx: ^wj.Context, n: ^Ongoing, error: wj.JSValue) {
	n.aborted = true
	if ongoing == n { ongoing = nil }
	if n.firing {
		pd := wj.JS_GetPropertyStr(ctx, n.event, "preventDefault")
		if wj.JS_IsFunction(ctx, pd) { wj.JS_FreeValue(ctx, wj.JS_Call(ctx, pd, n.event, 0, nil)) }
		wj.JS_FreeValue(ctx, pd)
	}
	if wj.is_object(n.controller) {
		arg := error
		r := wjr_AbortController_abort(ctx, n.controller, 1, &arg)
		if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
	}
	fire_navigateerror(ctx, error)
	if n.tracker != nil {
		prom_reject(ctx, &n.tracker.committed, error)
		prom_reject(ctx, &n.tracker.finished, error)
	}
	if n.intercepted && n.committed { transition_end(ctx, false, error) }
	wj.JS_FreeValue(ctx, error)
	if !n.firing { ongoing_free(ctx, n) }
}

@(private = "file")
abort_error :: proc "contextless" (ctx: ^wj.Context, message: cstring) -> wj.JSValue { return wj.web_dom_exception(ctx, "AbortError", message) }

// The after-transition scroll: push and replace go to the fragment of the new URL, or to the top.
@(private = "file")
nav_scroll :: proc(ctx: ^wj.Context, n: ^Ongoing) {
	n.scrolled = true
	if n.type != .Push && n.type != .Replace { return }
	loc := global_prop(ctx, "location")
	hash := wj.is_object(loc) ? wj.JS_GetPropertyStr(ctx, loc, "hash") : wj.UNDEFINED
	wj.JS_FreeValue(ctx, loc)
	hc: cstring
	h: string
	if wj.is_string(hash) { hc, h = to_text(ctx, hash) }
	wj.JS_FreeValue(ctx, hash)
	done := false
	if hc != nil && len(h) > 1 {
		doc := global_prop(ctx, "document")
		by_id := wj.is_object(doc) ? wj.JS_GetPropertyStr(ctx, doc, "getElementById") : wj.UNDEFINED
		if wj.JS_IsFunction(ctx, by_id) {
			id := wj.new_string_len(ctx, h[1:])
			el := wj.JS_Call(ctx, by_id, doc, 1, &id)
			wj.JS_FreeValue(ctx, id)
			if wj.is_object(el) {
				siv := wj.JS_GetPropertyStr(ctx, el, "scrollIntoView")
				if wj.JS_IsFunction(ctx, siv) { wj.JS_FreeValue(ctx, wj.JS_Call(ctx, siv, el, 0, nil)); done = true }
				wj.JS_FreeValue(ctx, siv)
			}
			if wj.is_exception(el) { wj.drop_exception(ctx) }
			wj.JS_FreeValue(ctx, el)
		}
		wj.free_values(ctx, by_id, doc)
	}
	if hc != nil { wj.JS_FreeCString(ctx, hc) }
	if !done {
		st := global_prop(ctx, "scrollTo")
		if wj.JS_IsFunction(ctx, st) {
			a := [2]wj.JSValue{wj.new_int32(0), wj.new_int32(0)}
			wj.JS_FreeValue(ctx, wj.JS_Call(ctx, st, wj.realm_global(), 2, &a[0]))
		}
		wj.JS_FreeValue(ctx, st)
	}
	if wj.JS_HasException(ctx) { wj.drop_exception(ctx) }
}

// The after-transition focus reset: when the focus did not move during the navigation, it goes back to the document.
@(private = "file")
nav_focus_reset :: proc(ctx: ^wj.Context, n: ^Ongoing) {
	doc := global_prop(ctx, "document")
	active := wj.is_object(doc) ? wj.JS_GetPropertyStr(ctx, doc, "activeElement") : wj.NULL
	body := wj.is_object(doc) ? wj.JS_GetPropertyStr(ctx, doc, "body") : wj.NULL
	if wj.is_object(active) && wj.same_ptr(active, n.focus_before) && !wj.same_ptr(active, body) {
		blur := wj.JS_GetPropertyStr(ctx, active, "blur")
		if wj.JS_IsFunction(ctx, blur) { wj.JS_FreeValue(ctx, wj.JS_Call(ctx, blur, active, 0, nil)) }
		wj.JS_FreeValue(ctx, blur)
	}
	wj.free_values(ctx, body, active, doc)
	if wj.JS_HasException(ctx) { wj.drop_exception(ctx) }
}

// The navigation is over: navigatesuccess (or navigateerror), the promises, navigation.transition.
@(private = "file")
nav_finish :: proc(ctx: ^wj.Context, n: ^Ongoing, ok: bool, error: wj.JSValue) {
	if ongoing == n { ongoing = nil }
	if ok {
		if n.intercepted {
			if !n.focus_manual { nav_focus_reset(ctx, n) }
			if !n.scroll_manual && !n.scrolled { nav_scroll(ctx, n) }
		}
		if !wj.is_undefined(nav_obj) { wj.web_fire_simple(ctx, nav_obj, "navigatesuccess") }
		if n.tracker != nil {
			entry := current_entry(ctx)
			prom_resolve(ctx, &n.tracker.finished, entry)
			wj.JS_FreeValue(ctx, entry)
		}
		if n.intercepted { transition_end(ctx, true, wj.UNDEFINED) }
	} else {
		if wj.is_object(n.controller) {
			arg := error
			r := wjr_AbortController_abort(ctx, n.controller, 1, &arg)
			if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
		}
		fire_navigateerror(ctx, error)
		if n.tracker != nil { prom_reject(ctx, &n.tracker.finished, error) }
		if n.intercepted { transition_end(ctx, false, error) }
	}
	ongoing_free(ctx, n)
}

// ---- Navigation ----

@(private = "file")
navigation_get :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	if wj.is_undefined(nav_obj) {
		o := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("Navigation"), wj.UNDEFINED)
		if wj.is_exception(o) { return o }
		nav_obj = o
	}
	return wj.JS_DupValue(ctx, nav_obj)
}

@(export, link_name = "wjr_Window_get_navigation")
wjr_Window_get_navigation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return navigation_get(ctx) }

@(private = "file")
nav_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> bool {
	return wj.wj_this(ctx, this_val, ifc("Navigation")) != nil
}

@(export, link_name = "wjr_Navigation_entries")
wjr_Navigation_entries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	nav_sync(ctx)
	arr := wj.JS_NewArray(ctx)
	for w, i in entries { wj.array_set(ctx, arr, u32(i), wj.JS_DupValue(ctx, w)) }
	return arr
}

@(export, link_name = "wjr_Navigation_get_currentEntry")
wjr_Navigation_get_currentEntry :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	return current_entry(ctx)
}

@(export, link_name = "wjr_Navigation_get_transition")
wjr_Navigation_get_transition :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	return wj.is_undefined(transition) ? wj.NULL : wj.JS_DupValue(ctx, transition)
}

// navigation.activation: made once from what the browser says (Navigation_activation); null without one.
@(private = "file") activation := wj.UNDEFINED

@(private = "file")
entry_by_key :: proc "contextless" (ctx: ^wj.Context, key: i64) -> wj.JSValue {
	if key == 0 { return wj.NULL }
	for w in entries { if e := entry_of(w); e != nil && e.key == key { return wj.JS_DupValue(ctx, w) } }
	return wj.NULL
}

@(export, link_name = "wjr_Navigation_get_activation")
wjr_Navigation_get_activation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	if !wj.is_undefined(activation) { return wj.JS_DupValue(ctx, activation) }
	nav_sync(ctx)
	text: string
	jsb.host(&text, api_decl.Navigation_activation, wj.wr_Navigation_activation)
	if len(text) == 0 { activation = wj.NULL; return wj.NULL }
	s := Scan{text = text[:min(len(text), 63)]}
	type := scan_int(&s)
	from := scan_int(&s)
	if type < 0 || type > i64(Nav_Type.Traverse) { activation = wj.NULL; return wj.NULL }
	a := wj.wj_new_object(ctx, ifc("NavigationActivation"), nil, nil)
	if wj.is_exception(a) { return a }
	wj.web_extra_set(ctx, a, "navigationType", wj.new_string(ctx, NAV_TYPES[Nav_Type(type)]))
	wj.web_extra_set(ctx, a, "entry", current_entry(ctx))
	wj.web_extra_set(ctx, a, "from", entry_by_key(ctx, from))
	activation = wj.JS_DupValue(ctx, a)
	return a
}

@(private = "file")
activation_member :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, name: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("NavigationActivation")) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	return wj.is_undefined(v) ? wj.NULL : v
}
@(export, link_name = "wjr_NavigationActivation_get_from")           wjr_NavigationActivation_get_from           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return activation_member(ctx, this_val, "from") }
@(export, link_name = "wjr_NavigationActivation_get_entry")          wjr_NavigationActivation_get_entry          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return activation_member(ctx, this_val, "entry") }
@(export, link_name = "wjr_NavigationActivation_get_navigationType") wjr_NavigationActivation_get_navigationType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return activation_member(ctx, this_val, "navigationType") }

@(export, link_name = "wjr_Navigation_get_canGoBack")
wjr_Navigation_get_canGoBack :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	nav_sync(ctx)
	return wj.new_bool(current > 0)
}

@(export, link_name = "wjr_Navigation_get_canGoForward")
wjr_Navigation_get_canGoForward :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	nav_sync(ctx)
	return wj.new_bool(current >= 0 && current + 1 < i64(len(entries)))
}

// `type` -1: none (updateCurrentEntry).
@(private = "file")
fire_currententrychange :: proc(ctx: ^wj.Context, type: int, from: wj.JSValue) {
	if wj.is_undefined(nav_obj) || !wj.is_object(from) { return }
	ev := wj.web_event_new(ctx, ifc("NavigationCurrentEntryChangeEvent"), "currententrychange", false, false)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_extra_set(ctx, ev, "navigationType", type >= 0 ? wj.new_string(ctx, NAV_TYPES[Nav_Type(type)]) : wj.NULL)
	wj.web_extra_set(ctx, ev, "from", wj.JS_DupValue(ctx, from))
	wj.web_event_fire(ctx, nav_obj, ev)
	wj.JS_FreeValue(ctx, ev)
}

@(export, link_name = "wjr_Navigation_updateCurrentEntry")
wjr_Navigation_updateCurrentEntry :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "updateCurrentEntry") { return wj.EXCEPTION }
	st: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "state", &st) { return wj.EXCEPTION }
	if wj.is_undefined(st) {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'updateCurrentEntry' on 'Navigation': required member state is undefined.")
	}
	from := current_entry(ctx)
	defer wj.JS_FreeValue(ctx, from)
	if !wj.is_object(from) {
		wj.JS_FreeValue(ctx, st)
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'updateCurrentEntry' on 'Navigation': the document has no current entry.")
	}
	sl: uint
	s := web_state_encode(ctx, st, &sl)
	wj.JS_FreeValue(ctx, st)
	if s == nil { return wj.EXCEPTION }
	defer wj.libc_free(s)
	if r := jsb.host(&none, api_decl.Navigation_updateCurrentEntry, wj.wr_Navigation_updateCurrentEntry, string(s[:sl])); r != .None {
		return wj.wj_throw_status(ctx, i32(r), "updateCurrentEntry")
	}
	fire_currententrychange(ctx, -1, from)
	return wj.UNDEFINED
}

// options.info and, when `want_state`, options.state serialized (nil: absent). False with an exception pending.
@(private = "file")
read_options :: proc(ctx: ^wj.Context, opt: wj.JSValue, what: cstring, info: ^wj.JSValue, state: ^[^]u8, state_len: ^uint, want_state: bool) -> bool {
	info^ = wj.UNDEFINED
	if state != nil { state^ = nil; state_len^ = 0 }
	if !wj.web_dict_check(ctx, opt, what) { return false }
	if !wj.web_dict_get(ctx, opt, "info", info) { return false }
	if want_state {
		st: wj.JSValue
		if !wj.web_dict_get(ctx, opt, "state", &st) { wj.JS_FreeValue(ctx, info^); return false }
		if !wj.is_undefined(st) {
			state^ = web_state_encode(ctx, st, state_len)
			wj.JS_FreeValue(ctx, st)
			if state^ == nil { wj.JS_FreeValue(ctx, info^); return false }
		}
	}
	return true
}

@(private = "file")
replace_upcoming :: proc(ctx: ^wj.Context, t: ^Tracker) {
	tracker_free(ctx, upcoming)
	upcoming = t
}

// options.history: NavigationHistoryBehavior (0 auto, 1 push, 2 replace).
@(private = "file")
read_history :: proc(ctx: ^wj.Context, opt: wj.JSValue, out: ^i32) -> bool {
	out^ = 0
	hv: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "history", &hv) { return false }
	if wj.is_undefined(hv) { return true }
	values := [4]cstring{"auto", "push", "replace", nil}
	hs: wj.Str
	ok := wj.wj_to_str(ctx, hv, &hs, 0, "")
	wj.JS_FreeValue(ctx, hv)
	if !ok { return false }
	defer wj.wj_str_free(ctx, &hs)
	if !wj.wj_check_enum(ctx, &hs, &values[0], "NavigationHistoryBehavior") { return false }
	out^ = wj.wj_enum_index(&hs, &values[0])
	return true
}

// After the browser call that started the navigation: a tracker no navigate event took (a javascript: URL) is let go
// (its promises never settle); a refusal of the browser rejects both.
@(private = "file")
tracker_done :: proc(ctx: ^wj.Context, t: ^Tracker, r: abi.Api_Error, res: wj.JSValue, what: cstring) -> wj.JSValue {
	if upcoming == t { upcoming = nil; tracker_free(ctx, t) }
	if r == .None { return res }
	wj.JS_FreeValue(ctx, res)
	if r == .Syntax { return early_dom_error(ctx, "SyntaxError", "Failed to execute on 'Navigation': the URL is invalid.") }
	wj.wj_throw_status(ctx, i32(r), what)
	return early_error(ctx)
}

// A state serialized by web_state_encode, or absent.
@(private = "file")
state_view :: proc "contextless" (state: [^]u8, n: uint) -> Maybe(string) {
	if state == nil { return nil }
	return string(state[:n])
}

@(export, link_name = "wjr_Navigation_navigate")
wjr_Navigation_navigate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Navigation.navigate", 1, argc) }
	u: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &u) { return early_error(ctx) }
	defer wj.wj_str_free(ctx, &u)
	opt := wj.arg(argc, argv, 1)
	info: wj.JSValue
	state: [^]u8
	sl: uint
	if !read_options(ctx, opt, "navigate", &info, &state, &sl, true) { return early_error(ctx) }
	defer wj.libc_free(state)
	history: i32
	if !read_history(ctx, opt, &history) { wj.JS_FreeValue(ctx, info); return early_error(ctx) }
	t := tracker_new(ctx, info)
	wj.JS_FreeValue(ctx, info)
	if t == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	res := tracker_result(ctx, t)
	replace_upcoming(ctx, t)
	r := jsb.host(&none, api_decl.Navigation_navigate, wj.wr_Navigation_navigate, str_view(u), state_view(state, sl), history)
	return tracker_done(ctx, t, r, res, "navigate")
}

@(export, link_name = "wjr_Navigation_reload")
wjr_Navigation_reload :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	info: wj.JSValue
	state: [^]u8
	sl: uint
	if !read_options(ctx, wj.arg(argc, argv, 0), "reload", &info, &state, &sl, true) { return early_error(ctx) }
	defer wj.libc_free(state)
	t := tracker_new(ctx, info)
	wj.JS_FreeValue(ctx, info)
	if t == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	res := tracker_result(ctx, t)
	replace_upcoming(ctx, t)
	r := jsb.host(&none, api_decl.Navigation_reload, wj.wr_Navigation_reload, state_view(state, sl))
	return tracker_done(ctx, t, r, res, "reload")
}

@(private = "file")
traverse_to :: proc(ctx: ^wj.Context, key: i64, key_ok: bool, opt: wj.JSValue, what: cstring) -> wj.JSValue {
	info: wj.JSValue
	if !read_options(ctx, opt, what, &info, nil, nil, false) { return early_error(ctx) }
	nav_sync(ctx)
	at := -1
	for w, i in entries {
		if !key_ok { break }
		if e := entry_of(w); e != nil && e.key == key { at = i; break }
	}
	if current < 0 || at < 0 {
		wj.JS_FreeValue(ctx, info)
		return early_dom_error(ctx, "InvalidStateError", "Failed to execute on 'Navigation': no entry of navigation.entries() has this key.")
	}
	if i64(at) == current {
		wj.JS_FreeValue(ctx, info)
		r := wj.JS_NewObject(ctx)
		wj.JS_DefinePropertyValueStr(ctx, r, "committed", wj.web_promise_resolved(ctx, entries[current]), wj.PROP_C_W_E)
		wj.JS_DefinePropertyValueStr(ctx, r, "finished", wj.web_promise_resolved(ctx, entries[current]), wj.PROP_C_W_E)
		return r
	}
	// a traversal to that entry already asked for answers with the same promises
	for x := traversals; x != nil; x = x.next {
		if x.key == key { wj.JS_FreeValue(ctx, info); return tracker_result(ctx, x) }
	}
	t := tracker_new(ctx, info)
	wj.JS_FreeValue(ctx, info)
	if t == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	t.key = key
	res := tracker_result(ctx, t)
	if r := jsb.host(&none, api_decl.Navigation_traverseTo, wj.wr_Navigation_traverseTo, key); r != .None {
		tracker_free(ctx, t)
		wj.JS_FreeValue(ctx, res)
		wj.wj_throw_status(ctx, i32(r), what)
		return early_error(ctx)
	}
	t.next = traversals
	traversals = t
	return res
}

@(export, link_name = "wjr_Navigation_traverseTo")
wjr_Navigation_traverseTo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Navigation.traverseTo", 1, argc) }
	k: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &k, 0, "") { return early_error(ctx) }
	// keys are the browser's numbers: anything else is no entry's
	text := str_view(k)
	ok := len(text) > 0 && len(text) < 24
	key: i64
	if ok {
		s := Scan{text = text}
		key = scan_int(&s)
		ok = s.at == len(text) && key > 0
	}
	wj.wj_str_free(ctx, &k)
	return traverse_to(ctx, key, ok, wj.arg(argc, argv, 1), "traverseTo")
}

@(private = "file")
go_by :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, delta: i64, what: cstring) -> wj.JSValue {
	if !nav_this(ctx, this_val) { return wj.EXCEPTION }
	nav_sync(ctx)
	at := current + delta
	if current < 0 || at < 0 || at >= i64(len(entries)) {
		return early_dom_error(ctx, "InvalidStateError", delta < 0 ? "Failed to execute 'back' on 'Navigation': cannot go back." : "Failed to execute 'forward' on 'Navigation': cannot go forward.")
	}
	e := entry_of(entries[at])
	return traverse_to(ctx, e != nil ? e.key : 0, e != nil, wj.arg(argc, argv, 0), what)
}

@(export, link_name = "wjr_Navigation_back")
wjr_Navigation_back :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return go_by(ctx, this_val, argc, argv, -1, "back")
}
@(export, link_name = "wjr_Navigation_forward")
wjr_Navigation_forward :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return go_by(ctx, this_val, argc, argv, 1, "forward")
}

// ---- NavigationDestination ----

@(private = "file")
Destination :: struct {
	url:                wj.JSValue,
	key, id, index:     i64,
	same_doc, has_state: bool,
	state:              string,   // on the libc heap
}

@(private = "file")
dest_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	d := (^Destination)(p)
	wj.JS_FreeValueRT(wj.web_rt(), d.url)
	delete(d.state, wj.libc_allocator())
	free(d)
}

@(private = "file")
dest_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Destination)(p).url, mark_func) }

@(private = "file")
dest_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Destination {
	o := wj.wj_this(ctx, this_val, ifc("NavigationDestination"))
	if o == nil { return nil }
	if o.impl_free != dest_free { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Destination)(o.impl)
}

// A key or id as a string ("" for none).
@(private = "file")
id_string :: proc "contextless" (ctx: ^wj.Context, v: i64) -> wj.JSValue {
	if v <= 0 { return wj.new_string(ctx, "") }
	buf: [24]u8
	n := wj.snprintf(&buf[0], len(buf), "%lld", v)
	return wj.new_string_len(ctx, buf[:max(n, 0)])
}

@(export, link_name = "wjr_NavigationDestination_get_url")          wjr_NavigationDestination_get_url          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { d := dest_this(ctx, this_val); return d != nil ? wj.JS_DupValue(ctx, d.url) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationDestination_get_key")          wjr_NavigationDestination_get_key          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { d := dest_this(ctx, this_val); return d != nil ? id_string(ctx, d.key) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationDestination_get_id")           wjr_NavigationDestination_get_id           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { d := dest_this(ctx, this_val); return d != nil ? id_string(ctx, d.id) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationDestination_get_index")        wjr_NavigationDestination_get_index        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { d := dest_this(ctx, this_val); return d != nil ? wj.new_int64(ctx, d.index) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationDestination_get_sameDocument") wjr_NavigationDestination_get_sameDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { d := dest_this(ctx, this_val); return d != nil ? wj.new_bool(d.same_doc) : wj.EXCEPTION }

@(export, link_name = "wjr_NavigationDestination_getState")
wjr_NavigationDestination_getState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := dest_this(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	if !d.has_state { return wj.UNDEFINED }
	return web_state_decode(ctx, raw_data(d.state), uint(len(d.state)))
}

// ---- the browser's side: firing navigate, committing ----

// Fires navigate for the navigation the browser is about to make: 0 go on, 1 cancelled, 2 intercepted.
@(export, link_name = "wj_nav_fire")
wj_nav_fire :: proc "c" (unused: i32) -> i32 {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	if ctx == nil || wj.is_undefined(nav_obj) { return 0 }
	wj.wj_stack_enter(ctx)
	pending: string
	if jsb.host(&pending, api_decl.Navigation_pending, wj.wr_Navigation_pending) != .None { return 0 }
	text := clone_text(pending)
	defer delete(text, wj.libc_allocator())
	s := Scan{text = text}
	type := scan_int(&s)
	flags := transmute(Nav_Flags)u32(scan_int(&s))
	key := scan_int(&s)
	id := scan_int(&s)
	index := scan_int(&s)
	if s.at < len(text) && text[s.at] == ' ' { s.at += 1 }
	if type < 0 || type > i64(Nav_Type.Traverse) { return 0 }
	nav_type := Nav_Type(type)
	d := new(Destination)
	if d == nil { return 0 }
	d.url = wj.new_string_len(ctx, text[s.at:])
	d.key, d.id, d.index = key, id, index
	d.same_doc = .Same_Doc in flags
	if .Has_State in flags {
		state: string
		if jsb.host(&state, api_decl.Navigation_pendingState, wj.wr_Navigation_pendingState) == .None {
			d.state = clone_text(state)
			d.has_state = true
		}
	}
	dest := wj.wj_new_object(ctx, ifc("NavigationDestination"), nil, nil)
	if wj.is_exception(dest) { dest_free(d); wj.wj_report_pending(ctx); return 0 }
	wj.web_set_impl(dest, d, dest_free, dest_mark)

	from := current_entry(ctx)
	if ongoing != nil { nav_abort(ctx, ongoing, abort_error(ctx, "A new navigation started.")) }

	o := new(Ongoing)
	if o == nil { wj.free_values(ctx, dest, from); return 0 }
	ongoing_serial += 1
	o.serial = ongoing_serial
	o.type = nav_type
	o.flags = flags
	o.from = from
	o.destination = dest
	o.event, o.controller, o.handlers, o.focus_before = wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	if nav_type == .Traverse {
		for x := &traversals; x^ != nil; x = &x^.next {
			if x^.key == key {
				o.tracker = x^
				x^ = x^.next
				o.tracker.next = nil
				break
			}
		}
	} else {
		o.tracker = upcoming
		upcoming = nil
	}
	o.controller = wj.JS_CallConstructor(ctx, wj.wj_the_realm.ctors[ifc("AbortController")], 0, nil)
	if wj.is_exception(o.controller) { o.controller = wj.UNDEFINED; wj.wj_report_pending(ctx) }
	signal := wj.is_object(o.controller) ? wjr_AbortController_get_signal(ctx, o.controller) : wj.NULL
	if wj.is_exception(signal) { signal = wj.NULL; wj.wj_report_pending(ctx) }
	ev := wj.web_event_new(ctx, ifc("NavigateEvent"), "navigate", false, .Cancelable in flags)
	if wj.is_exception(ev) { wj.JS_FreeValue(ctx, signal); ongoing_free(ctx, o); wj.wj_report_pending(ctx); return 0 }
	wj.web_extra_set(ctx, ev, "navigationType", wj.new_string(ctx, NAV_TYPES[nav_type]))
	wj.web_extra_set(ctx, ev, "destination", wj.JS_DupValue(ctx, dest))
	wj.web_extra_set(ctx, ev, "canIntercept", wj.new_bool(.Can_Intercept in flags))
	wj.web_extra_set(ctx, ev, "userInitiated", wj.new_bool(.User in flags))
	wj.web_extra_set(ctx, ev, "hashChange", wj.new_bool(.Hash in flags))
	wj.web_extra_set(ctx, ev, "signal", signal)
	wj.web_extra_set(ctx, ev, "info", o.tracker != nil ? wj.JS_DupValue(ctx, o.tracker.info) : wj.UNDEFINED)
	// what started it: sourceElement, and a POST form submission's formData (new FormData(form, submitter))
	src: wj.wr_NavigationSource
	wj.wr_Navigation_pendingSource(&src)
	if src.source != 0 {
		el := wj.wj_wrap_node(ctx, src.source)
		if wj.is_exception(el) { wj.drop_exception(ctx); el = wj.NULL }
		wj.web_extra_set(ctx, ev, "sourceElement", el)
	}
	if src.form != 0 {
		args := [2]wj.JSValue{wj.wj_wrap_node(ctx, src.form), src.submitter != 0 ? wj.wj_wrap_node(ctx, src.submitter) : wj.UNDEFINED}
		fd := wj.JS_CallConstructor(ctx, wj.wj_the_realm.ctors[ifc("FormData")], src.submitter != 0 ? 2 : 1, &args[0])
		wj.free_values(ctx, args[0], args[1])
		if wj.is_exception(fd) { wj.drop_exception(ctx); fd = wj.NULL }
		wj.web_extra_set(ctx, ev, "formData", fd)
	}
	o.event = ev
	o.handlers = wj.JS_NewArray(ctx)
	o.firing = true
	ongoing = o
	go_on := wj.web_event_fire(ctx, nav_obj, ev)
	o.firing = false
	if o.aborted { ongoing_free(ctx, o); return 1 }   // (another navigation started from a listener)
	if !go_on { nav_abort(ctx, o, abort_error(ctx, "The navigation was cancelled.")); return 1 }
	if o.intercepted { return 2 }
	if .Same_Doc in flags { return 0 }   // wj_nav_commit follows
	// another document: this one goes away (the promises never settle)
	ongoing = nil
	ongoing_free(ctx, o)
	return 0
}

@(private = "file")
handler_ok :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	serial: u32
	wj.JS_ToUint32(ctx, &serial, data[0])
	o := ongoing
	if o == nil || o.serial != serial || o.pending == 0 { return wj.UNDEFINED }
	o.pending -= 1
	if o.pending == 0 { nav_finish(ctx, o, true, wj.UNDEFINED) }
	return wj.UNDEFINED
}

@(private = "file")
handler_failed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	serial: u32
	wj.JS_ToUint32(ctx, &serial, data[0])
	o := ongoing
	if o == nil || o.serial != serial || o.pending == 0 { return wj.UNDEFINED }
	o.pending = 0
	nav_finish(ctx, o, false, argc > 0 ? argv[0] : wj.UNDEFINED)
	return wj.UNDEFINED
}

@(private = "file")
still :: #force_inline proc "contextless" (serial: u32) -> bool { return ongoing != nil && ongoing.serial == serial }

// The browser committed a same-document navigation (`arg`: type << 1 | intercepted): currententrychange, the handlers,
// then the end of the navigation.
@(export, link_name = "wj_nav_commit")
wj_nav_commit :: proc "c" (arg: i32) {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	if ctx == nil || wj.is_undefined(nav_obj) { return }
	wj.wj_stack_enter(ctx)
	type := Nav_Type((arg >> 1) & 3)
	o := ongoing
	if o != nil && (o.committed || o.firing || o.type != type) { o = nil }
	nav_sync(ctx)
	if o == nil { return }   // (no navigate event was fired for it: the entry it left is not known)
	serial := o.serial
	o.committed = true
	if o.intercepted {
		t := (^Transition)(wj.libc_calloc(1, size_of(Transition)))
		tr := t != nil ? wj.wj_new_object(ctx, ifc("NavigationTransition"), nil, nil) : wj.EXCEPTION
		if wj.is_exception(tr) {
			wj.libc_free(t)
			wj.wj_report_pending(ctx)
		} else {
			t.type = type
			t.from = wj.JS_DupValue(ctx, o.from)
			t.to = wj.JS_DupValue(ctx, o.destination)
			t.committed = wj.web_promise_resolved(ctx, wj.UNDEFINED)
			t.finished = PROM_NONE
			prom_new(ctx, &t.finished)
			mark_handled(ctx, t.finished.p)
			wj.web_set_impl(tr, t, transition_free, transition_mark)
			set_transition(ctx, tr)
		}
		doc := global_prop(ctx, "document")
		o.focus_before = wj.is_object(doc) ? wj.JS_GetPropertyStr(ctx, doc, "activeElement") : wj.NULL
		wj.JS_FreeValue(ctx, doc)
		if wj.is_exception(o.focus_before) { wj.drop_exception(ctx); o.focus_before = wj.NULL }
	}
	// committed resolves first: a navigation started from currententrychange aborts the finished promise only
	if o.tracker != nil {
		entry := current_entry(ctx)
		prom_resolve(ctx, &o.tracker.committed, entry)
		wj.JS_FreeValue(ctx, entry)
	}
	if !still(serial) { return }
	from := wj.JS_DupValue(ctx, o.from)
	fire_currententrychange(ctx, int(type), from)
	wj.JS_FreeValue(ctx, from)
	if !still(serial) { return }
	if !o.intercepted { nav_finish(ctx, o, true, wj.UNDEFINED); return }
	// the handlers, in order; navigatesuccess once every promise they returned is fulfilled
	count: i64
	wj.JS_GetLength(ctx, o.handlers, &count)
	handlers := wj.JS_DupValue(ctx, o.handlers)
	data := wj.new_uint32(ctx, serial)
	o.pending = u32(count) + 1
	for i in 0 ..< count {
		h := wj.JS_GetPropertyUint32(ctx, handlers, u32(i))
		r := wj.JS_Call(ctx, h, wj.UNDEFINED, 0, nil)
		wj.JS_FreeValue(ctx, h)
		fn: [2]wj.JSValue
		pr := wj.web_promise_new(ctx, &fn[0])
		if wj.is_exception(r) { wj.web_settle(ctx, fn[1], wj.JS_GetException(ctx)) } else { wj.web_settle(ctx, fn[0], r) }
		wj.free_values(ctx, fn[0], fn[1])
		then_drop(ctx, pr, handler_ok, handler_failed, data)
		wj.JS_FreeValue(ctx, pr)
		if !still(serial) { break }
	}
	wj.JS_FreeValue(ctx, handlers)
	// (Promise.all of no promise settles in a microtask too)
	if still(serial) {
		pr := wj.web_promise_resolved(ctx, wj.UNDEFINED)
		then_drop(ctx, pr, handler_ok, handler_failed, data)
		wj.JS_FreeValue(ctx, pr)
	}
	wj.JS_FreeValue(ctx, data)
}

// ---- NavigateEvent ----

@(private = "file")
extra_or :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, name: cstring, def: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface) == nil { wj.JS_FreeValue(ctx, def); return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if wj.is_undefined(v) { return def }
	wj.JS_FreeValue(ctx, def)
	return v
}

@(export, link_name = "wjr_NavigateEvent_get_navigationType")       wjr_NavigateEvent_get_navigationType       :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "navigationType", wj.new_string(ctx, "push")) }
@(export, link_name = "wjr_NavigateEvent_get_destination")          wjr_NavigateEvent_get_destination          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "destination", wj.NULL) }
@(export, link_name = "wjr_NavigateEvent_get_canIntercept")         wjr_NavigateEvent_get_canIntercept         :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "canIntercept", wj.FALSE) }
@(export, link_name = "wjr_NavigateEvent_get_userInitiated")        wjr_NavigateEvent_get_userInitiated        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "userInitiated", wj.FALSE) }
@(export, link_name = "wjr_NavigateEvent_get_hashChange")           wjr_NavigateEvent_get_hashChange           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "hashChange", wj.FALSE) }
@(export, link_name = "wjr_NavigateEvent_get_signal")               wjr_NavigateEvent_get_signal               :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "signal", wj.NULL) }
@(export, link_name = "wjr_NavigateEvent_get_formData")             wjr_NavigateEvent_get_formData             :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "formData", wj.NULL) }
@(export, link_name = "wjr_NavigateEvent_get_downloadRequest")      wjr_NavigateEvent_get_downloadRequest      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "downloadRequest", wj.NULL) }
@(export, link_name = "wjr_NavigateEvent_get_hasUAVisualTransition") wjr_NavigateEvent_get_hasUAVisualTransition :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "hasUAVisualTransition", wj.FALSE) }
@(export, link_name = "wjr_NavigateEvent_get_sourceElement")        wjr_NavigateEvent_get_sourceElement        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "sourceElement", wj.NULL) }
@(export, link_name = "wjr_NavigateEvent_get_info")                 wjr_NavigateEvent_get_info                 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return extra_or(ctx, this_val, ifc("NavigateEvent"), "info", wj.UNDEFINED) }

// The ongoing navigation of `ev` while it is being fired (or after, for scroll()), else nil.
@(private = "file")
ongoing_of :: proc "contextless" (ev: wj.JSValue) -> ^Ongoing {
	o := ongoing
	return o != nil && wj.same_ptr(o.event, ev) ? o : nil
}

@(private = "file")
event_trusted :: proc "contextless" (ctx: ^wj.Context, ev: wj.JSValue) -> bool {
	v := wj.JS_GetPropertyStr(ctx, ev, "isTrusted")
	t := wj.JS_ToBool(ctx, v) > 0
	wj.JS_FreeValue(ctx, v)
	return t
}

@(export, link_name = "wjr_NavigateEvent_intercept")
wjr_NavigateEvent_intercept :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, this_val, ifc("NavigateEvent")) == nil { return wj.EXCEPTION }
	if !event_trusted(ctx, this_val) { return wj.wj_throw_dom(ctx, "SecurityError", "Failed to execute 'intercept' on 'NavigateEvent': the event was not created by the browser.") }
	o := ongoing_of(this_val)
	if o == nil || !o.firing { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'intercept' on 'NavigateEvent': intercept() may only be called while the navigate event is being dispatched.") }
	if .Can_Intercept not_in o.flags { return wj.wj_throw_dom(ctx, "SecurityError", "Failed to execute 'intercept' on 'NavigateEvent': a navigation to this URL cannot be intercepted.") }
	dp := wj.JS_GetPropertyStr(ctx, this_val, "defaultPrevented")
	prevented := wj.JS_ToBool(ctx, dp) > 0
	wj.JS_FreeValue(ctx, dp)
	if prevented { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'intercept' on 'NavigateEvent': the navigation was cancelled.") }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "intercept") { return wj.EXCEPTION }
	h: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "handler", &h) { return wj.EXCEPTION }
	if !wj.is_undefined(h) && !wj.JS_IsFunction(ctx, h) {
		wj.JS_FreeValue(ctx, h)
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'intercept' on 'NavigateEvent': handler is not a function.")
	}
	modes := [3]cstring{"after-transition", "manual", nil}
	names := [2]cstring{"focusReset", "scroll"}
	mode := [2]i32{-1, -1}
	for i in 0 ..< 2 {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, opt, names[i], &v) { wj.JS_FreeValue(ctx, h); return wj.EXCEPTION }
		if wj.is_undefined(v) { continue }
		s: wj.Str
		ok := wj.wj_to_str(ctx, v, &s, 0, "")
		wj.JS_FreeValue(ctx, v)
		if !ok || !wj.wj_check_enum(ctx, &s, &modes[0], i == 0 ? "NavigationFocusReset" : "NavigationScrollBehavior") {
			wj.JS_FreeValue(ctx, h)
			return wj.EXCEPTION
		}
		mode[i] = wj.wj_enum_index(&s, &modes[0])
		wj.wj_str_free(ctx, &s)
	}
	if wj.JS_IsFunction(ctx, h) {
		n: i64
		wj.JS_GetLength(ctx, o.handlers, &n)
		wj.array_set(ctx, o.handlers, u32(n), h)
	} else {
		wj.JS_FreeValue(ctx, h)
	}
	if mode[0] >= 0 { o.focus_manual = mode[0] == 1 }
	if mode[1] >= 0 { o.scroll_manual = mode[1] == 1 }
	o.intercepted = true
	return wj.UNDEFINED
}

@(export, link_name = "wjr_NavigateEvent_scroll")
wjr_NavigateEvent_scroll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.wj_this(ctx, this_val, ifc("NavigateEvent")) == nil { return wj.EXCEPTION }
	if !event_trusted(ctx, this_val) { return wj.wj_throw_dom(ctx, "SecurityError", "Failed to execute 'scroll' on 'NavigateEvent': the event was not created by the browser.") }
	o := ongoing_of(this_val)
	if o == nil || !o.intercepted || !o.committed || o.scrolled {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'scroll' on 'NavigateEvent': only an intercepted navigation that committed and did not scroll yet can scroll.")
	}
	nav_scroll(ctx, o)
	return wj.UNDEFINED
}

// new NavigateEvent(type, init): destination and signal are required.
@(export, link_name = "wjr_NavigateEvent_constructor")
wjr_NavigateEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 2 { return wj.wj_throw_arity(ctx, "NavigateEvent", 2, argc) }
	init := argv[1]
	if !wj.is_object(init) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': the init dictionary is required.") }
	ev := wj_event_construct(ctx, new_target, argc, argv, ifc("NavigateEvent"), "NavigateEvent")
	if wj.is_exception(ev) { return ev }
	if !navigate_event_init(ctx, ev, init) { wj.JS_FreeValue(ctx, ev); return wj.EXCEPTION }
	return ev
}

// The members of the NavigateEventInit dictionary, kept on the event; false with an exception pending.
@(private = "file")
navigate_event_init :: proc(ctx: ^wj.Context, ev, init: wj.JSValue) -> bool {
	v: wj.JSValue
	if !wj.web_dict_get(ctx, init, "navigationType", &v) { return false }
	if wj.is_undefined(v) {
		v = wj.new_string(ctx, "push")
	} else {
		s: wj.Str
		ok := wj.wj_to_str(ctx, v, &s, 0, "")
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		defer wj.wj_str_free(ctx, &s)
		if !wj.wj_check_enum(ctx, &s, &NAV_TYPES_Z[0], "NavigationType") { return false }
		v = wj.new_string_len(ctx, str_view(s))
	}
	wj.web_extra_set(ctx, ev, "navigationType", v)
	if !wj.web_dict_get(ctx, init, "destination", &v) { return false }
	if wj.wj_unwrap(v, ifc("NavigationDestination")) == nil {
		wj.JS_FreeValue(ctx, v)
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': destination is not a NavigationDestination.")
		return false
	}
	wj.web_extra_set(ctx, ev, "destination", v)
	if !wj.web_dict_get(ctx, init, "signal", &v) { return false }
	if wj.wj_unwrap(v, ifc("AbortSignal")) == nil {
		wj.JS_FreeValue(ctx, v)
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': signal is not an AbortSignal.")
		return false
	}
	wj.web_extra_set(ctx, ev, "signal", v)
	for name in ([?]cstring{"canIntercept", "userInitiated", "hashChange", "hasUAVisualTransition"}) {
		if !wj.web_dict_get(ctx, init, name, &v) { return false }
		b := wj.JS_ToBool(ctx, v) > 0
		wj.JS_FreeValue(ctx, v)
		wj.web_extra_set(ctx, ev, name, wj.new_bool(b))
	}
	if !wj.web_dict_get(ctx, init, "formData", &v) { return false }
	if !wj.is_undefined(v) && !wj.is_null(v) && !web_formdata_is(v) {
		wj.JS_FreeValue(ctx, v)
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': formData is not a FormData.")
		return false
	}
	wj.web_extra_set(ctx, ev, "formData", wj.is_undefined(v) ? wj.NULL : v)
	if !wj.web_dict_get(ctx, init, "downloadRequest", &v) { return false }
	if !wj.is_undefined(v) && !wj.is_null(v) {
		s := wj.JS_ToString(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(s) { return false }
		v = s
	}
	wj.web_extra_set(ctx, ev, "downloadRequest", wj.is_undefined(v) ? wj.NULL : v)
	if !wj.web_dict_get(ctx, init, "sourceElement", &v) { return false }
	if !wj.is_undefined(v) && !wj.is_null(v) && wj.wj_unwrap(v, ifc("Element")) == nil {
		wj.JS_FreeValue(ctx, v)
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigateEvent': sourceElement is not an Element.")
		return false
	}
	wj.web_extra_set(ctx, ev, "sourceElement", wj.is_undefined(v) ? wj.NULL : v)
	if !wj.web_dict_get(ctx, init, "info", &v) { return false }
	wj.web_extra_set(ctx, ev, "info", v)
	return true
}

// ---- NavigationHistoryEntry ----

@(private = "file")
entry_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Entry {
	o := wj.wj_this(ctx, this_val, ifc("NavigationHistoryEntry"))
	if o == nil { return nil }
	if o.impl_free != entry_free { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	context = wj.heap_context()
	nav_sync(ctx)
	return (^Entry)(o.impl)
}

@(export, link_name = "wjr_NavigationHistoryEntry_get_url")          wjr_NavigationHistoryEntry_get_url          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { e := entry_this(ctx, this_val); return e != nil ? wj.JS_DupValue(ctx, e.url) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationHistoryEntry_get_key")          wjr_NavigationHistoryEntry_get_key          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { e := entry_this(ctx, this_val); return e != nil ? id_string(ctx, e.key) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationHistoryEntry_get_id")           wjr_NavigationHistoryEntry_get_id           :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { e := entry_this(ctx, this_val); return e != nil ? id_string(ctx, e.id) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationHistoryEntry_get_index")        wjr_NavigationHistoryEntry_get_index        :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { e := entry_this(ctx, this_val); return e != nil ? wj.new_int64(ctx, e.index) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationHistoryEntry_get_sameDocument") wjr_NavigationHistoryEntry_get_sameDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { e := entry_this(ctx, this_val); return e != nil ? wj.new_bool(e.index >= 0 && e.same_doc) : wj.EXCEPTION }

@(export, link_name = "wjr_NavigationHistoryEntry_getState")
wjr_NavigationHistoryEntry_getState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	e := entry_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if e.index < 0 { return wj.UNDEFINED }
	text: string
	st := jsb.host(&text, api_decl.Navigation_getState, wj.wr_Navigation_getState, e.key, e.id)
	return state_value(ctx, text, st)
}

// ---- NavigationTransition ----

@(private = "file")
transition_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Transition {
	o := wj.wj_this(ctx, this_val, ifc("NavigationTransition"))
	if o == nil { return nil }
	if o.impl_free != transition_free { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Transition)(o.impl)
}

@(export, link_name = "wjr_NavigationTransition_get_navigationType") wjr_NavigationTransition_get_navigationType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { t := transition_this(ctx, this_val); return t != nil ? wj.new_string(ctx, NAV_TYPES[t.type]) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationTransition_get_from")          wjr_NavigationTransition_get_from          :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { t := transition_this(ctx, this_val); return t != nil ? wj.JS_DupValue(ctx, t.from) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationTransition_get_to")            wjr_NavigationTransition_get_to            :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { t := transition_this(ctx, this_val); return t != nil ? wj.JS_DupValue(ctx, t.to) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationTransition_get_committed")     wjr_NavigationTransition_get_committed     :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { t := transition_this(ctx, this_val); return t != nil ? wj.JS_DupValue(ctx, t.committed) : wj.EXCEPTION }
@(export, link_name = "wjr_NavigationTransition_get_finished")      wjr_NavigationTransition_get_finished      :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { t := transition_this(ctx, this_val); return t != nil ? wj.JS_DupValue(ctx, t.finished.p) : wj.EXCEPTION }

// ---- NavigationCurrentEntryChangeEvent ----

@(export, link_name = "wjr_NavigationCurrentEntryChangeEvent_get_navigationType")
wjr_NavigationCurrentEntryChangeEvent_get_navigationType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return extra_or(ctx, this_val, ifc("NavigationCurrentEntryChangeEvent"), "navigationType", wj.NULL)
}
@(export, link_name = "wjr_NavigationCurrentEntryChangeEvent_get_from")
wjr_NavigationCurrentEntryChangeEvent_get_from :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return extra_or(ctx, this_val, ifc("NavigationCurrentEntryChangeEvent"), "from", wj.NULL)
}

@(export, link_name = "wjr_NavigationCurrentEntryChangeEvent_constructor")
wjr_NavigationCurrentEntryChangeEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 2 { return wj.wj_throw_arity(ctx, "NavigationCurrentEntryChangeEvent", 2, argc) }
	init := argv[1]
	if !wj.is_object(init) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigationCurrentEntryChangeEvent': the init dictionary is required.") }
	from, type: wj.JSValue
	if !wj.web_dict_get(ctx, init, "from", &from) { return wj.EXCEPTION }
	if entry_of(from) == nil {
		wj.JS_FreeValue(ctx, from)
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'NavigationCurrentEntryChangeEvent': from is not a NavigationHistoryEntry.")
	}
	if !wj.web_dict_get(ctx, init, "navigationType", &type) { wj.JS_FreeValue(ctx, from); return wj.EXCEPTION }
	if !wj.is_undefined(type) && !wj.is_null(type) {
		s: wj.Str
		ok := wj.wj_to_str(ctx, type, &s, 0, "")
		wj.JS_FreeValue(ctx, type)
		if !ok { wj.JS_FreeValue(ctx, from); return wj.EXCEPTION }
		defer wj.wj_str_free(ctx, &s)
		if !wj.wj_check_enum(ctx, &s, &NAV_TYPES_Z[0], "NavigationType") { wj.JS_FreeValue(ctx, from); return wj.EXCEPTION }
		type = wj.new_string_len(ctx, str_view(s))
	} else {
		type = wj.NULL
	}
	ev := wj_event_construct(ctx, new_target, argc, argv, ifc("NavigationCurrentEntryChangeEvent"), "NavigationCurrentEntryChangeEvent")
	if wj.is_exception(ev) { wj.free_values(ctx, from, type); return ev }
	wj.web_extra_set(ctx, ev, "navigationType", type)
	wj.web_extra_set(ctx, ev, "from", from)
	return ev
}

package page

// Window, Location and History (import module "history").
//
// The page never navigates by itself: a cross-document navigation (location.assign / replace / reload, history.go to an
// entry of another document) is handed to the embedder's Navigate_Hook from a task of its own, since it closes this
// page. Same-document changes are done here: a fragment navigation, pushState / replaceState, and traversals between
// entries of this document (popstate, hashchange). The embedder is told (Url_Changed) so its address bar follows.
//
// Events of the Window (popstate, hashchange, storage) are fired at the Window host object returned by Window_self.

import "core:strings"
import "wb:dom"
import "wb:url"
import "wb:wasm"

window_vt := Object_VTable{name = "Window"}

// The Window object of the page (created on first use; the same handle afterwards unless released).
window_object :: proc(p: ^Page, owner: u32 = 0) -> u64 {
	w := p.web
	if w.window != 0 && object_get(p, w.window) != nil { return w.window }
	w.window = object_create(p, &window_vt, nil, owner)
	return w.window
}

// Fires `ev` at the Window, if a script ever asked for it (nobody can be listening otherwise).
fire_window_event :: proc(p: ^Page, ev: dom.Event) {
	w := p.web
	if w.window == 0 || object_get(p, w.window) == nil { return }
	object_dispatch(p, w.window, ev)
}

@(private)
set_history_state :: proc(p: ^Page, state: string, has_state: bool) {
	w := p.web
	delete(w.history_state)
	w.history_state = strings.clone(state) if has_state else ""
	w.has_state = has_state
}

// Same-document URL change: the origin does not change (callers check), so only the location is replaced.
@(private)
set_document_url :: proc(p: ^Page, href: string) -> bool {
	u, ok := url.parse(href, nil)
	if !ok { return false }
	url.destroy(&p.env.location)
	p.env.location = u
	return true
}

@(private)
Nav_Task :: struct {
	kind:  Navigate_Kind,
	url:   string,
	delta: int,
}

// Hands a navigation to the embedder from a task of its own.
@(private)
request_navigation :: proc(p: ^Page, kind: Navigate_Kind, href: string, delta := 0) {
	t := new(Nav_Task)
	t^ = Nav_Task{kind = kind, url = strings.clone(href), delta = delta}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Nav_Task)(data)
		defer { delete(t.url); free(t) }
		if pg == nil { return }
		if t.kind == .Traverse {
			switch history_traverse(pg, t.delta) {
			case .None: return
			case .Same_Document: notify_url_changed(pg); return
			case .Other_Document:
			}
		}
		emb := pg.web.embedder
		if emb.navigate == nil {
			log(pg, .Warn, "navigation requested, but this document has no browsing context to navigate")
			return
		}
		emb.navigate(emb.user, pg, Navigate_Request{kind = t.kind, url = t.url, delta = t.delta})
	}, t)
}

@(private)
notify_url_changed :: proc(p: ^Page) {
	emb := p.web.embedder
	if emb.navigate != nil { emb.navigate(emb.user, p, Navigate_Request{kind = .Url_Changed, url = p.env.location.href}) }
}

// HTML "navigate to a fragment": same document, new entry (or replaced), history.state becomes null, hashchange.
@(private)
navigate_fragment :: proc(p: ^Page, target: url.URL, replace: bool) {
	old := strings.clone(p.env.location.href, context.temp_allocator)
	sh := p.web.session
	if replace { session_replace(sh, target.href) } else { session_push(sh, target.href, p.web.id, dedupe = false, max_entries = p.settings.web.history_max_entries) }
	set_document_url(p, target.href)
	set_history_state(p, "", false)
	queue_hashchange(p, old, target.href)
	notify_url_changed(p)
}

@(private)
Hash_Task :: struct { old_url, new_url: string }

@(private)
queue_hashchange :: proc(p: ^Page, old_url, new_url: string) {
	ou, ok1 := url.parse(old_url, nil, context.temp_allocator)
	nu, ok2 := url.parse(new_url, nil, context.temp_allocator)
	if !ok1 || !ok2 || ou.fragment == nu.fragment && ou.has_fragment == nu.has_fragment { return }
	t := new(Hash_Task)
	t^ = Hash_Task{strings.clone(old_url), strings.clone(new_url)}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Hash_Task)(data)
		defer { delete(t.old_url); delete(t.new_url); free(t) }
		if pg == nil { return }
		push_event_detail(pg, Event_Detail{type = "hashchange", old_value = t.old_url, new_value = t.new_url, url = t.new_url})
		fire_window_event(pg, dom.Event{type = "hashchange", data = t.new_url, text = t.old_url})
		if !pg.closed { pop_event_detail(pg) }
	}, t)
}

// location.assign / replace / href setter: a fragment navigation stays in the document, anything else goes to the embedder.
@(private)
location_navigate :: proc(p: ^Page, target: url.URL, replace: bool) {
	cur := p.env.location
	if target.has_fragment && url.without_fragment(target) == url.without_fragment(cur) {
		navigate_fragment(p, target, replace)
		return
	}
	request_navigation(p, replace ? .Replace : .Assign, target.href)
}

Traverse_Result :: enum u8 { None, Same_Document, Other_Document }

// history.go(delta) / back / forward. An entry of this document is reached here (popstate, and hashchange when only the
// fragment differs); for another document's entry nothing changes and the caller navigates (the shell does it for its
// back / forward buttons, the page asks the embedder for history.go).
history_traverse :: proc(p: ^Page, delta: int) -> Traverse_Result {
	if p == nil || p.closed || delta == 0 { return .None }
	sh := p.web.session
	target := session_peek(sh, delta)
	if target == nil { return .None }
	if target.doc != p.web.id { return .Other_Document }
	old := strings.clone(p.env.location.href, context.temp_allocator)
	sh.index += delta
	href := strings.clone(target.url, context.temp_allocator)
	state := strings.clone(target.state, context.temp_allocator)
	has_state := target.has_state
	set_document_url(p, href)
	set_history_state(p, state, has_state)
	push_event_detail(p, Event_Detail{type = "popstate", new_value = state, flags = has_state ? 0 : 4})
	fire_window_event(p, dom.Event{type = "popstate", data = state, code = has_state ? 1 : 0})
	if p.closed { return .Same_Document }
	pop_event_detail(p)
	ou, _ := url.parse(old, nil, context.temp_allocator)
	nu, _ := url.parse(href, nil, context.temp_allocator)
	if url.without_fragment(ou) == url.without_fragment(nu) { queue_hashchange(p, old, href) }
	return .Same_Document
}

// HTML "can have its URL rewritten" (pushState / replaceState).
can_rewrite_url :: proc(doc, target: url.URL) -> bool {
	if doc.scheme != target.scheme || doc.username != target.username || doc.password != target.password || doc.host != target.host || doc.port != target.port { return false }
	if target.scheme == "https" || target.scheme == "http" { return true }
	if target.scheme == "file" && doc.path != target.path { return false }
	return doc.path == target.path && doc.opaque_path == target.opaque_path
}

////////////////////////////////
// Imports

n_Window_self :: proc "c" (env: wasm.Exec_Env) -> u64 {
	context = ctx()
	return window_object(page_of(env), inst_of(env).index)
}

// The Document node (target of visibilitychange, readystatechange...).
n_Document_self :: proc "c" (env: wasm.Exec_Env) -> u64 {
	context = ctx()
	return u64(page_of(env).doc.root)
}

n_Location_get :: proc "c" (env: wasm.Exec_Env, component: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if component < 0 || component > i32(url.Component.Origin) { return i32(dom.Error.Invalid_Argument) }
	return out_string(url.component(page_of(env).env.location, url.Component(component), context.temp_allocator), buf, cap)
}

@(private)
location_assign :: proc(env: wasm.Exec_Env, s: string, replace: bool) -> i32 {
	p := page_of(env)
	if len(s) > p.settings.web.url_max_length { return WEB_ERR_TYPE }
	target, ok := url.parse(s, &p.env.location, context.temp_allocator)
	if !ok { return WEB_ERR_SYNTAX }
	location_navigate(p, target, replace)
	return 0
}

n_Location_assign :: proc "c" (env: wasm.Exec_Env, s: [^]u8, n: i32) -> i32 {
	context = ctx()
	return location_assign(env, str(s, n), false)
}

n_Location_replace :: proc "c" (env: wasm.Exec_Env, s: [^]u8, n: i32) -> i32 {
	context = ctx()
	return location_assign(env, str(s, n), true)
}

n_Location_reload :: proc "c" (env: wasm.Exec_Env) -> i32 {
	context = ctx()
	p := page_of(env)
	request_navigation(p, .Reload, p.env.location.href)
	return 0
}

// location.protocol = ..., location.hash = ... (component numbers of url.Component; href behaves like assign).
n_Location_set :: proc "c" (env: wasm.Exec_Env, component: i32, value: [^]u8, n: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	v := str(value, n)
	if component == i32(url.Component.Href) { return location_assign(env, v, false) }
	if component < 0 || component >= i32(url.Component.Origin) { return i32(dom.Error.Invalid_Argument) }
	if len(v) > p.settings.web.url_max_length { return WEB_ERR_TYPE }
	c := url.Component(component)
	nu, res := url.set_component(p.env.location, c, v, context.temp_allocator)
	if res != .Ok { return WEB_ERR_SYNTAX }
	if c == .Hash && nu.fragment == p.env.location.fragment && nu.has_fragment == p.env.location.has_fragment { return 0 }
	// a protocol change to something that is not http(s) is ignored (Location protocol setter)
	if c == .Protocol && nu.scheme != "http" && nu.scheme != "https" { return 0 }
	location_navigate(p, nu, false)
	return 0
}

n_History_length :: proc "c" (env: wasm.Exec_Env) -> i32 {
	context = ctx()
	return i32(session_length(page_of(env).web.session))
}

// history.state: Not_Found when it is null.
n_History_state :: proc "c" (env: wasm.Exec_Env, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	w := page_of(env).web
	if !w.has_state { return i32(dom.Error.Not_Found) }
	return out_string(w.history_state, buf, cap)
}

@(private)
history_change :: proc(env: wasm.Exec_Env, state: string, has_state: bool, u: string, has_url: bool, replace: bool) -> i32 {
	p := page_of(env)
	s := &p.settings.web
	if has_state && len(state) > s.history_max_state_bytes { return WEB_ERR_DATA_CLONE }
	if len(u) > s.url_max_length { return WEB_ERR_TYPE }
	target := p.env.location
	if has_url {
		ok: bool
		target, ok = url.parse(u, &p.env.location, context.temp_allocator)
		if !ok { return WEB_ERR_SYNTAX }
		if !can_rewrite_url(p.env.location, target) { return WEB_ERR_SECURITY }
	}
	href := strings.clone(target.href, context.temp_allocator)
	sh := p.web.session
	if replace {
		session_replace(sh, href, state, has_state)
	} else {
		session_push(sh, href, p.web.id, state, has_state, dedupe = false, max_entries = s.history_max_entries)
	}
	set_document_url(p, href)
	set_history_state(p, state, has_state)
	notify_url_changed(p)
	return 0
}

n_History_pushState :: proc "c" (env: wasm.Exec_Env, state: [^]u8, sl: i32, has_state: i32, u: [^]u8, ul: i32, has_url: i32) -> i32 {
	context = ctx()
	return history_change(env, str(state, sl), has_state != 0, str(u, ul), has_url != 0, false)
}

n_History_replaceState :: proc "c" (env: wasm.Exec_Env, state: [^]u8, sl: i32, has_state: i32, u: [^]u8, ul: i32, has_url: i32) -> i32 {
	context = ctx()
	return history_change(env, str(state, sl), has_state != 0, str(u, ul), has_url != 0, true)
}

// history.go(delta); back() is go(-1), forward() go(1), go(0) reloads. Asynchronous, as in HTML.
n_History_go :: proc "c" (env: wasm.Exec_Env, delta: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	if delta == 0 {
		request_navigation(p, .Reload, p.env.location.href)
	} else {
		request_navigation(p, .Traverse, "", int(delta))
	}
	return 0
}

history_symbols := [?]wasm.Native_Symbol{
	{"Window_self", rawptr(n_Window_self), "()I", nil},
	{"Document_self", rawptr(n_Document_self), "()I", nil},
	{"Location_get", rawptr(n_Location_get), "(i*~)i", nil},
	{"Location_set", rawptr(n_Location_set), "(i*~)i", nil},
	{"Location_assign", rawptr(n_Location_assign), "(*~)i", nil},
	{"Location_replace", rawptr(n_Location_replace), "(*~)i", nil},
	{"Location_reload", rawptr(n_Location_reload), "()i", nil},
	{"History_length", rawptr(n_History_length), "()i", nil},
	{"History_state", rawptr(n_History_state), "(*~)i", nil},
	{"History_pushState", rawptr(n_History_pushState), "(*~i*~i)i", nil},
	{"History_replaceState", rawptr(n_History_replaceState), "(*~i*~i)i", nil},
	{"History_go", rawptr(n_History_go), "(i)i", nil},
}

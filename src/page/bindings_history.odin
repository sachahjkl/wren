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
	nav_state: string,
	has_nav_state: bool,
}

// Hands a navigation to the embedder from a task of its own (`nav_state`: the Navigation API state of its entry).
@(private)
request_navigation :: proc(p: ^Page, kind: Navigate_Kind, href: string, delta := 0, nav_state := "", has_nav_state := false) {
	t := new(Nav_Task)
	t^ = Nav_Task{kind = kind, url = strings.clone(href), delta = delta, nav_state = strings.clone(nav_state), has_nav_state = has_nav_state}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Nav_Task)(data)
		defer { delete(t.url); delete(t.nav_state); free(t) }
		if pg == nil { return }
		if t.kind == .Traverse {
			switch history_traverse(pg, t.delta) {
			case .None, .Canceled: return
			case .Same_Document: notify_url_changed(pg); return
			case .Other_Document:
			}
		}
		emb := pg.web.embedder
		if emb.navigate == nil {
			log(pg, .Warn, "navigation requested, but this document has no browsing context to navigate")
			return
		}
		emb.navigate(emb.user, pg, Navigate_Request{kind = t.kind, url = t.url, delta = t.delta, nav_state = t.nav_state, has_nav_state = t.has_nav_state})
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
	if !replace { entry_leaving(p) }
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

// A link followed by the user (the shell's default action of <a>): a fragment of this document stays in it (new history
// entry, hashchange); true when handled here, false when the shell has to load another document.
follow_fragment_link :: proc(p: ^Page, target: url.URL) -> bool {
	if p == nil || p.web == nil || !target.has_fragment { return false }
	if url.without_fragment(target) != url.without_fragment(p.env.location) { return false }
	location_navigate(p, target, false, user = true)
	return true
}

// location.assign / replace / href setter, navigation.navigate (`opts`), a fragment link (`user`): the navigate event
// first (navigation.odin); then a fragment navigation stays in the document, anything else goes to the embedder.
@(private)
location_navigate :: proc(p: ^Page, target: url.URL, replace: bool, user := false, opts: Nav_Options = {}) {
	if follow_javascript_url(p, target) { return }   // javascript: runs in this document (js_load_realm.odin)
	cur := p.env.location
	fragment := target.has_fragment && url.without_fragment(target) == url.without_fragment(cur)
	pend := Nav_Pending{
		type = replace ? .Replace : .Push, url = target.href, same_document = fragment, user_initiated = user,
		hash_change = fragment && (target.fragment != cur.fragment || !cur.has_fragment),
		can_intercept = can_rewrite_url(cur, target), cancelable = true, state = opts.state, has_state = opts.has_state,
	}
	switch navigation_fire(p, &pend) {
	case .Canceled: return
	case .Intercepted:
		navigation_commit_url(p, target.href, replace, opts)
		navigation_committed(p, pend.type, true)
		return
	case .Proceed:
	}
	if fragment {
		navigate_fragment(p, target, replace)
		session_set_nav_state(p.web.session, opts.state, opts.has_state)
		navigation_committed(p, pend.type, false)
		return
	}
	request_navigation(p, replace ? .Replace : .Assign, target.href, nav_state = opts.state, has_nav_state = opts.has_state)
}

// Canceled: a listener of navigate cancelled the traversal (nothing changed).
Traverse_Result :: enum u8 { None, Same_Document, Other_Document, Canceled }

// The embedder saves what the current entry shows before the document moves to another of its entries.
@(private)
entry_leaving :: proc(p: ^Page) {
	emb := p.web.embedder
	if cur := session_current(p.web.session); cur != nil && emb.leaving != nil { emb.leaving(emb.user, p, cur) }
}

// history.go(delta) / back / forward. An entry of this document is reached here (popstate, and hashchange when only the
// fragment differs); for another document's entry nothing changes and the caller navigates (the shell does it for its
// back / forward buttons, the page asks the embedder for history.go).
history_traverse :: proc(p: ^Page, delta: int) -> Traverse_Result {
	if p == nil || p.closed || delta == 0 { return .None }
	return history_traverse_to(p, session_peek(p.web.session, delta), user = false)
}

// The same towards any entry of the tab's history tree (the interface's tree view): it becomes the current one, and the
// path to it the active one, when it belongs to this document. `user`: the browser's buttons (navigate's userInitiated).
history_traverse_to :: proc(p: ^Page, target: ^History_Entry, user := true) -> Traverse_Result {
	if p == nil || p.closed || target == nil { return .None }
	sh := p.web.session
	if target == session_current(sh) { return .None }
	if target.doc != p.web.id { return .Other_Document }
	old := strings.clone(p.env.location.href, context.temp_allocator)
	target := target
	{
		ou, _ := url.parse(old, nil, context.temp_allocator)
		tu, _ := url.parse(target.url, nil, context.temp_allocator)
		pend := Nav_Pending{
			type = .Traverse, url = strings.clone(target.url, context.temp_allocator), dest = target, same_document = true, user_initiated = user,
			hash_change = url.without_fragment(ou) == url.without_fragment(tu) && ou.fragment != tu.fragment,
			can_intercept = true, cancelable = true, state = strings.clone(target.nav_state, context.temp_allocator), has_state = target.has_nav_state,
		}
		id := target.id
		verdict := navigation_fire(p, &pend)
		if verdict == .Canceled { return .Canceled }
		// (a listener may have changed the history: the entry is looked up again)
		if target = session_find(sh, id); target == nil || target == session_current(sh) || target.doc != p.web.id { return .None }
		entry_leaving(p)
		session_goto(sh, target)
		set_document_url(p, target.url)
		set_history_state(p, target.state, target.has_state)
		navigation_committed(p, .Traverse, verdict == .Intercepted)   // currententrychange before popstate (HTML)
		if p.closed || session_current(sh) != target { return .Same_Document }
	}
	href := strings.clone(target.url, context.temp_allocator)
	state := strings.clone(target.state, context.temp_allocator)
	has_state := target.has_state
	push_event_detail(p, Event_Detail{type = "popstate", new_value = state, flags = has_state ? 0 : 4})
	fire_window_event(p, dom.Event{type = "popstate", data = state, code = has_state ? 1 : 0})
	if p.closed { return .Same_Document }
	pop_event_detail(p)
	if emb := p.web.embedder; emb.entered != nil && session_current(sh) == target { emb.entered(emb.user, p, target) }
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

Window_self :: proc(c: ^Call) -> u64 { return window_object(c.page, c.owner) }

// The Document node (target of visibilitychange, readystatechange...).
Document_self :: proc(c: ^Call) -> u64 { return u64(c.page.doc.root) }

Location_get :: proc(c: ^Call, component: Api_URLComponent) -> string {
	return url.component(c.page.env.location, url.Component(component), context.temp_allocator)
}

@(private)
location_assign :: proc(c: ^Call, s: string, replace: bool) -> Api_Error {
	p := c.page
	if len(s) > p.settings.web.url_max_length { return fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	target, ok := url.parse(s, &p.env.location, context.temp_allocator)
	if !ok { return fail(c, .Syntax, "SyntaxError: invalid URL") }
	location_navigate(p, target, replace)
	return .None
}

Location_assign :: proc(c: ^Call, target: string) -> Api_Error { return location_assign(c, target, false) }
Location_replace :: proc(c: ^Call, target: string) -> Api_Error { return location_assign(c, target, true) }

Location_reload :: proc(c: ^Call) { navigation_reload(c.page, {}) }

// location.protocol = ..., location.hash = ... (href behaves like assign).
Location_set :: proc(c: ^Call, component: Api_URLComponent, value: string) -> Api_Error {
	p := c.page
	if component == .Href { return location_assign(c, value, false) }
	if component == .Origin { return fail(c, .Invalid_Argument, "origin is read-only") }
	if len(value) > p.settings.web.url_max_length { return fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	uc := url.Component(component)
	nu, res := url.set_component(p.env.location, uc, value, context.temp_allocator)
	if res != .Ok { return fail(c, .Syntax, "SyntaxError: invalid value") }
	if uc == .Hash && nu.fragment == p.env.location.fragment && nu.has_fragment == p.env.location.has_fragment { return .None }
	// a protocol change to something that is not http(s) is ignored (Location protocol setter)
	if uc == .Protocol && nu.scheme != "http" && nu.scheme != "https" { return .None }
	location_navigate(p, nu, false)
	return .None
}

History_length :: proc(c: ^Call) -> i32 { return i32(session_length(c.page.web.session)) }

// history.state: Not_Found when it is null.
History_state :: proc(c: ^Call) -> (string, Api_Error) {
	w := c.page.web
	if !w.has_state { return "", .Not_Found }
	return w.history_state, .None
}

@(private)
history_change :: proc(c: ^Call, state_arg, url_arg: Maybe(string), replace: bool) -> Api_Error {
	p := c.page
	s := &p.settings.web
	state, has_state := state_arg.?
	u, has_url := url_arg.?
	if has_state && len(state) > s.history_max_state_bytes { return fail(c, .Data_Clone, "DataCloneError: the state is over history.max_state_bytes") }
	if len(u) > s.url_max_length { return fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	target := p.env.location
	if has_url {
		ok: bool
		target, ok = url.parse(u, &p.env.location, context.temp_allocator)
		if !ok { return fail(c, .Syntax, "SyntaxError: invalid URL") }
		if !can_rewrite_url(p.env.location, target) { return fail(c, .Security, "SecurityError: the document's URL cannot be rewritten to this one") }
	}
	href := strings.clone(target.href, context.temp_allocator)
	sh := p.web.session
	// the navigate event first (cancelable, interceptable); the new entry keeps the Navigation API state of the current one
	state = strings.clone(state, context.temp_allocator)   // (guest memory: the listeners may grow it)
	nav_state: string
	has_nav_state: bool
	if cur := session_current(sh); cur != nil { nav_state, has_nav_state = strings.clone(cur.nav_state, context.temp_allocator), cur.has_nav_state }
	pend := Nav_Pending{type = replace ? .Replace : .Push, url = href, same_document = true, can_intercept = true, cancelable = true, state = nav_state, has_state = has_nav_state}
	verdict := navigation_fire(p, &pend)
	if verdict == .Canceled || p.closed { return .None }
	if replace {
		session_replace(sh, href, state, has_state)
	} else {
		entry_leaving(p)
		session_push(sh, href, p.web.id, state, has_state, dedupe = false, max_entries = s.history_max_entries)
	}
	session_set_nav_state(sh, nav_state, has_nav_state)
	set_document_url(p, href)
	set_history_state(p, state, has_state)
	notify_url_changed(p)
	navigation_committed(p, pend.type, verdict == .Intercepted)
	return .None
}

History_pushState :: proc(c: ^Call, state, target: Maybe(string)) -> Api_Error { return history_change(c, state, target, false) }
History_replaceState :: proc(c: ^Call, state, target: Maybe(string)) -> Api_Error { return history_change(c, state, target, true) }

// history.scrollRestoration: a property of the current entry (HTML "scroll restoration mode"); pushState copies it to
// the entry it adds.
History_scrollRestoration :: proc(c: ^Call) -> Api_ScrollRestoration {
	cur := session_current(c.page.web.session)
	return cur != nil && cur.scroll_manual ? .Manual : .Auto
}

History_set_scrollRestoration :: proc(c: ^Call, mode: Api_ScrollRestoration) {
	if cur := session_current(c.page.web.session); cur != nil { cur.scroll_manual = mode == .Manual }
}

// history.go(delta); back() is go(-1), forward() go(1), go(0) reloads. Asynchronous, as in HTML.
History_go :: proc(c: ^Call, delta: i32) {
	p := c.page
	if delta == 0 {
		navigation_reload(p, {})
	} else {
		request_navigation(p, .Traverse, "", int(delta))
	}
}
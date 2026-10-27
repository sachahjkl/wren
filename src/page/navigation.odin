package page

// The Navigation API (HTML "navigation API", import module "navigation"): window.navigation over the tab's session
// history (history.odin).
//
// The browser keeps what the API shows: the entries (the same-origin run of the path the web sees around the current
// entry; key = History_Entry.id, id = History_Entry.nav_id, new when an entry is replaced), the state of each entry
// (navigation.navigate({state}), updateCurrentEntry), and every navigation. The engine (native/js/runtime/
// web_navigation.c) keeps the JavaScript objects: NavigationHistoryEntry wrappers, the NavigateEvent and what
// intercept() was given, the promises of navigate() / reload() / traverseTo(), navigation.transition.
//
// Every navigation of the document goes through here before it happens: location (assign, replace, href, hash...),
// history.pushState / replaceState, history.go / back / forward, the browser's back and forward buttons on an entry of
// this document, links the user follows, navigation.navigate / reload / traverseTo:
//   1. navigation_fire calls the engine's wj_nav_fire, which reads the navigation (Navigation_pending) and fires
//      `navigate`. A listener may cancel it (preventDefault: nothing happens) or intercept it (intercept(): the browser
//      makes it a same-document navigation, whatever its URL, and the document's handlers do the work);
//   2. the browser commits it: a same-document change here (a new or replaced entry, the URL, popstate for a
//      traversal), or a navigation handed to the embedder (another document: the engine's promises never settle, the
//      document goes away);
//   3. navigation_committed calls the engine's wj_nav_commit after a same-document commit: currententrychange, the
//      intercept handlers, then navigatesuccess / navigateerror when their promises settle.
// Cross-document traversals fire no navigate event (HTML), and a document without a realm (scripts off) skips 1 and 3.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:url"
import "wb:wasm"

Nav_Type :: enum u8 { Push, Replace, Reload, Traverse }   // NavigationType, in the engine's order
Nav_Verdict :: enum u8 { Proceed, Canceled, Intercepted }

// What navigation.navigate() / reload() add to the navigation they start: the new entry's Navigation API state.
Nav_Options :: struct {
	state:     string,   // valid during the call
	has_state: bool,
}

// The navigation whose navigate event is being fired (Navigation_pending reads it).
Nav_Pending :: struct {
	type:           Nav_Type,
	url:            string,
	dest:           ^History_Entry,   // a traversal's entry, nil otherwise (destination.key "" and index -1)
	same_document:  bool,
	user_initiated: bool,
	hash_change:    bool,
	can_intercept:  bool,
	cancelable:     bool,
	state:          string,           // the destination's Navigation API state (getState())
	has_state:      bool,
}

// The realm of the document, if it has one now (the API is never what starts one).
@(private)
nav_realm :: proc(p: ^Page) -> ^wasm.Instance {
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead || p.closed || p.worker != nil || p.web == nil || p.web.frozen { return nil }
	return r.inst
}

// Fires navigate for `pend`. Proceed when nothing listens or nobody objected.
navigation_fire :: proc(p: ^Page, pend: ^Nav_Pending) -> Nav_Verdict {
	inst := nav_realm(p)
	if inst == nil { return .Proceed }
	w := p.web
	prev := w.nav_pending
	w.nav_pending = pend
	argv := [1]u32{0}
	res := call_export(p, inst, "wj_nav_fire", argv[:])
	if !p.closed { w.nav_pending = prev }
	if p.closed { return .Canceled }   // (a listener closed the document: nothing more to do for it)
	if res != .Ok { return .Proceed }
	switch argv[0] {
	case 1: return .Canceled
	case 2: return .Intercepted
	}
	return .Proceed
}

// A same-document navigation of `type` was committed: currententrychange, then the intercept handlers when
// `intercepted`, then navigatesuccess (the engine's own steps).
navigation_committed :: proc(p: ^Page, type: Nav_Type, intercepted: bool) {
	inst := nav_realm(p)
	if inst == nil { return }
	argv := [1]u32{u32(type) << 1 | (intercepted ? 1 : 0)}
	call_export(p, inst, "wj_nav_commit", argv[:])
}

// An intercepted push / replace towards any URL the document can be rewritten to: a same-document change, like
// pushState, with a null history.state and the navigation's own state.
@(private)
navigation_commit_url :: proc(p: ^Page, href: string, replace: bool, opts: Nav_Options) {
	sh := p.web.session
	if replace {
		session_replace(sh, href)
	} else {
		entry_leaving(p)
		session_push(sh, href, p.web.id, dedupe = false, max_entries = p.settings.web.history_max_entries)
	}
	session_set_nav_state(sh, opts.state, opts.has_state)
	set_document_url(p, href)
	set_history_state(p, "", false)
	notify_url_changed(p)
}

// A link the user follows to another document (the shell's default action of <a>, before it loads anything): the
// navigate event may cancel it or intercept it. True when the document took it (the shell then does nothing more).
navigation_link :: proc(p: ^Page, target: url.URL) -> bool {
	if p == nil || p.web == nil || p.closed { return false }
	pend := Nav_Pending{type = .Push, url = target.href, user_initiated = true, can_intercept = can_rewrite_url(p.env.location, target), cancelable = true}
	switch navigation_fire(p, &pend) {
	case .Proceed: return false
	case .Canceled: return true
	case .Intercepted:
		navigation_commit_url(p, target.href, false, {})
		navigation_committed(p, .Push, true)
	}
	return true
}

// A link a script clicked (element.click(), forms' activation behaviour of <a> / <area>): followed in this document's
// browsing context as a link the user follows is by the shell, after the navigate event. A download link (the shell's
// downloads) and a link to another browsing context (`target` other than _self) are left alone, as before.
navigation_follow_script_link :: proc(p: ^Page, link: base.Handle) {
	if p == nil || p.closed || p.web == nil { return }
	href, ok := dom.get_attribute(p.doc, link, "href")
	if !ok { return }
	if _, dl := dom.get_attribute(p.doc, link, "download"); dl { return }
	if target, has := dom.get_attribute(p.doc, link, "target"); has && target != "" && !strings.equal_fold(target, "_self") { return }
	base_href := document_base_url(p)
	base_url, bok := url.parse(base_href, nil, context.temp_allocator)
	if !bok { return }
	u, uok := url.parse(strings.clone(href, context.temp_allocator), &base_url, context.temp_allocator)
	if !uok { return }
	location_navigate(p, u, false)
}

// location.reload(), history.go(0), navigation.reload(): an intercepted reload keeps the document.
@(private)
navigation_reload :: proc(p: ^Page, opts: Nav_Options) {
	sh := p.web.session
	cur := session_current(sh)
	state, has_state := opts.state, opts.has_state
	if !has_state && cur != nil { state, has_state = strings.clone(cur.nav_state, context.temp_allocator), cur.has_nav_state }
	pend := Nav_Pending{type = .Reload, url = p.env.location.href, can_intercept = true, cancelable = true, state = state, has_state = has_state}
	switch navigation_fire(p, &pend) {
	case .Canceled: return
	case .Intercepted:
		if opts.has_state { session_set_nav_state(sh, opts.state, true) }
		navigation_committed(p, .Reload, true)
		return
	case .Proceed:
	}
	request_navigation(p, .Reload, p.env.location.href, nav_state = state, has_nav_state = has_state)
}

// The entries the API shows: the run of same-origin entries of the path the web sees around the current one (none for
// a document with an opaque origin), and the current one's place in it.
@(private)
nav_entries :: proc(p: ^Page) -> (list: []^History_Entry, current: int) {
	sh := p.web.session
	if sh == nil || sh.index < 0 || sh.index >= len(sh.entries) || p.env.origin.opaque { return nil, -1 }
	same :: proc(p: ^Page, e: ^History_Entry) -> bool {
		if e.doc != 0 && e.doc == p.web.id { return true }
		u, ok := url.parse(e.url, nil, context.temp_allocator)
		return ok && url.same_origin(url.origin_of(u, context.temp_allocator), p.env.origin)
	}
	lo, hi := sh.index, sh.index
	for lo > 0 && same(p, sh.entries[lo - 1]) { lo -= 1 }
	for hi + 1 < len(sh.entries) && same(p, sh.entries[hi + 1]) { hi += 1 }
	return sh.entries[lo:hi + 1], sh.index - lo
}

@(private)
nav_index_of :: proc(p: ^Page, e: ^History_Entry) -> int {
	list, _ := nav_entries(p)
	for x, i in list { if x == e { return i } }
	return -1
}

////////////////////////////////
// Imports

// navigation.entries() / currentEntry: "<current index>\n" then one "<key> <id> <same document 0|1> <url>\n" per entry
// (a URL never holds a space or a line break).
Navigation_entries :: proc(c: ^Call) -> string {
	p := c.page
	list, cur := nav_entries(p)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d\n", cur)
	for e in list { fmt.sbprintf(&b, "%d %d %d %s\n", e.id, e.nav_id, e.doc != 0 && e.doc == p.web.id ? 1 : 0, e.url) }
	return strings.to_string(b)
}

// Bumped by every change of the session history: the engine reads the entries again only then.
Navigation_serial :: proc(c: ^Call) -> i64 {
	sh := c.page.web.session
	return sh != nil ? i64(sh.serial) : 0
}

// entry.getState(): the state of the entry `key` while it is still `id`; Not_Found when it has none (undefined).
Navigation_getState :: proc(c: ^Call, key, id: i64) -> (string, Api_Error) {
	list, _ := nav_entries(c.page)
	for e in list {
		if e.id != u64(key) { continue }
		if e.nav_id != u64(id) || !e.has_nav_state { return "", .Not_Found }
		return e.nav_state, .None
	}
	return "", .Not_Found
}

// navigation.updateCurrentEntry({state}): Data_Clone past history.max_state_bytes, Invalid_State without entries.
Navigation_updateCurrentEntry :: proc(c: ^Call, state: string) -> Api_Error {
	p := c.page
	if len(state) > p.settings.web.history_max_state_bytes { return fail(c, .Data_Clone, "DataCloneError: the state is over history.max_state_bytes") }
	if _, cur := nav_entries(p); cur < 0 { return fail(c, .Invalid_State, "InvalidStateError: the document has no current entry") }
	session_set_nav_state(p.web.session, state, true)
	return .None
}

Nav_History :: enum i32 { Auto, Push, Replace }

// navigation.navigate(url, {state, history}): Syntax for an invalid URL, Not_Supported for a push to a javascript: URL,
// Data_Clone past history.max_state_bytes. The navigate event fires inside the call.
Navigation_navigate :: proc(c: ^Call, target: string, state: Maybe(string), history: i32) -> Api_Error {
	p := c.page
	s := &p.settings.web
	if len(target) > s.url_max_length { return fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	st, has_state := state.?
	if has_state && len(st) > s.history_max_state_bytes { return fail(c, .Data_Clone, "DataCloneError: the state is over history.max_state_bytes") }
	u, ok := url.parse(target, &p.env.location, context.temp_allocator)
	if !ok { return fail(c, .Syntax, "SyntaxError: invalid URL") }
	if u.scheme == "javascript" && Nav_History(history) == .Push { return fail(c, .Not_Supported, "NotSupportedError: a javascript: URL cannot be pushed") }
	// "auto" replaces the entry when it goes to the URL the document already has
	replace := Nav_History(history) == .Replace || Nav_History(history) == .Auto && u.href == p.env.location.href
	// (copied out of the guest's memory: the navigate listeners may grow it)
	location_navigate(p, u, replace, opts = Nav_Options{state = strings.clone(st, context.temp_allocator), has_state = has_state})
	return .None
}

// navigation.reload({state}): without a state, the entry keeps its own.
Navigation_reload :: proc(c: ^Call, state: Maybe(string)) -> Api_Error {
	p := c.page
	st, has_state := state.?
	if has_state && len(st) > p.settings.web.history_max_state_bytes { return fail(c, .Data_Clone, "DataCloneError: the state is over history.max_state_bytes") }
	navigation_reload(p, Nav_Options{state = strings.clone(st, context.temp_allocator), has_state = has_state})
	return .None
}

// navigation.traverseTo(key) (back() and forward() too): Invalid_State when no entry of navigation.entries() has
// this key. The traversal happens from a task of its own, as history.go does.
Navigation_traverseTo :: proc(c: ^Call, key: i64) -> Api_Error {
	p := c.page
	list, _ := nav_entries(p)
	for e in list {
		if e.id != u64(key) { continue }
		delta, ok := session_delta_of(p.web.session, e)
		if !ok { break }
		if delta != 0 { request_navigation(p, .Traverse, "", delta) }
		return .None
	}
	return fail(c, .Invalid_State, "InvalidStateError: no entry of navigation.entries() has this key")
}

// The navigation being fired: "<type> <flags> <key> <id> <index> <url>"; flags: 1 same document, 2 user initiated,
// 4 hash change, 8 can intercept, 16 cancelable, 32 has a state. Not_Found outside wj_nav_fire.
Navigation_pending :: proc(c: ^Call) -> (string, Api_Error) {
	p := c.page
	n := p.web.nav_pending
	if n == nil { return "", .Not_Found }
	flags := 0
	if n.same_document { flags |= 1 }
	if n.user_initiated { flags |= 2 }
	if n.hash_change { flags |= 4 }
	if n.can_intercept { flags |= 8 }
	if n.cancelable { flags |= 16 }
	if n.has_state { flags |= 32 }
	key, id, index: i64 = 0, 0, -1
	if n.dest != nil { key, id, index = i64(n.dest.id), i64(n.dest.nav_id), i64(nav_index_of(p, n.dest)) }
	return fmt.tprintf("%d %d %d %d %d %s", int(n.type), flags, key, id, index, n.url), .None
}

// destination.getState() of the navigation being fired: Not_Found when it has none.
Navigation_pendingState :: proc(c: ^Call) -> (string, Api_Error) {
	n := c.page.web.nav_pending
	if n == nil || !n.has_state { return "", .Not_Found }
	return n.state, .None
}

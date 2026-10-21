package page

// Per-page state of the "platform" web APIs (timers and animation frames, abort signals, promise fetch, encoding, crypto,
// storage, URL, performance, location / history), and what they need from the embedder.
//
// Each API lives in its own bindings_<area>.odin file; this file holds what they share:
//   * the registry of live pages: work that finishes later (a digest on a worker thread, a storage event for another
//     page, a navigation requested by a script) refers to a page by id and finds out whether it still exists;
//   * the error codes beyond dom.Error (Web IDL exceptions and DOMException names), the same for every area;
//   * the Embedder: what the shell supplies (navigation, the tab's session history, the profile's storage).

import "base:runtime"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:url"

// Negative results of the web API imports, after the dom.Error range. Promise rejections use the same codes.
WEB_ERR_TYPE          :: -10   // TypeError
WEB_ERR_RANGE         :: -11   // RangeError
WEB_ERR_SECURITY      :: -12   // SecurityError
WEB_ERR_QUOTA         :: -13   // QuotaExceededError
WEB_ERR_NOT_SUPPORTED :: -14   // NotSupportedError
WEB_ERR_SYNTAX        :: -15   // SyntaxError
WEB_ERR_ABORT         :: -16   // AbortError
WEB_ERR_TIMEOUT       :: -17   // TimeoutError
WEB_ERR_INVALID_STATE :: -18   // InvalidStateError
WEB_ERR_DATA_CLONE    :: -19   // DataCloneError
WEB_ERR_NETWORK       :: -20   // NetworkError (fetch failures; the promise text says why)
WEB_ERR_ENCODING      :: -21   // EncodingError

// What a script asks the embedder to do with its tab. Navigations always reach the hook from a task of their own,
// never from inside a guest call: the hook may close the page.
Navigate_Kind :: enum u8 {
	Assign,        // location.assign / href setter: a new entry
	Replace,       // location.replace: replaces the current entry
	Reload,
	Traverse,      // history.go(delta) towards an entry of another document
	Url_Changed,   // same-document change (pushState, replaceState, fragment): the session history already has it
}

Navigate_Request :: struct {
	kind:  Navigate_Kind,
	url:   string,   // absolute, valid during the call
	delta: int,      // Traverse
}

Navigate_Hook :: #type proc(user: rawptr, p: ^Page, req: Navigate_Request)

Embedder :: struct {
	navigate: Navigate_Hook,
	user:     rawptr,
	session:  ^Session_History,   // the tab's joint session history; nil = the page keeps a private one
	tab_key:  string,             // sessionStorage partition (copied); stable for the tab's lifetime
	storage:  ^Storage_Manager,   // the profile's Web Storage; nil = no Web Storage for this page
	print:    proc(user: rawptr, p: ^Page),   // window.print() (js_print.odin); nil = nothing to tell
	// The document leaves `entry` for another of its own entries (pushState, a fragment, a traversal): its persisted
	// state is saved now. Then `entered` after a same-document traversal: restore it. nil = nothing.
	leaving:  proc(user: rawptr, p: ^Page, entry: ^History_Entry),
	entered:  proc(user: rawptr, p: ^Page, entry: ^History_Entry),
}

Web_State :: struct {
	id:              u64,       // 0 for a worker's realm (not in the live-page registry)
	live:            bool,
	visible:         bool,
	origin_ns:       i64,       // loop clock at creation: performance.now() == 0
	origin_unix_ms:  f64,       // performance.timeOrigin
	timer_nesting:   int,       // nesting level of the timer task running now, 0 outside timer tasks
	frames:          [dynamic]Frame_Callback,
	running_frames:  ^[dynamic]Frame_Callback,
	next_frame_id:   u64,
	io_active:       bool,      // some IntersectionObserver watches a target: each rendering update computes them
	io_pending:      bool,      // ... and one is wanted soon (a target was just observed): a frame is requested
	idle:            [dynamic]Idle_Callback,
	next_idle_id:    u64,
	idle_timer:      base.Handle,
	window:          u64,       // the Window host object, created on first use
	embedder:        Embedder,
	own_session:     Session_History,
	session:         ^Session_History,
	history_state:   string,    // history.state of the current entry (owned)
	has_state:       bool,
	perf:            [dynamic]Perf_Entry,
	perf_warned:     bool,
	event_details:   [dynamic]Event_Detail,   // StorageEvent / PopStateEvent / HashChangeEvent fields while dispatching
	print_posted:    bool,      // a window.print() notice is on its way to the embedder (js_print.odin)
	frozen:          bool,      // in the back/forward cache: no task, timer or idle callback runs (bfcache.odin)
	frozen_timers:   [dynamic]base.Handle,   // timers that came due while frozen, run when thawed
	frozen_tasks:    [dynamic]rawptr,        // ^Page_Task posted while frozen, run when thawed
}

// Extra fields of an event being dispatched (dom.Event has two strings; a StorageEvent needs four).
Event_Detail :: struct {
	type:      string,
	key:       string,
	old_value: string,
	new_value: string,
	url:       string,
	area:      u64,
	flags:     u8,      // bit 0 key is null, bit 1 old value is null, bit 2 new value is null
}

@(private)
live_pages: map[u64]^Page
@(private)
next_page_id: u64

@(private)
// `live`: register the page in the registry of live pages (storage events, page_by_id). That registry belongs to the
// UI thread: a worker's realm, which runs on its own thread, gets the web state without being registered.
web_init :: proc(p: ^Page, live := true) {
	w := new(Web_State)
	p.web = w
	w.live = live
	if live {
		if live_pages == nil { live_pages = make(map[u64]^Page, runtime.heap_allocator()) }
		next_page_id += 1
		w.id = next_page_id
	}
	w.visible = true
	w.origin_ns = host.now_ns(p.loop)
	w.origin_unix_ms = f64(time.time_to_unix_nano(time.now())) / 1e6
	w.session = &w.own_session
	session_push(w.session, p.env.location.href, w.id, max_entries = p.settings.web.history_max_entries)
	if live { live_pages[w.id] = p }
}

// Runs before the objects and the DOM are freed: every web API releases what it holds outside the object registry.
@(private)
web_destroy :: proc(p: ^Page) {
	w := p.web
	if w == nil { return }
	if w.live { delete_key(&live_pages, w.id) }
	if w.idle_timer != base.NIL_HANDLE { host.clear_timer(p.loop, w.idle_timer) }
	storage_page_closed(p)
	for d in w.frozen_tasks {
		t := (^Page_Task)(d)
		t.fn(nil, t.data)   // the page is gone: the task frees its data
		free(t)
	}
	delete(w.frozen_tasks)
	delete(w.frozen_timers)
	delete(w.frames)
	delete(w.idle)
	delete(w.history_state)
	delete(w.embedder.tab_key)
	session_destroy(&w.own_session)
	perf_clear(p, "", .Mark); perf_clear(p, "", .Measure)
	delete(w.perf)
	delete(w.event_details)
	free(w)
	p.web = nil
}

// The live page with this id, nil once it is closed.
page_by_id :: proc(id: u64) -> ^Page {
	p, ok := live_pages[id]
	if !ok || p.closed { return nil }
	return p
}

// Every live page (storage events, tests). The slice is temporary.
live_page_list :: proc(allocator := context.temp_allocator) -> []^Page {
	out := make([dynamic]^Page, 0, len(live_pages), allocator)
	for _, p in live_pages { if !p.closed { append(&out, p) } }
	return out[:]
}

page_id :: proc(p: ^Page) -> u64 { return p.web.id if p.web != nil else 0 }

// Connects the page to its tab. Call right after page_create for a document that belongs to a tab. The current entry of
// the tab's session history becomes this document's, and its saved state (history.state) is restored.
set_embedder :: proc(p: ^Page, e: Embedder) {
	w := p.web
	delete(w.embedder.tab_key)
	w.embedder = e
	w.embedder.tab_key = clone_heap(e.tab_key)
	if e.session != nil {
		w.session = e.session
		if cur := session_current(w.session); cur != nil {
			cur.doc = w.id
			if cur.has_state { set_history_state(p, cur.state, true) }
		}
	}
	if e.storage != nil && p.settings.web.storage_local && !p.env.origin.opaque {
		storage_prefetch(e.storage, url.origin_serialize(p.env.origin, context.temp_allocator))
	}
}

// Same as set_embedder's navigate field, for embedders that only need navigation.
set_navigate_hook :: proc(p: ^Page, hook: Navigate_Hook, user: rawptr) {
	p.web.embedder.navigate = hook
	p.web.embedder.user = user
}

@(private)
clone_heap :: proc(s: string) -> string {
	if s == "" { return "" }
	b := make([]byte, len(s))
	copy(b, s)
	return string(b)
}

// Milliseconds on the page's performance timeline (performance.now()).
page_now_ms :: proc(p: ^Page) -> f64 {
	return f64(host.now_ns(p.loop) - p.web.origin_ns) / 1e6
}

////////////////////////////////
// Tasks that outlive the call that queued them

Page_Task_Proc :: #type proc(p: ^Page, data: rawptr)   // p == nil: the page closed first; free `data`

@(private)
Page_Task :: struct {
	id:   u64,
	fn:   Page_Task_Proc,
	data: rawptr,
}

// Queues `fn` as a task of the page on its loop. It runs with p == nil when the page closed meanwhile. A worker's realm
// (on its own thread, not in the registry of live pages) is followed through its scope instead of its id.
post_page_task :: proc(p: ^Page, fn: Page_Task_Proc, data: rawptr) {
	if p.web == nil || p.web.id == 0 {
		t := new(Realm_Task)
		t^ = Realm_Task{page = p, fn = fn, data = data}
		t.cleanup = base.on_close(p.scope, proc(d: rawptr) { (^Realm_Task)(d).dead = true }, t)
		host.post(p.loop, proc(d: rawptr) {
			t := (^Realm_Task)(d)
			defer free(t)
			if t.dead { t.fn(nil, t.data); return }
			base.forget_cleanup(t.page.scope, t.cleanup)
			t.fn(t.page, t.data)
		}, t)
		return
	}
	t := new(Page_Task)
	t^ = Page_Task{id = p.web.id, fn = fn, data = data}
	host.post(p.loop, run_page_task, t)
}

@(private)
Realm_Task :: struct {
	page:    ^Page,
	fn:      Page_Task_Proc,
	data:    rawptr,
	cleanup: base.Cleanup_Id,
	dead:    bool,
}

@(private)
run_page_task :: proc(data: rawptr) {
	t := (^Page_Task)(data)
	p := page_by_id(t.id)
	if p != nil && p.web.frozen {
		append(&p.web.frozen_tasks, rawptr(t))   // runs when the page is shown again (page_thaw)
		return
	}
	defer free(t)
	t.fn(p, t.data)
}

////////////////////////////////
// Event details

@(private)
push_event_detail :: proc(p: ^Page, d: Event_Detail) { append(&p.web.event_details, d) }

@(private)
pop_event_detail :: proc(p: ^Page) { if len(p.web.event_details) > 0 { pop(&p.web.event_details) } }

// The detail of the innermost event of `type` being dispatched, if the event handle is live.
@(private)
event_detail :: proc(p: ^Page, ev: u64) -> ^Event_Detail {
	e := base.pool_get(&p.dp.events, base.Handle(ev))
	if e == nil { return nil }
	for i := len(p.web.event_details) - 1; i >= 0; i -= 1 {
		if p.web.event_details[i].type == e.type { return &p.web.event_details[i] }
	}
	return nil
}

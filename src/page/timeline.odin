package page

// The document's Performance Timeline (api/performance.widl; native/js/runtime/web_perf.c makes the objects): the entries
// the browser itself records, as opposed to the marks and measures a page makes (bindings_performance.odin).
//
//   * navigation  (PerformanceNavigationTiming): one for the document. The shell gives what it measured of the load
//     (`set_navigation_timing`: when it started, when the answer's head and its end came); the page's own life cycle
//     (parsing done, DOMContentLoaded, load) is read from Script_Timing. The time origin moves back to the start of the
//     navigation, as in other browsers, so performance.now() at the first script is what the network and the parser took.
//     Connection steps (DNS, TCP, TLS) are not observable through the loader: they take no time of their own here
//     (domainLookup, connect: the fetch start; secureConnectionStart 0).
//   * resource    (PerformanceResourceTiming): one for each request a document's own scripts, styles, images, fonts and
//     frames made, from the loader's observers (fetch/observe.odin): started, answered, done. Failed and cancelled
//     requests make none. At most performance.resource_timing_entries are kept (the oldest go first, which also keeps
//     observers fed; browsers drop the newest and fire resourcetimingbufferfull).
//   * paint       (PerformancePaintTiming): first-paint and first-contentful-paint, when the shell painted the document
//     the first time (the shell has no finer test of "contentful": both have the same time).
//   * event, first-input (PerformanceEventTiming): input events whose listeners took long (dispatch_event measures them:
//     processingStart / End, the duration rounded up to 8 ms as the specification does) and the first one of any length.
//
// Entries have a sequence number; the engine asks for the ones after the last it saw (Performance_timeline) when it is
// told there are new ones (Performance_onTimeline), and only for the kinds a PerformanceObserver registered
// (Performance_timelineInterest): a page with no observer is not woken, and an idle one costs nothing.

import "core:encoding/json"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:fetch"
import "wb:host"

Timeline_Settings :: struct {
	resource_entries: int,
	event_entries:    int,
	event_min_ms:     f64,
}

TIMELINE_PREFS := [?]config.Def{
	{name = "performance.resource_timing_entries", kind = .Int, default = {i = 250}, bounded = true, min = 0, max = 100_000,
		description = "How many Resource Timing entries a document keeps (performance.getEntriesByType(\"resource\"), setResourceTimingBufferSize changes it): its scripts, styles, images, fonts and frames. Past it the oldest go. 0: none are recorded."},
	{name = "performance.event_timing_entries", kind = .Int, default = {i = 150}, bounded = true, min = 0, max = 100_000,
		description = "How many Event Timing entries (slow input events, PerformanceObserver type \"event\") a document keeps. 0: none are recorded."},
	{name = "performance.event_timing_min_ms", kind = .Float, default = {f = 16}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "An input event whose listeners took at least this long (rounded up to 8 ms) is recorded as an Event Timing entry; an observer asks for its own threshold (durationThreshold, 104 ms by default). The first input is recorded whatever it took."},
}

timeline_settings_from_prefs :: proc(p: ^config.Prefs) -> Timeline_Settings {
	return {
		resource_entries = int(config.int_of(p, "performance.resource_timing_entries")),
		event_entries = int(config.int_of(p, "performance.event_timing_entries")),
		event_min_ms = config.float_of(p, "performance.event_timing_min_ms"),
	}
}

// The kinds of entries (the values of Api_PerformanceEntryType from Navigation on).
@(private)
Tl_Kind :: enum u8 { Navigation = 3, Resource, Paint, Event, First_Input }

// One entry as the engine reads it (JSON): the members of the interfaces, absent ones are 0 or "".
@(private)
Tl_Entry :: struct {
	seq:            u64     `json:"seq"`,
	name:           string  `json:"name"`,
	start:          f64     `json:"startTime"`,
	duration:       f64     `json:"duration"`,
	initiator:      string  `json:"initiatorType,omitempty"`,
	protocol:       string  `json:"nextHopProtocol,omitempty"`,
	content_type:   string  `json:"contentType,omitempty"`,
	nav_type:       string  `json:"type,omitempty"`,
	redirect_start: f64     `json:"redirectStart,omitempty"`,
	redirect_end:   f64     `json:"redirectEnd,omitempty"`,
	fetch_start:    f64     `json:"fetchStart,omitempty"`,
	dns_start:      f64     `json:"domainLookupStart,omitempty"`,
	dns_end:        f64     `json:"domainLookupEnd,omitempty"`,
	connect_start:  f64     `json:"connectStart,omitempty"`,
	connect_end:    f64     `json:"connectEnd,omitempty"`,
	request_start:  f64     `json:"requestStart,omitempty"`,
	response_start: f64     `json:"responseStart,omitempty"`,
	response_end:   f64     `json:"responseEnd,omitempty"`,
	transfer_size:  int     `json:"transferSize,omitempty"`,
	encoded_size:   int     `json:"encodedBodySize,omitempty"`,
	decoded_size:   int     `json:"decodedBodySize,omitempty"`,
	status:         int     `json:"responseStatus,omitempty"`,
	redirects:      int     `json:"redirectCount,omitempty"`,
	dom_interactive: f64    `json:"domInteractive,omitempty"`,
	dcl_start:      f64     `json:"domContentLoadedEventStart,omitempty"`,
	dcl_end:        f64     `json:"domContentLoadedEventEnd,omitempty"`,
	dom_complete:   f64     `json:"domComplete,omitempty"`,
	load_start:     f64     `json:"loadEventStart,omitempty"`,
	load_end:       f64     `json:"loadEventEnd,omitempty"`,
	processing_start: f64   `json:"processingStart,omitempty"`,
	processing_end: f64     `json:"processingEnd,omitempty"`,
	cancelable:     bool    `json:"cancelable,omitempty"`,
	interaction_id: int     `json:"interactionId,omitempty"`,
}

@(private)
Tl_Buffer :: struct {
	entries:  [dynamic]Tl_Entry,   // names, protocols and content types owned
	next_seq: u64,
}

// What the shell measured of the navigation that made the document (loop clock, ns; 0: not measured).
Navigation_Timing :: struct {
	start_ns:     i64,   // the navigation began
	response_ns:  i64,   // the head of the answer arrived
	end_ns:       i64,   // the body was complete
	reload:       bool,
	back_forward: bool,
	status:       int,
	bytes:        int,
	redirects:    int,
	from_cache:   bool,
	mime:         string,   // copied
}

@(private)
Page_Timeline :: struct {
	bufs:       [Tl_Kind]Tl_Buffer,
	nav:        Navigation_Timing,
	nav_known:  bool,
	callback:   u32,
	user:       u32,
	owner:      u32,
	has_callback: bool,
	interest:   u32,
	announced:  u32,
	posted:     bool,
	res_limit:  int,
	painted:    bool,
	first_input: bool,
	interaction: int,
}

@(private)
Pending_Resource :: struct {
	page_id:    u64,
	url:        string,   // owned
	initiator:  string,   // static
	start_ms:   f64,
	response_ms: f64,
	status:     int,
	mime:       string,   // owned
	cache:      fetch.Cache_Outcome,
	redirects:  int,
	has_response: bool,
}

@(private) tl_pending: map[u64]Pending_Resource
@(private) tl_loader: u8   // (its address names the timelines' observer of a loader)

@(private)
tl_of :: proc(p: ^Page, create := true) -> ^Page_Timeline {
	if p.timeline == nil && create && p.web != nil {
		p.timeline = new(Page_Timeline)
		p.timeline.res_limit = p.settings.timeline.resource_entries
		base.on_close(p.scope, timeline_page_closing, p)
	}
	return p.timeline
}

@(private)
tl_entry_free :: proc(e: ^Tl_Entry) {
	delete(e.name); delete(e.initiator); delete(e.protocol); delete(e.content_type); delete(e.nav_type)
}

@(private)
timeline_page_closing :: proc(data: rawptr) {
	p := (^Page)(data)
	t := p.timeline
	if t == nil { return }
	p.timeline = nil
	for &b in t.bufs {
		for &e in b.entries { tl_entry_free(&e) }
		delete(b.entries)
	}
	delete(t.nav.mime)
	free(t)
}

// A page was made: its loader's requests are described to the timelines (once for a loader).
@(private)
timeline_attach :: proc(p: ^Page) {
	if p.loader == nil { return }
	for o in p.loader.observers { if o.user == &tl_loader { return } }
	fetch.observer_add(p.loader, {user = &tl_loader, event = timeline_observe})   // (the loader drops it with itself)
}

// Process end: the requests still described are forgotten.
timeline_shutdown :: proc() {
	for _, pr in tl_pending { delete(pr.url, base.process_allocator()); delete(pr.mime, base.process_allocator()) }
	delete(tl_pending)
	tl_pending = nil
}

// The live page whose environment this is (the request's initiator), nil for none.
@(private)
page_of_environment :: proc(env: ^fetch.Environment) -> ^Page {
	if env == nil { return nil }
	for _, pg in live_pages { if &pg.env == env { return pg } }
	return nil
}

@(private)
initiator_type :: proc(d: fetch.Destination) -> string {
	switch d {
	case .Script, .Worker: return "script"
	case .Style: return "css"
	case .Image: return "img"
	case .Font: return "css"
	case .Audio: return "audio"
	case .Video: return "video"
	case .Iframe: return "iframe"
	case .Empty: return "fetch"
	case .Document, .Manifest, .Report: return "other"
	}
	return "other"
}

// fetch.Observer.event: the steps of every request, on the loop thread.
@(private)
timeline_observe :: proc(user: rawptr, ev: ^fetch.Observed) {
	switch ev.kind {
	case .Started:
		if ev.initiator == nil || ev.destination == .Document || ev.destination == .Report { return }
		p := page_of_environment(ev.initiator)
		if p == nil || p.closed || p.settings.timeline.resource_entries == 0 { return }
		if tl_pending == nil { tl_pending = make(map[u64]Pending_Resource, base.process_allocator()) }
		tl_pending[ev.id] = Pending_Resource{page_id = page_id(p), url = strings.clone(ev.url, base.process_allocator()), initiator = initiator_type(ev.destination), start_ms = page_now_ms(p)}
	case .Response:
		pr, ok := &tl_pending[ev.id]
		if !ok { return }
		p := page_by_id(pr.page_id)
		if p == nil { return }
		pr.has_response = true
		pr.response_ms = page_now_ms(p)
		pr.status, pr.cache, pr.redirects = ev.status, ev.cache, ev.redirects
		if ev.url != "" && ev.url != pr.url { delete(pr.url, base.process_allocator()); pr.url = strings.clone(ev.url, base.process_allocator()) }
		delete(pr.mime, base.process_allocator())
		pr.mime = strings.clone(ev.mime, base.process_allocator())
	case .Done:
		pr, ok := tl_pending[ev.id]
		if !ok { return }
		delete_key(&tl_pending, ev.id)
		defer { delete(pr.url, base.process_allocator()); delete(pr.mime, base.process_allocator()) }
		p := page_by_id(pr.page_id)
		if p == nil || !pr.has_response { return }
		end := page_now_ms(p)
		e := Tl_Entry{
			name = strings.clone(pr.url), start = pr.start_ms, duration = end - pr.start_ms, initiator = strings.clone(pr.initiator),
			content_type = strings.clone(pr.mime),
			fetch_start = pr.start_ms, dns_start = pr.start_ms, dns_end = pr.start_ms, connect_start = pr.start_ms, connect_end = pr.start_ms,
			request_start = pr.start_ms, response_start = pr.response_ms, response_end = end,
			encoded_size = ev.bytes, decoded_size = ev.bytes, status = pr.status,
		}
		if pr.cache == .Network || pr.cache == .Revalidated { e.transfer_size = ev.bytes + 300 }   // (the headers' size is not known)
		timeline_add(p, .Resource, e)
	case .Failed:
		pr, ok := tl_pending[ev.id]
		if !ok { return }
		delete_key(&tl_pending, ev.id)
		delete(pr.url, base.process_allocator())
		delete(pr.mime, base.process_allocator())
	}
}

// Adds an entry to the buffer of its kind (taking its strings) and tells the engine when it asked.
@(private)
timeline_add :: proc(p: ^Page, kind: Tl_Kind, e: Tl_Entry) {
	t := tl_of(p)
	if t == nil { tmp := e; tl_entry_free(&tmp); return }
	b := &t.bufs[kind]
	limit := 0
	switch kind {
	case .Resource: limit = t.res_limit
	case .Event: limit = p.settings.timeline.event_entries
	case .Navigation, .Paint, .First_Input: limit = 64
	}
	if limit <= 0 { tmp := e; tl_entry_free(&tmp); b.next_seq += 1; return }
	for len(b.entries) >= limit {
		tl_entry_free(&b.entries[0])
		ordered_remove(&b.entries, 0)
	}
	ne := e
	ne.seq = b.next_seq
	b.next_seq += 1
	append(&b.entries, ne)
	timeline_announce(p, kind)
}

@(private)
timeline_announce :: proc(p: ^Page, kind: Tl_Kind) {
	t := p.timeline
	if t == nil || !t.has_callback || t.interest & (1 << u32(kind)) == 0 { return }
	t.announced |= 1 << u32(kind)
	if t.posted { return }
	t.posted = true
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		if pg == nil || pg.closed { return }
		t := pg.timeline
		if t == nil { return }
		t.posted = false
		kinds := t.announced & t.interest
		t.announced = 0
		if kinds == 0 || !t.has_callback { return }
		inst := instance_by_index(pg, t.owner)
		if inst == nil { return }
		argv := [2]u32{t.user, kinds}
		call_guest(pg, inst, t.callback, argv[:])
	}, nil)
}

////////////////////////////////
// What the shell and the document's life cycle give

// The shell measured the navigation that made this document: the time origin moves to its start (performance.now() then
// counts what the network took, as in other browsers) and the navigation entry gets its network times.
set_navigation_timing :: proc(p: ^Page, nt: Navigation_Timing) {
	t := tl_of(p)
	if t == nil || p.web == nil || nt.start_ns <= 0 { return }
	w := p.web
	shift := w.origin_ns - nt.start_ns
	if shift > 0 {
		w.origin_ns -= shift
		w.origin_unix_ms -= f64(shift) / 1e6
	}
	delete(t.nav.mime)
	t.nav = nt
	t.nav.mime = strings.clone(nt.mime)
	t.nav_known = true
}

// The body of the document is complete.
navigation_response_end :: proc(p: ^Page, end_ns: i64, bytes: int) {
	t := p.timeline
	if t == nil || !t.nav_known { return }
	t.nav.end_ns, t.nav.bytes = end_ns, bytes
}

@(private)
nav_entry :: proc(p: ^Page) -> Tl_Entry {
	t := tl_of(p)
	w := p.web
	ms :: proc(w: ^Web_State, ns: i64) -> f64 { return ns > 0 ? max(f64(ns - w.origin_ns) / 1e6, 0) : 0 }
	e := Tl_Entry{name = strings.clone(p.env.location.href), initiator = strings.clone("navigation"), nav_type = strings.clone("navigate")}
	if t.nav_known {
		n := &t.nav
		e.response_start = ms(w, n.response_ns)
		e.response_end = max(ms(w, n.end_ns), e.response_start)
		e.status, e.redirects = n.status, n.redirects
		if n.reload { delete(e.nav_type); e.nav_type = strings.clone("reload") }
		if n.back_forward { delete(e.nav_type); e.nav_type = strings.clone("back_forward") }
		if !n.from_cache { e.transfer_size = n.bytes + 300 }
		e.encoded_size, e.decoded_size = n.bytes, n.bytes
		e.content_type = strings.clone(n.mime)
	}
	e.request_start = 0
	if s := p.scripts; s != nil {
		at :: proc(w: ^Web_State, ms_loop: f64) -> f64 { return ms_loop > 0 ? max(ms_loop - f64(w.origin_ns) / 1e6, 0) : 0 }
		e.dom_interactive = at(w, s.timing.parsed_ms)
		e.dcl_start = at(w, s.timing.dcl_ms)
		e.dcl_end = e.dcl_start
		e.dom_complete = at(w, s.timing.load_ms)
		e.load_start = e.dom_complete
		e.load_end = e.dom_complete
		e.duration = e.load_end
	}
	return e
}

// The shell painted the document for the first time.
timeline_painted :: proc(p: ^Page) {
	if p.web == nil || p.worker != nil { return }
	t := tl_of(p)
	if t == nil || t.painted { return }
	t.painted = true
	now := page_now_ms(p)
	timeline_add(p, .Paint, Tl_Entry{name = strings.clone("first-paint"), start = now})
	timeline_add(p, .Paint, Tl_Entry{name = strings.clone("first-contentful-paint"), start = now})
}

////////////////////////////////
// Event Timing

@(private)
event_timed :: proc(type: string) -> (known: bool, interaction: bool) {
	switch type {
	case "click", "keydown", "pointerdown": return true, true
	case "auxclick", "contextmenu", "dblclick", "mousedown", "mouseup", "pointerup", "pointercancel", "keyup", "keypress",
	     "beforeinput", "input", "touchstart", "touchend", "touchcancel", "dragstart", "dragend", "drop", "mouseover", "mouseout", "pointerover", "pointerout":
		return true, false
	}
	return false, false
}

// Before a browser input event is dispatched: the start of its measure (0: it is not measured).
@(private)
timeline_event_begin :: proc(p: ^Page, ev: ^dom.Event) -> i64 {
	if ev.engine_id != 0 || len(ev.type) > 12 || p.settings.timeline.event_entries == 0 { return 0 }
	if known, _ := event_timed(ev.type); !known { return 0 }
	return host.now_ns(p.loop)
}

@(private)
timeline_event_end :: proc(p: ^Page, ev: ^dom.Event, begin: i64) {
	if p.closed || p.web == nil { return }
	end := host.now_ns(p.loop)
	processing := f64(end - begin) / 1e6
	// the presentation of the next frame is not known: the duration is the processing, up to the next 8 ms
	dur := max(8.0, 8.0 * f64(int((processing + 7.999) / 8)))
	t := tl_of(p)
	if t == nil { return }
	_, interaction := event_timed(ev.type)
	first := interaction && !t.first_input
	if !first && dur < p.settings.timeline.event_min_ms { return }
	if first { t.first_input = true }
	start := f64(begin - p.web.origin_ns) / 1e6
	id := 0
	if interaction { t.interaction += 1; id = t.interaction }
	mk := proc(name: string, start, dur, ps, pe: f64, c: bool, id: int) -> Tl_Entry {
		return Tl_Entry{name = strings.clone(name), start = start, duration = dur, processing_start = ps, processing_end = pe, cancelable = c, interaction_id = id}
	}
	pstart := start
	pend := start + processing
	if first { timeline_add(p, .First_Input, mk(ev.type, start, dur, pstart, pend, ev.cancelable, id)) }
	if dur >= p.settings.timeline.event_min_ms { timeline_add(p, .Event, mk(ev.type, start, dur, pstart, pend, ev.cancelable, id)) }
}

////////////////////////////////
// Imports

Performance_timeline :: proc(c: ^Call, entry_type: Api_PerformanceEntryType, from_seq: u64) -> string {
	p := c.page
	if entry_type < .Navigation || entry_type > .First_Input { return "[]" }
	kind := Tl_Kind(entry_type)
	list := make([dynamic]Tl_Entry, context.temp_allocator)
	if kind == .Navigation {
		if from_seq > 0 { return "[]" }
		e := nav_entry(p)
		defer tl_entry_free(&e)
		append(&list, e)
	} else if t := tl_of(p, false); t != nil {
		for e in t.bufs[kind].entries { if e.seq >= from_seq { append(&list, e) } }
	}
	data, err := json.marshal(list[:], {}, context.temp_allocator)
	if err != nil { return "[]" }
	return string(data)
}

Performance_timelineNextSeq :: proc(c: ^Call, entry_type: Api_PerformanceEntryType) -> u64 {
	if entry_type < .Navigation || entry_type > .First_Input { return 0 }
	t := tl_of(c.page, false)
	if t == nil { return 0 }
	return t.bufs[Tl_Kind(entry_type)].next_seq
}

Performance_timelineInterest :: proc(c: ^Call, kinds: u32) {
	if t := tl_of(c.page); t != nil { t.interest = kinds }
}

Performance_onTimeline :: proc(c: ^Call, callback: u32, user: i32) {
	t := tl_of(c.page)
	if t == nil { return }
	t.callback, t.user, t.owner, t.has_callback = callback, u32(user), c.owner, true
}

Performance_setResourceTimingBufferSize :: proc(c: ^Call, entries: u32) {
	t := tl_of(c.page)
	if t == nil { return }
	t.res_limit = int(entries)
	b := &t.bufs[.Resource]
	for len(b.entries) > t.res_limit {
		tl_entry_free(&b.entries[0])
		ordered_remove(&b.entries, 0)
	}
}

Performance_clearResourceTimings :: proc(c: ^Call) {
	t := tl_of(c.page, false)
	if t == nil { return }
	b := &t.bufs[.Resource]
	for &e in b.entries { tl_entry_free(&e) }
	clear(&b.entries)
}

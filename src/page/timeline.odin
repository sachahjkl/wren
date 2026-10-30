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
	long_task_entries: int,
	long_animation_frame_entries: int,
	loaf_script_min_ms: f64,
	lcp_entries:      int,
	layout_shift_entries: int,
	element_entries:  int,
	visibility_entries: int,
	lcp_min_bpp:      f64,
	layout_shift_recent_input_ms: f64,
}

// Long Tasks: a task that took at least this long (the specification's 50 ms) is a long task.
LONG_TASK_MS :: 50

TIMELINE_PREFS := [?]config.Def{
	{name = "performance.resource_timing_entries", kind = .Int, default = {i = 250}, bounded = true, min = 0, max = 100_000,
		description = "How many Resource Timing entries a document keeps (performance.getEntriesByType(\"resource\"), setResourceTimingBufferSize changes it): its scripts, styles, images, fonts and frames. Past it the oldest go. 0: none are recorded."},
	{name = "performance.event_timing_entries", kind = .Int, default = {i = 150}, bounded = true, min = 0, max = 100_000,
		description = "How many Event Timing entries (slow input events, PerformanceObserver type \"event\") a document keeps. 0: none are recorded."},
	{name = "performance.event_timing_min_ms", kind = .Float, default = {f = 16}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "An input event whose listeners took at least this long (rounded up to 8 ms) is recorded as an Event Timing entry; an observer asks for its own threshold (durationThreshold, 104 ms by default). The first input is recorded whatever it took."},
	{name = "performance.long_task_entries", kind = .Int, default = {i = 200}, bounded = true, min = 0, max = 100_000,
		description = "How many Long Tasks entries (a task of a page's scripts that took 50 ms or more, PerformanceObserver type \"longtask\") a document keeps for its observers. 0: none are recorded (tasks are not timed)."},
	{name = "performance.long_animation_frame_entries", kind = .Int, default = {i = 200}, bounded = true, min = 0, max = 100_000,
		description = "How many Long Animation Frames entries (a frame or task of the page that took 50 ms or more, PerformanceObserver type \"long-animation-frame\", PerformanceLongAnimationFrameTiming) a document keeps for its observers. 0: none are recorded (frames are not timed)."},
	{name = "performance.long_animation_frame_script_min_ms", kind = .Float, default = {f = 5}, bounded = true, min = 0, max = 1000, unit = "ms",
		description = "A script invocation inside a long animation frame that took at least this long (the specification's 5 ms) becomes a PerformanceScriptTiming in the entry's scripts list; shorter ones are not reported, to keep the list small. 0: every invocation of the frame is reported."},
	// Largest Contentful Paint, Layout Instability and Element Timing: the spec keeps at most 150 of each; 0 turns a kind off.
	{name = "performance.largest_contentful_paint_entries", kind = .Int, default = {i = 150}, bounded = true, min = 0, max = 100_000,
		description = "How many Largest Contentful Paint entries (PerformanceObserver type \"largest-contentful-paint\") a document keeps: one per larger candidate painted, until the first user interaction. 0: largest contentful paint is not measured."},
	{name = "performance.layout_shift_entries", kind = .Int, default = {i = 150}, bounded = true, min = 0, max = 100_000,
		description = "How many Layout Instability entries (PerformanceObserver type \"layout-shift\", LayoutShift) a document keeps: one per unexpected move of visible content. 0: layout shifts are not measured."},
	{name = "performance.element_timing_entries", kind = .Int, default = {i = 150}, bounded = true, min = 0, max = 100_000,
		description = "How many Element Timing entries (PerformanceObserver type \"element\", PerformanceElementTiming) a document keeps: one per element with an elementtiming attribute when it is first painted. 0: element timing is not measured."},
	{name = "performance.visibility_state_entries", kind = .Int, default = {i = 50}, bounded = true, min = 0, max = 100_000,
		description = "How many visibility-state entries (PerformanceObserver type \"visibility-state\", VisibilityStateEntry) a document keeps: one each time the page becomes visible or hidden. 0: visibility-state changes are not recorded."},
	{name = "performance.largest_contentful_paint_min_bpp", kind = .Float, default = {f = 0.05}, bounded = true, min = 0, max = 100, unit = "bpp",
		description = "An image whose displayed bits-per-pixel (encoded bytes * 8 / displayed area) is below this is too low-entropy to be a Largest Contentful Paint candidate (the specification's 0.05), so background and spacer images do not win. 0: images are never excluded for low entropy."},
	{name = "performance.layout_shift_recent_input_ms", kind = .Float, default = {f = 500}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "A layout shift within this long after a discrete user input (a click or a key) is marked hadRecentInput and does not count against the page (the specification's 500 ms). 0: every shift counts."},
}

timeline_settings_from_prefs :: proc(p: ^config.Prefs) -> Timeline_Settings {
	return {
		resource_entries = int(config.int_of(p, "performance.resource_timing_entries")),
		event_entries = int(config.int_of(p, "performance.event_timing_entries")),
		event_min_ms = config.float_of(p, "performance.event_timing_min_ms"),
		long_task_entries = int(config.int_of(p, "performance.long_task_entries")),
		long_animation_frame_entries = int(config.int_of(p, "performance.long_animation_frame_entries")),
		loaf_script_min_ms = config.float_of(p, "performance.long_animation_frame_script_min_ms"),
		lcp_entries = int(config.int_of(p, "performance.largest_contentful_paint_entries")),
		layout_shift_entries = int(config.int_of(p, "performance.layout_shift_entries")),
		element_entries = int(config.int_of(p, "performance.element_timing_entries")),
		visibility_entries = int(config.int_of(p, "performance.visibility_state_entries")),
		lcp_min_bpp = config.float_of(p, "performance.largest_contentful_paint_min_bpp"),
		layout_shift_recent_input_ms = config.float_of(p, "performance.layout_shift_recent_input_ms"),
	}
}

// The kinds of entries (the values of Api_PerformanceEntryType from Navigation on).
@(private)
Tl_Kind :: enum u8 { Navigation = 3, Resource, Paint, Event, First_Input, Long_Task, Largest_Contentful_Paint, Layout_Shift, Element, Visibility_State, Long_Animation_Frame, Script }

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
	// Largest Contentful Paint / Element Timing (loadTime from load_start, renderTime from start, toJSON reads these):
	render_time:    f64     `json:"renderTime,omitempty"`,
	load_time:      f64     `json:"loadTime,omitempty"`,
	size:           f64     `json:"size,omitempty"`,     // visible area, CSS px^2 (unsigned long)
	id:             string  `json:"id,omitempty"`,       // the element's id attribute ("" when none)
	url:            string  `json:"url,omitempty"`,      // the image's request URL ("" for text / no image)
	identifier:     string  `json:"identifier,omitempty"`,   // Element Timing: the elementtiming attribute
	natural_w:      int     `json:"naturalWidth,omitempty"`,
	natural_h:      int     `json:"naturalHeight,omitempty"`,
	intersect_rect: [4]f64  `json:"intersectRect,omitempty"`,   // Element Timing intersectionRect (x, y, w, h)
	// Layout Instability (LayoutShift): the score of this shift and whether a recent input preceded it.
	value:          f64     `json:"value,omitempty"`,
	had_input:      bool    `json:"hadRecentInput,omitempty"`,
	last_input_ms:  f64     `json:"lastInputTime,omitempty"`,
	// LayoutShiftAttribution: the rects go through the JSON (previousRect / currentRect); each source's node handle stays
	// here only (json:"-" below) and is wrapped live by Performance_timelineNode at the index of the source.
	sources:        []Tl_Source `json:"sources,omitempty"`,
	// Long Animation Frames (PerformanceLongAnimationFrameTiming): the rendering phase of the frame and the scripts it
	// ran. renderStart / styleAndLayoutStart are 0 when the frame had no rendering update (a bare long task). Durations
	// are on the page's performance timeline (ms since the time origin) for the timestamps, or plain ms for the spans.
	render_start:       f64 `json:"renderStart,omitempty"`,
	style_layout_start: f64 `json:"styleAndLayoutStart,omitempty"`,
	style_duration:     f64 `json:"styleDuration,omitempty"`,
	layout_duration:    f64 `json:"layoutDuration,omitempty"`,
	blocking_duration:  f64 `json:"blockingDuration,omitempty"`,
	first_ui_event:     f64 `json:"firstUIEventTimestamp,omitempty"`,
	scripts:            []Tl_Script `json:"scripts,omitempty"`,
	// PerformanceScriptTiming (one script run inside a long animation frame): its invoker and where it came from.
	invoker_type:       string `json:"invokerType,omitempty"`,
	invoker:            string `json:"invoker,omitempty"`,
	execution_start:    f64    `json:"executionStart,omitempty"`,
	source_url:         string `json:"sourceURL,omitempty"`,
	source_function:    string `json:"sourceFunctionName,omitempty"`,
	source_char:        i64    `json:"sourceCharPosition,omitempty"`,
	source_line:        i64    `json:"sourceLine,omitempty"`,
	source_column:      i64    `json:"sourceColumn,omitempty"`,
	forced_style:       f64    `json:"forcedStyleDuration,omitempty"`,
	forced_layout:      f64    `json:"forcedLayoutDuration,omitempty"`,
	pause_duration:     f64    `json:"pauseDuration,omitempty"`,
	window_attribution: string `json:"windowAttribution,omitempty"`,
	// The element the entry refers to (LCP, Element Timing), kept out of the JSON: a handle cannot be put in JSON and stay
	// valid. Performance_timelineNode wraps it live, or nothing when it left the document (the attribute goes null).
	node:           base.Handle `json:"-"`,
}

// One script invocation inside a long animation frame (PerformanceScriptTiming), marshalled as a nested object in the
// entry's `scripts`. The strings are owned by the entry and freed with it.
@(private)
Tl_Script :: struct {
	invoker_type:       string `json:"invokerType"`,
	invoker:            string `json:"invoker"`,
	name:               string `json:"name"`,
	start:              f64    `json:"startTime"`,
	duration:           f64    `json:"duration"`,
	execution_start:    f64    `json:"executionStart,omitempty"`,
	source_url:         string `json:"sourceURL,omitempty"`,
	source_function:    string `json:"sourceFunctionName,omitempty"`,
	source_char:        i64    `json:"sourceCharPosition"`,
	source_line:        i64    `json:"sourceLine"`,
	source_column:      i64    `json:"sourceColumn"`,
	forced_style:       f64    `json:"forcedStyleDuration,omitempty"`,
	forced_layout:      f64    `json:"forcedLayoutDuration,omitempty"`,
	pause_duration:     f64    `json:"pauseDuration,omitempty"`,
	window_attribution: string `json:"windowAttribution"`,
}

// One source of a layout shift (LayoutShiftAttribution): the node that moved and its rectangle before and after, in
// viewport coordinates, CSS px. The node handle is resolved live when the script reads it (Performance_timelineNode).
@(private)
Tl_Source :: struct {
	node: base.Handle `json:"-"`,   // resolved live by Performance_timelineNode (a handle cannot be put in JSON and stay valid)
	prev: [4]f64      `json:"previousRect"`,   // x, y, width, height, CSS px, viewport coordinates
	cur:  [4]f64      `json:"currentRect"`,
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
	// Largest Contentful Paint: the area of the largest candidate reported so far (CSS px^2), and whether the algorithm
	// has stopped (the first user interaction or the document being frozen / torn down ends it, as the spec says).
	lcp_largest: f64,
	lcp_stopped: bool,
	// Layout Instability: session windows (informational), and the time of the last discrete input (hadRecentInput is
	// true for a shift within performance.layout_shift_recent_input_ms of it).
	ls_last_input_ms: f64,
	ls_session_value: f64,
	ls_session_first_ms: f64,
	ls_session_last_ms:  f64,
	ls_max_session:      f64,   // the largest session window so far (informational: Cumulative Layout Shift)
	ls_prev:             map[base.Handle]Ls_Prev,   // where each box was in the previous frame (timeline_lcp.odin)
	// Element Timing: the elements already reported (one entry per element, the first time it is painted).
	et_seen: map[base.Handle]bool,
	// Visibility: the last state reported, so only changes make an entry.
	vis_hidden: bool,
	vis_known:  bool,
	// The document mutation count and viewport at the last Largest Contentful Paint / Element Timing scan: an unchanged
	// layout and viewport cannot change the largest element, so the scan is skipped (it walks every box).
	lcp_scan_mutations: u64,
	lcp_scan_w, lcp_scan_h, lcp_scan_scroll: f64,
	lcp_scanned: bool,
	// The same gate for the layout-shift check: a shift can only happen when the layout changed (a mutation or a new
	// viewport, not a scroll — scrolling is expected movement and never a layout shift).
	ls_scan_mutations: u64,
	ls_scan_w, ls_scan_h: f64,
	ls_scanned: bool,
	// Long Animation Frames: the frame being accumulated (timeline_loaf.odin). A frame is a depth-0 task and the
	// rendering update it may trigger; the scripts it ran are collected here and emitted when the frame ends.
	loaf: Loaf_Frame,
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
	delete(e.id); delete(e.url); delete(e.identifier)
	delete(e.sources)
	delete(e.invoker_type); delete(e.invoker); delete(e.source_url); delete(e.source_function); delete(e.window_attribution)
	for &s in e.scripts {
		delete(s.invoker_type); delete(s.invoker); delete(s.name); delete(s.source_url); delete(s.source_function); delete(s.window_attribution)
	}
	delete(e.scripts)
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
	delete(t.et_seen)
	delete(t.ls_prev)
	loaf_frame_discard(&t.loaf)   // an animation frame left open when the page went: free its script strings
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
	case .Frame: return "frame"
	case .Empty: return "fetch"
	case .Document, .Manifest, .Report: return "other"
	}
	return "other"
}

// fetch.Observer.event: the steps of every request, on the loop thread.
@(private)
timeline_observe :: proc(user: rawptr, ev: ^fetch.Observed) {
	#partial switch ev.kind {   // (the Request / Redirect / Body / Ws_* steps are the developer tools' business)
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
	case .Long_Task: limit = p.settings.timeline.long_task_entries
	case .Largest_Contentful_Paint: limit = p.settings.timeline.lcp_entries
	case .Layout_Shift: limit = p.settings.timeline.layout_shift_entries
	case .Element: limit = p.settings.timeline.element_entries
	case .Visibility_State: limit = p.settings.timeline.visibility_entries
	case .Long_Animation_Frame: limit = p.settings.timeline.long_animation_frame_entries
	case .Script: limit = 0   // scripts are carried inside long-animation-frame entries, never buffered on their own
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
	timeline_visibility_state(p, !p.web.visible)   // the page's visibility when it is first shown (timeline_lcp.odin)
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
// Long Tasks

// The start of a task of the page (an outermost call into one of its realms): 0 when tasks are not timed.
@(private)
timeline_task_begin :: proc(p: ^Page) -> i64 {
	if p.worker != nil || p.web == nil || p.settings.timeline.long_task_entries == 0 { return 0 }
	return host.now_ns(p.loop)
}

// The task (its microtask checkpoint included) ended: a long one becomes an entry ("self": the page's own window; the
// attribution says no more).
@(private)
timeline_task_end :: proc(p: ^Page, begin: i64) {
	if begin == 0 || p.closed || p.web == nil { return }
	end := host.now_ns(p.loop)
	ms := f64(end - begin) / 1e6
	if ms < LONG_TASK_MS { return }
	timeline_add(p, .Long_Task, Tl_Entry{name = strings.clone("self"), start = f64(begin - p.web.origin_ns) / 1e6, duration = ms})
}

////////////////////////////////
// Imports

Performance_timeline :: proc(c: ^Call, entry_type: Api_PerformanceEntryType, from_seq: u64) -> string {
	p := c.page
	if entry_type < .Navigation || entry_type > .Long_Animation_Frame { return "[]" }
	kind := Tl_Kind(entry_type)
	list := make([dynamic]Tl_Entry, context.temp_allocator)
	nav: Tl_Entry
	has_nav := false
	// (the entry's strings are freed once the list is marshalled: a defer in the block below would free them before)
	defer if has_nav { tl_entry_free(&nav) }
	if kind == .Navigation {
		// (a worker has no navigation: Navigation Timing is a document's)
		if from_seq > 0 || p.worker != nil { return "[]" }
		nav, has_nav = nav_entry(p), true
		append(&list, nav)
	} else if t := tl_of(p, false); t != nil {
		for e in t.bufs[kind].entries { if e.seq >= from_seq { append(&list, e) } }
	}
	data, err := json.marshal(list[:], {}, context.temp_allocator)
	if err != nil { return "[]" }
	return string(data)
}

Performance_timelineNextSeq :: proc(c: ^Call, entry_type: Api_PerformanceEntryType) -> u64 {
	if entry_type < .Navigation || entry_type > .Long_Animation_Frame { return 0 }
	t := tl_of(c.page, false)
	if t == nil { return 0 }
	return t.bufs[Tl_Kind(entry_type)].next_seq
}

// The DOM node a timeline entry refers to, wrapped and returned as a handle, or 0 when there is none or it left the
// document: LargestContentfulPaint.element / PerformanceElementTiming.element (index 0, the entry's own element), or the
// node of a layout shift's `index`-th source (LayoutShiftAttribution.node). The engine wraps the returned handle.
Performance_timelineNode :: proc(c: ^Call, entry_type: Api_PerformanceEntryType, seq: u64, index: u32) -> u64 {
	if entry_type < .Navigation || entry_type > .Visibility_State { return 0 }
	t := tl_of(c.page, false)
	if t == nil { return 0 }
	b := &t.bufs[Tl_Kind(entry_type)]
	h := base.NIL_HANDLE
	for &e in b.entries {
		if e.seq != seq { continue }
		if entry_type == .Layout_Shift {
			if int(index) < len(e.sources) { h = e.sources[index].node }
		} else if index == 0 {
			h = e.node
		}
		break
	}
	if h == base.NIL_HANDLE { return 0 }
	// Only a node still in the document is returned (the attribute goes null once it is removed, as the specs say). The
	// engine pins it when it wraps it; we never pin an entry's node, so an entry never keeps a removed node alive.
	n := dom.get(c.page.doc, h)
	if n == nil || !dom.is_connected(c.page.doc, h) { return 0 }
	return u64(h)
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

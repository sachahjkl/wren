package page

// Navigation Timing level 1 (performance.timing): native/js/runtime/web_perf.c (wjr_PerformanceTiming_*), and the
// PerformanceTiming names performance.measure accepts as marks ("navigationStart"...).

import "core:math"

// The attributes of PerformanceTiming, in the interface's order (Performance_timingOf's `which`).
Timing_Attribute :: enum i32 {
	Navigation_Start, Unload_Event_Start, Unload_Event_End, Redirect_Start, Redirect_End, Fetch_Start,
	Domain_Lookup_Start, Domain_Lookup_End, Connect_Start, Connect_End, Secure_Connection_Start, Request_Start,
	Response_Start, Response_End, Dom_Loading, Dom_Interactive, Dom_Content_Loaded_Event_Start,
	Dom_Content_Loaded_Event_End, Dom_Complete, Load_Event_Start, Load_Event_End,
}

Performance_timingOf :: proc(c: ^Call, which: i32) -> f64 {
	p := c.page
	if which < 0 || which > i32(max(Timing_Attribute)) || p.web == nil { return math.nan_f64() }
	// the loop clock of the document's life cycle steps (Script_Timing) to the performance timeline; 0 = not yet
	on_timeline :: proc(p: ^Page, loop_ms: f64) -> f64 {
		if loop_ms <= 0 { return math.nan_f64() }
		return loop_ms - f64(p.web.origin_ns) / 1e6
	}
	switch Timing_Attribute(which) {
	case .Navigation_Start, .Fetch_Start, .Domain_Lookup_Start, .Domain_Lookup_End, .Connect_Start, .Connect_End,
	     .Request_Start, .Response_Start, .Response_End, .Dom_Loading:
		// the document's fetch is not timed: its phases are the time origin (as for a document from the cache)
		return 0
	case .Secure_Connection_Start:
		return p.env.location.scheme == "https" ? 0 : math.nan_f64()
	case .Unload_Event_Start, .Unload_Event_End, .Redirect_Start, .Redirect_End:
		// a previous document's unload and redirects are not recorded
		return math.nan_f64()
	case .Dom_Interactive, .Dom_Content_Loaded_Event_Start, .Dom_Content_Loaded_Event_End, .Dom_Complete,
	     .Load_Event_Start, .Load_Event_End:
		s := p.scripts
		if s == nil { return math.nan_f64() }
		#partial switch Timing_Attribute(which) {
		case .Dom_Interactive: return on_timeline(p, s.timing.parsed_ms)
		case .Dom_Content_Loaded_Event_Start: return on_timeline(p, s.timing.dcl_ms)
		case .Dom_Content_Loaded_Event_End: return on_timeline(p, s.timing.dcl_end_ms)
		case .Dom_Complete: return on_timeline(p, s.timing.complete_ms)
		case .Load_Event_Start: return on_timeline(p, s.timing.load_ms)
		case: return on_timeline(p, s.timing.load_end_ms)
		}
	}
	return math.nan_f64()
}

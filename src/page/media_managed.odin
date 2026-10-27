package page

// ManagedMediaSource, ManagedSourceBuffer and BufferedChangeEvent (api/media_source.widl, the Managed Media Source
// Extensions): a MediaSource whose user agent tells the page when to stream. Safari and iOS use them, and streaming
// sites increasingly feature-detect them.
//
//   * ManagedMediaSource.streaming is true while the user agent wants data. We derive it from how much is buffered
//     ahead of the playback position: below media.mse.managed.low_seconds the agent starts streaming (startstreaming),
//     above media.mse.managed.high_seconds it stops (endstreaming). The page listens for those and appends / pauses
//     accordingly — the whole point of the managed variant is that the agent, not a script timer, drives the fetch.
//   * ManagedSourceBuffer fires bufferedchange whenever its buffered ranges change (an append or an eviction), carrying
//     the ranges added and removed. The engine builds the BufferedChangeEvent's TimeRanges from the event payload.
//
// The objects are the same host structs as the plain MediaSource / SourceBuffer with their `managed` flag set; the
// script engine wraps them as the Managed* interfaces (native/js/runtime/web_mediaobjects.c).

import "core:slice"
import "core:strings"
import "wb:dom"
import "wb:media"

////////////////////////////////
// ManagedMediaSource

ManagedMediaSource_streaming :: proc(c: ^Call, source: Api_MediaSource) -> bool {
	return source.data != nil && source.data.streaming
}

// Decides whether a managed source should be streaming, from the buffered-ahead seconds, and fires the transition.
@(private)
ms_managed_update :: proc(ms: ^Media_Source_Object, ahead_seconds: f64) {
	if !ms.managed || ms.state != .Open { return }
	st := &ms.page.settings.media
	low := media.time_seconds(st.managed_low)
	high := media.time_seconds(st.managed_high)
	want := ms.streaming
	switch {
	case ahead_seconds < low: want = true
	case ahead_seconds >= high: want = false
	}
	if want == ms.streaming { return }
	ms.streaming = want
	mse_fire(ms.page, ms.self, want ? "startstreaming" : "endstreaming")
}

// A source closed / detached: streaming stops (so a reattach starts clean).
@(private)
ms_managed_closed :: proc(ms: ^Media_Source_Object) {
	if ms.managed && ms.streaming {
		ms.streaming = false
		mse_fire(ms.page, ms.self, "endstreaming")
	}
}

////////////////////////////////
// ManagedSourceBuffer

// Fires bufferedchange on a managed source buffer when its ranges changed, with what was added and removed. Called
// after an append or remove completes (media_source.odin sb_run).
@(private)
sb_fire_buffered_change :: proc(sb: ^Source_Buffer_Object) {
	p := sb.page
	if sb.ms == nil { return }
	now := sb_ranges(sb)   // temp-allocated (start, end) seconds pairs
	added, removed := ranges_diff(sb.last_ranges[:], now)
	// remember the new ranges for the next diff
	clear(&sb.last_ranges)
	for r in now { append(&sb.last_ranges, r) }
	if len(added) == 0 && len(removed) == 0 { return }
	if !object_has_listener(p, sb.self, "bufferedchange") { return }
	// the two range lists ride in the event payload as their little-endian byte blobs (the engine reads them back)
	ev := Managed_Buffered_Event{
		handle = sb.self,
		added  = strings.clone(string(ranges_bytes(added))),
		removed = strings.clone(string(ranges_bytes(removed))),
	}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		e := (^Managed_Buffered_Event)(data)
		defer { delete(e.added); delete(e.removed); free(e) }
		if pg == nil || pg.closed { return }
		object_dispatch(pg, e.handle, dom.Event{type = "bufferedchange", data = e.added, text = e.removed})
	}, new_clone(ev))
}

@(private)
Managed_Buffered_Event :: struct {
	handle:  u64,
	added:   string,   // owned: addedRanges as (start, end) f64 pairs, little endian
	removed: string,   // owned: removedRanges, same
}

// The ranges that are in `now` but not `old` (added) and in `old` but not `now` (removed). A simple exact-pair diff:
// both lists are sorted, so a range unchanged is in both; this reports whole ranges that appeared or vanished, which is
// what a bufferedchange listener uses (the spec allows reporting at range granularity).
@(private)
ranges_diff :: proc(old, now: [][2]f64) -> (added, removed: [][2]f64) {
	a := make([dynamic][2]f64, context.temp_allocator)
	r := make([dynamic][2]f64, context.temp_allocator)
	for n in now { if !range_in(old, n) { append(&a, n) } }
	for o in old { if !range_in(now, o) { append(&r, o) } }
	slice.sort_by(a[:], proc(x, y: [2]f64) -> bool { return x[0] < y[0] })
	slice.sort_by(r[:], proc(x, y: [2]f64) -> bool { return x[0] < y[0] })
	return a[:], r[:]
}

@(private)
range_in :: proc(list: [][2]f64, v: [2]f64) -> bool {
	for x in list { if range_close(x[0], v[0]) && range_close(x[1], v[1]) { return true } }
	return false
}

@(private)
range_close :: proc(a, b: f64) -> bool {
	d := a - b
	return d > -0.001 && d < 0.001
}

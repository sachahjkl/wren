package style

import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"

// What a page measures, for the tests: the viewport scrolls 0..`range` in a port of `port`, a subject stands at `at`.
@(private = "file")
Reading :: struct {
	pos, range, port: f64,
	at, size:         f64,
}

@(private = "file")
probe_of :: proc(f: ^Fixture, r: ^Reading) -> Timeline_Probe {
	return {
		user = r, root = f.doc.root,
		scroller = proc(user: rawptr, node: base.Handle) -> Scroll_Measure {
			r := (^Reading)(user)
			return {ok = true, pos = {0, r.pos}, hi = {0, r.range}, port = {r.port, r.port}}
		},
		subject = proc(user: rawptr, subject, source: base.Handle) -> (lo, hi: [2]f64, ok: bool) {
			r := (^Reading)(user)
			return {0, r.at}, {0, r.at + r.size}, true
		},
	}
}

@(private = "file")
open :: proc(src: string) -> ^Fixture {
	s := settings_default()
	defer settings_destroy(&s)
	return fixture_load(src, {set = &s, timeline = true})
}

@(private = "file")
opacity_of :: proc(f: ^Fixture, id: string) -> f64 { return f64(style_of(f.st, dom.find_by_id(f.doc, id)).opacity) }

@(private = "file")
close_to :: proc(a, b: f64) -> bool { return math.abs(a - b) <= 0.002 }

@(test)
the_values_of_timelines_parse_and_read_back :: proc(t: ^testing.T) {
	f := open(`<style>
		#a { animation-timeline: scroll(self x), view(inline 10px 20%), --tl, none, auto; animation-range: entry 10% exit 90%; view-timeline: --v inline; scroll-timeline: --s x; timeline-scope: --s, --v; }
		#b { animation-timeline: scroll(nearest nearest); animation-range: bogus; scroll-timeline-axis: diagonal; }
	</style><div id=a></div><div id=b></div>`)
	defer fixture_unload(f)
	a := style_of(f.st, dom.find_by_id(f.doc, "a"))
	length :: proc(l: Length) -> string { return l.kind == .Percent ? "20%" : "10px" }
	testing.expect_value(t, timeline_prop_text(a, "animation-timeline", length), "scroll(self x), view(inline 10px 20%), --tl, none, auto")
	testing.expect_value(t, timeline_prop_text(a, "animation-range-start", length), "entry 20%")
	testing.expect_value(t, timeline_prop_text(a, "view-timeline", length), "--v inline")
	testing.expect_value(t, timeline_prop_text(a, "scroll-timeline", length), "--s x")
	testing.expect_value(t, timeline_prop_text(a, "timeline-scope", length), "--s, --v")
	b := style_of(f.st, dom.find_by_id(f.doc, "b"))
	testing.expect_value(t, b.animation_timeline[0].kind, Anim_Timeline_Kind.Auto)   // (a scroller twice: not a value)
	testing.expect_value(t, b.animation_range_start[0], Anim_Range{})
	testing.expect_value(t, b.scroll_timeline_axis[0], Timeline_Axis.Block)
}

// An attachment range, a delay in proportion, an inactive scroller, the end of the range at the very end of the scroll.
@(test)
progress_follows_the_offset_within_the_attachment_range :: proc(t: ^testing.T) {
	f := open(`<style>
		@keyframes fade { from { opacity: 1 } to { opacity: 0 } }
		#a { animation: fade linear; animation-timeline: scroll(root); }
		#b { animation: fade linear both; animation-timeline: scroll(root); animation-range: 25% 75%; }
		#c { animation: fade 1s linear 1s both; animation-timeline: scroll(root); }
		#d { animation: fade linear; animation-timeline: view(); }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div>`)
	defer fixture_unload(f)
	r := Reading{pos = 500, range = 1000, port = 100, at = 450, size = 100}
	timeline_scroll_sample(f.tl, f.doc, f.st, probe_of(f, &r))
	timeline_tick(f.tl, f.doc, f.st, 0)
	testing.expect(t, close_to(opacity_of(f, "a"), 0.5), "half way")
	testing.expect(t, close_to(opacity_of(f, "b"), 0.5), "half way through the range")
	testing.expect(t, close_to(opacity_of(f, "c"), 1), "the end of the delay: a time in proportion to the range")
	// a view timeline: 0% with the box's start at the port's end (350), 100% with its end at the port's start (550)
	testing.expect(t, close_to(opacity_of(f, "d"), 0.25), "three quarters of the way across the port")
	r.pos = 1000
	timeline_scroll_sample(f.tl, f.doc, f.st, probe_of(f, &r))
	timeline_tick(f.tl, f.doc, f.st, 1)
	testing.expect(t, close_to(opacity_of(f, "a"), 0), "at the very end, fill none: the end of the animation")
	r.range = 0
	timeline_scroll_sample(f.tl, f.doc, f.st, probe_of(f, &r))
	timeline_tick(f.tl, f.doc, f.st, 2)
	testing.expect(t, close_to(opacity_of(f, "a"), 1), "no scrollable overflow: the timeline is inactive, no effect")
}

// Scrolling back fires the events again; a timeline asks for no frame of its own.
@(test)
a_progress_based_animation_starts_and_ends_with_its_phase :: proc(t: ^testing.T) {
	f := open(`<style>
		@keyframes fade { from { opacity: 1 } to { opacity: 0 } }
		#a { animation: fade linear; animation-timeline: scroll(root); animation-range: 25% 75%; }
	</style><div id=a></div>`)
	defer fixture_unload(f)
	count :: proc(f: ^Fixture, kind: Anim_Event_Kind) -> int {
		n := 0
		for e in timeline_events(f.tl) { if e.kind == kind { n += 1 } }
		return n
	}
	r := Reading{pos = 0, range = 1000, port = 100}
	at :: proc(f: ^Fixture, r: ^Reading, pos: f64, ms: f64) {
		r.pos = pos
		timeline_scroll_sample(f.tl, f.doc, f.st, probe_of(f, r))
		timeline_tick(f.tl, f.doc, f.st, ms)
	}
	at(f, &r, 0, 0)
	testing.expect_value(t, len(timeline_events(f.tl)), 0)
	at(f, &r, 500, 1)
	testing.expect_value(t, count(f, .Animation_Start), 1)
	at(f, &r, 900, 2)
	testing.expect_value(t, count(f, .Animation_End), 1)
	at(f, &r, 500, 3)
	testing.expect_value(t, count(f, .Animation_Start), 2)
	testing.expect_value(t, timeline_next_ms(f.tl), -1.0)
}

// A chrome frame: the value at the offset shown, nothing of the run moved; a scroll range that changed since the last tick (a layout pass) does not take the
// animation from it.
@(test)
compositor_values_stand_at_the_offset_shown :: proc(t: ^testing.T) {
	f := open(`<style>
		@keyframes fade { from { opacity: 1 } to { opacity: 0 } }
		#a { animation: fade linear both; animation-timeline: scroll(root); }
	</style><div id=a></div>`)
	defer fixture_unload(f)
	r := Reading{pos = 0, range = 1000, port = 100}
	timeline_scroll_sample(f.tl, f.doc, f.st, probe_of(f, &r))
	timeline_tick(f.tl, f.doc, f.st, 0)
	r.range = 800   // (the layout after that tick)
	timeline_scroll_sample(f.tl, f.doc, f.st, probe_of(f, &r))
	vals := make([dynamic]Compositor_Value, context.temp_allocator)
	shown := []Shown_Offset{{base.NIL_HANDLE, {0, 400}}}
	moving, any := timeline_compositor_values(f.tl, f.st, 0, shown, false, &vals)
	testing.expect(t, any && !moving, "there is a value, and it does not move by itself")
	testing.expectf(t, len(vals) == 1 && close_to(f64(vals[0].cs.opacity), 0.5), "at the offset shown: %v", vals)
	testing.expect(t, close_to(opacity_of(f, "a"), 1), "what scripts read stays")
}

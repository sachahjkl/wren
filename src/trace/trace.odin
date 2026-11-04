// Package trace: what Wren does as external profilers see it, beside the built-in profiler (src/browser/prof.odin): zones
// (the phases of a frame, the JavaScript engine's calls into the browser), frames, marks. Two switches, both off by default:
//   * Tracy, -define:WREN_TRACY=true (WREN_TRACY=1 wrentool build <variant>): its client (build/tracy, wrentool build tracy)
//     records only while a viewer is connected (wrentool fetch tracy). tracy.odin.
//   * ETW, -define:WREN_ETW=true, on in the profile build: the TraceLogging provider Wren.Browser for WPR and WPA
//     (tools/wren.wprp, tools/wren_regions.xml, wrentool trace start|stop). Its events cost the test of a flag while no
//     session listens. etw.odin.
// Off, every procedure here is empty and nothing is linked (docs/performance.md, Profilers).
//
// A zone is a Site (a name, made once and kept: Tracy holds its address) begun and ended on one thread. The zones of a thread
// pair on every path: an end closes what was begun after its zone and left open (an early return), an end of a zone that is
// not open closes nothing, and a zone past ZONE_DEPTH is not recorded.
package trace

import "base:runtime"
@(require) import "core:strings"   // (the builds with a profiler)

TRACY :: #config(WREN_TRACY, false)
ETW :: ODIN_OS == .Windows && #config(WREN_ETW, #config(PROFILE, false))
ON :: TRACY || ETW

// Zones open at once on a thread (the phases of a frame nest four deep; the engine's calls into the browser, as deep as a
// page's script recurses through them).
ZONE_DEPTH :: 64

Site :: struct {
	name:  cstring,
	tracy: Tracy_Location,
	etw:   Etw_Event,
}

// The zones open on a thread, the most recent last; `dropped`: begun past ZONE_DEPTH, not recorded (their ends come first).
Zone_Stack :: struct {
	open:    [ZONE_DEPTH]Open_Zone,
	n:       int,
	dropped: int,
}

Open_Zone :: struct {
	site:  ^Site,
	tracy: Tracy_Ctx,
}

@(private, thread_local)
zones: Zone_Stack

// The process's provider (ETW); once, before the first zone.
start :: proc() {
	when ETW { etw_start() }
}

// `name`'s copy lives as long as the process: profilers keep pointers to it.
site_init :: proc(s: ^Site, name: string, allocator: runtime.Allocator) {
	when ON {
		s.name = strings.clone_to_cstring(name, allocator)
		when TRACY { s.tracy = {name = s.name, function = s.name, file = "wren", line = 0} }
		when ETW { s.etw = etw_event(name) }
	}
}

begin :: #force_inline proc "contextless" (s: ^Site) {
	when ON {
		when !TRACY { if !etw_listening() { return } }
		i := stack_push(&zones, s)
		if i < 0 { return }
		when TRACY { zones.open[i].tracy = tracy_begin(&s.tracy) }
		when ETW { etw_emit(&s.etw, .Start, KEYWORD_ZONES) }
	}
}

end :: #force_inline proc "contextless" (s: ^Site) {
	when ON {
		if zones.n == 0 && zones.dropped == 0 { return }
		close_down_to(stack_closing(&zones, s))
	}
}

// Every zone of this thread ends: a frame begins, whatever an early return of the last one left open.
end_all :: proc "contextless" () {
	when ON {
		zones.dropped = 0
		close_down_to(0)
	}
}

// A frame went to the screen.
frame :: proc "contextless" () {
	when TRACY { tracy_frame() }
	when ETW { etw_emit(&etw_present, .Info, KEYWORD_FRAMES) }
}

// A moment worth a line in the profile (the start-up's steps).
mark :: proc "contextless" (text: string) {
	when TRACY { tracy_message(text) }
	when ETW { etw_mark(text) }
}

// A value over time (Tracy's plots).
plot :: proc "contextless" (name: cstring, value: f64) {
	when TRACY { tracy_plot(name, value) }
}

@(private)
close_down_to :: proc "contextless" (from: int) {
	when ON {
		for zones.n > from {
			zones.n -= 1
			o := zones.open[zones.n]
			when TRACY { tracy_end(o.tracy) }
			when ETW { etw_emit(&o.site.etw, .Stop, KEYWORD_ZONES) }
		}
	}
}

// The entry a new zone of `s` takes; -1 when the stack is full (the zone is counted as dropped).
stack_push :: proc "contextless" (z: ^Zone_Stack, s: ^Site) -> int {
	if z.n == ZONE_DEPTH { z.dropped += 1; return -1 }
	z.open[z.n] = {site = s}
	z.n += 1
	return z.n - 1
}

// What an end of `s` closes: the entries from the returned index to the top, the most recent of `s` and what was begun after
// it; z.n (nothing) when `s` is not open or when the end is one of a dropped zone.
stack_closing :: proc "contextless" (z: ^Zone_Stack, s: ^Site) -> int {
	if z.dropped > 0 { z.dropped -= 1; return z.n }
	for i := z.n - 1; i >= 0; i -= 1 {
		if z.open[i].site == s { return i }
	}
	return z.n
}

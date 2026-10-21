// Headless end-to-end test of what the style engine does for a page at run time: web fonts loaded through the policy
// layer (CORS), transitions and animations driven by the document clock, their events and the frame scheduling. Needs
// build\testserver.exe running; run from the repository root.
//   styletest.exe
package styletest

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:style"
import "wb:tools/testenv"

failures: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) { fmt.printf("  [%v] %s\n", level, message) }

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
the_page: ^page.Page

pump_until :: proc(what: string, cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		host.loop_wait(&loop, 20)
	}
	return true
}

face :: proc(family: string) -> ^page.Web_Font {
	for f in page.fonts_all(the_page) { if f.family == family { return f } }
	return nil
}

DOC :: `<!doctype html><html><head><style>
@font-face { font-family: Same; src: url(/site/fonts/missing.woff2) format("woff2"), url(/site/fonts/roboto.ttf) }
@font-face { font-family: Cross; src: url(http://127.0.0.1:8766/site/fonts/roboto.ttf) }
@font-face { font-family: Unused; src: url(/site/fonts/roboto.ttf?unused) }
@font-face { font-family: Notfont; src: url(/site/index.html) }
body { font-family: Same, Cross, Notfont, serif }
#t { opacity: 1; transition: opacity 1000ms linear }
#t:hover { opacity: 0 }
@keyframes later { from { width: 0px } to { width: 100px } }
#d { animation: later 100ms linear 500ms }
</style></head><body><p id=t>t</p><div id=d>d</div></body></html>`

main :: proc() {
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	process := base.scope_make("process")

	p := page.page_create(&loop, &loader, &settings, process, testenv.url("http://127.0.0.1:8765/site/styletest.html"), console)
	the_page = p
	page.load_html(p, transmute([]byte)testenv.url(DOC))
	page.set_frame_time(p, 0)
	st := page.styles(p, 800, 600, 1)
	check(st != nil, "styles computed")

	////////////////////////////////
	fmt.println("-- web fonts")
	check(face("Unused") == nil, "a face no element uses is not fetched")
	check(face("Same") != nil && face("Cross") != nil, "the faces in use are queued")
	pump_until("fonts", proc() -> bool {
		for f in page.fonts_all(the_page) { if f.state == .Queued || f.state == .Loading { return false } }
		return true
	})
	same := face("Same")
	check(same != nil && same.state == .Ready && len(same.data) > 100_000, "same-origin TrueType font loaded (after skipping the WOFF2 source)")
	check(same != nil && strings.has_suffix(same.url, "roboto.ttf"), "the first usable source was taken")
	cross := face("Cross")
	check(cross != nil && cross.state == .Failed, "a cross-origin font without Access-Control-Allow-Origin is refused (CORS)")
	nf := face("Notfont")
	check(nf != nil && nf.state == .Failed, "an HTML file is not a font")
	check(page.fonts_generation(p) == 1 && len(page.fonts_ready(p)) == 1, "one face ready, one generation")

	////////////////////////////////
	fmt.println("-- transitions and animations")
	t := dom.find_by_id(p.doc, "t")
	d := dom.find_by_id(p.doc, "d")
	check(!page.animations_active(p), "the delayed animation needs no frame yet")
	next := page.animations_next_ms(p)
	check(next > 400 && next <= 500, fmt.tprintf("its start is the next deadline (%v ms)", next))
	check(p.anim.wake_timer != base.NIL_HANDLE, "a wake-up timer is armed for it")

	state := p.style_state
	state.hover = t
	page.set_style_state(p, state)
	page.set_frame_time(p, 100)
	page.styles(p, 800, 600, 1)
	check(page.animations_active(p), "a running transition asks for frames")
	page.set_frame_time(p, 550)
	st = page.styles(p, 800, 600, 1)
	op := style.style_of(st, t).opacity
	check(math.abs(op - 0.55) < 0.01, fmt.tprintf("45%% through the transition (opacity %v)", op))
	w := style.style_of(st, d).width
	check(w.kind == .Px && math.abs(w.v - 50) < 0.5, fmt.tprintf("halfway through the animation after its delay (width %v)", w.v))
	page.set_frame_time(p, 1200)
	st = page.styles(p, 800, 600, 1)
	check(style.style_of(st, t).opacity == 0 && style.style_of(st, d).width.kind == .Auto, "both are over: cascaded values")
	check(!page.animations_active(p) && page.animations_next_ms(p) < 0, "idle: no frame, no deadline")
	kinds: [style.Anim_Event_Kind]int
	for e in p.anim.pending { kinds[e.kind] += 1 }
	check(kinds[.Transition_Run] == 1 && kinds[.Transition_Start] == 1 && kinds[.Transition_End] == 1, "transitionrun, transitionstart, transitionend queued")
	check(kinds[.Animation_Start] == 1 && kinds[.Animation_End] == 1, "animationstart and animationend queued")
	check(p.anim.flush_timer != base.NIL_HANDLE, "they are dispatched on the next turn of the loop")
	pump_until("event dispatch", proc() -> bool { return len(the_page.anim.pending) == 0 })
	check(len(p.anim.pending) == 0 && p.dp.events.count == 0, "events dispatched and freed")

	page.page_close(p)
	check(loop.timers.count == 0, "closing the page released its timers")
	base.scope_close(process)
	fmt.printf("%d failure(s)\n", failures)
	os.exit(failures == 0 ? 0 : 1)
}

#+build windows
#+private file
// What the style engine does for a page at run time: web fonts loaded through the policy layer (CORS), transitions and animations driven
// by the document clock, their events and the frame scheduling.
package e2e_scenarios

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:page"
import "wb:style"
import "wb:tools/testenv"

ADDRESS :: "http://127.0.0.1:8765/site/styletest.html"
VIEW_WIDTH :: 800
VIEW_HEIGHT :: 600
VIEW_SCALE :: 1
MIN_FONT_BYTES :: 100_000

FONTS_DOC :: `<!doctype html><html><head><style>
@font-face { font-family: Same; src: url(/site/fonts/missing.woff2) format("woff2"), url(/site/fonts/roboto.ttf) }
@font-face { font-family: Cross; src: url(http://127.0.0.1:8766/site/fonts/roboto.ttf) }
@font-face { font-family: Unused; src: url(/site/fonts/roboto.ttf?unused) }
@font-face { font-family: Notfont; src: url(/site/index.html) }
body { font-family: Same, Cross, Notfont, serif }
</style></head><body><p>t</p></body></html>`

ANIMATIONS_DOC :: `<!doctype html><html><head><style>
#t { opacity: 1; transition: opacity 1000ms linear }
#t:hover { opacity: 0 }
@keyframes later { from { width: 0px } to { width: 100px } }
#d { animation: later 100ms linear 500ms }
</style></head><body><p id=t>t</p><div id=d>d</div></body></html>`

ANIMATION_DELAY_MS :: 500           // (of `later`, above)
NEXT_DEADLINE_ABOVE_MS :: 400
HOVER_AT_MS :: 100                  // the transition's start
FRAME_AT_MS :: 550                  // 45% of its 1000 ms; 50 ms into the animation, half of its 100 ms
OPACITY_AT_FRAME :: 0.55
OPACITY_TOLERANCE :: 0.01
WIDTH_AT_FRAME :: 50
WIDTH_TOLERANCE :: 0.5
OVER_AT_MS :: 1200

face :: proc(p: ^page.Page, family: string) -> ^page.Web_Font {
	for f in page.fonts_all(p) { if f.family == family { return f } }
	return nil
}

styled :: proc(p: ^page.Page) -> ^style.Styled { return page.styles(p, VIEW_WIDTH, VIEW_HEIGHT, VIEW_SCALE) }

@(test)
style_web_fonts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := page_make(t, "web fonts", testenv.url(ADDRESS))
	p := pr.p
	page.load_html(p, transmute([]byte)testenv.url(FONTS_DOC))
	page.set_frame_time(p, 0)
	check(pr, styled(p) != nil, "styles computed")
	check(pr, face(p, "Unused") == nil, "a face no element uses is not fetched")
	check(pr, face(p, "Same") != nil && face(p, "Cross") != nil, "the faces in use are queued")
	wait_until(t, "the fonts", p, proc(p: ^page.Page) -> bool {
		for f in page.fonts_all(p) { if f.state == .Queued || f.state == .Loading { return false } }
		return true
	})
	same := face(p, "Same")
	check(pr, same != nil && same.state == .Ready && len(same.data) > MIN_FONT_BYTES, "same-origin TrueType font loaded (after skipping the WOFF2 source)")
	check(pr, same != nil && strings.has_suffix(same.url, "roboto.ttf"), "the first usable source was taken")
	cross := face(p, "Cross")
	check(pr, cross != nil && cross.state == .Failed, "a cross-origin font without Access-Control-Allow-Origin is refused (CORS)")
	nf := face(p, "Notfont")
	check(pr, nf != nil && nf.state == .Failed, "an HTML file is not a font")
	check(pr, page.fonts_generation(p) == 1 && len(page.fonts_ready(p)) == 1, "one face ready, one generation")
	close_page(pr, min_checks = 8)
}

// On the test's clock: the wake-up timer stays armed for as long as the test says, and no frame depends on how fast the machine is.
@(test)
style_transitions_and_animations :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	virtual_clock(t)
	timers := loop.timers.count
	pr := page_make(t, "transitions and animations", testenv.url(ADDRESS))
	p := pr.p
	page.load_html(p, transmute([]byte)string(ANIMATIONS_DOC))
	page.set_frame_time(p, 0)
	st := styled(p)
	check(pr, st != nil, "styles computed")
	tr := dom.find_by_id(p.doc, "t")
	d := dom.find_by_id(p.doc, "d")
	check(pr, !page.animations_active(p), "the delayed animation needs no frame yet")
	next := page.animations_next_ms(p)
	check(pr, next > NEXT_DEADLINE_ABOVE_MS && next <= ANIMATION_DELAY_MS, fmt.tprintf("its start is the next deadline (%v ms)", next))
	check(pr, p.anim.wake_timer != base.NIL_HANDLE, "a wake-up timer is armed for it")

	state := p.style_state
	state.hover = tr
	page.set_style_state(p, state)
	page.set_frame_time(p, HOVER_AT_MS)
	styled(p)
	check(pr, page.animations_active(p), "a running transition asks for frames")
	page.set_frame_time(p, FRAME_AT_MS)
	st = styled(p)
	op := style.style_of(st, tr).opacity
	check(pr, math.abs(op - OPACITY_AT_FRAME) < OPACITY_TOLERANCE, fmt.tprintf("45%% through the transition (opacity %v)", op))
	w := style.style_of(st, d).width
	check(pr, w.kind == .Px && math.abs(w.v - WIDTH_AT_FRAME) < WIDTH_TOLERANCE, fmt.tprintf("halfway through the animation after its delay (width %v)", w.v))
	page.set_frame_time(p, OVER_AT_MS)
	st = styled(p)
	check(pr, style.style_of(st, tr).opacity == 0 && style.style_of(st, d).width.kind == .Auto, "both are over: cascaded values")
	check(pr, !page.animations_active(p) && page.animations_next_ms(p) < 0, "idle: no frame, no deadline")
	kinds: [style.Anim_Event_Kind]int
	for e in p.anim.pending { kinds[e.kind] += 1 }
	check(pr, kinds[.Transition_Run] == 1 && kinds[.Transition_Start] == 1 && kinds[.Transition_End] == 1, "transitionrun, transitionstart, transitionend queued")
	check(pr, kinds[.Animation_Start] == 1 && kinds[.Animation_End] == 1, "animationstart and animationend queued")
	check(pr, p.anim.flush_timer != base.NIL_HANDLE, "they are dispatched on the next turn of the loop")
	wait_until(t, "the events' dispatch", p, proc(p: ^page.Page) -> bool { return len(p.anim.pending) == 0 })
	check(pr, len(p.anim.pending) == 0 && p.dp.events.count == 0, "events dispatched and freed")
	close_page(pr, min_checks = 13)
	testing.expect_value(t, loop.timers.count, timers)
}

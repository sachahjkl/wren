package style

// An animation nobody sees (Seen_Probe) asks for no frame at every refresh: its next tick is its next event, or the unseen tick to look
// again. The times are the timeline's own (document ms): no clock, no wait.

import "core:testing"
import "wb:base"
import "wb:dom"

@(private = "file") UNSEEN_TICK_MS :: 250.0
@(private = "file") SPIN :: `<style>
	@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }
	#a { animation: spin 1000ms linear infinite }
</style><div id=a></div>`

// What the probe was told and asked.
@(private = "file")
Seen_Fake :: struct {
	seen:   bool,
	begun:  int,
	asked:  [dynamic]base.Handle,
	boxes:  [dynamic]bool,   // moves_boxes of each question
}

@(private = "file")
open_seen :: proc(src: string, fake: ^Seen_Fake, unseen_tick_ms := UNSEEN_TICK_MS) -> ^Fixture {
	s := settings_default()
	defer settings_destroy(&s)
	s.anim_mode = .Normal
	s.anim_unseen_tick_ms = unseen_tick_ms
	f := fixture_load(src, {set = &s, timeline = true})
	timeline_set_seen(f.tl, Seen_Probe{user = fake,
		begin = proc(user: rawptr) { (^Seen_Fake)(user).begun += 1 },
		seen = proc(user: rawptr, node: base.Handle, moves_boxes: bool) -> bool {
			fk := (^Seen_Fake)(user)
			append(&fk.asked, node)
			append(&fk.boxes, moves_boxes)
			return fk.seen
		}})
	return f
}

@(private = "file")
fake_free :: proc(fk: ^Seen_Fake) { delete(fk.asked); delete(fk.boxes) }

@(test)
an_unseen_animation_asks_for_a_tick_at_the_unseen_rate :: proc(t: ^testing.T) {
	fk := Seen_Fake{seen = false}
	defer fake_free(&fk)
	f := open_seen(SPIN, &fk)
	defer fixture_unload(f)
	timeline_tick(f.tl, f.doc, f.st, 100)
	testing.expect_value(t, timeline_next_ms(f.tl), UNSEEN_TICK_MS)
	testing.expect(t, !timeline_active(f.tl), "no frame at every refresh")
	testing.expect_value(t, fk.begun, 1)   // (once a tick, before the first question)
	testing.expect(t, len(fk.asked) == 1 && fk.asked[0] == dom.find_by_id(f.doc, "a") && !fk.boxes[0], "the element asked about, a transform only paints")
	// its values still move whenever the page ticks, seen or not
	timeline_tick(f.tl, f.doc, f.st, 350)
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "a")).transform != nil, "the animated value is written")
	// seen again: every frame
	fk.seen = true
	timeline_tick(f.tl, f.doc, f.st, 400)
	testing.expect_value(t, timeline_next_ms(f.tl), 0)
}

// The next tick of an unseen animation is no later than its next event: the iteration ends at 1000, so a tick at 900 asks for 101 (after it).
@(test)
an_unseen_animation_keeps_its_events_on_time :: proc(t: ^testing.T) {
	fk := Seen_Fake{seen = false}
	defer fake_free(&fk)
	f := open_seen(SPIN, &fk)
	defer fixture_unload(f)
	timeline_tick(f.tl, f.doc, f.st, 0)
	timeline_clear_events(f.tl)
	timeline_tick(f.tl, f.doc, f.st, 900)
	next := timeline_next_ms(f.tl)
	testing.expectf(t, next > 100 && next <= 101, "asked for the end of the iteration: %v", next)
	timeline_tick(f.tl, f.doc, f.st, 900 + next)
	n := 0
	for e in timeline_events(f.tl) { if e.kind == .Animation_Iteration { n += 1 } }
	testing.expect_value(t, n, 1)
}

// 0: the setting is off, every animation moves at every frame.
@(test)
unseen_animations_tick_every_frame_when_the_setting_is_off :: proc(t: ^testing.T) {
	fk := Seen_Fake{seen = false}
	defer fake_free(&fk)
	f := open_seen(SPIN, &fk, unseen_tick_ms = 0)
	defer fixture_unload(f)
	timeline_tick(f.tl, f.doc, f.st, 100)
	testing.expect_value(t, timeline_next_ms(f.tl), 0)
	testing.expect_value(t, fk.begun, 0)   // (nobody asked)
}

// What moves boxes says so: the page counts it seen as soon as it has a box.
@(test)
an_animation_of_a_size_tells_the_probe_it_moves_boxes :: proc(t: ^testing.T) {
	fk := Seen_Fake{seen = true}
	defer fake_free(&fk)
	f := open_seen(`<style>
	@keyframes grow { from { width: 0px } to { width: 100px } }
	#w { animation: grow 1000ms linear infinite }
</style><div id=w></div>`, &fk)
	defer fixture_unload(f)
	timeline_tick(f.tl, f.doc, f.st, 100)
	testing.expect(t, len(fk.boxes) == 1 && fk.boxes[0], "width moves boxes")
	testing.expect_value(t, timeline_next_ms(f.tl), 0)
}

// The unseen tick is for the screen: once a tick let an animation wait, a reading at a later instant is behind and ticks first (the page's
// styles_clean); at the instant of the tick, or when every animation is seen, it is not.
@(test)
a_reading_after_an_unseen_tick_is_behind :: proc(t: ^testing.T) {
	fk := Seen_Fake{seen = false}
	defer fake_free(&fk)
	f := open_seen(SPIN, &fk)
	defer fixture_unload(f)
	timeline_tick(f.tl, f.doc, f.st, 100)
	testing.expect(t, !timeline_behind(f.tl, 100), "at the tick's own instant")
	testing.expect(t, timeline_behind(f.tl, 200), "100 ms later")
	timeline_tick(f.tl, f.doc, f.st, 200)
	a := style_of(f.st, dom.find_by_id(f.doc, "a")).transform[0]
	timeline_tick(f.tl, f.doc, f.st, 300)
	b := style_of(f.st, dom.find_by_id(f.doc, "a")).transform[0]
	testing.expectf(t, a != b, "a tick at the reading's instant moves the value: %v, then %v", a, b)
	fk.seen = true
	timeline_tick(f.tl, f.doc, f.st, 400)
	testing.expect(t, !timeline_behind(f.tl, 500), "seen: the frames tick it")
}

// CSS Animations 1 §3: display: none ends the animations of the element and of what it holds (animationcancel), it does not tick them
// slowly; shown again, they start over.
@(private = "file") HIDDEN_PARENT :: `<style>
	@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }
	#s { animation: spin 1000ms linear infinite }
	#p:hover { display: none }
	#n { animation: spin 1000ms linear infinite; display: none }
</style><div id=p><div id=s></div></div><div id=n></div>`

// A state change at `ms` as the page makes it: a partial restyle, else a full pass.
@(private = "file")
state_at :: proc(f: ^Fixture, st: State, ms: f64) {
	if _, ok := restyle_state(f.eng, f.doc, f.st, st); ok {
		timeline_restyled_dom(f.tl, f.doc, f.st, ms)
	} else {
		old := f.st
		f.st = compute_styles(f.eng, f.doc, st)
		timeline_restyled(f.tl, f.doc, old, f.st, ms)
		styled_destroy(old)
	}
	timeline_tick(f.tl, f.doc, f.st, ms)
}

@(test)
display_none_ends_an_animation_and_showing_starts_it_again :: proc(t: ^testing.T) {
	fk := Seen_Fake{seen = false}
	defer fake_free(&fk)
	f := open_seen(HIDDEN_PARENT, &fk)
	defer fixture_unload(f)
	s, n, p := dom.find_by_id(f.doc, "s"), dom.find_by_id(f.doc, "n"), dom.find_by_id(f.doc, "p")
	timeline_tick(f.tl, f.doc, f.st, 0)
	testing.expect_value(t, len(timeline_css_animations(f.tl, n)), 0)   // (display: none of its own: never started)
	timeline_tick(f.tl, f.doc, f.st, 300)
	testing.expect_value(t, len(timeline_css_animations(f.tl, s)), 1)
	timeline_clear_events(f.tl)
	state_at(f, State{hover = p}, 400)
	cancels := 0
	for e in timeline_events(f.tl) { if e.kind == .Animation_Cancel && e.node == s { cancels += 1 } }
	testing.expect_value(t, cancels, 1)
	testing.expect_value(t, len(timeline_css_animations(f.tl, s)), 0)
	testing.expectf(t, timeline_next_ms(f.tl) < 0 && !timeline_behind(f.tl, 900), "nothing runs, nothing waits for a tick: %v", timeline_next_ms(f.tl))
	timeline_clear_events(f.tl)
	state_at(f, State{}, 900)
	runs := timeline_css_animations(f.tl, s)
	testing.expectf(t, len(runs) == 1 && runs[0].current == 0, "shown again, it starts over: %v", runs)
}

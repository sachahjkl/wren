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

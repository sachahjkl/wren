package style

import "core:math"
import "core:testing"
import "wb:dom"
import "wb:html"

@(private = "file")
Sx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
	tl:  ^Timeline,
}

@(private = "file")
open :: proc(src: string) -> Sx {
	f: Sx
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	s.anim_mode = .Normal
	f.eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	f.tl = timeline_make(f.eng)
	timeline_restyled(f.tl, f.doc, nil, f.st, 0)
	timeline_tick(f.tl, f.doc, f.st, 0)
	return f
}

@(private = "file")
close :: proc(f: ^Sx) {
	timeline_destroy(f.tl, f.st)
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
node :: proc(f: ^Sx, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

@(private = "file")
near :: proc(a, b: f64, eps := 0.002) -> bool { return math.abs(a - b) <= eps }

@(private = "file")
timing :: proc(duration: f64, fill := Fill_Mode.None, iterations := 1.0, direction := Anim_Direction.Normal, delay := 0.0) -> Effect_Timing {
	return Effect_Timing{duration = duration, iterations = iterations, fill = fill, direction = direction, delay = delay, easing = {kind = .Linear}}
}

@(test)
effect_timing_model :: proc(t: ^testing.T) {
	tm := timing(1000, .None, 2)
	st := effect_state(tm, 500, true)
	testing.expect(t, st.phase == .Active && st.has_active && near(st.progress, 0.5) && st.iteration == 0, "halfway through the first iteration")
	st = effect_state(tm, 1500, true)
	testing.expect(t, near(st.progress, 0.5) && st.iteration == 1, "the second iteration")
	st = effect_state(tm, 2000, true)
	testing.expect(t, st.phase == .After && !st.has_active, "after, fill none: no effect")
	tm.fill = .Forwards
	st = effect_state(tm, 2500, true)
	testing.expect(t, st.has_active && near(st.progress, 1) && st.iteration == 1, "fill forwards holds the end of the last iteration")
	tm.direction = .Alternate
	st = effect_state(tm, 1250, true)
	testing.expect(t, near(st.progress, 0.75), "alternate: the second iteration runs backwards")
	d := timing(1000, .Backwards, 1, .Normal, 200)
	st = effect_state(d, 100, true)
	testing.expect(t, st.phase == .Before && st.has_active && near(st.progress, 0), "fill backwards in the delay")
	st = effect_state(d, 0, false)
	testing.expect(t, !st.has_local && !st.has_active, "no local time: nothing")
	testing.expect(t, effect_end_time(Effect_Timing{duration = 100, iterations = 3, delay = 50, end_delay = -400}) == 0, "the end time is never negative")
	inf := timing(100, .None, math.inf_f64(1))
	testing.expect(t, math.is_inf(effect_end_time(inf)), "infinite iterations: infinite end")
	st = effect_state(timing(0, .Forwards), 0, true)
	testing.expect(t, st.phase == .After && near(st.progress, 1), "a zero duration fills forwards with its end")
	ez := timing(1000)
	ez.easing = Easing{kind = .Steps, steps = 2, pos = .Jump_End}
	st = effect_state(ez, 600, true)
	testing.expect(t, near(st.progress, 0.5), "the effect's easing transforms the progress")
}

@(test)
script_effects_write_values :: proc(t: ^testing.T) {
	f := open(`<style>#a { opacity: 0.2 } #b { width: 10px }</style><div id=a></div><div id=b></div>`)
	defer close(&f)
	a := dom.find_by_id(f.doc, "a")
	testing.expect(t, !timeline_script_put(f.tl, 1, a, "0\x1f\x1fopacity\x1f0", timing(1000), "bogus(", .Replace), "an easing that does not parse is refused")
	ok := timeline_script_put(f.tl, 1, a, "0\x1f\x1fopacity\x1f0\x1e1\x1f\x1fopacity\x1f1", timing(1000), "", .Replace)
	testing.expect(t, ok, "keyframes compile")
	timeline_script_clock(f.tl, 1, {start = 0, has_start = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 250)
	testing.expectf(t, near(f64(node(&f, "a").opacity), 0.25, 0.01), "a quarter of the way: %v", node(&f, "a").opacity)
	testing.expect(t, timeline_active(f.tl), "a running effect asks for every frame")
	timeline_script_clock(f.tl, 1, {hold = 500, has_hold = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 900)
	testing.expectf(t, near(f64(node(&f, "a").opacity), 0.5, 0.01), "paused at its hold time: %v", node(&f, "a").opacity)
	testing.expect(t, !timeline_active(f.tl), "paused: no frames")
	timeline_tick(f.tl, f.doc, f.st, 1000)
	timeline_script_clock(f.tl, 1, {hold = 1000, has_hold = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 1001)
	testing.expect(t, near(f64(node(&f, "a").opacity), 0.2, 0.01), "finished with fill none: the cascaded value again")

	// a value holding another declaration is refused; an implicit end keyframe takes the underlying value
	b := dom.find_by_id(f.doc, "b")
	ok = timeline_script_put(f.tl, 2, b, "0\x1f\x1fwidth\x1f110px\x1fheight\x1f1px; color: red", timing(100, .Both), "", .Replace)
	testing.expect(t, ok)
	timeline_script_clock(f.tl, 2, {hold = 50, has_hold = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 1002)
	bw := node(&f, "b").width
	testing.expectf(t, near(f64(bw.v), 60, 0.5), "halfway from 110px to the cascaded 10px: %v", bw)
	testing.expect(t, node(&f, "b").color == node(&f, "a").color, "an injected declaration does nothing")

	// composite order: a later effect on the same property wins
	ok = timeline_script_put(f.tl, 3, b, "0\x1f\x1fwidth\x1f300px\x1e1\x1f\x1fwidth\x1f300px", timing(100, .Both), "", .Replace)
	timeline_script_clock(f.tl, 3, {hold = 50, has_hold = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 1003)
	testing.expectf(t, near(f64(node(&f, "b").width.v), 300, 0.5), "the later animation is above: %v", node(&f, "b").width)
	testing.expect(t, timeline_script_covered(f.tl, 2, {3}), "every property of 2 is animated by 3")
	timeline_script_remove(f.tl, 3)
	timeline_script_remove(f.tl, 2)
	timeline_tick(f.tl, f.doc, f.st, 1004)
	testing.expect(t, near(f64(node(&f, "b").width.v), 10, 0.5), "removed effects leave the cascaded value")
	timeline_script_remove(f.tl, 1)
	testing.expect_value(t, len(f.tl.elements), 0)
}

@(test)
keyframe_composite_and_css_animations_for_scripts :: proc(t: ^testing.T) {
	f := open(`<style>#b { width: 10px } #c { animation: grow 1000ms linear } @keyframes grow { from { height: 0 } to { height: 100px } }</style><div id=b></div><div id=c></div>`)
	defer close(&f)
	// a keyframe's own composite operation: `add` at 0% over the effect's `replace`
	b := dom.find_by_id(f.doc, "b")
	ok := timeline_script_put(f.tl, 1, b, "0\x1f\x1fcomposite\x1fadd\x1fwidth\x1f100px\x1e1\x1f\x1fwidth\x1f100px", timing(100, .Both), "", .Replace)
	testing.expect(t, ok)
	timeline_script_clock(f.tl, 1, {hold = 0, has_hold = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 1)
	testing.expectf(t, near(f64(node(&f, "b").width.v), 110, 0.5), "0%% adds to the underlying 10px: %v", node(&f, "b").width)
	timeline_script_clock(f.tl, 1, {hold = 100, has_hold = true, rate = 1, timeline = true})
	timeline_tick(f.tl, f.doc, f.st, 2)
	testing.expectf(t, near(f64(node(&f, "b").width.v), 100, 0.5), "100%% replaces: %v", node(&f, "b").width)

	// the CSS animation as scripts see it: listed, paused and played, sought, canceled
	c := dom.find_by_id(f.doc, "c")
	list := timeline_css_animations(f.tl, c)
	testing.expect(t, len(list) == 1 && list[0].name == "grow" && !list[0].transition && list[0].running, "the CSS animation is listed")
	serial := list[0].serial
	timeline_tick(f.tl, f.doc, f.st, 200)
	testing.expect(t, timeline_css_pause(f.tl, serial, true))
	timeline_tick(f.tl, f.doc, f.st, 600)
	info, found := timeline_css_info(f.tl, serial)
	testing.expectf(t, found && !info.running && near(info.current, 200, 1), "paused by a script: its time holds (%v)", info.current)
	testing.expect(t, timeline_css_seek(f.tl, serial, 500))
	timeline_tick(f.tl, f.doc, f.st, 601)
	testing.expectf(t, near(f64(node(&f, "c").height.v), 50, 0.5), "sought to the middle: %v", node(&f, "c").height)
	testing.expect(t, timeline_css_cancel(f.tl, serial))
	timeline_tick(f.tl, f.doc, f.st, 602)
	info, found = timeline_css_info(f.tl, serial)
	testing.expect(t, found && info.canceled, "canceled: idle")
	testing.expectf(t, near(f64(node(&f, "c").height.v), 0, 0.5), "and no effect: %v", node(&f, "c").height)
	timeline_script_remove(f.tl, 1)
}

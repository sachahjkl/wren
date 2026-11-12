package e2e_scenarios

// Scroll-driven animations (examples/site/scroll_driven_probe.html): what each kind of timeline shows at a scroll offset, on the
// page's turn and in the chrome frames made while a script holds the thread.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:browser"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{1000, 700}
@(private = "file") SHORTER :: [2]int{1000, 690}   // what lets the task go
@(private = "file") DOC_HEIGHT :: 4000             // body's height: the root scroller's range is this less the viewport's
@(private = "file") WITHIN_PX :: 1.5               // a computed length, against what the scroll offset gives

@(private = "file")
open :: proc(t: ^testing.T, prefs: []string = nil, loc := #caller_location) -> ^e2e.Session {
	s := e2e.start(t, {pixels = true, size = SIZE, dpi = e2e.DPI_ONE, prefs = prefs, url = e2e.file_url(fmt.tprintf("%s/examples/site/scroll_driven_probe.html", e2e.repo_root()))}, loc)
	e2e.wait_idle(s)
	e2e.wait_frames(s)
	return s
}

@(private = "file")
number :: proc(s: ^e2e.Session, js: string, loc := #caller_location) -> f64 {
	text := e2e.eval(s, js, loc = loc)
	text = strings.trim_suffix(strings.trim(text, "\""), "px")
	v, ok := strconv.parse_f64(text)
	testing.expectf(s.t, ok, "%s is a number, not %q", js, text, loc = loc)
	return v
}

@(private = "file")
scroll_to :: proc(s: ^e2e.Session, y: int, loc := #caller_location) {
	e2e.eval(s, fmt.tprintf("window.scrollTo(0, %d); 1", y), loc = loc)
	e2e.wait_frames(s, loc = loc)
	e2e.wait_frames(s, loc = loc)
}

@(private = "file")
near :: proc(t: ^testing.T, got, want: f64, what: string, loc := #caller_location) {
	testing.expectf(t, abs(got - want) <= WITHIN_PX, "%s: %v, not %v", what, got, want, loc = loc)
}

// The width of the bar (0 to 600px), a transform and an opacity, at the top, half way and at the end of the document.
@(test)
a_scroll_timeline_follows_the_document :: proc(t: ^testing.T) {
	s := open(t)
	max_scroll := number(s, "document.documentElement.scrollHeight - innerHeight")
	testing.expect(t, max_scroll > 3000, "the document scrolls")
	near(t, number(s, "getComputedStyle(bar).width"), 0, "at the top")
	near(t, number(s, "getComputedStyle(fade).opacity * 100"), 100, "opaque at the top")
	scroll_to(s, int(max_scroll / 2))
	near(t, number(s, "getComputedStyle(bar).width"), 300, "half way")
	near(t, number(s, "getComputedStyle(fade).opacity * 100"), 50, "half faded half way")
	near(t, number(s, "new DOMMatrix(getComputedStyle(slide).transform).m41"), 200, "half slid half way")
	near(t, number(s, "getComputedStyle(head).height"), 80, "the header half shrunk")
	near(t, number(s, "getComputedStyle(head).fontSize"), 28, "its text half shrunk")
	scroll_to(s, int(max_scroll))
	near(t, number(s, "getComputedStyle(bar).width"), 600, "at the end")
	scroll_to(s, 0)
	near(t, number(s, "getComputedStyle(bar).width"), 0, "back at the top")
}

// view(): a box goes from 0% as its top meets the bottom of the viewport to 100% as its bottom leaves the top; a range and keyframes at named ranges.
@(test)
a_view_timeline_follows_the_box :: proc(t: ^testing.T) {
	s := open(t)
	top, height, port := f64(1500), f64(100), number(s, "innerHeight")
	scroll_to(s, int(top - port))
	near(t, number(s, "getComputedStyle(post).width"), 100, "entering")
	scroll_to(s, int(top - port + (port + height) / 2))
	near(t, number(s, "getComputedStyle(post).width"), 300, "in the middle")
	scroll_to(s, int(top + height))
	near(t, number(s, "getComputedStyle(post).width"), 500, "leaving")
	// entry 0% entry 100%: done once the box is all in view
	range_top := f64(2500)
	scroll_to(s, int(range_top - port + height / 2))
	near(t, number(s, "new DOMMatrix(getComputedStyle(range).transform).m41"), 200, "half way through entry")
	scroll_to(s, int(range_top - port + height + 50))
	near(t, number(s, "new DOMMatrix(getComputedStyle(range).transform).m41"), 400, "past entry")
	kf_top := f64(3500)
	scroll_to(s, int(kf_top - port + height / 2))
	near(t, number(s, "getComputedStyle(kf).opacity * 100"), 50, "a keyframe at entry 100%, half way there")
	scroll_to(s, int(kf_top - port + height + 100))
	near(t, number(s, "getComputedStyle(kf).opacity * 100"), 100, "in view")
}

// ScrollTimeline, ViewTimeline and what scripts see of a CSS animation on them.
@(test)
scripts_see_the_timelines :: proc(t: ^testing.T) {
	s := open(t)
	max_scroll := number(s, "document.documentElement.scrollHeight - innerHeight")
	scroll_to(s, int(max_scroll / 4))
	near(t, number(s, "(window.tl = new ScrollTimeline({source: document.documentElement})).currentTime.value"), 25, "the timeline's time is a percentage")
	testing.expect_value(t, e2e.eval(s, "tl.currentTime.unit"), "percent")
	testing.expect_value(t, e2e.eval(s, "tl.axis"), "block")
	// an animation on it: the page's turn commits it, at the start of its range
	e2e.eval(s, "window.a = document.querySelector('#slide').animate({opacity: [0, 1]}, {timeline: tl, fill: 'both'}); 1")
	e2e.wait_frames(s)
	testing.expect_value(t, e2e.eval(s, "a.timeline === tl"), "true")
	near(t, number(s, "a.currentTime.value"), 25, "its current time is the timeline's")
	near(t, number(s, "a.effect.getComputedTiming().progress * 100"), 25, "its progress too")
	near(t, number(s, "getComputedStyle(document.querySelector('#slide')).opacity * 100"), 25, "and what it shows")
	// getAnimations() and the timeline of a CSS animation
	testing.expect_value(t, e2e.eval(s, "bar.getAnimations()[0].timeline instanceof ScrollTimeline"), "true")
	near(t, number(s, "bar.getAnimations()[0].timeline.currentTime.value"), 25, "of a CSS animation")
	near(t, number(s, "bar.getAnimations()[0].currentTime.value"), 25, "its current time")
	testing.expect_value(t, e2e.eval(s, "post.getAnimations()[0].timeline instanceof ViewTimeline"), "true")
	testing.expect_value(t, e2e.eval(s, "post.getAnimations()[0].timeline.subject === post"), "true")
	testing.expect_value(t, e2e.eval(s, "new ViewTimeline({subject: post}).startOffset.value"), fmt.tprint(1500 - int(number(s, "innerHeight"))))
}

// A named timeline: on an ancestor's sibling through timeline-scope; none: no effect.
@(test)
named_timelines_reach_their_animations :: proc(t: ^testing.T) {
	s := open(t)
	near(t, number(s, "new DOMMatrix(getComputedStyle(farther).transform).m41"), 0, "before")
	e2e.eval(s, "far.scrollTop = (far.scrollHeight - far.clientHeight) / 2; 1")
	e2e.wait_frames(s)
	e2e.wait_frames(s)
	near(t, number(s, "new DOMMatrix(getComputedStyle(farther).transform).m41"), 200, "timeline-scope")
	testing.expect_value(t, e2e.eval(s, "getComputedStyle(none).transform"), "none")
	testing.expect_value(t, e2e.eval(s, "getComputedStyle(none).animationTimeline"), "none")
	testing.expect_value(t, e2e.eval(s, "getComputedStyle(bar).animationTimeline"), "scroll(root)")
	testing.expect_value(t, e2e.eval(s, "getComputedStyle(range).animationRangeStart + ' / ' + getComputedStyle(range).animationRangeEnd"), "entry / entry")
}

@(private = "file") WHEEL_AT :: e2e.Point{800, 500}
@(private = "file") SLIDE_COLOR :: [3]u8{0x00, 0x88, 0xaa}
@(private = "file") CHANNEL_WITHIN :: 24
@(private = "file") SLIDE_PX :: 400.0
@(private = "file") ROW_SLIDE, ROW_FADE, ROW_TINT :: 25, 65, 105
@(private = "file") FADE_X, TINT_X, STICKY_X :: 25, 25, 725
@(private = "file") STICKY_LEFT, STICKY_TOP :: 700, 300
@(private = "file") STICKY_COLOR :: [3]u8{0xcc, 0x44, 0x00}
@(private = "file") SHOWN_WITHIN_PX :: 4     // the slide in a frame under the task, against where the scroll puts it
@(private = "file") SHOWN_WITHIN_LEVEL :: 8  // a channel likewise
@(private = "file") NOTCHES :: 4

@(private = "file")
close_to :: proc(c: [3]u8, want: [3]u8) -> bool {
	for k in 0 ..< 3 { if abs(int(c[k]) - int(want[k])) > CHANNEL_WITHIN { return false } }
	return true
}

// The first x of row `y` that shows `color` (-1: none).
@(private = "file")
left_of :: proc(img: e2e.Image, y: int, color: [3]u8) -> int {
	for x in 0 ..< img.width { if close_to(e2e.pixel(img, x, y).rgb, color) { return x } }
	return -1
}

// The first y of column `x` that shows `color` (-1: none).
@(private = "file")
top_of :: proc(img: e2e.Image, x: int, color: [3]u8) -> int {
	for y in 0 ..< img.height { if close_to(e2e.pixel(img, x, y).rgb, color) { return y } }
	return -1
}

// In the chrome frames under a task: the wheel moves the document, and what its timeline drives follows, transform, opacity and a background
// colour, at the frame's offset. The task reads none of it; the page's turn shows the same.
@(test)
what_a_scroll_timeline_drives_follows_the_wheel_under_a_task :: proc(t: ^testing.T) { follows_the_wheel(t, nil) }

// With no layout in chrome frames (a page too long for one): a box keeps its space and its group from the start, as under will-change, and those values follow by themselves.
@(test)
the_compositor_alone_follows_the_wheel_under_a_task :: proc(t: ^testing.T) { follows_the_wheel(t, {"browser.shell.shown_layout_max_ms=0"}) }

@(private = "file")
follows_the_wheel :: proc(t: ^testing.T, prefs: []string) {
	s := open(t, prefs)
	short := false
	near(t, number(s, "getComputedStyle(fade).opacity * 100"), 100, "opaque at the top")
	corner := e2e.box_model(s, "#sticky").window   // (the pictures are of the window; the box is held at its inset from the page's corner)
	ox, oy := int(corner.x) - STICKY_LEFT, int(corner.y) - STICKY_TOP
	notches := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	append(&notches, e2e.busy_capture())
	for _ in 0 ..< NOTCHES { append(&notches, e2e.busy_wheel(s, 1, WHEEL_AT)) }
	append(&notches, e2e.busy_capture())
	shots := while_held(s, &short, notches[:])
	near(t, number(s, "scrolled_in_task"), 0, "the task saw no scroll")
	testing.expect_value(t, e2e.eval(s, "width_in_task"), "0px")
	e2e.wait_frames(s)
	e2e.wait_frames(s)
	y := number(s, "scrollY")
	testing.expectf(t, y > 0, "the page took the scroll")
	p := y / number(s, "document.documentElement.scrollHeight - innerHeight")

	before, after := shots[0], shots[1]
	x0, x1 := left_of(before, oy + ROW_SLIDE, SLIDE_COLOR) - ox, left_of(after, oy + ROW_SLIDE, SLIDE_COLOR) - ox
	testing.expectf(t, x0 == 0, "the slide at its start: %d", x0)
	testing.expectf(t, abs(f64(x1) - SLIDE_PX * p) <= SHOWN_WITHIN_PX, "the slide follows under the task: x %d, the scroll puts it at %v", x1, SLIDE_PX * p)
	// the fade: white shows through its green; the tint: red gives way to blue
	fade, tint := e2e.pixel(after, ox + FADE_X, oy + ROW_FADE), e2e.pixel(after, ox + TINT_X, oy + ROW_TINT)
	testing.expectf(t, abs(f64(fade.r) - 255 * p) <= SHOWN_WITHIN_LEVEL, "the fade follows under the task: red %d, the scroll says %v", fade.r, 255 * p)
	testing.expectf(t, abs(f64(tint.b) - 255 * p) <= SHOWN_WITHIN_LEVEL, "the tint follows under the task: blue %d, the scroll says %v", tint.b, 255 * p)
	// the sticky box stays where its inset holds it
	testing.expectf(t, top_of(after, ox + STICKY_X, STICKY_COLOR) == oy + STICKY_TOP, "a sticky box holds under the wheel: y %d", top_of(after, ox + STICKY_X, STICKY_COLOR) - oy)
	// the page's turn: the same values
	near(t, number(s, "new DOMMatrix(getComputedStyle(slide).transform).m41"), f64(x1), "the page's turn goes on from there")
}

@(private = "file") BAR_COLOR :: [3]u8{0xaa, 0x00, 0x88}
@(private = "file") ROW_BAR :: 135
@(private = "file") BAR_PX :: 600.0
@(private = "file") HEAD_BG :: [3]u8{0x44, 0x66, 0x88}
@(private = "file") HEAD_X, HEAD_TOP :: 290, 150
@(private = "file") HEAD_FROM, HEAD_TO :: 120.0, 40.0
@(private = "file") POST_LEFT_ROW_MARGIN :: 50    // a row inside the post, from its top
@(private = "file") POST_COLOR :: [3]u8{0x88, 0x88, 0x00}

// The length of the run of `color` along row `y`, from `x`.
@(private = "file")
run_right :: proc(img: e2e.Image, y, x: int, color: [3]u8) -> int {
	n := 0
	for i in x ..< img.width {
		if !close_to(e2e.pixel(img, i, y).rgb, color) { break }
		n += 1
	}
	return n
}

// The length of the run of `color` down column `x`, from `y`.
@(private = "file")
run_down :: proc(img: e2e.Image, x, y: int, color: [3]u8) -> int {
	n := 0
	for i in y ..< img.height {
		if !close_to(e2e.pixel(img, x, i).rgb, color) { break }
		n += 1
	}
	return n
}

// Layout properties in the chrome frames under a task: a bar's width, a header's height. The task reads what its turn left, and the page's turn shows the same.
@(test)
layout_values_of_a_timeline_follow_the_wheel_under_a_task :: proc(t: ^testing.T) {
	s := open(t, {"browser.shell.shown_layout_max_ms=100"})   // (past its budget a whole pass is left out, as it should be: on a slow machine that is not what is tested here)
	short := false
	corner := e2e.box_model(s, "#sticky").window
	ox, oy := int(corner.x) - STICKY_LEFT, int(corner.y) - STICKY_TOP
	notches := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	append(&notches, e2e.busy_capture())
	for _ in 0 ..< NOTCHES { append(&notches, e2e.busy_wheel(s, 1, WHEEL_AT)) }
	append(&notches, e2e.busy_capture())
	shots := while_held(s, &short, notches[:])
	testing.expect_value(t, e2e.eval(s, "width_in_task"), "0px")
	e2e.wait_frames(s)
	e2e.wait_frames(s)
	p := number(s, "scrollY") / number(s, "document.documentElement.scrollHeight - innerHeight")
	testing.expectf(t, p > 0, "the page took the scroll")
	before, after := shots[0], shots[1]
	testing.expectf(t, run_right(before, oy + ROW_BAR, ox, BAR_COLOR) == 0, "the bar starts empty")
	bar := run_right(after, oy + ROW_BAR, ox, BAR_COLOR)
	testing.expectf(t, abs(f64(bar) - BAR_PX * p) <= SHOWN_WITHIN_PX, "the bar's width follows under the task: %d, the scroll says %v", bar, BAR_PX * p)
	head := run_down(after, ox + HEAD_X, oy + HEAD_TOP, HEAD_BG)
	want := HEAD_FROM + (HEAD_TO - HEAD_FROM) * p
	testing.expectf(t, abs(f64(head) - want) <= SHOWN_WITHIN_PX, "the header's height follows under the task: %d, the scroll says %v", head, want)
	near(t, number(s, "parseFloat(getComputedStyle(bar).width)"), f64(bar), "the page's turn goes on from there")
}

@(private = "file") INK_X, INK_ROW :: 310, 105        // inside #inked, on the text of the child that takes its colour by inheritance
@(private = "file") INK_MS :: 16_000                    // #inked's animation, red to blue
@(private = "file") INK_AT_MS :: [2]f64{2_000, 6_000}  // the chrome frames' clock at the two pictures, after the page's last frame
@(private = "file") INK_WITHIN_LEVEL :: 1               // a channel against the time: the rounding of the colour, and of the animation's time the task read

// A colour by the clock, on an element and on the child that inherits it: it goes on under the task, with no scroll. The chrome frames
// run on the test's clock (busy_clock), from the time the task read of the animation as it began: the colour at two known times.
@(test)
a_colour_and_what_inherits_it_go_on_under_a_task :: proc(t: ^testing.T) {
	s := open(t, {"style.animations.mode=normal"})   // (whatever the system's reduced motion)
	short := false
	corner := e2e.box_model(s, "#sticky").window
	ox, oy := int(corner.x) - STICKY_LEFT, int(corner.y) - STICKY_TOP
	e2e.eval(s, "inked.style.animationPlayState = 'running'; 1")
	at := INK_AT_MS
	shots := while_held(s, &short, {e2e.busy_clock(at[0]), e2e.busy_capture(), e2e.busy_clock(at[1]), e2e.busy_capture()},
		hold = "hold(() => window.ink_from = inked.getAnimations()[0].currentTime)")
	from := number(s, "ink_from")
	for shot, i in shots {
		p := (from + at[i]) / INK_MS
		testing.expectf(t, p < 1, "the second picture falls inside the animation: %v ms", from + at[i])
		c := e2e.pixel(shot, ox + INK_X, oy + INK_ROW)
		red, blue := 255 * (1 - p), 255 * p
		testing.expectf(t, abs(f64(c.r) - red) <= INK_WITHIN_LEVEL && abs(f64(c.b) - blue) <= INK_WITHIN_LEVEL,
			"the inherited colour under the task, %v ms in: red %d blue %d, the clock says %.1f and %.1f", from + at[i], c.r, c.b, red, blue)
	}
}

// At rest a page of scroll-driven animations draws nothing: a layout that moved a timeline asks for one more frame, not for frames for ever.
@(test)
a_page_of_timelines_at_rest_draws_no_frames :: proc(t: ^testing.T) {
	s := open(t)
	scroll_to(s, 1000)
	e2e.wait_at_rest(s)
}

// A task that changes the document leaves nothing to paint from (the layout's items hold what it changed): the frames show the page's last pixels, moved.
@(test)
a_task_that_changes_the_document_stops_the_layout_values :: proc(t: ^testing.T) {
	s := open(t)
	short := false
	corner := e2e.box_model(s, "#sticky").window
	ox, oy := int(corner.x) - STICKY_LEFT, int(corner.y) - STICKY_TOP
	e2e.eval(s, "window.mutate = true; 1")
	notches := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	for _ in 0 ..< NOTCHES { append(&notches, e2e.busy_wheel(s, 1, WHEEL_AT)) }
	append(&notches, e2e.busy_capture())
	shots := while_held(s, &short, notches[:])
	testing.expectf(t, run_right(shots[0], oy + ROW_BAR, ox, BAR_COLOR) == 0, "the bar stays as it was painted")
	testing.expect_value(t, e2e.eval(s, "document.querySelector('#head').textContent"), "changed")
}

@(private = "file") PERF_NOTCH :: 0.25         // a quarter of a notch at every frame
@(private = "file") PERF_STEPS :: 240
@(private = "file") PERF_FRAMES :: 600
@(private = "file") PERF_OUT :: "build/scroll_driven_frames_%d.tsv"
@(private = "file") PERF_TASKS_MS :: [?]int{50, 200, 500}
@(private = "file") PERF_BAR_ROW, PERF_HEADER_X :: 2, 6   // inside the reading bar; inside the header, left of what it holds
@(private = "file") HEADER_WITHIN :: 2         // a pixel of the header, against the first one (the page around it is near that colour)

// The demo under tasks back to back, frame by frame (Timeline.every): when each frame came, whether it was made under a task, and what it shows of the
// reading bar's width and the header's height against the scroll it shows. An opt-in measure: PERF_OUT has every frame.
@(test)
the_demo_frame_by_frame_under_tasks :: proc(t: ^testing.T) {
	if base.perf_skip("scroll-driven animations frame by frame") { return }
	s := e2e.start(t, {pixels = true, size = SIZE, dpi = e2e.DPI_ONE, url = e2e.file_url(fmt.tprintf("%s/examples/site/scroll_driven.html", e2e.repo_root()))})
	e2e.wait_load(s)
	e2e.wait_frames(s)
	for ms in PERF_TASKS_MS { measure_tasks(t, s, ms) }
}

@(private = "file")
measure_tasks :: proc(t: ^testing.T, s: ^e2e.Session, task_ms: int) {
	e2e.eval(s, fmt.tprintf("document.getElementById('load').value = '%d'; window.scrollTo(0, 0); 1", task_ms))
	e2e.wait_frames(s)
	corner := e2e.box_model(s, "#bar").window
	ox, oy := int(corner.x), int(corner.y)
	range_px := number(s, "document.documentElement.scrollHeight - innerHeight")
	width := number(s, "innerWidth")
	steps := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	for _ in 0 ..< PERF_STEPS { append(&steps, e2e.busy_wheel(s, PERF_NOTCH, WHEEL_AT)) }
	context = s.ctx
	browser.control_timeline_start(s.app, 1, PERF_FRAMES, every = true)
	e2e.while_busy(s, steps[:])
	e2e.wait_until_plain(s, proc(s: ^e2e.Session) -> bool { return e2e.busy_left(s) == 0 }, "the steps taken")
	browser.timeline_end(s.app)
	defer browser.timeline_free(&s.app.remote.tl)
	frames := s.app.remote.tl.frames[:]
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "frame\tms\tgap_ms\tchrome\tscroll\tbar_px\tbar_wanted\theader_px")
	worst_gap, worst_lag, lag_sum, chrome, moved, last_ms := 0.0, 0.0, 0.0, 0, 0, 0.0
	last_bar := -1
	for f, i in frames {
		bar := 0
		for x in ox ..< f.w {
			c := f.pixels[(((oy + PERF_BAR_ROW) * f.w) + x) * 4:]
			if !close_to({c[0], c[1], c[2]}, {0xb4, 0x53, 0x2a}) { break }
			bar += 1
		}
		card := f.pixels[(((oy + PERF_BAR_ROW + 6) * f.w) + ox + PERF_HEADER_X) * 4:]
		header := 0
		for y in oy + PERF_BAR_ROW + 6 ..< f.h {
			c := f.pixels[((y * f.w) + ox + PERF_HEADER_X) * 4:]
			if abs(int(c[0]) - int(card[0])) > HEADER_WITHIN { break }
			header += 1
		}
		wanted := width * f64(f.scroll) / range_px
		gap := i > 0 ? f.ms - last_ms : 0
		last_ms = f.ms
		fmt.sbprintfln(&b, "%d\t%.1f\t%.1f\t%v\t%.0f\t%d\t%.0f\t%d", f.n, f.ms, gap, f.nested, f.scroll, bar, wanted, header)
		worst_gap = max(worst_gap, gap)
		worst_lag = max(worst_lag, abs(f64(bar) - wanted))
		lag_sum += abs(f64(bar) - wanted)
		if f.nested { chrome += 1 }
		if bar != last_bar { moved += 1 }
		last_bar = bar
	}
	_ = os.write_entire_file(fmt.tprintf(PERF_OUT, task_ms), transmute([]u8)strings.to_string(b))
	span := len(frames) > 1 ? frames[len(frames) - 1].ms - frames[0].ms : 0
	tab := browser.current_tab(s.app)
	fmt.printfln("the demo under %d ms tasks: %d frames in %.0f ms (%.1f a second), %d made under a task, %d with a new width of the bar; worst gap %.1f ms, the bar %.1f px at worst and %.1f px on average from where the scroll puts it; a whole layout %.2f ms, the last one made in a chrome frame %.2f ms", task_ms, len(frames), span, f64(len(frames)) * 1000 / max(span, 1), chrome, moved, worst_gap, worst_lag, lag_sum / f64(max(len(frames), 1)), tab.full_layout_ms, tab.shown.ms)
}

// While the task holds the thread, then the page takes the scroll: the pictures of the capture steps.
@(private = "file")
while_held :: proc(s: ^e2e.Session, short: ^bool, steps: []e2e.Busy_Step, hold := "hold()", loc := #caller_location) -> []e2e.Image {
	short^ = !short^
	all := make([dynamic]e2e.Busy_Step, context.temp_allocator)
	append(&all, ..steps)
	append(&all, e2e.busy_resize(short^ ? SHORTER : SIZE))
	e2e.wait_frames(s, loc = loc)
	e2e.eval(s, hold, loc = loc)
	e2e.while_busy(s, all[:], loc)
	e2e.wait_js(s, "window.released === true", loc = loc)
	testing.expectf(s.t, e2e.busy_left(s, loc) == 0, "every step was taken under the task", loc = loc)
	return e2e.busy_shots(s, loc)
}

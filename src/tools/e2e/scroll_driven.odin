package e2e_scenarios

// Scroll-driven animations (examples/site/scroll_driven_probe.html): what each kind of timeline shows at a scroll offset, on the
// page's turn and in the chrome frames made while a script holds the thread.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{1000, 700}
@(private = "file") SHORTER :: [2]int{1000, 690}   // what lets the task go
@(private = "file") DOC_HEIGHT :: 4000             // body's height: the root scroller's range is this less the viewport's
@(private = "file") WITHIN_PX :: 1.5               // a computed length, against what the scroll offset gives

@(private = "file")
open :: proc(t: ^testing.T, loc := #caller_location) -> ^e2e.Session {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = e2e.file_url(fmt.tprintf("%s/examples/site/scroll_driven_probe.html", e2e.repo_root()))}, loc)
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

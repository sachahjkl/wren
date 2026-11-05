package page

import "core:math"
import "core:strings"
import "wb:base"
import "wb:style"

// ScrollTimeline and ViewTimeline for scripts (Scroll-driven Animations 1, Web Animations 2 §4.4): timelines whose time is a
// percentage of a scroller's range. The style timeline measures them with the CSS ones (style/script_anim.odin); an animation
// attached to one (Web_Animation.progress) counts its start time, hold time and current time in percents of it, starts at the
// beginning of its attachment range (rangeStart, rangeEnd: `auto-align`), and its effect's timing shares that range.

Web_Progress_Timeline :: struct {
	page: ^Page,
	id:   u64,    // its key on the style timeline
}

web_progress_timeline_vt := Object_VTable{name = "ScrollTimeline", destroy = web_progress_timeline_destroy}

lookup_ProgressTimeline :: proc(c: ^Call, h: u64) -> ^Web_Progress_Timeline { return (^Web_Progress_Timeline)(object_data(c.page, h, &web_progress_timeline_vt)) }

@(private)
web_progress_timeline_destroy :: proc(p: ^Page, data: rawptr) {
	t := (^Web_Progress_Timeline)(data)
	if !p.closed && p.anim.timeline != nil { style.timeline_progress_remove(p.anim.timeline, t.id) }
	free(t)
}

@(private = "file")
progress_timeline_new :: proc(p: ^Page, owner: u32) -> (h: u64, t: ^Web_Progress_Timeline) {
	w := anims_of(p)
	t = new(Web_Progress_Timeline)
	w.next_id += 1
	t.page, t.id = p, w.next_id
	return object_create(p, &web_progress_timeline_vt, t, owner), t
}

ProgressTimeline_create :: proc(c: ^Call, source: Api_Element, none: bool, subject: Api_Element, axis: i32, inset: string) -> u64 {
	p := c.page
	if call_doc(c) == nil { return 0 }
	h, t := progress_timeline_new(p, c.owner)
	view := subject.data != nil
	i, ok := style.parse_inset_text(p.engine, inset)
	if !ok { i = style.AUTO_INSET }
	node := H(source.handle)
	if !view && node == jd_document_element(p.doc) { node = base.NIL_HANDLE }
	style.timeline_progress_put(p.anim.timeline, t.id, view, none, node, H(subject.handle), style.Timeline_Axis(clamp(axis, 0, 3)), i)
	scroll_timelines_now(p)
	return h
}

// The timeline object of a CSS animation on a scroll or view timeline.
@(private)
css_timeline_object :: proc(c: ^Call, t: style.Css_Timeline_Info) -> u64 {
	p := c.page
	h, w := progress_timeline_new(p, c.owner)
	style.timeline_progress_put(p.anim.timeline, w.id, t.kind == .View, false, t.source, t.subject, t.axis, t.inset)
	scroll_timelines_now(p)
	return h
}

// A new timeline reads its scroller at once, as the next frame would: its current time is there for the script that made it.
@(private = "file")
scroll_timelines_now :: proc(p: ^Page) {
	l, vp := js_layout_now(p)
	scroll_timelines_sample(p, l, vp)
}

ProgressTimeline_currentTime :: proc(c: ^Call, timeline: Api_ProgressTimeline) -> f64 {
	percent, active := style.timeline_progress_percent(c.page.anim.timeline, timeline.data.id)
	return active ? percent : math.nan_f64()
}

ProgressTimeline_source :: proc(c: ^Call, timeline: Api_ProgressTimeline) -> u64 {
	return u64(style.timeline_progress_source(c.page.anim.timeline, timeline.data.id))
}

ProgressTimeline_offset :: proc(c: ^Call, timeline: Api_ProgressTimeline, which: i32) -> f64 {
	a, b, ok := style.timeline_progress_offsets(c.page.anim.timeline, timeline.data.id)
	if !ok { return 0 }
	return which == 0 ? a : b
}

Animation_setProgressTimeline :: proc(c: ^Call, animation: Api_Animation, timeline: Api_ProgressTimeline) {
	a := animation.data
	if a.css != 0 { return }
	a.timeline, a.progress = true, timeline.data.id
	if a.has_start || a.pending == .Play {
		// (a time in ms means nothing on it: a running animation aligns with its range)
		a.auto_align = true
		a.has_start, a.has_hold = false, false
		if a.pending == .None {
			anim_new_ready(a)
			a.pending = .Play
		}
	}
	anim_changed(a)
}

Animation_isProgress :: proc(c: ^Call, animation: Api_Animation) -> bool {
	a := animation.data
	if a.css != 0 {
		info, _ := style.timeline_css_timeline(c.page.anim.timeline, a.css)
		return info.kind == .Scroll || info.kind == .View
	}
	return a.progress != 0
}

Animation_setRange :: proc(c: ^Call, animation: Api_Animation, which: i32, text: string) -> bool {
	a := animation.data
	r, ok := style.parse_range_text(c.page.engine, text)
	if !ok { return false }
	a.range[clamp(which, 0, 1)] = r
	if a.progress != 0 && a.pending == .None && a.auto_align { a.start = anim_range_percent(a)[a.rate < 0 ? 1 : 0] }
	anim_changed(a)
	return true
}

Animation_range :: proc(c: ^Call, animation: Api_Animation, which: i32) -> string {
	i := clamp(which, 0, 1)
	return strings.clone(style.range_text_of(animation.data.range[i], i == 0 ? 0 : 100, css_length), context.temp_allocator)
}

// The attachment range of an animation on a progress timeline, in percents of it.
@(private)
anim_range_percent :: proc(a: ^Web_Animation) -> [2]f64 {
	lo, hi := style.timeline_progress_range(a.page.anim.timeline, a.progress, a.range)
	return {lo, hi}
}

// The time of an animation's timeline; ok false: it has none now.
@(private)
anim_now :: proc(a: ^Web_Animation) -> (now: f64, ok: bool) {
	if a.progress != 0 { return style.timeline_progress_percent(a.page.anim.timeline, a.progress) }
	return anims_now(a.page), true
}

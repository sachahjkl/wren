package page

// CSS animations and transitions as Animation objects (CSS Animations 2 CSSAnimation, CSS Transitions 2 CSSTransition):
// getAnimations() lists them with the scripts' animations. Each running CSS animation or transition of the style
// timeline (style/css_anim_api.odin, known by a serial never reused) gets a Web_Animation host object with `css` set the
// first time a script sees it, kept in Web_Anims.css while it lasts: the same object at every call. Its state is read
// from the timeline (play state, current time, start time); pause() / play() hold it over animation-play-state, cancel()
// stops it, finish() and currentTime seek it. Its ready and finished promises are not settled (the timeline does not
// report to them).

import "core:slice"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:style"

Css_Anim_Op :: enum u8 { Play, Pause, Cancel, Finish }

@(private)
css_anim_control :: proc(a: ^Web_Animation, op: Css_Anim_Op) {
	tl := a.page.anim.timeline
	switch op {
	case .Play: style.timeline_css_pause(tl, a.css, false)
	case .Pause: style.timeline_css_pause(tl, a.css, true)
	case .Cancel: style.timeline_css_cancel(tl, a.css)
	case .Finish: style.timeline_css_seek(tl, a.css, anim_end(a))
	}
}

// The Animation object of a CSS animation or transition (made on first sight).
@(private)
css_anim_object :: proc(p: ^Page, info: style.Css_Anim_Info) -> u64 {
	w := anims_of(p)
	if h, ok := w.css[info.serial]; ok && object_data(p, h, &web_animation_vt) != nil { return h }
	a := new(Web_Animation)
	w.next_id += 1
	a.page, a.id, a.css, a.css_transition = p, w.next_id, info.serial, info.transition
	a.css_name = strings.clone(info.name)
	a.target = info.node
	a.timeline = true
	a.rate = 1
	a.ready, a.finished = .Resolved, .Pending
	a.self = object_create(p, &web_animation_vt, a, 0)
	w.css[info.serial] = a.self
	return a.self
}

// Appends (8 bytes each) the CSS transitions, then the CSS animations, of the elements in scope, in tree order; the
// ones a script canceled, and the finished ones that do not fill, are not relevant.
@(private)
css_relevant :: proc(p: ^Page, d: ^dom.Document, r: base.Handle, subtree: bool, in_scope: proc(d: ^dom.Document, target, r: base.Handle, subtree: bool) -> bool, out: ^[dynamic]u8) {
	tl := p.anim.timeline
	nodes := style.timeline_css_nodes(tl)
	if len(nodes) == 0 { return }
	scoped := make([dynamic]base.Handle, 0, len(nodes), context.temp_allocator)
	for n in nodes { if dom.get(d, n) != nil && in_scope(d, n, r, subtree) { append(&scoped, n) } }
	context.user_ptr = d
	slice.sort_by(scoped[:], proc(a, b: base.Handle) -> bool { return dom.tree_order_compare((^dom.Document)(context.user_ptr), a, b) < 0 })
	for pass in 0 ..< 2 {
		for n in scoped {
			for info in style.timeline_css_animations(tl, n) {
				if info.transition != (pass == 0) || info.canceled || (info.finished && !info.filling) { continue }
				v := css_anim_object(p, info)
				for k in 0 ..< 8 { append(out, u8(v >> (8 * uint(k)))) }
			}
		}
	}
}

Animation_cssBind :: proc(c: ^Call, animation: Api_Animation, notify: u32, user: i32) -> Api_CssAnimationInfo {
	a := animation.data
	if a.css == 0 { return {} }
	a.instance, a.notify, a.user = c.owner, notify, u32(user)
	info, _ := style.timeline_css_info(c.page.anim.timeline, a.css)
	return {kind = a.css_transition ? 2 : 1, target = u64(a.target), delay = info.delay, duration = info.duration, iterations = info.iterations}
}

Animation_cssName :: proc(c: ^Call, animation: Api_Animation) -> string {
	return animation.data.css_name
}

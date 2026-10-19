package style

import "core:math"
import "core:testing"
import "wb:css"
import "wb:dom"
import "wb:html"

@(private = "file")
Ax :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
	tl:  ^Timeline,
}

@(private = "file")
open :: proc(src: string, mode := Anim_Mode.Normal) -> Ax {
	f: Ax
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	s.anim_mode = mode
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
close :: proc(f: ^Ax) {
	timeline_destroy(f.tl, f.st)
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
node :: proc(f: ^Ax, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

// A state change at time `ms`, as the page does it: partial restyle, then the timeline.
@(private = "file")
set_state :: proc(f: ^Ax, st: State, ms: f64) {
	changed, ok := restyle_state(f.eng, f.doc, f.st, st)
	_ = changed
	if !ok {
		old := f.st
		f.st = compute_styles(f.eng, f.doc, st)
		timeline_restyled(f.tl, f.doc, old, f.st, ms)
		styled_destroy(old)
	} else {
		timeline_restyled_partial(f.tl, f.doc, f.st, ms)
	}
	timeline_tick(f.tl, f.doc, f.st, ms)
}

@(private = "file")
tick :: proc(f: ^Ax, ms: f64) { timeline_tick(f.tl, f.doc, f.st, ms) }

@(private = "file")
close_to :: proc(a, b: f64, eps := 0.002) -> bool { return math.abs(a - b) <= eps }

@(private = "file")
count_events :: proc(f: ^Ax, kind: Anim_Event_Kind) -> int {
	n := 0
	for e in timeline_events(f.tl) { if e.kind == kind { n += 1 } }
	return n
}

////////////////////////////////
// Easing

@(test)
easing_functions :: proc(t: ^testing.T) {
	testing.expect(t, close_to(cubic_bezier(0.25, 0.1, 0.25, 1, 0.5), 0.8024033877399112, 1e-4), "ease at 50%")
	testing.expect(t, close_to(cubic_bezier(0.42, 0, 0.58, 1, 0.5), 0.5, 1e-6), "ease-in-out is symmetric")
	testing.expect(t, close_to(cubic_bezier(0.42, 0, 1, 1, 0.25), 0.0934, 2e-3), "ease-in at 25%")
	testing.expect(t, close_to(cubic_bezier(0, 0, 0.58, 1, 0.75), 0.9065, 2e-3), "ease-out at 75%")
	testing.expect(t, close_to(cubic_bezier(0.1, 0.6, 0.7, 0.2, 0.3), cubic_bezier(0.1, 0.6, 0.7, 0.2, 0.3)), "deterministic")
	testing.expect(t, cubic_bezier(0.3, 1.8, 0.6, -0.8, 0.2) > 0.4, "y outside 0..1 overshoots")
	steps :: proc(n: i32, pos: Step_Position) -> Easing { return Easing{kind = .Steps, steps = n, pos = pos} }
	testing.expect(t, close_to(easing_eval(steps(4, .Jump_End), 0.3), 0.25))
	testing.expect(t, close_to(easing_eval(steps(4, .Jump_Start), 0.3), 0.5))
	testing.expect(t, close_to(easing_eval(steps(4, .Jump_End), 1), 1))
	testing.expect(t, close_to(easing_eval(steps(5, .Jump_None), 0.5), 0.5))
	testing.expect(t, close_to(easing_eval(steps(5, .Jump_None), 0), 0))
	testing.expect(t, close_to(easing_eval(steps(3, .Jump_Both), 0), 0.25))
	testing.expect(t, close_to(easing_eval(steps(3, .Jump_Both), 0.5), 0.5))
	testing.expect(t, close_to(easing_eval(steps(1, .Jump_Start), 0), 1), "step-start at 0 is already up")
	testing.expect(t, close_to(easing_eval(steps(1, .Jump_Start), 0, before = true), 0), "... but not in the before phase")

	f := open(`<style>
		#a { transition-timing-function: linear(0, 0.25 75%, 1), steps(3, jump-both), cubic-bezier(0.1, 0.2, 0.3, 0.4), ease-in }
		#b { transition-timing-function: cubic-bezier(2, 0, 0, 1) }
	</style><div id=a></div><div id=b></div>`)
	defer close(&f)
	a := node(&f, "a")
	testing.expect_value(t, len(a.transition_timing), 4)
	lin := a.transition_timing[0]
	testing.expect(t, lin.kind == .Points && len(lin.points) == 3)
	testing.expect(t, close_to(easing_eval(lin, 0.5), 0.25 * 0.5 / 0.75))
	testing.expect(t, close_to(easing_eval(lin, 0.875), 0.625))
	testing.expect(t, a.transition_timing[1].kind == .Steps && a.transition_timing[1].pos == .Jump_Both)
	e := node(&f, "b").transition_timing[0]
	testing.expect(t, e.kind == .Cubic_Bezier && e.p == EASE.p, "x outside 0..1 is invalid: the initial value stays")
}

////////////////////////////////
// Parsing

@(test)
transition_and_animation_lists :: proc(t: ^testing.T) {
	f := open(`<style>
		#a { transition: opacity 2s ease-in 0.5s, transform 300ms allow-discrete, margin 1s }
		#b { animation: 2s ease-in 1s infinite alternate both paused spin, 500ms fade }
		#c { transition: none }
		#d { transition-property: color, width, bogus-prop; transition-duration: 1s, 2s }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div>`)
	defer close(&f)
	a := node(&f, "a")
	testing.expect_value(t, len(a.transition_property), 3)
	testing.expect(t, a.transition_property[0].kind == .Prop && a.transition_property[0].prop == .Opacity)
	testing.expect(t, a.transition_property[2].kind == .Short && a.transition_property[2].short == .Margin)
	s0 := transition_at(a, 0)
	testing.expect(t, s0.duration == 2000 && s0.delay == 500 && s0.easing.p == [4]f32{0.42, 0, 1, 1})
	testing.expect(t, transition_at(a, 1).allow_discrete && transition_at(a, 1).duration == 300)
	b := node(&f, "b")
	testing.expect_value(t, len(b.animation_name), 2)
	s := animation_at(b, 0)
	testing.expect(t, s.name == "spin" && s.duration == 2000 && s.delay == 1000 && math.is_inf(s.iterations))
	testing.expect(t, s.direction == .Alternate && s.fill == .Both && s.play_state == .Paused)
	testing.expect(t, animation_at(b, 1).name == "fade" && animation_at(b, 1).iterations == 1)
	testing.expect(t, node(&f, "c").transition_property[0].kind == .None)
	d := node(&f, "d")
	testing.expect(t, len(d.transition_property) == 3 && d.transition_property[2].kind == .Unknown, "an unknown name keeps its place")
	testing.expect(t, transition_at(d, 2).duration == 1000, "shorter lists repeat")
}

@(test)
transforms_parse_and_matrix :: proc(t: ^testing.T) {
	f := open(`<style>
		#r { transform: rotate(90deg); width: 100px; height: 100px }
		#t { transform: translate(10px, 50%) }
		#s { transform: scale(2) }
		#m { transform: matrix(1, 2, 3, 4, 5, 6) rotateX(60deg) translate3d(1px, 2px, 3px) skewX(45deg) }
		#i { translate: 5px 6px; rotate: 0.25turn; scale: 2 3 }
		#o { transform-origin: left top; transform: rotate(180deg) }
		#bad { transform: rotate(10px) }
	</style><div id=r></div><div id=t></div><div id=s></div><div id=m></div><div id=i></div><div id=o></div><div id=bad></div>`)
	defer close(&f)
	near_m :: proc(m: Matrix, want: Matrix) -> bool {
		for i in 0 ..< 6 { if math.abs(m[i] - want[i]) > 1e-3 { return false } }
		return true
	}
	r := transform_matrix(node(&f, "r"), 0, 0, 100, 100)
	p := matrix_apply(r, 0, 0)
	testing.expectf(t, math.abs(p.x - 100) < 1e-3 && math.abs(p.y) < 1e-3, "rotate(90deg) around the center: top-left goes to top-right, got %v", p)
	testing.expect(t, near_m(transform_matrix(node(&f, "t"), 0, 0, 100, 40), Matrix{1, 0, 0, 1, 10, 20}), "translate percentages refer to the box")
	q := matrix_apply(transform_matrix(node(&f, "s"), 0, 0, 100, 100), 0, 0)
	testing.expect(t, math.abs(q.x + 50) < 1e-3 && math.abs(q.y + 50) < 1e-3, "scale(2) around the center")
	m := node(&f, "m").transform
	testing.expect_value(t, len(m), 4)
	testing.expect(t, m[1].kind == .Scale && math.abs(m[1].v[1] - 0.5) < 1e-4, "rotateX is flattened to its projection")
	testing.expect(t, m[2].kind == .Translate && m[3].kind == .Skew)
	i := node(&f, "i")
	testing.expect(t, i.translate.set && i.rotate.set && i.scale.set && i.scale.s[1] == 3)
	im := transform_matrix(i, 0, 0, 0, 0)
	testing.expect(t, near_m(im, Matrix{0, 2, -3, 0, 5, 6}), "translate, then rotate, then scale")
	o := matrix_apply(transform_matrix(node(&f, "o"), 0, 0, 10, 10), 10, 10)
	testing.expect(t, math.abs(o.x + 10) < 1e-3 && math.abs(o.y + 10) < 1e-3, "transform-origin: left top")
	testing.expect(t, node(&f, "bad").transform == nil)
	// decomposition round trip
	src := Matrix{0.8, 0.6, -1.2, 1.6, 7, -3}
	testing.expect(t, near_m(recompose(decompose(src)), src))
}

////////////////////////////////
// Interpolation

@(test)
interpolating_values :: proc(t: ^testing.T) {
	f := open(`<style>
		#a { width: 10px; margin-left: 10%; color: rgba(255, 0, 0, 0); box-shadow: 2px 2px 4px black; opacity: 0;
		     transform: translate(0px) rotate(0deg); visibility: hidden; z-index: 1; font-weight: 100 }
		#b { width: 30px; margin-left: 20px; color: red; box-shadow: 4px 6px 8px black, inset 1px 1px red; opacity: 1;
		     transform: translate(10px) rotate(90deg); visibility: visible; z-index: 4; font-weight: 900 }
		#c { transform: scale(2) } #d { transform: rotate(90deg) translate(10%) }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div>`)
	defer close(&f)
	a, b := node(&f, "a"), node(&f, "b")
	ctx := Interp_Ctx{alloc = context.temp_allocator}
	out := new(Computed, context.temp_allocator)
	out^ = a^
	testing.expect(t, interpolate_prop(out, a, b, .Width, 0.25, &ctx) && out.width.kind == .Px && out.width.v == 15)
	testing.expect(t, interpolate_prop(out, a, b, .Margin_Left, 0.5, &ctx) && out.margin[.Left].kind == .Calc)
	testing.expect(t, math.abs(resolve(out.margin[.Left], 200) - (0.5 * 20 + 0.5 * 20)) < 1e-3, "10% of 200 and 20px meet halfway through calc()")
	testing.expect(t, interpolate_prop(out, a, b, .Color, 0.5, &ctx))
	testing.expectf(t, math.abs(out.color.r - 1) < 1e-3 && math.abs(out.color.a - 0.5) < 1e-3, "premultiplied: transparent red to red stays red, got %v", out.color)
	testing.expect(t, interpolate_prop(out, a, b, .Box_Shadow, 0.5, &ctx) && len(out.box_shadow) == 2, "the shorter shadow list is padded")
	testing.expect(t, out.box_shadow[0].x == 3 && out.box_shadow[0].blur == 6 && out.box_shadow[1].inset && math.abs(out.box_shadow[1].color.a - 0.5) < 1e-3)
	testing.expect(t, interpolate_prop(out, a, b, .Transform, 0.5, &ctx) && len(out.transform) == 2)
	testing.expect(t, out.transform[0].kind == .Translate && out.transform[0].l[0].v == 5 && math.abs(out.transform[1].v[0] - math.PI / 4) < 1e-4, "function by function")
	testing.expect(t, interpolate_prop(out, a, b, .Visibility, 0.1, &ctx) && out.visibility == .Visible, "visible wins in between")
	testing.expect(t, interpolate_prop(out, a, b, .Z_Index, 0.5, &ctx) && out.z_index == 3, "integers round")
	testing.expect(t, interpolate_prop(out, a, b, .Font_Weight, 0.5, &ctx) && out.font_weight == 500)
	testing.expect(t, !interpolate_prop(out, a, b, .Display, 0.5, &ctx) || a.display == b.display)
	// different function lists: matrix interpolation; with box-relative lengths, a deferred mix
	c, d := node(&f, "c"), node(&f, "d")
	testing.expect(t, interpolate_prop(out, c, b, .Transform, 0.5, &ctx) && len(out.transform) == 1 && out.transform[0].kind == .Matrix)
	testing.expect(t, interpolate_prop(out, c, d, .Transform, 0.5, &ctx) && out.transform[0].kind == .Mix)
	mm := transform_matrix(out, 0, 0, 100, 100)
	testing.expect(t, !math.is_nan(mm[0]), "a mix resolves with the box")
	// discrete
	discrete_prop(out, a, b, .Visibility, 0.4)
	testing.expect(t, out.visibility == .Hidden)
	discrete_prop(out, a, b, .Visibility, 0.6)
	testing.expect(t, out.visibility == .Visible)
}

////////////////////////////////
// Transitions

@(test)
transitions_start_reverse_cancel :: proc(t: ^testing.T) {
	f := open(`<style>
		#a { opacity: 1; transition: opacity 1000ms linear }
		#a:hover { opacity: 0 }
		#b { width: 100px; transition: width 1s linear 500ms }
		#b:hover { width: 200px }
	</style><div id=a>a</div><div id=b>b</div>`)
	defer close(&f)
	a := dom.find_by_id(f.doc, "a")
	b := dom.find_by_id(f.doc, "b")
	set_state(&f, State{hover = a}, 1000)
	testing.expect(t, count_events(&f, .Transition_Run) == 1 && count_events(&f, .Transition_Start) == 1)
	testing.expect(t, close_to(f64(node(&f, "a").opacity), 1), "at the start the old value shows")
	testing.expect(t, timeline_active(f.tl), "a running transition wants frames")
	timeline_clear_events(f.tl)
	tick(&f, 1250)
	testing.expect(t, close_to(f64(node(&f, "a").opacity), 0.75))
	testing.expect(t, close_to(f64(base_style_of(f.st, a).opacity), 0), "the cascaded value is the end value")
	// reversal at 25%: the new transition is shortened to 250ms
	set_state(&f, State{}, 1250)
	testing.expect(t, count_events(&f, .Transition_Cancel) == 1 && count_events(&f, .Transition_Run) == 1)
	tick(&f, 1375)
	testing.expectf(t, close_to(f64(node(&f, "a").opacity), 0.875), "halfway back, got %v", node(&f, "a").opacity)
	tick(&f, 1500)
	testing.expect(t, close_to(f64(node(&f, "a").opacity), 1) && count_events(&f, .Transition_End) == 1)
	tick(&f, 1600)
	testing.expect(t, !timeline_active(f.tl) && timeline_running(f.tl) == 0, "nothing left to run: no frames")
	testing.expect(t, node(&f, "a") == base_style_of(f.st, a), "the overlay is gone")
	timeline_clear_events(f.tl)

	// delay: the start value holds, transitionstart fires when the delay is over
	set_state(&f, State{hover = b}, 2000)
	testing.expect(t, count_events(&f, .Transition_Run) == 1 && count_events(&f, .Transition_Start) == 0)
	testing.expect(t, close_to(timeline_next_ms(f.tl), 500), "the next change is when the delay ends")
	tick(&f, 2400)
	testing.expect(t, node(&f, "b").width.v == 100)
	tick(&f, 3000)
	testing.expect(t, count_events(&f, .Transition_Start) == 1 && close_to(f64(node(&f, "b").width.v), 150))
	// going back while running, not to the reversing start: a plain new transition from the current value
	set_state(&f, State{hover = a}, 3000)
	testing.expect(t, count_events(&f, .Transition_Cancel) == 1, "b's transition is replaced")
	tick(&f, 3500)
	testing.expectf(t, close_to(f64(node(&f, "b").width.v), 150), "still in the delay of the new one, got %v", node(&f, "b").width.v)
}

@(test)
transitions_follow_preferences :: proc(t: ^testing.T) {
	f := open(`<style>#a { opacity: 1; transition: opacity 1s } #a:hover { opacity: 0 }</style><div id=a>a</div>`, .Off)
	defer close(&f)
	set_state(&f, State{hover = dom.find_by_id(f.doc, "a")}, 100)
	testing.expect(t, node(&f, "a").opacity == 0 && timeline_running(f.tl) == 0 && len(timeline_events(f.tl)) == 0, "off: the end value at once, no event")
}

@(test)
inherited_animated_values_reach_descendants :: proc(t: ^testing.T) {
	f := open(`<style>
		#p { color: rgb(0, 0, 0); transition: color 1s linear }
		#p:hover { color: rgb(200, 0, 0) }
		#own { color: blue }
	</style><div id=p><span id=c>text <b id=g>bold</b></span><i id=own>own</i></div>`)
	defer close(&f)
	set_state(&f, State{hover = dom.find_by_id(f.doc, "p")}, 0)
	tick(&f, 500)
	testing.expectf(t, math.abs(node(&f, "c").color.r - 100.0 / 255) < 0.01, "the child inherits the animated color, got %v", node(&f, "c").color)
	testing.expect(t, math.abs(node(&f, "g").color.r - 100.0 / 255) < 0.01, "and the grandchild")
	testing.expect(t, node(&f, "own").color.b > 0.99, "an element with its own color is not touched")
	tick(&f, 1500)
	testing.expect(t, math.abs(node(&f, "g").color.r - 200.0 / 255) < 0.01)
}

////////////////////////////////
// Animations

@(test)
keyframe_animations :: proc(t: ^testing.T) {
	f := open(`<style>
		@keyframes move { from { margin-left: 0px } to { margin-left: 100px } }
		@keyframes mid { 50% { opacity: 0 } }
		@keyframes steps { 0% { width: 0px; animation-timing-function: steps(2) } 100% { width: 100px } }
		@layer x { @keyframes move { from { margin-left: 999px } to { margin-left: 999px } } }
		#a { animation: move 1000ms linear 2 alternate forwards }
		#b { opacity: 1; animation: mid 1000ms linear }
		#c { animation: steps 1000ms linear }
		#d { animation: missing 1s }
		#e { animation: move 1000ms linear 500ms backwards; margin-left: 7px }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div><div id=e></div>`)
	defer close(&f)
	ml :: proc(f: ^Ax, id: string) -> f32 { return node(f, id).margin[.Left].v }
	testing.expect(t, count_events(&f, .Animation_Start) == 3, "a, b, c start (e is in its delay, d has no keyframes)")
	testing.expect(t, ml(&f, "a") == 0, "the unlayered @keyframes wins over the layered one")
	testing.expect(t, ml(&f, "e") == 0, "fill backwards: the first keyframe during the delay")
	timeline_clear_events(f.tl)
	tick(&f, 250)
	testing.expect(t, close_to(f64(ml(&f, "a")), 25))
	testing.expectf(t, close_to(f64(node(&f, "b").opacity), 0.5), "implicit 0%% keyframe is the underlying value, got %v", node(&f, "b").opacity)
	testing.expect(t, node(&f, "c").width.v == 0, "steps(2) holds")
	tick(&f, 600)
	testing.expect(t, node(&f, "c").width.v == 50)
	testing.expect(t, close_to(f64(node(&f, "b").opacity), 0.2), "past the middle, toward the implicit 100%%")
	testing.expect(t, count_events(&f, .Animation_Start) == 1, "e leaves its delay")
	tick(&f, 1250)
	testing.expect(t, count_events(&f, .Animation_Iteration) == 1)
	testing.expectf(t, close_to(f64(ml(&f, "a")), 75), "second iteration runs backwards, got %v", ml(&f, "a"))
	testing.expect(t, node(&f, "b").opacity == 1 && count_events(&f, .Animation_End) >= 2, "b and c are over; fill none: the cascaded value")
	tick(&f, 2500)
	testing.expect(t, ml(&f, "a") == 0, "fill forwards keeps the end of the last (reversed) iteration")
	testing.expect(t, ml(&f, "e") == 7, "e is over and does not fill forwards")
	testing.expect(t, !timeline_active(f.tl) && timeline_next_ms(f.tl) < 0, "all finished: idle")
}

@(test)
animation_play_state_and_name_changes :: proc(t: ^testing.T) {
	f := open(`<style>
		@keyframes grow { from { width: 0px } to { width: 100px } }
		#a { animation: grow 1000ms linear infinite }
		#a:hover { animation-play-state: paused }
		#b { animation: grow 1000ms linear }
		#b:hover { animation-name: none }
	</style><div id=a></div><div id=b></div>`)
	defer close(&f)
	a := dom.find_by_id(f.doc, "a")
	tick(&f, 300)
	testing.expect(t, close_to(f64(node(&f, "a").width.v), 30))
	set_state(&f, State{hover = a}, 300)
	tick(&f, 900)
	testing.expect(t, close_to(f64(node(&f, "a").width.v), 30), "paused: time stands still")
	testing.expect(t, !timeline_active(f.tl) || node(&f, "b").width.v < 100)
	set_state(&f, State{}, 900)
	tick(&f, 1000)
	testing.expect(t, close_to(f64(node(&f, "a").width.v), 40), "running again from where it stopped")
	timeline_clear_events(f.tl)
	set_state(&f, State{hover = dom.find_by_id(f.doc, "b")}, 1000)
	testing.expect(t, count_events(&f, .Animation_Cancel) == 0, "b had already ended at 1000ms: nothing to cancel")
	tick(&f, 1400)
	testing.expect(t, close_to(f64(node(&f, "a").width.v), 80))
}

////////////////////////////////
// Counters, quotes, gradients, font faces, other properties

@(test)
counters_and_quotes :: proc(t: ^testing.T) {
	f := open(`<style>
		li::before { content: counters(list-item, ".") " " }
		h2 { counter-increment: chapter; }
		h2::before { content: counter(chapter, upper-roman) ". " }
		body { counter-reset: chapter }
		q { quotes: "<" ">" "(" ")" }
		.lower { list-style-type: lower-alpha }
		.arm { list-style-type: upper-armenian }
	</style>
	<h2 id=h1>A</h2><h2 id=h2>B</h2>
	<ol><li id=l1>one</li><li id=l2>two<ol><li id=l21>two.one</li><li id=l22>two.two</li></ol></li><li id=l3>three</li></ol>
	<ol reversed><li id=r1>x</li><li id=r2>y</li><li id=r3>z</li></ol>
	<ol start=5 class=lower><li id=s1>e</li><li id=s2 value=10>j</li><li id=s3>k</li></ol>
	<ul class=arm><li id=m1>i</li></ul>
	<p><q id=q1>outer <q id=q2>inner</q></q></p>`)
	defer close(&f)
	before :: proc(f: ^Ax, id: string) -> string {
		c := node(f, id)
		if c == nil || c.before == nil || len(c.before.content.items) == 0 { return "" }
		return c.before.content.items[0].text
	}
	after :: proc(f: ^Ax, id: string) -> string {
		c := node(f, id)
		if c == nil || c.after == nil || len(c.after.content.items) == 0 { return "" }
		return c.after.content.items[0].text
	}
	testing.expect_value(t, before(&f, "h1"), "I. ")
	testing.expect_value(t, before(&f, "h2"), "II. ")
	testing.expect_value(t, before(&f, "l1"), "1 ")
	testing.expect_value(t, before(&f, "l21"), "2.1 ")
	testing.expect_value(t, before(&f, "l22"), "2.2 ")
	testing.expect_value(t, before(&f, "l3"), "3 ")
	testing.expect_value(t, node(&f, "l3").marker_text, "3. ")
	testing.expect_value(t, node(&f, "r1").marker_text, "3. ")
	testing.expect_value(t, node(&f, "r3").marker_text, "1. ")
	testing.expect_value(t, node(&f, "s1").marker_text, "e. ")
	testing.expect_value(t, node(&f, "s2").marker_text, "j. ")
	testing.expect_value(t, node(&f, "s3").marker_text, "k. ")
	testing.expect_value(t, node(&f, "m1").marker_text, "Ա. ")
	testing.expect_value(t, before(&f, "q1"), "<")
	testing.expect_value(t, before(&f, "q2"), "(")
	testing.expect_value(t, after(&f, "q2"), ")")
	testing.expect_value(t, after(&f, "q1"), ">")
	testing.expect(t, f.st.counters_used)

	testing.expect_value(t, format_counter(1994, {style = .Upper_Roman}, context.temp_allocator), "MCMXCIV")
	testing.expect_value(t, format_counter(28, {style = .Lower_Alpha}, context.temp_allocator), "ab")
	testing.expect_value(t, format_counter(7, {style = .Decimal_Leading_Zero}, context.temp_allocator), "07")
	testing.expect_value(t, format_counter(12, {style = .Arabic_Indic}, context.temp_allocator), "\u0661\u0662")
	testing.expect_value(t, format_counter(5000, {style = .Lower_Roman}, context.temp_allocator), "5000")
	testing.expect_value(t, format_counter(15, {style = .Hebrew}, context.temp_allocator), "טו")
	testing.expect_value(t, format_counter(1, {style = .Lower_Greek}, context.temp_allocator), "α")
	testing.expect_value(t, format_counter(12, {style = .Simp_Chinese_Informal}, context.temp_allocator), "十二")
	testing.expect_value(t, format_counter(105, {style = .Simp_Chinese_Informal}, context.temp_allocator), "一百零五")
}

@(test)
counters_survive_partial_restyles :: proc(t: ^testing.T) {
	f := open(`<style>
		li:hover { color: red }
		li::before { content: counter(list-item) ": " }
		.x:hover { display: none }
	</style><ol><li id=a>a</li><li id=b>b</li><li id=c>c</li></ol><p class=x id=x>no counters here</p>`)
	defer close(&f)
	changed, ok := restyle_state(f.eng, f.doc, f.st, State{hover = dom.find_by_id(f.doc, "b")})
	testing.expect(t, changed && ok, "a color change keeps the counters: the restyle stays partial")
	testing.expect_value(t, node(&f, "b").before.content.items[0].text, "2: ")
	_, ok = restyle_state(f.eng, f.doc, f.st, State{hover = dom.find_by_id(f.doc, "x")})
	testing.expect(t, ok, "hiding something that uses no counter stays partial")

	g := open(`<style>
		nav > ul > li > ul { display: none } nav > ul > li:hover > ul { display: block }
		nav > ol > li > ol { display: none } nav > ol > li:hover > ol { display: block }
	</style><nav><ul><li id=m>menu<ul><li>a</li><li>b</li></ul></li></ul>
	<ol><li id=n>numbered<ol><li id=n1>x</li><li id=n2>y</li></ol></li></ol></nav>`)
	defer close(&g)
	_, ok = restyle_state(g.eng, g.doc, g.st, State{hover = dom.find_by_id(g.doc, "m")})
	testing.expect(t, ok, "a bulleted drop-down menu opens with a partial restyle")
	_, ok = restyle_state(g.eng, g.doc, g.st, State{hover = dom.find_by_id(g.doc, "n")})
	testing.expect(t, !ok, "a numbered one needs its numbers: full pass")
	restyled := compute_styles(g.eng, g.doc, State{hover = dom.find_by_id(g.doc, "n")})
	defer styled_destroy(restyled)
	testing.expect_value(t, style_of(restyled, dom.find_by_id(g.doc, "n2")).marker_text, "2. ")
}

@(test)
gradients_and_backgrounds :: proc(t: ^testing.T) {
	f := open(`<style>
		#a { background: linear-gradient(to right, red, blue 30%, green) no-repeat, url(x.png) repeat-x 10px 20px / 5px auto content-box, yellow }
		#b { background-image: radial-gradient(circle 20px at 10% 20%, red, blue) }
		#c { background-image: repeating-linear-gradient(45deg, red 0 10px, blue 10px 20px) }
		#d { background-image: conic-gradient(from 90deg, red, 50%, blue) }
		#e { background-image: linear-gradient(to top right, red, blue) }
		#bad { background-image: linear-gradient(red) }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div><div id=e></div><div id=bad></div>`)
	defer close(&f)
	a := node(&f, "a")
	layers := background_layers(a)
	testing.expect(t, len(layers) == 3 && layers[2].image.kind == .None, "a color alone is the last layer")
	g := layers[0].image.grad
	testing.expect(t, g != nil && g.kind == .Linear && math.abs(g.angle - math.PI / 2) < 1e-4 && len(g.stops) == 3)
	testing.expect(t, layers[0].repeat == {.No_Repeat, .No_Repeat} && layers[1].repeat == {.Repeat, .No_Repeat})
	testing.expect(t, layers[1].image.kind == .Url && layers[1].position[0].v == 10 && layers[1].size.w.v == 5)
	testing.expect(t, layers[1].origin == .Content_Box && layers[1].clip == .Content_Box)
	testing.expect(t, a.background_color.r == 1 && a.background_color.g == 1, "the color of the last layer")
	stops := gradient_stops(g, 200)
	testing.expect(t, stops[0].pos == 0 && stops[1].pos == 60 && stops[2].pos == 200, "fixed-up positions")
	b := node(&f, "b").background_image.grad
	testing.expect(t, b.kind == .Radial && b.shape == .Circle && b.extent == .Explicit && b.radius[0].v == 20 && b.position[0].v == 10)
	c := node(&f, "c").background_image.grad
	testing.expect(t, c.repeating && len(c.stops) == 4)
	d := node(&f, "d").background_image.grad
	testing.expect(t, d.kind == .Conic && len(d.stops) == 3 && d.stops[1].hint)
	e := node(&f, "e").background_image.grad
	testing.expect(t, e.to_corner && math.abs(gradient_angle(e, 100, 100) - math.PI / 4) < 1e-4)
	testing.expect(t, node(&f, "bad").background_image.grad != nil, "one stop is a solid color")
}

@(test)
font_faces :: proc(t: ^testing.T) {
	f := open(`<style>
		@font-face { font-family: "My Font"; src: local("My Font Regular"), url(a.woff2) format("woff2"), url("a.woff") format("woff"), url(a.ttf);
		             font-weight: 300 700; font-style: italic; unicode-range: U+0000-00FF, U+0E00-0E7F, U+4??; font-display: swap }
		@font-face { font-family: Other Name; src: url(o.otf) format(opentype) }
		@font-face { src: url(nofamily.ttf) }
	</style>`)
	defer close(&f)
	faces := engine_font_faces(f.eng)
	testing.expect_value(t, len(faces), 2)
	ff := faces[0]
	testing.expect(t, ff.family == "My Font" && ff.weight == {300, 700} && ff.style == .Italic && ff.display == .Swap)
	testing.expect_value(t, len(ff.sources), 4)
	testing.expect(t, ff.sources[0].kind == .Local && ff.sources[1].format == .Woff2 && ff.sources[1].supported && ff.sources[2].supported)
	testing.expect(t, len(ff.unicode_range) == 3 && ff.unicode_range[1] == {0xE00, 0xE7F} && ff.unicode_range[2] == {0x400, 0x4FF})
	testing.expect(t, face_covers(&faces[0], 'é') && !face_covers(&faces[0], 'Ա') && face_covers(&faces[0], 'Ѐ'))
	testing.expect(t, faces[1].family == "Other Name" && faces[1].sources[0].format == .Opentype)
}

@(test)
more_properties :: proc(t: ^testing.T) {
	f := open(`<style>
		#g { display: grid; grid-template: [top] "a a b" 40px [mid] "c . b" 1fr / 100px repeat(2, minmax(10px, 1fr)); gap: 4px }
		#ga { grid-area: b } #gr { grid-column: 2 / span 3; grid-row: auto }
		#fi { filter: blur(3px) brightness(150%) drop-shadow(1px 2px 3px red); backdrop-filter: none }
		#cp { clip-path: inset(10px 20px round 5px) padding-box }
		#ws { white-space: pre-wrap } #nw { white-space: nowrap } #tw { text-wrap: balance }
		#tx { text-decoration: underline dotted 2px red; text-underline-offset: 25%; font: italic small-caps bold condensed 20px/2 serif }
		#mi { will-change: transform, opacity; contain: strict; content-visibility: hidden; caret-color: red; accent-color: auto;
		      appearance: button; resize: both; columns: 3 200px; overscroll-behavior: contain none; isolation: isolate;
		      mix-blend-mode: multiply; object-position: right 10px bottom; scroll-behavior: smooth; hyphens: auto }
		@supports (transition: opacity 1s) and (grid-template-areas: "a") { #sup { color: red } }
		@supports (transform: frobnicate(1)) { #sup2 { color: red } }
	</style>
	<div id=g><i id=ga></i><i id=gr></i></div><div id=fi></div><div id=cp></div><p id=ws></p><p id=nw></p><p id=tw></p>
	<p id=tx></p><p id=mi></p><p id=sup></p><p id=sup2></p>`)
	defer close(&f)
	g := node(&f, "g")
	testing.expect(t, g.grid_template_rows.kind == .Tracks && len(g.grid_template_rows.tracks) == 2)
	testing.expect(t, g.grid_template_rows.tracks[0].names_before[0] == "top" && g.grid_template_rows.tracks[1].max.kind == .Fr)
	testing.expect(t, len(g.grid_template_columns.tracks) == 2 && g.grid_template_columns.tracks[1].kind == .Repeat && g.grid_template_columns.tracks[1].count == 2)
	testing.expect(t, g.grid_template_areas.rows == 2 && g.grid_template_areas.cols == 3 && len(g.grid_template_areas.areas) == 3)
	testing.expect(t, node(&f, "ga").grid_row_start.kind == .Name && node(&f, "ga").grid_column_end.name == "b")
	gr := node(&f, "gr")
	testing.expect(t, gr.grid_column_start.kind == .Line && gr.grid_column_start.n == 2 && gr.grid_column_end.kind == .Span && gr.grid_column_end.n == 3)
	fi := node(&f, "fi")
	testing.expect(t, len(fi.filter) == 3 && fi.filter[0].v == 3 && fi.filter[1].v == 1.5 && fi.filter[2].shadow.blur == 3)
	cp := node(&f, "cp").clip_path
	testing.expect(t, cp != nil && node(&f, "fi").clip_path == nil)
	testing.expect(t, cp.kind == .Inset && cp.inset[.Right].v == 20 && cp.round[.Top_Left].h.v == 5 && cp.box == .Padding_Box)
	testing.expect(t, node(&f, "ws").white_space == .Pre_Wrap && node(&f, "nw").white_space == .Nowrap && node(&f, "tw").text_wrap_style == .Balance)
	tx := node(&f, "tx")
	testing.expect(t, tx.text_decoration_style == .Dotted && tx.text_decoration_thickness.v == 2 && .Underline in tx.text_decoration)
	testing.expect(t, tx.font_variant_caps == .Small_Caps && tx.font_stretch == 75 && tx.font_weight == 700 && tx.font_size == 20)
	testing.expect(t, math.abs(tx.text_underline_offset.v - 5) < 1e-3, "a percentage of 1em")
	mi := node(&f, "mi")
	testing.expect(t, len(mi.will_change) == 2 && mi.contain == {.Size, .Layout, .Style, .Paint} && mi.content_visibility == .Hidden)
	testing.expect(t, !mi.caret_color.auto && mi.accent_color.auto && mi.appearance == .Auto && mi.resize == .Both)
	testing.expect(t, mi.column_count == 3 && mi.column_width.v == 200 && mi.overscroll_x == .Contain && mi.overscroll_y == .None)
	testing.expect(t, mi.isolation == .Isolate && mi.mix_blend_mode == .Multiply && mi.scroll_behavior == .Smooth && mi.hyphens == .Auto)
	testing.expect(t, mi.object_position[0].kind == .Calc && mi.object_position[1].v == 100)
	testing.expect(t, node(&f, "sup").color == css.Color{1, 0, 0, 1} && node(&f, "sup2").color != css.Color{1, 0, 0, 1}, "@supports knows the new properties")
}

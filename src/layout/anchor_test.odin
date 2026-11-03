package layout

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:style"

// CSS Anchor Positioning: where boxes end up (every character 0.5 em wide), and, after each change, that an incremental pass
// made what a full pass makes (layout.incremental.verify).

@(private = "file")
ax_load :: proc(src: string, vw: f32 = FIXTURE_VP_W, vh: f32 = FIXTURE_VP_H) -> ^Fixture {
	f := fixture_load(src, vw, vh, {band_h = FIXTURE_NARROW_BAND_H, journal = true, inc_verify = true})
	anchored_commit(&f.l)
	return f
}

// After a change of the document: styles again, then a pass.
@(private = "file")
ax_frame :: proc(t: ^testing.T, f: ^Fixture, loc := #caller_location) {
	if f.st.mutations != f.doc.mutations {
		old := f.st
		f.st = style.compute_styles(f.eng, f.doc, {})
		style.journal_diff(old, f.st)
		style.styled_destroy(old)
	}
	fixture_run(f)
	testing.expectf(t, f.l.inc.verify_failures == 0, "incremental differs from full: %s", f.l.inc.verify_report, loc = loc)
	anchored_commit(&f.l)
}

// Where the box of an element is drawn (no scrolling of the page).
@(private = "file")
rect :: proc(f: ^Fixture, id: string) -> Rect {
	h := dom.find_by_id(f.doc, id)
	r, ok := box_of(&f.l, h, f.vp, 0)
	return ok ? r.border : Rect{{-1, -1}, {-1, -1}}
}

@(private = "file")
is :: proc(t: ^testing.T, f: ^Fixture, id: string, x, y, w, h: f32, loc := #caller_location) {
	r := rect(f, id)
	got := [4]f32{r.min.x, r.min.y, r.max.x - r.min.x, r.max.y - r.min.y}
	testing.expectf(t, got == [4]f32{x, y, w, h}, "#%s at %v, want %v", id, got, [4]f32{x, y, w, h}, loc = loc)
}

@(private = "file")
BASE :: `<!doctype html><style>
	body { margin: 0 }
	#cb { position: relative; width: 400px; height: 300px }
	#a { anchor-name: --a; position: absolute; left: 100px; top: 50px; width: 40px; height: 20px }
	.t { position: absolute; position-anchor: --a; width: 10px; height: 10px }
</style>`

@(test)
anchor_function_sides :: proc(t: ^testing.T) {
	f := ax_load(strings_of(BASE, `<div id=cb><div id=a></div>
		<div class=t id=l style="left: anchor(right); top: anchor(top)"></div>
		<div class=t id=r style="right: anchor(left); bottom: anchor(bottom)"></div>
		<div class=t id=c style="left: anchor(center); top: anchor(center)"></div>
		<div class=t id=p style="left: anchor(25%); top: anchor(50%)"></div>
		<div class=t id=i style="left: anchor(inside); top: anchor(outside)"></div>
		<div class=t id=s style="left: anchor(start); top: anchor(end)"></div>
		<div class=t id=m style="left: calc(anchor(left) + 5px); top: min(anchor(top), 10px)"></div>
		<div class=t id=n style="left: anchor(--a right); top: anchor(--a bottom)"></div>
	</div>`))
	defer fixture_unload(f)
	is(t, f, "l", 140, 50, 10, 10)
	is(t, f, "r", 90, 60, 10, 10)
	is(t, f, "c", 120, 60, 10, 10)
	is(t, f, "p", 110, 60, 10, 10)
	is(t, f, "i", 100, 70, 10, 10)
	is(t, f, "s", 100, 70, 10, 10)
	is(t, f, "m", 105, 10, 10, 10)
	is(t, f, "n", 140, 70, 10, 10)
}

@(test)
anchor_function_fallback :: proc(t: ^testing.T) {
	f := ax_load(strings_of(BASE, `<div id=cb><div id=a></div>
		<div class=t id=none style="left: anchor(--missing right, 7px); top: anchor(--missing top, 10%)"></div>
		<div class=t id=wrong style="left: anchor(top, 3px)"></div>
		<div class=t id=nested style="left: anchor(--missing left, anchor(right))"></div>
		<div class=t id=auto style="left: anchor(--missing left); top: 4px"></div>
	</div>`))
	defer fixture_unload(f)
	is(t, f, "none", 7, 30, 10, 10)
	testing.expect_value(t, rect(f, "wrong").min.x, 3)
	testing.expect_value(t, rect(f, "nested").min.x, 140)
	testing.expect_value(t, rect(f, "auto").min.y, 4)
}

@(test)
anchor_size_in_sizes :: proc(t: ^testing.T) {
	f := ax_load(strings_of(BASE, `<div id=cb><div id=a></div>
		<div class=t id=s style="width: anchor-size(width); height: anchor-size(height)"></div>
		<div class=t id=x style="width: anchor-size(--a height); height: calc(anchor-size(width) * 2)"></div>
		<div class=t id=m style="min-width: anchor-size(width); max-height: anchor-size(height)"></div>
		<div class=t id=f style="width: anchor-size(--missing width, 33px)"></div>
		<div id=flow style="width: anchor-size(width, 44px); height: anchor-size(height)"></div>
	</div>`))
	defer fixture_unload(f)
	r := rect(f, "s")
	testing.expect_value(t, r.max - r.min, Vec2{40, 20})
	r = rect(f, "x")
	testing.expect_value(t, r.max - r.min, Vec2{20, 80})
	r = rect(f, "m")
	testing.expect_value(t, r.max - r.min, Vec2{40, 10})
	r = rect(f, "f")
	testing.expect_value(t, r.max.x - r.min.x, 33)
	r = rect(f, "flow")
	testing.expect_value(t, r.max.x - r.min.x, 44)   // not absolutely positioned: the fallback
	testing.expect_value(t, r.max.y - r.min.y, 0)    // and with none, as if auto
}

// Which anchor: the last acceptable one in tree order, in-flow ones after the box too, not an absolutely positioned one that
// comes after it, not its containing block; anchor-scope.
@(test)
anchor_acceptability :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		.cb { position: relative; width: 300px; height: 100px }
		.x { anchor-name: --x; width: 10px; height: 10px; margin-left: 30px }
		.y { anchor-name: --y; position: absolute; left: 77px; width: 5px; height: 5px }
		.t { position: absolute; left: anchor(--x left, 1px); top: 0; width: 1px; height: 1px }
		.u { position: absolute; left: anchor(--y left, 2px); top: 0; width: 1px; height: 1px }
		.c { position: absolute; left: anchor(--c left, 3px); top: 0; width: 1px; height: 1px }
		.scope { anchor-scope: --x }
	</style>
	<div class=cb><div class=t id=t1></div><div class=x style="margin-left: 10px"></div><div class=x style="margin-left: 20px"></div></div>
	<div class=cb><div class=u id=u1 style="left: anchor(--y1 left, 2px)"></div><div class=y style="anchor-name: --y1"></div></div>
	<div class=cb><div class=y></div><div class=u id=u2></div></div>
	<div class=cb style="anchor-name: --c"><div class=c id=c1></div></div>
	<div class=cb style="width: 300px"><div class=scope><div class=x style="margin-left: 50px"></div></div><div class=t id=t2></div></div>
	<div class=cb><div class=scope><div class=x style="margin-left: 60px"></div><div class=t id=t3></div></div></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, rect(f, "t1").min.x, 20)
	testing.expect_value(t, rect(f, "u1").min.x, 2)    // comes after it, and absolutely positioned
	testing.expect_value(t, rect(f, "u2").min.x, 77)
	testing.expect_value(t, rect(f, "c1").min.x, 3)    // its own containing block
	testing.expect_value(t, rect(f, "t3").min.x, 60)   // inside the scope
	// out of the scope: an anchor of an earlier row, outside of its containing block, comes first
	testing.expect_value(t, rect(f, "t2").min.x, 20)
}

@(test)
anchor_outside_containing_block :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		.cb { position: relative; margin-left: 20px; width: 100px; height: 50px }
		#a { anchor-name: --a; margin-left: 70px; width: 30px; height: 10px }
		#q { position: absolute; left: anchor(--a right); top: anchor(--a bottom); width: 5px; height: 5px }
	</style><div id=a></div><div class=cb><div id=q></div></div><div id=later style="anchor-name: --b"></div>
	<div class=cb style="top: 7px"><div id=none style="position: absolute; left: anchor(--b right, 9px); top: 0"></div></div>`)
	defer fixture_unload(f)
	// anchor at (70, 0) to (100, 10) in the page, the containing block starts at x = 20
	r := rect(f, "q")
	testing.expect_value(t, r.min, Vec2{100, 10})
}

@(test)
position_area_grid :: proc(t: ^testing.T) {
	f := ax_load(strings_of(BASE, `<div id=cb><div id=a></div>
		<div class=t id=tl style="position-area: top left"></div>
		<div class=t id=br style="position-area: bottom right"></div>
		<div class=t id=c style="position-area: center"></div>
		<div class=t id=st style="position-area: span-top right"></div>
		<div class=t id=sa style="position-area: top; width: auto; height: auto"></div>
		<div class=t id=fill style="position-area: bottom; width: auto; justify-self: stretch"></div>
		<div class=t id=ins style="position-area: bottom right; left: 3px; top: 4px"></div>
		<div class=t id=none style="position-area: top left; position-anchor: --missing; left: 1px; top: 1px"></div>
	</div>`))
	defer fixture_unload(f)
	is(t, f, "tl", 90, 40, 10, 10)
	is(t, f, "br", 140, 70, 10, 10)
	is(t, f, "c", 115, 55, 10, 10)
	is(t, f, "st", 140, 60, 10, 10)
	is(t, f, "ins", 143, 74, 10, 10)
	is(t, f, "fill", 0, 70, 400, 10)
	is(t, f, "none", 1, 1, 10, 10)
}

@(test)
anchor_center_centers :: proc(t: ^testing.T) {
	f := ax_load(strings_of(BASE, `<div id=cb><div id=a></div>
		<div class=t id=j style="justify-self: anchor-center; top: 0"></div>
		<div class=t id=b style="align-self: anchor-center; left: 0"></div>
		<div class=t id=no style="position-anchor: --missing; justify-self: anchor-center; left: 0; right: 0; top: 0"></div>
	</div>`))
	defer fixture_unload(f)
	is(t, f, "j", 115, 0, 10, 10)
	is(t, f, "b", 0, 55, 10, 10)
	is(t, f, "no", 195, 0, 10, 10)   // no anchor: as center
}

@(test)
fallbacks_flip_and_rules :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 200px; height: 200px }
		#a { anchor-name: --a; position: absolute; left: 0; top: 0; width: 50px; height: 50px }
		#b { anchor-name: --b; position: absolute; right: 0; bottom: 0; width: 50px; height: 50px }
		.t { position: absolute; width: 60px; height: 60px }
		@position-try --side { top: anchor(top); bottom: auto; left: anchor(right); right: auto }
		@position-try --never { width: 1000px }
	</style><div id=cb><div id=a></div><div id=b></div>
		<div class=t id=flipb style="position-anchor: --a; bottom: anchor(top); left: 0; position-try-fallbacks: flip-block"></div>
		<div class=t id=flipi style="position-anchor: --a; right: anchor(left); top: 0; position-try-fallbacks: flip-inline"></div>
		<div class=t id=rule style="position-anchor: --a; bottom: anchor(top); left: 0; position-try-fallbacks: --never, --side"></div>
		<div class=t id=area style="position-anchor: --a; position-area: top; position-try-fallbacks: bottom"></div>
		<div class=t id=stays style="position-anchor: --a; top: anchor(bottom); left: 0; position-try-fallbacks: flip-block"></div>
		<div class=t id=none style="position-anchor: --a; bottom: anchor(top); left: 0; position-try-fallbacks: --never"></div>
		<div class=t id=miss style="position-anchor: --a; bottom: anchor(top); left: 0; position-try-fallbacks: --absent, flip-block"></div>
		<div class=t id=order style="position-anchor: --b; bottom: anchor(bottom); right: anchor(right); position-try-fallbacks: flip-block; position-try-order: most-height"></div>
	</div>
	<div style="position: relative; width: 300px; height: 200px">
		<div style="anchor-name: --c; position: absolute; left: 0; top: 0; width: 50px; height: 50px"></div>
		<div id=start style="position: absolute; position-anchor: --c; top: anchor(bottom); left: 0; width: 60px; height: 160px; position-try-fallbacks: flip-start"></div>
	</div>`)
	defer fixture_unload(f)
	is(t, f, "flipb", 0, 50, 60, 60)
	is(t, f, "flipi", 50, 0, 60, 60)
	is(t, f, "rule", 50, 0, 60, 60)
	is(t, f, "start", 50, 200, 160, 60)
	is(t, f, "area", 0, 50, 60, 60)
	is(t, f, "stays", 0, 50, 60, 60)
	testing.expect_value(t, rect(f, "none").max.y, 0)   // no option fits: its own style
	is(t, f, "miss", 0, 50, 60, 60)
	// bottom: anchor(bottom) leaves 200 px above, flipped (top: anchor(top)) 50: its own style has the most height
	is(t, f, "order", 140, 140, 60, 60)
}

// What fits stays while it fits, even when an earlier option would fit again.
@(test)
last_successful_option_stays :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 200px; height: 300px }
		#a { anchor-name: --a; position: absolute; left: 0; top: 100px; width: 50px; height: 50px }
		#t { position: absolute; position-anchor: --a; bottom: anchor(top); left: 0; width: 10px; height: 60px; position-try-fallbacks: flip-block }
	</style><div id=cb><div id=a></div><div id=t></div></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, rect(f, "t").min.y, 40)
	a := dom.find_by_id(f.doc, "a")
	dom.set_attribute(f.doc, a, "style", "top: 20px")
	ax_frame(t, f)
	testing.expect_value(t, rect(f, "t").min.y, 70)   // no room above: flipped
	dom.set_attribute(f.doc, a, "style", "top: 100px")
	ax_frame(t, f)
	testing.expect_value(t, rect(f, "t").min.y, 150)  // above fits again, below still does: it stays
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "t"), "style", "height: 59px")
	ax_frame(t, f)
	testing.expect_value(t, rect(f, "t").min.y, 41)   // its style changed: starts again
}

// The anchor moved, its name changed, the box is new: an incremental pass follows, and agrees with a full one.
@(test)
anchors_follow_changes_incrementally :: proc(t: ^testing.T) {
	f := ax_load(strings_of(BASE, `<div id=cb><div id=a></div><div id=other style="anchor-name: --o; position: absolute; left: 200px; top: 200px; width: 10px; height: 10px"></div>
		<div class=t id=q style="left: anchor(right); top: anchor(bottom)"><div style="height: 100%" id=inner>x</div></div>
		<div class=t id=sized style="width: anchor-size(width)">text</div>
	</div>`))
	defer fixture_unload(f)
	is(t, f, "q", 140, 70, 10, 10)
	a := dom.find_by_id(f.doc, "a")
	dom.set_attribute(f.doc, a, "style", "left: 10px; width: 70px")
	ax_frame(t, f)
	is(t, f, "q", 80, 70, 10, 10)
	r := rect(f, "sized")
	testing.expect_value(t, r.max.x - r.min.x, 70)
	testing.expect_value(t, f.l.last_pass, Pass_Kind.Incremental)
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "q"), "style", "position-anchor: --o; left: anchor(left); top: anchor(top)")
	ax_frame(t, f)
	is(t, f, "q", 200, 200, 10, 10)
	dom.set_attribute(f.doc, a, "style", "anchor-name: --o; left: 300px; top: 10px")
	ax_frame(t, f)
	is(t, f, "q", 200, 200, 10, 10)   // #other comes after #a: it is the last one
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "other"), "style", "display: none")
	ax_frame(t, f)
	is(t, f, "q", 300, 10, 10, 10)    // gone: the other one
	dom.set_attribute(f.doc, a, "style", "display: none")
	ax_frame(t, f)
	testing.expect_value(t, f.l.inc.verify_failures, 0)
	// the viewport: a fixed box anchored on the page's right edge
	f.vp.x = 600
	ax_frame(t, f)
}

@(test)
fixed_anchored_box :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#a { anchor-name: --a; margin-top: 100px; margin-left: 50px; width: 30px; height: 30px }
		#q { position: fixed; position-anchor: --a; left: anchor(right); top: anchor(top); width: 5px; height: 5px }
		#spacer { height: 3000px }
	</style><div id=a></div><div id=spacer></div><div id=q></div>`)
	defer fixture_unload(f)
	h := dom.find_by_id(f.doc, "q")
	r, ok := box_of(&f.l, h, f.vp, 0)
	testing.expect(t, ok)
	testing.expect_value(t, r.border.min, Vec2{80, 100})
	// the page scrolled by 60: a fixed box is drawn in the viewport, its anchor went up
	v := view_make(&f.l, f.vp, 60, cull = false)
	bi := box_index(&f.l, h)
	testing.expect_value(t, v.offsets[f.l.boxes[bi].space].y, -60)
}

// A fixed box under position-area stays in the viewport as it is when the page is scrolled: the anchor is far down the
// document, near the top of the viewport.
@(test)
fixed_area_on_scrolled_page :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#a { anchor-name: --a; margin-top: 1000px; width: 30px; height: 30px }
		#q { position: fixed; position-anchor: --a; position-area: bottom; position-visibility: always; width: 10px; height: 40px }
		#tail { height: 2000px }
	</style><div id=a></div><div id=tail></div><div id=q></div>`, 800, 300)
	defer fixture_unload(f)
	layout_doc_scroll :: 900
	note_doc_scroll(&f.l, layout_doc_scroll)
	ax_frame(t, f)
	v := view_make(&f.l, f.vp, layout_doc_scroll, cull = false)
	q := box_index(&f.l, dom.find_by_id(f.doc, "q"))
	b := &f.l.boxes[q]
	// the anchor shows at 100 .. 130 of the viewport: the box right under it, in the page's coordinates plus its shift
	testing.expect_value(t, b.abs.y + v.offsets[b.space].y, 130)
}

@(test)
box_follows_scrolling_anchor :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 400px; height: 400px }
		#s { width: 200px; height: 200px; overflow: scroll }
		#a { anchor-name: --a; margin-top: 100px; width: 30px; height: 30px }
		#end { height: 1000px }
		#q { position: absolute; position-anchor: --a; position-visibility: always; left: anchor(right); top: anchor(top); width: 5px; height: 5px }
		#o { position: absolute; left: anchor(--a right); top: 0; width: 5px; height: 5px }
		#x { position: absolute; position-anchor: --a; position-visibility: always; left: anchor(right); top: 0; width: 5px; height: 5px }
	</style><div id=cb><div id=s><div id=a></div><div id=end></div></div><div id=q></div><div id=o></div><div id=x></div></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, rect(f, "q").min, Vec2{30, 100})
	s := dom.find_by_id(f.doc, "s")
	passes := f.l.passes
	set_scroll(&f.l, s, {0, 70})
	testing.expect_value(t, rect(f, "q").min, Vec2{30, 30})   // no pass: its space moved
	testing.expect_value(t, rect(f, "a").min, Vec2{0, 30})
	testing.expect_value(t, rect(f, "o").min, Vec2{30, 0})    // no default anchor: it stays
	testing.expect_value(t, rect(f, "x").min, Vec2{30, 0})    // refers to the anchor in x only: it stays in y
	testing.expect(t, passes == f.l.passes)
	testing.expect(t, !f.l.anchor_stale)
}

// A scrolled anchor: the option that overflows the containing block once scrolled gives way, on the next pass.
@(test)
scrolling_switches_fallback :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 400px; height: 400px }
		#s { width: 400px; height: 400px; overflow: scroll }
		#a { anchor-name: --a; margin-top: 300px; width: 30px; height: 30px }
		#end { height: 700px }
		#q { position: absolute; position-anchor: --a; position-visibility: always; bottom: anchor(top); left: 0; width: 5px; height: 100px; position-try-fallbacks: flip-block }
	</style><div id=cb><div id=s><div id=a></div><div id=end></div></div><div id=q></div></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, rect(f, "q").min.y, 200)
	testing.expect(t, f.l.anchor_scroll)
	s := dom.find_by_id(f.doc, "s")
	set_scroll(&f.l, s, {0, 200})
	testing.expect(t, !f.l.anchor_stale || rect(f, "q").min.y == 0)
	testing.expect_value(t, rect(f, "q").min.y, 0)
	set_scroll(&f.l, s, {0, 201})
	testing.expect(t, f.l.anchor_stale)
	ax_frame(t, f)
	testing.expect(t, !f.l.anchor_stale)
	testing.expect_value(t, rect(f, "q").min.y, 129)   // below the anchor, which is at 99 .. 129
}

@(test)
visibility_hides_painting :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 300px; height: 300px }
		#s { width: 100px; height: 100px; overflow: hidden scroll }
		#a { anchor-name: --a; width: 50px; height: 50px }
		#end { height: 500px }
		.q { position: absolute; position-anchor: --a; left: 150px; top: 0; width: 5px; height: 5px }
		#v { position-visibility: anchor-visible }
		#al { position-visibility: always; top: 10px }
		#no { position-visibility: no-overflow; top: 299px; height: 50px }
		#inv { position-visibility: anchor-valid; position-anchor: normal; left: anchor(--missing left) }
		#keep { position-visibility: anchor-valid; position-anchor: normal; left: anchor(--missing left, 1px) }
	</style><div id=cb><div id=s><div id=a></div><div id=end></div></div>
		<div class=q id=v>v</div><div class=q id=al>a</div><div class=q id=no>n</div><div class=q id=inv>i</div><div class=q id=keep>k</div></div>`)
	defer fixture_unload(f)
	painted :: proc(f: ^Fixture, id: string) -> bool {
		h := dom.find_by_id(f.doc, id)
		for &it in f.l.items { if it.node == h { return true } }
		return false
	}
	testing.expect(t, painted(f, "v"))
	testing.expect(t, painted(f, "al"))
	testing.expect(t, !painted(f, "no"))
	testing.expect(t, !painted(f, "inv"))
	testing.expect(t, painted(f, "keep"))
	set_scroll(&f.l, dom.find_by_id(f.doc, "s"), {0, 60})
	ax_frame(t, f)
	testing.expect(t, !painted(f, "v"))   // scrolled out of its scroll container
	testing.expect(t, painted(f, "al"))
	hit := hit_test(&f.l, {150, 2}, f.vp, 0)
	testing.expect(t, hit.node != dom.find_by_id(f.doc, "v"))
	set_scroll(&f.l, dom.find_by_id(f.doc, "s"), {0, 10})
	ax_frame(t, f)
	testing.expect(t, painted(f, "v"))
}

@(test)
pseudo_and_attribute_anchors :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 300px; height: 300px }
		#a { margin-left: 60px; width: 20px; height: 20px }
		#a::after { content: ""; position: absolute; position-anchor: auto; left: anchor(right); top: anchor(top); width: 3px; height: 3px }
		#m { margin-left: 100px; width: 20px; height: 20px }
		#q { position: absolute; position-anchor: auto; left: anchor(right, 1px); top: 0; width: 3px; height: 3px }
	</style><div id=cb><div id=a></div><div id=m></div><div id=q anchor=m></div></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, rect(f, "q").min.x, 120)
	found := false
	for &e in f.l.anchored {
		b := &f.l.boxes[e.box]
		if .Pseudo in b.flags {
			found = true
			testing.expect_value(t, b.abs, Vec2{80, 0})
		}
	}
	testing.expect(t, found)
}

@(test)
grid_area_contains_anchored_box :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#g { display: grid; position: relative; grid-template-columns: 100px 100px; grid-template-rows: 50px 50px; width: 200px; height: 100px }
		#a { anchor-name: --a; grid-column: 1; grid-row: 1 }
		#q { position: absolute; grid-column: 2; grid-row: 2; position-anchor: --a; left: 0; top: anchor(--a bottom, 5px); width: 3px; height: 3px }
		#r { position: absolute; grid-column: 2; grid-row: 2; position-anchor: --a; position-area: bottom right; width: 3px; height: 3px }
	</style><div id=g><div id=a></div><div id=q></div><div id=r></div></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, rect(f, "q").min, Vec2{100, 50})
	testing.expect_value(t, rect(f, "r").min, Vec2{100, 50})
}

@(private = "file")
strings_of :: proc(a, b: string) -> string {
	buf := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

_ :: base.NIL_HANDLE

// A flow-relative declaration of @position-try means what it means for the element, as anywhere else.
@(test)
try_rule_flow_relative :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		#cb { position: relative; width: 400px; height: 300px }
		#a { anchor-name: --a; position: absolute; left: 100px; top: 50px; width: 40px; height: 20px }
		.q { position: absolute; position-anchor: --a; width: 10px; height: 10px; left: 1000px; position-try-fallbacks: --pf }
		@position-try --pf { inset: auto; inset-block-start: 10px; inset-inline-start: 20px }
	</style><div id=cb><div id=a></div>
		<div class=q id=h></div>
		<div class=q id=vrl style="writing-mode: vertical-rl"></div>
		<div class=q id=vlr style="writing-mode: vertical-lr"></div>
		<div class=q id=vrr style="writing-mode: vertical-rl; direction: rtl"></div>
		<div class=q id=rtl style="direction: rtl"></div>
	</div>`)
	defer fixture_unload(f)
	is(t, f, "h", 20, 10, 10, 10)
	is(t, f, "vrl", 380, 20, 10, 10)
	is(t, f, "vlr", 10, 20, 10, 10)
	is(t, f, "vrr", 380, 270, 10, 10)
	is(t, f, "rtl", 370, 10, 10, 10)
}

// The end margins of what is in a scroll container are scrollable where its axes end: left of vertical-rl and of right-to-left
// lines, at the top of upward lines.
@(test)
end_margins_where_axes_end :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		.s { overflow: scroll; width: 200px; height: 100px; scrollbar-width: none }
		.c { width: 50px; height: 50px }
	</style>
		<div class=s id=vrl style="writing-mode: vertical-rl"><div class=c style="margin-left: 500px"></div></div>
		<div class=s id=vlr style="writing-mode: vertical-lr"><div class=c style="margin-right: 500px"></div></div>
		<div class=s id=vup style="writing-mode: vertical-lr; direction: rtl"><div class=c style="margin-top: 500px"></div></div>
		<div class=s id=rtl style="direction: rtl"><div class=c style="margin-left: 500px"></div></div>
		<div class=s id=ltr><div class=c style="margin-right: 500px; margin-bottom: 500px"></div></div>`)
	defer fixture_unload(f)
	range :: proc(f: ^Fixture, id: string) -> (lo, hi: Vec2) {
		h := dom.find_by_id(f.doc, id)
		hi, _ = scroll_max(&f.l, h)
		return scroll_min(&f.l, h), hi
	}
	lo, hi := range(f, "vrl")
	testing.expect_value(t, lo, Vec2{-350, 0})
	testing.expect_value(t, hi, Vec2{0, 0})
	lo, hi = range(f, "vlr")
	testing.expect_value(t, lo, Vec2{0, 0})
	testing.expect_value(t, hi, Vec2{350, 0})
	lo, hi = range(f, "vup")
	testing.expect_value(t, lo, Vec2{0, -450})
	lo, hi = range(f, "rtl")
	testing.expect_value(t, lo, Vec2{-350, 0})
	lo, hi = range(f, "ltr")
	testing.expect_value(t, hi, Vec2{350, 450})
}

// The page scrolls upwards when its lines do; the viewport has the principal direction, for anchor(start) and anchor(end) too.
@(test)
doc_scroll_origin_at_the_bottom :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		html { writing-mode: vertical-rl; direction: rtl }
		body { margin: 0; width: 1000px; height: 1000px }
		#a { anchor-name: --a; width: 100px; height: 100px }
		#q { position: fixed; position-anchor: --a; width: 10px; height: 10px; top: anchor(start); left: 0 }
	</style><div id=a></div><div id=q></div>`)
	defer fixture_unload(f)
	lo, hi := doc_scroll_y_range(&f.l, f.vp.y)
	testing.expect_value(t, lo, f32(-400))
	testing.expect_value(t, hi, f32(0))
	is(t, f, "a", 700, 500, 100, 100)
	testing.expect_value(t, rect(f, "q").min.y, 600)   // the start of the anchor, the low side being its end
	_, thumb, shown := doc_scrollbar(&f.l, f.vp, 0)
	testing.expect(t, shown)
	_, top, _ := doc_scrollbar(&f.l, f.vp, -400)
	testing.expect(t, top.min.y < thumb.min.y, "at the top of the range the thumb is at the top of the track")

	g := ax_load(`<!doctype html><style>
		html { writing-mode: vertical-lr }
		body { margin: 0; width: 1000px; height: 1000px }
	</style><div></div>`)
	defer fixture_unload(g)
	lo, hi = doc_scroll_y_range(&g.l, g.vp.y)
	testing.expect_value(t, lo, f32(0))
	testing.expect_value(t, hi, f32(400))
}

// In a spanner: a box positioned there shows with its anchor; what lies between the spanner and its container contains neither.
@(test)
anchored_in_a_spanner :: proc(t: ^testing.T) {
	f := ax_load(`<!doctype html><style>
		body { margin: 0 }
		.relpos { position: relative }
		#mc { column-count: 2; column-gap: 10px; width: 210px; height: 100px }
		#sp { column-span: all }
		#a { anchor-name: --a; margin-left: 10px; width: 40px; height: 20px }
		.t { position: absolute; position-anchor: --a; left: anchor(left); top: anchor(top); width: anchor-size(width); height: anchor-size(height) }
	</style><div id=mc class=relpos>
		<div style="height: 40px"></div>
		<div class=relpos id=between>
			<div id=sp>
				<div class=relpos><div id=a></div><div class=t id=inner></div></div>
				<div class=t id=contained></div>
			</div>
			<div class=t id=none></div>
		</div>
	</div>`)
	defer fixture_unload(f)
	is(t, f, "a", 10, 20, 40, 20)
	is(t, f, "inner", 10, 20, 40, 20)
	is(t, f, "contained", 10, 20, 40, 20)
	testing.expect_value(t, rect(f, "none").max.x - rect(f, "none").min.x, 0)   // the anchor is not for what is contained by #between
	bi := box_index(&f.l, dom.find_by_id(f.doc, "contained"))
	testing.expect_value(t, f.l.boxes[bi].cb, box_index(&f.l, dom.find_by_id(f.doc, "mc")))
}

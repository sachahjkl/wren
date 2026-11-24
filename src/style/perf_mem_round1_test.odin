package style

import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"

@(test)
container_query_settled_gate_and_cached_containers :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		#c1 { container-type: inline-size; width: 400px; }
		#c2 { container-type: size; width: 300px; height: 200px; }
		@container (min-width: 350px) { #child { color: red; } }
	</style><div id=c1><div id=child></div></div><div id=c2></div>`)
	defer fixture_unload(f)

	testing.expect(t, engine_uses_container_queries(f.eng), "engine detects @container rule")
	fake_layout := rawptr(uintptr(0x1234))
	testing.expect(t, !engine_cq_settled(f.eng, fake_layout, 1, f.st.serial, 1), "initially unsettled")

	c1 := engine_containers(f.eng, f.st)
	testing.expect_value(t, len(c1), 2)
	// Second call on same (st, serial) hits cache
	c2 := engine_containers(f.eng, f.st)
	testing.expect_value(t, len(c2), 2)
	testing.expect(t, f.eng.cq_containers_styled == rawptr(f.st) && f.eng.cq_containers_serial == f.st.serial, "containers cached")

	engine_cq_mark_settled(f.eng, fake_layout, 1, f.st.serial, 1)
	testing.expect(t, engine_cq_settled(f.eng, fake_layout, 1, f.st.serial, 1), "settled for matching state")
	testing.expect(t, !engine_cq_settled(f.eng, fake_layout, 2, f.st.serial, 1), "new layout pass invalidates gate")
	testing.expect(t, !engine_cq_settled(f.eng, fake_layout, 1, f.st.serial + 1, 1), "new serial invalidates gate")
	testing.expect(t, !engine_cq_settled(f.eng, fake_layout, 1, f.st.serial, 1.25), "scale change invalidates gate")

	// Updating container sizes invalidates settled state
	sizes := make(map[base.Handle][2]f32, 2, context.temp_allocator)
	for h in c1 { sizes[h] = {400, 200} }
	testing.expect(t, engine_set_container_sizes(f.eng, sizes), "new container sizes trigger update")
	testing.expect(t, !engine_cq_settled(f.eng, fake_layout, 1, f.st.serial, 1), "size change clears settled gate")

	// Releasing spares clears cached containers and settled marker cleanly
	engine_release_spares(f.eng)
	testing.expect(t, f.eng.cq_settled_layout == nil && len(f.eng.cq_containers) == 0, "spares released")
}

@(test)
timeline_steady_state_zero_element_alloc_and_compact_transitions :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		.btn { transition: opacity 200ms linear, transform 200ms linear(0, 0.5 50%, 1); animation-name: nonexistent-kf; opacity: 1; transform: translateX(0px); }
		.btn:hover { opacity: 0; transform: translateX(100px); }
	</style><div id=a class=btn></div><div id=b class=btn></div><div id=c class=btn></div>`, {timeline = true})
	defer fixture_unload(f)

	// Steady state: elements have transition and nonexistent animation-name, but nothing is running -> zero Element_Anim entries
	testing.expect_value(t, len(f.tl.elements), 0)
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	timeline_restyled(f.tl, f.doc, old, f.st, 16)
	styled_destroy(old)
	testing.expect_value(t, len(f.tl.elements), 0)

	// Compact Transition struct check (replaces 3x full Computed + 16 KiB base.Arena)
	testing.expectf(t, size_of(Transition) < 512, "Transition struct must be compact, got %d bytes", size_of(Transition))

	// Trigger hover on #a: starts opacity (scalar, 0 arena blocks) and transform (slice + linear easing) transitions
	ha := dom.find_by_id(f.doc, "a")
	old2 := f.st
	f.st = compute_styles(f.eng, f.doc, State{hover = ha})
	timeline_restyled(f.tl, f.doc, old2, f.st, 100)
	styled_destroy(old2)
	timeline_tick(f.tl, f.doc, f.st, 100)

	testing.expect_value(t, len(f.tl.elements), 1)
	ea := f.tl.elements[ha]
	testing.expect(t, ea != nil && len(ea.transitions) == 2, "two transitions started on hovered element only")
	if ea != nil {
		for tr in ea.transitions {
			if tr.prop == .Opacity {
				testing.expect_value(t, len(tr.arena.blocks), 0)
			}
		}
	}

	// Halfway through: opacity should be ~0.5
	timeline_tick(f.tl, f.doc, f.st, 200)
	cs := style_of(f.st, ha)
	testing.expect(t, math.abs(f64(cs.opacity) - 0.5) < 0.02, "scalar opacity transition interpolates halfway")

	// Reverse hover at 200ms (halfway): shortening factor = 0.5 -> completes in 100ms (at 300ms)
	old3 := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	timeline_restyled(f.tl, f.doc, old3, f.st, 200)
	styled_destroy(old3)
	timeline_tick(f.tl, f.doc, f.st, 250)
	cs2 := style_of(f.st, ha)
	testing.expect(t, math.abs(f64(cs2.opacity) - 0.75) < 0.02, "reversed transition interpolates with shortening")

	// Finish transitions: Element_Anim cleaned up, zero elements left
	timeline_tick(f.tl, f.doc, f.st, 400)
	testing.expect_value(t, len(f.tl.elements), 0)
}

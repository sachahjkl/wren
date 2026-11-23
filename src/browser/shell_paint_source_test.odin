package browser

import "core:testing"
import "wb:dom"
import "wb:page"
import "wb:style"

// A chrome frame paints a busy page from its last layout only while the page's styles are those it was painted with. A
// script's style pass without a layout (getComputedStyle under a running animation) ticks the timeline: each overlay's arena
// is emptied and made again, and the anonymous boxes and pseudo-elements of the layout still point at what it held. Neither
// the document nor the layout's serial moves then: before the page's serial was part of Paint_Source, the frame painted those
// freed records (a crash in the compositor's item_hash, under shell_preempt).
@(test)
a_style_pass_without_a_layout_stops_painting_from_the_layout :: proc(t: ^testing.T) {
	doc := dom.Document{mutations = 3}
	styled := style.Styled{serial = 7}
	p := page.Page{doc = &doc, styled = &styled}
	tab := Tab{page = &p}
	tab.layout.valid, tab.layout.mutations, tab.layout.serial = true, 3, 7
	painted := paint_source(&tab)
	testing.expect(t, paint_source(&tab) == painted, "nothing changed: the layout can be painted again")
	styled.serial = 8   // (what a tick of the timeline does: style.timeline_tick, styled_touch_paint)
	testing.expect(t, paint_source(&tab) != painted, "the page's styles moved without the layout: its records may be gone")
	styled.serial = 7
	other := style.Styled{serial = 9}
	p.styled = &other   // (a full pass the script made: overlays retire against it, which no layout reads yet)
	testing.expect(t, paint_source(&tab) != painted, "the page has another pass of its styles")
}

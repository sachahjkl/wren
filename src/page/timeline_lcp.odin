package page

// Largest Contentful Paint, Element Timing and Layout Instability — the parts of the Performance Timeline that depend on
// what the page draws, computed natively from the layout the shell lays out (no JavaScript, no periodic DOM walk). The
// browser owns the state (timeline.odin); the engine is only told there are new entries.
//
//   * Largest Contentful Paint (largest-contentful-paint, LargestContentfulPaint): after each real paint of the shell
//     (timeline_painted / timeline_present), the largest contentful element inside the viewport is found and, when it is
//     larger than every candidate reported so far, an entry is added. A candidate is an image (<img>, <input type=image>,
//     <video> poster, a CSS background image) or a block of text (an element whose box starts an inline formatting context
//     with text). The reported size is the element's visible area, clamped to the viewport, in CSS px. The algorithm stops
//     at the first user interaction (timeline_layout_shift_input sets lcp_stopped) or when the document is torn down, as
//     the specification says. Excluded: elements with opacity 0 or visibility other than visible, a background image that covers the whole
//     viewport, and images whose bits-per-pixel is below performance.largest_contentful_paint_min_bpp (low-entropy
//     placeholders and spacers).
//   * Element Timing (element, PerformanceElementTiming): an element carrying an `elementtiming` attribute (an image or a
//     text block) makes one entry the first time it is painted, with its render and load times, natural size, the id and
//     the intersection rectangle.
//   * Layout Instability (layout-shift, LayoutShift): each rendering update compares where visible, non-fixed boxes are to
//     where they were in the previous frame; a box that moved without a recent user input contributes its move to a shift
//     score (impact fraction × distance fraction, the specification's formula), reported as one entry per frame with
//     sources (LayoutShiftAttribution). hadRecentInput marks a shift within performance.layout_shift_recent_input_ms of a
//     discrete input (a click or a key); session windows are kept for information (Cumulative Layout Shift).

import "core:strings"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:style"

// The grace period after a discrete input (click, key) within which a layout shift still counts as caused by it
// (LayoutShift.hadRecentInput) is performance.layout_shift_recent_input_ms (the specification's 500 ms by default).
// The gap that ends a layout-shift session window, and its longest span (Cumulative Layout Shift, informational).
LAYOUT_SHIFT_SESSION_GAP_MS :: 1000.0
LAYOUT_SHIFT_SESSION_MAX_MS :: 5000.0

@(private)
Lcp_Candidate :: struct {
	node:    base.Handle,
	area:    f64,          // visible area clamped to the viewport, CSS px^2
	rect:    [4]f64,       // the visible (clamped) rect: x, y, width, height, CSS px, viewport coordinates
	is_image: bool,
	load_ms: f64,
	url:     string,       // owned by the image state (cloned into the entry)
	natural_w, natural_h: int,
}

// The shell presented a frame that contains the document (the real paint LCP and Element Timing time to), with the layout
// it painted and the viewport it used. Finds the largest contentful element now and, when it beats every earlier
// candidate, records a Largest Contentful Paint entry; records Element Timing entries for elements that ask for them and
// are painted now. The shell passes its own layout so this never re-enters the layout pass.
timeline_present :: proc(p: ^Page, l: ^lay.Layout, vp: Viewport) {
	if p.web == nil || p.worker != nil { return }
	if l == nil || !l.valid { return }
	t := tl_of(p)
	if t == nil { return }
	s := &p.settings.timeline
	want_lcp := s.lcp_entries > 0 && !t.lcp_stopped
	want_et := s.element_entries > 0
	if !want_lcp && !want_et { return }
	// nothing new to find when the document and the viewport are as they were at the last scan (the scan walks every box)
	if t.lcp_scanned && t.lcp_scan_mutations == p.doc.mutations && t.lcp_scan_w == vp.width && t.lcp_scan_h == vp.height && t.lcp_scan_scroll == vp.scroll_y { return }
	t.lcp_scanned = true
	t.lcp_scan_mutations = p.doc.mutations
	t.lcp_scan_w, t.lcp_scan_h, t.lcp_scan_scroll = vp.width, vp.height, vp.scroll_y
	now_ms := page_now_ms(p)
	scale := f32(vp.scale)
	view := lay.view_make(l, {f32(vp.width) * scale, f32(vp.height) * scale}, f32(vp.scroll_y) * scale, cull = false)
	vp_area := vp.width * vp.height

	best: Lcp_Candidate
	for &b in l.boxes {
		node := b.node
		if node == base.NIL_HANDLE || .Anonymous in b.flags || .Dead in b.flags { continue }
		cand, ok := lcp_candidate_of(p, l, &view, vp, &b, vp_area)
		if !ok { continue }
		if want_et { element_timing_consider(p, t, node, cand, now_ms) }
		if want_lcp && cand.area > best.area { best = cand }
	}

	if want_lcp && best.node != base.NIL_HANDLE && best.area > t.lcp_largest {
		t.lcp_largest = best.area
		lcp_add_entry(p, t, best, now_ms)
	}
}

// Whether `b` is a Largest Contentful Paint / Element Timing candidate, and its clamped geometry. Images and text blocks
// qualify; the exclusions of the specification are applied here.
@(private)
lcp_candidate_of :: proc(p: ^Page, l: ^lay.Layout, view: ^lay.View, vp: Viewport, b: ^lay.Box, vp_area: f64) -> (c: Lcp_Candidate, ok: bool) {
	cs := b.cs
	if cs == nil { return }
	if cs.visibility != .Visible { return }   // visibility: hidden / collapse: not contentful
	if cs.opacity <= 0 { return }             // opacity 0: excluded by the spec
	node := b.node

	r, rok := lay.box_of_view(l, view, node)
	if !rok || !r.visible { return }
	g := geometry_of_rects(l, vp, node, r, rok)
	if !g.ok { return }
	// the border box in viewport coordinates, clamped to the viewport (the visible area is what counts)
	rect := clamp_to_viewport(g.client, vp)
	area := rect[2] * rect[3]
	if area <= 0 { return }

	// an image element (or a video poster): the natural pixels and the encoded size decide the entropy
	if load_ms, natural_px, enc, url, is_img := image_candidate(p, node); is_img {
		min_bpp := p.settings.timeline.lcp_min_bpp
		if min_bpp > 0 && enc > 0 {
			bpp := f64(enc) * 8 / area   // bits per displayed CSS px (the spec uses the displayed, concrete area)
			if bpp < min_bpp { return }
		}
		_ = natural_px
		c = Lcp_Candidate{node = node, area = area, rect = rect, is_image = true, load_ms = load_ms, url = url}
		c.natural_w, c.natural_h = image_natural_px(p, node)
		return c, true
	}

	// a background image that is not the full viewport: contentful; one covering the whole viewport is excluded
	if background_image_candidate(p, cs) {
		if area >= vp_area * 0.99 { return }   // a full-viewport background is not a candidate (the spec)
		return Lcp_Candidate{node = node, area = area, rect = rect, is_image = true}, true
	}

	// a block of text: a box that roots an inline formatting context and shows text
	if box_has_text(l, b) {
		return Lcp_Candidate{node = node, area = area, rect = rect}, true
	}
	return
}

@(private)
image_natural_px :: proc(p: ^Page, node: base.Handle) -> (w, h: int) {
	v := image_view(p, node)
	return v.pixel_size[0], v.pixel_size[1]
}

@(private)
background_image_candidate :: proc(p: ^Page, cs: ^style.Computed) -> bool {
	for img in cs.background_images {
		if img.kind != .Url || img.url == "" { continue }
		v := css_image_view(p, img.url)
		if v.state == .Ready && !v.svg { return true }
	}
	return false
}

// Whether a box roots an inline formatting context that shows at least one run of visible text.
@(private)
box_has_text :: proc(l: ^lay.Layout, b: ^lay.Box) -> bool {
	if .Ifc not_in b.flags { return false }
	start, end := b.items[0], b.items[1]
	if start < 0 || end > i32(len(l.inline_items)) { return false }
	for i in start ..< end {
		it := &l.inline_items[i]
		if it.kind == .Text && len(it.text) > 0 {
			// at least one non-space byte: a run of only whitespace is not contentful text
			for ch in it.text { if ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' { return true } }
		}
	}
	return false
}

// A rect (viewport coordinates, CSS px) clamped to the viewport: x, y, width, height of the visible part.
@(private)
clamp_to_viewport :: proc(r: Api_DomRect, vp: Viewport) -> [4]f64 {
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.width, vp.width)
	y1 := min(r.y + r.height, vp.height)
	if x1 <= x0 || y1 <= y0 { return {} }
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
lcp_add_entry :: proc(p: ^Page, t: ^Page_Timeline, c: Lcp_Candidate, now_ms: f64) {
	id_attr := ""
	if v, ok := dom.get_attribute(p.doc, c.node, "id"); ok { id_attr = v }
	// startTime is renderTime (the paint); loadTime is when an image candidate finished loading. Wren does not gate
	// renderTime behind Timing-Allow-Origin yet, so renderTime is always the real paint time.
	e := Tl_Entry{
		name = clone_str(""),   // LargestContentfulPaint.name is the empty string
		start = now_ms,
		render_time = now_ms,
		load_time = c.is_image ? c.load_ms : 0,
		size = f64(i64(c.area + 0.5)),
		id = clone_str(id_attr),
		url = clone_str(c.url),
		natural_w = c.natural_w,
		natural_h = c.natural_h,
		node = c.node,
	}
	timeline_add(p, .Largest_Contentful_Paint, e)
}

// Element Timing: an element with an `elementtiming` attribute makes one entry the first time it is painted.
@(private)
element_timing_consider :: proc(p: ^Page, t: ^Page_Timeline, node: base.Handle, c: Lcp_Candidate, now_ms: f64) {
	if t.et_seen[node] { return }
	identifier, has := dom.get_attribute(p.doc, node, "elementtiming")
	if !has { return }
	if t.et_seen == nil { t.et_seen = make(map[base.Handle]bool) }
	t.et_seen[node] = true
	id_attr := ""
	if v, ok := dom.get_attribute(p.doc, node, "id"); ok { id_attr = v }
	name := c.is_image ? c.url : "text"
	e := Tl_Entry{
		name = clone_str(name),
		start = now_ms,   // Element Timing startTime is renderTime
		render_time = now_ms,
		load_time = c.is_image ? c.load_ms : 0,
		size = f64(i64(c.area + 0.5)),
		id = clone_str(id_attr),
		identifier = clone_str(identifier),
		url = clone_str(c.url),
		natural_w = c.natural_w,
		natural_h = c.natural_h,
		intersect_rect = c.rect,
		node = node,
	}
	timeline_add(p, .Element, e)
}

////////////////////////////////
// Layout Instability

// Whether an event type is a discrete user input that ends Largest Contentful Paint and starts the layout-shift grace
// period (a pointer press, a key press, a mouse wheel; the Largest Contentful Paint and Layout Instability specs).
timeline_is_discrete_input :: proc(type: string) -> bool {
	switch type {
	case "mousedown", "pointerdown", "touchstart", "keydown", "wheel", "click": return true
	}
	return false
}

// A discrete user input happened now (page timeline): layout shifts within the grace period after it do not count against
// the page (LayoutShift.hadRecentInput), and Largest Contentful Paint stops at the first one. Called from the event path
// for clicks, keys and scrolls.
timeline_layout_shift_input :: proc(p: ^Page) {
	t := tl_of(p, false)
	if t == nil { return }
	t.ls_last_input_ms = page_now_ms(p)
	t.lcp_stopped = true
}

// One box's position between frames, kept to find what moved. The map lives on the timeline.
@(private)
Ls_Prev :: struct {
	doc:  [4]f64,   // the box's border rect in document coordinates (scroll-independent: a scroll is not a shift)
	view: [4]f64,   // ... and in viewport coordinates (what LayoutShiftAttribution reports)
}

// After a frame is laid out, compare where visible non-fixed boxes are to where they were, and record a layout-shift entry
// for the frame when content moved. The shell passes the layout it painted and its viewport (no re-entrant layout).
timeline_layout_shift_check :: proc(p: ^Page, l: ^lay.Layout, vp: Viewport) {
	if p.web == nil || p.worker != nil { return }
	if l == nil || !l.valid { return }
	s := &p.settings.timeline
	if s.layout_shift_entries == 0 { return }
	t := tl_of(p)
	if t == nil { return }
	// a layout shift needs the layout to have changed; a pure scroll or an unchanged frame moves nothing unexpectedly
	if t.ls_scanned && t.ls_scan_mutations == p.doc.mutations && t.ls_scan_w == vp.width && t.ls_scan_h == vp.height { return }
	t.ls_scanned = true
	t.ls_scan_mutations = p.doc.mutations
	t.ls_scan_w, t.ls_scan_h = vp.width, vp.height
	now_ms := page_now_ms(p)
	scale := f32(vp.scale)
	view := lay.view_make(l, {f32(vp.width) * scale, f32(vp.height) * scale}, f32(vp.scroll_y) * scale, cull = false)
	vp_area := vp.width * vp.height
	if vp_area <= 0 { return }

	// the union of the move regions (impact) and of the moved areas (for the distance fraction), and the sources
	impact_union: [4]f64
	have_impact := false
	max_move := 0.0
	sources := make([dynamic]Tl_Source, context.temp_allocator)

	prev := t.ls_prev
	if prev == nil { prev = make(map[base.Handle]Ls_Prev); t.ls_prev = prev }
	cur := make(map[base.Handle]Ls_Prev, len(prev))

	for &b in l.boxes {
		node := b.node
		if node == base.NIL_HANDLE || .Anonymous in b.flags || .Dead in b.flags { continue }
		cs := b.cs
		if cs == nil || cs.visibility != .Visible { continue }
		if cs.position == .Fixed { continue }   // fixed boxes do not shift the page
		r, rok := lay.box_of_view(l, &view, node)
		if !rok || !r.visible || r.transformed { continue }   // a transform move is not a layout shift
		g := geometry_of_rects(l, vp, node, r, rok)
		if !g.ok { continue }
		view_rect := [4]f64{g.client.x, g.client.y, g.client.width, g.client.height}
		doc_rect := [4]f64{f64(g.border.min.x), f64(g.border.min.y), f64(g.border.max.x - g.border.min.x), f64(g.border.max.y - g.border.min.y)}
		here := Ls_Prev{doc = doc_rect, view = view_rect}
		cur[node] = here
		// only boxes with content on screen now or before: at least partly in the viewport
		if view_rect[0] >= vp.width || view_rect[1] >= vp.height || view_rect[0] + view_rect[2] <= 0 || view_rect[1] + view_rect[3] <= 0 { continue }
		was, had := prev[node]
		if !had { continue }
		// movement in document coordinates: a scroll changes viewport coordinates but not these, so it is not a shift
		dx := doc_rect[0] - was.doc[0]
		dy := doc_rect[1] - was.doc[1]
		if abs(dx) < 0.5 && abs(dy) < 0.5 { continue }   // not moved (sub-pixel jitter ignored)
		// the move region is the union of the old and new viewport positions (Layout Instability §: impact region)
		old_clamped := clamp_rect_to_viewport(was.view, vp)
		new_clamped := clamp_rect_to_viewport(view_rect, vp)
		region := rect_union4(old_clamped, new_clamped)
		if region[2] * region[3] <= 0 { continue }
		if !have_impact { impact_union = region; have_impact = true } else { impact_union = rect_union4(impact_union, region) }
		move := max(abs(dx), abs(dy))
		if move > max_move { max_move = move }
		append(&sources, Tl_Source{node = node, prev = was.view, cur = view_rect})
	}

	delete(t.ls_prev)
	t.ls_prev = cur

	if !have_impact || len(sources) == 0 { return }
	impact_fraction := (impact_union[2] * impact_union[3]) / vp_area
	// distance fraction: the greatest move divided by the larger viewport side (Layout Instability §)
	max_side := max(vp.width, vp.height)
	distance_fraction := max_side > 0 ? max_move / max_side : 0
	value := impact_fraction * distance_fraction
	if value <= 0 { return }

	had_input := t.ls_last_input_ms > 0 && (now_ms - t.ls_last_input_ms) <= f64(config_layout_shift_recent_input_ms(p))

	// session windows (informational Cumulative Layout Shift)
	if !had_input {
		if t.ls_session_first_ms == 0 || now_ms - t.ls_session_last_ms > LAYOUT_SHIFT_SESSION_GAP_MS || now_ms - t.ls_session_first_ms > LAYOUT_SHIFT_SESSION_MAX_MS {
			t.ls_session_first_ms = now_ms
			t.ls_session_value = 0
		}
		t.ls_session_last_ms = now_ms
		t.ls_session_value += value
		if t.ls_session_value > t.ls_max_session { t.ls_max_session = t.ls_session_value }
	}

	owned_sources := make([]Tl_Source, len(sources))
	copy(owned_sources, sources[:])
	e := Tl_Entry{
		name = clone_str(""),
		start = now_ms,
		value = value,
		had_input = had_input,
		last_input_ms = had_input ? t.ls_last_input_ms : 0,
		sources = owned_sources,
	}
	timeline_add(p, .Layout_Shift, e)
}

@(private)
config_layout_shift_recent_input_ms :: proc(p: ^Page) -> f64 {
	return p.settings.timeline.layout_shift_recent_input_ms
}

@(private)
clamp_rect_to_viewport :: proc(r: [4]f64, vp: Viewport) -> [4]f64 {
	x0 := max(r[0], 0)
	y0 := max(r[1], 0)
	x1 := min(r[0] + r[2], vp.width)
	y1 := min(r[1] + r[3], vp.height)
	if x1 <= x0 || y1 <= y0 { return {} }
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
rect_union4 :: proc(a, b: [4]f64) -> [4]f64 {
	if a[2] * a[3] <= 0 { return b }
	if b[2] * b[3] <= 0 { return a }
	x0 := min(a[0], b[0])
	y0 := min(a[1], b[1])
	x1 := max(a[0] + a[2], b[0] + b[2])
	y1 := max(a[1] + a[3], b[1] + b[3])
	return {x0, y0, x1 - x0, y1 - y0}
}

////////////////////////////////
// visibility-state

// The page became visible or hidden: record a visibility-state entry when it changed (the name is "visible" or "hidden",
// startTime is the moment). Called by the shell when it shows or hides the tab.
timeline_visibility_state :: proc(p: ^Page, hidden: bool) {
	if p.web == nil || p.worker != nil { return }
	if p.settings.timeline.visibility_entries == 0 { return }
	t := tl_of(p)
	if t == nil { return }
	if t.vis_known && t.vis_hidden == hidden { return }
	t.vis_known = true
	t.vis_hidden = hidden
	timeline_add(p, .Visibility_State, Tl_Entry{name = clone_str(hidden ? "hidden" : "visible"), start = page_now_ms(p)})
}

@(private)
clone_str :: proc(s: string) -> string {
	if s == "" { return "" }
	return strings.clone(s)
}

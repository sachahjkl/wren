package browser

// Text selection in the page, as Chromium does it: press and drag (the page scrolls, or the scroll box the selection
// started in, while the pointer is past its edge), double click = word (and its trailing spaces on Windows), triple
// click = paragraph, Shift+click extends, Ctrl+A selects all, Escape or a click elsewhere deselects; user-select: none
// text is skipped and user-select: all elements are selected whole. The selection itself is the page's (DOM
// boundary points, page/selection.odin); positions come from the display list (layout/selection.odin).
//
// Painting: the painter calls `selection_paint_under` before each item (the highlight goes above the backgrounds,
// under the text) and `selection_paint_over` after it (selected text again in the highlight text color, clipped to the
// highlight; replaced content tinted). Colors: the page's ::selection, else browser.selection.* (system colors by
// default). Find-in-page matches are painted the same way (find_bar.odin).
//
// Copy (Ctrl+C, Ctrl+Insert, the context menu): a cancelable `copy` event at the selection, then text (innerText
// rules) and HTML on the clipboard.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:dom"
import "wb:forms"
import lay "wb:layout"
import "wb:page"
import "wb:style"

Sel_Unit :: enum u8 { Char, Word, Paragraph }

// A window's text selection gesture (Window_Own.selection).
Selection_Shell :: struct {
	page:        ^page.Page,          // the page the current gesture belongs to
	down:        bool,                // the left button is held since a press that selects
	unit:        Sel_Unit,
	press_pos:   [2]f32,              // window pixels
	moved:       bool,                // past the drag threshold
	origin:      [2]lay.Text_Pos,     // the unit first selected (word / paragraph drags keep it selected)
	started:     bool,                // selectstart was fired for this gesture and not cancelled
	cancelled:   bool,                // selectstart was cancelled: this gesture selects nothing
	clicks:      int,
	last_click:  time.Tick,
	last_click_pos: [2]f32,
	mouse:       [2]f32,
	scroller:    base.Handle,         // what auto-scroll moves (NIL: the document)
	pending:     bool,                // a press came while the layout was older than the document: handled next frame
	pending_ev:  platform.Event,
	selected_by_drag: bool,           // the gesture selected text: its release is not a click
	last_tick:   time.Tick,
	stale:       bool,                // a move found the layout older than the document: the gesture extends to the pointer once it is fresh
	preview:     Sel_Preview,
}

// A drag that goes on while the page holds the thread (a long script): its moves wait for the page in order (shell_frames.odin
// `deferred`), and each will extend the selection when the page has its turn, as it would have then. Meanwhile chrome frames
// show what they will select: the range is worked out here from the last layout, without the page (no event, no change of
// the DOM's selection: a script running sees the selection it had when its task began) and painted by the compositor from
// that layout (shell_paint_layout). Only where the moves cannot run the page's code: no pointermove or mousemove listener
// anywhere, and no selectstart one before the gesture has started a selection. Gone once the page's turn has extended the
// selection (extend_to), or when the gesture ends.
Sel_Preview :: struct {
	on:            bool,
	anchor, focus: lay.Text_Pos,
}


// Start-up: the preferences of this part of the shell, then follows them.
interaction_init :: proc(app: ^App) {
	app.ix = interaction_settings_from_prefs(&app.prefs)
	search_engines_init(app)
	app.watches[.Interaction] = config.watch(&app.prefs, "browser.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		interaction_settings_destroy(&the_app.ix)
		the_app.ix = interaction_settings_from_prefs(p)
		request_frames((^App)(user), 2)
	}, app)
}

interaction_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, app.watches[.Interaction])
	interaction_settings_destroy(&app.ix)
	search_engines_destroy(app)
	find_destroy(find_state(app))
	closed_tabs_destroy(app)
	context_menu_destroy(app)
}

@(private = "file")
page_viewport :: proc(app: ^App) -> [2]f32 { return draw.rect_size(active_window(app).page_rect) }

@(private = "file")
text_api :: proc(app: ^App) -> lay.Text_Api { return page_text_api(&app.page_render.fonts, &app.measure, &app.page_settings.style) }

// The text position under a window point (ok = false: no text, or a layout older than the document).
position_of :: proc(app: ^App, t: ^Tab, pos: [2]f32) -> (lay.Text_Pos, bool) {
	if t.page == nil || !t.layout.valid { return {}, false }
	return lay.position_at(&t.layout, t.page.doc, t.page.styled, pos - active_window(app).page_rect.min, page_viewport(app), t.scroll, text_api(app))
}

@(private = "file")
layout_fresh :: proc(t: ^Tab) -> bool { return t.page != nil && t.layout.valid && t.layout.mutations == t.page.doc.mutations }

// Is `target` (or an ancestor) a form control? Presses there are the control's (forms_shell.odin).
@(private = "file")
in_control :: proc(t: ^Tab, target: base.Handle) -> bool {
	p := t.page
	if p.formctl == nil { return false }
	f := page.page_forms(p)
	for cur := target; cur != base.NIL_HANDLE; cur = forms.parent_element(f, cur) {
		#partial switch forms.kind(f, cur) {
		case .Input, .Textarea, .Select, .Button, .Option: return true
		}
	}
	return false
}

@(private = "file")
double_click_ms :: proc(app: ^App) -> f64 {
	if ms := app.page_settings.forms.double_click_ms; ms > 0 { return f64(ms) }
	return system_double_click_ms()   // forms_shell_<os>.odin: the desktop's double-click time (Windows) or a default
}

// The unit (word, paragraph, user-select: all element) at `p` for a gesture of `unit`.
@(private = "file")
unit_at :: proc(t: ^Tab, p: lay.Text_Pos, unit: Sel_Unit) -> (a, b: lay.Text_Pos, ok: bool) {
	d, st := t.page.doc, t.page.styled
	if root := lay.select_all_root(d, st, dom.get(d, p.node) != nil && dom.get(d, p.node).kind == .Text ? dom.get(d, p.node).parent : p.node); root != base.NIL_HANDLE {
		return lay.pos_before(d, root), lay.pos_after(d, root), true
	}
	switch unit {
	case .Char: return p, p, true
	case .Word: return lay.word_range(d, st, p, the_app.ix.word_eats_space)
	case .Paragraph: return lay.paragraph_range(d, st, p)
	}
	return
}

// selectstart at the node where the selection begins: false when the page cancels it.
@(private = "file")
fire_selectstart :: proc(t: ^Tab, at: lay.Text_Pos) -> bool {
	p := t.page
	target := at.node
	if n := dom.get(p.doc, target); n != nil && n.kind != .Element && n.kind != .Text { target = p.body }
	return page.dispatch_event(p, target, dom.Event{type = "selectstart", bubbles = true, cancelable = true})
}

// When the user pressed: the event's time, not its turn's: on a busy page two quick clicks wait, and came together or far apart.
press_time :: proc(ev: platform.Event) -> time.Tick { return ev.stamp != {} ? ev.stamp : time.tick_now() }

// A left press in the page: which click of a series it is. Every press counts, whatever then takes it: the third click of a triple
// click lands on the word the second one selected, which is also how a drag of the selection begins.
selection_press_count :: proc(app: ^App, ev: platform.Event) {
	ss := &window_own(app).selection
	now := press_time(ev)
	scale := page_scale(app)
	if time.duration_milliseconds(time.tick_diff(ss.last_click, now)) <= double_click_ms(app) && abs(ev.pos.x - ss.last_click_pos.x) < 4 * scale && abs(ev.pos.y - ss.last_click_pos.y) < 4 * scale {
		ss.clicks = ss.clicks % 3 + 1
	} else {
		ss.clicks = 1
	}
	ss.last_click, ss.last_click_pos = now, ev.pos
}

// A left press in the page that no form control took (after mousedown, which `allowed` says was not cancelled).
selection_pointer_down :: proc(app: ^App, t: ^Tab, ev: platform.Event, target: base.Handle, allowed: bool) {
	if t.page == nil || ev.button != .Left { return }
	ss := &window_own(app).selection
	p := t.page
	ss.down, ss.moved, ss.selected_by_drag = false, false, false
	ss.stale, ss.preview = false, {}
	if !allowed { return }
	if target != base.NIL_HANDLE && in_control(t, target) { page.selection_clear(p); return }
	if !layout_fresh(t) { ss.pending, ss.pending_ev = true, ev; return }
	start_gesture(app, t, ev)
}

@(private = "file")
start_gesture :: proc(app: ^App, t: ^Tab, ev: platform.Event) {
	ss := &window_own(app).selection
	p := t.page
	ss.page = p
	ss.press_pos, ss.mouse = ev.pos, ev.pos
	ss.cancelled, ss.started = false, false
	pos, ok := position_of(app, t, ev.pos)
	when DEBUG_INPUT {
		n := dom.get(p.doc, pos.node)
		debug_log(fmt.tprintf("press %v page_rect %v scroll %v -> %v %q", ev.pos, active_window(app).page_rect, t.scroll, pos, n != nil ? n.text : ""))
	}
	if !ok { page.selection_clear(p); return }
	ss.down = true
	ss.scroller = scroller_of(t, pos.node)
	ss.unit = .Char
	if ss.clicks == 2 { ss.unit = .Word } else if ss.clicks >= 3 { ss.unit = .Paragraph }
	if .Shift in ev.mods && p.selection.has {
		// extend from the anchor, by the unit of the gesture
		page.selection_extend(p, pos)
		ss.origin = {p.selection.anchor, p.selection.anchor}
		ss.started = true
		return
	}
	a, b, uok := unit_at(t, pos, ss.unit)
	if !uok { a, b = pos, pos }
	ss.origin = {a, b}
	if a == b {
		page.selection_collapse(p, a)   // nothing selected; the next drag starts here
		return
	}
	if !fire_selectstart(t, a) { ss.cancelled = true; page.selection_clear(p); return }
	if t.page != p { return }
	ss.started = true
	page.selection_set(p, a, b)
}

// Pointer moves while the button is held: the focus follows the pointer (by words / paragraphs after a double / triple click).
selection_pointer_move :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	ss := &window_own(app).selection
	ss.mouse = pos
	if !ss.down || t.page == nil || t.page != ss.page || ss.cancelled { return }
	if !ss.moved {
		if !past_threshold(app, ss, pos) { return }
		ss.moved = true
	}
	extend_to(app, t, pos)
}

@(private = "file")
past_threshold :: proc(app: ^App, ss: ^Selection_Shell, pos: [2]f32) -> bool {
	d := pos - ss.press_pos
	return d.x * d.x + d.y * d.y >= app.ix.drag_threshold_px * app.ix.drag_threshold_px * page_scale(app) * page_scale(app)
}

// The anchor and focus a gesture has with the pointer at `pos` (ok = false: no text there).
@(private = "file")
gesture_range :: proc(app: ^App, t: ^Tab, pos: [2]f32) -> (anchor, focus: lay.Text_Pos, ok: bool) {
	ss := &window_own(app).selection
	tp := position_of(app, t, pos) or_return
	a, b, uok := unit_at(t, tp, ss.unit)
	if !uok { a, b = tp, tp }
	o := ss.origin
	if lay.pos_compare(t.page.doc, a, o[0]) < 0 { return o[1], a, true }
	return o[0], b, true
}

@(private = "file")
extend_to :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	ss := &window_own(app).selection
	p := t.page
	if !layout_fresh(t) { ss.stale = true; return }
	ss.stale, ss.preview = false, {}
	anchor, focus, ok := gesture_range(app, t, pos)
	if !ok { return }
	if anchor != focus && !ss.started {
		if !fire_selectstart(t, anchor) { ss.cancelled = true; page.selection_clear(p); return }
		if t.page != p { return }
		ss.started = true
	}
	page.selection_set(p, anchor, focus)
	if anchor != focus { ss.selected_by_drag = true }
}

// The release ends the gesture. True when the gesture selected text by dragging: the release is not a click then.
selection_pointer_up :: proc(app: ^App, t: ^Tab, ev: platform.Event) -> bool {
	if ev.button != .Left { return false }
	ss := &window_own(app).selection
	was := ss.down && ss.moved && ss.selected_by_drag
	// a press that was waiting for a fresh layout (selection_shell_frame) is over with its release: started later it would open a gesture
	// with the button already up, and the next moves would select text
	ss.pending = false
	ss.down = false
	ss.stale, ss.preview = false, {}
	return was
}

// A chrome frame (shell_frames.odin): the pointer moved to `pos` with the gesture's button held; the move itself waits for
// the page. What it will select is shown meanwhile (Sel_Preview), when that can be known without the page.
selection_preview_move :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	ss := &window_own(app).selection
	if !ss.down || ss.cancelled || t.page == nil || t.page != ss.page || !preview_possible(app, t) { return }
	if !ss.moved && !ss.preview.on && !past_threshold(app, ss, pos) { return }
	anchor, focus, ok := gesture_range(app, t, pos)
	if !ok { return }
	// (the gesture's first selection fires selectstart, which the page may cancel)
	if anchor != focus && !ss.started && page.page_listens(t.page, "selectstart") { return }
	ss.preview = {true, anchor, focus}
}

// What is shown of the gesture in a chrome frame is its preview: the page's last frame painted again with it.
selection_preview_shown :: proc(app: ^App, t: ^Tab) -> bool {
	ss := &window_own(app).selection
	return ss.preview.on && t.page != nil && t.page == ss.page && preview_possible(app, t)
}

// Its two ends are still in the document (the script that held the thread may have changed it).
@(private = "file")
preview_valid :: proc(p: ^page.Page, pv: Sel_Preview) -> bool {
	inside :: proc(p: ^page.Page, at: lay.Text_Pos) -> bool { return dom.get(p.doc, at.node) != nil && lay.in_document(p.doc, at.node) && at.offset <= lay.node_length(p.doc, at.node) }
	return inside(p, pv.anchor) && inside(p, pv.focus)
}

// The gesture's next selection can be worked out and painted from the layout of the page's last frame (shell_frames.odin
// shell_layout_paintable), the moves run none of the page's code, and the wheel did not move the page meanwhile (the moves
// are hit-tested where the page's turn finds it).
@(private = "file")
preview_possible :: proc(app: ^App, t: ^Tab) -> bool {
	if !shell_layout_paintable(app, t) || !layout_fresh(t) { return false }
	if app.chrome_frames.pending_tab == t.id && app.chrome_frames.pending_scroll != {} { return false }
	return !page.page_listens(t.page, "pointermove") && !page.page_listens(t.page, "mousemove")
}

// The nearest scroll container of `node` that can scroll (NIL: the document scrolls).
@(private = "file")
scroller_of :: proc(t: ^Tab, node: base.Handle) -> base.Handle {
	d := t.page.doc
	for cur := node; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if lim, ok := lay.scroll_max(&t.layout, cur); ok && (lim.x > 0 || lim.y > 0) { return cur }
		cur = n.parent
	}
	return base.NIL_HANDLE
}

// Each frame: selectionchange, a press that waited for a fresh layout, automatic scrolling while dragging past an edge.
selection_shell_frame :: proc(app: ^App) {
	wnd := active_window(app)
	ss := &window_own(app).selection
	now := time.tick_now()
	dt := f32(clamp(time.duration_seconds(time.tick_diff(ss.last_tick, now)), 0, 0.1))
	ss.last_tick = now
	t := current_tab(app)
	for tab in tabs_all(app) { if tab.page != nil { page.selection_flush(tab.page) } }
	if t == nil || t.page == nil || t.kind != .Web { ss.down, ss.preview = false, {}; return }
	if ss.pending && layout_fresh(t) {
		ss.pending = false
		start_gesture(app, t, ss.pending_ev)
	}
	// the moves of this frame have had their turn: what a chrome frame showed of them is the selection now, but where the
	// layout was older than the document (the script changed it), which the next frame, laid out, extends to the pointer
	waits := false
	if ss.stale && ss.down && ss.moved && !ss.cancelled && t.page == ss.page {
		extend_to(app, t, ss.mouse)
		waits = ss.stale
		if waits { request_frames(app, 2) }
	}
	if !waits { ss.stale, ss.preview = false, {} }
	if !ss.down || t.page != ss.page || !ss.moved || ss.cancelled || app.ix.autoscroll_speed <= 0 { return }
	port := wnd.page_rect
	if ss.scroller != base.NIL_HANDLE {
		if r, ok := lay.box_of(&t.layout, ss.scroller, page_viewport(app), t.scroll); ok {
			off := wnd.page_rect.min - doc_scroll_vec(t)   // (document coordinates, position: fixed boxes included)
			port = draw.Rect{r.padding.min + off, r.padding.max + off}
			port = {{max(port.min.x, wnd.page_rect.min.x), max(port.min.y, wnd.page_rect.min.y)}, {min(port.max.x, wnd.page_rect.max.x), min(port.max.y, wnd.page_rect.max.y)}}
		}
	}
	past :: proc(v, lo, hi: f32) -> f32 { return v < lo ? v - lo : (v > hi ? v - hi : 0) }
	m := ss.mouse
	d := [2]f32{past(m.x, port.min.x, port.max.x), past(m.y, port.min.y, port.max.y)}
	if d == {} { return }
	speed := [2]f32{clamp(d.x * app.ix.autoscroll_speed, -app.ix.autoscroll_max, app.ix.autoscroll_max), clamp(d.y * app.ix.autoscroll_speed, -app.ix.autoscroll_max, app.ix.autoscroll_max)} * page_scale(app)
	step := speed * dt
	moved := false
	if ss.scroller != base.NIL_HANDLE {
		if cur, ok := lay.scroll_of(&t.layout, ss.scroller); ok {
			got, _ := lay.set_scroll(&t.layout, ss.scroller, cur + step)
			moved = got != cur
		}
	}
	if !moved && step != {} {
		before := [2]f32{t.layout.doc_scroll_x, t.scroll}
		lo_y, hi_y := lay.doc_scroll_y_range(&t.layout, page_viewport(app).y)
		t.scroll = clamp(t.scroll + step.y, lo_y, hi_y)
		doc_scroll_x_set(t, t.layout.doc_scroll_x + step.x, page_viewport(app).x)
		moved = before != {t.layout.doc_scroll_x, t.scroll}
	}
	// keep selecting under the pointer, clamped into the view (what is scrolled in gets selected)
	inside := [2]f32{clamp(m.x, port.min.x + 1, port.max.x - 1), clamp(m.y, port.min.y + 1, port.max.y - 1)}
	extend_to(app, t, inside)
	request_frames(app, 2)
	_ = moved
}

////////////////////////////////
// Keyboard and copy

// Keys of the page that act on the selection or the focused link, after keydown was not cancelled and no text field
// took them. True when used.
selection_key :: proc(app: ^App, t: ^Tab, p: ^page.Page, ev: platform.Event) -> bool {
	ctrl, shift, alt := .Ctrl in ev.mods, .Shift in ev.mods, .Alt in ev.mods
	switch {
	case ctrl && !shift && !alt && ev.key == .A:
		page.selection_select_all(p)
		return true
	case ctrl && !shift && !alt && (ev.key == .C || ev.key == .Insert):
		copy_selection(app, t)
		return true
	case ev.key == .Escape && !ctrl && !alt && page.selection_active(p):
		page.selection_clear(p)
		return true
	}
	return false
}

// Copy of the selection: `copy` at the selection's start (a listener may cancel it), then text and HTML.
copy_selection :: proc(app: ^App, t: ^Tab) -> bool {
	p := t.page
	if p == nil || !page.selection_active(p) { return false }
	a, _, _ := page.selection_range(p)
	target := a.node
	if n := dom.get(p.doc, target); n != nil && n.kind == .Text { target = n.parent }
	if !page.dispatch_event(p, target, dom.Event{type = "copy", bubbles = true, cancelable = true}) { return false }
	if t.page != p { return false }
	text := page.selection_text(p)
	html := page.selection_html(p)
	return clipboard_set_rich(app, text, html, p.env.location.href)
}

////////////////////////////////
// Painting

Sel_Paint :: struct {
	on:        bool,
	doc:       ^dom.Document,
	styled:    ^style.Styled,
	start, end: lay.Text_Pos,
	bg, fg:    draw.Color,
	keep_fg:   bool,
	api:       lay.Text_Api,
	find:      ^Find_State,
	drop:      lay.Text_Pos,   // the caret of text dragged over an editing host (dnd_shell.odin)
	has_drop:  bool,
	drop_color: draw.Color,
	highlights: ^page.Page_Highlights,   // CSS.highlights (nil: nothing registered)
}


// What the selection and find highlights painted into recorded pictures depend on (compositor.odin records again when it changes).
selection_paint_key :: proc() -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: ^u64, b: []byte) { for c in b { h^ = (h^ ~ u64(c)) * 0x100000001b3 } }
	on := the_app.spaint.on
	mix(&h, mem.ptr_to_bytes(&on))
	if hl := the_app.spaint.highlights; hl != nil { mix(&h, mem.ptr_to_bytes(&hl.serial)) }
	if on {
		mix(&h, mem.ptr_to_bytes(&the_app.spaint.start)); mix(&h, mem.ptr_to_bytes(&the_app.spaint.end))
		mix(&h, mem.ptr_to_bytes(&the_app.spaint.bg)); mix(&h, mem.ptr_to_bytes(&the_app.spaint.fg))
	}
	if f := the_app.spaint.find; f != nil {
		mix(&h, transmute([]byte)f.query)
		n, a := len(f.matches), f.active
		mix(&h, mem.ptr_to_bytes(&n)); mix(&h, mem.ptr_to_bytes(&a))
	}
	if the_app.spaint.has_drop { mix(&h, mem.ptr_to_bytes(&the_app.spaint.drop)) }
	return h
}

// Hex color "#rgb", "#rrggbb", "#rrggbbaa" (sRGB) as a draw color; ok = false for anything else.
parse_pref_color :: proc(s: string) -> (draw.Color, bool) {
	t := strings.trim_space(s)
	if len(t) < 4 || t[0] != '#' { return {}, false }
	hexv :: proc(c: u8) -> (u32, bool) {
		switch c {
		case '0' ..= '9': return u32(c - '0'), true
		case 'a' ..= 'f': return u32(c - 'a') + 10, true
		case 'A' ..= 'F': return u32(c - 'A') + 10, true
		}
		return 0, false
	}
	h := t[1:]
	v: [8]u32
	for i in 0 ..< len(h) {
		if i >= 8 { return {}, false }
		x, ok := hexv(h[i])
		if !ok { return {}, false }
		v[i] = x
	}
	switch len(h) {
	case 3: return draw.srgb(f32(v[0] * 17) / 255, f32(v[1] * 17) / 255, f32(v[2] * 17) / 255, 1), true
	case 6: return draw.srgb(f32(v[0] * 16 + v[1]) / 255, f32(v[2] * 16 + v[3]) / 255, f32(v[4] * 16 + v[5]) / 255, 1), true
	case 8: return draw.srgb(f32(v[0] * 16 + v[1]) / 255, f32(v[2] * 16 + v[3]) / 255, f32(v[4] * 16 + v[5]) / 255, f32(v[6] * 16 + v[7]) / 255), true
	}
	return {}, false
}

// The default selection colors (used when the preference is not a color): the system's highlight on Windows, a sensible
// default elsewhere. system_selection_bg / _fg are in selection_colors_<os>.odin.

// Before the page is painted: what is selected, in which colors, and the find matches.
selection_paint_begin :: proc(app: ^App, t: ^Tab) {
	app.spaint = {}
	if t.page == nil || !layout_fresh(t) { return }
	p := t.page
	app.spaint.doc, app.spaint.styled = p.doc, p.styled
	app.spaint.api = text_api(app)
	app.spaint.find = find_paint_state(app, t)
	app.spaint.highlights = page.highlights_paint(p)
	if c, ok := page.drag_caret(p); ok && !c.field {
		app.spaint.drop, app.spaint.has_drop = c.pos, true
		if cs := style.style_of(p.styled, c.node); cs != nil { app.spaint.drop_color = to_draw(cs.color) } else { app.spaint.drop_color = draw.srgb(0, 0, 0, 1) }
	}
	if ss := &window_own(app).selection; ss.preview.on && ss.page == p && preview_valid(p, ss.preview) {
		// a drag's moves are waiting for the page: what they will select (Sel_Preview)
		a, b := ss.preview.anchor, ss.preview.focus
		if lay.pos_compare(p.doc, a, b) > 0 { a, b = b, a }
		app.spaint.on = a != b
		app.spaint.start, app.spaint.end = a, b
	} else if a, b, ok := page.selection_range(p); ok && a != b {
		app.spaint.on = true
		app.spaint.start, app.spaint.end = a, b
	}
	active := active_window(app).win.focused
	if c, ok := parse_pref_color(active ? app.ix.sel_bg : app.ix.sel_inactive_bg); ok { app.spaint.bg = c } else if active { app.spaint.bg = system_selection_bg() } else {
		app.spaint.bg = draw.srgb(0.78, 0.78, 0.78, 1)
		if c2, ok2 := parse_pref_color(app.ix.sel_bg); ok2 { app.spaint.bg = c2; app.spaint.bg.a *= 0.5 }
	}
	if app.ix.sel_fg == "keep" || !active { app.spaint.keep_fg = true } else if c, ok := parse_pref_color(app.ix.sel_fg); ok { app.spaint.fg = c } else { app.spaint.fg = system_selection_fg() }
}

@(private = "file")
item_index :: proc(l: ^Layout, it: ^lay.Display_Item) -> int {
	if len(l.items) == 0 { return -1 }
	i := int((uintptr(it) - uintptr(&l.items[0])) / size_of(lay.Display_Item))
	return i >= 0 && i < len(l.items) ? i : -1
}

// The colors of the selection over the text of element `el` (its ::selection, else the browser's).
@(private = "file")
colors_for :: proc(el: base.Handle) -> (bg, fg: draw.Color, keep: bool) {
	bg, fg, keep = the_app.spaint.bg, the_app.spaint.fg, the_app.spaint.keep_fg
	if the_app.spaint.styled == nil { return }
	sfg, has_fg, sbg, has_bg := style.selection_colors(the_app.spaint.styled, the_app.spaint.doc, el)
	if has_bg { bg = to_draw(sbg) }
	if has_fg { fg, keep = to_draw(sfg), false } else if has_bg { keep = true }   // a page background alone keeps the text's color
	return
}

@(private = "file")
span_rect :: proc(l: ^Layout, it: ^lay.Display_Item, r: draw.Rect, a, b: int) -> draw.Rect {
	// caret positions through the shaped clusters: a right-to-left item has the start of the range on the right
	ca, cb := lay.item_caret_x(l, it, a, the_app.spaint.api), lay.item_caret_x(l, it, b, the_app.spaint.api)
	x0, x1 := min(ca, cb), max(ca, cb)
	if .Vertical in it.flags { return {{r.min.x, math.floor(r.min.y + x0)}, {r.max.x, math.ceil(r.min.y + x1)}} }
	return {{math.floor(r.min.x + x0), r.min.y}, {math.ceil(r.min.x + x1), r.max.y}}
}

// The painter, before item `it` (drawn at `r`, window pixels): highlights of the selection and of find matches.
selection_paint_under :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	if it.kind != .Text || (!the_app.spaint.on && the_app.spaint.find == nil && !the_app.spaint.has_drop && the_app.spaint.highlights == nil) { return }
	idx := item_index(l, it)
	if idx < 0 { return }
	if the_app.spaint.highlights != nil { highlights_paint_under(l, dc, it, idx, r) }
	if the_app.spaint.has_drop {
		// the drop caret, in the piece of text it falls in (the item's start owns a position between two items)
		if node, lo, hi, ok := lay.item_source(l, the_app.spaint.doc, idx); ok && node == the_app.spaint.drop.node && the_app.spaint.drop.offset >= lo && the_app.spaint.drop.offset <= hi {
			if n := dom.get(the_app.spaint.doc, node); n != nil && hi <= len(n.text) {
				k := lay.source_to_item(it.text, n.text[lo:hi], the_app.spaint.drop.offset - lo)
				if .Vertical in it.flags {
					y := math.round(r.min.y + lay.item_caret_x(l, it, k, the_app.spaint.api))
					w := max(math.round((r.max.x - r.min.x) / 16), 1)
					draw.rect(dc, {{r.min.x, y}, {r.max.x, y + w}}, the_app.spaint.drop_color)
				} else {
					x := math.round(r.min.x + lay.item_caret_x(l, it, k, the_app.spaint.api))
					w := max(math.round((r.max.y - r.min.y) / 16), 1)
					draw.rect(dc, {{x, r.min.y}, {x + w, r.max.y}}, the_app.spaint.drop_color)
				}
			}
		}
	}
	if !the_app.spaint.on && the_app.spaint.find == nil { return }
	if the_app.spaint.find != nil { find_paint_item(the_app.spaint.find, l, dc, it, idx, r) }
	if !the_app.spaint.on { return }
	a, b, ok := lay.item_range(l, the_app.spaint.doc, idx, the_app.spaint.start, the_app.spaint.end)
	if !ok || !lay.is_selectable(the_app.spaint.doc, the_app.spaint.styled, it.node) { return }
	bg, _, _ := colors_for(it.node)
	rect := span_rect(l, it, r, a, b)
	// the selection goes on past this piece of text: the collapsed space after it (not drawn by any item) or the
	// line's end is highlighted too, as browsers do
	if b == len(it.text) && !strings.has_suffix(it.text, " ") {
		if node, _, hi, sok := lay.item_source(l, the_app.spaint.doc, idx); sok && lay.pos_compare(the_app.spaint.doc, {node, hi}, the_app.spaint.end) < 0 {
			if fi := lay.item_font(l, it); fi != nil {
				// after the logical end: on the left of a right-to-left item
				if .Vertical in it.flags {
					rect.max.y += math.ceil(fi.space)
				} else if it.level & 1 == 1 { rect.min.x -= math.ceil(fi.space) } else { rect.max.x += math.ceil(fi.space) }
			}
		}
	}
	draw.rect(dc, rect, bg)
}

// Bytes [a, b) of the text of item `it` drawn again, in `fg`.
@(private = "file")
text_again :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect, a, b: int, fg: draw.Color) {
	fi := lay.item_font(l, it)
	if fi == nil || it.cs == nil { return }
	draw.push_clip(dc, span_rect(l, it, r, a, b))
	if .Vertical in it.flags {
		draw_vertical_text(l, dc, it, fi, it.baseline + (r.min.x - it.rect.min.x), r.min.y, r.max.y, fg, text_shape_options(l, it.cs, it.level, it.extra))
	} else {
		baseline := it.baseline + (r.min.y - it.rect.min.y)
		sel_draw_run(dc, font.Font_Id(fi.font), fi.size, {r.min.x, baseline}, fg, it.text, text_shape_options(l, it.cs, it.level, it.extra))
	}
	draw.pop_clip(dc)
}

// What of CSS.highlights falls on item `idx`, lowest priority first: `each` with the bytes of the item and the highlight.
@(private = "file")
highlights_of_item :: proc(l: ^Layout, idx: int, data: Highlight_Draw, each: proc(data: Highlight_Draw, a, b: int, name: string)) {
	hl := the_app.spaint.highlights
	node, _, _, ok := lay.item_source(l, the_app.spaint.doc, idx)
	if !ok { return }
	spans, has := hl.spans[node]
	if !has { return }
	for s in spans {
		if a, b, in_item := lay.item_range(l, the_app.spaint.doc, idx, {node, s.lo}, {node, s.hi}); in_item { each(data, a, b, hl.list[s.highlight].name) }
	}
}

Highlight_Draw :: struct { l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect }

// The backgrounds of the highlights over item `it`, under its text and the selection.
@(private = "file")
highlights_paint_under :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, idx: int, r: draw.Rect) {
	highlights_of_item(l, idx, Highlight_Draw{l, dc, it, r}, proc(h: Highlight_Draw, a, b: int, name: string) {
		if the_app.spaint.styled == nil { return }
		_, _, bg, has_bg := style.highlight_colors(the_app.spaint.styled, the_app.spaint.doc, h.it.node, name)
		if has_bg { draw.rect(h.dc, span_rect(h.l, h.it, h.r, a, b), to_draw(bg)) }
	})
}

// Their colors, on the text just drawn: the highest priority last.
@(private = "file")
highlights_paint_over :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	idx := item_index(l, it)
	if idx < 0 { return }
	highlights_of_item(l, idx, Highlight_Draw{l, dc, it, r}, proc(h: Highlight_Draw, a, b: int, name: string) {
		if the_app.spaint.styled == nil { return }
		fg, has_fg, _, _ := style.highlight_colors(the_app.spaint.styled, the_app.spaint.doc, h.it.node, name)
		if has_fg { text_again(h.l, h.dc, h.it, h.r, a, b, to_draw(fg)) }
	})
}

// The painter, after item `it`: selected text again in the highlight text color; selected images and controls tinted.
selection_paint_over :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	if the_app.spaint.highlights != nil && it.kind == .Text { highlights_paint_over(l, dc, it, r) }
	if !the_app.spaint.on { return }
	#partial switch it.kind {
	case .Text:
		idx := item_index(l, it)
		if idx < 0 { return }
		a, b, ok := lay.item_range(l, the_app.spaint.doc, idx, the_app.spaint.start, the_app.spaint.end)
		if !ok || !lay.is_selectable(the_app.spaint.doc, the_app.spaint.styled, it.node) { return }
		_, fg, keep := colors_for(it.node)
		if keep { return }
		text_again(l, dc, it, r, a, b, fg)
	case .Replaced, .Control:
		if it.node == base.NIL_HANDLE || !lay.node_in_range(the_app.spaint.doc, it.node, the_app.spaint.start, the_app.spaint.end) { return }
		bg, _, _ := colors_for(it.node)
		bg.a *= 0.5
		draw.rect(dc, r, bg)
	}
}

// The painter's text run (render.odin draw_run): the fragment shaped as painted (one directional run, spacing and
// justification in the shaper), so the selected glyphs land exactly on the ones drawn under them.
sel_draw_run :: proc(dc: ^draw.Context, fid: font.Font_Id, size: f32, pos: draw.Vec2, col: draw.Color, text: string, opts: font.Shape_Options) {
	sh := font.shape(dc.fonts, fid, size, text, opts, context.temp_allocator)
	draw.glyph_run(dc, size, pos, col, sh.glyphs)
}

_ :: css
_ :: fmt

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
import "core:slice"
import "core:strings"
import "core:time"
import "toolkit:draw"
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

// The longest step of a drag's automatic scrolling: the frames may have stopped for much longer.
@(private = "file") AUTOSCROLL_MAX_STEP_S :: 0.1

// A text selection gesture (Pointer_Gesture.sel: the payload of Press_Pending and Selecting).
Selection_Gesture :: struct {
	unit:        Sel_Unit,
	press_pos:   [2]f32,              // window pixels
	moved:       bool,                // past the drag threshold
	origin:      [2]lay.Text_Pos,     // the unit first selected (word / paragraph drags keep it selected)
	started:     bool,                // selectstart was fired for this gesture and not cancelled
	mouse:       [2]f32,
	scroller:    base.Handle,         // what auto-scroll moves (NIL: the document)
	press:       platform.Event,      // Press_Pending: the press that had its turn, kept for a fresh layout (none yet: a chrome frame opened the gesture)
	selected_by_drag: bool,           // the gesture selected text: its release is not a click
	released:    bool,                // Press_Pending: its release came first: the press still has its effect, then the gesture is over
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
// A press under a long script waits with its moves, for as long as the script runs: the gesture is opened here too (`pressed`,
// selection_preview_press) where that press cannot run the page's code either and is sure to begin a selection. And past the
// view's edge the drag scrolls the document as a full frame does (selection_preview_frame), which the page takes at its turn.
Sel_Preview :: struct {
	on:            bool,
	pressed:       bool,   // the gesture was opened here, its press waits for the page: the owner is Press_Pending
	dragged:       bool,   // past the drag threshold: `moved` is not set yet
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

text_api :: proc(app: ^App) -> lay.Text_Api { return page_text_api(&app.page_render.fonts, &app.measure, &app.page_settings.style) }

// The text position under a window point (ok = false: no text, or a layout older than the document).
position_of :: proc(app: ^App, t: ^Tab, pos: [2]f32) -> (lay.Text_Pos, bool) { return position_scrolled(app, t, pos, t.scroll) }

// The same with the document at this offset.
@(private = "file")
position_scrolled :: proc(app: ^App, t: ^Tab, pos: [2]f32, scroll: f32) -> (lay.Text_Pos, bool) {
	if t.page == nil || !t.layout.valid { return {}, false }
	return lay.position_at(&t.layout, t.page.doc, t.page.styled, pos - active_window(app).page_rect.min, page_viewport(app), scroll, text_api(app))
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

// A left press in the page that no form control took (after mousedown, which `allowed` says was not cancelled): Page_Press it stays, or it
// selects, now or once the layout is as new as the document.
selection_pointer_down :: proc(app: ^App, t: ^Tab, ev: platform.Event, target: base.Handle, allowed: bool) {
	g := gesture_of(app)
	p := t.page
	if allowed && !(target != base.NIL_HANDLE && in_control(t, target)) && !layout_fresh(t) {
		g.owner, g.sel.press, g.sel.mouse = .Press_Pending, ev, ev.pos   // (what a chrome frame showed of the gesture stays until then)
		return
	}
	g.sel.preview = {}
	if !allowed { return }
	if target != base.NIL_HANDLE && in_control(t, target) { page.selection_clear(p); return }
	start_gesture(app, t, ev)
}

// Past the press: the gesture is Selecting, or nothing is to select and the press is the page's alone.
@(private = "file")
start_gesture :: proc(app: ^App, t: ^Tab, ev: platform.Event) {
	g := gesture_of(app)
	p := t.page
	shown := g.sel.preview
	g.sel = {press_pos = ev.pos, mouse = ev.pos, preview = shown}
	g.owner = .Page_Press
	pos, ok := position_of(app, t, ev.pos)
	when DEBUG_INPUT {
		n := dom.get(p.doc, pos.node)
		debug_log(fmt.tprintf("press %v page_rect %v scroll %v -> %v %q", ev.pos, active_window(app).page_rect, t.scroll, pos, n != nil ? n.text : ""))
	}
	if !ok { page.selection_clear(p); return }
	g.owner = .Selecting
	g.sel.scroller = scroller_of(t, pos.node)
	switch click_in_text(g.clicks.count) {
	case 2: g.sel.unit = .Word
	case 3: g.sel.unit = .Paragraph
	}
	if .Shift in ev.mods && p.selection.has {
		// extend from the anchor, by the unit of the gesture
		page.selection_extend(p, pos)
		g.sel.origin = {p.selection.anchor, p.selection.anchor}
		g.sel.started = true
		return
	}
	a, b, uok := unit_at(t, pos, g.sel.unit)
	if !uok { a, b = pos, pos }
	g.sel.origin = {a, b}
	if a == b {
		page.selection_collapse(p, a)   // nothing selected; the next drag starts here
		return
	}
	if !fire_selectstart(t, a) { refuse_gesture(g, p); return }
	if t.page != p { return }
	g.sel.started = true
	page.selection_set(p, a, b)
}

// selectstart was cancelled: this press selects nothing.
@(private = "file")
refuse_gesture :: proc(g: ^Pointer_Gesture, p: ^page.Page) {
	g.owner = .Page_Press
	page.selection_clear(p)
}

// Pointer moves while the button is held: the focus follows the pointer (by words / paragraphs after a double / triple click).
selection_pointer_move :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	g := gesture_of(app)
	g.sel.mouse = pos
	if g.owner != .Selecting { return }
	if !g.sel.moved {
		if !past_threshold(app, g.sel, pos) { return }
		g.sel.moved = true
	}
	extend_to(app, t, pos)
}

@(private = "file")
past_threshold :: proc(app: ^App, sel: Selection_Gesture, pos: [2]f32) -> bool {
	d := pos - sel.press_pos
	return d.x * d.x + d.y * d.y >= app.ix.drag_threshold_px * app.ix.drag_threshold_px * page_scale(app) * page_scale(app)
}

// The anchor and focus a gesture has with the pointer at `pos` (ok = false: no text there).
@(private = "file")
gesture_range :: proc(app: ^App, t: ^Tab, pos: [2]f32, scroll: f32) -> (anchor, focus: lay.Text_Pos, ok: bool) {
	g := gesture_of(app)
	tp := position_scrolled(app, t, pos, scroll) or_return
	a, b, uok := unit_at(t, tp, g.sel.unit)
	if !uok { a, b = tp, tp }
	o := g.sel.origin
	if lay.pos_compare(t.page.doc, a, o[0]) < 0 { return o[1], a, true }
	return o[0], b, true
}

@(private = "file")
extend_to :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	g := gesture_of(app)
	p := t.page
	if !layout_fresh(t) { g.sel.stale = true; return }
	g.sel.stale, g.sel.preview = false, {}
	anchor, focus, ok := gesture_range(app, t, pos, t.scroll)
	if !ok { return }
	if anchor != focus && !g.sel.started {
		if !fire_selectstart(t, anchor) { refuse_gesture(g, p); return }
		if t.page != p { return }
		g.sel.started = true
	}
	page.selection_set(p, anchor, focus)
	if anchor != focus { g.sel.selected_by_drag = true }
}

// A chrome frame (shell_frames.odin): the pointer moved to `pos` with the gesture's button held; the move itself waits for
// the page. What it will select is shown meanwhile (Sel_Preview), when that can be known without the page.
selection_preview_move :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	g := gesture_of(app)
	if !gesture_open(g, t) { return }
	g.sel.mouse = pos
	if !preview_possible(app, t) { return }
	if !g.sel.moved && !g.sel.preview.dragged {
		if !past_threshold(app, g.sel, pos) { return }
		g.sel.preview.dragged = true
	}
	preview_to(app, t, pos)
}

// A selection gesture is open on `t`: its press had its turn, or a chrome frame opened it. (A chrome frame comes before gesture_follow.)
@(private = "file")
gesture_open :: proc(g: ^Pointer_Gesture, t: ^Tab) -> bool { return (g.owner == .Selecting || g.owner == .Press_Pending && g.sel.preview.pressed) && t == g.tab && t.page == g.top }

// The preview, with the pointer at `pos` over the document as a chrome frame shows it.
@(private = "file")
preview_to :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	g := gesture_of(app)
	anchor, focus, ok := gesture_range(app, t, pos, shell_shown_scroll(t).y)
	if !ok { return }
	// (the gesture's first selection fires selectstart, which the page may cancel)
	if anchor != focus && !g.sel.started && page.page_listens(t.page, "selectstart") { return }
	g.sel.preview.on, g.sel.preview.anchor, g.sel.preview.focus = true, anchor, focus
}

// A chrome frame (shell_frames.odin): a left press over the page, which waits for the page as any press does, and nothing of the user's before it. The gesture it will
// begin is opened now, as start_gesture will, when its turn can be told from here: it runs none of the page's code, it is the first of a series (no word to find), it does
// not extend (Shift), and it is on text that will select: no form control, nothing draggable, not the selection itself. Else the gesture begins at the page's turn.
selection_preview_press :: proc(app: ^App, t: ^Tab, ev: platform.Event) {
	g := gesture_of(app)
	p := t.page
	if p == nil || ev.button != .Left || .Shift in ev.mods || !gesture_free(g) || !preview_possible(app, t) || click_next(app, g.clicks, ev) != 1 { return }
	if page.page_listens(p, "mousedown") || page.page_listens(p, "pointerdown") { return }
	target := lay.hit_test(&t.layout, ev.pos - active_window(app).page_rect.min, page_viewport(app), shell_shown_scroll(t).y).node
	if target != base.NIL_HANDLE {
		if _, drag := page.drag_source_for(p, target); drag != .None || in_control(t, target) { return }
	}
	pos, ok := position_scrolled(app, t, ev.pos, shell_shown_scroll(t).y)
	if !ok { return }
	if a, b, has := page.selection_range(p); has && lay.pos_compare(p.doc, a, pos) <= 0 && lay.pos_compare(p.doc, pos, b) < 0 { return }
	g = gesture_take(app, t, .Press_Pending, .Left)
	g.sel = {press_pos = ev.pos, mouse = ev.pos, origin = {pos, pos}, scroller = scroller_of(t, pos.node), preview = {on = true, pressed = true, anchor = pos, focus = pos}}
}

// The pointer is past the edge of the view a chrome frame scrolls, its button held: a frame is wanted though no input comes.
selection_preview_scrolls :: proc(app: ^App) -> bool {
	t := current_tab(app)
	g := gesture_of(app)
	if t == nil || t.page == nil || !gesture_open(g, t) || g.sel.scroller != base.NIL_HANDLE || autoscroll_velocity(app, g.sel.mouse, active_window(app).page_rect).y == 0 { return false }
	return preview_drags(app, t)
}

// A drag's selection can be shown in chrome frames.
@(private = "file")
preview_drags :: proc(app: ^App, t: ^Tab) -> bool {
	g := gesture_of(app)
	return gesture_open(g, t) && (g.sel.moved || g.sel.preview.dragged) && preview_possible(app, t)
}

// A chrome frame, its input taken: past the view's top or bottom the drag scrolls the document, at the speed of a full frame's selection_shell_frame (a box that scrolls
// waits for the page, and so does sideways: shell_layout_wanted), and what the pointer is over then is selected; so does what the wheel scrolled under it.
selection_preview_frame :: proc(app: ^App) {
	t := current_tab(app)
	g := gesture_of(app)
	if t == nil || t.page == nil || !preview_drags(app, t) { return }
	now := time.tick_now()
	dt := autoscroll_dt(g.last_tick, now)
	g.last_tick = now
	port := active_window(app).page_rect
	if v := autoscroll_velocity(app, g.sel.mouse, port); v.y != 0 && g.sel.scroller == base.NIL_HANDLE {
		shown := shell_shown_scroll(t)
		shell_async_scroll_to(app, t, {shown.x, shown.y + v.y * dt})
	}
	if app.chrome_frames.pending_tab == t.id && app.chrome_frames.pending_scroll != {} { preview_to(app, t, autoscroll_inside(g.sel.mouse, port)) }
}

// What is shown of the gesture in a chrome frame is its preview: the page's last frame painted again with it.
selection_preview_shown :: proc(app: ^App, t: ^Tab) -> bool {
	g := gesture_of(app)
	return g.sel.preview.on && t.page != nil && t.page == g.top && preview_possible(app, t)
}

// Its two ends are still in the document (the script that held the thread may have changed it).
@(private = "file")
preview_valid :: proc(p: ^page.Page, pv: Sel_Preview) -> bool {
	inside :: proc(p: ^page.Page, at: lay.Text_Pos) -> bool { return dom.get(p.doc, at.node) != nil && lay.in_document(p.doc, at.node) && at.offset <= lay.node_length(p.doc, at.node) }
	return inside(p, pv.anchor) && inside(p, pv.focus)
}

// The gesture's next selection can be worked out and painted from the layout of the page's last frame (shell_frames.odin
// shell_layout_paintable), the moves run none of the page's code, and the page was not moved sideways meanwhile: that offset is the layout's own, a chrome frame shows it
// from kept pixels. (The document's vertical offset is taken before the moves at the page's turn: they are hit-tested where the preview hit-tests them.)
@(private = "file")
preview_possible :: proc(app: ^App, t: ^Tab) -> bool {
	if !shell_layout_paintable(app, t) || !layout_fresh(t) { return false }
	if app.chrome_frames.pending_tab == t.id && app.chrome_frames.pending_scroll.x != 0 { return false }
	return !page.page_listens(t.page, "pointermove") && !page.page_listens(t.page, "mousemove")
}

// A frame's time for automatic scrolling: since the last one, at most AUTOSCROLL_MAX_STEP_S (the frames may have stopped).
@(private = "file")
autoscroll_dt :: proc(last, now: time.Tick) -> f32 { return f32(clamp(time.duration_seconds(time.tick_diff(last, now)), 0, AUTOSCROLL_MAX_STEP_S)) }

// How fast a drag scrolls with the pointer at `m` (window pixels) and `port` the view it scrolls, in pixels a second.
@(private = "file")
autoscroll_velocity :: proc(app: ^App, m: [2]f32, port: draw.Rect) -> [2]f32 {
	past :: proc(v, lo, hi: f32) -> f32 { return v < lo ? v - lo : (v > hi ? v - hi : 0) }
	d := [2]f32{past(m.x, port.min.x, port.max.x), past(m.y, port.min.y, port.max.y)}
	return [2]f32{clamp(d.x * app.ix.autoscroll_speed, -app.ix.autoscroll_max, app.ix.autoscroll_max), clamp(d.y * app.ix.autoscroll_speed, -app.ix.autoscroll_max, app.ix.autoscroll_max)} * page_scale(app)
}

// The pointer clamped into the view: what is scrolled in gets selected.
@(private = "file")
autoscroll_inside :: proc(m: [2]f32, port: draw.Rect) -> [2]f32 { return {clamp(m.x, port.min.x + 1, port.max.x - 1), clamp(m.y, port.min.y + 1, port.max.y - 1)} }

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
	g := gesture_of(app)
	now := time.tick_now()
	dt := autoscroll_dt(g.last_tick, now)
	g.last_tick = now
	t := current_tab(app)
	for tab in tabs_all(app) { if tab.page != nil { page.selection_flush(tab.page) } }
	gesture_follow(app)
	if t == nil || t.page == nil || t.kind != .Web { return }
	if g.owner == .Press_Pending && g.sel.press.kind == .Mouse_Press && layout_fresh(t) {
		// (the moves that came with the press found no gesture: it goes on from where they left the pointer)
		mouse, press, released := g.sel.mouse, g.sel.press, g.sel.released
		start_gesture(app, t, press)
		g.sel.mouse = mouse
		if released { gesture_end(g) }
		if g.owner == .Selecting && past_threshold(app, g.sel, mouse) {
			g.sel.moved = true
			extend_to(app, t, mouse)
		}
	}
	// the moves of this frame have had their turn: what a chrome frame showed of them is the selection now, but where the
	// layout was older than the document (the script changed it), which the next frame, laid out, extends to the pointer,
	// or where the gesture's press waits for that layout
	waits := g.owner == .Press_Pending
	if g.sel.stale && g.owner == .Selecting && g.sel.moved {
		extend_to(app, t, g.sel.mouse)
		waits = g.sel.stale
	}
	if waits { request_frames(app, 2) } else { g.sel.stale, g.sel.preview = false, {} }
	if g.owner != .Selecting || !g.sel.moved || app.ix.autoscroll_speed <= 0 { return }
	port := wnd.page_rect
	if g.sel.scroller != base.NIL_HANDLE {
		if r, ok := lay.box_of(&t.layout, g.sel.scroller, page_viewport(app), t.scroll); ok {
			off := wnd.page_rect.min - doc_scroll_vec(t)   // (document coordinates, position: fixed boxes included)
			port = draw.Rect{r.padding.min + off, r.padding.max + off}
			port = {{max(port.min.x, wnd.page_rect.min.x), max(port.min.y, wnd.page_rect.min.y)}, {min(port.max.x, wnd.page_rect.max.x), min(port.max.y, wnd.page_rect.max.y)}}
		}
	}
	speed := autoscroll_velocity(app, g.sel.mouse, port)
	if speed == {} { return }
	step := speed * dt
	moved := false
	if g.sel.scroller != base.NIL_HANDLE {
		if cur, ok := lay.scroll_of(&t.layout, g.sel.scroller); ok {
			got, _ := lay.set_scroll(&t.layout, g.sel.scroller, cur + step)
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
	// keep selecting under the pointer, clamped into the view
	extend_to(app, t, autoscroll_inside(g.sel.mouse, port))
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
	// (what the rules of highlights say: only in the style, not in what an item's record keeps)
	if st := the_app.spaint.styled; st != nil && (on || the_app.spaint.highlights != nil) { mix(&h, mem.ptr_to_bytes(&st.serial)) }
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
	if g := gesture_of(app); g.sel.preview.on && g.top == p && preview_valid(p, g.sel.preview) {
		// a drag's moves are waiting for the page: what they will select (Sel_Preview)
		a, b := g.sel.preview.anchor, g.sel.preview.focus
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

// The paint of the selection over the text of element `el`: its page's ::selection, else the browser's colors; those go together (CSS Pseudo 4 §3.3): a page's color alone
// has no background, a page's background alone leaves the text as it is.
@(private = "file")
selection_paint_of :: proc(el: base.Handle) -> (o: Text_Overlay) {
	sp := &the_app.spaint
	if sp.styled != nil { o.paint = style.highlight_paint(sp.styled, sp.doc, el, .Selection) }
	overlay_colors(&o)
	if !o.paint.declared_color && !o.paint.has_background {
		o.background = sp.bg
		if !sp.keep_fg { o.color, o.has_color = sp.fg, true }
	}
	return
}

// What the page says of an overlay's colors.
@(private = "file")
overlay_colors :: proc(o: ^Text_Overlay) {
	if o.paint.has_background { o.background = to_draw(o.paint.background) }
	if o.paint.has_color { o.color, o.has_color = to_draw(o.paint.color), true }
}

@(private = "file")
span_rect :: proc(l: ^Layout, it: ^lay.Display_Item, r: draw.Rect, a, b: int) -> draw.Rect {
	// caret positions through the shaped clusters: a right-to-left item has the start of the range on the right
	api := text_api(the_app)
	ca, cb := lay.item_caret_x(l, it, a, api), lay.item_caret_x(l, it, b, api)
	x0, x1 := min(ca, cb), max(ca, cb)
	if .Vertical in it.flags { return {{r.min.x, math.floor(r.min.y + x0)}, {r.max.x, math.ceil(r.min.y + x1)}} }
	return {{math.floor(r.min.x + x0), r.min.y}, {math.ceil(r.min.x + x1), r.max.y}}
}

// The painter, before item `it` (drawn at `r`, window pixels): the caret of text dragged here.
selection_paint_under :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	if it.kind != .Text || !the_app.spaint.has_drop { return }
	idx := item_index(l, it)
	if idx < 0 { return }
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

// The painter, after item `it`: selected images and controls under a wash of the selection's background, else its color (CSS Pseudo 4 §3.6.4).
selection_paint_over :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, r: draw.Rect) {
	if !the_app.spaint.on || (it.kind != .Replaced && it.kind != .Control) { return }
	if it.node == base.NIL_HANDLE || !lay.node_in_range(the_app.spaint.doc, it.node, the_app.spaint.start, the_app.spaint.end) { return }
	o := selection_paint_of(it.node)
	wash := o.background.a > 0 ? o.background : o.color
	wash.a *= 0.5
	draw.rect(dc, r, wash)
}

// A highlight over a part of a text item, from the lowest up: bytes [a, b), and `rect` that its background fills.
Text_Overlay :: struct {
	a, b:      int,
	rect:      draw.Rect,
	paint:     style.Highlight_Paint,
	background: draw.Color,
	color:     draw.Color,   // of its text: its own, or the one of the layers below (currentcolor)
	has_color: bool,
	selection: bool,
}

// The rectangle of the selection on `it`: past the end of this piece of text when the selection goes on, over the collapsed space after it (not drawn by any item) or the
// line's end, as browsers do.
@(private = "file")
selection_rect :: proc(tp: ^Text_Paint, idx, a, b: int) -> draw.Rect {
	l, it := tp.l, tp.it
	rect := span_rect(l, it, tp.r, a, b)
	if b == len(it.text) && !strings.has_suffix(it.text, " ") {
		if node, _, hi, ok := lay.item_source(l, the_app.spaint.doc, idx); ok && lay.pos_compare(the_app.spaint.doc, {node, hi}, the_app.spaint.end) < 0 {
			// after the logical end: on the left of a right-to-left item
			if .Vertical in it.flags {
				rect.max.y += math.ceil(tp.fi.space)
			} else if it.level & 1 == 1 { rect.min.x -= math.ceil(tp.fi.space) } else { rect.max.x += math.ceil(tp.fi.space) }
		}
	}
	return rect
}

// The highlights over the item, by their overlays (CSS Pseudo 4 §3.6): nil, most of the time.
selection_overlays :: proc(tp: ^Text_Paint) -> []Text_Overlay {
	sp := &the_app.spaint
	if !sp.on && sp.highlights == nil { return nil }
	l, it := tp.l, tp.it
	idx := item_index(l, it)
	if idx < 0 || sp.styled == nil { return nil }
	out: [dynamic]Text_Overlay
	if hl := sp.highlights; hl != nil {
		if node, _, _, ok := lay.item_source(l, sp.doc, idx); ok {
			if spans, has := hl.spans[node]; has {
				out = make([dynamic]Text_Overlay, 0, len(spans) + 1, context.temp_allocator)
				for s in spans {
					a, b, in_item := lay.item_range(l, sp.doc, idx, {node, s.lo}, {node, s.hi})
					if !in_item || a == b { continue }
					h := &hl.list[s.highlight]
					o := Text_Overlay{a = a, b = b, rect = span_rect(l, it, tp.r, a, b), paint = style.highlight_paint(sp.styled, sp.doc, it.node, h.kind, h.name)}
					overlay_colors(&o)
					if h.kind == .Target_Text && !o.paint.declared_color && !o.paint.has_background {
						o.color, o.has_color = to_draw(style.settings_color(&the_app.page_settings.style, .Mark_Text, it.cs.used_scheme)), true
						o.background = to_draw(style.settings_color(&the_app.page_settings.style, .Mark, it.cs.used_scheme))
					}
					append(&out, o)
				}
			}
		}
	}
	if sp.on {
		if a, b, ok := lay.item_range(l, sp.doc, idx, sp.start, sp.end); ok && lay.is_selectable(sp.doc, sp.styled, it.node) {
			if out == nil { out = make([dynamic]Text_Overlay, 0, 1, context.temp_allocator) }
			o := selection_paint_of(it.node)
			o.a, o.b, o.rect, o.selection = a, b, selection_rect(tp, idx, a, b), true
			append(&out, o)
		}
	}
	// (currentcolor: of the next layer below, where they overlap)
	for &o, i in out {
		if o.has_color { continue }
		o.color = to_draw(it.cs.color)
		for k := i - 1; k >= 0; k -= 1 {
			if out[k].has_color && out[k].a < o.b && o.a < out[k].b { o.color = out[k].color; break }
		}
	}
	return out[:]
}

// Their backgrounds, each with its text-shadow, then find's matches and the selection above them (§3.6.1, §3.6.2).
selection_paint_backgrounds :: proc(tp: ^Text_Paint, overlays: []Text_Overlay) {
	sp := &the_app.spaint
	find_painted := sp.find == nil
	find_matches :: proc(tp: ^Text_Paint) {
		if idx := item_index(tp.l, tp.it); idx >= 0 { find_paint_item(the_app.spaint.find, tp.l, tp.dc, tp.it, idx, tp.r) }
	}
	for &o in overlays {
		if o.selection && !find_painted { find_matches(tp); find_painted = true }
		if o.background.a > 0 { draw.rect(tp.dc, o.rect, o.background) }
		if len(o.paint.shadows) == 0 { continue }
		draw.push_clip(tp.dc, o.rect)
		for i := len(o.paint.shadows) - 1; i >= 0; i -= 1 {
			s := o.paint.shadows[i]
			if s.color.a <= 0 { continue }
			col := to_draw(s.color)
			if s.blur > 0 { col.a *= 0.6 }
			text_ink_draw(tp, draw.Vec2{s.x, s.y} * tp.l.scale, {fill = col})
		}
		draw.pop_clip(tp.dc)
	}
	if !find_painted { find_matches(tp) }
}

// A part of the item under the same highlights: how its text is drawn.
Text_Part :: struct {
	a, b:      int,
	clip:      draw.Rect,
	ink:       Text_Ink,
	emphasis:  draw.Color,
	line:      draw.Color,   // of the lines of the boxes that decorate it, where `recolored`
	recolored: bool,
}

// How far past the ends of the item its first and last parts go: glyphs and strokes that overhang are theirs.
@(private = "file") PART_OVERHANG_EMS :: 2

// The item cut where its highlights begin and end; nil: it is whole.
selection_text_parts :: proc(tp: ^Text_Paint, overlays: []Text_Overlay) -> []Text_Part {
	if len(overlays) == 0 { return nil }
	cuts := make([dynamic]int, 0, len(overlays) * 2 + 2, context.temp_allocator)
	append(&cuts, 0, len(tp.it.text))
	for o in overlays { append(&cuts, o.a, o.b) }
	slice.sort(cuts[:])
	parts := make([dynamic]Text_Part, 0, len(cuts), context.temp_allocator)
	api := text_api(the_app)
	at := tp.vertical ? tp.r.min.y : tp.r.min.x
	over := tp.fi.size * PART_OVERHANG_EMS
	base_ink := text_ink_of(tp.cs, tp.l.scale)
	base_emphasis := to_draw(style.emphasis_color(tp.cs))
	follows_color := tp.cs.text_stroke_color.auto
	for i in 1 ..< len(cuts) {
		a, b := cuts[i - 1], cuts[i]
		if a == b { continue }
		lo, hi := math.round(at + lay.item_caret_x(tp.l, tp.it, a, api)), math.round(at + lay.item_caret_x(tp.l, tp.it, b, api))
		rtl := lo > hi
		if rtl { lo, hi = hi, lo }
		if a == 0 { if rtl { hi += over } else { lo -= over } }
		if b == len(tp.it.text) { if rtl { lo -= over } else { hi += over } }
		p := Text_Part{a = a, b = b, ink = base_ink, emphasis = base_emphasis}
		p.clip = tp.vertical ? draw.Rect{{tp.r.min.x - over, lo}, {tp.r.max.x + over, hi}} : draw.Rect{{lo, tp.r.min.y - over}, {hi, tp.r.max.y + over}}
		for &o in overlays {
			if o.a > a || o.b < b { continue }
			hp := &o.paint
			if o.has_color {
				p.ink.fill = o.color
				p.line, p.recolored = o.color, true
				if follows_color { p.ink.stroke = o.color }
				if tp.cs.text_emphasis_color.auto { p.emphasis = o.color }
			}
			if hp.has_line_color { p.line, p.recolored = to_draw(hp.line_color), true }
			if hp.has_fill { p.ink.fill = to_draw(hp.fill) }
			if hp.has_stroke { p.ink.stroke = to_draw(hp.stroke) }
			if hp.has_stroke_width { p.ink.width = hp.stroke_width * tp.l.scale }
		}
		append(&parts, p)
	}
	return parts[:]
}

// The lines of kind `line`: of the boxes that decorate the item, in the color of what is over them, then of each highlight, in the order of its layer (§3.6.3).
selection_paint_lines :: proc(tp: ^Text_Paint, lines: []Deco_Line, parts: []Text_Part, overlays: []Text_Overlay, line: style.Decoration) {
	if len(parts) == 0 {
		for &d in lines { deco_paint(tp, &d, line) }
		return
	}
	if len(lines) > 0 {
		for &p in parts {
			draw.push_clip(tp.dc, p.clip)
			for &d in lines { deco_paint(tp, &d, line, {}, p.recolored ? &p.line : nil) }
			draw.pop_clip(tp.dc)
		}
	}
	for &o in overlays {
		if o.paint.lines == {} { continue }
		lo, hi := tp.vertical ? o.rect.min.y : o.rect.min.x, tp.vertical ? o.rect.max.y : o.rect.max.x
		d := deco_line_of_highlight(tp, &o.paint, lo, hi, o.color)
		deco_paint(tp, &d, line)
	}
}

// The glyphs and their emphasis marks, each part as what is over it says.
selection_paint_text :: proc(tp: ^Text_Paint, parts: []Text_Part, emphasis: bool) {
	if len(parts) == 0 {
		text_ink_draw(tp, {}, text_ink_of(tp.cs, tp.l.scale))
		if emphasis { emphasis_paint(tp, 0, len(tp.it.text), {}, to_draw(style.emphasis_color(tp.cs))) }
		return
	}
	for &p in parts {
		draw.push_clip(tp.dc, p.clip)
		text_ink_draw(tp, {}, p.ink)
		draw.pop_clip(tp.dc)
		if emphasis { emphasis_paint(tp, p.a, p.b, {}, p.emphasis) }
	}
}

_ :: css
_ :: fmt

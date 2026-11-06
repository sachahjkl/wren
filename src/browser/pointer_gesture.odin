package browser

// Who owns the pressed button of a window: one gesture, one owner. The press decides the owner once (route_page_input), its moves and
// its release go to that owner wherever the pointer is, and each kind of gesture lives in its own file:
//
//   Idle ── a left press on the document ── Page_Press ──┬── Press_Pending ── Selecting ──┐
//     │                                                  ├── Selecting ───────────────────┤
//     │                                                  └── Drag_Candidate ── Page_Drag ─┼── the release ── Idle
//     ├── a press on a scroll bar ── Thumb, Arrow ────────────────────────────────────────┤
//     ├── a press in a frame ── Frame ────────────────────────────────────────────────────┤
//     └── a middle press ── Autoscroll (a tap latches it: no button held) ────────────────┘
//
// A gesture belongs to a tab and to the document the tab shows. When the window shows something else, or the document closes, it is over
// through one transition (gesture_cancel: what it left on the page goes, a drag is cancelled); what is left of it is Spent: its release
// is nobody's. A gesture's data is its owner's payload: it is gone with it.

import "core:time"
import "toolkit:platform"
import "wb:base"
import "wb:page"

Pointer_Owner :: enum u8 {
	Idle,
	Spent,            // nothing more comes of this press (cancelled, or on a scroll bar's track): its release is nobody's
	Page_Press,       // the document had the press and took it for nothing but a click; its form control may follow the pointer (`field`)
	Press_Pending,    // a press that selects, waiting for its turn (a chrome frame opened it) or for a layout as new as the document (`sel`)
	Selecting,        // text follows the pointer (selection_shell.odin, `sel`)
	Drag_Candidate,   // a press that may become a drag (dnd_shell.odin, `candidate`)
	Page_Drag,        // a drag from the page, in the window or the system's (dnd_shell.odin, `drag`)
	Thumb,            // a scroll bar's thumb (smooth_scroll.odin, `thumb`)
	Arrow,            // a classic bar's arrow, repeating (smooth_scroll.odin, `arrow`)
	Autoscroll,       // a middle-click autoscroll session (page_autoscroll.odin, `autoscroll`)
	Frame,            // a press in a frame's document (frames_shell.odin, `frame`)
}

// Window_Own.gesture.
Pointer_Gesture :: struct {
	owner:      Pointer_Owner,
	tab:        ^Tab,                    // whose gesture it is
	top:        ^page.Page,              // the document that tab showed
	doc:        ^page.Page,              // the document the press went to: `top`, or a frame's, watched while the gesture lasts (nil: nothing of the gesture is in a document)
	watch:      base.Cleanup_Id,
	button:     platform.Mouse_Button,
	target:     base.Handle,             // what a left press hit: a click is at this element or above
	// the owners'
	sel:        Selection_Gesture,
	field:      Field_Press,
	candidate:  Drag_Candidate,
	drag:       Page_Drag,
	thumb:      Scrollbar_Drag,
	arrow:      Arrow_Hold,
	autoscroll: Page_Autoscroll,
	frame:      ^page.Page,
	// the window's, gesture or not
	held:       platform.Mouse_Buttons,  // buttons whose press went to the page, in a chrome frame or a full one (their moves and release follow)
	clicks:     Click_Series,
	last_tick:  time.Tick,               // the last frame that could scroll a drag (selection_shell.odin)
}

// A left press that ended (gesture_release): what the page does with its release.
Ended_Press :: struct {
	target:  base.Handle,
	field:   Field_Press,
	dragged: bool,         // it selected text by dragging: its release is not a click
}

// Presses of the left button on the document, close in time and place. Text takes them three at a time (CLICKS_IN_TEXT).
Click_Series :: struct {
	count: int,
	last:  time.Tick,
	pos:   [2]f32,
}

// A series of clicks goes on within this many pixels of the last one (CSS px).
@(private = "file") CLICK_SLOP_PX :: 4
// In text a fourth click starts over: char, word, paragraph.
@(private = "file") CLICKS_IN_TEXT :: 3

gesture_of :: proc(app: ^App) -> ^Pointer_Gesture { return &window_own(app).gesture }

// No owner: a press may take the pointer.
gesture_free :: proc(g: ^Pointer_Gesture) -> bool { return g.owner == .Idle || g.owner == .Spent }

// When the user pressed: the event's time, not its turn's: on a busy page two quick clicks wait, and came together or far apart.
press_time :: proc(ev: platform.Event) -> time.Tick { return ev.stamp != {} ? ev.stamp : time.tick_now() }

// Which press of a series `ev` would be.
click_next :: proc(app: ^App, c: Click_Series, ev: platform.Event) -> int {
	scale := page_scale(app)
	near := abs(ev.pos.x - c.pos.x) < CLICK_SLOP_PX * scale && abs(ev.pos.y - c.pos.y) < CLICK_SLOP_PX * scale
	return near && time.duration_milliseconds(time.tick_diff(c.last, press_time(ev))) <= double_click_ms(app) ? c.count + 1 : 1
}

// Which click it is for text: the first, the second (a word) or the third (a paragraph).
click_in_text :: proc(count: int) -> int { return (count - 1) % CLICKS_IN_TEXT + 1 }

// The next press starts a series of its own.
click_forget :: proc(g: ^Pointer_Gesture) { g.clicks = {} }

// Whatever a gesture holds, dropped: the window's own data stays.
@(private = "file")
gesture_reset :: proc(g: ^Pointer_Gesture) {
	if g.doc != nil { base.forget_cleanup(g.doc.scope, g.watch) }
	delete(g.candidate.text)
	held, clicks, last_tick := g.held, g.clicks, g.last_tick
	g^ = {held = held, clicks = clicks, last_tick = last_tick}
}

// `owner` takes the pointer on tab `t`, in the place of nothing or of a spent press. No document is touched: a chrome frame may do it.
gesture_take :: proc(app: ^App, t: ^Tab, owner: Pointer_Owner, button: platform.Mouse_Button) -> ^Pointer_Gesture {
	g := gesture_of(app)
	gesture_reset(g)
	g.owner, g.tab, g.top, g.button = owner, t, t.page, button
	return g
}

// A press reaches document `doc` of tab `t` (a frame's, for owner .Frame). It counts in the series whatever then takes it: the third click of
// a triple click lands on the word the second one selected, which is also how a drag of the selection begins. What a chrome frame showed
// of the gesture stays until its turn is over (selection_shell_frame).
gesture_press :: proc(app: ^App, t: ^Tab, doc: ^page.Page, owner: Pointer_Owner, ev: platform.Event) {
	g := gesture_of(app)
	shown := g.sel.preview
	gesture_take(app, t, owner, ev.button)
	g.sel.preview = shown
	g.doc = doc
	g.watch = base.on_close(doc.scope, gesture_doc_closed, window_own(app))
	if ev.button == .Left { g.clicks = {click_next(app, g.clicks, ev), press_time(ev), ev.pos} }
}

// The gesture is over, its button up.
gesture_end :: proc(g: ^Pointer_Gesture) { gesture_reset(g) }

// The gesture is over, its button still down.
gesture_spend :: proc(g: ^Pointer_Gesture) {
	button := g.button
	gesture_reset(g)
	g.owner, g.button = .Spent, button
}

// The one way out of a gesture that does not end with its release: what it left in its document goes.
gesture_cancel :: proc(app: ^App) {
	g := gesture_of(app)
	owner, doc := g.owner, g.doc
	latched := owner == .Autoscroll && !(g.autoscroll.auto.phase == .Holding)
	gesture_spend(g)
	if latched { gesture_end(g) }
	#partial switch owner {
	case .Thumb, .Arrow: bar_over_set(app, {})
	case .Page_Drag: dnd_drag_cancelled(app, doc)
	}
	if doc != nil { page_set_active(doc, base.NIL_HANDLE) }
}

// A document under a gesture closed: nothing of it can be touched. (`data`: the Window_Own.)
@(private = "file")
gesture_doc_closed :: proc(data: rawptr) {
	own := (^Window_Own)(data)
	g := &own.gesture
	if g.owner == .Page_Drag { dnd_image_forget(own) }
	g.doc = nil
	gesture_spend(g)
}

// The window closes.
gesture_destroy :: proc(app: ^App, own: ^Window_Own) {
	dnd_image_forget(own)
	gesture_reset(&own.gesture)
}

// The gesture belongs to what the window shows, or it is over: a tab switch, a navigation, a tab gone. Looked at wherever a gesture acts.
gesture_follow :: proc(app: ^App) {
	g := gesture_of(app)
	if gesture_free(g) { return }
	if t := current_tab(app); t != g.tab || t.page != g.top || t.kind != .Web { gesture_cancel(app) }
}

// The gesture's press has not had its turn: what comes before it in the queue is older than the gesture.
@(private = "file")
press_waits_turn :: proc(g: ^Pointer_Gesture) -> bool { return g.owner == .Press_Pending && g.sel.press.kind != .Mouse_Press }

// A pointer event of a full frame, before anyone looks at it: which buttons are the page's now, and whether the gesture lost its release:
// its button is up (a move says which are down), or it comes down again. A thumb is left out: it can begin in a chrome frame ahead of the
// moves still waiting in the queue, which were made with no button. A latched autoscroll holds none. What the window was doing ends with a
// press on its frame, and the gesture of a button whose release the system made: the system has the pointer now, no click comes of it.
gesture_note :: proc(app: ^App, ev: platform.Event, inside: bool) {
	g := gesture_of(app)
	#partial switch ev.kind {
	case .Mouse_Press:
		if inside { g.held += {ev.button} } else { g.held -= {ev.button} }
	case .Mouse_Release:
		g.held -= {ev.button}
		if ev.lost && ev.button == g.button && !gesture_free(g) { gesture_cancel(app) }
	case .Frame_Press:
		if !gesture_free(g) { gesture_cancel(app) }
		return
	case .Mouse_Move:
	case:
		return
	}
	if press_waits_turn(g) {
		if ev.kind == .Mouse_Press && ev.button == g.button { g.owner = .Idle }   // here it is: it decides, what was shown of it stays until then
		return
	}
	if g.owner == .Idle || g.owner == .Autoscroll || (g.owner == .Press_Pending && g.sel.released && ev.kind == .Mouse_Move) { return }
	up := ev.kind == .Mouse_Move && g.button not_in ev.buttons && g.owner != .Thumb
	if !up && !(ev.kind == .Mouse_Press && ev.button == g.button) { return }
	if g.owner != .Spent { gesture_cancel(app) }
	gesture_end(g)
}

// Mouse_Release of a press the page holds: over, and what it leaves to the release (nothing for a button that is not the gesture's).
gesture_release :: proc(app: ^App, ev: platform.Event) -> (ended: Ended_Press) {
	g := gesture_of(app)
	if ev.button != g.button { return }
	#partial switch g.owner {
	case .Page_Press, .Press_Pending, .Selecting, .Drag_Candidate, .Frame:
		ended = {g.target, g.field, g.owner == .Selecting && g.sel.selected_by_drag}
		page_set_active(g.doc, base.NIL_HANDLE)
		// (a press waiting for a layout is a click all the same: selection_shell_frame gives it its effect, then ends it)
		if g.owner == .Press_Pending && g.sel.press.kind == .Mouse_Press { g.sel.released = true } else { gesture_end(g) }
	}
	return
}

// A spent press: its release is nobody's.
gesture_spent_event :: proc(g: ^Pointer_Gesture, ev: platform.Event) -> bool {
	if ev.kind != .Mouse_Release || ev.button != g.button { return false }
	gesture_end(g)
	return true
}

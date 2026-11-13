package browser

// Who has a window's keyboard: one owner, moved by keyboard_to.
//
//   Page          the tab's document (its keys, its form controls)
//   Frame         a frame's document (Keyboard.frame), the last press went into it
//   Chrome_Field  the address field
//   Chrome_Lent   a widget of the chrome holds it for the document that had it (Ctrl+F from the page): when the widget lets go the document has it again
//   Chrome        the chrome, a widget of its own or none: the keys are its shortcuts
//
// What moves it: a press (forms_route_event, frames_route_pointer, and shell_route when a chrome frame takes it: keyboard_press), a document that comes to the window
// (keyboard_document), the chrome's Tab order and commands (keyboard_take), and the toolkit's own focus, which clicks, Tab and menus move inside a build:
// keyboard_follow sees it change. A press on the page may be owned before the toolkit saw it (a chrome frame leaves it for the page's turn): the owner says Page while
// the field's focus is still there, which is why the follow goes by what changed, not by what is.

import "toolkit:ui"
import "wb:page"

Keyboard_Owner :: enum u8 { Chrome, Chrome_Field, Chrome_Lent, Page, Frame }

Frame_Document :: ^page.Page   // (the name for a struct with a field `page`: Tab)

Keyboard :: struct {
	owner: Keyboard_Owner,
	frame: ^page.Page,   // Frame, and Chrome_Lent from a frame: that document
	seen:  ui.Key,       // the toolkit's focus when keyboard_follow last looked
}

keyboard_of :: proc(app: ^App) -> ^Keyboard { return &window_own(app).keyboard }

// The one transition.
keyboard_to :: proc(k: ^Keyboard, to: Keyboard_Owner, frame: ^page.Page = nil) {
	k.owner = to
	k.frame = to == .Frame || to == .Chrome_Lent ? frame : nil
}

// The toolkit's focus moved: what that makes of the owner.
keyboard_follow :: proc(app: ^App) {
	k := keyboard_of(app)
	now := ui.focus_key()
	if now == k.seen { return }
	k.seen = now
	switch {
	case now != 0 && now == address_key(app):
		keyboard_to(k, .Chrome_Field)
	case now != 0:
		page_side := k.owner == .Page || k.owner == .Frame || k.owner == .Chrome_Lent
		keyboard_to(k, page_side ? .Chrome_Lent : .Chrome, k.frame)
	case k.owner == .Chrome_Lent:
		keyboard_to(k, k.frame != nil ? .Frame : .Page, k.frame)
	case k.owner == .Chrome_Field:
		keyboard_to(k, .Chrome)
	}
}

// Who has it now.
keyboard_owner :: proc(app: ^App) -> Keyboard_Owner {
	keyboard_follow(app)
	return keyboard_of(app).owner
}

// It goes to `to` from where it is now (what the toolkit did so far came first, it must not pass for a change after this).
keyboard_move :: proc(app: ^App, to: Keyboard_Owner, frame: ^page.Page = nil) {
	keyboard_follow(app)
	keyboard_to(keyboard_of(app), to, frame)
}

// The chrome hands it to a document: the toolkit's focus goes.
keyboard_take :: proc(app: ^App, to := Keyboard_Owner.Page, frame: ^page.Page = nil) {
	ui.set_focus(0)
	keyboard_move(app, to, frame)
}

// A press a chrome frame sorts out, before the page's turn: the keys after it follow it. (A press that closes a menu gives nothing.)
keyboard_press :: proc(app: ^App, over_page: bool) {
	if !ui.menu_any_open() { keyboard_move(app, over_page ? .Page : .Chrome) }
}

// A document came to the window (a load, the tab `t` shown): it has the keyboard, or gets it when the chrome's widget lets go. The address field keeps it:
// a home page that arrives under Ctrl+T, a page under what is being typed. A frame's document that had it stays its tab's: the keyboard goes back there with the tab.
keyboard_document :: proc(app: ^App, t: ^Tab) {
	k := keyboard_of(app)
	owner := keyboard_owner(app)
	if fv := frame_view_of(k.frame); fv != nil && fv.host != nil && fv.host != t { fv.host.keyboard_frame = k.frame }
	back := t.keyboard_frame
	t.keyboard_frame = nil
	if fv := frame_view_of(back); fv == nil || fv.host != t { back = nil }
	to := back != nil ? Keyboard_Owner.Frame : .Page
	switch owner {
	case .Chrome_Field:
	case .Chrome, .Chrome_Lent: keyboard_to(k, ui.focus_key() != 0 ? .Chrome_Lent : to, back)
	case .Page, .Frame:         keyboard_to(k, to, back)
	}
}

// A widget that takes the keyboard for good: no document gets it back when it lets go.
keyboard_leave_page :: proc(app: ^App) {
	if keyboard_owner(app) != .Chrome_Field { keyboard_to(keyboard_of(app), .Chrome) }
}

// A frame's document is gone.
keyboard_frame_closed :: proc(k: ^Keyboard, p: ^page.Page) {
	if k.frame == p { keyboard_to(k, k.owner == .Frame ? .Page : k.owner) }
}

// The keys are the page's now. A toolkit dialog (ui.modal: the Vault's login, a confirmation) holds them while it is
// open: the page reads its keys before the dialogs are built, and Tab or Enter typed in the dialog must not reach it.
page_has_keyboard :: proc(app: ^App) -> bool {
	o := keyboard_owner(app)
	return (o == .Page || o == .Frame) && !ui.menu_any_open() && !ui.dialog_open() && !setup_captures(app)
}

// The page's focus is a focus (its caret, its ring): the keyboard is there, or a widget has it from there.
page_shows_focus :: proc(app: ^App) -> bool {
	o := keyboard_of(app).owner
	return o == .Page || o == .Frame || o == .Chrome_Lent
}

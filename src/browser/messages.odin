package browser

// What the browser says of an act it finished (Copied, Saved, Deleted, Imported): ui.announce, where the person's
// general.messages says (the system's notifications, the window's toasts, or nowhere; a failure is always said). The
// state of a load or a check that goes on stays a toast or a line where it is shown.

import prefs_page "toolkit:prefs_page"
import "toolkit:ui"

// Says `title` (and `body`: a path, an address) in the active window, or as the system's notification.
announce :: proc(app: ^App, kind: ui.Toast_Kind, title: string, body := "") {
	w := active_window(app)
	a := &app.announcer
	a.mode = prefs_page.messages_mode(&app.prefs)
	// (the window in front: its toasts when the system shows none, also for a task's answer said between two builds)
	a.window, a.state = w.win, w.ui
	ui.announce(a, kind, title, body)
}

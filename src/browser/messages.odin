package browser

// What the browser says (Copied, Saved, a failure, an update found): ui.announce, the toolkit's one way to say something,
// where the person's general.messages says (the system's notifications, the window's toasts, or nowhere; a failure is
// always said).

import prefs_page "toolkit:prefs_page"
import "toolkit:ui"

// Says `title` (and `body`: a path, an address) in the active window, or as the system's notification.
// `in_window`: a hint about the window itself (press Esc to leave full screen; click the shield): in it, whatever the
// Messages setting.
announce :: proc(app: ^App, kind: ui.Toast_Kind, title: string, body := "", in_window := false) {
	w := active_window(app)
	a := &app.announcer
	a.mode = prefs_page.announce_mode(&app.prefs)
	// (the window in front: its toasts when the system shows none, also for a task's answer said between two builds)
	a.window, a.state = w.win, w.ui
	ui.announce(a, kind, title, body, in_window = in_window)
}

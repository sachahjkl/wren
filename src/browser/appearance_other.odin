#+build !windows
package browser

import "toolkit:platform"
import "wb:style"

// Off Windows the desktop's look comes from the toolkit's neutral light/dark preference (the XDG Settings portal, else
// the GTK settings): the apps theme is known, the accent and selection colors are left unknown so pages fall back to
// the browser's own palette (a later chantier when the platform layer reports them). watch_color_scheme fires the UI
// restyle when the scheme changes live. appearance_windows.odin is the Windows counterpart; appearance.odin shares the
// read-once-and-restyle logic.

@(private = "file") watch_app: ^App

read_os_appearance :: proc() -> style.Os_Appearance {
	a := style.Os_Appearance{known = true}
	when ODIN_OS == .Linux {
		a.dark = platform.dark_mode_preferred()
	}
	// accent and highlight are not reported by the platform layer here: has_accent / has_highlight stay false, so
	// page.color.accent `system` and the selection colors use the browser's defaults.
	return a
}

appearance_watch_start :: proc(app: ^App) {
	watch_app = app
	when ODIN_OS == .Linux {
		// the callback runs on the UI thread's bus pump (the toolkit folds the portal socket into the window loop), so
		// it posts the restyle the same way the Windows watch thread does.
		platform.watch_color_scheme(proc(dark: bool) { appearance_post(watch_app) })
	}
}

appearance_watch_stop :: proc() {
	watch_app = nil
}

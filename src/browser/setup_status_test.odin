package browser

import "core:testing"

// The dialog reads the disk again whenever the system says the integration changed: a read alone leaves the status
// line as it was ("Working…" blinked over it at each read); installing or uninstalling shows it.
@(test)
setup_status_working_only_while_acting :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.stp.known = true
	f := Setup_Facts{kind = .Not_Installed, running_exe = "C:\\w\\wren.exe"}
	at_rest, _ := status_text(app, &f)
	app.stp.busy = 1
	reading, _ := status_text(app, &f)
	testing.expect_value(t, reading, at_rest)
	app.stp.acting = 1
	acting, _ := status_text(app, &f)
	testing.expect_value(t, acting, "Working\u2026")
}

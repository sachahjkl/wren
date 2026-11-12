package browser

// SIGTERM (a session that logs out, the system that shuts down, `kill`), SIGINT and SIGHUP end the browser as closing its
// last window does: its session saved, its recovery marker gone. By default they killed the process on the spot: the next
// start read a session that ended without a word as a crash ("Wren closed unexpectedly").

import "core:sync"
import "core:sys/posix"
import "toolkit:platform"
import "wb:base"

end_signal_install :: proc(app: ^App) {
	act: posix.sigaction_t
	act.sa_handler = proc "c" (sig: posix.Signal) {
		// (a signal handler: an atomic store and the wake's one write to an eventfd, nothing that locks or allocates)
		app := the_app
		if app == nil { return }
		sync.atomic_store(&app.end_signal, 1)
		context = base.process_context()
		if w := (^platform.Window)(sync.atomic_load(&app.wake_target)); w != nil { platform.wake(w) }
	}
	for s in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) { posix.sigaction(s, &act, nil) }
}

// The loop's turn: a signal came, the browser ends (once).
end_signal_check :: proc(app: ^App) {
	if sync.atomic_load(&app.end_signal) == 0 || app.quitting { return }
	control_close(app, 0)
}

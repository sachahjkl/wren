package browser

// Wren's log: what core:log is told (log.info, log.warn, log.error) goes to <profile>/logs/wren.log through the toolkit's gt:log,
// written by a thread of its own; a dev build says each line on standard error too, as Wren did before it had a log. The file is
// rotated past 1 MiB (wren.log.1 ... .3). The log is the process's, like the crash handler: the first App that starts installs it
// with its profile (several Apps run in one process in the end-to-end tests), base.process_context hands it to every thread and
// callback, the crash reports show its last lines, and the program's main closes it after the last App.
//
// The profile is the user's one even in a private Wren: its own profile is a temporary folder, removed at its end (the log open in
// it would keep the folder on Windows, and what it said would go with it).

import "base:runtime"
import "core:path/filepath"
import "core:sync"
import "wb:base"
import tk_log "toolkit:log"

@(private = "file") program_log_lock: sync.Mutex

// The process's log, installed by the first call with `profile_dir`'s logs folder; later calls give the same one. false: none (a
// test: its Apps run in one process with a profile each, removed after it, which a log open in the first one's would keep on
// Windows; the test runner's own logger stays).
program_log_install :: proc(profile_dir: string) -> (runtime.Logger, bool) {
	// (`if`, not `when`: the test build checks the code below too)
	if ODIN_TEST { return {}, false }
	sync.mutex_lock(&program_log_lock)
	defer sync.mutex_unlock(&program_log_lock)
	if logger, ok := base.process_logger(); ok { return logger, true }
	dir, _ := filepath.join({profile_dir, "logs"}, context.temp_allocator)
	// (permanent: the leak report of a check build runs before the main closes it)
	logger := tk_log.install({program = APP_NAME, dir = dir, echo = IS_DEV_BUILD}, base.permanent_allocator())
	base.process_logger_set(logger)
	return logger, true
}

// What was logged is in the file: before the process ends without the main's end (os.exit, the watchdog's forced exit).
program_log_flush :: proc "contextless" () {
	if logger, ok := base.process_logger(); ok {
		context = base.process_context()
		tk_log.flush(logger)
	}
}

// The end of the log, after the last line: the contexts made from now on drop their lines. The caller's context.logger must not be
// the log any more (its own logger goes with it).
program_log_close :: proc() {
	sync.mutex_lock(&program_log_lock)
	defer sync.mutex_unlock(&program_log_lock)
	logger, ok := base.process_logger()
	if !ok { return }
	base.process_logger_clear()
	tk_log.close(logger)
}

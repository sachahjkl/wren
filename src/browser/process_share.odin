package browser

import "core:sync"
import "wb:host"
import "wb:page"
import "wb:wasm"
import "wb:tools/crashtrace"

// What the Apps of a process share (docs/architecture.md, Where state lives): the Wasm engine and its host functions, the bytecode cache,
// the image decoders, the layout threads, the decoded web fonts (page.process_shutdown), the crash session. The first App to start sets it
// up, with its preferences and profile; the last to end lets it go. An App that starts or ends while another sets it up or lets it go
// waits for that. One atomic word, its states:
//   0                 off
//   PROCESS_BUSY      the first App sets it up, or the last lets it go (only that App touches it)
//   n (1 ..)          on, n Apps use it
// off --first start--> busy --> 1 --start--> n + 1 ... n --end--> n - 1 ... 1 --last end--> busy --> off
PROCESS_BUSY :: sync.Futex(1) << 31

Process_Share :: struct {
	word: sync.Futex,   // the Apps that use it, or PROCESS_BUSY
}

// (the process's: one whatever the number of Apps)
@(private = "file")
process_share: Process_Share

// The App uses what the process shares, set up first when it is the first: false when that failed (the App does not use it then).
process_share_join :: proc(app: ^App) -> bool {
	w := &process_share.word
	for {
		v := sync.atomic_load(w)
		switch {
		case v & PROCESS_BUSY != 0:
			sync.futex_wait(w, u32(v))   // (until the App that sets it up or lets it go is done)
		case v == 0:
			if _, won := sync.atomic_compare_exchange_strong(w, 0, sync.Futex(PROCESS_BUSY)); !won { continue }
			ok := process_setup(app)
			sync.atomic_store(w, ok ? 1 : 0)
			sync.futex_broadcast(w)
			return ok
		case:
			if _, won := sync.atomic_compare_exchange_strong(w, v, v + 1); won { return true }
		}
	}
}

// The App no longer uses what the process shares (every page of it is closed): let go of it when it was the last.
process_share_leave :: proc() {
	w := &process_share.word
	for {
		v := sync.atomic_load(w)
		assert(v != 0 && v & PROCESS_BUSY == 0, "process_share_leave by an App that did not join")
		if v == 1 {
			if _, won := sync.atomic_compare_exchange_strong(w, 1, sync.Futex(PROCESS_BUSY)); !won { continue }
			process_teardown()
			sync.atomic_store(w, 0)
			sync.futex_broadcast(w)
			return
		}
		if _, won := sync.atomic_compare_exchange_strong(w, v, v - 1); won { return }
	}
}

// How many Apps use what the process shares (tests).
process_share_users :: proc() -> int {
	v := sync.atomic_load(&process_share.word)
	return v & PROCESS_BUSY != 0 ? 0 : int(v)
}

@(private = "file")
process_setup :: proc(app: ^App) -> bool {
	crashtrace.begin_session()   // (a session that ended without a report: crashes\unclean exit <date>.txt at this start)
	host.shutdown_on_force = crashtrace.end_session   // (shutdown.log says what a watchdog ended, and the profile was saved first: no crash)
	rs := wasm.runtime_settings_from_prefs(&app.prefs, app.cfg.persist_profile ? app.profile_dir : "")   // nothing on disk without a kept profile
	wasm.configure(rs)
	wasm.runtime_settings_destroy(&rs)
	if !page.register_imports() { wasm.runtime_destroy(); crashtrace.end_session(); return false }
	page.js_startup(&app.prefs, app.cfg.persist_profile ? app.profile_dir : "")
	return true
}

@(private = "file")
process_teardown :: proc() {
	page.process_shutdown()   // the layout threads, the image decoders, the decoded web fonts, the bytecode cache, the Wasm engine
	crashtrace.end_session()   // a clean end (a kill leaves the file: the next start reports it)
}

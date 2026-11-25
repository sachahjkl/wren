package embed

import "core:sync"

// Process-wide shared resource gate: the first World or App to join runs `on_begin`,
// and the last to leave runs `on_end`. Concurrent callers wait until the transition finishes.
//
// State machine in one atomic word:
//   0             off
//   PROCESS_BUSY  first joiner runs on_begin, or last leaver runs on_end
//   n (1 ..)      active, n users joined
//
// off --first join--> busy --> 1 --join--> n + 1 ... n --leave--> n - 1 ... 1 --last leave--> busy --> off
PROCESS_BUSY :: sync.Futex(1) << 31

Process_Share :: struct {
	word: sync.Futex,
}

// Callbacks for process-wide setup and teardown owned by a Process_Share.
Process_Hooks :: struct {
	on_begin: proc(user: rawptr) -> bool,
	on_end:   proc(user: rawptr),
	user:     rawptr,
}

// Joins the shared process runtime. The first joiner runs `hooks.on_begin`.
// Returns false when `hooks.on_begin` fails (the caller is not counted as joined).
process_share_join :: proc(s: ^Process_Share, hooks: Process_Hooks) -> bool {
	w := &s.word
	for {
		v := sync.atomic_load(w)
		switch {
		case v & PROCESS_BUSY != 0:
			sync.futex_wait(w, u32(v))
		case v == 0:
			if _, won := sync.atomic_compare_exchange_strong(w, 0, sync.Futex(PROCESS_BUSY)); !won { continue }
			ok := hooks.on_begin == nil ? true : hooks.on_begin(hooks.user)
			sync.atomic_store(w, ok ? 1 : 0)
			sync.futex_broadcast(w)
			return ok
		case:
			if _, won := sync.atomic_compare_exchange_strong(w, v, v + 1); won { return true }
		}
	}
}

// Leaves the shared process runtime. The last leaver runs `hooks.on_end`.
process_share_leave :: proc(s: ^Process_Share, hooks: Process_Hooks) {
	w := &s.word
	for {
		v := sync.atomic_load(w)
		assert(v != 0 && v & PROCESS_BUSY == 0, "process_share_leave by a caller that did not join")
		if v == 1 {
			if _, won := sync.atomic_compare_exchange_strong(w, 1, sync.Futex(PROCESS_BUSY)); !won { continue }
			if hooks.on_end != nil { hooks.on_end(hooks.user) }
			sync.atomic_store(w, 0)
			sync.futex_broadcast(w)
			return
		}
		if _, won := sync.atomic_compare_exchange_strong(w, v, v - 1); won { return }
	}
}

// Number of active users currently joined to `s` (0 while off or transitioning).
process_share_users :: proc(s: ^Process_Share) -> int {
	v := sync.atomic_load(&s.word)
	return v & PROCESS_BUSY != 0 ? 0 : int(v)
}

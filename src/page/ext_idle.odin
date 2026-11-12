package page

// idle.queryState, idle.setDetectionInterval, idle.onStateChanged (docs/extensions.md, section 2.2: the vault's
// timeout). The shell gives the seconds since the last input in the browser's windows (Ext_Embedder.idle_seconds); the
// toolkit has no idle time of the whole system, so time spent in another program counts as idle. "locked" is never
// reported (the screen lock is not known).
//
// The state is watched only while a context listens to idle.onStateChanged, with one timer for every extension: while
// a state is "active", the timer is set for the moment it can turn "idle" (the interval less the time already idle);
// while one is "idle", the timer polls every EXT_IDLE_POLL_MS to see the input that ends it.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "wb:base"
import "wb:extensions"
import "wb:host"

EXT_IDLE_EVENT :: "idle.onStateChanged"
EXT_IDLE_POLL_MS :: 1000

@(private = "file")
ext_idle_seconds :: proc() -> f64 {
	em := &ext_router().embedder
	if em.idle_seconds == nil { return 0 }
	return em.idle_seconds(em.user)
}

@(private = "file")
ext_idle_interval_of :: proc(e: ^extensions.Extension) -> int {
	return e.idle_interval > 0 ? max(e.idle_interval, extensions.IDLE_MIN_INTERVAL) : extensions.IDLE_DEFAULT_INTERVAL
}

ext_idle_query :: proc(x: ^Ext_Call) {
	n: f64
	ok: bool
	#partial switch v in ext_arg(x, 0) {
	case json.Float:   n, ok = v, true
	case json.Integer: n, ok = f64(v), true
	}
	if !ok { ext_fail(x, "Error in invocation of idle.queryState: detectionIntervalInSeconds must be an integer"); return }
	st := extensions.idle_state_of(ext_idle_seconds(), int(n), false)
	ext_ok(x, extensions.json_quote(extensions.IDLE_STATE_NAMES[st]))
}

ext_idle_interval :: proc(x: ^Ext_Call) {
	n: f64
	ok: bool
	#partial switch v in ext_arg(x, 0) {
	case json.Float:   n, ok = v, true
	case json.Integer: n, ok = f64(v), true
	}
	if !ok || n < 0 { ext_fail(x, "Error in invocation of idle.setDetectionInterval: intervalInSeconds must be an integer"); return }
	x.e.idle_interval = int(min(n, 4 * 3600))
	ext_idle_schedule()
	ext_ok(x, "")
}

// Whether a context of `ext` listens to idle.onStateChanged (a background's stored listeners count: they start it).
@(private = "file")
ext_idle_listened :: proc(ext: string) -> bool {
	for _, c in ext_router().contexts { if c.ext == ext && c.listening[EXT_IDLE_EVENT] { return true } }
	return false
}

// Sends the state changes due now, then sets the timer for the next one (none when nobody listens).
ext_idle_schedule :: proc() {
	r := ext_router()
	loop := ext_loop()
	if loop == nil { return }
	if r.idle_timer != base.NIL_HANDLE { host.clear_timer(loop, r.idle_timer); r.idle_timer = base.NIL_HANDLE }
	secs := ext_idle_seconds()
	soonest := math.F64_MAX
	for e in ext_registry().list {
		if !e.enabled || e.image == nil || !e.image.ok || !ext_idle_listened(e.id) { continue }
		interval := ext_idle_interval_of(e)
		st := extensions.idle_state_of(secs, interval, false)
		if st != e.idle_state {
			e.idle_state = st
			ext_emit(e.id, EXT_IDLE_EVENT, fmt.tprintf("[%s]", extensions.json_quote(extensions.IDLE_STATE_NAMES[st])))
		}
		wait := st == .Active ? (f64(interval) - secs) * 1000 : EXT_IDLE_POLL_MS
		soonest = min(soonest, max(wait, EXT_IDLE_POLL_MS))
	}
	if soonest == math.F64_MAX { return }
	r.idle_timer = host.set_timer(loop, soonest, 0, proc(_: rawptr) {
		ext_router().idle_timer = base.NIL_HANDLE
		ext_idle_schedule()
	}, nil)
}

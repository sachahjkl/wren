// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=locks order=53 exposed=(Window,Worker)
/// The Web Locks API (src/page/bindings_locks.odin): navigator.locks.request / query, held per origin and shared
/// across every page and worker of that origin in this process. The grant order, the shared/exclusive rule,
/// ifAvailable, steal and the waiting queue are native; the engine holds each request's callback and the promise it
/// returns and runs the callback when the host grants the lock (wj_cb_lock_granted).
package api_locks

/// A lock mode (LockMode).
LockMode :: enum i32 {
	Shared,
	Exclusive,
}

/// navigator.locks.request(name, {mode, ifAvailable, steal, signal}, callback). The result is packed: bit 0 is
/// "available" (clear only for ifAvailable on a busy lock, or an opaque origin), bit 1 is "granted now" (run the
/// callback with the Lock immediately), and the rest (>> 2) is the lock id used to release it. When available but
/// not granted-now, the request waits and the engine is told on grant (the callback index / user name the engine
/// record for that notification).
//@wb fn
LockManager_request :: proc(name: string, mode: LockMode, if_available: bool, steal: bool, callback: u32, user: i32, broken_callback: u32, has_signal: bool) -> i64

/// The callback's returned promise settled, the callback was null, or a pending request was aborted: release the
/// lock (or drop the queued request) and grant whatever waits.
//@wb fn
LockManager_release :: proc(id: u64)

/// navigator.locks.query(): the number of held / pending locks of the caller's origin, and the i-th entry's fields.
//@wb fn
LockManager_queryCount :: proc(held: bool) -> i32

//@wb fn raises
LockManager_queryName :: proc(held: bool, index: i32) -> string

//@wb fn raises
LockManager_queryMode :: proc(held: bool, index: i32) -> string

//@wb fn raises
LockManager_queryClient :: proc(held: bool, index: i32) -> string


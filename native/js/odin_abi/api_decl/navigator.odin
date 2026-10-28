// navigator (api/js_web.widl module navigator), the Web Locks API (api/locks.widl) and Prioritized Task Scheduling
// (api/scheduler.widl). Used by native/js/odin/web_navigator.odin, web_locks.odin, web_scheduler.odin.
package api_decl

import "../abi"

// A string member of Navigator.
NavigatorField :: enum i32 { User_Agent, App_Version, Platform, Vendor, Languages, Do_Not_Track }

// A string member of Navigator (Languages: comma separated; Do_Not_Track: "1", or "" for null).
Navigator_get :: #type proc(field: NavigatorField) -> string
Navigator_hardwareConcurrency :: #type proc() -> i32
Navigator_onLine :: #type proc() -> bool
Navigator_maxTouchPoints :: #type proc() -> i32
Navigator_cookieEnabled :: #type proc() -> bool
UserActivation_isActive :: #type proc() -> bool
UserActivation_hasBeenActive :: #type proc() -> bool
// navigator.sendBeacon(url, data): false when the beacon is refused. `content_type` "" sends none.
Beacon_send :: #type proc(url: string, data: Maybe(abi.Bytes), content_type: string) -> bool

// A lock mode.
LockMode :: enum i32 { Shared, Exclusive }

// navigator.locks.request: packed, bit 0 "available", bit 1 "granted now", >> 2 the lock id. `callback` and
// `broken_callback` are function-table indices called with `user`.
LockManager_request :: #type proc(name: string, mode: LockMode, if_available: bool, steal: bool, callback: u32, user: i32, broken_callback: u32, has_signal: bool) -> i64
// Release a lock, or drop a queued request.
LockManager_release :: #type proc(id: u64)
// navigator.locks.query(): the held / pending entries of the caller's origin and their fields.
LockManager_queryCount :: #type proc(held: bool) -> i32
LockManager_queryName :: #type proc(held: bool, index: i32) -> (string, abi.Api_Error)
LockManager_queryMode :: #type proc(held: bool, index: i32) -> (string, abi.Api_Error)
LockManager_queryClient :: #type proc(held: bool, index: i32) -> (string, abi.Api_Error)

// A task priority, highest first.
TaskPriority :: enum i32 { User_Blocking, User_Visible, Background }

// Post a task: `callback` (a function-table index) runs with `user` when due. The task id, 0 without a page realm.
Scheduler_post :: #type proc(callback: u32, user: i32, priority: TaskPriority, delay_ms: f64) -> u64
Scheduler_cancel :: #type proc(id: u64) -> abi.Api_Error
Scheduler_setPriority :: #type proc(id: u64, priority: TaskPriority) -> abi.Api_Error
Scheduler_isInputPending :: #type proc(include_continuous: bool) -> bool

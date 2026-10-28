// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=scheduler order=62 exposed=(Window,Worker)
/// Prioritized Task Scheduling (src/page/bindings_scheduler.odin): scheduler.postTask / scheduler.yield, TaskController
/// and TaskSignal. The priority queue and the ordering are native (on the page's event loop); the C glue holds each
/// task's JavaScript promise, callback and signal and runs the callback when the host says the task is due. Three
/// priorities, highest first: user-blocking, user-visible, background.
package api_scheduler

/// A task priority (TaskPriority), highest first.
TaskPriority :: enum i32 {
	User_Blocking,
	User_Visible,
	Background,
}

/// Post a task; `callback` (a function-table index) runs with (user: i32) when the task is due. `delay_ms` 0 queues
/// it at once. Returns the task id (for cancel / setPriority), 0 when there is no page realm.
//@wb fn
Scheduler_post :: proc(callback: u32, user: i32, priority: TaskPriority, delay_ms: f64) -> u64

/// Drop a queued (or delayed) task: its signal aborted, or the realm released it.
//@wb fn raises
Scheduler_cancel :: proc(id: u64)

/// Change a queued task's priority (TaskController.setPriority).
//@wb fn raises
Scheduler_setPriority :: proc(id: u64, priority: TaskPriority)

/// navigator.scheduling.isInputPending.
//@wb fn
Scheduler_isInputPending :: proc(include_continuous: bool) -> bool


// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=timers order=65 exposed=(Window,Worker)
/// Timers and the rendering-related scheduling of HTML: setTimeout / setInterval (with the HTML nesting clamp and
/// background throttling), requestAnimationFrame, requestIdleCallback, and the page's visibility. Timestamps given to
/// callbacks are on the performance.now() timeline of the page.
package api_timers

//@wb handle host=Timer lookup=lookup_Timer
/// A pending timeout or interval.
Timer :: distinct Handle

//@wb callback
TimerHandler :: #type proc "contextless" (user: i32)

/// A timer callback with a 64-bit user value.
//@wb callback
TimerHandler64 :: #type proc "contextless" (user: i64)

/// An animation frame callback: `time` is the frame's time on the page's performance timeline.
//@wb callback
FrameRequestCallback :: #type proc "contextless" (user: i32, time: f64)

/// An idle callback: run before `deadline` (performance timeline), or late because its timeout expired.
//@wb callback
IdleRequestCallback :: #type proc "contextless" (user: i32, deadline: f64, did_timeout: bool)

/// Whether the page is shown.
VisibilityState :: enum i32 {
	Visible,
	Hidden,
}

/// setTimeout(callback, delay_ms)
//@wb fn
Timers_setTimeout :: proc(callback: TimerHandler, user: i32, delay_ms: f64 = 0) -> Timer

/// setInterval(callback, delay_ms)
//@wb fn
Timers_setInterval :: proc(callback: TimerHandler, user: i32, delay_ms: f64 = 0) -> Timer

/// setTimeout with a 64-bit user value.
//@wb fn
Timers_setTimeout64 :: proc(callback: TimerHandler64, user: i64, delay_ms: f64 = 0) -> Timer

/// setInterval with a 64-bit user value.
//@wb fn
Timers_setInterval64 :: proc(callback: TimerHandler64, user: i64, delay_ms: f64 = 0) -> Timer

/// clearTimeout / clearInterval. Invalid_Handle when the timer already fired or was cleared.
//@wb fn raises
Timers_clear :: proc(timer: Timer)

/// The browser's monotonic clock in ms (performance.now() is the page's own timeline).
//@wb fn
Timers_now :: proc() -> f64

/// requestAnimationFrame(callback): an id, 0 when too many callbacks wait (timers.max_frame_callbacks).
//@wb fn
requestAnimationFrame :: proc(callback: FrameRequestCallback, user: i32 = 0) -> u64

/// cancelAnimationFrame(id). Not_Found when it ran or was cancelled already.
//@wb fn raises
cancelAnimationFrame :: proc(id: u64)

/// requestIdleCallback(callback, {timeout}): an id, 0 when too many wait. timeout_ms <= 0 means none.
//@wb fn
requestIdleCallback :: proc(callback: IdleRequestCallback, user: i32 = 0, timeout_ms: f64 = 0) -> u64

/// cancelIdleCallback(id). Not_Found when it ran or was cancelled already.
//@wb fn raises
cancelIdleCallback :: proc(id: u64)

/// document.visibilityState
//@wb fn
Document_visibilityState :: proc() -> VisibilityState


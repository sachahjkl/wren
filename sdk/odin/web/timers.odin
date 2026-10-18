package web

// Animation frames, idle callbacks, 64-bit timer user values and page visibility (import module "timers").
//
// Animation frame and idle timestamps are on the performance.now() timeline (see performance.odin).

Frame_Callback :: #type proc "contextless" (user: i32, timestamp_ms: f64)
Idle_Callback :: #type proc "contextless" (user: i32, deadline_ms: f64, did_timeout: i32)
Timer_Callback64 :: #type proc "contextless" (user: i64)

Visibility_State :: enum i32 { Visible = 0, Hidden = 1 }

foreign import timers_ext "timers"

@(default_calling_convention = "contextless")
foreign timers_ext {
	Timers_setTimeout64 :: proc(callback: Timer_Callback64, user: i64, delay_ms: f64) -> Handle ---
	Timers_setInterval64 :: proc(callback: Timer_Callback64, user: i64, delay_ms: f64) -> Handle ---
	// 0 when the page has too many waiting (preference timers.max_animation_callbacks)
	requestAnimationFrame :: proc(callback: Frame_Callback, user: i32) -> u64 ---
	cancelAnimationFrame :: proc(id: u64) -> Error ---
	// timeout_ms <= 0: no timeout
	requestIdleCallback :: proc(callback: Idle_Callback, user: i32, timeout_ms: f64) -> u64 ---
	cancelIdleCallback :: proc(id: u64) -> Error ---
	Document_visibilityState :: proc() -> Visibility_State ---
}

// IdleDeadline.timeRemaining()
idle_time_remaining :: proc "contextless" (deadline_ms: f64) -> f64 { return max(deadline_ms - Performance_now(), 0) }

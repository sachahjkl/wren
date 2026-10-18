package web

// AbortController / AbortSignal (import module "abort"). A signal is an EventTarget: listen for "abort" with
// add_listener; Event_code / event_text carry the reason. Release controllers and signals with Object_release.

foreign import abort_mod "abort"

@(default_calling_convention = "contextless")
foreign abort_mod {
	AbortController_create :: proc() -> Handle ---
	AbortController_signal :: proc(controller: Handle) -> Handle ---
	@(link_name = "AbortController_abort") raw_abortControllerAbort :: proc(controller: Handle, code: i64, reason: [^]u8, rl: i32) -> Error ---
	// 1 aborted, 0 not, < 0 error
	AbortSignal_aborted :: proc(signal: Handle) -> i32 ---
	AbortSignal_reasonCode :: proc(signal: Handle) -> i64 ---
	@(link_name = "AbortSignal_reason") raw_abortSignalReason :: proc(signal: Handle, buf: [^]u8, cap: i32) -> i32 ---
	// 0, or the reason's code
	AbortSignal_throwIfAborted :: proc(signal: Handle) -> i64 ---
	@(link_name = "AbortSignal_abort") raw_abortSignalAbort :: proc(code: i64, reason: [^]u8, rl: i32) -> Handle ---
	AbortSignal_timeout :: proc(ms: f64) -> Handle ---
	@(link_name = "AbortSignal_any") raw_abortSignalAny :: proc(list: [^]Handle, bytes: i32) -> Handle ---
}

// abort(): code 0 and an empty reason give the default AbortError.
abort_controller_abort :: proc "contextless" (c: Handle, code: i64 = 0, reason := "") -> Error {
	return raw_abortControllerAbort(c, code, raw_data(reason), i32(len(reason)))
}

abort_signal_reason :: proc "contextless" (s: Handle, buf: []u8) -> string {
	n := raw_abortSignalReason(s, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

abort_signal_aborted_with :: proc "contextless" (code: i64 = 0, reason := "") -> Handle {
	return raw_abortSignalAbort(code, raw_data(reason), i32(len(reason)))
}

abort_signal_any :: proc "contextless" (signals: []Handle) -> Handle {
	return raw_abortSignalAny(raw_data(signals), i32(len(signals) * size_of(Handle)))
}

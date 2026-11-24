#+build !windows
package browser

// Off Windows the chrome-frame pacing helpers that read the Win32 message queue have no counterpart: the toolkit's event
// loop drives frames (poll_events / on_frame), not WM_PAINT modal loops, so there is no separate modal pump to peek at.
// shell_input_pending / shell_user_input_pending therefore answer false (the loop already decides when to build a frame
// from the events it polled).

shell_input_pending :: proc() -> bool { return false }

shell_user_input_pending :: proc() -> bool { return false }

package browser

// Reading the thread's message queue to pace the chrome frames inside the system's modal loops (live resize, a menu,
// where WM_PAINT drives frames): what input and repaints wait, and whether genuine user input (not another thread's
// wake-up) is pending so a frame is shown at once. Windows only (the Win32 queue); shell_frames_other.odin answers
// false off Windows, where the toolkit's event loop drives frames and there is no such modal pump. It also provides
// frame_slot_ready, the non-blocking poll of the swap chain's frame-latency object (shell_frames.odin / pacing).

import win "core:sys/windows"

foreign import user32_shell "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_shell {
	GetQueueStatus :: proc(flags: u32) -> u32 ---
	PeekMessageW :: proc(msg: ^win.MSG, hwnd: win.HWND, filter_min, filter_max, remove: u32) -> win.BOOL ---
}

// Messages wait in the thread's queue (input, posted or sent messages, a repaint), without taking them.
shell_input_pending :: proc() -> bool {
	QS_KEY :: 0x0001; QS_MOUSEMOVE :: 0x0002; QS_MOUSEBUTTON :: 0x0004; QS_POSTMESSAGE :: 0x0008
	QS_PAINT :: 0x0020; QS_SENDMESSAGE :: 0x0040
	status := GetQueueStatus(QS_KEY | QS_MOUSEMOVE | QS_MOUSEBUTTON | QS_POSTMESSAGE | QS_PAINT | QS_SENDMESSAGE)
	return status >> 16 != 0   // (the high word: kinds of messages now in the queue)
}

// The user's input waits in the thread's queue: keys, pointer, buttons, touch, raw input, hot keys. Not the messages
// other threads post to wake the loop (a network chunk, a decoded picture, a timer): those are work for the next frame,
// not a hand on the keyboard, and counting them made every frame of a busy page "answer input" (shown at once, the
// screen's slot not waited for: twice the display's rate while a video played).
shell_user_input_pending :: proc() -> bool {
	QS_KEY :: 0x0001; QS_MOUSEMOVE :: 0x0002; QS_MOUSEBUTTON :: 0x0004; QS_POSTMESSAGE :: 0x0008; QS_HOTKEY :: 0x0080
	QS_RAWINPUT :: 0x0400; QS_TOUCH :: 0x0800; QS_POINTER :: 0x1000
	status := GetQueueStatus(QS_KEY | QS_MOUSEMOVE | QS_MOUSEBUTTON | QS_POSTMESSAGE | QS_HOTKEY | QS_RAWINPUT | QS_TOUCH | QS_POINTER)
	if status >> 16 & (QS_KEY | QS_MOUSEMOVE | QS_MOUSEBUTTON | QS_HOTKEY | QS_RAWINPUT | QS_TOUCH | QS_POINTER) != 0 { return true }
	if status >> 16 & QS_POSTMESSAGE == 0 { return false }
	// only posted messages wait: other threads' wake-ups, or input posted to the window (an automation driver, a remote
	// desktop): look through them for keys, pointer and touch
	WM_KEYFIRST :: 0x0100; WM_KEYLAST :: 0x0109; WM_MOUSEFIRST :: 0x0200; WM_MOUSELAST :: 0x020E
	WM_TOUCH :: 0x0240; WM_POINTERFIRST :: 0x0245; WM_POINTERLAST :: 0x0258
	PM_NOREMOVE :: 0x0000; PM_NOYIELD :: 0x0002
	msg: win.MSG
	for r in ([?][2]u32{{WM_KEYFIRST, WM_KEYLAST}, {WM_MOUSEFIRST, WM_MOUSELAST}, {WM_TOUCH, WM_TOUCH}, {WM_POINTERFIRST, WM_POINTERLAST}}) {
		if PeekMessageW(&msg, nil, r[0], r[1], PM_NOREMOVE | PM_NOYIELD) { return true }
	}
	return false
}

// Whether the swap chain can take a frame now: the frame-latency object polled without blocking (nil object: always
// ready, e.g. an offscreen window).
frame_slot_ready :: proc(handle: rawptr) -> bool {
	if handle == nil { return true }
	return win.WaitForSingleObject(win.HANDLE(handle), 0) == win.WAIT_OBJECT_0
}

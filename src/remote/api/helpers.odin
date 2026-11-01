package api

// What a program driving a Wren says often: the general barrier, where the page is, the address bar, a capture as pixels.

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:time"

// How many frames a poll of wait_until lets pass: what a test looks at moves in a frame of the browser's, no sooner.
POLL_FRAMES :: 1
// The limit of one such frame (the deadline is what ends a failing run).
POLL_FRAME_LIMIT :: 10 * time.Second

// Waits until `ready` holds, looking again after each frame of the browser; false when the deadline passed. The poll asks for
// frames, which a headless Wren makes as fast as they are asked for. For what a script can see, wait_js costs less.
wait_until_plain :: proc(s: ^Session, ready: proc(s: ^Session) -> bool, what := "a condition", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> bool {
	end := time.tick_add(time.tick_now(), deadline)
	for {
		if ready(s) { return true }
		if time.tick_diff(time.tick_now(), end) <= 0 { poll_timed_out(s, what, deadline, loc); return false }
		if wait_frames(s, POLL_FRAMES, POLL_FRAME_LIMIT, loc) != .None { return false }
	}
}

// The same with what the condition needs: `ready(s, data)`.
wait_until_with :: proc(s: ^Session, data: $D, ready: proc(s: ^Session, data: D) -> bool, what := "a condition", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> bool {
	end := time.tick_add(time.tick_now(), deadline)
	for {
		if ready(s, data) { return true }
		if time.tick_diff(time.tick_now(), end) <= 0 { poll_timed_out(s, what, deadline, loc); return false }
		if wait_frames(s, POLL_FRAMES, POLL_FRAME_LIMIT, loc) != .None { return false }
	}
}

wait_until :: proc { wait_until_plain, wait_until_with }

@(private)
poll_timed_out :: proc(s: ^Session, what: string, deadline: time.Duration, loc: runtime.Source_Code_Location) {
	set_failure(fmt.tprintf("%v passed waiting for %s", deadline, what))
	call_failed(s, .Timeout, what, loc)
}

// The address of the current tab.
location :: proc(s: ^Session, loc := #caller_location) -> (string, Error) { return eval(s, "location.href", loc = loc) }

// `text` typed in the address bar (and `keys` pressed before Enter, one each), the load waited for; the address it led to.
address_bar :: proc(s: ^Session, text: string, keys: []string = nil, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> (address: string, e: Error) {
	key(s, "Ctrl+L", loc = loc) or_return
	type_text(s, text, loc) or_return
	for k in keys { key(s, k, loc = loc) or_return }
	key(s, "Enter", loc = loc) or_return
	wait_load(s, deadline, loc) or_return
	return location(s, loc)
}

// The pixels of the next frame (the browser's real render, shown on a screen or not). The options are `screenshot`'s: the window by default.
capture :: proc(s: ^Session, o := Shot_Options{}, loc := #caller_location) -> (img: Image, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_shot(&p, o)
	a := request(s, "Page.captureScreenshot", &p) or_return
	data, derr := base64.decode(s_of(a, "data"), allocator = context.temp_allocator)
	decoded, ok := decode_png(data)
	if derr != nil || !ok {
		set_failure("the capture is not a PNG picture")
		call_failed(s, .Bad_Answer, "capture", loc)
		return {}, .Bad_Answer
	}
	return decoded, .None
}

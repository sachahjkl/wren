package browser

import "core:testing"
import "toolkit:platform"

@(test)
selection_release_drops_a_press_waiting_for_layout :: proc(t: ^testing.T) {
	app := new(App)   // (no window: its own state is the App's bare one)
	defer free(app)
	ss := &window_own(app).selection
	ss.pending, ss.down = true, true
	selection_pointer_up(app, nil, platform.Event{kind = .Mouse_Release, button = .Right})
	testing.expect(t, ss.pending, "a right release does not end a left press")
	selection_pointer_up(app, nil, platform.Event{kind = .Mouse_Release, button = .Left})
	testing.expect(t, !ss.pending, "the left release ends the press that waited for a fresh layout: started later it would select under a button that is up")
	testing.expect(t, !ss.down, "and the gesture is closed")
}

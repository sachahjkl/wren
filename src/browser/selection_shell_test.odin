package browser

import "core:testing"
import "toolkit:platform"

@(test)
selection_release_drops_a_press_waiting_for_layout :: proc(t: ^testing.T) {
	app := app_make()   // (no window: its own state is the App's bare one)
	defer app_free(app)
	g := gesture_of(app)
	g.owner, g.button = .Press_Pending, .Left
	gesture_release(app, platform.Event{kind = .Mouse_Release, button = .Right})
	testing.expect(t, g.owner == .Press_Pending, "a right release does not end a left press")
	gesture_release(app, platform.Event{kind = .Mouse_Release, button = .Left})
	testing.expect(t, g.owner == .Idle, "the left release ends the press that waited for a fresh layout: started later it would select under a button that is up")
}

package browser

import "core:testing"
import "toolkit:platform"

@(test)
selection_release_drops_a_press_waiting_for_layout :: proc(t: ^testing.T) {
	saved := sshell
	defer sshell = saved
	sshell.pending, sshell.down = true, true
	selection_pointer_up(nil, nil, platform.Event{kind = .Mouse_Release, button = .Right})
	testing.expect(t, sshell.pending, "a right release does not end a left press")
	selection_pointer_up(nil, nil, platform.Event{kind = .Mouse_Release, button = .Left})
	testing.expect(t, !sshell.pending, "the left release ends the press that waited for a fresh layout: started later it would select under a button that is up")
	testing.expect(t, !sshell.down, "and the gesture is closed")
}

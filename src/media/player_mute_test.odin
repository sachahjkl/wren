package media

import "core:testing"

// The application's mute of a player (a muted tab) silences it whatever the element's volume and muted say, and gives
// back the element's own gain when lifted; the element's settings are kept through it.
@(test)
host_mute_silences_the_player_and_keeps_its_volume :: proc(t: ^testing.T) {
	p := player_create(nil, nil, {}, nil, nil)   // (no tracks: no threads)
	defer player_destroy(p)
	gain: f32 = -1
	out := Audio_Output{impl = &gain, set_gain = proc(o: ^Audio_Output, g: f32) { (^f32)(o.impl)^ = g }}
	p.out = &out
	defer p.out = nil   // (not an output to stop or destroy)
	player_set_volume(p, 0.5, false)
	testing.expect_value(t, gain, 0.25)
	player_set_host_muted(p, true)
	testing.expect_value(t, gain, 0)
	testing.expect(t, player_host_muted(p))
	player_set_volume(p, 0.8, false)   // the page changes its volume meanwhile: still silent
	testing.expect_value(t, gain, 0)
	player_set_host_muted(p, false)
	testing.expect(t, abs(gain - 0.64) < 1e-5)
	player_set_volume(p, 0.8, true)    // the page's own mute still works
	testing.expect_value(t, gain, 0)
	testing.expect_value(t, p.gain, 0.8)
}

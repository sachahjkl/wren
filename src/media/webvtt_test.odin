package media

import "core:testing"

// Tags left open at the end of a cue (<c>, <v>, <lang>) and a setting given twice free what they hold: the fuzzer found
// them leaking. The test's tracking allocator fails it on a leak.
@(test)
vtt_open_tags_and_repeated_settings_leave_nothing :: proc(t: ^testing.T) {
	text := "WEBVTT\n\nREGION\nid:a id:b width:40%\n\n00:00:01.000 --> 00:00:02.000 region:a region:b align:start\n<c.big.red>never closed <v Ada>still open <lang fr>ouvert\n"
	f := vtt_parse(text)
	defer vtt_destroy(&f)
	testing.expect_value(t, len(f.cues), 1)
	cue := vtt_cue_from_text("<c.x>a <v B>b <lang en>c")
	vtt_cue_destroy(&cue)
}

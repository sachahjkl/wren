package media

import "core:testing"

@(private = "file")
parse_webm :: proc(data: []u8, step: int, c: ^Collected) -> Parse_Error {
	d: Webm_Demuxer
	webm_init(&d, collector(c))
	defer webm_destroy(&d)
	if step <= 0 { return webm_feed(&d, data) }
	for i := 0; i < len(data); i += step {
		if err := webm_feed(&d, data[i:min(i + step, len(data))]); err != .None { return err }
	}
	return .None
}

@(test)
webm_av1_opus :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	c: Collected
	defer collected_free(&c)
	testing.expect_value(t, parse_webm(data, 0, &c), Parse_Error.None)
	if !testing.expect_value(t, len(c.tracks), 2) { return }
	v, a := c.tracks[0], c.tracks[1]
	testing.expect_value(t, v.kind, Track_Kind.Video)
	testing.expect_value(t, v.codec, Codec.AV1)
	testing.expect_value(t, v.width, 320)
	testing.expect_value(t, v.height, 180)
	testing.expect_value(t, a.kind, Track_Kind.Audio)
	testing.expect_value(t, a.codec, Codec.Opus)
	testing.expect_value(t, a.channels, 2)
	testing.expect_value(t, a.sample_rate, 48000)
	testing.expect(t, len(a.config) >= 19 && string(a.config[:8]) == "OpusHead", "OpusHead")
	testing.expect(t, a.codec_delay > 0, "pre-skip")
	testing.expect_value(t, len(c.samples[0]), 96)
	testing.expect(t, len(c.samples[1]) > 150, "opus packets")
	testing.expect(t, .Keyframe in c.samples[0][0].flags, "first frame is a keyframe")
	for i in 1 ..< len(c.samples[0]) {
		if c.samples[0][i].pts <= c.samples[0][i - 1].pts { testing.fail_now(t, "pts not increasing") }
	}
	last := c.samples[0][len(c.samples[0]) - 1]
	testing.expect(t, abs(time_seconds(last.pts) - 95.0 / 24.0) < 0.01, "last frame time")
}

@(test)
webm_any_split :: proc(t: ^testing.T) {
	data := fixture("clip_vp9.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip_vp9.webm missing") { return }
	whole: Collected
	defer collected_free(&whole)
	testing.expect_value(t, parse_webm(data, 0, &whole), Parse_Error.None)
	if !testing.expect_value(t, len(whole.tracks), 2) { return }
	testing.expect_value(t, whole.tracks[0].codec, Codec.VP9)
	testing.expect_value(t, len(whole.samples[0]), 96)
	for step in ([?]int{1, 5, 17, 999, 4096}) {
		parts: Collected
		defer collected_free(&parts)
		testing.expect_value(t, parse_webm(data, step, &parts), Parse_Error.None)
		for tr in 0 ..< len(whole.samples) {
			if !testing.expect_value(t, len(parts.samples[tr]), len(whole.samples[tr])) { continue }
			for i in 0 ..< len(whole.samples[tr]) {
				a, b := whole.samples[tr][i], parts.samples[tr][i]
				if a.pts != b.pts || string(a.data) != string(b.data) {
					testing.expectf(t, false, "step %d track %d sample %d differs", step, tr, i)
					break
				}
			}
		}
	}
}

@(test)
webm_garbage_is_not_a_crash :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	for i := 0; i < min(len(data), 2000); i += 1 {
		bad := make([]u8, len(data))
		defer delete(bad)
		copy(bad, data)
		bad[i] ~= 0xff
		c: Collected
		parse_webm(bad, 0, &c)
		collected_free(&c)
	}
}

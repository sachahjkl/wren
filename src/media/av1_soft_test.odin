package media

import "core:testing"

// The built-in AV1 decoder plays the test clip: every coded frame comes out as a picture of the track's size, in
// presentation order, with planes the size its strides say; a flush (a seek) and a picture kept past the decoder's end
// are fine.
@(test)
av1_software_decoder_decodes_the_clip :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	c: Collected
	defer collected_free(&c)
	d0: Webm_Demuxer
	webm_init(&d0, collector(&c))
	testing.expect_value(t, webm_feed(&d0, data), Parse_Error.None)
	webm_destroy(&d0)
	if !testing.expect(t, len(c.tracks) >= 1 && c.tracks[0].codec == .AV1) { return }
	track := c.tracks[0]
	dec := av1_soft_create(track)
	if !testing.expect(t, dec != nil, "the decoder opens") { return }
	got := 0
	last := TIME_NONE
	kept: Video_Frame
	take :: proc(t: ^testing.T, dec: ^Video_Decoder, track: Track, got: ^int, last: ^Time, kept: ^Video_Frame) {
		for {
			f: Video_Frame
			if dec.pull(dec, &f) != .Frame { return }
			testing.expect(t, f.width == track.width && f.height == track.height && f.format == .I420, "a 320x180 8-bit picture")
			testing.expect(t, len(f.planes[0]) >= f.strides[0] * f.height && f.strides[0] >= f.width, "the luma plane")
			testing.expect(t, last^ == TIME_NONE || f.pts > last^, "presentation order")
			last^ = f.pts
			got^ += 1
			if got^ == 10 { kept^ = f } else { frame_release(&f) }
		}
	}
	for &s in c.samples[0] {
		for !dec.push(dec, &s) { take(t, dec, track, &got, &last, &kept) }
		take(t, dec, track, &got, &last, &kept)
	}
	dec.drain(dec)
	take(t, dec, track, &got, &last, &kept)
	testing.expect_value(t, got, len(c.samples[0]))
	dec.flush(dec)
	dec.destroy(dec)
	frame_release(&kept)   // after the decoder: the context closes with its last picture
}

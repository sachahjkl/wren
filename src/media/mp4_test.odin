package media

import "core:fmt"
import "core:os"
import "core:testing"

// Files: examples/site/media/video (tools/gen_video_fixtures.ps1).
@(private)
fixture :: proc(name: string) -> []u8 {
	data, err := os.read_entire_file(fmt.tprintf("examples/site/media/video/%s", name), context.allocator)
	if err != nil { return nil }
	return data
}

@(private)
Collected :: struct {
	tracks:  [dynamic]Track,
	samples: [dynamic][dynamic]Sample,   // by track
	duration: Time,
	inits:   int,
}

@(private)
collector :: proc(c: ^Collected) -> Demux_Sink {
	return Demux_Sink{
		user = c,
		tracks = proc(user: rawptr, tracks: []Track, duration: Time) {
			c := (^Collected)(user)
			c.inits += 1
			c.duration = duration
			for &t in c.tracks { track_destroy(&t) }
			clear(&c.tracks)
			for t in tracks { append(&c.tracks, track_clone(t)) }
			for len(c.samples) < len(tracks) { append(&c.samples, make([dynamic]Sample)) }
		},
		sample = proc(user: rawptr, track: int, s: Sample) {
			c := (^Collected)(user)
			for len(c.samples) <= track { append(&c.samples, make([dynamic]Sample)) }
			append(&c.samples[track], s)
		},
	}
}

@(private)
collected_free :: proc(c: ^Collected) {
	for &t in c.tracks { track_destroy(&t) }
	delete(c.tracks)
	for &l in c.samples {
		for &s in l { sample_destroy(&s) }
		delete(l)
	}
	delete(c.samples)
}

// Feeds `data` in pieces of `step` bytes (0: whole).
@(private = "file")
parse_mp4 :: proc(data: []u8, step: int, c: ^Collected) -> Parse_Error {
	d: Mp4_Demuxer
	mp4_init(&d, collector(c))
	defer mp4_destroy(&d)
	if step <= 0 { return mp4_feed(&d, data) }
	for i := 0; i < len(data); i += step {
		if err := mp4_feed(&d, data[i:min(i + step, len(data))]); err != .None { return err }
	}
	return .None
}

@(test)
mp4_progressive_tracks_and_samples :: proc(t: ^testing.T) {
	data := fixture("clip.mp4")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.mp4 missing") { return }
	c: Collected
	defer collected_free(&c)
	testing.expect_value(t, parse_mp4(data, 0, &c), Parse_Error.None)
	if !testing.expect_value(t, len(c.tracks), 2) { return }
	v, a := c.tracks[0], c.tracks[1]
	testing.expect_value(t, v.kind, Track_Kind.Video)
	testing.expect_value(t, v.codec, Codec.H264)
	testing.expect_value(t, v.width, 320)
	testing.expect_value(t, v.height, 180)
	testing.expect_value(t, v.nal_length_size, 4)
	testing.expect(t, len(v.config) > 8, "avcC kept")
	testing.expect_value(t, a.kind, Track_Kind.Audio)
	testing.expect_value(t, a.codec, Codec.AAC)
	testing.expect_value(t, a.sample_rate, 44100)
	testing.expect_value(t, a.channels, 2)
	testing.expect(t, len(a.config) >= 2, "AudioSpecificConfig kept")
	testing.expect_value(t, v.codec_string[:4], "avc1")
	testing.expect_value(t, a.codec_string, "mp4a.40.2")
	// 4 s at 24 fps
	testing.expect_value(t, len(c.samples[0]), 96)
	testing.expect(t, abs(time_seconds(c.duration) - 4) < 0.1, "movie duration 4 s")
	// the first frame is a keyframe at 0; B-frames: some pts differ from dts
	testing.expect(t, .Keyframe in c.samples[0][0].flags)
	testing.expect_value(t, c.samples[0][0].pts, Time(0))
	reordered := 0
	keys := 0
	for s in c.samples[0] {
		if s.pts != s.dts { reordered += 1 }
		if .Keyframe in s.flags { keys += 1 }
		testing.expect(t, len(s.data) > 0, "payload")
	}
	testing.expect(t, reordered > 0, "B-frames: presentation order differs from decode order")
	testing.expect_value(t, keys, 4)
	// decode order: dts never goes back
	for i in 1 ..< len(c.samples[0]) {
		if c.samples[0][i].dts < c.samples[0][i - 1].dts { testing.fail_now(t, "dts goes back") }
	}
	// audio: 1024 samples per frame, the edit list shifts the priming delay out of the timeline
	testing.expect(t, len(c.samples[1]) > 150, "audio frames")
	testing.expect(t, c.samples[1][0].pts <= 0, "priming frame starts before 0")
}

@(test)
mp4_any_split_gives_the_same_samples :: proc(t: ^testing.T) {
	data := fixture("clip.mp4")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.mp4 missing") { return }
	whole: Collected
	defer collected_free(&whole)
	parse_mp4(data, 0, &whole)
	for step in ([?]int{1, 7, 13, 1000, 4099}) {
		parts: Collected
		defer collected_free(&parts)
		testing.expect_value(t, parse_mp4(data, step, &parts), Parse_Error.None)
		if !testing.expect_value(t, len(parts.samples), len(whole.samples)) { continue }
		for tr in 0 ..< len(whole.samples) {
			if !testing.expect_value(t, len(parts.samples[tr]), len(whole.samples[tr])) { continue }
			for i in 0 ..< len(whole.samples[tr]) {
				a, b := whole.samples[tr][i], parts.samples[tr][i]
				if a.pts != b.pts || a.dts != b.dts || string(a.data) != string(b.data) {
					testing.expectf(t, false, "step %d track %d sample %d differs", step, tr, i)
					break
				}
			}
		}
	}
}

@(test)
mp4_moov_at_the_end :: proc(t: ^testing.T) {
	data := fixture("clip_moov_end.mp4")
	defer delete(data)
	ref := fixture("clip.mp4")
	defer delete(ref)
	if !testing.expect(t, len(data) > 0 && len(ref) > 0, "fixtures missing") { return }
	a, b: Collected
	defer collected_free(&a)
	defer collected_free(&b)
	testing.expect_value(t, parse_mp4(data, 0, &a), Parse_Error.None)
	testing.expect_value(t, parse_mp4(data, 4099, &b), Parse_Error.None)
	if !testing.expect_value(t, len(a.samples), 2) { return }
	testing.expect_value(t, len(a.samples[0]), 96)
	testing.expect_value(t, len(b.samples[0]), 96)
	testing.expect_value(t, len(b.samples[1]), len(a.samples[1]))
}

@(test)
mp4_fragmented :: proc(t: ^testing.T) {
	data := fixture("clip_frag.mp4")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip_frag.mp4 missing") { return }
	for step in ([?]int{0, 1, 333, 8192}) {
		c: Collected
		defer collected_free(&c)
		testing.expect_value(t, parse_mp4(data, step, &c), Parse_Error.None)
		if !testing.expect_value(t, len(c.tracks), 2) { continue }
		testing.expect_value(t, c.tracks[0].codec, Codec.H264)
		testing.expect_value(t, len(c.samples[0]), 96)
		testing.expect(t, len(c.samples[1]) > 150, "audio frames")
		// continuous times across fragments
		for i in 1 ..< len(c.samples[0]) {
			if c.samples[0][i].dts <= c.samples[0][i - 1].dts { testing.fail_now(t, "dts not increasing") }
		}
	}
}

@(test)
mp4_audio_only :: proc(t: ^testing.T) {
	data := fixture("tone.m4a")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "tone.m4a missing") { return }
	c: Collected
	defer collected_free(&c)
	testing.expect_value(t, parse_mp4(data, 0, &c), Parse_Error.None)
	if !testing.expect_value(t, len(c.tracks), 1) { return }
	testing.expect_value(t, c.tracks[0].kind, Track_Kind.Audio)
	testing.expect(t, len(c.samples[0]) > 80, "frames")
}

@(test)
mp4_garbage_is_an_error_not_a_crash :: proc(t: ^testing.T) {
	data := fixture("clip.mp4")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.mp4 missing") { return }
	// every byte of the headers flipped in turn: never a crash (the result may be an error or odd samples)
	for i := 0; i < min(len(data), 3000); i += 1 {
		bad := make([]u8, len(data))
		defer delete(bad)
		copy(bad, data)
		bad[i] ~= 0xff
		c: Collected
		parse_mp4(bad, 0, &c)
		collected_free(&c)
	}
}

// ---- trex defaults when the mvex comes before the traks (DASH segmenters), sizes from the trex ----

@(private = "file")
put_be32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }

@(private = "file")
box_end :: proc(d: []u8, pos: int) -> int {
	return pos + int(u32(d[pos]) << 24 | u32(d[pos + 1]) << 16 | u32(d[pos + 2]) << 8 | u32(d[pos + 3]))
}

@(test)
mp4_mvex_before_the_traks_and_default_sample_size :: proc(t: ^testing.T) {
	src := fixture("clip_frag.mp4")
	defer delete(src)
	if !testing.expect(t, len(src) > 0, "clip_frag.mp4 missing") { return }
	// the top-level boxes: ftyp, moov
	moov := -1
	for p := 0; p + 8 <= len(src); p = box_end(src, p) {
		if string(src[p + 4:p + 8]) == "moov" { moov = p; break }
	}
	if !testing.expect(t, moov >= 0, "a moov box") { return }
	moov_end := box_end(src, moov)
	// moov with its mvex moved right after the mvhd, and the audio track's trex defaults: 6-byte samples of 1024 ticks
	var_children: [dynamic][]u8
	defer delete(var_children)
	mvex: []u8
	for p := moov + 8; p < moov_end; p = box_end(src, p) {
		e := box_end(src, p)
		if string(src[p + 4:p + 8]) == "mvex" { mvex = src[p:e] } else { append(&var_children, src[p:e]) }
	}
	if !testing.expect(t, len(mvex) > 0 && len(var_children) > 1, "mvex and the other children") { return }
	out: [dynamic]u8
	defer delete(out)
	append(&out, ..src[:moov])
	body: [dynamic]u8
	defer delete(body)
	append(&body, ..var_children[0])   // mvhd
	mv := make([]u8, len(mvex))
	defer delete(mv)
	copy(mv, mvex)
	for p := 8; p < len(mv); p = box_end(mv, p) {
		if string(mv[p + 4:p + 8]) != "trex" { continue }
		if u32(mv[p + 12]) << 24 | u32(mv[p + 13]) << 16 | u32(mv[p + 14]) << 8 | u32(mv[p + 15]) != 2 { continue }
		mv[p + 20], mv[p + 21], mv[p + 22], mv[p + 23] = 0, 0, 0x04, 0x00   // default_sample_duration 1024
		mv[p + 24], mv[p + 25], mv[p + 26], mv[p + 27] = 0, 0, 0, 6         // default_sample_size 6
	}
	append(&body, ..mv)
	for c in var_children[1:] { append(&body, ..c) }
	put_be32(&out, u32(8 + len(body)))
	append(&out, 'm', 'o', 'o', 'v')
	append(&out, ..body[:])
	// a fragment of the audio track alone: tfhd with default-base-is-moof only, a trun with a data offset only
	moof: [dynamic]u8
	defer delete(moof)
	put_be32(&moof, 84); append(&moof, 'm', 'o', 'o', 'f')
	put_be32(&moof, 16); append(&moof, 'm', 'f', 'h', 'd'); put_be32(&moof, 0); put_be32(&moof, 1)
	put_be32(&moof, 60); append(&moof, 't', 'r', 'a', 'f')
	put_be32(&moof, 16); append(&moof, 't', 'f', 'h', 'd'); put_be32(&moof, 0x020000); put_be32(&moof, 2)
	put_be32(&moof, 16); append(&moof, 't', 'f', 'd', 't'); put_be32(&moof, 0); put_be32(&moof, 0)
	put_be32(&moof, 20); append(&moof, 't', 'r', 'u', 'n'); put_be32(&moof, 1); put_be32(&moof, 3); put_be32(&moof, 92)
	append(&out, ..moof[:])
	put_be32(&out, 8 + 18); append(&out, 'm', 'd', 'a', 't')
	for i in 0 ..< 18 { append(&out, u8(i)) }

	c: Collected
	defer collected_free(&c)
	testing.expect_value(t, parse_mp4(out[:], 0, &c), Parse_Error.None)
	if !testing.expect_value(t, len(c.tracks), 2) { return }
	ai := c.tracks[0].kind == .Audio ? 0 : 1
	if !testing.expect_value(t, len(c.samples[ai]), 3) { return }
	for s, i in c.samples[ai] {
		testing.expect_value(t, len(s.data), 6)
		testing.expect_value(t, s.data[0], u8(i * 6))
		testing.expect_value(t, s.duration, time_from_ticks(1024, c.tracks[ai].timescale))
	}
}
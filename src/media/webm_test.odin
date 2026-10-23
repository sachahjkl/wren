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

// ---- keyframes, live streams, Media Source Extensions segments, VP8, Opus only ----

@(test)
webm_simpleblock_keyframe_flag_is_read :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	c: Collected
	defer collected_free(&c)
	testing.expect_value(t, parse_webm(data, 0, &c), Parse_Error.None)
	if !testing.expect(t, len(c.samples) > 0) { return }
	keys := 0
	for s in c.samples[0] { if .Keyframe in s.flags { keys += 1 } }
	// one keyframe a second (-g 24) in 4 s: not every frame
	testing.expect(t, keys >= 2 && keys <= 8, "keyframes among the 96 frames")
	testing.expect(t, .Keyframe not_in c.samples[0][1].flags, "the second frame is not a keyframe")
}

@(test)
webm_live_stream_unknown_sizes :: proc(t: ^testing.T) {
	whole := fixture("clip.webm")
	live := fixture("clip_live.webm")
	defer delete(whole)
	defer delete(live)
	if !testing.expect(t, len(whole) > 0 && len(live) > 0, "fixtures missing") { return }
	a, b: Collected
	defer collected_free(&a)
	defer collected_free(&b)
	testing.expect_value(t, parse_webm(whole, 0, &a), Parse_Error.None)
	testing.expect_value(t, parse_webm(live, 7, &b), Parse_Error.None)
	if !testing.expect_value(t, len(b.samples), len(a.samples)) { return }
	for tr in 0 ..< len(a.samples) {
		if !testing.expect_value(t, len(b.samples[tr]), len(a.samples[tr])) { continue }
		for i in 0 ..< len(a.samples[tr]) {
			if a.samples[tr][i].pts != b.samples[tr][i].pts || (.Keyframe in a.samples[tr][i].flags) != (.Keyframe in b.samples[tr][i].flags) {
				testing.expectf(t, false, "track %d sample %d differs", tr, i)
				break
			}
		}
	}
}

// Where the first Cluster starts: what comes before is an initialization segment, the rest media segments.
@(private = "file")
first_cluster :: proc(data: []u8) -> int {
	for i in 0 ..< len(data) - 4 {
		if data[i] == 0x1F && data[i + 1] == 0x43 && data[i + 2] == 0xB6 && data[i + 3] == 0x75 { return i }
	}
	return -1
}

@(test)
webm_mse_initialization_then_media_segments :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	cut := first_cluster(data)
	if !testing.expect(t, cut > 0, "a Cluster") { return }
	whole: Collected
	defer collected_free(&whole)
	testing.expect_value(t, parse_webm(data, 0, &whole), Parse_Error.None)

	d: Webm_Demuxer
	c: Collected
	webm_init(&d, collector(&c))
	defer webm_destroy(&d)
	defer collected_free(&c)
	testing.expect_value(t, webm_feed(&d, data[:cut]), Parse_Error.None)
	testing.expect_value(t, c.inits, 1)
	testing.expect_value(t, len(c.samples[0]), 0)
	// the media in two pieces cut inside a block, an abort() between them is a new segment boundary only when asked
	mid := cut + (len(data) - cut) / 2
	testing.expect_value(t, webm_feed(&d, data[cut:mid]), Parse_Error.None)
	testing.expect_value(t, webm_feed(&d, data[mid:]), Parse_Error.None)
	testing.expect_value(t, len(c.samples[0]), len(whole.samples[0]))
	// the initialization segment again (a quality switch, a new SourceBuffer round): a second configuration
	testing.expect_value(t, webm_feed(&d, data[:cut]), Parse_Error.None)
	testing.expect_value(t, c.inits, 2)
	n := len(c.samples[0])
	testing.expect_value(t, webm_feed(&d, data[cut:]), Parse_Error.None)
	testing.expect_value(t, len(c.samples[0]), n + len(whole.samples[0]))
	testing.expect_value(t, c.samples[0][n].config, u32(2))
	testing.expect_value(t, c.samples[0][0].config, u32(1))
	// abort(): the parser forgets a half-read element and starts at a boundary
	webm_reset_parser(&d)
	testing.expect_value(t, webm_feed(&d, data[cut:cut + 100]), Parse_Error.None)
	webm_reset_parser(&d)
	m := len(c.samples[0])
	testing.expect_value(t, webm_feed(&d, data[cut:]), Parse_Error.None)
	testing.expect_value(t, len(c.samples[0]), m + len(whole.samples[0]))
}

@(test)
webm_vp8_and_opus_only :: proc(t: ^testing.T) {
	v8 := fixture("clip_vp8.webm")
	op := fixture("tone_opus.webm")
	defer delete(v8)
	defer delete(op)
	if !testing.expect(t, len(v8) > 0 && len(op) > 0, "fixtures missing") { return }
	a, b: Collected
	defer collected_free(&a)
	defer collected_free(&b)
	testing.expect_value(t, parse_webm(v8, 0, &a), Parse_Error.None)
	if testing.expect_value(t, len(a.tracks), 1) {
		testing.expect_value(t, a.tracks[0].codec, Codec.VP8)
		testing.expect_value(t, a.tracks[0].width, 160)
		testing.expect_value(t, a.tracks[0].height, 90)
		testing.expect_value(t, len(a.samples[0]), 24)
	}
	testing.expect_value(t, parse_webm(op, 0, &b), Parse_Error.None)
	if testing.expect_value(t, len(b.tracks), 1) {
		testing.expect_value(t, b.tracks[0].kind, Track_Kind.Audio)
		testing.expect_value(t, b.tracks[0].codec, Codec.Opus)
		testing.expect(t, len(b.samples[0]) > 150, "packets")
		for s in b.samples[0] { if .Keyframe not_in s.flags { testing.fail_now(t, "every Opus packet starts a decode") } }
	}
}

// ---- built in the test: lacing, BlockGroups, unknown sizes ----

@(private = "file")
put_id :: proc(b: ^[dynamic]u8, id: u32) {
	switch {
	case id > 0xFFFFFF: append(b, u8(id >> 24), u8(id >> 16), u8(id >> 8), u8(id))
	case id > 0xFFFF: append(b, u8(id >> 16), u8(id >> 8), u8(id))
	case id > 0xFF: append(b, u8(id >> 8), u8(id))
	case: append(b, u8(id))
	}
}

// A master or leaf element with an 8-byte size (or the unknown size).
@(private = "file")
element :: proc(id: u32, payload: []u8, unknown := false) -> [dynamic]u8 {
	out: [dynamic]u8
	put_id(&out, id)
	n := u64(len(payload))
	if unknown { append(&out, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff) } else {
		append(&out, 0x01, u8(n >> 48), u8(n >> 40), u8(n >> 32), u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	}
	append(&out, ..payload)
	return out
}

@(private = "file")
uint_element :: proc(id: u32, v: u64) -> [dynamic]u8 {
	p := []u8{u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
	return element(id, p)
}

@(private = "file")
cat :: proc(parts: ..[dynamic]u8) -> [dynamic]u8 {
	out: [dynamic]u8
	for &p in parts { append(&out, ..p[:]); delete(p) }
	return out
}

// Info (1 ms scale) and Tracks (1: video VP9, 2: audio Opus without a default duration).
@(private = "file")
synthetic_header :: proc() -> [dynamic]u8 {
	info := cat(uint_element(0x2AD7B1, 1_000_000))
	v := cat(uint_element(0xB0, 64), uint_element(0xBA, 48))
	a := cat(element(0xB5, []u8{0x40, 0xE7, 0x70, 0, 0, 0, 0, 0}), uint_element(0x9F, 2))
	head: [dynamic]u8
	append(&head, 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0)
	t1 := cat(uint_element(0xD7, 1), uint_element(0x83, 1), element(0x86, transmute([]u8)string("V_VP9")), element(0xE0, v[:]))
	t2 := cat(uint_element(0xD7, 2), uint_element(0x83, 2), element(0x86, transmute([]u8)string("A_OPUS")), element(0x63A2, head[:]), element(0xE1, a[:]))
	tracks := cat(element(0xAE, t1[:]), element(0xAE, t2[:]))
	out := cat(element(0x1549A966, info[:]), element(0x1654AE6B, tracks[:]))
	delete(v); delete(a); delete(head); delete(t1); delete(t2); delete(tracks); delete(info)
	return out
}

@(test)
webm_lacing_blockgroups_and_unknown_sizes :: proc(t: ^testing.T) {
	// three Opus packets in one Xiph laced block (TOC 0xFC: CELT 20 ms, one frame), then an EBML laced one, then fixed
	pkt :: proc(n: int) -> []u8 {
		p := make([]u8, n, context.temp_allocator)
		p[0] = 0xFC
		return p
	}
	body: [dynamic]u8
	defer delete(body)
	// track 2, timecode +0, flags: Xiph lacing (bit 1)
	append(&body, 0x82, 0, 0, 0x02, 2, 3, 4)   // 3 frames: sizes 3, 4, then the rest
	append(&body, ..pkt(3)); append(&body, ..pkt(4)); append(&body, ..pkt(5))
	xiph := cat(element(0xA3, body[:]))

	eb: [dynamic]u8
	defer delete(eb)
	// timecode +60, EBML lacing: 3 frames, first size 3 (0x83), then a signed delta of +1 (0xC0 | 63 + 1 = 0xC0)
	append(&eb, 0x82, 0, 60, 0x06, 2, 0x83, 0xC0)
	append(&eb, ..pkt(3)); append(&eb, ..pkt(4)); append(&eb, ..pkt(5))
	ebml := cat(element(0xA3, eb[:]))

	fx: [dynamic]u8
	defer delete(fx)
	append(&fx, 0x82, 0, 120, 0x04, 1)   // fixed-size lacing, 2 frames
	append(&fx, ..pkt(4)); append(&fx, ..pkt(4))
	fixed := cat(element(0xA3, fx[:]))

	// a video SimpleBlock (key), a BlockGroup (a P frame: with a reference, duration after BlockAdditions), a key frame group
	vb := []u8{0x81, 0, 0, 0x80, 1, 2, 3}
	vkey := cat(element(0xA3, vb))
	pblock := []u8{0x81, 0, 40, 0x00, 9, 9}
	g1inner := cat(element(0xA1, pblock), element(0x75A1, []u8{0x01}), uint_element(0x9B, 40), element(0xFB, []u8{0xFF}))
	g1 := cat(element(0xA0, g1inner[:]))
	kblock := []u8{0x81, 0, 80, 0x00, 7, 7, 7}
	g2inner := cat(element(0xA1, kblock), uint_element(0x9B, 40))
	g2 := cat(element(0xA0, g2inner[:]))

	cluster_payload := cat(uint_element(0xE7, 1000), vkey, xiph, ebml, fixed, g1, g2)
	cluster := cat(element(0x1F43B675, cluster_payload[:], true))   // unknown size
	header := synthetic_header()
	seg_payload := cat(header, cluster)
	segment := cat(element(0x18538067, seg_payload[:], true))
	defer delete(segment)
	delete(g1inner); delete(g2inner); delete(cluster_payload); delete(seg_payload)

	for step in ([?]int{0, 1, 3, 11}) {
		c: Collected
		defer collected_free(&c)
		testing.expect_value(t, parse_webm(segment[:], step, &c), Parse_Error.None)
		if !testing.expect_value(t, len(c.tracks), 2) { return }
		vs, as := c.samples[0], c.samples[1]
		if !testing.expect_value(t, len(vs), 3) { return }
		testing.expect(t, .Keyframe in vs[0].flags, "SimpleBlock with the keyframe flag")
		testing.expect(t, .Keyframe not_in vs[1].flags, "a group with a reference is not a keyframe")
		testing.expect(t, .Keyframe in vs[2].flags, "a group with no reference is")
		testing.expect_value(t, vs[1].duration, Time(40_000_000))   // BlockDuration came after BlockAdditions
		testing.expect_value(t, vs[1].pts, Time(1040) * 1_000_000)
		testing.expect_value(t, vs[2].pts, Time(1080) * 1_000_000)
		// 3 + 3 + 2 laced packets, each 20 ms by its TOC, one after the other
		if !testing.expect_value(t, len(as), 8) { return }
		for i in 0 ..< len(as) { testing.expect_value(t, as[i].duration, Time(20_000_000)) }
		testing.expect_value(t, as[0].pts, Time(1000) * 1_000_000)
		testing.expect_value(t, as[1].pts, Time(1020) * 1_000_000)
		testing.expect_value(t, as[2].pts, Time(1040) * 1_000_000)
		testing.expect_value(t, as[3].pts, Time(1060) * 1_000_000)
		testing.expect_value(t, len(as[0].data), 3)
		testing.expect_value(t, len(as[1].data), 4)
		testing.expect_value(t, len(as[2].data), 5)
		testing.expect_value(t, len(as[3].data), 3)
		testing.expect_value(t, len(as[4].data), 4)
		testing.expect_value(t, len(as[5].data), 5)
		testing.expect_value(t, len(as[6].data), 4)
		testing.expect_value(t, as[6].pts, Time(1120) * 1_000_000)
	}
}

@(test)
webm_opus_packet_durations :: proc(t: ^testing.T) {
	testing.expect_value(t, opus_packet_duration([]u8{0xFC}), Time(20_000_000))        // CELT 20 ms, 1 frame
	testing.expect_value(t, opus_packet_duration([]u8{0xFD}), Time(40_000_000))        // two frames
	testing.expect_value(t, opus_packet_duration([]u8{0xFB, 3}), Time(60_000_000))     // code 3: three 20 ms frames
	testing.expect_value(t, opus_packet_duration([]u8{0x08}), Time(20_000_000))    // SILK config 1: 20 ms
	testing.expect_value(t, opus_packet_duration([]u8{0x80}), Time(2_500_000))     // CELT 2.5 ms
	testing.expect_value(t, opus_packet_duration([]u8{}), Time(0))
}
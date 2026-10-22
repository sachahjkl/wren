package media

// WebM / Matroska: an incremental parser, bytes in any split. Like mp4.odin it reports the tracks (Info + Tracks) and every
// coded frame once complete. The elements it reads whole (Info, Tracks, blocks) are buffered; Segment, Cluster and
// BlockGroup are entered (their sizes may be unknown: live streams, Media Source Extensions segments, which carry
// clusters with no Segment around them); everything else is skipped without being kept.

import "wb:base"
import "core:strings"

Webm_Limits :: struct {
	max_element_bytes: int,   // the largest element read whole (a block, Tracks)
}

WEBM_LIMITS_DEFAULT :: Webm_Limits{max_element_bytes = 128 << 20}

@(private = "file")
EBML_ID :: enum u32 {
	Segment = 0x18538067, Info = 0x1549A966, Tracks = 0x1654AE6B, Cluster = 0x1F43B675,
	Timecode_Scale = 0x2AD7B1, Duration = 0x4489,
	Track_Entry = 0xAE, Track_Number = 0xD7, Track_Type = 0x83, Codec_Id = 0x86, Codec_Private = 0x63A2,
	Codec_Delay = 0x56AA, Seek_Pre_Roll = 0x56BB, Default_Duration = 0x23E383, Language = 0x22B59C,
	Video = 0xE0, Pixel_Width = 0xB0, Pixel_Height = 0xBA, Display_Width = 0x54B0, Display_Height = 0x54BA,
	Colour = 0x55B0, Matrix_Coefficients = 0x55B1, Bits_Per_Channel = 0x55B2, Range = 0x55B9, Transfer = 0x55BA, Primaries = 0x55BB,
	Audio = 0xE1, Sampling_Frequency = 0xB5, Channels = 0x9F, Bit_Depth = 0x6264,
	Content_Encodings = 0x6D80,
	Cluster_Timecode = 0xE7, Simple_Block = 0xA3, Block_Group = 0xA0, Block = 0xA1, Block_Duration = 0x9B,
	Reference_Block = 0xFB, Discard_Padding = 0x75A2,
	// children of a BlockGroup this parser has no use for (they must not end the group before its Block_Duration)
	Block_Additions = 0x75A1, Reference_Priority = 0xFA, Reference_Virtual = 0xFD, Codec_State = 0xA4, Slices = 0x8E, Block_Virtual = 0xA2,
}

@(private = "file")
Webm_Track :: struct {
	info:   Track,
	number: u64,
}

@(private = "file")
Block_Pending :: struct {
	active: bool,
	data:   []u8,    // the Block element's payload (owned)
	cluster_tc: i64,
	duration: i64,   // timecode units, -1: unknown
	has_ref: bool,
	discard: i64,    // ns
}

Webm_State :: enum u8 { Header, Collect, Skip }

Webm_Demuxer :: struct {
	sink:      Demux_Sink,
	limits:    Webm_Limits,
	tracks:    [dynamic]Webm_Track,
	scale:     i64,             // ns per timecode unit
	duration:  Time,
	config:    u32,
	cluster_tc: i64,
	state:     Webm_State,
	hdr:       [12]u8,
	hdr_len:   int,
	id:        u32,
	size:      u64,             // payload size (max(u64): unknown)
	buf:       [dynamic]u8,     // the element being collected (payload only)
	skip_left: u64,
	group:     Block_Pending,
	group_end: u64,             // absolute end of the BlockGroup being read (0: unknown)
	pos:       u64,
	error:     Parse_Error,
	tracks_seen: bool,
}

webm_init :: proc(d: ^Webm_Demuxer, sink: Demux_Sink, limits := WEBM_LIMITS_DEFAULT) {
	d^ = {}
	d.sink = sink
	d.limits = limits
	d.scale = 1_000_000
}

webm_destroy :: proc(d: ^Webm_Demuxer) {
	for &t in d.tracks { track_destroy(&t.info) }
	delete(d.tracks)
	delete(d.buf)
	delete(d.group.data, base.process_allocator())
	d^ = {}
}

// Forgets a half-read element (abort() of a SourceBuffer); the tracks stay.
webm_reset_parser :: proc(d: ^Webm_Demuxer) {
	d.state = .Header
	d.hdr_len = 0
	clear(&d.buf)
	delete(d.group.data, base.process_allocator())
	d.group = {}
	d.group_end = 0
	d.error = .None
}

// EBML variable-length integers. Returns the length in bytes (0: not enough bytes / invalid).
@(private = "file")
vint_len :: proc(first: u8) -> int {
	for i in 0 ..< 8 { if first & (0x80 >> u8(i)) != 0 { return i + 1 } }
	return 0
}

@(private = "file")
read_size :: proc(b: []u8) -> (v: u64, n: int, unknown: bool) {
	if len(b) == 0 { return }
	n = vint_len(b[0])
	if n == 0 || n > len(b) { return 0, 0, false }
	v = u64(b[0]) & (0xff >> u8(n))
	all_ones := v == u64(0xff >> u8(n))
	for i in 1 ..< n {
		v = v << 8 | u64(b[i])
		if b[i] != 0xff { all_ones = false }
	}
	return v, n, all_ones
}

@(private = "file")
is_master_entered :: proc(id: u32) -> bool {
	#partial switch EBML_ID(id) {
	case .Segment, .Cluster, .Block_Group: return true
	}
	return false
}

@(private = "file")
is_collected :: proc(id: u32) -> bool {
	#partial switch EBML_ID(id) {
	case .Info, .Tracks, .Cluster_Timecode, .Simple_Block, .Block, .Block_Duration, .Discard_Padding, .Reference_Block: return true
	}
	return false
}

webm_feed :: proc(d: ^Webm_Demuxer, data: []u8) -> Parse_Error {
	if d.error != .None { return d.error }
	rest := data
	for len(rest) > 0 && d.error == .None {
		switch d.state {
		case .Header:
			// the ID is 1-4 bytes, the size 1-8: gather bytes until both are complete
			n := min(len(rest), len(d.hdr) - d.hdr_len)
			copy(d.hdr[d.hdr_len:], rest[:n])
			d.hdr_len += n
			rest = rest[n:]
			d.pos += u64(n)
			idl := vint_len(d.hdr[0])
			if idl == 0 || idl > 4 {
				// not an element ID: garbage
				d.error = .Malformed
				return d.error
			}
			if d.hdr_len < idl + 1 { continue }
			szl := vint_len(d.hdr[idl])
			if szl == 0 { d.error = .Malformed; return d.error }
			if d.hdr_len < idl + szl { continue }
			used := idl + szl
			extra := d.hdr_len - used
			if extra > 0 {
				rest = data[len(data) - len(rest) - extra:]
				d.pos -= u64(extra)
			}
			id: u32
			for i in 0 ..< idl { id = id << 8 | u32(d.hdr[i]) }
			size, _, unknown := read_size(d.hdr[idl:used])
			d.id = id
			d.size = unknown ? max(u64) : size
			d.hdr_len = 0
			webm_element(d)
		case .Skip:
			n := min(u64(len(rest)), d.skip_left)
			rest = rest[n:]
			d.pos += n
			d.skip_left -= n
			if d.skip_left == 0 { d.state = .Header; webm_check_group_end(d) }
		case .Collect:
			want := int(d.size) - len(d.buf)
			n := min(len(rest), want)
			append(&d.buf, ..rest[:n])
			rest = rest[n:]
			d.pos += u64(n)
			if len(d.buf) == int(d.size) {
				webm_collected(d)
				clear(&d.buf)
				d.state = .Header
				webm_check_group_end(d)
			}
		}
	}
	return d.error
}

// An element header was read: enter, collect or skip it.
@(private = "file")
webm_element :: proc(d: ^Webm_Demuxer) {
	// a BlockGroup's Block waits for the rest of its group: anything that is not part of one ends it
	if d.group.active {
		#partial switch EBML_ID(d.id) {
		case .Block, .Block_Duration, .Reference_Block, .Discard_Padding, .Block_Additions, .Reference_Priority, .Reference_Virtual, .Codec_State, .Slices, .Block_Virtual:
		case: webm_emit_group(d)
		}
	}
	if is_master_entered(d.id) {
		d.state = .Header
		if EBML_ID(d.id) == .Block_Group { d.group_end = d.size == max(u64) ? 0 : d.pos + d.size }
		return
	}
	if is_collected(d.id) {
		if d.size == max(u64) || d.size > u64(d.limits.max_element_bytes) { d.error = .Too_Large; return }
		if d.size == 0 { webm_collected(d); return }
		d.state = .Collect
		clear(&d.buf)
		return
	}
	if d.size == max(u64) { d.error = .Unsupported; return }   // an unknown-size element we cannot enter
	if d.size == 0 { return }
	d.state = .Skip
	d.skip_left = d.size
}

@(private = "file")
read_uint :: proc(b: []u8) -> u64 {
	v: u64
	for x in b[:min(len(b), 8)] { v = v << 8 | u64(x) }
	return v
}

@(private = "file")
read_float :: proc(b: []u8) -> f64 {
	switch len(b) {
	case 4: return f64(transmute(f32)u32(read_uint(b)))
	case 8: return transmute(f64)read_uint(b)
	}
	return 0
}

@(private = "file")
read_sint :: proc(b: []u8) -> i64 {
	if len(b) == 0 { return 0 }
	v := i64(i8(b[0]))
	for x in b[1:min(len(b), 8)] { v = v << 8 | i64(x) }
	return v
}

@(private = "file")
webm_collected :: proc(d: ^Webm_Demuxer) {
	b := d.buf[:]
	#partial switch EBML_ID(d.id) {
	case .Info: webm_info(d, b)
	case .Tracks: webm_tracks(d, b)
	case .Cluster_Timecode: d.cluster_tc = i64(read_uint(b))
	case .Simple_Block:
		// the keyframe flag is the top bit of the block's flags byte (after the track number and the 16-bit timecode)
		_, nl, _ := read_size(b)
		key := nl > 0 && len(b) > nl + 2 && b[nl + 2] & 0x80 != 0
		webm_block(d, b, key, d.cluster_tc, -1, false, 0)
	case .Block:
		// the rest of the group (duration, references) follows: emitted when the group ends
		delete(d.group.data, base.process_allocator())
		d.group = Block_Pending{active = true, data = clone_bytes(b, base.process_allocator()), cluster_tc = d.cluster_tc, duration = -1}
	case .Block_Duration: if d.group.active { d.group.duration = i64(read_uint(b)) }
	case .Reference_Block: if d.group.active { d.group.has_ref = true }
	case .Discard_Padding: if d.group.active { d.group.discard = read_sint(b) }
	}
}

// A BlockGroup of known size is complete when its last byte went by: its block is emitted then, not at the next element.
@(private = "file")
webm_check_group_end :: proc(d: ^Webm_Demuxer) {
	if d.group.active && d.group_end != 0 && d.pos >= d.group_end { webm_emit_group(d) }
}

@(private = "file")
webm_emit_group :: proc(d: ^Webm_Demuxer) {
	g := d.group
	d.group = {}
	d.group_end = 0
	if g.data != nil {
		webm_block(d, g.data, !g.has_ref, g.cluster_tc, g.duration, true, g.discard)
		delete(g.data, base.process_allocator())
	}
}

@(private = "file")
webm_info :: proc(d: ^Webm_Demuxer, b: []u8) {
	pos := 0
	dur: f64
	for pos < len(b) {
		id, size, n, ok := element_at(b, pos)
		if !ok { break }
		payload := b[pos + n:][:size]
		#partial switch EBML_ID(id) {
		case .Timecode_Scale: d.scale = max(i64(read_uint(payload)), 1)
		case .Duration: dur = read_float(payload)
		}
		pos += n + int(size)
	}
	d.duration = Time(dur * f64(d.scale))
}

// One element inside a buffered master: (id, payload size, header length).
@(private = "file")
element_at :: proc(b: []u8, pos: int) -> (id: u32, size: u64, hdr: int, ok: bool) {
	if pos >= len(b) { return }
	idl := vint_len(b[pos])
	if idl == 0 || idl > 4 || pos + idl >= len(b) { return }
	for i in 0 ..< idl { id = id << 8 | u32(b[pos + i]) }
	sz, szl, unknown := read_size(b[pos + idl:])
	if szl == 0 || unknown { return }
	hdr = idl + szl
	if sz > u64(len(b) - pos - hdr) { return }
	return id, sz, hdr, true
}

@(private = "file")
webm_tracks :: proc(d: ^Webm_Demuxer, b: []u8) {
	for &t in d.tracks { track_destroy(&t.info) }
	clear(&d.tracks)
	d.config += 1
	pos := 0
	for pos < len(b) {
		id, size, n, ok := element_at(b, pos)
		if !ok { break }
		if EBML_ID(id) == .Track_Entry {
			t: Webm_Track
			t.info.timescale = 1_000_000_000
			if webm_track_entry(d, b[pos + n:][:size], &t) { append(&d.tracks, t) } else { track_destroy(&t.info) }
		}
		pos += n + int(size)
	}
	d.tracks_seen = true
	infos := make([]Track, len(d.tracks), context.temp_allocator)
	for &t, i in d.tracks { infos[i] = t.info }
	if d.sink.tracks != nil { d.sink.tracks(d.sink.user, infos, d.duration) }
}

@(private = "file")
webm_track_entry :: proc(d: ^Webm_Demuxer, b: []u8, t: ^Webm_Track) -> bool {
	heap := base.process_allocator()
	info := &t.info
	codec_id: string
	ttype: u64
	pos := 0
	for pos < len(b) {
		id, size, n, ok := element_at(b, pos)
		if !ok { break }
		p := b[pos + n:][:size]
		#partial switch EBML_ID(id) {
		case .Track_Number: t.number = read_uint(p)
		case .Track_Type: ttype = read_uint(p)
		case .Codec_Id: codec_id = strings.clone(string(p), context.temp_allocator)
		case .Codec_Private: info.config = clone_bytes(p, heap)
		case .Codec_Delay: info.codec_delay = Time(read_uint(p))
		case .Seek_Pre_Roll: info.seek_preroll = Time(read_uint(p))
		case .Default_Duration: info.default_duration = Time(read_uint(p))
		case .Language: info.language = strings.clone(string(p), heap)
		case .Content_Encodings: return false   // compression or encryption: unsupported
		case .Video:
			info.kind = .Video
			webm_video(p, info)
		case .Audio:
			webm_audio(p, info)
		}
		pos += n + int(size)
	}
	info.id = u32(t.number)
	switch ttype {
	case 1: info.kind = .Video
	case 2: info.kind = .Audio
	case: info.kind = .Other
	}
	switch codec_id {
	case "V_VP8": info.codec, info.codec_string = .VP8, strings.clone("vp8", heap)
	case "V_VP9": info.codec, info.codec_string = .VP9, strings.clone("vp09", heap)
	case "V_AV1": info.codec, info.codec_string = .AV1, strings.clone("av01", heap)
	case "V_MPEG4/ISO/AVC":
		info.codec = .H264
		info.codec_string = strings.clone("avc1", heap)
		if len(info.config) >= 5 { info.nal_length_size = int(info.config[4] & 3) + 1 }
	case "V_MPEGH/ISO/HEVC":
		info.codec = .HEVC
		info.codec_string = strings.clone("hvc1", heap)
		if len(info.config) >= 22 { info.nal_length_size = int(info.config[21] & 3) + 1 }
	case "A_OPUS":
		info.codec, info.codec_string = .Opus, strings.clone("opus", heap)
		// OpusHead: version, channels, pre-skip, input rate
		if len(info.config) >= 12 && string(info.config[:8]) == "OpusHead" {
			if info.channels == 0 { info.channels = int(info.config[9]) }
			if info.codec_delay == 0 { info.codec_delay = time_from_ticks(i64(le16(info.config, 10)), 48000) }
		}
		info.sample_rate = 48000
	case "A_VORBIS": info.codec, info.codec_string = .Vorbis, strings.clone("vorbis", heap)
	case "A_FLAC": info.codec, info.codec_string = .FLAC, strings.clone("flac", heap)
	case "A_MPEG/L3", "A_MPEG/L2": info.codec, info.codec_string = .MP3, strings.clone("mp3", heap)
	case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC": info.codec, info.codec_string = .AAC, strings.clone("mp4a.40.2", heap)
	case "A_PCM/INT/LIT": info.codec, info.codec_string = .PCM, strings.clone("pcm", heap)
	}
	if info.display_width == 0 { info.display_width, info.display_height = info.width, info.height }
	return t.number != 0
}

@(private = "file")
webm_video :: proc(b: []u8, info: ^Track) {
	pos := 0
	for pos < len(b) {
		id, size, n, ok := element_at(b, pos)
		if !ok { break }
		p := b[pos + n:][:size]
		#partial switch EBML_ID(id) {
		case .Pixel_Width: info.width = int(read_uint(p))
		case .Pixel_Height: info.height = int(read_uint(p))
		case .Display_Width: info.display_width = int(read_uint(p))
		case .Display_Height: info.display_height = int(read_uint(p))
		case .Colour:
			c := 0
			for c < len(p) {
				cid, csize, cn, cok := element_at(p, c)
				if !cok { break }
				cp := p[c + cn:][:csize]
				info.color.known = true
				#partial switch EBML_ID(cid) {
				case .Matrix_Coefficients: info.color.coeffs = h273_matrix(u8(read_uint(cp)))
				case .Transfer: info.color.transfer = h273_transfer(u8(read_uint(cp)))
				case .Primaries: info.color.primaries = u8(read_uint(cp))
				case .Range: info.color.full_range = read_uint(cp) == 2
				case .Bits_Per_Channel: info.bit_depth = int(read_uint(cp))
				}
				c += cn + int(csize)
			}
		}
		pos += n + int(size)
	}
}

@(private = "file")
webm_audio :: proc(b: []u8, info: ^Track) {
	pos := 0
	for pos < len(b) {
		id, size, n, ok := element_at(b, pos)
		if !ok { break }
		p := b[pos + n:][:size]
		#partial switch EBML_ID(id) {
		case .Sampling_Frequency: info.sample_rate = int(read_float(p))
		case .Channels: info.channels = int(read_uint(p))
		case .Bit_Depth: info.bit_depth = int(read_uint(p))
		}
		pos += n + int(size)
	}
}

// The duration of an Opus packet from its table of contents (RFC 6716 section 3.1); 0 when it is too short to say.
opus_packet_duration :: proc(p: []u8) -> Time {
	if len(p) < 1 { return 0 }
	config := int(p[0] >> 3)
	silk := [4]int{10000, 20000, 40000, 60000}
	celt := [4]int{2500, 5000, 10000, 20000}
	frame_us: int   // microseconds
	switch {
	case config < 12: frame_us = silk[config & 3]
	case config < 16: frame_us = config & 1 == 0 ? 10000 : 20000
	case: frame_us = celt[config & 3]
	}
	count := 1
	switch p[0] & 3 {
	case 1, 2: count = 2
	case 3:
		if len(p) < 2 { return 0 }
		count = int(p[1] & 0x3f)
	}
	return Time(frame_us * count) * 1000
}

// A Block or SimpleBlock payload: track number, relative timecode, flags, then the (laced) frames.
@(private = "file")
webm_block :: proc(d: ^Webm_Demuxer, b: []u8, keyframe: bool, cluster_tc: i64, duration: i64, is_group: bool, discard_ns: i64) {
	number, nl, _ := read_size(b)
	if nl == 0 || len(b) < nl + 3 { return }
	ti := -1
	for &t, i in d.tracks { if t.number == number { ti = i; break } }
	if ti < 0 || d.tracks[ti].info.kind == .Other { return }
	tr := &d.tracks[ti]
	rel := i64(i16(u16(b[nl]) << 8 | u16(b[nl + 1])))
	flags := b[nl + 2]
	body := b[nl + 3:]
	pts := Time((cluster_tc + rel) * d.scale)
	dur := tr.info.default_duration
	if duration >= 0 { dur = Time(duration * d.scale) }
	lacing := (flags >> 1) & 3
	frames: [dynamic][]u8
	defer delete(frames)
	if lacing == 0 {
		append(&frames, body)
	} else {
		if len(body) < 1 { return }
		count := int(body[0]) + 1
		p := 1
		sizes := make([]int, count, context.temp_allocator)
		switch lacing {
		case 1:   // Xiph
			total := 0
			for i in 0 ..< count - 1 {
				s := 0
				for p < len(body) {
					v := int(body[p])
					p += 1
					s += v
					if v != 255 { break }
				}
				sizes[i] = s
				total += s
			}
			sizes[count - 1] = len(body) - p - total
		case 3:   // EBML
			first, fl, _ := read_size(body[p:])
			if fl == 0 { return }
			p += fl
			sizes[0] = int(first)
			total := sizes[0]
			for i in 1 ..< count - 1 {
				v, vl, _ := read_size(body[p:])
				if vl == 0 { return }
				p += vl
				bias := (i64(1) << u8(7 * vl - 1)) - 1
				sizes[i] = sizes[i - 1] + int(i64(v) - bias)
				total += sizes[i]
			}
			sizes[count - 1] = len(body) - p - total
		case 2:   // fixed size
			each := (len(body) - 1) / count
			for i in 0 ..< count { sizes[i] = each }
		}
		for s in sizes {
			if s < 0 || p + s > len(body) { return }
			append(&frames, body[p:p + s])
			p += s
		}
	}
	each_dur := dur
	if len(frames) > 1 && duration >= 0 { each_dur = dur / Time(len(frames)) }
	t := pts
	for f, i in frames {
		if len(f) == 0 { continue }
		heap := base.process_allocator()
		data := make([]u8, len(f), heap)
		copy(data, f)
		// a laced block of frames with no duration given: Opus says how long each packet is, so they do not share one time
		fd := each_dur
		if fd == 0 && len(frames) > 1 && tr.info.codec == .Opus { fd = opus_packet_duration(f) }
		s := Sample{dts = t, pts = t, duration = fd, config = d.config, data = data}
		if keyframe && i == 0 || tr.info.kind == .Audio { s.flags += {.Keyframe} }
		if t + fd <= 0 && fd > 0 { s.flags += {.Pre_Roll} }
		if i == len(frames) - 1 && discard_ns > 0 { s.discard_end = Time(discard_ns) }
		if d.sink.sample != nil { d.sink.sample(d.sink.user, ti, s) } else { delete(data, heap) }
		t += fd
	}
	_ = is_group
}

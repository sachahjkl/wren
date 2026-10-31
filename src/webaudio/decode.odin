package webaudio

// decodeAudioData: a whole file in memory becomes planar audio at the context's rate. MP4 and WebM go through the demuxers
// of src/media; the formats that have none there (WAV, MP3, ADTS AAC, FLAC, Ogg) are cut into packets here. The packets go
// to the decoders of src/media (Media Foundation on Windows, Symphonia and libopus elsewhere); WAV needs no decoder.
// A blocking thread runs this.

import "core:math"
import "wb:media"

// Conversion of rates: a windowed sinc, half-width in zero crossings, and how finely its table is cut between two frames.
RESAMPLE_HALF_WIDTH :: 16
RESAMPLE_PHASES :: 512

@(private = "file")
Collector :: struct {
	tracks:   [dynamic]media.Track,
	samples:  [dynamic]media.Sample,
	track:    int,                     // the audio track kept (-1: none yet)
	duration: media.Time,
	rate:     f64,                     // the rate wanted in the end
	max_bytes: int,                    // and the most samples that may make, in bytes
}

@(private = "file")
collector_destroy :: proc(c: ^Collector) {
	for &t in c.tracks { media.track_destroy(&t) }
	delete(c.tracks)
	for &s in c.samples { media.sample_destroy(&s) }
	delete(c.samples)
}

@(private = "file")
sink_tracks :: proc(user: rawptr, tracks: []media.Track, duration: media.Time) {
	context.allocator = alloc()
	c := (^Collector)(user)
	if len(c.tracks) > 0 { return }
	c.duration = duration
	for t, i in tracks {
		append(&c.tracks, media.track_clone(t))
		if c.track < 0 && t.kind == .Audio { c.track = i }
	}
}

@(private = "file")
sink_sample :: proc(user: rawptr, track: int, s: media.Sample) {
	context.allocator = alloc()
	c := (^Collector)(user)
	s := s
	if track != c.track { media.sample_destroy(&s); return }
	append(&c.samples, s)
}

// A packet of the formats cut here.
@(private = "file")
add_packet :: proc(c: ^Collector, packet: []u8, pts: i64) {
	s: media.Sample
	s.data = make([]u8, len(packet), alloc())
	copy(s.data, packet)
	s.pts = media.Time(pts)
	s.dts = s.pts
	s.flags = {.Keyframe}
	append(&c.samples, s)
}

@(private = "file")
set_track :: proc(c: ^Collector, codec: media.Codec, rate, channels: int, config: []u8 = nil, delay: media.Time = 0) {
	t: media.Track
	t.kind, t.codec, t.sample_rate, t.channels, t.timescale, t.config, t.codec_delay = .Audio, codec, rate, channels, 1_000_000, config, delay
	append(&c.tracks, media.track_clone(t))
	c.track = 0
}

// ---- WAV ----

@(private = "file") WAV_FORMAT_PCM :: 1
@(private = "file") WAV_FORMAT_FLOAT :: 3
@(private = "file") WAV_FORMAT_ALAW :: 6
@(private = "file") WAV_FORMAT_MULAW :: 7
@(private = "file") WAV_FORMAT_EXTENSIBLE :: 0xFFFE

@(private = "file") le16 :: #force_inline proc "contextless" (b: []u8) -> int { return int(b[0]) | int(b[1]) << 8 }
@(private = "file") le32 :: #force_inline proc "contextless" (b: []u8) -> int { return int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24 }

@(private = "file")
is_tag :: #force_inline proc "contextless" (b: []u8, tag: string) -> bool {
	if len(b) < len(tag) { return false }
	for i in 0 ..< len(tag) { if b[i] != tag[i] { return false } }
	return true
}

@(private = "file")
alaw_sample :: proc(v: u8) -> f32 {
	x := v ~ 0x55
	sign := x & 0x80
	exp := int(x & 0x70) >> 4
	mant := int(x & 0x0F)
	s := exp == 0 ? (mant << 4) + 8 : ((mant << 4) + 0x108) << uint(exp - 1)
	return f32(sign != 0 ? s : -s) / 32768
}

@(private = "file")
mulaw_sample :: proc(v: u8) -> f32 {
	x := ~v
	sign := x & 0x80
	exp := int(x & 0x70) >> 4
	mant := int(x & 0x0F)
	s := (((mant << 3) + 0x84) << uint(exp)) - 0x84
	return f32(sign != 0 ? -s : s) / 32768
}

@(private = "file")
decode_wav :: proc(data: []u8) -> ^Pcm {
	at := 12
	format, channels, rate, bits, align := 0, 0, 0, 0, 0
	body: []u8
	for at + 8 <= len(data) {
		size := le32(data[at + 4:])
		chunk := data[at + 8:]
		size_in := min(size, len(chunk))
		if is_tag(data[at:], "fmt ") && size_in >= 16 {
			format, channels, rate = le16(chunk), le16(chunk[2:]), le32(chunk[4:])
			align, bits = le16(chunk[12:]), le16(chunk[14:])
			if format == WAV_FORMAT_EXTENSIBLE && size_in >= 26 { format = le16(chunk[24:]) }
		} else if is_tag(data[at:], "data") {
			body = chunk[:size_in]
			break
		}
		at += 8 + size + size % 2
	}
	if channels <= 0 || channels > MAX_CHANNELS || rate <= 0 || align <= 0 || bits <= 0 { return nil }
	bytes := (bits + 7) / 8
	if align < bytes * channels { return nil }
	frames := len(body) / align
	if frames == 0 { return nil }
	p := pcm_new(channels, frames, f64(rate))
	for c in 0 ..< channels {
		out := pcm_channel(p, c)
		for i in 0 ..< frames {
			b := body[i * align + c * bytes:]
			v: f32
			switch {
			case format == WAV_FORMAT_FLOAT && bytes == 4: v = transmute(f32)u32(le32(b))
			case format == WAV_FORMAT_FLOAT && bytes == 8:
				lo, hi := u64(le32(b)), u64(le32(b[4:]))
				v = f32(transmute(f64)(lo | hi << 32))
			case format == WAV_FORMAT_ALAW: v = alaw_sample(b[0])
			case format == WAV_FORMAT_MULAW: v = mulaw_sample(b[0])
			case format != WAV_FORMAT_PCM: pcm_release(p); return nil
			case bytes == 1: v = (f32(b[0]) - 128) / 128
			case bytes == 2: v = f32(i16(le16(b))) / (1 << 15)
			case bytes == 3: v = f32(i32(u32(b[0]) << 8 | u32(b[1]) << 16 | u32(b[2]) << 24) >> 8) / (1 << 23)
			case bytes == 4: v = f32(f64(i32(u32(le32(b)))) / (1 << 31))
			case: pcm_release(p); return nil
			}
			out[i] = v
		}
	}
	return p
}

// ---- MP3 ----

@(private = "file") MP3_BITRATES_V1_L3 := [16]int{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}
@(private = "file") MP3_BITRATES_V2_L3 := [16]int{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}
@(private = "file") MP3_BITRATES_V1_L2 := [16]int{0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0}
@(private = "file") MP3_RATES := [3]int{44100, 48000, 32000}

// The frame at the start of `b`: its length, rate and channels; 0 when this is no frame header.
@(private = "file")
mp3_frame :: proc(b: []u8) -> (length, rate, channels: int) {
	if len(b) < 4 || b[0] != 0xFF || b[1] & 0xE0 != 0xE0 { return }
	version := int(b[1] >> 3) & 3   // 3: MPEG 1, 2: MPEG 2, 0: MPEG 2.5
	layer := int(b[1] >> 1) & 3     // 1: III, 2: II, 3: I
	if version == 1 || layer == 0 || layer == 3 { return }
	index := int(b[2] >> 4)
	sr := int(b[2] >> 2) & 3
	if index == 0 || index == 15 || sr == 3 { return }
	padding := int(b[2] >> 1) & 1
	rate = MP3_RATES[sr]
	if version == 2 { rate /= 2 } else if version == 0 { rate /= 4 }
	kbps: int
	if layer == 1 {
		kbps = version == 3 ? MP3_BITRATES_V1_L3[index] : MP3_BITRATES_V2_L3[index]
	} else {
		kbps = version == 3 ? MP3_BITRATES_V1_L2[index] : MP3_BITRATES_V2_L3[index]
	}
	factor := (layer == 1 && version != 3) ? 72 : 144
	length = factor * kbps * 1000 / rate + padding
	channels = int(b[3] >> 6) == 3 ? 1 : 2
	return
}

@(private = "file")
cut_mp3 :: proc(data: []u8, c: ^Collector) -> bool {
	at := 0
	// an ID3v2 tag in front
	if is_tag(data, "ID3") && len(data) >= 10 {
		at = 10 + (int(data[6]) << 21 | int(data[7]) << 14 | int(data[8]) << 7 | int(data[9]))
	}
	pts: i64
	first := true
	for at < len(data) {
		length, rate, channels := mp3_frame(data[at:])
		if length <= 0 {
			at += 1
			continue
		}
		if at + length > len(data) { length = len(data) - at }
		frame := data[at:][:length]
		if first {
			first = false
			set_track(c, .MP3, rate, channels)
			// a Xing / Info frame says things about the file and holds no audio
			head := 4 + 32
			if len(frame) > head + 4 && (is_tag(frame[head:], "Xing") || is_tag(frame[head:], "Info")) {
				at += length
				continue
			}
		}
		add_packet(c, frame, pts)
		pts += media_ns_of(1152, rate)
		at += length
	}
	return !first
}

@(private = "file")
media_ns_of :: #force_inline proc "contextless" (frames, rate: int) -> i64 { return i64(frames) * media.NS_PER_S / i64(rate) }

@(private = "file")
is_mp3 :: proc(data: []u8) -> bool {
	if is_tag(data, "ID3") { return true }
	length, _, _ := mp3_frame(data)
	return length > 0
}

// ---- ADTS AAC ----

@(private = "file") AAC_RATES := [13]int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}

@(private = "file")
is_adts :: #force_inline proc "contextless" (d: []u8) -> bool { return len(d) >= 7 && d[0] == 0xFF && d[1] & 0xF6 == 0xF0 }

@(private = "file")
cut_adts :: proc(data: []u8, c: ^Collector) -> bool {
	at := 0
	pts: i64
	first := true
	for at + 7 <= len(data) {
		d := data[at:]
		if !is_adts(d) { at += 1; continue }
		profile := int(d[2] >> 6)
		sfi := int(d[2] >> 2) & 0xF
		channels := int(d[2] & 1) << 2 | int(d[3] >> 6)
		length := int(d[3] & 3) << 11 | int(d[4]) << 3 | int(d[5] >> 5)
		head := d[1] & 1 == 1 ? 7 : 9
		if sfi >= len(AAC_RATES) || length <= head || at + length > len(data) { at += 1; continue }
		if first {
			first = false
			asc := [2]u8{u8((profile + 1) << 3 | sfi >> 1), u8((sfi & 1) << 7 | channels << 3)}
			set_track(c, .AAC, AAC_RATES[sfi], max(channels, 1), asc[:])
		}
		add_packet(c, d[head:length], pts)
		pts += media_ns_of(1024, AAC_RATES[sfi])
		at += length
	}
	return !first
}

// ---- FLAC ----

// What a FLAC frame header's fields must pass: the CRC-8 of the header (polynomial x^8 + x^2 + x + 1).
@(private = "file")
flac_crc8 :: proc(b: []u8) -> u8 {
	crc: u8
	for v in b {
		crc ~= v
		for _ in 0 ..< 8 { crc = crc & 0x80 != 0 ? (crc << 1) ~ 0x07 : crc << 1 }
	}
	return crc
}

// A frame header at the start of `b`? (The sample number, block size and rate codes vary in length.)
@(private = "file")
flac_header_at :: proc(b: []u8) -> bool {
	if len(b) < 6 || b[0] != 0xFF || b[1] & 0xFE != 0xF8 { return false }
	block := b[2] >> 4
	rate_code := b[2] & 0xF
	if block == 0 || rate_code == 15 { return false }
	if b[3] >> 4 > 10 && b[3] >> 4 < 0 { return false }
	n := 4
	// the coded number (UTF-8 style)
	lead := b[n]
	extra := 0
	switch {
	case lead & 0x80 == 0: extra = 0
	case lead & 0xE0 == 0xC0: extra = 1
	case lead & 0xF0 == 0xE0: extra = 2
	case lead & 0xF8 == 0xF0: extra = 3
	case lead & 0xFC == 0xF8: extra = 4
	case lead & 0xFE == 0xFC: extra = 5
	case lead == 0xFE: extra = 6
	case: return false
	}
	n += 1 + extra
	if block == 6 { n += 1 } else if block == 7 { n += 2 }
	if rate_code == 12 { n += 1 } else if rate_code == 13 || rate_code == 14 { n += 2 }
	if n >= len(b) { return false }
	return flac_crc8(b[:n]) == b[n]
}

@(private = "file")
cut_flac :: proc(data: []u8, c: ^Collector) -> bool {
	at := 4
	info: []u8
	for at + 4 <= len(data) {
		last := data[at] & 0x80 != 0
		type := data[at] & 0x7F
		size := int(data[at + 1]) << 16 | int(data[at + 2]) << 8 | int(data[at + 3])
		if at + 4 + size > len(data) { return false }
		if type == 0 { info = data[at + 4:][:size] }
		at += 4 + size
		if last { break }
	}
	if len(info) < 18 { return false }
	rate := int(info[10]) << 12 | int(info[11]) << 4 | int(info[12] >> 4)
	channels := int(info[12] >> 1 & 7) + 1
	if rate <= 0 { return false }
	// (it says how long it is: a file too long at the rate asked for is not decoded to find out)
	total := int(info[13] & 0xF) << 32 | int(info[14]) << 24 | int(info[15]) << 16 | int(info[16]) << 8 | int(info[17])
	if f64(total) * f64(channels) * size_of(f32) * c.rate / f64(rate) > f64(c.max_bytes) { return false }
	set_track(c, .FLAC, rate, channels, info)
	start := at
	pts: i64
	for at < len(data) {
		if !flac_header_at(data[at:]) { at += 1; if start == at - 1 { start = at }; continue }
		next := at + 1
		for next < len(data) && !flac_header_at(data[next:]) { next += 1 }
		add_packet(c, data[at:next], pts)
		pts += 1
		at = next
	}
	return true
}

// ---- Ogg ----

@(private = "file")
OGG_HEADER :: 27

// Opus and Vorbis of the first logical stream. Packets may span pages.
@(private = "file")
cut_ogg :: proc(data: []u8, c: ^Collector) -> bool {
	context.allocator = alloc()
	at := 0
	packet: [dynamic]u8
	defer delete(packet)
	serial := -1
	count := 0
	codec := media.Codec.None
	vorbis_headers: [dynamic]u8   // the three headers
	defer delete(vorbis_headers)
	vorbis_sizes: [3]int
	vrate, vchannels := 0, 0
	pts: i64
	for at + OGG_HEADER <= len(data) {
		if !is_tag(data[at:], "OggS") { at += 1; continue }
		page := data[at:]
		this_serial := le32(page[14:])
		segments := int(page[26])
		if len(page) < OGG_HEADER + segments { break }
		lacing := page[OGG_HEADER:][:segments]
		body := page[OGG_HEADER + segments:]
		if serial < 0 { serial = this_serial }
		size := 0
		for v in lacing { size += int(v) }
		if size > len(body) { break }
		at += OGG_HEADER + segments + size
		if this_serial != serial { continue }
		off := 0
		run := 0
		for v, i in lacing {
			run += int(v)
			if v == 255 && i < len(lacing) - 1 { continue }
			append(&packet, ..body[off:off + run])
			off += run
			complete := v != 255
			run = 0
			if !complete { continue }
			p := packet[:]
			switch {
			case count == 0 && is_tag(p, "OpusHead") && len(p) >= 19:
				codec = .Opus
				set_track(c, .Opus, 48000, int(p[9]), p, media.Time(le16(p[10:])) * media.Time(media.NS_PER_S) / 48000)
			case count == 0 && len(p) >= 16 && p[0] == 1 && is_tag(p[1:], "vorbis"):
				codec = .Vorbis
				vchannels, vrate = int(p[11]), le32(p[12:])
				vorbis_sizes[0] = len(p)
				append(&vorbis_headers, ..p)
			case count == 0:
				return false
			case codec == .Opus && count == 1:   // OpusTags
			case codec == .Vorbis && count <= 2:
				vorbis_sizes[count] = len(p)
				append(&vorbis_headers, ..p)
				if count == 2 {
					// as WebM stores them: 2, the sizes of the first two (lacing), the headers
					cfg: [dynamic]u8
					defer delete(cfg)
					append(&cfg, 2)
					for k in 0 ..< 2 {
						n := vorbis_sizes[k]
						for n >= 255 { append(&cfg, 255); n -= 255 }
						append(&cfg, u8(n))
					}
					append(&cfg, ..vorbis_headers[:])
					set_track(c, .Vorbis, vrate, vchannels, cfg[:])
				}
			case:
				add_packet(c, p, pts)
				pts += 1
			}
			count += 1
			clear(&packet)
		}
		if run > 0 { append(&packet, ..body[off:off + run]) }
	}
	return codec != .None && c.track >= 0
}

// ---- the decoder, the rate ----

// The packets through the decoder of their codec: interleaved audio and its format.
@(private = "file")
run_decoder :: proc(c: ^Collector, target: f64, max_bytes: int) -> ^Pcm {
	context.allocator = alloc()
	if c.track < 0 || c.track >= len(c.tracks) || len(c.samples) == 0 { return nil }
	t := c.tracks[c.track]
	if !media.backend_audio_support(t.codec).supported { return nil }
	dec := media.backend_audio_decoder(t)
	if dec == nil { return nil }
	defer dec.destroy(dec)
	out: [dynamic]f32
	defer delete(out)
	channels, rate := 0, 0
	drain :: proc(dec: ^media.Audio_Decoder, out: ^[dynamic]f32, channels, rate: ^int) -> bool {
		for {
			block: media.Audio_Block
			r := dec.pull(dec, &block)
			switch r {
			case .Frame:
				defer delete(block.samples, alloc())
				if block.frames <= 0 || block.channels <= 0 { continue }
				if channels^ == 0 { channels^, rate^ = block.channels, block.rate }
				if block.channels == channels^ {
					append(out, ..block.samples[:block.frames * block.channels])
				}
			case .Format_Changed:
				media.audio_block_destroy(&block)
			case .Need_Input:
				return true
			case .Error:
				return false
			}
		}
	}
	failed := 0
	for &s in c.samples {
		if !dec.push(dec, &s) {
			if !drain(dec, &out, &channels, &rate) { failed += 1 }
			dec.push(dec, &s)
		}
		if !drain(dec, &out, &channels, &rate) { failed += 1 }
		// (a file that decodes to more than can be kept stops here)
		if rate > 0 && f64(len(out)) * size_of(f32) * target / f64(rate) > f64(max_bytes) { return nil }
	}
	if dec.drain != nil { dec.drain(dec) }
	drain(dec, &out, &channels, &rate)
	if channels == 0 || rate <= 0 || len(out) == 0 { return nil }
	frames := len(out) / channels
	if f64(frames) * f64(channels) * size_of(f32) * target / f64(rate) > f64(max_bytes) { return nil }
	p := pcm_new(min(channels, MAX_CHANNELS), frames, f64(rate))
	for ch in 0 ..< p.channels {
		dst := pcm_channel(p, ch)
		for i in 0 ..< frames { dst[i] = out[i * channels + ch] }
	}
	return p
}

// The audio at another rate. Takes `in_pcm` when it needs nothing done.
pcm_to_rate :: proc(in_pcm: ^Pcm, rate: f64) -> ^Pcm {
	context.allocator = alloc()
	if in_pcm.rate == rate { return in_pcm }
	ratio := rate / in_pcm.rate
	frames := int(math.ceil(f64(in_pcm.length) * ratio))
	out := pcm_new(in_pcm.channels, frames, rate)
	// the kernel, wider for a lower rate (it then also removes what the new rate cannot hold)
	cutoff := min(ratio, 1)
	half := int(math.ceil(RESAMPLE_HALF_WIDTH / cutoff))
	taps := 2 * half
	table := make([]f32, (RESAMPLE_PHASES + 1) * taps)
	defer delete(table)
	for ph in 0 ..= RESAMPLE_PHASES {
		frac := f64(ph) / RESAMPLE_PHASES
		sum := 0.0
		for t in 0 ..< taps {
			x := f64(t - half + 1) - frac
			w := math.PI * x * cutoff
			sinc := abs(w) < 1e-9 ? 1.0 : math.sin(w) / w
			pos := x / f64(half)
			window := abs(pos) >= 1 ? 0.0 : 0.42 + 0.5 * math.cos(math.PI * pos) + 0.08 * math.cos(2 * math.PI * pos)
			v := sinc * window * cutoff
			table[ph * taps + t] = f32(v)
			sum += v
		}
		if sum != 0 { for t in 0 ..< taps { table[ph * taps + t] = f32(f64(table[ph * taps + t]) / sum) } }
	}
	for c in 0 ..< in_pcm.channels {
		src, dst := pcm_channel(in_pcm, c), pcm_channel(out, c)
		for i in 0 ..< frames {
			pos := f64(i) / ratio
			k := int(pos)
			phase := (pos - f64(k)) * RESAMPLE_PHASES
			ph := int(phase)
			t := f32(phase - f64(ph))
			a := table[ph * taps:][:taps]
			b := table[(ph + 1) * taps:][:taps]
			acc: f32
			for tap in 0 ..< taps {
				at := k + tap - half + 1
				if at < 0 || at >= len(src) { continue }
				acc += src[at] * (a[tap] + (b[tap] - a[tap]) * t)
			}
			dst[i] = acc
		}
	}
	pcm_release(in_pcm)
	return out
}

// A whole file to audio at `rate`. nil: not audio this browser can decode, or more than `max_bytes` of samples at that rate. One
// reference for the caller.
decode_audio :: proc(data: []u8, rate: f64, max_bytes: int) -> ^Pcm {
	context.allocator = alloc()
	if len(data) < 4 { return nil }
	p: ^Pcm
	switch {
	case is_tag(data, "RIFF") && len(data) >= 12 && is_tag(data[8:], "WAVE"):
		p = decode_wav(data)
	case:
		c: Collector
		c.track, c.rate, c.max_bytes = -1, rate, max_bytes
		defer collector_destroy(&c)
		ok := false
		sink := media.Demux_Sink{user = &c, tracks = sink_tracks, sample = sink_sample}
		switch {
		case data[0] == 0x1A && data[1] == 0x45 && data[2] == 0xDF && data[3] == 0xA3:
			w: media.Webm_Demuxer
			media.webm_init(&w, sink)
			defer media.webm_destroy(&w)
			ok = media.webm_feed(&w, data) == .None
		case len(data) >= 8 && is_tag(data[4:], "ftyp"):
			m: media.Mp4_Demuxer
			lim := media.MP4_LIMITS_DEFAULT
			lim.max_retain_bytes = len(data)
			media.mp4_init(&m, sink, lim)
			defer media.mp4_destroy(&m)
			ok = media.mp4_feed(&m, data) == .None
		case is_tag(data, "fLaC"):
			ok = cut_flac(data, &c)
		case is_tag(data, "OggS"):
			ok = cut_ogg(data, &c)
		case is_adts(data):
			ok = cut_adts(data, &c)
		case is_mp3(data):
			ok = cut_mp3(data, &c)
		}
		if ok { p = run_decoder(&c, rate, max_bytes) }
	}
	if p == nil { return nil }
	return pcm_to_rate(p, rate)
}

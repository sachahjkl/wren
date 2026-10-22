package media

// ISO BMFF (MP4, fragmented MP4 / CMAF, M4A): an incremental parser. Bytes come in any split (a Media Source Extensions
// append may end in the middle of a box); the parser reports the tracks of each `moov` and every coded sample once its
// bytes are all there. Both layouts work the same way:
//   * a progressive file: `moov` lists every sample of the file with its offset; `mdat` then delivers the bytes. When
//     `mdat` comes first (moov at the end of the file) its payload is kept until the `moov` arrives.
//   * a fragmented one: each `moof` lists the samples of the `mdat` that follows it.
// Edit lists (elst) shift the timeline the way players do (an AAC priming delay, a B-frame delay, a delayed start).

import "base:runtime"
import "wb:base"
import "core:slice"
import "core:strings"

Mp4_Limits :: struct {
	max_box_bytes:   int,   // largest moov / moof read whole
	max_retain_bytes: int,  // payload of an mdat kept while the moov is still to come
	max_samples:     int,   // samples of one moov
}

MP4_LIMITS_DEFAULT :: Mp4_Limits{max_box_bytes = 256 << 20, max_retain_bytes = 1 << 30, max_samples = 8_000_000}

@(private = "file")
Pending :: struct {
	offset: u64,       // absolute position in the stream of the sample's first byte
	size:   u32,
	track:  u32,
	dts, pts, dur: Time,
	flags:  Sample_Flags,
	config: u32,
}

@(private = "file")
Trex :: struct { duration, size, flags: u32 }

@(private = "file")
Mp4_Track :: struct {
	info:      Track,
	handler:   [4]u8,
	edit_shift: i64,     // media ticks taken off every time
	edit_delay: Time,    // an empty edit: the track starts later
	trex:      Trex,
	next_dts:  i64,      // ticks: where the next fragment of the track continues
	has_trex:  bool,
	// the sample table of a progressive file, kept until the pending list is built
	stts, ctts, stsc, stsz, chunks, sync: []u32,
	stsz_fixed: u32,
	stsz_count: u32,
	chunks64:  []u64,
	ctts_signed: bool,
	has_sync:  bool,
}

Mp4_State :: enum u8 { Header, Collect, Skip, Mdat }

Mp4_Demuxer :: struct {
	sink:      Demux_Sink,
	limits:    Mp4_Limits,
	tracks:    [dynamic]Mp4_Track,
	movie_timescale: u32,
	duration:  Time,
	config:    u32,                 // initialization segments seen so far
	pos:       u64,                 // bytes fed since the start
	state:     Mp4_State,
	hdr:       [16]u8,
	hdr_len:   int,
	box_type:  [4]u8,
	box_start: u64,                 // absolute position of the box being read
	box_end:   u64,                 // absolute end (max(u64) = to the end of the stream)
	buf:       [dynamic]u8,         // the box being collected (header included)
	moof_start: u64,
	pending:   [dynamic]Pending,
	head:      int,                 // first pending sample not delivered
	carry:     [dynamic]u8,         // mdat bytes not delivered yet
	carry_off: u64,
	retain:    bool,                // keeping the whole mdat: the moov is to come
	error:     Parse_Error,
	saw_moov:  bool,
}

mp4_init :: proc(d: ^Mp4_Demuxer, sink: Demux_Sink, limits := MP4_LIMITS_DEFAULT) {
	d^ = {}
	d.sink = sink
	d.limits = limits
}

mp4_destroy :: proc(d: ^Mp4_Demuxer) {
	for &t in d.tracks { mp4_track_free(&t) }
	delete(d.tracks)
	delete(d.buf)
	delete(d.pending)
	delete(d.carry)
	d^ = {}
}

// Forgets the position and any half-read box, keeping the tracks (a SourceBuffer's abort(): the next append starts at a
// box boundary, after a new initialization segment or a media segment).
mp4_reset_parser :: proc(d: ^Mp4_Demuxer) {
	d.state = .Header
	d.hdr_len = 0
	clear(&d.buf)
	clear(&d.pending)
	d.head = 0
	clear(&d.carry)
	d.retain = false
	d.error = .None
}

@(private = "file")
mp4_track_free :: proc(t: ^Mp4_Track) {
	track_destroy(&t.info)
	delete(t.stts); delete(t.ctts); delete(t.stsc); delete(t.stsz); delete(t.chunks); delete(t.sync); delete(t.chunks64)
	t^ = {}
}

// Feeds bytes. Returns the first error (sticky: later calls return it too until mp4_reset_parser).
mp4_feed :: proc(d: ^Mp4_Demuxer, data: []u8) -> Parse_Error {
	if d.error != .None { return d.error }
	rest := data
	for len(rest) > 0 && d.error == .None {
		switch d.state {
		case .Header:
			n := min(len(rest), 16 - d.hdr_len)
			// 8 bytes tell the size unless it is 1 (64-bit size follows)
			copy(d.hdr[d.hdr_len:], rest[:n])
			d.hdr_len += n
			rest = rest[n:]
			d.pos += u64(n)
			// parse as soon as enough is there; unused look-ahead bytes go back
			need := 8
			if d.hdr_len >= 8 && be32(d.hdr[:], 0) == 1 { need = 16 }
			if d.hdr_len < need { continue }
			extra := d.hdr_len - need
			if extra > 0 {
				// bytes read past the header: put them back in front of `rest`
				// (only possible when rest was sliced from `data`: step back)
				rest = data[len(data) - len(rest) - extra:]
				d.pos -= u64(extra)
				d.hdr_len = need
			}
			mp4_box_header(d, need)
		case .Skip:
			remain := d.box_end - d.pos
			n := min(u64(len(rest)), remain)
			rest = rest[n:]
			d.pos += n
			if d.pos >= d.box_end { d.state = .Header; d.hdr_len = 0 }
		case .Collect:
			want := int(d.box_end - d.box_start) - len(d.buf)
			n := min(len(rest), want)
			append(&d.buf, ..rest[:n])
			rest = rest[n:]
			d.pos += u64(n)
			if len(d.buf) == int(d.box_end - d.box_start) {
				mp4_box_complete(d)
				clear(&d.buf)
				d.state = .Header
				d.hdr_len = 0
			}
		case .Mdat:
			remain := d.box_end == max(u64) ? u64(len(rest)) : d.box_end - d.pos
			n := int(min(u64(len(rest)), remain))
			mp4_mdat_bytes(d, rest[:n])
			rest = rest[n:]
			d.pos += u64(n)
			if d.box_end != max(u64) && d.pos >= d.box_end {
				d.state = .Header
				d.hdr_len = 0
				if !d.retain { clear(&d.carry) }
			}
		}
	}
	return d.error
}

// The box header just read: what to do with the box.
@(private = "file")
mp4_box_header :: proc(d: ^Mp4_Demuxer, hdr_len: int) {
	size := u64(be32(d.hdr[:], 0))
	copy(d.box_type[:], d.hdr[4:8])
	d.box_start = d.pos - u64(hdr_len)
	switch size {
	case 1: size = be64(d.hdr[:], 8)
	case 0: size = 0   // to the end of the stream
	}
	if size == 0 {
		d.box_end = max(u64)
	} else {
		if size < u64(hdr_len) { d.error = .Malformed; return }
		d.box_end = d.box_start + size
	}
	typ := string(d.box_type[:])
	switch typ {
	case "moov", "moof":
		if d.box_end == max(u64) || d.box_end - d.box_start > u64(d.limits.max_box_bytes) { d.error = .Too_Large; return }
		clear(&d.buf)
		append(&d.buf, ..d.hdr[:hdr_len])
		if d.box_end - d.box_start == u64(hdr_len) { mp4_box_complete(d); clear(&d.buf); d.hdr_len = 0; return }
		d.state = .Collect
		if typ == "moof" { d.moof_start = d.box_start }
	case "mdat":
		d.state = .Mdat
		d.carry_off = d.pos
		clear(&d.carry)
		d.retain = d.head >= len(d.pending) && !d.saw_moov && len(d.tracks) == 0
		if d.box_end == max(u64) && d.retain { d.error = .Unsupported }   // an open-ended mdat before the moov
	case:
		if d.box_end != max(u64) && d.pos >= d.box_end {
			d.state = .Header
			d.hdr_len = 0
			return
		}
		d.state = .Skip
	}
}

// A whole moov or moof is in d.buf.
@(private = "file")
mp4_box_complete :: proc(d: ^Mp4_Demuxer) {
	switch string(d.box_type[:]) {
	case "moov": mp4_moov(d, d.buf[:])
	case "moof": mp4_moof(d, d.buf[:])
	}
}

////////////////////////////////
// Boxes

@(private = "file")
Box :: struct {
	type:    string,
	start:   int,
	payload: int,
	end:     int,
}

// The box at `pos` inside `data` (children of a parsed box); ok false at the end or on a size that does not fit.
@(private = "file")
box_at :: proc(data: []u8, pos: int, limit: int) -> (b: Box, ok: bool) {
	if pos + 8 > limit || limit > len(data) { return {}, false }
	size := u64(be32(data, pos))
	hdr := 8
	if size == 1 {
		if pos + 16 > limit { return {}, false }
		size = be64(data, pos + 8)
		hdr = 16
	} else if size == 0 {
		size = u64(limit - pos)
	}
	if size < u64(hdr) || u64(pos) + size > u64(limit) { return {}, false }
	return Box{type = string(data[pos + 4:pos + 8]), start = pos, payload = pos + hdr, end = pos + int(size)}, true
}

@(private = "file")
find_box :: proc(data: []u8, from, to: int, type: string) -> (Box, bool) {
	pos := from
	for pos < to {
		b, ok := box_at(data, pos, to)
		if !ok { return {}, false }
		if b.type == type { return b, true }
		pos = b.end
	}
	return {}, false
}

@(private = "file")
mp4_moov :: proc(d: ^Mp4_Demuxer, buf: []u8) {
	root, ok := box_at(buf, 0, len(buf))
	if !ok { d.error = .Malformed; return }
	// a new initialization segment replaces the tracks
	for &t in d.tracks { mp4_track_free(&t) }
	clear(&d.tracks)
	d.movie_timescale = 1000
	d.duration = 0
	d.saw_moov = true
	d.config += 1
	pos := root.payload
	for pos < root.end {
		b, bok := box_at(buf, pos, root.end)
		if !bok { break }
		switch b.type {
		case "mvhd":
			v := int(b8(buf, b.payload))
			o := b.payload + 4
			if v == 1 {
				d.movie_timescale = be32(buf, o + 16)
				dur := be64(buf, o + 20)
				if d.movie_timescale > 0 && dur != max(u64) { d.duration = time_from_ticks(i64(dur), d.movie_timescale) }
			} else {
				d.movie_timescale = be32(buf, o + 8)
				dur := be32(buf, o + 12)
				if d.movie_timescale > 0 && dur != max(u32) { d.duration = time_from_ticks(i64(dur), d.movie_timescale) }
			}
		case "trak":
			t: Mp4_Track
			if mp4_trak(d, buf, b, &t) { append(&d.tracks, t) } else { mp4_track_free(&t) }
		case "mvex":
			mp4_mvex(d, buf, b)
		}
		pos = b.end
	}
	// trex defaults (mvex may follow the traks)
	if d.error != .None { return }
	infos := make([]Track, len(d.tracks), context.temp_allocator)
	for &t, i in d.tracks { infos[i] = t.info }
	if d.sink.tracks != nil { d.sink.tracks(d.sink.user, infos, d.duration) }
	// the samples of a progressive file
	total := 0
	for &t in d.tracks { total += int(t.stsz_count) }
	if total > d.limits.max_samples { d.error = .Too_Large; return }
	first := len(d.pending)
	for &t, i in d.tracks { mp4_table_samples(d, &t, u32(i)) }
	if len(d.pending) > first {
		batch := d.pending[first:]
		slice.stable_sort_by(batch, proc(a, b: Pending) -> bool { return a.offset < b.offset })
	}
	// a retained mdat (moov at the end of the file): deliver from it now
	if len(d.carry) > 0 || d.retain {
		d.retain = false
		mp4_deliver(d, d.carry[:], d.carry_off)
		clear(&d.carry)
	}
}

@(private = "file")
mp4_mvex :: proc(d: ^Mp4_Demuxer, buf: []u8, mvex: Box) {
	pos := mvex.payload
	for pos < mvex.end {
		b, ok := box_at(buf, pos, mvex.end)
		if !ok { return }
		if b.type == "trex" {
			id := be32(buf, b.payload + 4)
			for &t in d.tracks {
				if t.info.id == id {
					t.trex = Trex{duration = be32(buf, b.payload + 12), size = be32(buf, b.payload + 16), flags = be32(buf, b.payload + 20)}
					t.has_trex = true
				}
			}
		}
		pos = b.end
	}
}

// trak -> t (the tables are kept for mp4_table_samples). false: not a usable track.
@(private = "file")
mp4_trak :: proc(d: ^Mp4_Demuxer, buf: []u8, trak: Box, t: ^Mp4_Track) -> bool {
	t.info.timescale = 1000
	mdhd_found := false
	pos := trak.payload
	for pos < trak.end {
		b, ok := box_at(buf, pos, trak.end)
		if !ok { break }
		switch b.type {
		case "tkhd":
			v := b8(buf, b.payload)
			o := b.payload + 4
			if v == 1 {
				t.info.id = be32(buf, o + 16)
				o += 8 + 8 + 4 + 4 + 8   // created, modified, id, reserved, duration
			} else {
				t.info.id = be32(buf, o + 8)
				o += 4 + 4 + 4 + 4 + 4
			}
			o += 8 + 2 + 2 + 2 + 2   // reserved, layer, alternate group, volume, reserved
			// unity matrix 3x3 of 16.16 / 2.30: a, b ... only a, b, c, d decide the rotation
			a, bb, c, dd := i32(be32(buf, o)), i32(be32(buf, o + 4)), i32(be32(buf, o + 12)), i32(be32(buf, o + 16))
			switch {
			case a == 0 && bb > 0 && c < 0 && dd == 0: t.info.rotation = 90
			case a < 0 && bb == 0 && c == 0 && dd < 0: t.info.rotation = 180
			case a == 0 && bb < 0 && c > 0 && dd == 0: t.info.rotation = 270
			}
			o += 36
			t.info.display_width = int(be32(buf, o) >> 16)
			t.info.display_height = int(be32(buf, o + 4) >> 16)
		case "edts":
			if el, eok := find_box(buf, b.payload, b.end, "elst"); eok { mp4_elst(d, buf, el, t) }
		case "mdia":
			m := b.payload
			for m < b.end {
				mb, mok := box_at(buf, m, b.end)
				if !mok { break }
				switch mb.type {
				case "mdhd":
					v := b8(buf, mb.payload)
					o := mb.payload + 4
					if v == 1 {
						t.info.timescale = be32(buf, o + 16)
						dur := be64(buf, o + 20)
						if dur != max(u64) { t.info.duration = time_from_ticks(i64(dur), max(t.info.timescale, 1)) }
						o += 28
					} else {
						t.info.timescale = be32(buf, o + 8)
						dur := be32(buf, o + 12)
						if dur != max(u32) { t.info.duration = time_from_ticks(i64(dur), max(t.info.timescale, 1)) }
						o += 16
					}
					mdhd_found = true
					lang := be16(buf, o)
					t.info.language = strings.clone(string([]u8{u8(((lang >> 10) & 31) + 0x60), u8(((lang >> 5) & 31) + 0x60), u8((lang & 31) + 0x60)}), base.process_allocator())
				case "hdlr":
					copy(t.handler[:], buf[mb.payload + 8:mb.payload + 12])
				case "minf":
					if stbl, sok := find_box(buf, mb.payload, mb.end, "stbl"); sok { mp4_stbl(d, buf, stbl, t) }
				}
				m = mb.end
			}
		}
		pos = b.end
	}
	if !mdhd_found || t.info.timescale == 0 { return false }
	switch string(t.handler[:]) {
	case "vide": t.info.kind = .Video
	case "soun": t.info.kind = .Audio
	}
	if t.info.display_width == 0 { t.info.display_width, t.info.display_height = t.info.width, t.info.height }
	return true
}

@(private = "file")
mp4_elst :: proc(d: ^Mp4_Demuxer, buf: []u8, el: Box, t: ^Mp4_Track) {
	v := b8(buf, el.payload)
	n := int(be32(buf, el.payload + 4))
	o := el.payload + 8
	step := v == 1 ? 20 : 12
	delay: i64   // movie timescale ticks of empty edits before the first media edit
	for _ in 0 ..< min(n, 64) {
		if o + step > el.end { break }
		seg, mt: i64
		if v == 1 { seg, mt = i64(be64(buf, o)), i64(be64(buf, o + 8)) } else { seg, mt = i64(be32(buf, o)), i64(i32(be32(buf, o + 4))) }
		if mt == -1 {
			delay += seg
		} else {
			t.edit_shift = mt
			break
		}
		o += step
	}
	if delay > 0 && d.movie_timescale > 0 { t.edit_delay = time_from_ticks(delay, d.movie_timescale) }
}

////////////////////////////////
// stbl

@(private = "file")
mp4_stbl :: proc(d: ^Mp4_Demuxer, buf: []u8, stbl: Box, t: ^Mp4_Track) {
	pos := stbl.payload
	for pos < stbl.end {
		b, ok := box_at(buf, pos, stbl.end)
		if !ok { break }
		p := b.payload
		switch b.type {
		case "stsd":
			count := be32(buf, p + 4)
			if count > 0 {
				if e, eok := box_at(buf, p + 8, b.end); eok { mp4_sample_entry(buf, e, t) }
			}
		case "stts": t.stts = read_u32s(buf, p + 8, int(be32(buf, p + 4)) * 2, b.end)
		case "ctts":
			t.ctts = read_u32s(buf, p + 8, int(be32(buf, p + 4)) * 2, b.end)
			t.ctts_signed = b8(buf, p) >= 1
		case "stsc": t.stsc = read_u32s(buf, p + 8, int(be32(buf, p + 4)) * 3, b.end)
		case "stsz":
			t.stsz_fixed = be32(buf, p + 4)
			t.stsz_count = be32(buf, p + 8)
			if t.stsz_fixed == 0 { t.stsz = read_u32s(buf, p + 12, int(t.stsz_count), b.end) }
		case "stz2":
			fsz := int(b8(buf, p + 7))
			t.stsz_count = be32(buf, p + 8)
			t.stsz = make([]u32, t.stsz_count)
			o := p + 12
			for i in 0 ..< int(t.stsz_count) {
				switch fsz {
				case 4:
					bb := o + i / 2 < b.end ? buf[o + i / 2] : 0
					t.stsz[i] = u32(i % 2 == 0 ? bb >> 4 : bb & 15)
				case 8: t.stsz[i] = o + i < b.end ? u32(buf[o + i]) : 0
				case 16: t.stsz[i] = be16(buf, o + i * 2)
				}
			}
		case "stco": t.chunks = read_u32s(buf, p + 8, int(be32(buf, p + 4)), b.end)
		case "co64":
			n := int(be32(buf, p + 4))
			if p + 8 + n * 8 <= b.end { t.chunks64 = make([]u64, n); for i in 0 ..< n { t.chunks64[i] = be64(buf, p + 8 + i * 8) } }
		case "stss":
			t.sync = read_u32s(buf, p + 8, int(be32(buf, p + 4)), b.end)
			t.has_sync = true
		}
		pos = b.end
	}
}

@(private = "file")
read_u32s :: proc(buf: []u8, o, n, limit: int) -> []u32 {
	if n < 0 || o + n * 4 > limit || n > (1 << 26) { return nil }
	out := make([]u32, n)
	for i in 0 ..< n { out[i] = be32(buf, o + i * 4) }
	return out
}

// The first sample description: codec, size or channels, codec private data.
@(private = "file")
mp4_sample_entry :: proc(buf: []u8, e: Box, t: ^Mp4_Track) {
	heap := base.process_allocator()
	info := &t.info
	kind := e.type
	children: int
	switch string(t.handler[:]) {
	case "vide":
		info.width = int(be16(buf, e.payload + 24))
		info.height = int(be16(buf, e.payload + 26))
		children = e.payload + 78
	case "soun":
		ver := be16(buf, e.payload + 8)
		info.channels = int(be16(buf, e.payload + 16))
		info.sample_rate = int(be32(buf, e.payload + 24) >> 16)
		children = e.payload + 28
		if ver == 1 { children += 16 } else if ver == 2 { children += 36 }
	case: return
	}
	switch kind {
	case "avc1", "avc3": info.codec = .H264
	case "hvc1", "hev1": info.codec = .HEVC
	case "vp08": info.codec = .VP8
	case "vp09": info.codec = .VP9
	case "av01": info.codec = .AV1
	case "mp4a": info.codec = .AAC   // refined by the esds object type
	case "Opus", "opus": info.codec = .Opus
	case "fLaC": info.codec = .FLAC
	case "ac-3": info.codec = .AC3
	case "ec-3": info.codec = .EAC3
	case "mp3 ", ".mp3": info.codec = .MP3
	}
	pos := children
	for pos < e.end {
		c, ok := box_at(buf, pos, e.end)
		if !ok { break }
		data := buf[c.payload:c.end]
		switch c.type {
		case "avcC":
			info.config = clone_bytes(data, heap)
			if len(data) >= 5 { info.nal_length_size = int(data[4] & 3) + 1 }
			if len(data) >= 4 { info.codec_string = strings.clone(fmt_hex_codec(string(kind[:]), data[1:4]), heap) }
		case "hvcC":
			info.config = clone_bytes(data, heap)
			if len(data) >= 22 { info.nal_length_size = int(data[21] & 3) + 1 }
			info.codec_string = strings.clone(string(kind[:]), heap)
		case "vpcC":
			info.config = clone_bytes(data, heap)
			if len(data) >= 12 {
				// FullBox(4) profile level bitdepth|chroma|range colourPrimaries transfer matrix
				info.bit_depth = int(data[6] >> 4)
				info.color = Color_Info{known = true, full_range = data[6] & 1 != 0, primaries = data[7], coeffs = h273_matrix(data[9]), transfer = h273_transfer(data[8])}
			}
		case "av1C":
			info.config = clone_bytes(data, heap)
			if len(data) >= 4 { info.bit_depth = (data[2] & 0x40) != 0 ? ((data[2] & 0x20) != 0 ? 12 : 10) : 8 }
		case "esds": mp4_esds(data, info, heap)
		case "dOps":
			if len(data) >= 11 {
				ch := int(data[1])
				pre := be16(data, 2)
				rate := be32(data, 4)
				head := make([dynamic]u8, 0, 19 + len(data), heap)
				append(&head, 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, u8(ch))
				put_le16(&head, pre)
				put_le32(&head, rate)
				put_le16(&head, be16(data, 8))   // output gain (big-endian in dOps, little-endian in OpusHead)
				append(&head, data[10])
				if len(data) > 11 { append(&head, ..data[11:]) }
				info.config = head[:]
				info.codec_delay = time_from_ticks(i64(pre), 48000)
				info.channels = ch
				info.sample_rate = 48000
				info.codec_string = strings.clone("opus", heap)
			}
		case "dfLa":
			// FLAC in MP4: after the FullBox, metadata blocks; the STREAMINFO block is the first
			if len(data) > 8 { info.config = clone_bytes(data[4:], heap) }
		case "colr":
			if len(data) >= 11 && string(data[:4]) == "nclx" {
				info.color = Color_Info{known = true, primaries = u8(be16(data, 4)), transfer = h273_transfer(u8(be16(data, 6))), coeffs = h273_matrix(u8(be16(data, 8))), full_range = data[10] & 0x80 != 0}
			}
		}
		pos = c.end
	}
	if info.codec_string == "" {
		switch info.codec {
		case .AAC: info.codec_string = strings.clone("mp4a.40.2", heap)
		case .VP9: info.codec_string = strings.clone("vp09", heap)
		case .AV1: info.codec_string = strings.clone("av01", heap)
		case .Opus: info.codec_string = strings.clone("opus", heap)
		case .H264, .HEVC, .VP8, .Vorbis, .MP3, .FLAC, .PCM, .AC3, .EAC3, .None:
		}
	}
}

@(private = "file")
fmt_hex_codec :: proc(kind: string, profile_compat_level: []u8) -> string {
	hex := "0123456789abcdef"
	b := make([]u8, 4 + 1 + 6, context.temp_allocator)
	copy(b, kind)
	b[4] = '.'
	for i in 0 ..< 3 {
		b[5 + i * 2] = hex[profile_compat_level[i] >> 4]
		b[6 + i * 2] = hex[profile_compat_level[i] & 15]
	}
	return string(b)
}

// H.273 code points to what the player needs.
@(private)
h273_matrix :: proc "contextless" (v: u8) -> Matrix_Coeffs {
	switch v {
	case 1: return .BT709
	case 5, 6: return .BT601
	case 9, 10: return .BT2020
	case 7: return .SMPTE240
	case 0: return .Identity
	}
	return .Unspecified
}

@(private)
h273_transfer :: proc "contextless" (v: u8) -> Transfer {
	switch v {
	case 16: return .PQ
	case 18: return .HLG
	case 0, 2: return .Unspecified
	}
	return .SDR
}

// esds: the elementary stream descriptor of MPEG-4 audio.
@(private = "file")
mp4_esds :: proc(data: []u8, info: ^Track, heap: runtime.Allocator) {
	pos := 4   // FullBox
	desc_len :: proc(d: []u8, pos: ^int) -> int {
		n := 0
		for _ in 0 ..< 4 {
			if pos^ >= len(d) { return 0 }
			b := d[pos^]
			pos^ += 1
			n = n << 7 | int(b & 0x7f)
			if b & 0x80 == 0 { break }
		}
		return n
	}
	for pos < len(data) {
		tag := data[pos]
		pos += 1
		size := desc_len(data, &pos)
		switch tag {
		case 0x03:   // ES_Descriptor: ES_ID, flags
			if pos + 3 > len(data) { return }
			flags := data[pos + 2]
			pos += 3
			if flags & 0x80 != 0 { pos += 2 }
			if flags & 0x40 != 0 && pos < len(data) { pos += 1 + int(data[pos]) }
			if flags & 0x20 != 0 { pos += 2 }
		case 0x04:   // DecoderConfigDescriptor
			if pos + 13 > len(data) { return }
			oti := data[pos]
			switch oti {
			case 0x40, 0x66, 0x67, 0x68: info.codec = .AAC
			case 0x69, 0x6b: info.codec = .MP3
			case 0xdd: info.codec = .Vorbis
			case 0xe1: info.codec = .None
			}
			pos += 13
		case 0x05:   // DecoderSpecificInfo: the AudioSpecificConfig
			if pos + size > len(data) { return }
			info.config = clone_bytes(data[pos:pos + size], heap)
			if info.codec == .AAC && size >= 2 {
				r := Bit_Reader{data = data[pos:pos + size]}
				aot := bits_read(&r, 5)
				if aot == 31 { aot = 32 + bits_read(&r, 6) }
				info.codec_string = strings.clone(aac_codec_string(int(aot)), heap)
			}
			return
		case:
			pos += size
		}
	}
}

@(private = "file")
aac_codec_string :: proc(aot: int) -> string {
	switch aot {
	case 2: return "mp4a.40.2"
	case 5: return "mp4a.40.5"
	case 29: return "mp4a.40.29"
	case 1: return "mp4a.40.1"
	}
	return "mp4a.40.2"
}

////////////////////////////////
// Samples of a progressive file

@(private = "file")
mp4_table_samples :: proc(d: ^Mp4_Demuxer, t: ^Mp4_Track, track: u32) {
	n := int(t.stsz_count)
	defer {
		delete(t.stts); delete(t.ctts); delete(t.stsc); delete(t.stsz); delete(t.chunks); delete(t.sync); delete(t.chunks64)
		t.stts, t.ctts, t.stsc, t.stsz, t.chunks, t.sync, t.chunks64 = nil, nil, nil, nil, nil, nil, nil
		t.stsz_count = 0
	}
	if n == 0 || t.info.kind == .Other { return }
	nchunks := len(t.chunks64) > 0 ? len(t.chunks64) : len(t.chunks)
	if nchunks == 0 || len(t.stsc) < 3 || len(t.stts) < 2 { return }
	size_of_sample :: proc(t: ^Mp4_Track, i: int) -> u32 { return t.stsz_fixed != 0 ? t.stsz_fixed : (i < len(t.stsz) ? t.stsz[i] : 0) }
	// stts / ctts run iterators
	stts_i, stts_left := 0, t.stts[0]
	ctts_i, ctts_left: int
	if len(t.ctts) >= 2 { ctts_left = int(t.ctts[0]) }
	sync_i := 0
	dts: i64
	sample := 0
	ts := max(t.info.timescale, 1)
	stsc_i := 0
	for chunk in 0 ..< nchunks {
		for stsc_i + 1 < len(t.stsc) / 3 && u32(chunk + 1) >= t.stsc[(stsc_i + 1) * 3] { stsc_i += 1 }
		per_chunk := int(t.stsc[stsc_i * 3 + 1])
		off := len(t.chunks64) > 0 ? t.chunks64[chunk] : u64(t.chunks[chunk])
		for _ in 0 ..< per_chunk {
			if sample >= n { break }
			size := size_of_sample(t, sample)
			// duration
			for stts_left == 0 {
				stts_i += 1
				if stts_i * 2 + 1 >= len(t.stts) { break }
				stts_left = t.stts[stts_i * 2]
			}
			dur: i64
			if stts_i * 2 + 1 < len(t.stts) { dur = i64(t.stts[stts_i * 2 + 1]); stts_left -= 1 }
			cts_off: i64
			if len(t.ctts) >= 2 {
				for ctts_left == 0 && ctts_i * 2 + 3 < len(t.ctts) {
					ctts_i += 1
					ctts_left = int(t.ctts[ctts_i * 2])
				}
				if ctts_i * 2 + 1 < len(t.ctts) {
					cts_off = t.ctts_signed ? i64(i32(t.ctts[ctts_i * 2 + 1])) : i64(t.ctts[ctts_i * 2 + 1])
					ctts_left -= 1
				}
			}
			flags: Sample_Flags
			if t.info.kind == .Audio || !t.has_sync {
				flags += {.Keyframe}
			} else {
				for sync_i < len(t.sync) && t.sync[sync_i] < u32(sample + 1) { sync_i += 1 }
				if sync_i < len(t.sync) && t.sync[sync_i] == u32(sample + 1) { flags += {.Keyframe} }
			}
			p := Pending{offset = off, size = size, track = track, config = d.config, flags = flags}
			p.dts = time_from_ticks(dts - t.edit_shift, ts) + t.edit_delay
			p.pts = time_from_ticks(dts + cts_off - t.edit_shift, ts) + t.edit_delay
			p.dur = time_from_ticks(dur, ts)
			if p.pts + p.dur <= 0 { p.flags += {.Pre_Roll} }
			append(&d.pending, p)
			off += u64(size)
			dts += dur
			sample += 1
		}
	}
}

////////////////////////////////
// Fragments

@(private = "file")
mp4_moof :: proc(d: ^Mp4_Demuxer, buf: []u8) {
	root, ok := box_at(buf, 0, len(buf))
	if !ok || len(d.tracks) == 0 { d.error = ok ? .Unsupported : .Malformed; return }
	first := len(d.pending)
	legacy_next: u64 = d.moof_start
	pos := root.payload
	for pos < root.end {
		b, bok := box_at(buf, pos, root.end)
		if !bok { break }
		if b.type == "traf" { legacy_next = mp4_traf(d, buf, b, legacy_next) }
		pos = b.end
	}
	if len(d.pending) > first {
		batch := d.pending[first:]
		slice.stable_sort_by(batch, proc(a, b: Pending) -> bool { return a.offset < b.offset })
	}
}

// One track fragment. Returns where the next fragment's data starts when no base offset is given (legacy layout).
@(private = "file")
mp4_traf :: proc(d: ^Mp4_Demuxer, buf: []u8, traf: Box, legacy_base: u64) -> u64 {
	tfhd, ok := find_box(buf, traf.payload, traf.end, "tfhd")
	if !ok { return legacy_base }
	p := tfhd.payload
	flags := be24(buf, p + 1)
	id := be32(buf, p + 4)
	o := p + 8
	var_base := d.moof_start
	has_base := false
	if flags & 1 != 0 { var_base = be64(buf, o); o += 8; has_base = true }
	if flags & 2 != 0 { o += 4 }
	def_dur, def_size, def_flags: u32
	have_dur, have_size, have_flags := false, false, false
	if flags & 8 != 0 { def_dur = be32(buf, o); o += 4; have_dur = true }
	if flags & 0x10 != 0 { def_size = be32(buf, o); o += 4; have_size = true }
	if flags & 0x20 != 0 { def_flags = be32(buf, o); o += 4; have_flags = true }
	if flags & 0x20000 != 0 { var_base = d.moof_start; has_base = true }
	ti := -1
	for &t, i in d.tracks { if t.info.id == id { ti = i; break } }
	if ti < 0 { return legacy_base }
	t := &d.tracks[ti]
	if !have_dur && t.has_trex { def_dur = t.trex.duration }
	if !have_size && t.has_trex { def_size = t.trex.size }
	if !have_flags && t.has_trex { def_flags = t.trex.flags }
	if !has_base { var_base = legacy_base }
	ts := max(t.info.timescale, 1)
	dts := t.next_dts
	if tfdt, tok := find_box(buf, traf.payload, traf.end, "tfdt"); tok {
		if b8(buf, tfdt.payload) == 1 { dts = i64(be64(buf, tfdt.payload + 4)) } else { dts = i64(be32(buf, tfdt.payload + 4)) }
	}
	data_end := var_base
	cursor := var_base
	pos := traf.payload
	for pos < traf.end {
		b, bok := box_at(buf, pos, traf.end)
		if !bok { break }
		pos = b.end
		if b.type != "trun" { continue }
		q := b.payload
		ver := b8(buf, q)
		tf := be24(buf, q + 1)
		count := int(be32(buf, q + 4))
		r := q + 8
		if tf & 1 != 0 { cursor = u64(i64(var_base) + i64(i32(be32(buf, r)))); r += 4 }
		first_flags := def_flags
		has_first := false
		if tf & 4 != 0 { first_flags = be32(buf, r); r += 4; has_first = true }
		if count > d.limits.max_samples { d.error = .Too_Large; return legacy_base }
		for i in 0 ..< count {
			dur, size, sflags: u32 = def_dur, def_size, def_flags
			cts: i64
			if tf & 0x100 != 0 { dur = be32(buf, r); r += 4 }
			if tf & 0x200 != 0 { size = be32(buf, r); r += 4 }
			if tf & 0x400 != 0 { sflags = be32(buf, r); r += 4 } else if i == 0 && has_first { sflags = first_flags }
			if tf & 0x800 != 0 {
				cts = ver >= 1 ? i64(i32(be32(buf, r))) : i64(be32(buf, r))
				r += 4
			}
			if r > traf.end { d.error = .Malformed; return legacy_base }
			if t.info.kind != .Other {
				fl: Sample_Flags
				if t.info.kind == .Audio || sflags & 0x10000 == 0 { fl += {.Keyframe} }
				s := Pending{offset = cursor, size = size, track = u32(ti), config = d.config, flags = fl}
				s.dts = time_from_ticks(dts - t.edit_shift, ts) + t.edit_delay
				s.pts = time_from_ticks(dts + cts - t.edit_shift, ts) + t.edit_delay
				s.dur = time_from_ticks(i64(dur), ts)
				if s.pts + s.dur <= 0 { s.flags += {.Pre_Roll} }
				append(&d.pending, s)
			}
			cursor += u64(size)
			dts += i64(dur)
		}
		data_end = cursor
	}
	t.next_dts = dts
	return data_end
}

////////////////////////////////
// mdat

@(private = "file")
mp4_mdat_bytes :: proc(d: ^Mp4_Demuxer, chunk: []u8) {
	abs := d.pos
	if d.retain {
		if len(d.carry) + len(chunk) > d.limits.max_retain_bytes { d.error = .Too_Large; return }
		append(&d.carry, ..chunk)
		return
	}
	if len(d.carry) > 0 {
		append(&d.carry, ..chunk)
		mp4_deliver(d, d.carry[:], d.carry_off)
	} else {
		mp4_deliver(d, chunk, abs)
	}
	// keep what the next pending sample still needs
	if d.head >= len(d.pending) {
		clear(&d.carry)
		return
	}
	next := d.pending[d.head].offset
	if len(d.carry) > 0 {
		cut := next > d.carry_off ? int(min(next - d.carry_off, u64(len(d.carry)))) : 0
		remove_range(&d.carry, 0, cut)
		d.carry_off += u64(cut)
	} else {
		end := abs + u64(len(chunk))
		if next < end && next >= abs {
			append(&d.carry, ..chunk[next - abs:])
			d.carry_off = next
		}
	}
	if d.head > 4096 && d.head * 2 > len(d.pending) {
		remove_range(&d.pending, 0, d.head)
		d.head = 0
	}
}

// Delivers every pending sample that lies completely inside win (the bytes from absolute position `off`).
@(private = "file")
mp4_deliver :: proc(d: ^Mp4_Demuxer, win: []u8, off: u64) {
	end := off + u64(len(win))
	for d.head < len(d.pending) {
		p := &d.pending[d.head]
		if p.offset + u64(p.size) > end { break }
		if p.offset < off {
			// its bytes went by before the sample was known: nothing to deliver
			d.head += 1
			continue
		}
		if p.size > 0 && d.sink.sample != nil {
			heap := base.process_allocator()
			data := make([]u8, p.size, heap)
			copy(data, win[p.offset - off:][:p.size])
			d.sink.sample(d.sink.user, int(p.track), Sample{dts = p.dts, pts = p.pts, duration = p.dur, flags = p.flags, config = p.config, data = data})
		}
		d.head += 1
	}
}

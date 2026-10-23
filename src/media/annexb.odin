package media

// H.264 / HEVC in MP4 and WebM are length-prefixed NAL units with the parameter sets in a configuration record
// (avcC / hvcC); decoders such as the Media Foundation ones take Annex B (start codes, parameter sets in the stream).

START_CODE :: [4]u8{0, 0, 0, 1}

// The parameter sets of an avcC record, each behind a start code.
avcc_annexb_header :: proc(config: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 64, allocator)
	if len(config) < 7 { return out[:] }
	pos := 5
	for round in 0 ..< 2 {
		if pos >= len(config) { break }
		n := int(config[pos])
		if round == 0 { n &= 31 }
		pos += 1
		for _ in 0 ..< n {
			if pos + 2 > len(config) { return out[:] }
			l := int(be16(config, pos))
			pos += 2
			if pos + l > len(config) { return out[:] }
			sc := START_CODE
			append(&out, ..sc[:])
			append(&out, ..config[pos:pos + l])
			pos += l
		}
	}
	return out[:]
}

// The parameter sets of an hvcC record (VPS, SPS, PPS and SEI arrays), each behind a start code.
hvcc_annexb_header :: proc(config: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 128, allocator)
	if len(config) < 23 { return out[:] }
	arrays := int(config[22])
	pos := 23
	for _ in 0 ..< arrays {
		if pos + 3 > len(config) { break }
		count := int(be16(config, pos + 1))
		pos += 3
		for _ in 0 ..< count {
			if pos + 2 > len(config) { return out[:] }
			l := int(be16(config, pos))
			pos += 2
			if pos + l > len(config) { return out[:] }
			sc := START_CODE
			append(&out, ..sc[:])
			append(&out, ..config[pos:pos + l])
			pos += l
		}
	}
	return out[:]
}

// Appends `sample` (NAL units behind `nal_len`-byte lengths) to out with start codes; `prefix` (parameter sets) goes first
// when given (keyframes). false: a length runs past the sample (corrupt).
length_to_annexb :: proc(sample: []u8, nal_len: int, prefix: []u8, out: ^[dynamic]u8) -> bool {
	if nal_len < 1 || nal_len > 4 { return false }
	if len(prefix) > 0 { append(out, ..prefix) }
	pos := 0
	for pos + nal_len <= len(sample) {
		l := 0
		for i in 0 ..< nal_len { l = l << 8 | int(sample[pos + i]) }
		pos += nal_len
		if l < 0 || pos + l > len(sample) { return false }
		sc := START_CODE
		append(out, ..sc[:])
		append(out, ..sample[pos:pos + l])
		pos += l
	}
	return true
}

// Whether an Annex B / length-prefixed sample holds an IDR (H.264) slice: a decoder can start there.
h264_has_idr :: proc(sample: []u8, nal_len: int) -> bool {
	pos := 0
	for pos + nal_len <= len(sample) {
		l := 0
		for i in 0 ..< nal_len { l = l << 8 | int(sample[pos + i]) }
		pos += nal_len
		if l <= 0 || pos + l > len(sample) { return false }
		if sample[pos] & 31 == 5 { return true }
		pos += l
	}
	return false
}

package page

// WebCodecs encoded chunks and audio data (api/webcodecs_codec.widl, native/js/runtime/web_webcodecs_codec.c):
//   * EncodedVideoChunk / EncodedAudioChunk: an immutable coded sample — a type ("key" / "delta"), a timestamp and
//     optional duration (microseconds), and the coded bytes (copyTo / byteLength). The bytes are held against the
//     page's memory ceiling like any buffer.
//   * AudioData: decoded (or caller-supplied) PCM samples in one of the WebCodecs AudioSampleFormats, with per-plane /
//     interleaved copyTo, allocationSize, clone and close. Everything is native: the layouts and the format
//     conversions are done here in Odin.

// ---- EncodedVideoChunk / EncodedAudioChunk (the same shape) ----

Encoded_Chunk_Obj :: struct {
	page:      ^Page,
	self:      u64,
	is_video:  bool,
	key:       bool,         // type "key" (else "delta")
	timestamp: i64,          // microseconds
	duration:  i64,          // microseconds, -1 = none
	has_duration: bool,
	data:      []u8,         // owned (page allocator), charged in p.held
}

encoded_chunk_vt := Object_VTable{
	name = "EncodedChunk",
	destroy = proc(p: ^Page, data: rawptr) {
		c := (^Encoded_Chunk_Obj)(data)
		if c.data != nil { if !p.closed { p.held -= len(c.data) }; delete(c.data) }
		free(c)
	},
}

lookup_EncodedVideoChunk :: proc(c: ^Call, h: u64) -> ^Encoded_Chunk_Obj { return encoded_chunk_of(c.page, h, true) }
lookup_EncodedAudioChunk :: proc(c: ^Call, h: u64) -> ^Encoded_Chunk_Obj { return encoded_chunk_of(c.page, h, false) }

@(private)
encoded_chunk_of :: proc(p: ^Page, h: u64, is_video: bool) -> ^Encoded_Chunk_Obj {
	c := (^Encoded_Chunk_Obj)(object_data(p, h, &encoded_chunk_vt))
	if c == nil || c.is_video != is_video { return nil }
	return c
}

// new EncodedVideoChunk / EncodedAudioChunk({type, timestamp, duration, data}). `key` is type == "key".
@(private)
encoded_chunk_new :: proc(c: ^Call, is_video: bool, key: bool, timestamp, duration: i64, has_duration: bool, data: []u8) -> (u64, Api_Error) {
	p := c.page
	if p.held + len(data) > p.settings.max_fetch_bytes { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit.") }
	o := new(Encoded_Chunk_Obj)
	o.page = p
	o.is_video = is_video
	o.key = key
	o.timestamp = timestamp
	o.duration = duration
	o.has_duration = has_duration
	o.data = make([]u8, len(data))
	copy(o.data, data)
	p.held += len(data)
	o.self = object_create(p, &encoded_chunk_vt, o, c.owner)
	return o.self, .None
}

EncodedVideoChunk_create :: proc(c: ^Call, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> (u64, Api_Error) {
	return encoded_chunk_new(c, true, key, timestamp, duration, has_duration, data)
}
EncodedAudioChunk_create :: proc(c: ^Call, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> (u64, Api_Error) {
	return encoded_chunk_new(c, false, key, timestamp, duration, has_duration, data)
}

EncodedVideoChunk_type :: proc(c: ^Call, chunk: Api_EncodedVideoChunk) -> bool { return chunk.data != nil && chunk.data.key }   // true = "key"
EncodedVideoChunk_timestamp :: proc(c: ^Call, chunk: Api_EncodedVideoChunk) -> i64 { return chunk.data == nil ? 0 : chunk.data.timestamp }
EncodedVideoChunk_duration :: proc(c: ^Call, chunk: Api_EncodedVideoChunk) -> i64 { return chunk.data == nil || !chunk.data.has_duration ? -1 : chunk.data.duration }
EncodedVideoChunk_byteLength :: proc(c: ^Call, chunk: Api_EncodedVideoChunk) -> u32 { return chunk.data == nil ? 0 : u32(len(chunk.data.data)) }
EncodedVideoChunk_copyTo :: proc(c: ^Call, chunk: Api_EncodedVideoChunk, dst: []u8) -> (i32, Api_Error) { return encoded_copy(c, chunk.data, dst) }

EncodedAudioChunk_type :: proc(c: ^Call, chunk: Api_EncodedAudioChunk) -> bool { return chunk.data != nil && chunk.data.key }
EncodedAudioChunk_timestamp :: proc(c: ^Call, chunk: Api_EncodedAudioChunk) -> i64 { return chunk.data == nil ? 0 : chunk.data.timestamp }
EncodedAudioChunk_duration :: proc(c: ^Call, chunk: Api_EncodedAudioChunk) -> i64 { return chunk.data == nil || !chunk.data.has_duration ? -1 : chunk.data.duration }
EncodedAudioChunk_byteLength :: proc(c: ^Call, chunk: Api_EncodedAudioChunk) -> u32 { return chunk.data == nil ? 0 : u32(len(chunk.data.data)) }
EncodedAudioChunk_copyTo :: proc(c: ^Call, chunk: Api_EncodedAudioChunk, dst: []u8) -> (i32, Api_Error) { return encoded_copy(c, chunk.data, dst) }

@(private)
encoded_copy :: proc(c: ^Call, o: ^Encoded_Chunk_Obj, dst: []u8) -> (i32, Api_Error) {
	if o == nil { return 0, fail(c, .Invalid_State, "InvalidStateError: the chunk is gone.") }
	if len(dst) < len(o.data) { return 0, fail(c, .Type, "TypeError: the destination is too small.") }
	copy(dst, o.data)
	return i32(len(o.data)), .None
}

////////////////////////////////
// AudioData

// The WebCodecs AudioSampleFormat enum. "planar" variants have one plane per channel; the others interleave the
// channels. All are kept exactly as given (no resampling); copyTo converts between interleaved and planar of the same
// sample type, and between sample types within reason (the common ones).
Audio_Sample_Format :: enum u8 {
	None,
	U8,       // "u8"        interleaved unsigned 8-bit
	S16,      // "s16"       interleaved signed 16-bit
	S32,      // "s32"       interleaved signed 32-bit
	F32,      // "f32"       interleaved 32-bit float
	U8_Planar,
	S16_Planar,
	S32_Planar,
	F32_Planar,
}

audio_format_bytes :: proc(f: Audio_Sample_Format) -> int {
	#partial switch f {
	case .U8, .U8_Planar: return 1
	case .S16, .S16_Planar: return 2
	case .S32, .S32_Planar, .F32, .F32_Planar: return 4
	}
	return 0
}

audio_format_planar :: proc(f: Audio_Sample_Format) -> bool {
	#partial switch f { case .U8_Planar, .S16_Planar, .S32_Planar, .F32_Planar: return true }
	return false
}

Audio_Data_Obj :: struct {
	page:       ^Page,
	self:       u64,
	format:     Audio_Sample_Format,
	sample_rate: f32,
	frames:     int,          // numberOfFrames
	channels:   int,          // numberOfChannels
	timestamp:  i64,          // microseconds
	data:       []u8,         // owned (page allocator), charged in p.held; layout matches `format`
	closed:     bool,
}

audio_data_vt := Object_VTable{
	name = "AudioData",
	destroy = proc(p: ^Page, data: rawptr) {
		a := (^Audio_Data_Obj)(data)
		if a.data != nil { if !p.closed { p.held -= len(a.data) }; delete(a.data) }
		free(a)
	},
}

lookup_AudioData :: proc(c: ^Call, h: u64) -> ^Audio_Data_Obj { return (^Audio_Data_Obj)(object_data(c.page, h, &audio_data_vt)) }

@(private)
audio_data_of :: proc(p: ^Page, h: u64) -> ^Audio_Data_Obj { return (^Audio_Data_Obj)(object_data(p, h, &audio_data_vt)) }

@(private)
audio_data_new :: proc(p: ^Page, owner: u32, format: Audio_Sample_Format, rate: f32, frames, channels: int, timestamp: i64, bytes: []u8) -> (u64, bool) {
	if p.held + len(bytes) > p.settings.max_fetch_bytes { return 0, false }
	a := new(Audio_Data_Obj)
	a.page = p
	a.format = format
	a.sample_rate = rate
	a.frames = frames
	a.channels = channels
	a.timestamp = timestamp
	a.data = make([]u8, len(bytes))
	copy(a.data, bytes)
	p.held += len(bytes)
	a.self = object_create(p, &audio_data_vt, a, owner)
	return a.self, true
}

@(private)
audio_format_from_abi :: proc(v: i32) -> Audio_Sample_Format {
	if v < 0 || v > i32(Audio_Sample_Format.F32_Planar) { return .None }
	return Audio_Sample_Format(v)
}

// new AudioData({format, sampleRate, numberOfFrames, numberOfChannels, timestamp, data}).
AudioData_create :: proc(c: ^Call, format_abi: i32, sample_rate: f64, frames: u32, channels: u32, timestamp: i64, data: []u8) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }
	format := audio_format_from_abi(format_abi)
	if format == .None { return 0, fail(c, .Not_Supported, "NotSupportedError: unknown AudioSampleFormat.") }
	if sample_rate <= 0 || channels == 0 || frames == 0 { return 0, fail(c, .Range, "RangeError: invalid AudioData geometry.") }
	need := int(frames) * int(channels) * audio_format_bytes(format)
	if len(data) < need { return 0, fail(c, .Type, "TypeError: the data buffer is too small for the geometry.") }
	h, ok := audio_data_new(p, c.owner, format, f32(sample_rate), int(frames), int(channels), timestamp, data[:need])
	if !ok { return 0, fail(c, .Quota, "QuotaExceededError: AudioData too large.") }
	return h, .None
}

AudioData_format :: proc(c: ^Call, a: Api_AudioData) -> i32 { return a.data == nil || a.data.closed ? -1 : i32(a.data.format) }
AudioData_sampleRate :: proc(c: ^Call, a: Api_AudioData) -> f64 { return a.data == nil ? 0 : f64(a.data.sample_rate) }
AudioData_numberOfFrames :: proc(c: ^Call, a: Api_AudioData) -> u32 { return a.data == nil || a.data.closed ? 0 : u32(a.data.frames) }
AudioData_numberOfChannels :: proc(c: ^Call, a: Api_AudioData) -> u32 { return a.data == nil || a.data.closed ? 0 : u32(a.data.channels) }
AudioData_timestamp :: proc(c: ^Call, a: Api_AudioData) -> i64 { return a.data == nil ? 0 : a.data.timestamp }
AudioData_duration :: proc(c: ^Call, a: Api_AudioData) -> i64 {
	if a.data == nil || a.data.sample_rate <= 0 { return 0 }
	return i64(f64(a.data.frames) * 1_000_000 / f64(a.data.sample_rate))
}

// allocationSize({planeIndex, format, frameOffset, frameCount}): the bytes copyTo needs for one plane (planar dest) or
// the whole interleaved block, in the destination format (default: the frame's own).
AudioData_allocationSize :: proc(c: ^Call, a: Api_AudioData, plane_index: u32, format_abi: i32, frame_offset: u32, frame_count: u32, has_count: bool) -> (i32, Api_Error) {
	ad := a.data
	if ad == nil || ad.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the AudioData is closed.") }
	dst_fmt := format_abi < 0 ? ad.format : audio_format_from_abi(format_abi)
	if dst_fmt == .None { return 0, fail(c, .Not_Supported, "NotSupportedError: unknown format.") }
	count := has_count ? int(frame_count) : ad.frames - int(frame_offset)
	if int(frame_offset) > ad.frames || count < 0 || int(frame_offset) + count > ad.frames { return 0, fail(c, .Range, "RangeError: frame range out of bounds.") }
	bytes := audio_format_bytes(dst_fmt)
	if audio_format_planar(dst_fmt) {
		if int(plane_index) >= ad.channels { return 0, fail(c, .Range, "RangeError: planeIndex out of range.") }
		return i32(count * bytes), .None
	}
	// interleaved: plane 0 only, all channels
	if plane_index != 0 { return 0, fail(c, .Range, "RangeError: an interleaved format has one plane.") }
	return i32(count * ad.channels * bytes), .None
}

// copyTo(destination, {planeIndex, format, frameOffset, frameCount}): converts and copies samples into `dst`. Returns
// the bytes written. Supports every pairing of the four sample types, interleaved or planar, for the chosen plane.
AudioData_copyTo :: proc(c: ^Call, a: Api_AudioData, dst: []u8, plane_index: u32, format_abi: i32, frame_offset: u32, frame_count: u32, has_count: bool) -> (i32, Api_Error) {
	ad := a.data
	if ad == nil || ad.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the AudioData is closed.") }
	dst_fmt := format_abi < 0 ? ad.format : audio_format_from_abi(format_abi)
	if dst_fmt == .None { return 0, fail(c, .Not_Supported, "NotSupportedError: unknown format.") }
	count := has_count ? int(frame_count) : ad.frames - int(frame_offset)
	if int(frame_offset) > ad.frames || count < 0 || int(frame_offset) + count > ad.frames { return 0, fail(c, .Range, "RangeError: frame range out of bounds.") }
	dst_planar := audio_format_planar(dst_fmt)
	dst_bytes := audio_format_bytes(dst_fmt)
	channels := dst_planar ? 1 : ad.channels
	if dst_planar && int(plane_index) >= ad.channels { return 0, fail(c, .Range, "RangeError: planeIndex out of range.") }
	if !dst_planar && plane_index != 0 { return 0, fail(c, .Range, "RangeError: an interleaved format has one plane.") }
	need := count * channels * dst_bytes
	if len(dst) < need { return 0, fail(c, .Type, "TypeError: the destination is too small.") }

	for f in 0 ..< count {
		for ch in 0 ..< channels {
			// source channel: for a planar destination it is `plane_index`; interleaved covers every channel
			src_ch := dst_planar ? int(plane_index) : ch
			sample := audio_read_sample(ad, int(frame_offset) + f, src_ch)
			di := (f * channels + ch) * dst_bytes
			audio_write_sample(dst[di:], dst_fmt, sample)
		}
	}
	return i32(need), .None
}

AudioData_clone :: proc(c: ^Call, a: Api_AudioData) -> (u64, Api_Error) {
	ad := a.data
	if ad == nil || ad.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the AudioData is closed.") }
	h, ok := audio_data_new(c.page, c.owner, ad.format, ad.sample_rate, ad.frames, ad.channels, ad.timestamp, ad.data)
	if !ok { return 0, fail(c, .Quota, "QuotaExceededError: AudioData too large.") }
	return h, .None
}

AudioData_close :: proc(c: ^Call, a: Api_AudioData) {
	ad := a.data
	if ad == nil || ad.closed { return }
	ad.closed = true
	if ad.data != nil { c.page.held -= len(ad.data); delete(ad.data); ad.data = nil }
}

// Reads one sample (frame f, channel ch) as a normalized f32 in [-1, 1].
@(private)
audio_read_sample :: proc(ad: ^Audio_Data_Obj, f, ch: int) -> f32 {
	bytes := audio_format_bytes(ad.format)
	planar := audio_format_planar(ad.format)
	// index of the sample in `data`
	idx: int
	if planar { idx = (ch * ad.frames + f) * bytes } else { idx = (f * ad.channels + ch) * bytes }
	if idx + bytes > len(ad.data) { return 0 }
	p := ad.data[idx:]
	#partial switch ad.format {
	case .U8, .U8_Planar: return (f32(p[0]) - 128) / 128
	case .S16, .S16_Planar:
		v := i16(u16(p[0]) | u16(p[1]) << 8)
		return f32(v) / 32768
	case .S32, .S32_Planar:
		v := i32(u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24)
		return f32(f64(v) / 2147483648.0)
	case .F32, .F32_Planar:
		u := u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
		return transmute(f32)u
	}
	return 0
}

// Writes a normalized f32 sample into `dst` in `format`.
@(private)
audio_write_sample :: proc(dst: []u8, format: Audio_Sample_Format, v: f32) {
	#partial switch format {
	case .U8, .U8_Planar:
		s := clamp(v * 128 + 128, 0, 255)
		dst[0] = u8(s)
	case .S16, .S16_Planar:
		s := i16(clamp(v * 32768, -32768, 32767))
		u := u16(s)
		dst[0] = u8(u); dst[1] = u8(u >> 8)
	case .S32, .S32_Planar:
		s := i32(clamp(f64(v) * 2147483648.0, -2147483648.0, 2147483647.0))
		u := u32(s)
		dst[0] = u8(u); dst[1] = u8(u >> 8); dst[2] = u8(u >> 16); dst[3] = u8(u >> 24)
	case .F32, .F32_Planar:
		u := transmute(u32)v
		dst[0] = u8(u); dst[1] = u8(u >> 8); dst[2] = u8(u >> 16); dst[3] = u8(u >> 24)
	}
}

// Builds an AudioData (format f32-planar) from a decoded media.Audio_Block (interleaved f32). Used by AudioDecoder.
@(private)
audio_data_from_block_f32 :: proc(p: ^Page, owner: u32, samples: []f32, frames, channels: int, rate: f32, timestamp: i64) -> (u64, bool) {
	// store as f32 interleaved (the block's own layout), no conversion
	bytes := frames * channels * 4
	buf := make([]u8, bytes, context.temp_allocator)
	for i in 0 ..< frames * channels {
		u := transmute(u32)samples[i]
		buf[i * 4] = u8(u); buf[i * 4 + 1] = u8(u >> 8); buf[i * 4 + 2] = u8(u >> 16); buf[i * 4 + 3] = u8(u >> 24)
	}
	return audio_data_new(p, owner, .F32, rate, frames, channels, timestamp, buf)
}

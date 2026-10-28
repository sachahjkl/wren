package page

// WebCodecs AudioDecoder (api/webcodecs_audio_decoder.widl, native/js/runtime/web_webcodecs_audio_decoder.c). Wires to
// the audio decoders of src/media (Audio_Decoder) behind an honest isConfigSupported. A decoded block (interleaved f32
// PCM) is wrapped as AudioData (webcodecs_chunks.odin) and delivered through the output callback. The queue count, the
// state machine and the drain are native; the engine holds the callbacks and the dequeue listeners.

import "wb:base"
import "wb:media"

Audio_Decoder_Obj :: struct {
	page:        ^Page,
	self:        u64,
	state:       Video_Decoder_State,   // same three states as the video one
	dec:         ^media.Audio_Decoder,
	track:       media.Track,
	codec:       media.Codec,
	output_cb, output_user: u32,
	error_cb, error_user:   u32,
	queue:       int,
	owner:       u32,
}

audio_decoder_vt := Object_VTable{
	name = "AudioDecoder",
	destroy = proc(p: ^Page, data: rawptr) {
		d := (^Audio_Decoder_Obj)(data)
		audio_decoder_teardown(d)
		free(d)
	},
}

lookup_AudioDecoder :: proc(c: ^Call, h: u64) -> ^Audio_Decoder_Obj { return (^Audio_Decoder_Obj)(object_data(c.page, h, &audio_decoder_vt)) }

@(private)
audio_decoder_teardown :: proc(d: ^Audio_Decoder_Obj) {
	if d.dec != nil { if d.dec.destroy != nil { d.dec.destroy(d.dec) }; d.dec = nil }
	media.track_destroy(&d.track)
}

AudioDecoder_create :: proc(c: ^Call, output_cb: u32, output_user: i32, error_cb: u32, error_user: i32) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }
	d := new(Audio_Decoder_Obj)
	d.page = p
	d.owner = c.owner
	d.output_cb, d.output_user = output_cb, u32(output_user)
	d.error_cb, d.error_user = error_cb, u32(error_user)
	d.state = .Unconfigured
	d.self = object_create(p, &audio_decoder_vt, d, c.owner)
	return d.self, .None
}

// AudioDecoder.isConfigSupported(config): honest. AAC, MP3, Opus and FLAC are decoded by src/media; Vorbis and PCM are
// not (yet) decodable as standalone chunks here.
AudioDecoder_isConfigSupported :: proc(c: ^Call, codec: string) -> bool {
	cc := media.codec_of_string(codec)
	#partial switch cc {
	case .AAC, .MP3, .Opus, .FLAC:
		return media.backend_audio_support(cc).supported
	}
	return false
}

// configure(decoder, {codec, description, sampleRate, numberOfChannels}).
AudioDecoder_configure :: proc(c: ^Call, dec: Api_AudioDecoder, codec: string, description: []u8, sample_rate: u32, channels: u32) -> Api_Error {
	d := dec.data
	if d == nil || d.state == .Closed { return fail(c, .Invalid_State, "InvalidStateError: the AudioDecoder is closed.") }
	cc := media.codec_of_string(codec)
	supported := false
	#partial switch cc {
	case .AAC, .MP3, .Opus, .FLAC: supported = media.backend_audio_support(cc).supported
	}
	if !supported { return fail(c, .Not_Supported, "NotSupportedError: unsupported audio codec.") }

	audio_decoder_teardown(d)
	t: media.Track
	t.kind = .Audio
	t.codec = cc
	t.codec_string = clone_str_process(codec)
	t.sample_rate = int(sample_rate)
	t.channels = int(channels)
	t.timescale = 1_000_000
	if len(description) > 0 { t.config = clone_bytes_process(description) }
	d.track = t
	d.codec = cc
	d.dec = media.backend_audio_decoder(t)
	if d.dec == nil {
		media.track_destroy(&d.track)
		return fail(c, .Not_Supported, "NotSupportedError: no decoder could be made for this configuration.")
	}
	d.state = .Configured
	d.queue = 0
	return .None
}

AudioDecoder_decode :: proc(c: ^Call, dec: Api_AudioDecoder, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> Api_Error {
	d := dec.data
	if d == nil || d.state != .Configured || d.dec == nil { return fail(c, .Invalid_State, "InvalidStateError: the AudioDecoder is not configured.") }
	if d.queue >= d.page.settings.webcodecs.max_decode_queue { return fail(c, .Quota, "QuotaExceededError: the decode queue is full.") }

	s: media.Sample
	s.data = make([]u8, len(data), base.process_allocator())
	copy(s.data, data)
	s.pts = media.Time(timestamp * 1000)
	s.dts = s.pts
	s.duration = has_duration ? media.Time(duration * 1000) : 0
	if key { s.flags += {.Keyframe} }
	d.queue += 1

	if !d.dec.push(d.dec, &s) {
		audio_decoder_drain(d)
		if !d.dec.push(d.dec, &s) {
			media.sample_destroy(&s)
			d.queue -= 1
			audio_decoder_error(d, .Encoding, "the audio decoder could not accept the sample")
			return .None
		}
	}
	audio_decoder_drain(d)
	return .None
}

@(private)
audio_decoder_drain :: proc(d: ^Audio_Decoder_Obj) {
	if d.dec == nil || d.dec.pull == nil { return }
	for {
		block: media.Audio_Block
		r := d.dec.pull(d.dec, &block)
		#partial switch r {
		case .Frame:
			audio_decoder_emit(d, &block)
			media.audio_block_destroy(&block)
		case .Format_Changed:
			media.audio_block_destroy(&block)
			continue
		case .Need_Input:
			return
		case .Error:
			audio_decoder_error(d, .Encoding, "the audio decoder failed")
			return
		}
	}
}

@(private)
audio_decoder_emit :: proc(d: ^Audio_Decoder_Obj, block: ^media.Audio_Block) {
	if d.queue > 0 { d.queue -= 1 }
	if block.frames <= 0 || block.channels <= 0 || len(block.samples) < block.frames * block.channels { return }
	ts := i64(media.time_seconds(block.pts) * 1_000_000)
	handle, ok := audio_data_from_block_f32(d.page, d.owner, block.samples, block.frames, block.channels, f32(block.rate), ts)
	if !ok {
		audio_decoder_error(d, .Quota, "AudioData too large")
		return
	}
	audio_decoder_deliver(d, handle)
	audio_decoder_fire_dequeue(d)
}

@(private)
Audio_Output :: struct { page: u64, callback, user, instance: u32, data: u64 }

@(private)
audio_decoder_deliver :: proc(d: ^Audio_Decoder_Obj, data: u64) {
	gr := new_clone(Audio_Output{page = page_id(d.page), callback = d.output_cb, user = d.output_user, instance = d.owner, data = data})
	post_page_task(d.page, proc(p: ^Page, task: rawptr) {
		g := (^Audio_Output)(task)
		defer free(g)
		if p == nil || p.closed { if p != nil { object_release(p, g.data) }; return }
		inst := instance_by_index(p, g.instance)
		if inst == nil { object_release(p, g.data); return }
		argv := [3]u32{g.user, u32(g.data), u32(g.data >> 32)}
		call_guest(p, inst, g.callback, argv[:])
	}, gr)
}

@(private)
audio_decoder_fire_dequeue :: proc(d: ^Audio_Decoder_Obj) {
	if d.self == 0 || d.page.closed || !object_has_listener(d.page, d.self, "dequeue") { return }
	object_dispatch(d.page, d.self, {type = "dequeue"})
}

@(private)
audio_decoder_error :: proc(d: ^Audio_Decoder_Obj, code: Api_Error, msg: string) {
	if d.error_cb == 0 { log(d.page, .Error, msg); return }
	gr := new_clone(Video_Error{page = page_id(d.page), callback = d.error_cb, user = d.error_user, instance = d.owner, code = i32(code)})
	post_page_task(d.page, proc(p: ^Page, task: rawptr) {
		g := (^Video_Error)(task)
		defer free(g)
		if p == nil || p.closed { return }
		inst := instance_by_index(p, g.instance)
		if inst == nil { return }
		argv := [2]u32{g.user, u32(g.code)}
		call_guest(p, inst, g.callback, argv[:])
	}, gr)
}

AudioDecoder_decodeQueueSize :: proc(c: ^Call, dec: Api_AudioDecoder) -> u32 { return dec.data == nil ? 0 : u32(max(dec.data.queue, 0)) }
AudioDecoder_state :: proc(c: ^Call, dec: Api_AudioDecoder) -> i32 { return dec.data == nil ? 0 : i32(dec.data.state) }

AudioDecoder_flush :: proc(c: ^Call, dec: Api_AudioDecoder) -> Api_Error {
	d := dec.data
	if d == nil || d.state != .Configured || d.dec == nil { return fail(c, .Invalid_State, "InvalidStateError: the AudioDecoder is not configured.") }
	if d.dec.drain != nil { d.dec.drain(d.dec) }
	audio_decoder_drain(d)
	return .None
}

AudioDecoder_reset :: proc(c: ^Call, dec: Api_AudioDecoder) {
	d := dec.data
	if d == nil || d.state == .Closed { return }
	if d.dec != nil && d.dec.flush != nil { d.dec.flush(d.dec) }
	d.queue = 0
	d.state = .Unconfigured
}

AudioDecoder_close :: proc(c: ^Call, dec: Api_AudioDecoder) {
	d := dec.data
	if d == nil || d.state == .Closed { return }
	audio_decoder_teardown(d)
	d.state = .Closed
	d.queue = 0
}

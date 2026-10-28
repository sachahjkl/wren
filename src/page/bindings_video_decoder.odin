package page

// WebCodecs VideoDecoder (api/webcodecs_video_decoder.widl, native/js/runtime/web_webcodecs_video_decoder.c). Wires to
// the media decoders of src/media (Video_Decoder) behind an honest isConfigSupported. The decoder, the queue count and
// the state machine are native; the engine holds the output / error callbacks and the dequeue event listeners.
//
// A decoded picture is wrapped as a VideoFrame (webcodecs_frame.odin) from its CPU planes. The software decoders (VP9,
// AV1) produce CPU planes; a GPU-only picture (DXVA H.264) cannot be read back from here, so configure() prefers a
// software decoder and, if the only available decoder yields GPU textures, a decoded picture that has no CPU planes is
// reported through the error callback. isConfigSupported reflects what src/media reports for the codec.

import "wb:base"
import "wb:media"

Video_Decoder_State :: enum u8 { Unconfigured, Configured, Closed }

Video_Decoder_Obj :: struct {
	page:       ^Page,
	self:       u64,
	state:      Video_Decoder_State,
	dec:        ^media.Video_Decoder,
	track:      media.Track,       // the configured track (owns config bytes, process allocator)
	codec:      media.Codec,
	output_cb:  u32,               // guest function-table index: (user, frame_handle)
	error_cb:   u32,               // (user, code, message via a buffer) — we deliver (user, code) and log the message
	output_user: u32,
	error_user: u32,
	queue:      int,               // decodeQueueSize: chunks accepted but not yet output
	owner:      u32,
}

video_decoder_vt := Object_VTable{
	name = "VideoDecoder",
	destroy = proc(p: ^Page, data: rawptr) {
		d := (^Video_Decoder_Obj)(data)
		video_decoder_teardown(d)
		free(d)
	},
}

lookup_VideoDecoder :: proc(c: ^Call, h: u64) -> ^Video_Decoder_Obj { return (^Video_Decoder_Obj)(object_data(c.page, h, &video_decoder_vt)) }

@(private)
video_decoder_of :: proc(p: ^Page, h: u64) -> ^Video_Decoder_Obj { return (^Video_Decoder_Obj)(object_data(p, h, &video_decoder_vt)) }

@(private)
video_decoder_teardown :: proc(d: ^Video_Decoder_Obj) {
	if d.dec != nil { if d.dec.destroy != nil { d.dec.destroy(d.dec) }; d.dec = nil }
	media.track_destroy(&d.track)
}

// new VideoDecoder({output, error}): the engine passes the two callbacks (table index + user).
VideoDecoder_create :: proc(c: ^Call, output_cb: u32, output_user: i32, error_cb: u32, error_user: i32) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }
	d := new(Video_Decoder_Obj)
	d.page = p
	d.owner = c.owner
	d.output_cb, d.output_user = output_cb, u32(output_user)
	d.error_cb, d.error_user = error_cb, u32(error_user)
	d.state = .Unconfigured
	d.self = object_create(p, &video_decoder_vt, d, c.owner)
	return d.self, .None
}

// VideoDecoder.isConfigSupported(config): honest. Parses the codec string; checks src/media's support for that codec
// (which already respects the media.* preferences and the software fallbacks). Returns true only when a decoder can be
// made for it. The engine resolves a promise with { supported, config }.
VideoDecoder_isConfigSupported :: proc(c: ^Call, codec: string) -> bool {
	cc := media.codec_of_string(codec)
	#partial switch cc {
	case .H264, .HEVC, .VP8, .VP9, .AV1:
		return media.backend_video_support(cc).supported
	}
	return false
}

// configure(decoder, {codec, description, codedWidth, codedHeight}). `description` is the codec's configuration record
// (avcC / hvcC / av1C / vpcC). Builds a media.Track and a decoder. Not_Supported when the codec cannot be decoded.
VideoDecoder_configure :: proc(c: ^Call, dec: Api_VideoDecoder, codec: string, description: []u8, coded_w: u32, coded_h: u32) -> Api_Error {
	d := dec.data
	if d == nil || d.state == .Closed { return fail(c, .Invalid_State, "InvalidStateError: the VideoDecoder is closed.") }
	cc := media.codec_of_string(codec)
	supported := false
	#partial switch cc {
	case .H264, .HEVC, .VP8, .VP9, .AV1: supported = media.backend_video_support(cc).supported
	}
	if !supported { return fail(c, .Not_Supported, "NotSupportedError: unsupported video codec.") }

	// rebuild the track / decoder (reconfigure replaces the old one)
	video_decoder_teardown(d)
	t: media.Track
	t.kind = .Video
	t.codec = cc
	t.codec_string = clone_str_process(codec)
	t.width, t.height = int(coded_w), int(coded_h)
	t.timescale = 1_000_000   // WebCodecs timestamps are microseconds
	if len(description) > 0 { t.config = clone_bytes_process(description) }
	d.track = t
	d.codec = cc
	// prefer a software decoder so the output has CPU planes we can wrap; the backend falls to it where it can
	d.dec = media.backend_video_decoder(t, false)
	if d.dec == nil {
		media.track_destroy(&d.track)
		return fail(c, .Not_Supported, "NotSupportedError: no decoder could be made for this configuration.")
	}
	d.state = .Configured
	d.queue = 0
	return .None
}

@(private)
clone_str_process :: proc(s: string) -> string {
	if s == "" { return "" }
	b := make([]u8, len(s), base.process_allocator())
	copy(b, s)
	return string(b)
}

@(private)
clone_bytes_process :: proc(b: []u8) -> []u8 {
	if len(b) == 0 { return nil }
	c := make([]u8, len(b), base.process_allocator())
	copy(c, b)
	return c
}

// decode(chunk): push one coded sample and drain whatever pictures come out. The output VideoFrames are delivered
// through the output callback as page tasks (their reactions run at a clean checkpoint). Invalid_State when not
// configured; Quota when the queue is over the ceiling.
VideoDecoder_decode :: proc(c: ^Call, dec: Api_VideoDecoder, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> Api_Error {
	d := dec.data
	if d == nil || d.state != .Configured || d.dec == nil { return fail(c, .Invalid_State, "InvalidStateError: the VideoDecoder is not configured.") }
	if d.queue >= d.page.settings.webcodecs.max_decode_queue { return fail(c, .Quota, "QuotaExceededError: the decode queue is full.") }

	s: media.Sample
	s.data = make([]u8, len(data), base.process_allocator())
	copy(s.data, data)
	s.pts = media.Time(timestamp * 1000)       // microseconds -> nanoseconds
	s.dts = s.pts
	s.duration = has_duration ? media.Time(duration * 1000) : 0
	if key { s.flags += {.Keyframe} }
	d.queue += 1

	if !d.dec.push(d.dec, &s) {
		// the decoder refused because pictures are waiting: drain then retry once
		video_decoder_drain(d)
		if !d.dec.push(d.dec, &s) {
			media.sample_destroy(&s)
			d.queue -= 1
			video_decoder_error(d, .Encoding, "the video decoder could not accept the sample")
			return .None
		}
	}
	video_decoder_drain(d)
	return .None
}

// Pulls every ready picture and emits it.
@(private)
video_decoder_drain :: proc(d: ^Video_Decoder_Obj) {
	if d.dec == nil || d.dec.pull == nil { return }
	for {
		frame: media.Video_Frame
		r := d.dec.pull(d.dec, &frame)
		#partial switch r {
		case .Frame:
			video_decoder_emit(d, &frame)
			media.frame_release(&frame)
		case .Format_Changed:
			media.frame_release(&frame)
			continue
		case .Need_Input:
			return
		case .Error:
			video_decoder_error(d, .Encoding, "the video decoder failed")
			return
		}
	}
}

// Wraps a decoded picture as a VideoFrame and delivers it through the output callback.
@(private)
video_decoder_emit :: proc(d: ^Video_Decoder_Obj, frame: ^media.Video_Frame) {
	if d.queue > 0 { d.queue -= 1 }
	fp, ok := video_pixels_from_media(d.page, frame)
	if !ok {
		// a GPU-only picture (no CPU planes) cannot be wrapped here
		video_decoder_error(d, .Not_Supported, "the decoder produced a GPU-only picture that cannot be read back; a software decoder is required")
		return
	}
	ts := i64(media.time_seconds(frame.pts) * 1_000_000)
	dur := i64(media.time_seconds(frame.duration) * 1_000_000)
	handle := video_frame_new(d.page, d.owner, fp, ts, dur, frame.duration != 0)
	video_decoder_deliver(d, handle)
	video_decoder_fire_dequeue(d)
}

// Posts the output callback with (user, frame_handle_lo, frame_handle_hi) on the owning realm.
@(private)
Video_Output :: struct { page: u64, callback, user, instance: u32, frame: u64 }

@(private)
video_decoder_deliver :: proc(d: ^Video_Decoder_Obj, frame: u64) {
	gr := new_clone(Video_Output{page = page_id(d.page), callback = d.output_cb, user = d.output_user, instance = d.owner, frame = frame})
	post_page_task(d.page, proc(p: ^Page, data: rawptr) {
		g := (^Video_Output)(data)
		defer free(g)
		if p == nil || p.closed { if p != nil { object_release(p, g.frame) }; return }
		inst := instance_by_index(p, g.instance)
		if inst == nil { object_release(p, g.frame); return }
		argv := [3]u32{g.user, u32(g.frame), u32(g.frame >> 32)}
		call_guest(p, inst, g.callback, argv[:])
	}, gr)
}

// The dequeue event: fired at the decoder object when the queue shrinks (decodeQueueSize changed).
@(private)
video_decoder_fire_dequeue :: proc(d: ^Video_Decoder_Obj) {
	if d.self == 0 || d.page.closed { return }
	if !object_has_listener(d.page, d.self, "dequeue") { return }
	object_dispatch(d.page, d.self, {type = "dequeue"})
}

@(private)
video_decoder_error :: proc(d: ^Video_Decoder_Obj, code: Api_Error, msg: string) {
	if d.error_cb == 0 { log(d.page, .Error, msg); return }
	gr := new_clone(Video_Error{page = page_id(d.page), callback = d.error_cb, user = d.error_user, instance = d.owner, code = i32(code)})
	post_page_task(d.page, proc(p: ^Page, data: rawptr) {
		g := (^Video_Error)(data)
		defer free(g)
		if p == nil || p.closed { return }
		inst := instance_by_index(p, g.instance)
		if inst == nil { return }
		argv := [2]u32{g.user, u32(g.code)}
		call_guest(p, inst, g.callback, argv[:])
	}, gr)
}

@(private)
Video_Error :: struct { page: u64, callback, user, instance: u32, code: i32 }

VideoDecoder_decodeQueueSize :: proc(c: ^Call, dec: Api_VideoDecoder) -> u32 { return dec.data == nil ? 0 : u32(max(dec.data.queue, 0)) }

VideoDecoder_state :: proc(c: ^Call, dec: Api_VideoDecoder) -> i32 { return dec.data == nil ? 0 : i32(dec.data.state) }

// flush(): drain everything still buffered in the decoder (its drain callback empties the pipeline), then the engine
// resolves the flush promise. Synchronous here.
VideoDecoder_flush :: proc(c: ^Call, dec: Api_VideoDecoder) -> Api_Error {
	d := dec.data
	if d == nil || d.state != .Configured || d.dec == nil { return fail(c, .Invalid_State, "InvalidStateError: the VideoDecoder is not configured.") }
	if d.dec.drain != nil { d.dec.drain(d.dec) }
	video_decoder_drain(d)
	return .None
}

VideoDecoder_reset :: proc(c: ^Call, dec: Api_VideoDecoder) {
	d := dec.data
	if d == nil || d.state == .Closed { return }
	if d.dec != nil && d.dec.flush != nil { d.dec.flush(d.dec) }
	d.queue = 0
	d.state = .Unconfigured
}

VideoDecoder_close :: proc(c: ^Call, dec: Api_VideoDecoder) {
	d := dec.data
	if d == nil || d.state == .Closed { return }
	video_decoder_teardown(d)
	d.state = .Closed
	d.queue = 0
}

// Builds Video_Pixels from a decoded media frame's CPU planes. Returns ok = false for a GPU-only frame (no planes).
@(private)
video_pixels_from_media :: proc(p: ^Page, frame: ^media.Video_Frame) -> (fp: Video_Pixels, ok: bool) {
	if frame.planes[0] == nil { return }
	w, h := frame.width, frame.height
	if w <= 0 || h <= 0 { return }
	// NV12 / P010 stays NV12 (8-bit) by down-shifting P010; I420 / I420_10 stays I420. We store 8-bit.
	format: Frame_Format
	#partial switch frame.format {
	case .NV12, .P010: format = .NV12
	case .I420, .I420_10: format = .I420
	case: return
	}
	fp, ok = frame_pixels_alloc(p, format, w, h)
	if !ok { return Video_Pixels{}, false }
	fp.color = frame_color_from_media(frame.color)
	cx0, cy0 := frame.crop[0], frame.crop[1]
	if format == .NV12 {
		p10 := frame.format == .P010
		for y in 0 ..< h {
			src := frame.planes[0][(cy0 + y) * frame.strides[0]:]
			dst := fp.pix[fp.offsets[0] + y * fp.strides[0]:]
			for x in 0 ..< w { dst[x] = media_sample8(src, cx0 + x, 8, p10) }
		}
		ch := (h + 1) / 2
		for y in 0 ..< ch {
			src := frame.planes[1][(cy0 / 2 + y) * frame.strides[1]:]
			dst := fp.pix[fp.offsets[1] + y * fp.strides[1]:]
			cw := (w + 1) / 2
			for x in 0 ..< cw {
				dst[x * 2] = media_sample8(src, (cx0 / 2 + x) * 2, 8, p10)
				dst[x * 2 + 1] = media_sample8(src, (cx0 / 2 + x) * 2 + 1, 8, p10)
			}
		}
	} else {
		p10 := frame.format == .I420_10
		for y in 0 ..< h {
			src := frame.planes[0][(cy0 + y) * frame.strides[0]:]
			dst := fp.pix[fp.offsets[0] + y * fp.strides[0]:]
			for x in 0 ..< w { dst[x] = media_sample8(src, cx0 + x, 8, p10) }
		}
		cw, chh := (w + 1) / 2, (h + 1) / 2
		for plane in 1 ..= 2 {
			for y in 0 ..< chh {
				src := frame.planes[plane][(cy0 / 2 + y) * frame.strides[plane]:]
				dst := fp.pix[fp.offsets[plane] + y * fp.strides[plane]:]
				for x in 0 ..< cw { dst[x] = media_sample8(src, cx0 / 2 + x, 8, p10) }
			}
		}
	}
	return fp, true
}

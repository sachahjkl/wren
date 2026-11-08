package media

// AV1 decoded in software by the built-in decoder (rav1d in native/media: av1video.rs), on every system: the AV1 decoder
// of a system without one of its own (Linux), behind the same Video_Decoder interface. Pictures come out as planes in
// memory (I420, or I420_10 for 10-bit streams), held by the decoder until the player releases them.

import "core:sync"
import "wb:base"
import "wb:host"

when ODIN_OS == .Windows {
	foreign import wren_native_media {
		"../../build/native/wren_native.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:kernel32.lib",
		"system:bcrypt.lib",
		"system:libcmt.lib",
		"system:libucrt.lib",
		"system:libvcruntime.lib",
	}
} else {
	foreign import wren_native_media { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:fontconfig", "system:opus", "system:asound", "system:dl", "system:pthread", "system:m" }
}

@(private)
Av1_Picture :: struct {
	width, height, bits, layout: u32,
	planes:  [3][^]u8,
	strides: [3]int,
	pts:     i64,
	primaries, transfer, coeffs: u16,
	full_range: u8,
	handle:  rawptr,
}

@(private, default_calling_convention = "c")
foreign wren_native_media {
	wm_av1_open    :: proc(threads: u32, max_pixels: u64, out: ^rawptr) -> i32 ---
	wm_av1_send    :: proc(d: rawptr, data: [^]u8, len: uint, pts: i64) -> i32 ---
	wm_av1_get     :: proc(d: rawptr, pic: ^Av1_Picture) -> i32 ---
	wm_av1_release :: proc(handle: rawptr) ---
	wm_av1_flush   :: proc(d: rawptr) ---
	wm_av1_close   :: proc(d: rawptr) ---
}

// Threads of one software decode (media.software.threads; 0: half the processors). Read when a decoder is made.
@(private)
software_threads: int

set_software_threads :: proc(n: int) { sync.atomic_store(&software_threads, n) }

// Whether the built-in software decoders stand in when the system has none for a codec (media.software.vp9_fallback /
// media.software.av1_fallback). On Linux there is no system decoder, so the backend uses them regardless; these gate
// the Windows fallback. Read when a decoder is made and when support is asked (canPlayType).
@(private)
software_vp9: b32 = true
@(private)
software_av1: b32 = true

set_software_fallbacks :: proc(vp9, av1: bool) {
	sync.atomic_store(&software_vp9, b32(vp9))
	sync.atomic_store(&software_av1, b32(av1))
}

// media.software.prefer_builtin: the built-in decoders of a codec come before the system's. What a machine without the system's
// decoder runs, on any machine.
@(private)
software_preferred: b32

set_software_preferred :: proc(on: bool) { sync.atomic_store(&software_preferred, b32(on)) }
software_is_preferred :: proc() -> bool { return bool(sync.atomic_load(&software_preferred)) }

software_vp9_enabled :: proc() -> bool { return bool(sync.atomic_load(&software_vp9)) }
software_av1_enabled :: proc() -> bool { return bool(sync.atomic_load(&software_av1)) }

@(private)
AV1_MAX_PIXELS :: u64(8192 * 8192)   // the largest picture of AV1's level 6.3; the container's limits come first
// What wm_av1_get answers (anything else: an error).
@(private)
AV1_GET_PICTURE :: 0
@(private)
AV1_GET_NOTHING :: 1

// Asking rav1d for a picture again with nothing sent since is what tells it to drain: it hands out the frames in flight and moves its
// queues on. In the middle of a stream, on a machine short of processors (two task threads, a CI runner), that leaves its workers
// parked with a frame unfinished, and the next send or get waits for that frame for ever. So: one question per coded frame, as
// long as more may come, and the questions that drain only at the end of the data.
@(private)
Av1_Output :: enum u8 {
	May_Ask,       // a coded frame went in: one question
	Asked,         // the question of that frame was put: nothing more until the next one
	Drain_Start,   // no more data: the first question may still be an ordinary one, whose answer says nothing of the end
	Draining,      // rav1d is draining: its answer "nothing" is the end
}

@(private)
Av1_Soft :: struct {
	ctx:      rawptr,
	track:    Track,
	refs:     int,      // atomic: the decoder itself and every picture handed out; the last one closes the context
	output:   Av1_Output,
	questions: int,     // wm_av1_get so far (av1_software_asks_one_question_per_coded_frame counts them)
}

av1_soft_supported :: proc() -> Decoder_Support { return {supported = true} }

av1_soft_create :: proc(track: Track) -> ^Video_Decoder {
	threads := sync.atomic_load(&software_threads)
	if threads <= 0 { threads = max(host.processor_count() / 2, 1) }
	ctx: rawptr
	if wm_av1_open(u32(threads), AV1_MAX_PIXELS, &ctx) != 0 || ctx == nil { return nil }
	a := new(Av1_Soft, base.process_allocator())
	a.ctx = ctx
	a.refs = 1
	a.track = track_clone(track)
	d := new(Video_Decoder, base.process_allocator())
	d.impl = a
	d.name = "AV1 (software)"
	d.push = av1_soft_push
	d.pull = av1_soft_pull
	d.flush = av1_soft_flush
	d.drain = av1_soft_drain
	d.destroy = av1_soft_destroy
	return d
}

@(private)
av1_soft_push :: proc(d: ^Video_Decoder, s: ^Sample) -> bool {
	a := (^Av1_Soft)(d.impl)
	if len(s.data) == 0 { return true }
	a.output = .May_Ask   // (refused too: rav1d stopped draining, and the picture it wants taken is the answer)
	r := wm_av1_send(a.ctx, raw_data(s.data), uint(len(s.data)), i64(s.pts))
	return r != 1   // 1: refused (pull first); an error drops the sample, the next keyframe recovers
}

@(private)
Av1_Frame_Owner :: struct { a: ^Av1_Soft, handle: rawptr }

@(private)
av1_soft_pull :: proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result {
	a := (^Av1_Soft)(d.impl)
	if a.output == .Asked { return .Need_Input }
	pic: Av1_Picture
	a.questions += 1
	answer := wm_av1_get(a.ctx, &pic)
	switch a.output {
	case .May_Ask:     a.output = .Asked
	case .Asked:
	case .Draining:
	case .Drain_Start:
		a.output = .Draining
		if answer == AV1_GET_NOTHING { answer = wm_av1_get(a.ctx, &pic) }
	}
	switch answer {
	case AV1_GET_PICTURE:
	case AV1_GET_NOTHING: return .Need_Input
	case:                 return .Error
	}
	if pic.layout != 0 {
		// 4:2:2, 4:4:4 and monochrome are not drawn yet: the picture is dropped (the stream plays on, without it)
		wm_av1_release(pic.handle)
		return .Error
	}
	o := new(Av1_Frame_Owner, base.process_allocator())
	o.a, o.handle = a, pic.handle
	sync.atomic_add(&a.refs, 1)
	w, h := int(pic.width), int(pic.height)
	out^ = Video_Frame{
		pts = Time(pic.pts), format = pic.bits > 8 ? .I420_10 : .I420,
		width = w, height = h, surface = {w, h},
		color = color_of_cicp(pic.primaries, pic.transfer, pic.coeffs, pic.full_range != 0),
		planes = {pic.planes[0][:pic.strides[0] * h], pic.planes[1][:pic.strides[1] * ((h + 1) / 2)], pic.planes[2][:pic.strides[2] * ((h + 1) / 2)]},
		strides = pic.strides,
		backend = o, release = av1_frame_release,
	}
	return .Frame
}

@(private)
av1_frame_release :: proc(f: ^Video_Frame) {
	o := (^Av1_Frame_Owner)(f.backend)
	if o == nil { return }
	a := o.a
	wm_av1_release(o.handle)
	free(o, base.process_allocator())
	if sync.atomic_sub(&a.refs, 1) == 1 { av1_soft_free(a) }
}

// H.273 codes as the player's colour description.
@(private)
color_of_cicp :: proc(primaries, transfer, coeffs: u16, full: bool) -> Color_Info {
	c := Color_Info{full_range = full, primaries = u8(min(primaries, 255))}
	switch coeffs {
	case 1:     c.coeffs = .BT709
	case 5, 6:  c.coeffs = .BT601
	case 9, 10: c.coeffs = .BT2020
	case 7:     c.coeffs = .SMPTE240
	case 0:     c.coeffs = .Identity
	}
	switch transfer {
	case 16: c.transfer = .PQ
	case 18: c.transfer = .HLG
	case 1, 6, 13, 14, 15: c.transfer = .SDR
	}
	c.known = coeffs != 2 || transfer != 2 || primaries != 2
	return c
}

@(private)
av1_soft_flush :: proc(d: ^Video_Decoder) {
	a := (^Av1_Soft)(d.impl)
	a.output = .May_Ask
	wm_av1_flush(a.ctx)
}

// No more input: the pictures still held come out of pull.
@(private)
av1_soft_drain :: proc(d: ^Video_Decoder) { (^Av1_Soft)(d.impl).output = .Drain_Start }

@(private)
av1_soft_free :: proc(a: ^Av1_Soft) {
	wm_av1_close(a.ctx)
	track_destroy(&a.track)
	free(a, base.process_allocator())
}

@(private)
av1_soft_destroy :: proc(d: ^Video_Decoder) {
	a := (^Av1_Soft)(d.impl)
	free(d, base.process_allocator())
	if sync.atomic_sub(&a.refs, 1) == 1 { av1_soft_free(a) }
}

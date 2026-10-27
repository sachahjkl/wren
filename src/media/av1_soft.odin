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
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
	}
} else {
	foreign import wren_native_media { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:dl", "system:pthread", "system:m" }
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

software_vp9_enabled :: proc() -> bool { return bool(sync.atomic_load(&software_vp9)) }
software_av1_enabled :: proc() -> bool { return bool(sync.atomic_load(&software_av1)) }

@(private)
AV1_MAX_PIXELS :: u64(8192 * 8192)   // the largest picture of AV1's level 6.3; the container's limits come first

@(private)
Av1_Soft :: struct {
	ctx:      rawptr,
	track:    Track,
	refs:     int,      // atomic: the decoder itself and every picture handed out; the last one closes the context
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
	r := wm_av1_send(a.ctx, raw_data(s.data), uint(len(s.data)), i64(s.pts))
	return r != 1   // 1: refused (pull first); an error drops the sample, the next keyframe recovers
}

@(private)
Av1_Frame_Owner :: struct { a: ^Av1_Soft, handle: rawptr }

@(private)
av1_soft_pull :: proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result {
	a := (^Av1_Soft)(d.impl)
	pic: Av1_Picture
	switch wm_av1_get(a.ctx, &pic) {
	case 0:
	case 1: return .Need_Input
	case:   return .Error
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
av1_soft_flush :: proc(d: ^Video_Decoder) { wm_av1_flush((^Av1_Soft)(d.impl).ctx) }

// No more input: the pictures still held come out of pull (rav1d drains when asked with nothing to send).
@(private)
av1_soft_drain :: proc(d: ^Video_Decoder) {}

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

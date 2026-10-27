package media

// VP9 decoded in software by the built-in decoder (vp9dec in native/media: vp9video.rs), on every system, behind the
// same Video_Decoder interface as the AV1 software decoder (av1_soft.odin). YouTube serves VP9 for its high
// resolutions; a machine without the system's VP9 decoder (no Media Foundation VP9 Store extension) falls to this one
// instead of dropping to a lower-resolution codec. Pictures come out as planes in memory (I420, or I420_10 for
// 10/12-bit streams), held by the decoder until the player releases them.
//
// vp9dec is a from-scratch pure-Rust decoder (no C), so VP9 needs no build-time toolchain of its own. It does not read
// the colour description from the bitstream, so the container's (the vpcC / webm colour element: track.color) is used.

import "core:sync"
import "wb:base"

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
Vp9_Picture :: struct {
	width, height, bits, layout: u32,
	planes:  [3][^]u8,
	strides: [3]int,
	pts:     i64,
	handle:  rawptr,
}

@(private, default_calling_convention = "c")
foreign wren_native_media {
	wm_vp9_open    :: proc(max_pixels: u64, out: ^rawptr) -> i32 ---
	wm_vp9_send    :: proc(d: rawptr, data: [^]u8, len: uint, pts: i64) -> i32 ---
	wm_vp9_get     :: proc(d: rawptr, pic: ^Vp9_Picture) -> i32 ---
	wm_vp9_release :: proc(handle: rawptr) ---
	wm_vp9_flush   :: proc(d: rawptr) ---
	wm_vp9_close   :: proc(d: rawptr) ---
}

@(private)
VP9_MAX_PIXELS :: u64(8192 * 8192)   // VP9 level 6.2's largest picture; the container's limits come first

@(private)
Vp9_Soft :: struct {
	ctx:   rawptr,
	track: Track,
	refs:  int,      // atomic: the decoder itself and every picture handed out; the last one closes the context
}

vp9_soft_supported :: proc() -> Decoder_Support { return {supported = true} }

vp9_soft_create :: proc(track: Track) -> ^Video_Decoder {
	ctx: rawptr
	if wm_vp9_open(VP9_MAX_PIXELS, &ctx) != 0 || ctx == nil { return nil }
	v := new(Vp9_Soft, base.process_allocator())
	v.ctx = ctx
	v.refs = 1
	v.track = track_clone(track)
	d := new(Video_Decoder, base.process_allocator())
	d.impl = v
	d.name = "VP9 (software)"
	d.push = vp9_soft_push
	d.pull = vp9_soft_pull
	d.flush = vp9_soft_flush
	d.drain = vp9_soft_drain
	d.destroy = vp9_soft_destroy
	return d
}

@(private)
vp9_soft_push :: proc(d: ^Video_Decoder, s: ^Sample) -> bool {
	v := (^Vp9_Soft)(d.impl)
	if len(s.data) == 0 { return true }
	r := wm_vp9_send(v.ctx, raw_data(s.data), uint(len(s.data)), i64(s.pts))
	return r != 1   // 1: refused (pull first); an error drops the sample, the next keyframe recovers
}

@(private)
Vp9_Frame_Owner :: struct { v: ^Vp9_Soft, handle: rawptr }

@(private)
vp9_soft_pull :: proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result {
	v := (^Vp9_Soft)(d.impl)
	pic: Vp9_Picture
	switch wm_vp9_get(v.ctx, &pic) {
	case 0:
	case 1: return .Need_Input
	case:   return .Error
	}
	if pic.layout != 0 {
		// 4:2:2, 4:4:4 and monochrome are not drawn yet: the picture is dropped (the stream plays on, without it)
		wm_vp9_release(pic.handle)
		return .Error
	}
	o := new(Vp9_Frame_Owner, base.process_allocator())
	o.v, o.handle = v, pic.handle
	sync.atomic_add(&v.refs, 1)
	w, h := int(pic.width), int(pic.height)
	out^ = Video_Frame{
		pts = Time(pic.pts), format = pic.bits > 8 ? .I420_10 : .I420,
		width = w, height = h, surface = {w, h},
		color = v.track.color,
		rotation = v.track.rotation,
		planes = {pic.planes[0][:pic.strides[0] * h], pic.planes[1][:pic.strides[1] * ((h + 1) / 2)], pic.planes[2][:pic.strides[2] * ((h + 1) / 2)]},
		strides = pic.strides,
		backend = o, release = vp9_frame_release,
	}
	return .Frame
}

@(private)
vp9_frame_release :: proc(f: ^Video_Frame) {
	o := (^Vp9_Frame_Owner)(f.backend)
	if o == nil { return }
	v := o.v
	wm_vp9_release(o.handle)
	free(o, base.process_allocator())
	if sync.atomic_sub(&v.refs, 1) == 1 { vp9_soft_free(v) }
}

@(private)
vp9_soft_flush :: proc(d: ^Video_Decoder) { wm_vp9_flush((^Vp9_Soft)(d.impl).ctx) }

// No more input: vp9dec queues every picture of a chunk as it decodes, so there is nothing left to drain.
@(private)
vp9_soft_drain :: proc(d: ^Video_Decoder) {}

@(private)
vp9_soft_free :: proc(v: ^Vp9_Soft) {
	wm_vp9_close(v.ctx)
	track_destroy(&v.track)
	free(v, base.process_allocator())
}

@(private)
vp9_soft_destroy :: proc(d: ^Video_Decoder) {
	v := (^Vp9_Soft)(d.impl)
	free(d, base.process_allocator())
	if sync.atomic_sub(&v.refs, 1) == 1 { vp9_soft_free(v) }
}

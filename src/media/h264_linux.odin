#+build !windows
package media

// H.264 decoding on Linux, behind the Video_Decoder interface, the counterpart of Media Foundation's DXVA path on
// Windows. Two decoders, chosen by media.h264.backend and what is present:
//
//   openh264   Cisco's decoder, loaded at run time by dlopen of libopenh264.so (never built from source: the patent
//              licence Cisco pays covers only the binaries it ships, which tools/fetch_openh264.sh downloads with its
//              SHA-256 pinned). Software, always available once the library is on disk. Output: I420 in memory.
//   VA-API     the GPU's decoder (vaapi_linux.odin), the Linux counterpart of DXVA; tried first when the preference
//              allows hardware and a device opens. Output: I420 in memory (planes mapped from the surface).
//
// Both take Annex B (start codes, parameter sets in the stream): the container stores length-prefixed NAL units with
// the parameter sets in an avcC record, so a sample is turned to Annex B (annexb.odin) before it is fed.

import "core:sync"
import "core:sys/posix"
import "wb:base"

// media.h264.backend: which H.264 decoder to prefer. Read when a decoder is made.
@(private)
H264_Backend :: enum u8 { Auto, Vaapi, Openh264, Off }

@(private)
h264_backend: H264_Backend

@(private)
h264_openh264_path: [512]u8   // a preference may name the library (media.h264.openh264_path); empty: the default search
@(private)
h264_openh264_path_len: int
@(private)
h264_path_mu: sync.Mutex

set_h264_backend :: proc(b: H264_Backend) { sync.atomic_store((^u8)(&h264_backend), u8(b)) }

set_h264_openh264_path :: proc(path: string) {
	sync.mutex_lock(&h264_path_mu)
	defer sync.mutex_unlock(&h264_path_mu)
	n := min(len(path), len(h264_openh264_path) - 1)
	copy(h264_openh264_path[:n], path[:n])
	h264_openh264_path[n] = 0
	h264_openh264_path_len = n
}

@(private)
h264_configured_path :: proc() -> string {
	sync.mutex_lock(&h264_path_mu)
	defer sync.mutex_unlock(&h264_path_mu)
	return string(h264_openh264_path[:h264_openh264_path_len])
}

// media.h264.backend (settings_from_prefs; neutral setters exist per platform).
apply_h264_prefs :: proc(backend: string, openh264_path: string) {
	b := H264_Backend.Auto
	switch backend {
	case "vaapi":    b = .Vaapi
	case "openh264": b = .Openh264
	case "off":      b = .Off
	}
	set_h264_backend(b)
	set_h264_openh264_path(openh264_path)
}

h264_supported :: proc() -> Decoder_Support {
	switch H264_Backend(sync.atomic_load((^u8)(&h264_backend))) {
	case .Off:      return {}
	case .Openh264: return {supported = openh264_available()}
	case .Vaapi:    return {supported = vaapi_available(), hardware = true}
	case .Auto:
		if vaapi_available() { return {supported = true, hardware = true} }
		return {supported = openh264_available()}
	}
	return {}
}

h264_create :: proc(track: Track, prefer_gpu: bool) -> ^Video_Decoder {
	b := H264_Backend(sync.atomic_load((^u8)(&h264_backend)))
	if b == .Off { return nil }
	try_vaapi := prefer_gpu && (b == .Auto || b == .Vaapi)
	if try_vaapi {
		if d := vaapi_h264_create(track); d != nil { return d }
		if b == .Vaapi { return nil }   // asked for hardware only
	}
	if b == .Auto || b == .Openh264 {
		return openh264_create(track)
	}
	return nil
}

////////////////////////////////
// openh264 by dlopen

// The OpenH264 C API (codec_api.h). The decoder is created by the exported WelsCreateDecoder; its methods are a C++
// vtable, which we call through pointers at the fixed slots of ISVCDecoder (the order is part of the stable ABI since
// 1.x). Only the methods the player needs are declared.

@(private)
Openh264_Vtable :: struct {
	Initialize:            proc "c" (self: rawptr, param: ^SDecodingParam) -> i32,
	Uninitialize:          proc "c" (self: rawptr) -> i32,
	DecodeFrameNoDelay:    proc "c" (self: rawptr, src: [^]u8, src_len: i32, dst: ^[3][^]u8, info: ^SBufferInfo) -> i32,
	DecodeFrame2:          rawptr,
	FlushFrame:            proc "c" (self: rawptr, dst: ^[3][^]u8, info: ^SBufferInfo) -> i32,
	DecodeParser:          rawptr,
	DecodeFrameEx:         rawptr,
	SetOption:             proc "c" (self: rawptr, opt: i32, value: rawptr) -> i32,
	GetOption:             proc "c" (self: rawptr, opt: i32, value: rawptr) -> i32,
}

@(private)
SDecodingParam :: struct {
	pFileNameRestructed: cstring,
	uiCpuLoad:           u32,
	uiTargetDqLayer:     u8,
	eEcActiveIdc:        i32,
	bParseOnly:          b32,
	sVideoProperty:      SVideoProperty,
}

@(private)
SVideoProperty :: struct { size: u32, eVideoBsType: i32 }

@(private)
SSysMEMBuffer :: struct {
	iWidth:   i32,
	iHeight:  i32,
	iFormat:  i32,
	iStride:  [2]i32,
}

@(private)
SBufferInfo :: struct {
	iBufferStatus: i32,        // 1: a frame is ready in the output pointers
	uiInBsTimeStamp:  u64,
	uiOutYuvTimeStamp: u64,
	// a union of a system-memory buffer description and a Dved one; the system one is what the decoder fills
	UsrData:  SSysMEMBuffer,
}

// decoded frame output (dsErrorFree == 0 means no error for the whole picture)
DECODING_STATE_ERROR_FREE :: 0
VIDEO_BITSTREAM_AVC :: 0
ERROR_CON_SLICE_COPY_CROSS_IDR_FREEZE_RES_CHANGE :: 0

@(private)
Openh264_Lib :: struct {
	handle:  posix.Symbol_Table,
	create:  proc "c" (out: ^rawptr) -> i32,
	destroy: proc "c" (dec: rawptr),
}

@(private)
openh264_lib: Openh264_Lib
@(private)
openh264_once: sync.Once
@(private)
openh264_ok: bool

// The library names tried, newest soname first, then a Wren-managed copy. media.h264.openh264_path overrides the list.
@(private)
OPENH264_SONAMES :: [?]string{
	"libopenh264.so.7", "libopenh264.so.6", "libopenh264.so.5", "libopenh264.so.2", "libopenh264.so",
}

@(private)
openh264_load :: proc() {
	flags := posix.RTLD_LOCAL + {.NOW}
	try_open :: proc(name: string, flags: posix.RTLD_Flags) -> posix.Symbol_Table {
		c := make([]u8, len(name) + 1, context.temp_allocator)
		copy(c, name)
		c[len(name)] = 0
		return posix.dlopen(cstring(raw_data(c)), flags)
	}
	h: posix.Symbol_Table
	if p := h264_configured_path(); len(p) > 0 {
		h = try_open(p, flags)
	}
	if h == nil {
		// The system's library, by its soname (tools/fetch_openh264.sh can place Cisco's binary where ldconfig finds it,
		// or a preference can name it directly: media.h264.openh264_path).
		for name in OPENH264_SONAMES {
			h = try_open(name, flags)
			if h != nil { break }
		}
	}
	if h == nil { return }
	create := posix.dlsym(h, "WelsCreateDecoder")
	destroy := posix.dlsym(h, "WelsDestroyDecoder")
	if create == nil || destroy == nil {
		posix.dlclose(h)
		return
	}
	openh264_lib.handle = h
	openh264_lib.create = auto_cast create
	openh264_lib.destroy = auto_cast destroy
	openh264_ok = true
}

@(private)
openh264_available :: proc() -> bool {
	sync.once_do(&openh264_once, openh264_load)
	return openh264_ok
}

@(private)
Openh264_Decoder :: struct {
	dec:    rawptr,                 // ISVCDecoder*
	vt:     ^Openh264_Vtable,
	track:  Track,
	prefix: [dynamic]u8,            // avcC parameter sets as Annex B, prepended to keyframes
	scratch: [dynamic]u8,           // the Annex B of one sample
	// one picture at a time: the planes point into the decoder's own buffers (valid until the next decode)
	pic:    Video_Frame,
	has_pic: bool,
	eos:    bool,
}

@(private)
openh264_create :: proc(track: Track) -> ^Video_Decoder {
	if !openh264_available() { return nil }
	dec: rawptr
	if openh264_lib.create(&dec) != 0 || dec == nil { return nil }
	// ISVCDecoder* points at its vtable pointer (C++ ABI).
	vt := (^^Openh264_Vtable)(dec)^
	o := new(Openh264_Decoder, base.process_allocator())
	o.dec = dec
	o.vt = vt
	o.track = track_clone(track)
	o.prefix = make([dynamic]u8, 0, 64, base.process_allocator())
	append(&o.prefix, ..avcc_annexb_header(track.config, base.process_allocator()))
	o.scratch = make([dynamic]u8, 0, 4096, base.process_allocator())
	param := SDecodingParam{
		uiTargetDqLayer = 0xff,
		eEcActiveIdc = ERROR_CON_SLICE_COPY_CROSS_IDR_FREEZE_RES_CHANGE,
		sVideoProperty = {size = size_of(SVideoProperty), eVideoBsType = VIDEO_BITSTREAM_AVC},
	}
	if o.vt.Initialize(o.dec, &param) != 0 {
		openh264_lib.destroy(o.dec)
		track_destroy(&o.track)
		delete(o.prefix); delete(o.scratch)
		free(o, base.process_allocator())
		return nil
	}
	d := new(Video_Decoder, base.process_allocator())
	d.impl = o
	d.name = "H.264 (openh264)"
	d.push = openh264_push
	d.pull = openh264_pull
	d.flush = openh264_flush
	d.drain = openh264_drain
	d.destroy = openh264_destroy
	return d
}

@(private)
openh264_feed :: proc(o: ^Openh264_Decoder, annexb: []u8, pts: i64) -> bool {
	dst: [3][^]u8
	info: SBufferInfo
	st := o.vt.DecodeFrameNoDelay(o.dec, raw_data(annexb), i32(len(annexb)), &dst, &info)
	if st != DECODING_STATE_ERROR_FREE { return false }
	if info.iBufferStatus != 1 { return false }   // no picture out of this access unit yet
	openh264_take(o, dst, info, pts)
	return true
}

@(private)
openh264_take :: proc(o: ^Openh264_Decoder, dst: [3][^]u8, info: SBufferInfo, pts: i64) {
	b := info.UsrData
	w, h := int(b.iWidth), int(b.iHeight)
	if w <= 0 || h <= 0 { return }
	cstride := int(b.iStride[1])
	o.pic = Video_Frame{
		pts = Time(pts), format = .I420,
		width = w, height = h, surface = {w, h},
		color = color_of_cicp(1, 1, 1, false),   // H.264 in the browser: BT.709 limited unless VUI says otherwise (not parsed here)
		planes = {dst[0][:int(b.iStride[0]) * h], dst[1][:cstride * ((h + 1) / 2)], dst[2][:cstride * ((h + 1) / 2)]},
		strides = {int(b.iStride[0]), cstride, cstride},
		rotation = o.track.rotation,
		// no backend / release: the planes are the decoder's, overwritten by the next decode; the player copies on present
	}
	o.has_pic = true
}

@(private)
openh264_push :: proc(d: ^Video_Decoder, s: ^Sample) -> bool {
	o := (^Openh264_Decoder)(d.impl)
	if o.has_pic { return false }   // take the picture first
	if len(s.data) == 0 { return true }
	clear(&o.scratch)
	key := .Keyframe in s.flags || h264_has_idr(s.data, max(o.track.nal_length_size, 1))
	if !length_to_annexb(s.data, max(o.track.nal_length_size, 1), key ? o.prefix[:] : nil, &o.scratch) {
		return true   // corrupt sample dropped; the next keyframe recovers
	}
	openh264_feed(o, o.scratch[:], i64(s.pts))
	return true
}

@(private)
openh264_pull :: proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result {
	o := (^Openh264_Decoder)(d.impl)
	if o.has_pic {
		// Copy the planes into memory the player owns: the decoder reuses its buffers on the next decode.
		out^ = openh264_clone_frame(o.pic)
		o.has_pic = false
		return .Frame
	}
	return o.eos ? .Error : .Need_Input
}

@(private)
Openh264_Frame_Owner :: struct { data: []u8 }

@(private)
openh264_clone_frame :: proc(src: Video_Frame) -> Video_Frame {
	f := src
	h := src.height
	ch := (h + 1) / 2
	y_size := src.strides[0] * h
	u_size := src.strides[1] * ch
	v_size := src.strides[2] * ch
	total := y_size + u_size + v_size
	buf := make([]u8, total, base.process_allocator())
	copy(buf[:y_size], src.planes[0][:y_size])
	copy(buf[y_size:y_size + u_size], src.planes[1][:u_size])
	copy(buf[y_size + u_size:], src.planes[2][:v_size])
	f.planes = {buf[:y_size], buf[y_size:y_size + u_size], buf[y_size + u_size:]}
	owner := new(Openh264_Frame_Owner, base.process_allocator())
	owner.data = buf
	f.backend = owner
	f.release = openh264_frame_release
	return f
}

@(private)
openh264_frame_release :: proc(f: ^Video_Frame) {
	owner := (^Openh264_Frame_Owner)(f.backend)
	if owner == nil { return }
	delete(owner.data, base.process_allocator())
	free(owner, base.process_allocator())
}

@(private)
openh264_flush :: proc(d: ^Video_Decoder) {
	o := (^Openh264_Decoder)(d.impl)
	o.has_pic = false
	o.eos = false
	// Drain the decoder's held pictures (if any) into nothing; openh264 has no explicit reset, FlushFrame empties it.
	for {
		dst: [3][^]u8
		info: SBufferInfo
		if o.vt.FlushFrame(o.dec, &dst, &info) != DECODING_STATE_ERROR_FREE { break }
		if info.iBufferStatus != 1 { break }
	}
}

// No more input: the decoder has no reorder delay (DecodeFrameNoDelay), so nothing is held back.
@(private)
openh264_drain :: proc(d: ^Video_Decoder) {
	o := (^Openh264_Decoder)(d.impl)
	o.eos = true
}

@(private)
openh264_destroy :: proc(d: ^Video_Decoder) {
	o := (^Openh264_Decoder)(d.impl)
	o.vt.Uninitialize(o.dec)
	openh264_lib.destroy(o.dec)
	track_destroy(&o.track)
	delete(o.prefix)
	delete(o.scratch)
	free(o, base.process_allocator())
	free(d, base.process_allocator())
}

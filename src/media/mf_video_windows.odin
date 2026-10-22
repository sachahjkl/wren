#+build windows
package media

// Video decoding with a Media Foundation transform: the system's H.264 / HEVC / AV1 / VP9 decoders (whichever the machine
// has: the H.264 one is in Windows, AV1 and VP9 come with Store extensions) which decode on the GPU through DXVA when they are
// given the Direct3D 11 device (through a DXGI device manager). Their output is an NV12 / P010 texture; it is
// handed to the renderer as it is (Video_Frame.gpu_texture), so a frame never passes through the CPU. Without a
// device, or when the decoder cannot use it, pictures come out in memory.

import wbbase "wb:base"
import "core:mem"
import "core:sync"
import "vendor:directx/d3d11"

// The device the decoders share with the renderer (set_gpu_device), and the manager Media Foundation uses it through.
@(private) gpu_device: ^d3d11.IDevice
@(private) gpu_manager: ^IMFDXGIDeviceManager
@(private) gpu_token: u32
@(private) gpu_mu: sync.Mutex

// Gives the decoders the renderer's Direct3D 11 device (nil: decode into memory). Call once the renderer exists, before
// any decoder is made; the device must have been created with VIDEO_SUPPORT. The device is switched to
// multithread-protected mode here: decoders use it from their own threads.
set_gpu_device :: proc(device: rawptr) {
	sync.mutex_lock(&gpu_mu)
	defer sync.mutex_unlock(&gpu_mu)
	if gpu_manager != nil { com_release(gpu_manager); gpu_manager = nil }
	gpu_device = (^d3d11.IDevice)(device)
	if gpu_device == nil || !mf_startup() { return }
	mt: ^ID3D10Multithread
	if hr_ok(gpu_device->QueryInterface(&IID_ID3D10Multithread, (^rawptr)(&mt))) && mt != nil {
		mt->SetMultithreadProtected(true)
		com_release(mt)
	}
	mgr: ^IMFDXGIDeviceManager
	if !hr_ok(MFCreateDXGIDeviceManager(&gpu_token, &mgr)) { return }
	if !hr_ok(mgr->ResetDevice((^IUnknown)(gpu_device), gpu_token)) { com_release(mgr); return }
	gpu_manager = mgr
}

@(private)
MF_Video :: struct {
	mft:       ^IMFTransform,
	track:     Track,
	header:    []u8,        // parameter sets, Annex B
	nal_len:   int,
	annexb:    bool,
	scratch:   [dynamic]u8,
	gpu:       bool,
	provides:  bool,        // the transform allocates its output samples
	out_bytes: u32,
	out_align: u32,
	surface:   [2]int,      // size of the output surface
	visible:   [2]int,
	crop:      [2]int,
	format:    Pixel_Format,
	stride:    int,
	color:     Color_Info,
	discont:   bool,        // the next input starts after a flush
	last_pts:  Time,
	frame:     Video_Decoder,
}

@(private)
MF_Frame :: struct {
	sample: ^IMFSample,
	tex:    ^d3d11.ITexture2D,
}

mf_video_supported :: proc(codec: Codec) -> Decoder_Support {
	sub, ok := video_subtype(codec)
	if !ok || !mf_startup() { return {} }
	acts, n := enum_transforms(MFT_CATEGORY_VIDEO_DECODER, MFMediaType_Video, sub)
	defer free_activates(acts, n)
	for i in 0 ..< int(n) {
		if is_async(acts[i]) { continue }
		return {supported = true, hardware = gpu_manager != nil}
	}
	return {}
}

@(private)
video_subtype :: proc(codec: Codec) -> (GUID, bool) {
	#partial switch codec {
	case .H264: return MFVideoFormat_H264, true
	case .HEVC: return MFVideoFormat_HEVC, true
	case .AV1: return MFVideoFormat_AV1, true
	case .VP9: return MFVideoFormat_VP90, true
	}
	return {}, false
}

@(private)
enum_transforms :: proc(category, major, sub: GUID) -> ([^]^IMFActivate, u32) {
	input := MFT_REGISTER_TYPE_INFO{major, sub}
	acts: [^]^IMFActivate
	n: u32
	flags := MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER
	if !hr_ok(MFTEnumEx(category, flags, &input, nil, &acts, &n)) { return nil, 0 }
	return acts, n
}

@(private)
free_activates :: proc(acts: [^]^IMFActivate, n: u32) {
	if acts == nil { return }
	for i in 0 ..< int(n) { com_release(acts[i]) }
	CoTaskMemFree(acts)
}

@(private)
is_async :: proc(a: ^IMFActivate) -> bool {
	v: u32
	return hr_ok(a->GetUINT32(&MF_TRANSFORM_ASYNC, &v)) && v != 0
}

// A decoder for `track` (video). nil when the system has none for the codec or it refuses the stream.
mf_video_create :: proc(track: Track, use_gpu := true) -> ^Video_Decoder {
	if !mf_startup() { return nil }
	com_thread_init()
	sub, ok := video_subtype(track.codec)
	if !ok { return nil }
	acts, n := enum_transforms(MFT_CATEGORY_VIDEO_DECODER, MFMediaType_Video, sub)
	defer free_activates(acts, n)
	mft: ^IMFTransform
	for i in 0 ..< int(n) {
		if is_async(acts[i]) { continue }
		if hr_ok(acts[i]->ActivateObject(&IID_IMFTransform, (^rawptr)(&mft))) && mft != nil { break }
	}
	if mft == nil { return nil }
	v := new(MF_Video, wbbase.process_allocator())
	v.mft = mft
	v.track = track_clone(track)
	v.nal_len = track.nal_length_size
	#partial switch track.codec {
	case .H264:
		v.annexb = true
		v.header = avcc_annexb_header(track.config, wbbase.process_allocator())
	case .HEVC:
		v.annexb = true
		v.header = hvcc_annexb_header(track.config, wbbase.process_allocator())
	}
	v.discont = true
	// GPU decoding: the transform asks the manager for the device and allocates its pictures as textures
	sync.mutex_lock(&gpu_mu)
	mgr := gpu_manager
	sync.mutex_unlock(&gpu_mu)
	if use_gpu && mgr != nil {
		attrs: ^IMFAttributes
		if hr_ok(mft->GetAttributes(&attrs)) && attrs != nil {
			aware: u32
			if hr_ok(attrs->GetUINT32(&MF_SA_D3D11_AWARE, &aware)) && aware != 0 {
				v.gpu = hr_ok(mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, uintptr(mgr)))
			}
			attrs->SetUINT32(&MF_LOW_LATENCY, 1)
			com_release(attrs)
		}
	}
	if !mf_video_input_type(v, sub) || !mf_video_output_type(v) {
		mf_video_free(v)
		return nil
	}
	mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
	mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
	d := new(Video_Decoder, wbbase.process_allocator())
	d.impl = v
	d.hardware = v.gpu
	d.name = "Media Foundation"
	d.push = mf_video_push
	d.pull = mf_video_pull
	d.flush = mf_video_flush
	d.drain = mf_video_drain
	d.destroy = mf_video_destroy
	return d
}

@(private)
mf_video_input_type :: proc(v: ^MF_Video, sub: GUID) -> bool {
	t: ^IMFMediaType
	if !hr_ok(MFCreateMediaType(&t)) { return false }
	defer com_release(t)
	major, subtype := MFMediaType_Video, sub
	t->SetGUID(&MF_MT_MAJOR_TYPE, &major)
	t->SetGUID(&MF_MT_SUBTYPE, &subtype)
	t->SetUINT64(&MF_MT_FRAME_SIZE, pack2(u32(max(v.track.width, 16)), u32(max(v.track.height, 16))))
	t->SetUINT64(&MF_MT_FRAME_RATE, pack2(30, 1))
	t->SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack2(1, 1))
	t->SetUINT32(&MF_MT_INTERLACE_MODE, 2)   // progressive
	if len(v.header) > 0 { t->SetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, raw_data(v.header), u32(len(v.header))) }
	return hr_ok(v.mft->SetInputType(0, t, 0))
}

// Picks NV12 (or P010 for 10-bit streams) among the output types and reads what the surface looks like.
@(private)
mf_video_output_type :: proc(v: ^MF_Video) -> bool {
	want10 := v.track.bit_depth > 8
	if v.gpu {
		attrs: ^IMFAttributes
		if hr_ok(v.mft->GetOutputStreamAttributes(0, &attrs)) && attrs != nil {
			attrs->SetUINT32(&MF_SA_D3D11_BINDFLAGS, 8)   // D3D11_BIND_SHADER_RESOURCE: the renderer samples the picture
			com_release(attrs)
		}
	}
	chosen: ^IMFMediaType
	for i: u32 = 0; ; i += 1 {
		t: ^IMFMediaType
		if !hr_ok(v.mft->GetOutputAvailableType(0, i, &t)) { break }
		sub: GUID
		t->GetGUID(&MF_MT_SUBTYPE, &sub)
		if (sub == MFVideoFormat_NV12 && !want10) || (sub == MFVideoFormat_P010 && want10) {
			chosen = t
			break
		}
		if chosen == nil && (sub == MFVideoFormat_NV12 || sub == MFVideoFormat_P010) { chosen = t; continue }
		com_release(t)
	}
	if chosen == nil { return false }
	defer com_release(chosen)
	if !hr_ok(v.mft->SetOutputType(0, chosen, 0)) { return false }
	return mf_video_read_output(v)
}

@(private)
mf_video_read_output :: proc(v: ^MF_Video) -> bool {
	t: ^IMFMediaType
	if !hr_ok(v.mft->GetOutputCurrentType(0, &t)) || t == nil { return false }
	defer com_release(t)
	sub: GUID
	t->GetGUID(&MF_MT_SUBTYPE, &sub)
	switch sub {
	case MFVideoFormat_NV12: v.format = .NV12
	case MFVideoFormat_P010: v.format = .P010
	case: return false
	}
	size: u64
	t->GetUINT64(&MF_MT_FRAME_SIZE, &size)
	v.surface = {int(size >> 32), int(size & 0xffffffff)}
	v.visible = v.surface
	v.crop = {}
	// the visible area: the aperture the transform reports, else what the container said
	area: [16]u8
	got: u32
	if hr_ok(t->GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, raw_data(area[:]), 16, &got)) && got == 16 {
		ox, oy := int(i16(le16(area[:], 2))), int(i16(le16(area[:], 6)))
		cx, cy := int(i32(le32(area[:], 8))), int(i32(le32(area[:], 12)))
		if cx > 0 && cy > 0 && ox + cx <= v.surface[0] && oy + cy <= v.surface[1] {
			v.crop, v.visible = {ox, oy}, {cx, cy}
		}
	} else if v.track.width > 0 && v.track.height > 0 && v.track.width <= v.surface[0] && v.track.height <= v.surface[1] {
		v.visible = {v.track.width, v.track.height}
	}
	stride: u32
	if hr_ok(t->GetUINT32(&MF_MT_DEFAULT_STRIDE, &stride)) { v.stride = int(i32(stride)) }
	// what the stream says about its colours (the container's description comes first)
	v.color = v.track.color
	if !v.color.known {
		m, r: u32
		if hr_ok(t->GetUINT32(&MF_MT_YUV_MATRIX, &m)) {
			v.color.known = true
			switch m {
			case 1: v.color.coeffs = .BT709   // MFVideoTransferMatrix_BT709
			case 2: v.color.coeffs = .BT601
			case 3: v.color.coeffs = .SMPTE240
			case 4: v.color.coeffs = .BT2020
			}
		}
		if hr_ok(t->GetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, &r)) { v.color.full_range = r == 1 }   // MFNominalRange_0_255 = 1, 16_235 = 2
	}
	info: MFT_OUTPUT_STREAM_INFO
	v.mft->GetOutputStreamInfo(0, &info)
	v.provides = info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES) != 0
	v.out_bytes, v.out_align = info.cbSize, info.cbAlignment
	return true
}

@(private)
mf_video_push :: proc(d: ^Video_Decoder, s: ^Sample) -> bool {
	v := (^MF_Video)(d.impl)
	data := s.data
	if v.annexb {
		clear(&v.scratch)
		prefix: []u8
		if .Keyframe in s.flags || v.discont { prefix = v.header }
		if !length_to_annexb(s.data, v.nal_len, prefix, &v.scratch) { return true }   // a broken sample is skipped
		data = v.scratch[:]
	}
	if len(data) == 0 { return true }
	buf: ^IMFMediaBuffer
	if !hr_ok(MFCreateMemoryBuffer(u32(len(data)), &buf)) { return true }
	defer com_release(buf)
	dst: [^]u8
	if !hr_ok(buf->Lock(&dst, nil, nil)) { return true }
	mem.copy(dst, raw_data(data), len(data))
	buf->Unlock()
	buf->SetCurrentLength(u32(len(data)))
	sample: ^IMFSample
	if !hr_ok(MFCreateSample(&sample)) { return true }
	defer com_release(sample)
	sample->AddBuffer(buf)
	sample->SetSampleTime(i64(s.pts) / 100)
	if s.duration > 0 { sample->SetSampleDuration(i64(s.duration) / 100) }
	if .Keyframe in s.flags { sample->SetUINT32(&MFSampleExtension_CleanPoint, 1) }
	if v.discont { sample->SetUINT32(&MFSampleExtension_Discontinuity, 1) }
	hr := v.mft->ProcessInput(0, sample, 0)
	if hr == MF_E_NOTACCEPTING { return false }
	v.discont = false
	return true
}

@(private)
mf_video_pull :: proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result {
	v := (^MF_Video)(d.impl)
	buffers := MFT_OUTPUT_DATA_BUFFER{}
	own: ^IMFSample
	if !v.provides {
		// we allocate the picture: a sample with a memory buffer of the size the transform wants
		if !hr_ok(MFCreateSample(&own)) { return .Error }
		b: ^IMFMediaBuffer
		if !hr_ok(MFCreateMemoryBuffer(max(v.out_bytes, 1), &b)) { com_release(own); return .Error }
		own->AddBuffer(b)
		com_release(b)
		buffers.pSample = own
	}
	status: u32
	hr := v.mft->ProcessOutput(0, 1, &buffers, &status)
	if hr == MF_E_TRANSFORM_NEED_MORE_INPUT {
		com_release(own)
		return .Need_Input
	}
	if hr == MF_E_TRANSFORM_STREAM_CHANGE {
		com_release(own)
		if buffers.pSample != nil && buffers.pSample != own { com_release(buffers.pSample) }
		if !mf_video_output_type_again(v) { return .Error }
		return .Format_Changed
	}
	if !hr_ok(hr) {
		com_release(own)
		return .Error
	}
	sample := buffers.pSample
	if sample == nil { return .Need_Input }
	if own != nil && own != sample { com_release(own) }
	return mf_video_frame(v, sample, out) ? .Frame : .Error
}

@(private)
mf_video_output_type_again :: proc(v: ^MF_Video) -> bool {
	want10 := v.format == .P010
	for i: u32 = 0; ; i += 1 {
		t: ^IMFMediaType
		if !hr_ok(v.mft->GetOutputAvailableType(0, i, &t)) { break }
		sub: GUID
		t->GetGUID(&MF_MT_SUBTYPE, &sub)
		if (sub == MFVideoFormat_NV12 && !want10) || (sub == MFVideoFormat_P010 && want10) {
			ok := hr_ok(v.mft->SetOutputType(0, t, 0))
			com_release(t)
			return ok && mf_video_read_output(v)
		}
		com_release(t)
	}
	return false
}

// A decoded sample as a Video_Frame: the texture it lives in, or planes copied out of its buffer.
@(private)
mf_video_frame :: proc(v: ^MF_Video, sample: ^IMFSample, out: ^Video_Frame) -> bool {
	t, dur: i64
	sample->GetSampleTime(&t)
	sample->GetSampleDuration(&dur)
	out^ = Video_Frame{
		pts = Time(t * 100), duration = Time(dur * 100), format = v.format,
		width = v.visible[0], height = v.visible[1], crop = v.crop, surface = v.surface,
		color = v.color, rotation = v.track.rotation,
	}
	buf: ^IMFMediaBuffer
	if !hr_ok(sample->GetBufferByIndex(0, &buf)) || buf == nil { com_release(sample); return false }
	defer com_release(buf)
	dxgi: ^IMFDXGIBuffer
	if hr_ok(buf->QueryInterface(&IID_IMFDXGIBuffer, (^rawptr)(&dxgi))) && dxgi != nil {
		defer com_release(dxgi)
		tex: ^d3d11.ITexture2D
		idx: u32
		if hr_ok(dxgi->GetResource(&IID_ID3D11Texture2D, (^rawptr)(&tex))) && tex != nil {
			dxgi->GetSubresourceIndex(&idx)
			f := new(MF_Frame, wbbase.process_allocator())
			f.sample, f.tex = sample, tex
			out.gpu_texture, out.gpu_index = tex, idx
			out.backend = f
			out.release = mf_frame_release
			return true
		}
	}
	// system memory: copy the planes out (the buffer is a 2-D one: rows of `pitch` bytes, UV after the luma)
	pitch := 0
	base: [^]u8
	b2d: ^IMF2DBuffer
	locked2d := false
	if hr_ok(buf->QueryInterface(&IID_IMF2DBuffer, (^rawptr)(&b2d))) && b2d != nil {
		p: i32
		if hr_ok(b2d->Lock2D(&base, &p)) { pitch, locked2d = int(p), true }
	}
	if !locked2d {
		cur: u32
		if !hr_ok(buf->Lock(&base, nil, &cur)) { com_release(b2d); com_release(sample); return false }
		pitch = v.stride != 0 ? abs(v.stride) : v.surface[0] * (v.format == .P010 ? 2 : 1)
	}
	bpp := v.format == .P010 ? 2 : 1
	w, h := v.visible[0], v.visible[1]
	row_bytes := w * bpp
	heap := wbbase.process_allocator()
	luma := make([]u8, row_bytes * h, heap)
	chroma_h := (h + 1) / 2
	chroma := make([]u8, ((w + 1) / 2 * 2) * bpp * chroma_h, heap)
	uv_base := base[pitch * v.surface[1]:]
	for y in 0 ..< h {
		src := base[pitch * (y + v.crop[1]) + v.crop[0] * bpp:]
		mem.copy(raw_data(luma[y * row_bytes:]), src, row_bytes)
	}
	crow := ((w + 1) / 2 * 2) * bpp
	for y in 0 ..< chroma_h {
		src := uv_base[pitch * (y + v.crop[1] / 2) + (v.crop[0] / 2 * 2) * bpp:]
		mem.copy(raw_data(chroma[y * crow:]), src, crow)
	}
	if locked2d { b2d->Unlock2D() } else { buf->Unlock() }
	com_release(b2d)
	com_release(sample)
	out.planes[0], out.planes[1] = luma, chroma
	out.strides[0], out.strides[1] = row_bytes, crow
	out.crop = {}
	out.surface = {w, h}
	out.release = mf_frame_release_cpu
	return true
}

IID_IMF2DBuffer := GUID{0x7dc9d5f9, 0x9ed9, 0x44ec, {0x9b, 0xbf, 0x06, 0x00, 0xbb, 0x58, 0x9f, 0xbf}}

@(private)
mf_frame_release :: proc(f: ^Video_Frame) {
	m := (^MF_Frame)(f.backend)
	if m == nil { return }
	com_release(m.tex)
	com_release(m.sample)
	free(m, wbbase.process_allocator())
}

@(private)
mf_frame_release_cpu :: proc(f: ^Video_Frame) {
	delete(f.planes[0], wbbase.process_allocator())
	delete(f.planes[1], wbbase.process_allocator())
}

@(private)
mf_video_flush :: proc(d: ^Video_Decoder) {
	v := (^MF_Video)(d.impl)
	v.mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0)
	v.discont = true
}

@(private)
mf_video_drain :: proc(d: ^Video_Decoder) {
	v := (^MF_Video)(d.impl)
	v.mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0)
}

@(private)
mf_video_free :: proc(v: ^MF_Video) {
	if v.mft != nil {
		v.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0)
		v.mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, 0)
		com_release(v.mft)
	}
	track_destroy(&v.track)
	delete(v.header, wbbase.process_allocator())
	delete(v.scratch)
	free(v, wbbase.process_allocator())
}

@(private)
mf_video_destroy :: proc(d: ^Video_Decoder) {
	mf_video_free((^MF_Video)(d.impl))
	free(d, wbbase.process_allocator())
}

package images

// Encoding with WIC: PNG and JPEG, as the 2D canvas did before the built-in encoder (native.odin). The encoder writes to a growing
// stream in memory (CreateStreamOnHGlobal), whose size is then read back. The interfaces are declared here, with their
// methods in the order of wincodec.h and objidl.h (the slots a call does not use stay untyped).

import "base:runtime"
import win "core:sys/windows"

GUID_ContainerFormatPng := GUID{0x1b7cfaf4, 0x713f, 0x473c, {0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf}}
GUID_ContainerFormatJpeg := GUID{0x19e4a5aa, 0x5662, 0x4fc5, {0xa0, 0xc0, 0x17, 0x58, 0x02, 0x8e, 0x10, 0x57}}
GUID_WICPixelFormat24bppBGR := GUID{0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0c}}

VT_R4 :: u16(4)
WICBitmapEncoderNoCache :: u32(2)
STREAM_SEEK_SET :: u32(0)
STATFLAG_NONAME :: u32(1)

foreign import ole32_enc "system:Ole32.lib"

@(default_calling_convention = "system")
foreign ole32_enc {
	CreateStreamOnHGlobal :: proc(hglobal: rawptr, delete_on_release: win.BOOL, stream: ^^IStream) -> HRESULT ---
}

STATSTG :: struct {
	name:     rawptr,
	type:     u32,
	size:     u64,
	mtime, ctime, atime: [2]u32,
	mode:     u32,
	locks:    u32,
	clsid:    GUID,
	state:    u32,
	reserved: u32,
}

IStream :: struct { using vt: ^IStream_Vtbl }
IStream_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	Read:  proc "system" (this: ^IStream, buffer: [^]u8, count: u32, read: ^u32) -> HRESULT,
	Write: rawptr,
	Seek:  proc "system" (this: ^IStream, move: i64, origin: u32, new_position: ^u64) -> HRESULT,
	SetSize, CopyTo, Commit, Revert, LockRegion, UnlockRegion: rawptr,
	Stat:  proc "system" (this: ^IStream, stat: ^STATSTG, flags: u32) -> HRESULT,
	Clone: rawptr,
}

PROPBAG2 :: struct {
	type:  u32,
	vt:    u16,
	cf:    u16,
	hint:  uintptr,
	name:  win.LPWSTR,
	clsid: GUID,
}

IPropertyBag2 :: struct { using vt: ^IPropertyBag2_Vtbl }
IPropertyBag2_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	Read:  rawptr,
	Write: proc "system" (this: ^IPropertyBag2, count: u32, props: [^]PROPBAG2, values: [^]PROPVARIANT) -> HRESULT,
	CountProperties, GetPropertyInfo, LoadObject: rawptr,
}

IWICBitmapEncoder :: struct { using vt: ^IWICBitmapEncoder_Vtbl }
IWICBitmapEncoder_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	Initialize:        proc "system" (this: ^IWICBitmapEncoder, stream: ^IStream, cache: u32) -> HRESULT,
	GetContainerFormat, GetEncoderInfo, SetColorContexts, SetPalette, SetThumbnail, SetPreview: rawptr,
	CreateNewFrame:    proc "system" (this: ^IWICBitmapEncoder, frame: ^^IWICBitmapFrameEncode, options: ^^IPropertyBag2) -> HRESULT,
	Commit:            proc "system" (this: ^IWICBitmapEncoder) -> HRESULT,
	GetMetadataQueryWriter: rawptr,
}

IWICBitmapFrameEncode :: struct { using vt: ^IWICBitmapFrameEncode_Vtbl }
IWICBitmapFrameEncode_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	Initialize:     proc "system" (this: ^IWICBitmapFrameEncode, options: ^IPropertyBag2) -> HRESULT,
	SetSize:        proc "system" (this: ^IWICBitmapFrameEncode, w, h: u32) -> HRESULT,
	SetResolution:  proc "system" (this: ^IWICBitmapFrameEncode, dx, dy: f64) -> HRESULT,
	SetPixelFormat: proc "system" (this: ^IWICBitmapFrameEncode, format: ^GUID) -> HRESULT,
	SetColorContexts, SetPalette, SetThumbnail: rawptr,
	WritePixels:    proc "system" (this: ^IWICBitmapFrameEncode, lines: u32, stride: u32, size: u32, pixels: [^]u8) -> HRESULT,
	WriteSource:    rawptr,
	Commit:         proc "system" (this: ^IWICBitmapFrameEncode) -> HRESULT,
	GetMetadataQueryWriter: rawptr,
}

// The factory's CreateEncoder, typed (its slot in IWICImagingFactory_Vtbl is the untyped `CreateEncoder`).
@(private)
Create_Encoder :: #type proc "system" (this: ^IWICImagingFactory, container: ^GUID, vendor: ^GUID, out: ^^IWICBitmapEncoder) -> HRESULT

// encode_rgba (native.odin) through WIC instead: kept to compare the two (encode_test.odin) while the built-in
// encoder replaces it. false: the platform could not encode (no WIC, no memory).
encode_rgba_system :: proc(rgba: []u8, w, h: int, format: Encode_Format, quality: f32, premultiplied: bool, allocator := context.allocator) -> (out: []u8, ok: bool) {
	if w <= 0 || h <= 0 || w > 65535 * 4 || h > 65535 * 4 || len(rgba) < w * h * 4 { return }
	c: Codec_Context
	if !codec_init(&c) { return }
	defer codec_destroy(&c)
	f := c.factory
	container := format == .Png ? GUID_ContainerFormatPng : GUID_ContainerFormatJpeg
	encoder: ^IWICBitmapEncoder
	create := cast(Create_Encoder)f.vt.CreateEncoder
	if !succeeded(create(f, &container, nil, &encoder)) || encoder == nil { return }
	defer com_release(encoder)
	stream: ^IStream
	if !succeeded(CreateStreamOnHGlobal(nil, true, &stream)) || stream == nil { return }
	defer com_release(stream)
	if !succeeded(encoder.Initialize(encoder, stream, WICBitmapEncoderNoCache)) { return }
	frame: ^IWICBitmapFrameEncode
	bag: ^IPropertyBag2
	if !succeeded(encoder.CreateNewFrame(encoder, &frame, &bag)) || frame == nil { return }
	defer com_release(frame)
	defer if bag != nil { com_release(bag) }
	if format == .Jpeg && bag != nil {
		name := [?]u16{'I', 'm', 'a', 'g', 'e', 'Q', 'u', 'a', 'l', 'i', 't', 'y', 0}
		prop := PROPBAG2{name = raw_data(name[:])}
		val := PROPVARIANT{vt = VT_R4}
		(^f32)(&val.pad)^ = clamp(quality, 0, 1)
		bag.Write(bag, 1, &prop, &val)   // (a quality the encoder refuses leaves its default)
	}
	if !succeeded(frame.Initialize(frame, bag)) { return }
	if !succeeded(frame.SetSize(frame, u32(w), u32(h))) { return }
	// the format the encoder prefers for what is asked: PNG takes BGRA, JPEG 24-bit BGR
	want := format == .Png ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat24bppBGR
	got := want
	if !succeeded(frame.SetPixelFormat(frame, &got)) || got != want { return }
	bpp := format == .Png ? 4 : 3
	stride := w * bpp
	if u64(stride) * u64(h) > u64(max(u32)) { return }
	buf := make([]u8, stride * h, allocator)
	defer delete(buf, allocator)
	for y in 0 ..< h {
		src := rgba[y * w * 4:][:w * 4]
		dst := buf[y * stride:][:stride]
		for x in 0 ..< w {
			r, g, b, a := src[x * 4], src[x * 4 + 1], src[x * 4 + 2], src[x * 4 + 3]
			if format == .Png {
				if premultiplied && a != 255 && a != 0 {
					r = u8(min((u32(r) * 255 + u32(a) / 2) / u32(a), 255))
					g = u8(min((u32(g) * 255 + u32(a) / 2) / u32(a), 255))
					b = u8(min((u32(b) * 255 + u32(a) / 2) / u32(a), 255))
				} else if premultiplied && a == 0 {
					r, g, b = 0, 0, 0
				}
				dst[x * 4], dst[x * 4 + 1], dst[x * 4 + 2], dst[x * 4 + 3] = b, g, r, a
			} else {
				if !premultiplied && a != 255 {
					r, g, b = u8((u32(r) * u32(a) + 127) / 255), u8((u32(g) * u32(a) + 127) / 255), u8((u32(b) * u32(a) + 127) / 255)
				}
				dst[x * 3], dst[x * 3 + 1], dst[x * 3 + 2] = b, g, r
			}
		}
	}
	if !succeeded(frame.WritePixels(frame, u32(h), u32(stride), u32(len(buf)), raw_data(buf))) { return }
	if !succeeded(frame.Commit(frame)) || !succeeded(encoder.Commit(encoder)) { return }
	st: STATSTG
	if !succeeded(stream.Stat(stream, &st, STATFLAG_NONAME)) || st.size == 0 || st.size > u64(max(int) / 2) { return }
	pos: u64
	if !succeeded(stream.Seek(stream, 0, STREAM_SEEK_SET, &pos)) { return }
	out = make([]u8, int(st.size), allocator)
	done := 0
	for done < len(out) {
		n: u32
		chunk := u32(min(len(out) - done, 1 << 30))
		if !succeeded(stream.Read(stream, raw_data(out[done:]), chunk, &n)) || n == 0 { delete(out, allocator); return nil, false }
		done += int(n)
	}
	return out, true
}

_ :: runtime

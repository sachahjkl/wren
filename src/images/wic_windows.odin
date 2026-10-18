package images

// Windows Imaging Component declarations: the part of wincodec.h this package uses. core:sys/windows has COM itself
// (CoInitializeEx, CoCreateInstance, IUnknown, GUID) but nothing of WIC, and its PROPVARIANT is a 16-byte stand-in
// (the real one is 24 bytes on 64-bit Windows), so both are declared here. Vtables list every method in the order of
// the SDK headers; methods this package never calls are kept as untyped slots so the offsets stay right.

import win "core:sys/windows"

HRESULT :: win.HRESULT
GUID :: win.GUID

CLSID_WICImagingFactory := GUID{0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}}
IID_IWICImagingFactory := GUID{0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}}

GUID_WICPixelFormat32bppRGBA := GUID{0xf5c7ad2d, 0x6a8d, 0x43dd, {0xa7, 0xa8, 0xa2, 0x99, 0x35, 0x26, 0x1a, 0xe9}}
GUID_WICPixelFormat32bppBGRA := GUID{0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}}

WICDecodeMetadataCacheOnDemand :: u32(0)
WICDecodeMetadataCacheOnLoad :: u32(1)

WICBitmapDitherTypeNone :: u32(0)
WICBitmapPaletteTypeCustom :: u32(0)
WICBitmapPaletteTypeMedianCut :: u32(1)

WICBitmapInterpolationModeNearestNeighbor :: u32(0)
WICBitmapInterpolationModeLinear :: u32(1)
WICBitmapInterpolationModeCubic :: u32(2)
WICBitmapInterpolationModeFant :: u32(3)
WICBitmapInterpolationModeHighQualityCubic :: u32(4)

WINCODEC_ERR_COMPONENTNOTFOUND :: HRESULT(-2003292336)   // 0x88982F50: no decoder recognises the stream
WINCODEC_ERR_UNKNOWNIMAGEFORMAT :: HRESULT(-2003292409)  // 0x88982F07
WINCODEC_ERR_PROPERTYNOTFOUND :: HRESULT(-2003292352)    // 0x88982F40
WINCODEC_ERR_COMPONENTINITIALIZEFAILURE :: HRESULT(-2003292277)   // 0x88982F8B: the codec is registered but unusable
E_OUTOFMEMORY :: HRESULT(-2147024882)                    // 0x8007000E
HRESULT_ARITHMETIC_OVERFLOW :: HRESULT(-2147024362)      // 0x80070216
RPC_E_CHANGED_MODE :: HRESULT(-2147417850)               // 0x80010106: the thread already has another apartment

VT_EMPTY :: u16(0)
VT_I2 :: u16(2)
VT_I4 :: u16(3)
VT_BOOL :: u16(11)
VT_UI1 :: u16(17)
VT_UI2 :: u16(18)
VT_UI4 :: u16(19)
VT_VECTOR :: u16(0x1000)

// The real layout: vt, three reserved words, then a 16-byte union (CAUB = {cElems: u32, pElems: ^u8}).
PROPVARIANT :: struct {
	vt:        u16,
	reserved:  [3]u16,
	using _: struct #raw_union {
		u8_val:  u8,
		u16_val: u16,
		u32_val: u32,
		i32_val: i32,
		i16_val: i16,
		bool_val: i16,
		caub:    struct { count: u32, elems: [^]u8 },
		pad:     [2]u64,
	},
}

WICRect :: struct { X, Y, Width, Height: i32 }

foreign import ole32 "system:Ole32.lib"

@(default_calling_convention = "system")
foreign ole32 {
	PropVariantClear :: proc(pvar: ^PROPVARIANT) -> HRESULT ---
}

Unknown_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
}

IWICImagingFactory :: struct { using vt: ^IWICImagingFactory_Vtbl }
IWICImagingFactory_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	CreateDecoderFromFilename:  rawptr,
	CreateDecoderFromStream:    proc "system" (this: ^IWICImagingFactory, stream: ^IWICStream, vendor: ^GUID, options: u32, out: ^^IWICBitmapDecoder) -> HRESULT,
	CreateDecoderFromFileHandle: rawptr,
	CreateComponentInfo:        rawptr,
	CreateDecoder:              rawptr,
	CreateEncoder:              rawptr,
	CreatePalette:              rawptr,
	CreateFormatConverter:      proc "system" (this: ^IWICImagingFactory, out: ^^IWICFormatConverter) -> HRESULT,
	CreateBitmapScaler:         proc "system" (this: ^IWICImagingFactory, out: ^^IWICBitmapScaler) -> HRESULT,
	CreateBitmapClipper:        rawptr,
	CreateBitmapFlipRotator:    rawptr,
	CreateStream:               proc "system" (this: ^IWICImagingFactory, out: ^^IWICStream) -> HRESULT,
	CreateColorContext:         rawptr,
	CreateColorTransformer:     rawptr,
	CreateBitmap:               rawptr,
	CreateBitmapFromSource:     rawptr,
	CreateBitmapFromSourceRect: rawptr,
	CreateBitmapFromMemory:     rawptr,
	CreateBitmapFromHBITMAP:    rawptr,
	CreateBitmapFromHICON:      rawptr,
	CreateComponentEnumerator:  rawptr,
	CreateFastMetadataEncoderFromDecoder: rawptr,
	CreateFastMetadataEncoderFromFrameDecode: rawptr,
	CreateQueryWriter:          rawptr,
	CreateQueryWriterFromReader: rawptr,
}

// IStream methods first (ISequentialStream Read / Write, then IStream), then IWICStream's own.
IWICStream :: struct { using vt: ^IWICStream_Vtbl }
IWICStream_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	Read, Write: rawptr,
	Seek, SetSize, CopyTo, Commit, Revert, LockRegion, UnlockRegion, Stat, Clone: rawptr,
	InitializeFromIStream:  rawptr,
	InitializeFromFilename: rawptr,
	InitializeFromMemory:   proc "system" (this: ^IWICStream, buffer: [^]u8, size: u32) -> HRESULT,
	InitializeFromIStreamRegion: rawptr,
}

IWICBitmapDecoder :: struct { using vt: ^IWICBitmapDecoder_Vtbl }
IWICBitmapDecoder_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	QueryCapability:        rawptr,
	Initialize:             rawptr,
	GetContainerFormat:     proc "system" (this: ^IWICBitmapDecoder, out: ^GUID) -> HRESULT,
	GetDecoderInfo:         rawptr,
	CopyPalette:            rawptr,
	GetMetadataQueryReader: proc "system" (this: ^IWICBitmapDecoder, out: ^^IWICMetadataQueryReader) -> HRESULT,
	GetPreview:             rawptr,
	GetColorContexts:       rawptr,
	GetThumbnail:           rawptr,
	GetFrameCount:          proc "system" (this: ^IWICBitmapDecoder, count: ^u32) -> HRESULT,
	GetFrame:               proc "system" (this: ^IWICBitmapDecoder, index: u32, out: ^^IWICBitmapFrameDecode) -> HRESULT,
}

// IWICBitmapSource: the first methods of every bitmap object (frames, converters, scalers).
Bitmap_Source_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	GetSize:        proc "system" (this: rawptr, w, h: ^u32) -> HRESULT,
	GetPixelFormat: proc "system" (this: rawptr, out: ^GUID) -> HRESULT,
	GetResolution:  proc "system" (this: rawptr, dx, dy: ^f64) -> HRESULT,
	CopyPalette:    rawptr,
	CopyPixels:     proc "system" (this: rawptr, rect: ^WICRect, stride: u32, size: u32, buffer: [^]u8) -> HRESULT,
}

IWICBitmapSource :: struct { using vt: ^Bitmap_Source_Vtbl }

IWICBitmapFrameDecode :: struct { using vt: ^IWICBitmapFrameDecode_Vtbl }
IWICBitmapFrameDecode_Vtbl :: struct {
	using source: Bitmap_Source_Vtbl,
	GetMetadataQueryReader: proc "system" (this: ^IWICBitmapFrameDecode, out: ^^IWICMetadataQueryReader) -> HRESULT,
	GetColorContexts:       rawptr,
	GetThumbnail:           rawptr,
}

IWICFormatConverter :: struct { using vt: ^IWICFormatConverter_Vtbl }
IWICFormatConverter_Vtbl :: struct {
	using source: Bitmap_Source_Vtbl,
	Initialize: proc "system" (this: ^IWICFormatConverter, src: rawptr, dst_format: ^GUID, dither: u32, palette: rawptr, alpha_threshold: f64, palette_type: u32) -> HRESULT,
	CanConvert: proc "system" (this: ^IWICFormatConverter, src_format, dst_format: ^GUID, can: ^win.BOOL) -> HRESULT,
}

IWICBitmapScaler :: struct { using vt: ^IWICBitmapScaler_Vtbl }
IWICBitmapScaler_Vtbl :: struct {
	using source: Bitmap_Source_Vtbl,
	Initialize: proc "system" (this: ^IWICBitmapScaler, src: rawptr, w, h: u32, mode: u32) -> HRESULT,
}

IWICMetadataQueryReader :: struct { using vt: ^IWICMetadataQueryReader_Vtbl }
IWICMetadataQueryReader_Vtbl :: struct {
	using unknown: Unknown_Vtbl,
	GetContainerFormat: rawptr,
	GetLocation:        rawptr,
	GetMetadataByName:  proc "system" (this: ^IWICMetadataQueryReader, name: win.LPCWSTR, value: ^PROPVARIANT) -> HRESULT,
	GetEnumerator:      rawptr,
}

@(private)
com_release :: #force_inline proc(p: rawptr) {
	if p != nil { (^^Unknown_Vtbl)(p)^.Release(p) }
}

@(private)
succeeded :: #force_inline proc "contextless" (hr: HRESULT) -> bool { return hr >= 0 }

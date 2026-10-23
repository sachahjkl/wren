#+build windows
package media

// Media Foundation, as far as the decoders need it: the COM interfaces (vtables in the order of the SDK headers: a slot
// out of place calls the wrong method, so every vtable below is the header's list) and the entry points. Methods the
// code does not call are kept as `rawptr` slots.

import win "core:sys/windows"

foreign import mfplat "system:mfplat.lib"
foreign import ole32 "system:ole32.lib"

HRESULT :: win.HRESULT
GUID :: win.GUID
IUnknown :: win.IUnknown
IUnknown_VTable :: win.IUnknown_VTable

MF_VERSION :: u32(0x00020070)
MFSTARTUP_FULL :: u32(0)

MF_E_TRANSFORM_NEED_MORE_INPUT :: HRESULT(i32(-1072861838))   // 0xC00D6D72
MF_E_TRANSFORM_STREAM_CHANGE :: HRESULT(i32(-1072861855))     // 0xC00D6D61
MF_E_TRANSFORM_TYPE_NOT_SET :: HRESULT(i32(-1072861851))      // 0xC00D6D65
MF_E_NO_MORE_TYPES :: HRESULT(i32(-1072861846))               // 0xC00D6D6A
MF_E_NOTACCEPTING :: HRESULT(i32(-1072875836))                // 0xC00D36B4

MFT_ENUM_FLAG_SYNCMFT :: u32(0x1)
MFT_ENUM_FLAG_ASYNCMFT :: u32(0x2)
MFT_ENUM_FLAG_HARDWARE :: u32(0x4)
MFT_ENUM_FLAG_SORTANDFILTER :: u32(0x40)

MFT_MESSAGE_COMMAND_FLUSH :: uintptr(0)
MFT_MESSAGE_COMMAND_DRAIN :: uintptr(1)
MFT_MESSAGE_SET_D3D_MANAGER :: uintptr(2)
MFT_MESSAGE_NOTIFY_BEGIN_STREAMING :: uintptr(0x10000000)
MFT_MESSAGE_NOTIFY_END_STREAMING :: uintptr(0x10000001)
MFT_MESSAGE_NOTIFY_START_OF_STREAM :: uintptr(0x10000003)

MFT_OUTPUT_STREAM_PROVIDES_SAMPLES :: u32(0x100)
MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES :: u32(0x200)
MFT_OUTPUT_DATA_BUFFER_FORMAT_CHANGE :: u32(0x100)

MFT_INPUT_STREAM_INFO :: struct {
	hnsMaxLatency: i64,
	dwFlags:       u32,
	cbSize:        u32,
	cbMaxLookahead: u32,
	cbAlignment:   u32,
}

MFT_OUTPUT_STREAM_INFO :: struct {
	dwFlags:     u32,
	cbSize:      u32,
	cbAlignment: u32,
}

MFT_OUTPUT_DATA_BUFFER :: struct {
	dwStreamID: u32,
	pSample:    ^IMFSample,
	dwStatus:   u32,
	pEvents:    rawptr,
}

MFT_REGISTER_TYPE_INFO :: struct {
	guidMajorType: GUID,
	guidSubtype:   GUID,
}

////////////////////////////////
// GUIDs

MF_MT_MAJOR_TYPE := GUID{0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}}
MF_MT_SUBTYPE := GUID{0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}}
MF_MT_FRAME_SIZE := GUID{0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}}
MF_MT_FRAME_RATE := GUID{0xc459a2e8, 0x3d2c, 0x4e44, {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}}
MF_MT_PIXEL_ASPECT_RATIO := GUID{0xc6376a1e, 0x8d0a, 0x4027, {0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6}}
MF_MT_INTERLACE_MODE := GUID{0xe2724bb8, 0xe676, 0x4806, {0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd}}
MF_MT_MPEG_SEQUENCE_HEADER := GUID{0x3c036de7, 0x3ad0, 0x4c9e, {0x92, 0x16, 0xee, 0x6d, 0x6a, 0xc2, 0x1c, 0xb3}}
MF_MT_USER_DATA := GUID{0xb6bc765f, 0x4c3b, 0x40a4, {0xbd, 0x51, 0x25, 0x35, 0xb6, 0x6f, 0xe0, 0x9d}}
MF_MT_AUDIO_NUM_CHANNELS := GUID{0x37e48bf5, 0x645e, 0x4c5b, {0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a}}
MF_MT_AUDIO_SAMPLES_PER_SECOND := GUID{0x5faeeae7, 0x0290, 0x4c31, {0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba}}
MF_MT_AUDIO_BITS_PER_SAMPLE := GUID{0xf2deb57f, 0x40fa, 0x4764, {0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69}}
MF_MT_AUDIO_BLOCK_ALIGNMENT := GUID{0x322de230, 0x9eeb, 0x43bd, {0xab, 0x7a, 0xff, 0x41, 0x22, 0x51, 0x54, 0x1d}}
MF_MT_AUDIO_AVG_BYTES_PER_SECOND := GUID{0x1aab75c8, 0xcfef, 0x451c, {0xab, 0x95, 0xac, 0x03, 0x4b, 0x8e, 0x17, 0x31}}
MF_MT_AUDIO_CHANNEL_MASK := GUID{0x55fb5765, 0x644a, 0x4caf, {0x84, 0x79, 0x93, 0x89, 0x83, 0xbb, 0x15, 0x88}}
MF_MT_AAC_PAYLOAD_TYPE := GUID{0xbfbabe79, 0x7434, 0x4d1c, {0x94, 0xf0, 0x72, 0xa3, 0xb9, 0xe1, 0x71, 0x88}}
MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION := GUID{0x7632f0e6, 0x9538, 0x4d61, {0xac, 0xda, 0xea, 0x29, 0xc8, 0xc1, 0x44, 0x56}}
MF_MT_ALL_SAMPLES_INDEPENDENT := GUID{0xc9173739, 0x5e56, 0x461c, {0xb7, 0x13, 0x46, 0xfb, 0x99, 0x5c, 0xb9, 0x5f}}
MF_MT_VIDEO_NOMINAL_RANGE := GUID{0xc21b8ee5, 0xb956, 0x4071, {0x8d, 0xaf, 0x32, 0x5e, 0xdf, 0x5c, 0xab, 0x11}}
MF_MT_YUV_MATRIX := GUID{0x3e23d450, 0x2c75, 0x4d25, {0xa0, 0x0e, 0xb9, 0x16, 0x70, 0xd1, 0x23, 0x27}}
MF_MT_VIDEO_PRIMARIES := GUID{0xdbfbe4d7, 0x0740, 0x4ee0, {0x81, 0x92, 0x85, 0x0a, 0xb0, 0xe2, 0x19, 0x35}}
MF_MT_TRANSFER_FUNCTION := GUID{0x5fb0fce9, 0xbe5c, 0x4935, {0xa8, 0x11, 0xec, 0x83, 0x8f, 0x8e, 0xed, 0x93}}
MF_MT_DEFAULT_STRIDE := GUID{0x644b4e48, 0x1e02, 0x4516, {0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6}}
MF_MT_MINIMUM_DISPLAY_APERTURE := GUID{0xd7388766, 0x18fe, 0x48c6, {0xa1, 0x77, 0xee, 0x89, 0x48, 0x67, 0xc8, 0xc4}}
MF_MT_GEOMETRIC_APERTURE := GUID{0x66758743, 0x7e5f, 0x400d, {0x98, 0x0a, 0xaa, 0x85, 0x96, 0xc8, 0x56, 0x96}}
MF_MT_PAN_SCAN_APERTURE := GUID{0x79614dde, 0x9187, 0x48fb, {0xb8, 0xc7, 0x4d, 0x52, 0x68, 0x9d, 0xe6, 0x49}}
MF_SA_D3D11_BINDFLAGS := GUID{0xeacf97ad, 0x065c, 0x4408, {0xbe, 0xe3, 0xfd, 0xcb, 0xfd, 0x12, 0x8b, 0xe2}}
MF_SA_D3D11_AWARE := GUID{0x206b4fc8, 0xfcf9, 0x4c51, {0xaf, 0xe3, 0x97, 0x64, 0x36, 0x9e, 0x33, 0xa0}}
MF_TRANSFORM_ASYNC := GUID{0xf81a699a, 0x649a, 0x497d, {0x8c, 0x73, 0x29, 0xf8, 0xfe, 0xd6, 0xad, 0x7a}}
MF_LOW_LATENCY := GUID{0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}}
MFSampleExtension_CleanPoint := GUID{0x9cdf01d8, 0xa0f0, 0x43ba, {0xb0, 0x77, 0xea, 0xa0, 0x6c, 0xbd, 0x72, 0x8a}}
MFSampleExtension_Discontinuity := GUID{0x9cdf01d9, 0xa0f0, 0x43ba, {0xb0, 0x77, 0xea, 0xa0, 0x6c, 0xbd, 0x72, 0x8a}}
MFT_CATEGORY_VIDEO_DECODER :: GUID{0xd6c02d4b, 0x6833, 0x45b4, {0x97, 0x1a, 0x05, 0xa4, 0xb0, 0x4b, 0xab, 0x91}}
MFT_CATEGORY_AUDIO_DECODER :: GUID{0x9ea73fb4, 0xef7a, 0x4559, {0x8d, 0x5d, 0x71, 0x9d, 0x8f, 0x04, 0x26, 0xc7}}

// {FOURCC-0000-0010-8000-00AA00389B71}
@(private)
mf_format_guid :: proc "contextless" (data1: u32) -> GUID {
	return GUID{data1, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
}

@(private)
fourcc_u32 :: proc "contextless" (a, b, c, d: u8) -> u32 { return u32(a) | u32(b) << 8 | u32(c) << 16 | u32(d) << 24 }

MFMediaType_Video :: GUID{0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFMediaType_Audio :: GUID{0x73647561, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFVideoFormat_H264 :: GUID{0x34363248, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFVideoFormat_HEVC :: GUID{0x43564548, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFVideoFormat_AV1 :: GUID{0x31305641, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFVideoFormat_VP90 :: GUID{0x30395056, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFVideoFormat_NV12 :: GUID{0x3231564E, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFVideoFormat_P010 :: GUID{0x30313050, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFAudioFormat_PCM :: GUID{0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFAudioFormat_Float :: GUID{0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFAudioFormat_MP3 :: GUID{0x00000055, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFAudioFormat_AAC :: GUID{0x00001610, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFAudioFormat_Opus :: GUID{0x0000704F, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
MFAudioFormat_FLAC :: GUID{0x0000F1AC, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}

IID_IMFDXGIBuffer := GUID{0xe7174cfa, 0x1c9e, 0x48b1, {0x88, 0x66, 0x62, 0x62, 0x26, 0xbf, 0xc2, 0x58}}
IID_ID3D11Texture2D := GUID{0x6f15aaf2, 0xd208, 0x4e89, {0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c}}
IID_ID3D10Multithread := GUID{0x9b7e4e00, 0x342c, 0x4106, {0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0}}
IID_IMFTransform := GUID{0xbf94c121, 0x5b05, 0x4e6f, {0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d}}

////////////////////////////////
// Interfaces

IMFAttributes :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMFAttributes_VTable,
}

IMFAttributes_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetItem:          rawptr,
	GetItemType:      rawptr,
	CompareItem:      rawptr,
	Compare:          rawptr,
	GetUINT32:        proc "system" (this: ^IMFAttributes, key: ^GUID, value: ^u32) -> HRESULT,
	GetUINT64:        proc "system" (this: ^IMFAttributes, key: ^GUID, value: ^u64) -> HRESULT,
	GetDouble:        rawptr,
	GetGUID:          proc "system" (this: ^IMFAttributes, key: ^GUID, value: ^GUID) -> HRESULT,
	GetStringLength:  rawptr,
	GetString:        rawptr,
	GetAllocatedString: rawptr,
	GetBlobSize:      proc "system" (this: ^IMFAttributes, key: ^GUID, size: ^u32) -> HRESULT,
	GetBlob:          proc "system" (this: ^IMFAttributes, key: ^GUID, buf: [^]u8, size: u32, written: ^u32) -> HRESULT,
	GetAllocatedBlob: rawptr,
	GetUnknown:       proc "system" (this: ^IMFAttributes, key: ^GUID, riid: ^GUID, out: ^rawptr) -> HRESULT,
	SetItem:          rawptr,
	DeleteItem:       rawptr,
	DeleteAllItems:   rawptr,
	SetUINT32:        proc "system" (this: ^IMFAttributes, key: ^GUID, value: u32) -> HRESULT,
	SetUINT64:        proc "system" (this: ^IMFAttributes, key: ^GUID, value: u64) -> HRESULT,
	SetDouble:        rawptr,
	SetGUID:          proc "system" (this: ^IMFAttributes, key: ^GUID, value: ^GUID) -> HRESULT,
	SetString:        rawptr,
	SetBlob:          proc "system" (this: ^IMFAttributes, key: ^GUID, buf: [^]u8, size: u32) -> HRESULT,
	SetUnknown:       proc "system" (this: ^IMFAttributes, key: ^GUID, value: ^IUnknown) -> HRESULT,
	LockStore:        rawptr,
	UnlockStore:      rawptr,
	GetCount:         rawptr,
	GetItemByIndex:   rawptr,
	CopyAllItems:     rawptr,
}

IMFMediaType :: struct #raw_union {
	#subtype imfattributes: IMFAttributes,
	using vtable: ^IMFMediaType_VTable,
}

IMFMediaType_VTable :: struct {
	using imfattributes_vtable: IMFAttributes_VTable,
	GetMajorType:       proc "system" (this: ^IMFMediaType, major: ^GUID) -> HRESULT,
	IsCompressedFormat: rawptr,
	IsEqual:            rawptr,
	GetRepresentation:  rawptr,
	FreeRepresentation: rawptr,
}

IMFMediaBuffer :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMFMediaBuffer_VTable,
}

IMFMediaBuffer_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	Lock:             proc "system" (this: ^IMFMediaBuffer, data: ^[^]u8, max_len, cur_len: ^u32) -> HRESULT,
	Unlock:           proc "system" (this: ^IMFMediaBuffer) -> HRESULT,
	GetCurrentLength: proc "system" (this: ^IMFMediaBuffer, len: ^u32) -> HRESULT,
	SetCurrentLength: proc "system" (this: ^IMFMediaBuffer, len: u32) -> HRESULT,
	GetMaxLength:     proc "system" (this: ^IMFMediaBuffer, len: ^u32) -> HRESULT,
}

IMFSample :: struct #raw_union {
	#subtype imfattributes: IMFAttributes,
	using vtable: ^IMFSample_VTable,
}

IMFSample_VTable :: struct {
	using imfattributes_vtable: IMFAttributes_VTable,
	GetSampleFlags:      rawptr,
	SetSampleFlags:      rawptr,
	GetSampleTime:       proc "system" (this: ^IMFSample, t: ^i64) -> HRESULT,
	SetSampleTime:       proc "system" (this: ^IMFSample, t: i64) -> HRESULT,
	GetSampleDuration:   proc "system" (this: ^IMFSample, t: ^i64) -> HRESULT,
	SetSampleDuration:   proc "system" (this: ^IMFSample, t: i64) -> HRESULT,
	GetBufferCount:      proc "system" (this: ^IMFSample, n: ^u32) -> HRESULT,
	GetBufferByIndex:    proc "system" (this: ^IMFSample, i: u32, buf: ^^IMFMediaBuffer) -> HRESULT,
	ConvertToContiguousBuffer: proc "system" (this: ^IMFSample, buf: ^^IMFMediaBuffer) -> HRESULT,
	AddBuffer:           proc "system" (this: ^IMFSample, buf: ^IMFMediaBuffer) -> HRESULT,
	RemoveBufferByIndex: rawptr,
	RemoveAllBuffers:    rawptr,
	GetTotalLength:      proc "system" (this: ^IMFSample, n: ^u32) -> HRESULT,
	CopyToBuffer:        rawptr,
}

IMF2DBuffer :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMF2DBuffer_VTable,
}

IMF2DBuffer_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	Lock2D:                proc "system" (this: ^IMF2DBuffer, scanline0: ^[^]u8, pitch: ^i32) -> HRESULT,
	Unlock2D:              proc "system" (this: ^IMF2DBuffer) -> HRESULT,
	GetScanline0AndPitch:  rawptr,
	IsContiguousFormat:    rawptr,
	GetContiguousLength:   rawptr,
	ContiguousCopyTo:      rawptr,
	ContiguousCopyFrom:    rawptr,
}

IMFDXGIBuffer :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMFDXGIBuffer_VTable,
}

IMFDXGIBuffer_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetResource:         proc "system" (this: ^IMFDXGIBuffer, riid: ^GUID, out: ^rawptr) -> HRESULT,
	GetSubresourceIndex: proc "system" (this: ^IMFDXGIBuffer, index: ^u32) -> HRESULT,
	GetUnknown:          rawptr,
	SetUnknown:          rawptr,
}

IMFDXGIDeviceManager :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMFDXGIDeviceManager_VTable,
}

IMFDXGIDeviceManager_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	CloseDeviceHandle: rawptr,
	GetVideoService:   rawptr,
	LockDevice:        rawptr,
	OpenDeviceHandle:  rawptr,
	ResetDevice:       proc "system" (this: ^IMFDXGIDeviceManager, device: ^IUnknown, token: u32) -> HRESULT,
	TestDevice:        rawptr,
	UnlockDevice:      rawptr,
}

IMFActivate :: struct #raw_union {
	#subtype imfattributes: IMFAttributes,
	using vtable: ^IMFActivate_VTable,
}

IMFActivate_VTable :: struct {
	using imfattributes_vtable: IMFAttributes_VTable,
	ActivateObject: proc "system" (this: ^IMFActivate, riid: ^GUID, out: ^rawptr) -> HRESULT,
	ShutdownObject: proc "system" (this: ^IMFActivate) -> HRESULT,
	DetachObject:   rawptr,
}

IMFTransform :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMFTransform_VTable,
}

IMFTransform_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetStreamLimits:  rawptr,
	GetStreamCount:   rawptr,
	GetStreamIDs:     rawptr,
	GetInputStreamInfo:  proc "system" (this: ^IMFTransform, id: u32, info: ^MFT_INPUT_STREAM_INFO) -> HRESULT,
	GetOutputStreamInfo: proc "system" (this: ^IMFTransform, id: u32, info: ^MFT_OUTPUT_STREAM_INFO) -> HRESULT,
	GetAttributes:       proc "system" (this: ^IMFTransform, attrs: ^^IMFAttributes) -> HRESULT,
	GetInputStreamAttributes:  rawptr,
	GetOutputStreamAttributes: proc "system" (this: ^IMFTransform, id: u32, attrs: ^^IMFAttributes) -> HRESULT,
	DeleteInputStream: rawptr,
	AddInputStreams:   rawptr,
	GetInputAvailableType:  rawptr,
	GetOutputAvailableType: proc "system" (this: ^IMFTransform, id, index: u32, t: ^^IMFMediaType) -> HRESULT,
	SetInputType:      proc "system" (this: ^IMFTransform, id: u32, t: ^IMFMediaType, flags: u32) -> HRESULT,
	SetOutputType:     proc "system" (this: ^IMFTransform, id: u32, t: ^IMFMediaType, flags: u32) -> HRESULT,
	GetInputCurrentType:  rawptr,
	GetOutputCurrentType: proc "system" (this: ^IMFTransform, id: u32, t: ^^IMFMediaType) -> HRESULT,
	GetInputStatus:    rawptr,
	GetOutputStatus:   rawptr,
	SetOutputBounds:   rawptr,
	ProcessEvent:      rawptr,
	ProcessMessage:    proc "system" (this: ^IMFTransform, msg: uintptr, param: uintptr) -> HRESULT,
	ProcessInput:      proc "system" (this: ^IMFTransform, id: u32, sample: ^IMFSample, flags: u32) -> HRESULT,
	ProcessOutput:     proc "system" (this: ^IMFTransform, flags: u32, count: u32, buffers: ^MFT_OUTPUT_DATA_BUFFER, status: ^u32) -> HRESULT,
}

// ID3D10Multithread: serialises the device's immediate context between the threads that use it (the interface thread
// that draws, and the threads Media Foundation decodes on).
ID3D10Multithread :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^ID3D10Multithread_VTable,
}

ID3D10Multithread_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	Enter:                   proc "system" (this: ^ID3D10Multithread),
	Leave:                   proc "system" (this: ^ID3D10Multithread),
	SetMultithreadProtected: proc "system" (this: ^ID3D10Multithread, protect: win.BOOL) -> win.BOOL,
	GetMultithreadProtected: proc "system" (this: ^ID3D10Multithread) -> win.BOOL,
}

@(default_calling_convention = "system")
foreign mfplat {
	MFStartup :: proc(version: u32, flags: u32) -> HRESULT ---
	MFShutdown :: proc() -> HRESULT ---
	MFCreateMediaType :: proc(out: ^^IMFMediaType) -> HRESULT ---
	MFCreateSample :: proc(out: ^^IMFSample) -> HRESULT ---
	MFCreateMemoryBuffer :: proc(max_len: u32, out: ^^IMFMediaBuffer) -> HRESULT ---
	MFCreateAttributes :: proc(out: ^^IMFAttributes, initial_size: u32) -> HRESULT ---
	MFCreateDXGIDeviceManager :: proc(token: ^u32, out: ^^IMFDXGIDeviceManager) -> HRESULT ---
	MFTEnumEx :: proc(category: GUID, flags: u32, input: ^MFT_REGISTER_TYPE_INFO, output: ^MFT_REGISTER_TYPE_INFO, activates: ^[^]^IMFActivate, count: ^u32) -> HRESULT ---
}

@(default_calling_convention = "system")
foreign ole32 {
	CoTaskMemFree :: proc(p: rawptr) ---
}

// Release for any of the COM pointers above (they all start with IUnknown).
@(private)
com_release :: proc "contextless" (p: ^$T) {
	if p != nil { (^IUnknown)(p)->Release() }
}

@(private)
com_addref :: proc "contextless" (p: ^$T) {
	if p != nil { (^IUnknown)(p)->AddRef() }
}

@(private)
hr_ok :: #force_inline proc "contextless" (hr: HRESULT) -> bool { return hr >= 0 }

// MF_MT_FRAME_SIZE and friends hold two u32 in one u64 (high, low).
@(private)
pack2 :: #force_inline proc "contextless" (hi, lo: u32) -> u64 { return u64(hi) << 32 | u64(lo) }

// Media Foundation is started once for the process (every decoder thread needs it; COM in the multithreaded apartment).
@(private) mf_started: bool

mf_startup :: proc() -> bool {
	@(static) tried: bool
	if tried { return mf_started }
	tried = true
	// the interface thread may be in a single-threaded apartment already: Media Foundation works in either
	_ = win.CoInitializeEx(nil, .MULTITHREADED)
	mf_started = hr_ok(MFStartup(MF_VERSION, MFSTARTUP_FULL))
	return mf_started
}

// Media Foundation needs the calling thread's COM initialized: decoder threads call this first.
com_thread_init :: proc "contextless" () { _ = win.CoInitializeEx(nil, .MULTITHREADED) }

// The WebCodecs domain (module webcodecs of api/webcodecs.widl): VideoFrame, ImageDecoder / ImageTrackList /
// ImageTrack, the decoders, the encoded chunks, AudioData and the encoders. Declared from today's generated wr_*
// imports (native/js/odin/wj/wr_imports.odin): a `has_*` flag that travels next to its value on the wire (value first,
// then the flag) is a separate bool here, not a Maybe (whose scalar wire puts the flag first). VideoFrame_fromBuffer
// is not declared: its 27 wire parameters are more than one bound call carries (abi.MAX_PARAMS); it becomes a
// dictionary argument when the host side moves to the serialised path.
package api_decl

import "../abi"

VideoFrame        :: distinct abi.Handle
ImageDecoder      :: distinct abi.Handle
ImageTrackList    :: distinct abi.Handle
ImageTrack        :: distinct abi.Handle
VideoDecoder      :: distinct abi.Handle
AudioDecoder      :: distinct abi.Handle
EncodedVideoChunk :: distinct abi.Handle
EncodedAudioChunk :: distinct abi.Handle
AudioData         :: distinct abi.Handle
VideoEncoder      :: distinct abi.Handle
AudioEncoder      :: distinct abi.Handle

// ---- VideoFrame ----

// new VideoFrame(image, init): `source` is the handle of any CanvasImageSource (an element or an object).
VideoFrame_fromImage :: #type proc(source: u64, timestamp: i64, has_ts: bool, duration: i64, has_duration: bool) -> (abi.Owned(VideoFrame), abi.Api_Error)
// The VideoPixelFormat (the host's Frame_Format: 0 none, then I420 ... BGRX), the sizes, the times (-1: no duration).
VideoFrame_format        :: #type proc(frame: VideoFrame) -> i32
VideoFrame_codedWidth    :: #type proc(frame: VideoFrame) -> u32
VideoFrame_codedHeight   :: #type proc(frame: VideoFrame) -> u32
VideoFrame_displayWidth  :: #type proc(frame: VideoFrame) -> u32
VideoFrame_displayHeight :: #type proc(frame: VideoFrame) -> u32
VideoFrame_timestamp     :: #type proc(frame: VideoFrame) -> i64
VideoFrame_duration      :: #type proc(frame: VideoFrame) -> i64
// visibleRect's x y width height (which 0..3; -1 when closed)
VideoFrame_visibleRect   :: #type proc(frame: VideoFrame, which: i32) -> f64
// colorSpace's primaries / transfer / matrix enum index or fullRange (which 0..3; -1: null)
VideoFrame_colorSpace    :: #type proc(frame: VideoFrame, which: i32) -> i32
VideoFrame_isClosed      :: #type proc(frame: VideoFrame) -> bool
// allocationSize(options): format -1 is the frame's; the rect and the layout only when their flag is set.
VideoFrame_allocationSize :: #type proc(frame: VideoFrame, format: i32, rx, ry, rw, rh: i32, has_rect: bool,
	layout_offsets: []i32, layout_strides: []i32, has_layout: bool) -> (i32, abi.Api_Error)
// copyTo(destination, options): the number of planes written; their layout with VideoFrame_copyLayout.
VideoFrame_copyTo :: #type proc(frame: VideoFrame, dst: []u8, format: i32, rx, ry, rw, rh: i32, has_rect: bool,
	in_offsets: []i32, in_strides: []i32, has_layout: bool) -> (i32, abi.Api_Error)
// The offset (which 0) or the stride (which 1) of a plane of the last copyTo.
VideoFrame_copyLayout :: #type proc(frame: VideoFrame, plane: i32, which: i32) -> i32
VideoFrame_clone      :: #type proc(frame: VideoFrame) -> (abi.Owned(VideoFrame), abi.Api_Error)
VideoFrame_close      :: #type proc(frame: VideoFrame)

// ---- ImageDecoder ----

ImageDecoder_create          :: #type proc(data: []u8, mime: string, prefer_animation: bool) -> (abi.Owned(ImageDecoder), abi.Api_Error)
ImageDecoder_isTypeSupported :: #type proc(mime: string) -> bool
ImageDecoder_type            :: #type proc(decoder: ImageDecoder) -> string
ImageDecoder_complete        :: #type proc(decoder: ImageDecoder) -> bool
ImageDecoder_decode          :: #type proc(decoder: ImageDecoder, frame_index: u32) -> (VideoFrame, abi.Api_Error)
ImageDecoder_reset           :: #type proc(decoder: ImageDecoder)
ImageDecoder_close           :: #type proc(decoder: ImageDecoder)
// The decoder's track list (borrowed: the same object every call; 0 when none).
ImageDecoder_tracks          :: #type proc(decoder: ImageDecoder) -> ImageTrackList

ImageTrackList_length        :: #type proc(list: ImageTrackList) -> u32
ImageTrackList_item          :: #type proc(list: ImageTrackList, index: u32) -> (ImageTrack, abi.Api_Error)
ImageTrackList_selectedIndex :: #type proc(list: ImageTrackList) -> i32

ImageTrack_animated       :: #type proc(track: ImageTrack) -> bool
ImageTrack_frameCount     :: #type proc(track: ImageTrack) -> u32
// -1: forever
ImageTrack_repetitionCount :: #type proc(track: ImageTrack) -> i32
ImageTrack_selected       :: #type proc(track: ImageTrack) -> bool

// ---- decoders: output / error are function-table indices with their `user` words ----

VideoDecoder_create :: #type proc(output: i32, output_user: i32, error: i32, error_user: i32) -> (abi.Owned(VideoDecoder), abi.Api_Error)
VideoDecoder_isConfigSupported :: #type proc(codec: string) -> bool
VideoDecoder_configure :: #type proc(decoder: VideoDecoder, codec: string, description: []u8, coded_w: u32, coded_h: u32) -> abi.Api_Error
VideoDecoder_decode :: #type proc(decoder: VideoDecoder, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> abi.Api_Error
VideoDecoder_flush :: #type proc(decoder: VideoDecoder) -> abi.Api_Error
VideoDecoder_reset :: #type proc(decoder: VideoDecoder)
VideoDecoder_close :: #type proc(decoder: VideoDecoder)
VideoDecoder_decodeQueueSize :: #type proc(decoder: VideoDecoder) -> u32
// 0 unconfigured, 1 configured, 2 closed
VideoDecoder_state :: #type proc(decoder: VideoDecoder) -> i32

AudioDecoder_create :: #type proc(output: i32, output_user: i32, error: i32, error_user: i32) -> (abi.Owned(AudioDecoder), abi.Api_Error)
AudioDecoder_isConfigSupported :: #type proc(codec: string) -> bool
AudioDecoder_configure :: #type proc(decoder: AudioDecoder, codec: string, description: []u8, sample_rate: u32, channels: u32) -> abi.Api_Error
AudioDecoder_decode :: #type proc(decoder: AudioDecoder, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> abi.Api_Error
AudioDecoder_flush :: #type proc(decoder: AudioDecoder) -> abi.Api_Error
AudioDecoder_reset :: #type proc(decoder: AudioDecoder)
AudioDecoder_close :: #type proc(decoder: AudioDecoder)
AudioDecoder_decodeQueueSize :: #type proc(decoder: AudioDecoder) -> u32
AudioDecoder_state :: #type proc(decoder: AudioDecoder) -> i32

// ---- encoded chunks ----

EncodedVideoChunk_create :: #type proc(key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> (abi.Owned(EncodedVideoChunk), abi.Api_Error)
EncodedAudioChunk_create :: #type proc(key: bool, timestamp: i64, duration: i64, has_duration: bool, data: []u8) -> (abi.Owned(EncodedAudioChunk), abi.Api_Error)
// type: true for "key"
EncodedVideoChunk_type       :: #type proc(chunk: EncodedVideoChunk) -> bool
EncodedVideoChunk_timestamp  :: #type proc(chunk: EncodedVideoChunk) -> i64
EncodedVideoChunk_duration   :: #type proc(chunk: EncodedVideoChunk) -> i64
EncodedVideoChunk_byteLength :: #type proc(chunk: EncodedVideoChunk) -> u32
EncodedVideoChunk_copyTo     :: #type proc(chunk: EncodedVideoChunk, dst: []u8) -> (i32, abi.Api_Error)
EncodedAudioChunk_type       :: #type proc(chunk: EncodedAudioChunk) -> bool
EncodedAudioChunk_timestamp  :: #type proc(chunk: EncodedAudioChunk) -> i64
EncodedAudioChunk_duration   :: #type proc(chunk: EncodedAudioChunk) -> i64
EncodedAudioChunk_byteLength :: #type proc(chunk: EncodedAudioChunk) -> u32
EncodedAudioChunk_copyTo     :: #type proc(chunk: EncodedAudioChunk, dst: []u8) -> (i32, abi.Api_Error)

// ---- AudioData ----

// format: the host's sample format (0 none, then u8 s16 s32 f32 and their -planar forms)
AudioData_create :: #type proc(format: i32, sample_rate: f64, frames: u32, channels: u32, timestamp: i64, data: []u8) -> (abi.Owned(AudioData), abi.Api_Error)
AudioData_format           :: #type proc(data: AudioData) -> i32
AudioData_sampleRate       :: #type proc(data: AudioData) -> f64
AudioData_numberOfFrames   :: #type proc(data: AudioData) -> u32
AudioData_numberOfChannels :: #type proc(data: AudioData) -> u32
AudioData_timestamp        :: #type proc(data: AudioData) -> i64
AudioData_duration         :: #type proc(data: AudioData) -> i64
AudioData_allocationSize   :: #type proc(data: AudioData, plane_index: u32, format: i32, frame_offset: u32, frame_count: u32, has_count: bool) -> (i32, abi.Api_Error)
AudioData_copyTo           :: #type proc(data: AudioData, dst: []u8, plane_index: u32, format: i32, frame_offset: u32, frame_count: u32, has_count: bool) -> (i32, abi.Api_Error)
AudioData_clone            :: #type proc(data: AudioData) -> (abi.Owned(AudioData), abi.Api_Error)
AudioData_close            :: #type proc(data: AudioData)

// ---- encoders (none linked: isConfigSupported is false, configure raises Not_Supported) ----

VideoEncoder_create :: #type proc(output: i32, output_user: i32, error: i32, error_user: i32) -> (abi.Owned(VideoEncoder), abi.Api_Error)
AudioEncoder_create :: #type proc(output: i32, output_user: i32, error: i32, error_user: i32) -> (abi.Owned(AudioEncoder), abi.Api_Error)
VideoEncoder_isConfigSupported :: #type proc(codec: string) -> bool
AudioEncoder_isConfigSupported :: #type proc(codec: string) -> bool
VideoEncoder_configure :: #type proc(encoder: VideoEncoder, codec: string) -> abi.Api_Error
AudioEncoder_configure :: #type proc(encoder: AudioEncoder, codec: string) -> abi.Api_Error
VideoEncoder_encode :: #type proc(encoder: VideoEncoder) -> abi.Api_Error
AudioEncoder_encode :: #type proc(encoder: AudioEncoder) -> abi.Api_Error
VideoEncoder_flush :: #type proc(encoder: VideoEncoder) -> abi.Api_Error
AudioEncoder_flush :: #type proc(encoder: AudioEncoder) -> abi.Api_Error
VideoEncoder_reset :: #type proc(encoder: VideoEncoder)
AudioEncoder_reset :: #type proc(encoder: AudioEncoder)
VideoEncoder_close :: #type proc(encoder: VideoEncoder)
AudioEncoder_close :: #type proc(encoder: AudioEncoder)
VideoEncoder_encodeQueueSize :: #type proc(encoder: VideoEncoder) -> u32
AudioEncoder_encodeQueueSize :: #type proc(encoder: AudioEncoder) -> u32
VideoEncoder_state :: #type proc(encoder: VideoEncoder) -> i32
AudioEncoder_state :: #type proc(encoder: AudioEncoder) -> i32

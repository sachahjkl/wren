// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webcodecs_codec order=71 exposed=(Window,Worker)
/// WebCodecs encoded chunks and AudioData (src/page/webcodecs_chunks.odin, native/js/runtime/web_webcodecs_codec.c).
/// EncodedVideoChunk / EncodedAudioChunk are immutable coded samples; AudioData is decoded PCM with planar / interleaved
/// copyTo. All the layouts and conversions are native.
package api_webcodecs_codec

//@wb handle parent=Object host=Encoded_Chunk_Obj lookup=lookup_EncodedVideoChunk
EncodedVideoChunk :: distinct Handle

//@wb handle parent=Object host=Encoded_Chunk_Obj lookup=lookup_EncodedAudioChunk
EncodedAudioChunk :: distinct Handle

//@wb handle parent=Object host=Audio_Data_Obj lookup=lookup_AudioData
AudioData :: distinct Handle

/// The WebCodecs AudioSampleFormat enum, in the order webcodecs_chunks.odin's Audio_Sample_Format uses (format()
/// returns -1 for a closed AudioData, which the engine maps to null).
AudioSampleFormat :: enum i32 {
	None,
	U8,
	S16,
	S32,
	F32,
	U8_Planar,
	S16_Planar,
	S32_Planar,
	F32_Planar,
}

/// new EncodedVideoChunk / EncodedAudioChunk({type, timestamp, duration, data}). `key` is type == "key".
//@wb fn raises owned
EncodedVideoChunk_create :: proc(key: bool, timestamp: i64, duration: i64, has_duration: bool, data: bytes) -> EncodedVideoChunk

//@wb fn raises owned
EncodedAudioChunk_create :: proc(key: bool, timestamp: i64, duration: i64, has_duration: bool, data: bytes) -> EncodedAudioChunk

/// chunk.type: true "key", false "delta".
//@wb fn
EncodedVideoChunk_type :: proc(chunk: EncodedVideoChunk) -> bool

//@wb fn
EncodedVideoChunk_timestamp :: proc(chunk: EncodedVideoChunk) -> i64

/// chunk.duration: -1 (null) when absent.
//@wb fn
EncodedVideoChunk_duration :: proc(chunk: EncodedVideoChunk) -> i64

//@wb fn
EncodedVideoChunk_byteLength :: proc(chunk: EncodedVideoChunk) -> u32

/// chunk.copyTo(dst): the bytes written. Type when the destination is too small.
//@wb fn raises out=dst
EncodedVideoChunk_copyTo :: proc(chunk: EncodedVideoChunk, dst: bytes) -> i32

//@wb fn
EncodedAudioChunk_type :: proc(chunk: EncodedAudioChunk) -> bool

//@wb fn
EncodedAudioChunk_timestamp :: proc(chunk: EncodedAudioChunk) -> i64

//@wb fn
EncodedAudioChunk_duration :: proc(chunk: EncodedAudioChunk) -> i64

//@wb fn
EncodedAudioChunk_byteLength :: proc(chunk: EncodedAudioChunk) -> u32

//@wb fn raises out=dst
EncodedAudioChunk_copyTo :: proc(chunk: EncodedAudioChunk, dst: bytes) -> i32

/// new AudioData({format, sampleRate, numberOfFrames, numberOfChannels, timestamp, data}).
//@wb fn raises owned
AudioData_create :: proc(format: AudioSampleFormat, sample_rate: f64, frames: u32, channels: u32, timestamp: i64, data: bytes) -> AudioData

/// data.format: -1 (null) for a closed AudioData.
//@wb fn
AudioData_format :: proc(data: AudioData) -> i32

//@wb fn
AudioData_sampleRate :: proc(data: AudioData) -> f64

//@wb fn
AudioData_numberOfFrames :: proc(data: AudioData) -> u32

//@wb fn
AudioData_numberOfChannels :: proc(data: AudioData) -> u32

//@wb fn
AudioData_timestamp :: proc(data: AudioData) -> i64

/// data.duration, microseconds.
//@wb fn
AudioData_duration :: proc(data: AudioData) -> i64

/// data.allocationSize(options): bytes for one plane (planar) or the interleaved block, in `format` (-1 = own).
//@wb fn raises
AudioData_allocationSize :: proc(data: AudioData, plane_index: u32, format: i32, frame_offset: u32, frame_count: u32, has_count: bool) -> i32

/// data.copyTo(destination, options): converts and copies; returns the bytes written.
//@wb fn raises out=dst
AudioData_copyTo :: proc(data: AudioData, dst: bytes, plane_index: u32, format: i32, frame_offset: u32, frame_count: u32, has_count: bool) -> i32

//@wb fn raises owned
AudioData_clone :: proc(data: AudioData) -> AudioData

//@wb fn
AudioData_close :: proc(data: AudioData)


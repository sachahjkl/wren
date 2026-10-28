// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webcodecs_audio_decoder order=69 exposed=(Window,Worker)
/// WebCodecs AudioDecoder (src/page/bindings_audio_decoder.odin, native/js/runtime/web_webcodecs_audio_decoder.c).
/// Wires to the audio decoders of src/media behind an honest isConfigSupported; a decoded block becomes an AudioData
/// delivered through the output callback.
package api_webcodecs_audio_decoder

//@wb handle parent=Object host=Audio_Decoder_Obj lookup=lookup_AudioDecoder
AudioDecoder :: distinct Handle

//@wb callback
AudioDecoderOutput :: #type proc "contextless" (user: i32, data: u64)

//@wb callback
AudioDecoderError :: #type proc "contextless" (user: i32, code: i32)

//@wb fn raises owned
AudioDecoder_create :: proc(output: AudioDecoderOutput, output_user: i32, error: AudioDecoderError, error_user: i32) -> AudioDecoder

/// AudioDecoder.isConfigSupported(config.codec): honest (AAC, MP3, Opus, FLAC).
//@wb fn
AudioDecoder_isConfigSupported :: proc(codec: string) -> bool

//@wb fn raises
AudioDecoder_configure :: proc(decoder: AudioDecoder, codec: string, description: bytes, sample_rate: u32, channels: u32)

//@wb fn raises
AudioDecoder_decode :: proc(decoder: AudioDecoder, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: bytes)

//@wb fn raises
AudioDecoder_flush :: proc(decoder: AudioDecoder)

//@wb fn
AudioDecoder_reset :: proc(decoder: AudioDecoder)

//@wb fn
AudioDecoder_close :: proc(decoder: AudioDecoder)

//@wb fn
AudioDecoder_decodeQueueSize :: proc(decoder: AudioDecoder) -> u32

//@wb fn
AudioDecoder_state :: proc(decoder: AudioDecoder) -> i32


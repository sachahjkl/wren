// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webcodecs_video_decoder order=74 exposed=(Window,Worker)
/// WebCodecs VideoDecoder (src/page/bindings_video_decoder.odin, native/js/runtime/web_webcodecs_video_decoder.c).
/// Wires to the media decoders of src/media behind an honest isConfigSupported. The engine holds the output / error
/// callbacks; a decoded VideoFrame is delivered through the output callback (user, frame handle).
package api_webcodecs_video_decoder

//@wb handle parent=Object host=Video_Decoder_Obj lookup=lookup_VideoDecoder
VideoDecoder :: distinct Handle

/// output(frame) and error(code) callbacks. The frame handle is a VideoFrame the guest must close.
//@wb callback
VideoDecoderOutput :: #type proc "contextless" (user: i32, frame: u64)

//@wb callback
VideoDecoderError :: #type proc "contextless" (user: i32, code: i32)

/// new VideoDecoder({output, error}).
//@wb fn raises owned
VideoDecoder_create :: proc(output: VideoDecoderOutput, output_user: i32, error: VideoDecoderError, error_user: i32) -> VideoDecoder

/// VideoDecoder.isConfigSupported(config.codec): honest — true only when src/media can decode the codec.
//@wb fn
VideoDecoder_isConfigSupported :: proc(codec: string) -> bool

/// decoder.configure({codec, description, codedWidth, codedHeight}).
//@wb fn raises
VideoDecoder_configure :: proc(decoder: VideoDecoder, codec: string, description: bytes, coded_w: u32, coded_h: u32)

/// decoder.decode(EncodedVideoChunk): the engine passes the chunk's fields and bytes.
//@wb fn raises
VideoDecoder_decode :: proc(decoder: VideoDecoder, key: bool, timestamp: i64, duration: i64, has_duration: bool, data: bytes)

/// decoder.flush(): drain the pipeline (the engine resolves the promise).
//@wb fn raises
VideoDecoder_flush :: proc(decoder: VideoDecoder)

//@wb fn
VideoDecoder_reset :: proc(decoder: VideoDecoder)

//@wb fn
VideoDecoder_close :: proc(decoder: VideoDecoder)

//@wb fn
VideoDecoder_decodeQueueSize :: proc(decoder: VideoDecoder) -> u32

/// 0 unconfigured, 1 configured, 2 closed.
//@wb fn
VideoDecoder_state :: proc(decoder: VideoDecoder) -> i32


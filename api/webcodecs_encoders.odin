// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webcodecs_encoders order=71 exposed=(Window,Worker)
/// WebCodecs VideoEncoder / AudioEncoder (src/page/bindings_encoders.odin, native/js/runtime/web_webcodecs_encoders.c).
/// No encoder is linked in this build, so isConfigSupported is honestly false and configure raises NotSupportedError.
/// The objects and their state machine exist so feature detection and `new VideoEncoder({...})` behave; when an encoder
/// crate is added, configure()/encode() wire to it here.
package api_webcodecs_encoders

//@wb handle parent=Object host=Encoder_Obj lookup=lookup_VideoEncoder
VideoEncoder :: distinct Handle

//@wb handle parent=Object host=Encoder_Obj lookup=lookup_AudioEncoder
AudioEncoder :: distinct Handle

//@wb callback
VideoEncoderOutput :: #type proc "contextless" (user: i32, chunk: u64)

//@wb callback
VideoEncoderError :: #type proc "contextless" (user: i32, code: i32)

//@wb callback
AudioEncoderOutput :: #type proc "contextless" (user: i32, chunk: u64)

//@wb callback
AudioEncoderError :: #type proc "contextless" (user: i32, code: i32)

//@wb fn raises owned
VideoEncoder_create :: proc(output: VideoEncoderOutput, output_user: i32, error: VideoEncoderError, error_user: i32) -> VideoEncoder

//@wb fn raises owned
AudioEncoder_create :: proc(output: AudioEncoderOutput, output_user: i32, error: AudioEncoderError, error_user: i32) -> AudioEncoder

/// Honest: false for every codec (no encoder is linked).
//@wb fn
VideoEncoder_isConfigSupported :: proc(codec: string) -> bool

//@wb fn
AudioEncoder_isConfigSupported :: proc(codec: string) -> bool

/// Raises NotSupportedError (no encoder).
//@wb fn raises
VideoEncoder_configure :: proc(encoder: VideoEncoder, codec: string)

//@wb fn raises
AudioEncoder_configure :: proc(encoder: AudioEncoder, codec: string)

//@wb fn raises
VideoEncoder_encode :: proc(encoder: VideoEncoder)

//@wb fn raises
AudioEncoder_encode :: proc(encoder: AudioEncoder)

//@wb fn raises
VideoEncoder_flush :: proc(encoder: VideoEncoder)

//@wb fn raises
AudioEncoder_flush :: proc(encoder: AudioEncoder)

//@wb fn
VideoEncoder_reset :: proc(encoder: VideoEncoder)

//@wb fn
AudioEncoder_reset :: proc(encoder: AudioEncoder)

//@wb fn
VideoEncoder_close :: proc(encoder: VideoEncoder)

//@wb fn
AudioEncoder_close :: proc(encoder: AudioEncoder)

//@wb fn
VideoEncoder_encodeQueueSize :: proc(encoder: VideoEncoder) -> u32

//@wb fn
AudioEncoder_encodeQueueSize :: proc(encoder: AudioEncoder) -> u32

//@wb fn
VideoEncoder_state :: proc(encoder: VideoEncoder) -> i32

//@wb fn
AudioEncoder_state :: proc(encoder: AudioEncoder) -> i32


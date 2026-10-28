package page

// WebCodecs VideoEncoder / AudioEncoder (api/webcodecs_encoders.widl, native/js/runtime/web_webcodecs_encoders.c).
//
// Wren has no encoder wired in today: the Rust workspace (native/Cargo.toml) ships decoders only, and no pure-Rust
// video encoder (rav1e / a VP8/VP9 encoder) or Opus encoder is linked. Rather than pretend, the encoders are honest:
//   * isConfigSupported reports { supported: false } for every codec (and when webcodecs.allow_encoders is off);
//   * configure raises NotSupportedError.
// The objects exist (so `new VideoEncoder({...})` works and feature-detection via isConfigSupported behaves), their
// state machine is real, and encode()/flush() on an unconfigured encoder raise as the spec says. When an encoder crate
// is added later, this is the single place to wire configure() + encode() to it (the queue, the callbacks and the
// dequeue event are already here).

Encoder_Kind :: enum u8 { Video, Audio }

Encoder_Obj :: struct {
	page:      ^Page,
	self:      u64,
	kind:      Encoder_Kind,
	state:     Video_Decoder_State,
	output_cb, output_user: u32,
	error_cb, error_user:   u32,
	owner:     u32,
}

encoder_vt := Object_VTable{
	name = "Encoder",
	destroy = proc(p: ^Page, data: rawptr) { free((^Encoder_Obj)(data)) },
}

lookup_VideoEncoder :: proc(c: ^Call, h: u64) -> ^Encoder_Obj { return encoder_of(c.page, h, .Video) }
lookup_AudioEncoder :: proc(c: ^Call, h: u64) -> ^Encoder_Obj { return encoder_of(c.page, h, .Audio) }

@(private)
encoder_of :: proc(p: ^Page, h: u64, kind: Encoder_Kind) -> ^Encoder_Obj {
	e := (^Encoder_Obj)(object_data(p, h, &encoder_vt))
	if e == nil || e.kind != kind { return nil }
	return e
}

@(private)
encoder_new :: proc(c: ^Call, kind: Encoder_Kind, output_cb: u32, output_user: i32, error_cb: u32, error_user: i32) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }
	e := new(Encoder_Obj)
	e.page = p
	e.kind = kind
	e.owner = c.owner
	e.output_cb, e.output_user = output_cb, u32(output_user)
	e.error_cb, e.error_user = error_cb, u32(error_user)
	e.state = .Unconfigured
	e.self = object_create(p, &encoder_vt, e, c.owner)
	return e.self, .None
}

VideoEncoder_create :: proc(c: ^Call, output_cb: u32, output_user: i32, error_cb: u32, error_user: i32) -> (u64, Api_Error) {
	return encoder_new(c, .Video, output_cb, output_user, error_cb, error_user)
}
AudioEncoder_create :: proc(c: ^Call, output_cb: u32, output_user: i32, error_cb: u32, error_user: i32) -> (u64, Api_Error) {
	return encoder_new(c, .Audio, output_cb, output_user, error_cb, error_user)
}

// Honest: no encoder is linked. Both report false (and when encoders are disabled by preference).
VideoEncoder_isConfigSupported :: proc(c: ^Call, codec: string) -> bool { return false }
AudioEncoder_isConfigSupported :: proc(c: ^Call, codec: string) -> bool { return false }

VideoEncoder_configure :: proc(c: ^Call, enc: Api_VideoEncoder, codec: string) -> Api_Error {
	if enc.data == nil || enc.data.state == .Closed { return fail(c, .Invalid_State, "InvalidStateError: the VideoEncoder is closed.") }
	return fail(c, .Not_Supported, "NotSupportedError: video encoding is not available in this build.")
}
AudioEncoder_configure :: proc(c: ^Call, enc: Api_AudioEncoder, codec: string) -> Api_Error {
	if enc.data == nil || enc.data.state == .Closed { return fail(c, .Invalid_State, "InvalidStateError: the AudioEncoder is closed.") }
	return fail(c, .Not_Supported, "NotSupportedError: audio encoding is not available in this build.")
}

// encode / flush on an encoder that could never configure: InvalidStateError (it is Unconfigured), as the spec says.
VideoEncoder_encode :: proc(c: ^Call, enc: Api_VideoEncoder) -> Api_Error {
	if enc.data == nil || enc.data.state != .Configured { return fail(c, .Invalid_State, "InvalidStateError: the VideoEncoder is not configured.") }
	return .None
}
AudioEncoder_encode :: proc(c: ^Call, enc: Api_AudioEncoder) -> Api_Error {
	if enc.data == nil || enc.data.state != .Configured { return fail(c, .Invalid_State, "InvalidStateError: the AudioEncoder is not configured.") }
	return .None
}

VideoEncoder_flush :: proc(c: ^Call, enc: Api_VideoEncoder) -> Api_Error {
	if enc.data == nil || enc.data.state != .Configured { return fail(c, .Invalid_State, "InvalidStateError: the VideoEncoder is not configured.") }
	return .None
}
AudioEncoder_flush :: proc(c: ^Call, enc: Api_AudioEncoder) -> Api_Error {
	if enc.data == nil || enc.data.state != .Configured { return fail(c, .Invalid_State, "InvalidStateError: the AudioEncoder is not configured.") }
	return .None
}

VideoEncoder_reset :: proc(c: ^Call, enc: Api_VideoEncoder) { if enc.data != nil && enc.data.state != .Closed { enc.data.state = .Unconfigured } }
AudioEncoder_reset :: proc(c: ^Call, enc: Api_AudioEncoder) { if enc.data != nil && enc.data.state != .Closed { enc.data.state = .Unconfigured } }
VideoEncoder_close :: proc(c: ^Call, enc: Api_VideoEncoder) { if enc.data != nil { enc.data.state = .Closed } }
AudioEncoder_close :: proc(c: ^Call, enc: Api_AudioEncoder) { if enc.data != nil { enc.data.state = .Closed } }

VideoEncoder_encodeQueueSize :: proc(c: ^Call, enc: Api_VideoEncoder) -> u32 { return 0 }
AudioEncoder_encodeQueueSize :: proc(c: ^Call, enc: Api_AudioEncoder) -> u32 { return 0 }
VideoEncoder_state :: proc(c: ^Call, enc: Api_VideoEncoder) -> i32 { return enc.data == nil ? 0 : i32(enc.data.state) }
AudioEncoder_state :: proc(c: ^Call, enc: Api_AudioEncoder) -> i32 { return enc.data == nil ? 0 : i32(enc.data.state) }

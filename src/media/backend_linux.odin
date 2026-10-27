package media

// The platform backend on Linux: the built-in decoders of native/media (AV1 by rav1d and VP9 by vp9dec: av1_soft.odin,
// vp9_soft.odin). The other codecs answer "not supported" for now (canPlayType says "", a source falls to its next one
// or fails as an unsupported format), and the audio output is the null one, which lets audio go by at the pace of the
// clock.

backend_name :: proc() -> string { return "built-in" }

backend_video_decoder :: proc(t: Track, prefer_gpu: bool) -> ^Video_Decoder {
	#partial switch t.codec {
	case .AV1: if software_av1_enabled() { return av1_soft_create(t) }
	case .VP9: if software_vp9_enabled() { return vp9_soft_create(t) }
	}
	return nil
}

backend_audio_decoder :: proc(t: Track) -> ^Audio_Decoder { return nil }

backend_audio_output :: proc(rate: int) -> ^Audio_Output { return null_audio_open(rate) }

backend_video_support :: proc(c: Codec) -> Decoder_Support {
	#partial switch c {
	case .AV1: if software_av1_enabled() { return av1_soft_supported() }
	case .VP9: if software_vp9_enabled() { return vp9_soft_supported() }
	}
	return {}
}

backend_audio_support :: proc(c: Codec) -> Decoder_Support { return {} }

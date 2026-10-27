package media

// The platform backend on Linux. No decoder yet: every codec answers "not supported" (canPlayType says "", a source
// falls to its next one or fails as an unsupported format), and the audio output is the null one, which lets audio go
// by at the pace of the clock.

backend_name :: proc() -> string { return "none" }

backend_video_decoder :: proc(t: Track, prefer_gpu: bool) -> ^Video_Decoder { return nil }

backend_audio_decoder :: proc(t: Track) -> ^Audio_Decoder { return nil }

backend_audio_output :: proc(rate: int) -> ^Audio_Output { return null_audio_open(rate) }

backend_video_support :: proc(c: Codec) -> Decoder_Support { return {} }

backend_audio_support :: proc(c: Codec) -> Decoder_Support { return {} }

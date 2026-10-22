#+build windows
package media

// The platform backend: what the player asks for, answered by Media Foundation and WASAPI. Another platform provides the same
// five procedures (backend_<os>.odin) with its own decoders and audio output.

backend_name :: proc() -> string { return "Media Foundation" }

backend_video_decoder :: proc(t: Track, prefer_gpu: bool) -> ^Video_Decoder {
	return mf_video_create(t, prefer_gpu)
}

backend_audio_decoder :: proc(t: Track) -> ^Audio_Decoder {
	return mf_audio_create(t)
}

backend_audio_output :: proc(rate: int) -> ^Audio_Output {
	return audio_open(rate)
}

backend_video_support :: proc(c: Codec) -> Decoder_Support {
	return mf_video_supported(c)
}

backend_audio_support :: proc(c: Codec) -> Decoder_Support {
	return mf_audio_supported(c)
}

// Threads that drive decoders start with the platform's component runtime initialized.
com_thread_init_any :: proc() { com_thread_init() }

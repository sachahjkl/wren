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

// The default device, or, on a machine that has none (a server, a CI runner), an output that lets the audio go by in silence at the
// pace of the clock: the video still plays, as in the browsers.
backend_audio_output :: proc(rate: int) -> ^Audio_Output {
	if o := audio_open(rate); o != nil { return o }
	return null_audio_open(rate)
}

backend_video_support :: proc(c: Codec) -> Decoder_Support {
	return mf_video_supported(c)
}

backend_audio_support :: proc(c: Codec) -> Decoder_Support {
	return mf_audio_supported(c)
}

// Threads that drive decoders start with the platform's component runtime initialized.
com_thread_init_any :: proc() { com_thread_init() }

// media.audio.backend selects an alternative audio output on systems without a native one (Linux); on Windows WASAPI
// is always the output, so the preference does nothing here.
apply_audio_backend_pref :: proc(name: string) {}

// media.h264.* select the H.264 decoder on systems without a native one (Linux: VA-API / openh264); on Windows Media
// Foundation (DXVA) is always used, so the preferences do nothing here.
apply_h264_prefs :: proc(backend: string, openh264_path: string) {}

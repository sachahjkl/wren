package media

// The platform backend on Linux: the built-in decoders of native/media. Video: AV1 by rav1d (av1_soft.odin) and H.264
// by openh264 / VA-API (h264_linux.odin). Audio: Symphonia and libopus (audio_decode_rust.odin), played through cpal
// (audio_out_cpal.odin), or the null output when there is no device or the preference asks for silence. Other codecs
// answer "not supported" (canPlayType says "", a source falls to its next one or fails as an unsupported format).

import "core:sync"

// Which audio output to use (media.audio.backend). Read when an output is opened.
@(private)
Audio_Backend :: enum u8 { Cpal, Null }

@(private)
audio_backend: Audio_Backend

set_audio_backend :: proc(b: Audio_Backend) { sync.atomic_store((^u8)(&audio_backend), u8(b)) }

// Applies the media.audio.backend preference (settings_from_prefs; neutral name, a no-op on Windows).
apply_audio_backend_pref :: proc(name: string) {
	set_audio_backend(name == "null" ? .Null : .Cpal)
}

backend_name :: proc() -> string { return "built-in" }

backend_video_decoder :: proc(t: Track, prefer_gpu: bool) -> ^Video_Decoder {
	#partial switch t.codec {
	case .AV1:  return av1_soft_create(t)
	case .H264: return h264_create(t, prefer_gpu)
	}
	return nil
}

backend_audio_decoder :: proc(t: Track) -> ^Audio_Decoder { return rust_audio_create(t) }

backend_audio_output :: proc(rate: int) -> ^Audio_Output {
	if Audio_Backend(sync.atomic_load((^u8)(&audio_backend))) == .Cpal {
		if o := cpal_audio_open(rate); o != nil { return o }
	}
	// No device, cpal failed to open, or the preference asks for silence: let audio go by at the pace of the clock.
	return null_audio_open(rate)
}

backend_video_support :: proc(c: Codec) -> Decoder_Support {
	#partial switch c {
	case .AV1:  return av1_soft_supported()
	case .H264: return h264_supported()
	}
	return {}
}

backend_audio_support :: proc(c: Codec) -> Decoder_Support { return rust_audio_supported(c) }

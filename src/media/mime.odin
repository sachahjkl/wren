package media

// MIME types with a `codecs` parameter (RFC 6381) against what the containers and decoders here can do: what
// canPlayType, MediaSource.isTypeSupported and the media capabilities API answer.

import "core:strings"

Container :: enum u8 { None, MP4, WebM, Audio_Only_MP3, Ogg, Wav, Flac }

Support :: enum u8 { No, Maybe, Probably }

Parsed_Type :: struct {
	container: Container,
	video:     bool,          // the type names video (video/*)
	codecs:    [dynamic]Codec,
	unknown_codec: bool,      // a codec string we do not know
	codec_strings: [dynamic]string,
}

parsed_type_destroy :: proc(t: ^Parsed_Type) {
	delete(t.codecs)
	for s in t.codec_strings { delete(s) }
	delete(t.codec_strings)
	t^ = {}
}

// "video/mp4; codecs=\"avc1.64001f, mp4a.40.2\"" -> container and codecs. false: not a MIME type.
parse_type :: proc(s: string) -> (t: Parsed_Type, ok: bool) {
	semi := strings.index_byte(s, ';')
	essence := strings.trim_space(semi < 0 ? s : s[:semi])
	slash := strings.index_byte(essence, '/')
	if slash <= 0 || slash == len(essence) - 1 { return {}, false }
	main := strings.to_lower(essence[:slash], context.temp_allocator)
	sub := strings.to_lower(essence[slash + 1:], context.temp_allocator)
	t.video = main == "video"
	switch main {
	case "video", "audio":
		switch sub {
		case "mp4", "x-m4a", "m4a", "x-m4v", "m4v": t.container = .MP4
		case "webm": t.container = .WebM
		case "mpeg", "mp3": t.container = .Audio_Only_MP3
		case "ogg": t.container = .Ogg
		case "wav", "x-wav", "wave": t.container = .Wav
		case "flac", "x-flac": t.container = .Flac
		}
	case "application":
		if sub == "ogg" { t.container = .Ogg }
	}
	if semi >= 0 {
		rest := s[semi + 1:]
		for len(rest) > 0 {
			end := 0
			in_quote := false
			for end < len(rest) {
				if rest[end] == '"' { in_quote = !in_quote }
				if rest[end] == ';' && !in_quote { break }
				end += 1
			}
			param := strings.trim_space(rest[:end])
			rest = end < len(rest) ? rest[end + 1:] : ""
			eq := strings.index_byte(param, '=')
			if eq <= 0 { continue }
			name := strings.to_lower(strings.trim_space(param[:eq]), context.temp_allocator)
			value := strings.trim_space(param[eq + 1:])
			if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' { value = value[1:len(value) - 1] }
			if name != "codecs" { continue }
			for part in strings.split(value, ",", context.temp_allocator) {
				c := strings.trim_space(part)
				if c == "" { continue }
				append(&t.codec_strings, strings.clone(c))
				codec := codec_of_string(c)
				if codec == .None { t.unknown_codec = true } else { append(&t.codecs, codec) }
			}
		}
	}
	return t, true
}

// The codec an RFC 6381 string names.
codec_of_string :: proc(c: string) -> Codec {
	lc := strings.to_lower(c, context.temp_allocator)
	has :: proc(s, prefix: string) -> bool { return strings.has_prefix(s, prefix) }
	switch {
	case has(lc, "avc1.") || has(lc, "avc3.") || lc == "avc1" || lc == "avc3": return .H264
	case has(lc, "hvc1") || has(lc, "hev1"): return .HEVC
	case has(lc, "vp09") || lc == "vp9": return .VP9
	case has(lc, "vp08") || lc == "vp8": return .VP8
	case has(lc, "av01") || lc == "av1": return .AV1
	case lc == "mp4a.40.2" || lc == "mp4a.40.02" || lc == "mp4a.40.5" || lc == "mp4a.40.05" || lc == "mp4a.40.29" || lc == "mp4a.40.1" || lc == "mp4a.40.17" || lc == "mp4a.40.42" || lc == "mp4a.67": return .AAC
	case lc == "mp4a.69" || lc == "mp4a.6b" || lc == "mp3": return .MP3
	case lc == "opus": return .Opus
	case lc == "vorbis": return .Vorbis
	case lc == "flac": return .FLAC
	case lc == "ac-3" || lc == "mp4a.a5": return .AC3
	case lc == "ec-3" || lc == "mp4a.a6": return .EAC3
	}
	return .None
}

// Whether a codec can be decoded here, for a stream of the given container.
codec_supported :: proc(c: Codec, s: Settings) -> bool {
	switch c {
	case .None, .VP8, .Vorbis, .AC3, .EAC3, .PCM: return false
	case .H264: return backend_video_support(.H264).supported
	case .HEVC: return s.hevc && backend_video_support(.HEVC).supported
	case .VP9: return s.vp9 && backend_video_support(.VP9).supported
	case .AV1: return s.av1 && backend_video_support(.AV1).supported
	case .AAC, .MP3, .Opus, .FLAC: return backend_audio_support(c).supported
	}
	return false
}

// canPlayType / isTypeSupported: Probably when the container and every codec named are supported, Maybe when the container
// is and no codec is named, No otherwise.
type_support :: proc(type: string, s: Settings) -> Support {
	if !s.enabled { return .No }
	t, ok := parse_type(type)
	if !ok { return .No }
	defer parsed_type_destroy(&t)
	switch t.container {
	case .MP4, .WebM:
	case .None, .Audio_Only_MP3, .Ogg, .Wav, .Flac: return .No   // (no demuxer for these yet)
	}
	if t.unknown_codec { return .No }
	for c in t.codecs {
		if !codec_supported(c, s) { return .No }
		// a codec in a container that cannot hold it
		if t.container == .WebM && (c == .H264 || c == .HEVC || c == .AAC || c == .MP3) { return .No }
		if t.container == .MP4 && (c == .VP8) { return .No }
	}
	if len(t.codecs) == 0 { return .Maybe }
	return .Probably
}

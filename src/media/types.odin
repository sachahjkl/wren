// Package media: audio and video playback behind abstract interfaces, for <video> / <audio> and Media Source Extensions.
//
//   container parsers   mp4.odin, webm.odin: bytes in (any split), tracks and coded samples out (Demux_Sink)
//   sample store        store.odin: the coded samples of a stream, by track, with the ranges they cover (what a
//                       SourceBuffer is, and what a progressive download fills)
//   decoders            decoder.odin: Video_Decoder / Audio_Decoder, made by a backend; the Windows one is Media
//                       Foundation (mf_*_windows.odin: DXVA decoding into Direct3D 11 textures), AV1 may fall back
//                       to the software decoder of native/media
//   audio output        audio.odin: Audio_Output (WASAPI on Windows, wasapi_windows.odin)
//   player              player.odin: threads, queues, the clock, seeking; the page's media elements drive it
//
// Nothing here knows the DOM or the page: the page layer (src/page/media_*.odin) owns elements and events, the shell
// (src/browser/video_shell.odin) paints the frames. A platform backend lives in its own files and is chosen in
// backend_*.odin, so that VA-API (Linux) and VideoToolbox (macOS) can be added beside the Windows one.
package media

import "base:runtime"

// All times are in nanoseconds: exact for every timescale of the containers (90 kHz, 44.1 kHz, 12288...) over days.
Time :: distinct i64

NS_PER_S :: i64(1_000_000_000)
TIME_NONE :: Time(min(i64))   // no time (unset)

// ticks / timescale seconds as a Time, without overflowing for large tick counts.
time_from_ticks :: proc "contextless" (ticks: i64, timescale: u32) -> Time {
	if timescale == 0 { return 0 }
	ts := i64(timescale)
	whole, rem := ticks / ts, ticks % ts
	return Time(whole * NS_PER_S + rem * NS_PER_S / ts)
}

// A Time as seconds (what script sees).
time_seconds :: proc "contextless" (t: Time) -> f64 { return f64(t) / 1e9 }

seconds_time :: proc "contextless" (s: f64) -> Time { return Time(s * 1e9) }

Codec :: enum u8 { None, H264, HEVC, VP8, VP9, AV1, AAC, Opus, Vorbis, MP3, FLAC, PCM, AC3, EAC3 }

Track_Kind :: enum u8 { Other, Video, Audio }

Matrix_Coeffs :: enum u8 { Unspecified, BT709, BT601, BT2020, SMPTE240, Identity }
Transfer :: enum u8 { Unspecified, SDR, PQ, HLG }
Color_Info :: struct {
	coeffs:    Matrix_Coeffs,
	transfer:  Transfer,
	full_range: bool,
	known:     bool,    // the stream said (else: the decoder and the frame size decide)
	primaries: u8,      // ITU-T H.273 colour primaries code (1 = BT.709, 9 = BT.2020, 12 = P3), 0 unspecified
}

// One track of a stream, as an initialization segment / header describes it.
Track :: struct {
	id:          u32,         // the container's track number
	kind:        Track_Kind,
	codec:       Codec,
	codec_string: string,     // RFC 6381 as far as the container tells ("avc1.4d401e", "mp4a.40.2", "opus", "vp09...")
	timescale:   u32,         // ticks per second of the container's times for this track
	duration:    Time,        // 0 = unknown (fragmented / live)
	// video
	width, height: int,       // coded size
	display_width, display_height: int,   // size the container asks for (0: the coded one)
	rotation:    int,         // degrees clockwise, 0 / 90 / 180 / 270
	color:       Color_Info,
	bit_depth:   int,         // 0: 8
	// audio
	channels:    int,
	sample_rate: int,
	// codec private data (owned by the track): avcC / hvcC / av1C / vpcC records, the AudioSpecificConfig of AAC, the
	// OpusHead of Opus, Vorbis' headers, the FLAC STREAMINFO
	config:      []u8,
	nal_length_size: int,     // H.264 / HEVC: bytes of the length prefix of a NAL unit in a sample
	codec_delay: Time,        // Opus: pre-skip; audio samples to drop at the start
	seek_preroll: Time,       // Opus: decode this long before a seek target
	language:    string,
	default_duration: Time,   // WebM: a frame's duration when the blocks do not say
}

track_clone :: proc(t: Track) -> Track {
	allocator := runtime.heap_allocator()
	c := t
	c.config = clone_bytes(t.config, allocator)
	c.codec_string = clone_str(t.codec_string, allocator)
	c.language = clone_str(t.language, allocator)
	return c
}

track_destroy :: proc(t: ^Track) {
	allocator := runtime.heap_allocator()
	delete(t.config, allocator)
	delete(t.codec_string, allocator)
	delete(t.language, allocator)
	t^ = {}
}

@(private)
clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(b) == 0 { return nil }
	c := make([]u8, len(b), allocator)
	copy(c, b)
	return c
}

@(private)
clone_str :: proc(s: string, allocator: runtime.Allocator) -> string {
	if len(s) == 0 { return "" }
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

Sample_Flag :: enum u8 {
	Keyframe,
	Pre_Roll,   // presented before the start of the timeline (negative time): decoded, never shown or heard
}
Sample_Flags :: bit_set[Sample_Flag; u8]

// A coded frame. `data` is the codec's payload as the container stores it (H.264: length-prefixed NAL units; AAC: raw
// access unit; Opus: one packet); the sink that receives a Sample owns it (heap allocator).
Sample :: struct {
	dts, pts:  Time,
	duration:  Time,
	flags:     Sample_Flags,
	config:    u32,      // which set of track descriptions it belongs to (a new initialization segment: a new one)
	data:      []u8,
	discard_end: Time,   // audio: drop this much at the end of the frame (WebM DiscardPadding, MP4 edit lists)
}

sample_destroy :: proc(s: ^Sample) {
	delete(s.data, runtime.heap_allocator())
	s.data = nil
}

// What a container parser reports. Callbacks run on the thread that feeds the parser.
Demux_Sink :: struct {
	user:    rawptr,
	// An initialization segment (a file's header) was parsed: the tracks it describes. The slice and everything in it are
	// valid during the call only (clone what you keep: track_clone).
	tracks:  proc(user: rawptr, tracks: []Track, duration: Time),
	// A coded frame of `track` (an index into the last tracks call). Ownership of s.data passes to the callee.
	sample:  proc(user: rawptr, track: int, s: Sample),
}

Parse_Error :: enum u8 { None, Malformed, Unsupported, Too_Large }

package page

// Preferences for WebCodecs (VideoFrame / ImageDecoder / VideoDecoder / AudioDecoder and the encoders,
// bindings_webcodecs*.odin). Memory a page's codecs may hold is charged in p.held against page.max_fetch_bytes like any
// other buffer; these bounds cap a single frame and the decode queue so a hostile page cannot exhaust memory.

import "wb:config"

Webcodecs_Settings :: struct {
	enabled:          bool,
	max_frame_bytes:  int,   // the pixels of one VideoFrame / AudioData
	max_dimension:    int,   // a VideoFrame side
	max_decode_queue: int,   // encoded chunks queued at a VideoDecoder / AudioDecoder at once (decodeQueueSize ceiling)
	allow_encoders:   bool,  // VideoEncoder / AudioEncoder (off: isConfigSupported is honest false, configure raises)
}

WEBCODECS_PREFS := [?]config.Def{
	{name = "webcodecs.enabled", kind = .Bool, default = {b = true},
		description = "WebCodecs: VideoFrame, ImageDecoder, VideoDecoder, AudioDecoder and the encoders. Off hides the interfaces."},
	{name = "webcodecs.max_frame_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 20, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Most bytes the pixels (or samples) of a single VideoFrame or AudioData may take. A frame larger than this is refused."},
	{name = "webcodecs.max_dimension", kind = .Int, default = {i = 16384}, bounded = true, min = 16, max = 65536, unit = "px",
		description = "The largest width or height of a VideoFrame."},
	{name = "webcodecs.max_decode_queue", kind = .Int, default = {i = 256}, bounded = true, min = 1, max = 100000,
		description = "Most encoded chunks a VideoDecoder or AudioDecoder may have queued (decodeQueueSize) before decode() is refused."},
	{name = "webcodecs.allow_encoders", kind = .Bool, default = {b = true},
		description = "VideoEncoder and AudioEncoder. Off makes isConfigSupported report false and configure raise NotSupportedError for every codec."},
}

webcodecs_settings_from_prefs :: proc(p: ^config.Prefs) -> Webcodecs_Settings {
	return Webcodecs_Settings{
		enabled          = config.bool_of(p, "webcodecs.enabled"),
		max_frame_bytes  = int(config.int_of(p, "webcodecs.max_frame_bytes")),
		max_dimension    = int(config.int_of(p, "webcodecs.max_dimension")),
		max_decode_queue = int(config.int_of(p, "webcodecs.max_decode_queue")),
		allow_encoders   = config.bool_of(p, "webcodecs.allow_encoders"),
	}
}

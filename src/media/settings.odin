package media

// Preferences of media playback (about:config, media.*). The page layer keeps a Settings in its page Settings; the
// player reads its part when it is made.

import "wb:config"

Autoplay_Policy :: enum u8 { Allow_Muted, Allow_All, Block }

Settings :: struct {
	enabled:         bool,
	player:          Player_Settings,
	autoplay:        Autoplay_Policy,
	progressive_max: int,      // bytes of a file played without Media Source Extensions
	enough_ahead:    Time,     // buffered ahead for HAVE_ENOUGH_DATA
	future_ahead:    Time,     // buffered ahead for HAVE_FUTURE_DATA
	gap_tolerance:   Time,     // buffered ranges closer than this are one (a few frames)
	timeupdate_ms:   f64,
	progress_ms:     f64,
	mse_enabled:     bool,
	mse_video_bytes: int,      // per SourceBuffer, before eviction
	mse_audio_bytes: int,
	mse_ahead:       Time,     // what eviction keeps in front of the playback position
	mse_behind:      Time,     // and behind
	mse_max_buffers: int,      // SourceBuffer objects per MediaSource
	hevc:            bool,     // offer HEVC where the system decodes it
	vp9:             bool,
	av1:             bool,
	controls:        bool,     // draw the built-in controls of <video controls>
	controls_hide_ms: f64,
}

MEDIA_PREFS := [?]config.Def{
	{name = "media.enabled", kind = .Bool, default = {b = true},
		description = "Play <video> and <audio>. Off: media elements behave as ones with no supported source."},
	{name = "media.hardware_decoding", kind = .Bool, default = {b = true},
		description = "Decode video on the GPU where the system's decoder can (DXVA through Direct3D 11): pictures stay in video memory and are drawn from there. Off: decode in software, pictures pass through the CPU."},
	{name = "media.autoplay.policy", kind = .String, default = {s = "allow-muted"}, choices = {"allow-muted", "allow-all", "block"},
		description = "When a page may start media on its own (autoplay, play() without a click): allow-muted lets muted media start, and sound once the page had a click or key press; allow-all lets everything; block needs a user gesture for any."},
	{name = "media.progressive.max_mb", kind = .Int, default = {i = 1024}, bounded = true, min = 1, max = 1 << 20, unit = "MB",
		description = "Largest file a <video src> / <audio src> plays that is not a Media Source (it is kept in memory as it downloads)."},
	{name = "media.ready.enough_seconds", kind = .Float, default = {f = 3}, bounded = true, min = 0.1, max = 600, unit = "s",
		description = "Media buffered ahead of the playback position for readyState HAVE_ENOUGH_DATA (canplaythrough)."},
	{name = "media.ready.future_ms", kind = .Float, default = {f = 150}, bounded = true, min = 0, max = 60000, unit = "ms",
		description = "Media buffered ahead for readyState HAVE_FUTURE_DATA (canplay): playback can start."},
	{name = "media.buffered.gap_ms", kind = .Float, default = {f = 100}, bounded = true, min = 0, max = 10000, unit = "ms",
		description = "Ranges of media this close to each other count as one in `buffered` (frame times are not exact)."},
	{name = "media.video.queue_frames", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 16, unit = "frames",
		description = "Decoded pictures kept ready for the screen. More hides a slow decode, and holds more video memory."},
	{name = "media.audio.ahead_ms", kind = .Float, default = {f = 300}, bounded = true, min = 40, max = 5000, unit = "ms",
		description = "Audio decoded ahead of the playback position."},
	{name = "media.audio.start_ms", kind = .Float, default = {f = 60}, bounded = true, min = 0, max = 2000, unit = "ms",
		description = "Audio queued before playback starts (a lower value starts sooner, a higher one rides out a slow start of the audio device)."},
	{name = "media.timeupdate_ms", kind = .Float, default = {f = 250}, bounded = true, min = 15, max = 5000, unit = "ms",
		description = "How often timeupdate fires during playback (browsers use 15 to 250 ms)."},
	{name = "media.progress_ms", kind = .Float, default = {f = 350}, bounded = true, min = 50, max = 5000, unit = "ms",
		description = "How often progress fires while a file downloads."},
	{name = "media.mse.enabled", kind = .Bool, default = {b = true},
		description = "Expose Media Source Extensions (MediaSource, SourceBuffer): adaptive streaming sites such as YouTube need them."},
	{name = "media.mse.video_buffer_mb", kind = .Int, default = {i = 150}, bounded = true, min = 8, max = 8192, unit = "MB",
		description = "Video a SourceBuffer keeps before the oldest is removed (appendBuffer raises QuotaExceededError past it when nothing can go)."},
	{name = "media.mse.audio_buffer_mb", kind = .Int, default = {i = 24}, bounded = true, min = 1, max = 1024, unit = "MB",
		description = "Audio a SourceBuffer keeps before the oldest is removed."},
	{name = "media.mse.ahead_seconds", kind = .Float, default = {f = 120}, bounded = true, min = 5, max = 7200, unit = "s",
		description = "How much media in front of the playback position an over-full SourceBuffer keeps when it makes room."},
	{name = "media.mse.behind_seconds", kind = .Float, default = {f = 20}, bounded = true, min = 0, max = 7200, unit = "s",
		description = "How much media behind the playback position an over-full SourceBuffer keeps."},
	{name = "media.mse.max_source_buffers", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 256,
		description = "SourceBuffer objects one MediaSource accepts (addSourceBuffer raises QuotaExceededError past it)."},
	{name = "media.codec.hevc", kind = .Bool, default = {b = true},
		description = "Offer HEVC (hvc1 / hev1) when the system has a decoder for it."},
	{name = "media.codec.vp9", kind = .Bool, default = {b = true},
		description = "Offer VP9 when the system has a decoder for it."},
	{name = "media.codec.av1", kind = .Bool, default = {b = true},
		description = "Offer AV1 when a decoder is available (the system's, or the software one)."},
	{name = "media.software.threads", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 64, unit = "threads",
		description = "Threads of one video decoded in software (the built-in AV1 decoder). 0: half the processors, at least one."},
	{name = "media.software.vp9_fallback", kind = .Bool, default = {b = true},
		description = "Decode VP9 in software (the built-in decoder) when the system has no VP9 decoder of its own (no Store extension). Off: VP9 then counts as unsupported and a page falls to another codec."},
	{name = "media.software.av1_fallback", kind = .Bool, default = {b = true},
		description = "Decode AV1 in software (the built-in decoder) when the system has no AV1 decoder of its own. Off: AV1 then counts as unsupported."},
	{name = "media.controls.enabled", kind = .Bool, default = {b = true},
		description = "Draw the built-in controls (play, position, volume) of <video controls> and <audio controls>."},
	{name = "media.controls.hide_ms", kind = .Float, default = {f = 2500}, bounded = true, min = 0, max = 60000, unit = "ms",
		description = "How long the controls of a playing video stay after the pointer stopped over it."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, MEDIA_PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	policy := Autoplay_Policy.Allow_Muted
	switch config.string_of(p, "media.autoplay.policy") {
	case "allow-all": policy = .Allow_All
	case "block": policy = .Block
	}
	ms :: proc(f: f64) -> Time { return Time(f * 1e6) }
	set_software_threads(int(config.int_of(p, "media.software.threads")))
	set_software_fallbacks(config.bool_of(p, "media.software.vp9_fallback"), config.bool_of(p, "media.software.av1_fallback"))
	return Settings{
		enabled = config.bool_of(p, "media.enabled"),
		player = Player_Settings{
			video_queue = int(config.int_of(p, "media.video.queue_frames")),
			audio_ahead = ms(config.float_of(p, "media.audio.ahead_ms")),
			start_audio = ms(config.float_of(p, "media.audio.start_ms")),
			prefer_gpu = config.bool_of(p, "media.hardware_decoding"),
		},
		autoplay = policy,
		progressive_max = int(config.int_of(p, "media.progressive.max_mb")) << 20,
		enough_ahead = Time(config.float_of(p, "media.ready.enough_seconds") * 1e9),
		future_ahead = ms(config.float_of(p, "media.ready.future_ms")),
		gap_tolerance = ms(config.float_of(p, "media.buffered.gap_ms")),
		timeupdate_ms = config.float_of(p, "media.timeupdate_ms"),
		progress_ms = config.float_of(p, "media.progress_ms"),
		mse_enabled = config.bool_of(p, "media.mse.enabled"),
		mse_video_bytes = int(config.int_of(p, "media.mse.video_buffer_mb")) << 20,
		mse_audio_bytes = int(config.int_of(p, "media.mse.audio_buffer_mb")) << 20,
		mse_ahead = Time(config.float_of(p, "media.mse.ahead_seconds") * 1e9),
		mse_behind = Time(config.float_of(p, "media.mse.behind_seconds") * 1e9),
		mse_max_buffers = int(config.int_of(p, "media.mse.max_source_buffers")),
		hevc = config.bool_of(p, "media.codec.hevc"),
		vp9 = config.bool_of(p, "media.codec.vp9"),
		av1 = config.bool_of(p, "media.codec.av1"),
		controls = config.bool_of(p, "media.controls.enabled"),
		controls_hide_ms = config.float_of(p, "media.controls.hide_ms"),
	}
}

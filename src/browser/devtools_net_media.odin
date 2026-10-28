package browser

// The Preview of audio and video: a minimal player with play / pause, a seek bar, the time, mute and a volume. MP4 and WebM
// are demuxed whole into the media package's stores and played by its player (the decoders and the audio clock the pages'
// <video> and <audio> use; the picture is converted to a texture as video_shell.odin does); other audio (MP3, WAV, WMA,
// AAC...) goes to the system's media control interface from a temporary file. One media is open at a time, the one of the
// chosen request; it is closed when another is chosen, the panel closes or another tab of it is shown.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:media"

// The system's media control interface (devtools_net_media_windows.odin: MCI; devtools_net_media_other.odin: a stub that
// answers "unsupported", so a format the browser's own player cannot demux simply shows a notice off Windows, rather than
// playing through MCI). Every `.System` operation goes through `mci`; its false result keeps the mode from activating.

Media_Mode :: enum u8 { None, Player, System }

Net_Media :: struct {
	mode:     Media_Mode,
	id:       u64,
	err:      string,           // owned
	seen:     bool,             // the preview was built this frame
	owner:    ^Devtools,        // the developer tools (of a window: Window_Own.devtools) whose preview it is
	// the player
	vs, as:   ^media.Track_Store,
	player:   ^media.Player,
	tex:      render.Texture,
	tex_size: [2]int,
	has_pic:  bool,
	video, audio: bool,
	w, h:     int,
	duration: f64,              // s
	volume:   f32,
	muted:    bool,
	playing:  bool,
	ended:    bool,
	// the system's
	path:     string,           // owned: the temporary file
	pos_s:    f64,
	started:  bool,
}

net_media: Net_Media

@(private = "file")
Demux_Ctx :: struct { m: ^Net_Media, kinds: [dynamic]media.Track_Kind, duration: media.Time }

net_media_active :: proc() -> bool { return net_media.mode != .None }

net_media_release :: proc() {
	m := &net_media
	app := the_app
	switch m.mode {
	case .Player:
		media.player_destroy(m.player)
		media.store_destroy(m.vs)
		media.store_destroy(m.as)
		if app != nil && m.tex != 0 { render.destroy_texture(&app.r, m.tex) }
	case .System:
		mci("close dtmedia")
		if m.path != "" { os.remove(m.path) }
	case .None:
	}
	delete(m.err); delete(m.path)
	vol, muted := m.volume, m.muted
	m^ = {}
	m.volume, m.muted = vol, muted
}

@(private = "file")
sniff_container :: proc(b: []byte) -> enum { Unknown, Mp4, Webm } {
	if len(b) >= 12 && (string(b[4:8]) == "ftyp" || string(b[4:8]) == "moov" || string(b[4:8]) == "mdat" || string(b[4:8]) == "free" || string(b[4:8]) == "styp") { return .Mp4 }
	if len(b) >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3 { return .Webm }
	return .Unknown
}

@(private = "file")
net_media_open :: proc(app: ^App, e: ^Net_Entry) {
	m := &net_media
	if m.volume == 0 && !m.muted { m.volume = 0.7 }
	m.id = e.id
	body := e.body[:]
	kind := sniff_container(body)
	if kind != .Unknown {
		video_shell_init(app)
		ctx := Demux_Ctx{m = m}
		defer delete(ctx.kinds)
		sink := media.Demux_Sink{
			user = &ctx,
			tracks = proc(user: rawptr, tracks: []media.Track, duration: media.Time) {
				c := (^Demux_Ctx)(user)
				c.duration = duration
				for t in tracks {
					append(&c.kinds, t.kind)
					switch t.kind {
					case .Video: if c.m.vs == nil { c.m.vs = media.store_create(); media.store_set_config(c.m.vs, 1, media.track_clone(t)); c.m.video = true; c.m.w, c.m.h = t.display_width > 0 ? t.display_width : t.width, t.display_height > 0 ? t.display_height : t.height }
					case .Audio: if c.m.as == nil { c.m.as = media.store_create(); media.store_set_config(c.m.as, 1, media.track_clone(t)); c.m.audio = true }
					case .Other:
					}
				}
			},
			sample = proc(user: rawptr, track: int, s: media.Sample) {
				c := (^Demux_Ctx)(user)
				if track < 0 || track >= len(c.kinds) { return }
				switch c.kinds[track] {
				case .Video: if c.m.vs != nil { media.store_append(c.m.vs, s) }
				case .Audio: if c.m.as != nil { media.store_append(c.m.as, s) }
				case .Other:
				}
			},
		}
		perr: media.Parse_Error
		if kind == .Webm {
			dm: media.Webm_Demuxer
			media.webm_init(&dm, sink)
			perr = media.webm_feed(&dm, body)
			media.webm_destroy(&dm)
		} else {
			dm: media.Mp4_Demuxer
			media.mp4_init(&dm, sink)
			perr = media.mp4_feed(&dm, body)
			media.mp4_destroy(&dm)
		}
		if (m.vs != nil || m.as != nil) && perr != .Malformed {
			m.duration = media.time_seconds(ctx.duration)
			m.player = media.player_create(m.vs, m.as, app.page_settings.media.player, nil, nil)
			media.player_set_source_ended(m.player, true)
			media.player_set_volume(m.player, m.volume, m.muted)
			m.mode = .Player
			return
		}
		media.store_destroy(m.vs); media.store_destroy(m.as)
		m.vs, m.as, m.video, m.audio = nil, nil, false, false
		m.err = strings.clone("This file could not be read (the container is damaged or has no track the decoders take).")
		return
	}
	// the system's player, from a file
	ext := ".bin"
	switch net_mime_base(e.mime) {
	case "audio/mpeg", "audio/mp3": ext = ".mp3"
	case "audio/wav", "audio/x-wav", "audio/wave": ext = ".wav"
	case "audio/ogg", "application/ogg": ext = ".ogg"
	case "audio/flac": ext = ".flac"
	case "audio/aac", "audio/mp4", "audio/x-m4a": ext = ".m4a"
	case "audio/webm": ext = ".webm"
	case "video/ogg": ext = ".ogv"
	case: if i := strings.last_index_byte(net_name_of(e.url), '.'); i >= 0 { ext = net_name_of(e.url)[i:] }
	}
	if q := strings.index_byte(ext, '?'); q >= 0 { ext = ext[:q] }
	dir := base.temp_dir(context.temp_allocator)
	path, _ := filepath.join({dir, fmt.tprintf("wren_devtools_media_%d%s", e.id, ext)}, context.allocator)
	if err := os.write_entire_file(path, body); err != nil {
		m.err = strings.clone("The media could not be written to a temporary file for the system's player.")
		delete(path)
		return
	}
	m.path = path
	if _, ok := mci(fmt.tprintf("open \"%s\" alias dtmedia", path)); !ok {
		m.err = strings.clone("The system cannot play this format (the browser's own player reads MP4 and WebM).")
		os.remove(path); delete(m.path); m.path = ""
		return
	}
	mci("set dtmedia time format milliseconds")
	if s, ok := mci("status dtmedia length"); ok { m.duration = f64(parse_int(s)) / 1000 }
	m.audio = true
	m.mode = .System
	mci(fmt.tprintf("setaudio dtmedia volume to %d", int(m.muted ? 0 : m.volume * 1000)))
}

@(private = "file")
parse_int :: proc(s: string) -> int {
	n := 0
	for c in transmute([]u8)s { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } else { break } }
	return n
}

@(private = "file")
position_s :: proc(m: ^Net_Media) -> f64 {
	switch m.mode {
	case .Player: return media.time_seconds(media.player_time(m.player))
	case .System: if s, ok := mci("status dtmedia position"); ok { return f64(parse_int(s)) / 1000 }
	case .None:
	}
	return 0
}

@(private = "file")
set_playing :: proc(m: ^Net_Media, on: bool) {
	m.playing = on
	switch m.mode {
	case .Player:
		if on { if m.ended { media.player_seek(m.player, 0); m.ended = false }; media.player_play(m.player) } else { media.player_pause(m.player) }
	case .System:
		if on {
			if m.ended { mci("seek dtmedia to start"); m.ended = false }
			mci("play dtmedia")
		} else { mci("pause dtmedia") }
	case .None:
	}
}

@(private = "file")
seek_to :: proc(m: ^Net_Media, s: f64) {
	m.ended = false
	switch m.mode {
	case .Player: media.player_seek(m.player, media.seconds_time(clamp(s, 0, max(m.duration, 0))))
	case .System:
		mci(fmt.tprintf("seek dtmedia to %d", int(clamp(s, 0, m.duration) * 1000)))
		if m.playing { mci("play dtmedia") }
	case .None:
	}
}

@(private = "file")
apply_volume :: proc(m: ^Net_Media) {
	switch m.mode {
	case .Player: media.player_set_volume(m.player, m.volume, m.muted)
	case .System: mci(fmt.tprintf("setaudio dtmedia volume to %d", int(m.muted ? 0 : m.volume * 1000)))
	case .None:
	}
}

@(private = "file")
time_text :: proc(s: f64) -> string {
	t := int(max(s, 0))
	if t >= 3600 { return fmt.tprintf("%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
	return fmt.tprintf("%d:%02d", t / 60, t % 60)
}

@(private = "file")
Slider_Draw :: struct { frac: f32, hot: bool, buffered: f32 }

@(private = "file")
slider_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Slider_Draw)(user)
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	th := dt_px(4)
	track := draw.Rect{{r.min.x + dt_px(4), cy - th * 0.5}, {r.max.x - dt_px(4), cy + th * 0.5}}
	draw.rect(dc, track, with_alpha(dtc.weak, 0.3), th * 0.5)
	fx := track.min.x + (track.max.x - track.min.x) * clamp(d.frac, 0, 1)
	draw.rect(dc, {track.min, {fx, track.max.y}}, dtc.accent, th * 0.5)
	kr := dt_px(d.hot ? 6 : 5)
	draw.rect(dc, {{fx - kr, cy - kr}, {fx + kr, cy + kr}}, dtc.accent, kr)
}

// A horizontal slider of `w` px (0: fills); returns the position (0..1) the user dragged it to, and whether they did.
@(private = "file")
slider :: proc(id: string, frac: f32, w: f32) -> (f32, bool) {
	ui.next({width = w > 0 ? ui.px(w) : ui.fill(), height = ui.pct(1), cursor = .Hand})
	b := ui.build_box({.Clickable}, id)
	sig := ui.signal(b)
	sd := ui.frame_new(Slider_Draw)
	sd.frac, sd.hot = frac, sig.hovering || sig.dragging
	b.custom, b.custom_user = slider_paint, sd
	if sig.pressed || sig.dragging {
		width := b.rect.max.x - b.rect.min.x - dt_px(8)
		if width > 0 { return clamp((sig.mouse.x - dt_px(4)) / width, 0, 1), true }
	}
	return frac, false
}

@(private = "file")
Video_Paint :: struct { has: bool, tex: render.Texture, size: [2]int, audio_only: bool, name: string }

@(private = "file")
video_stage_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := the_app
	m := &net_media
	r := b.rect
	draw.rect(dc, r, draw.Color{0.03, 0.03, 0.04, 1})
	if m.mode == .Player && m.video {
		// the picture the player shows now: converted into the target when it is new
		media.player_tick(m.player)
		f, changed := media.player_present(m.player)
		if f != nil {
			pic := picture_of(f)
			want := render.video_target_size(pic)
			if m.tex != 0 && m.tex_size != want { render.destroy_texture(&app.r, m.tex); m.tex, m.has_pic = 0, false }
			if m.tex == 0 && want.x > 0 && want.y > 0 { m.tex = render.create_video_target(&app.r, want.x, want.y); m.tex_size = want }
			if m.tex != 0 && (changed || !m.has_pic) { if render.video_convert(&app.r, m.tex, pic) { m.has_pic = true } }
		}
		if m.has_pic && m.tex != 0 {
			avail := draw.Vec2{r.max.x - r.min.x, r.max.y - r.min.y}
			ar := f32(m.tex_size.x) / max(f32(m.tex_size.y), 1)
			w, h := avail.x, avail.x / ar
			if h > avail.y { h = avail.y; w = h * ar }
			c := draw.rect_center(r)
			draw.image(dc, m.tex, {{c.x - w * 0.5, c.y - h * 0.5}, {c.x + w * 0.5, c.y + h * 0.5}}, {}, draw.Color{1, 1, 1, 1})
		}
		return
	}
	// sound only: an icon in a ring and the name
	c := draw.rect_center(r)
	rr := dt_px(30)
	draw.rect(dc, {{c.x - rr, c.y - rr - dt_px(8)}, {c.x + rr, c.y + rr - dt_px(8)}}, with_alpha(dtc.accent, 0.15), rr)
	dt_icon(dc, .File_Media, {c.x, c.y - dt_px(8)}, dt_px(30), dtc.accent, dtm.sc)
}

net_media_preview :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	m := &net_media
	if m.mode != .None && m.owner != nil && m.owner != dev() {
		// (one media at a time: another window's developer tools play theirs)
		dt_empty("###dt_pm_err", .File_Media, "Playing in another window", "The developer tools of another window are playing a media; one plays at a time.")
		return
	}
	if m.id != e.id || m.owner != dev() {
		net_media_release()
		net_media_open(app, e)
	}
	m.owner = dev()
	m.seen = true
	if m.mode == .None {
		dt_empty("###dt_pm_err", .File_Media, "No player for this media", m.err != "" ? m.err : "Press the request's address in a tab to play it.")
		return
	}
	pos := position_s(m)
	// the end, as the player or the system says it
	switch m.mode {
	case .Player:
		_, _, ended, perr := media.player_state(m.player)
		if ended && m.playing { m.playing, m.ended = false, true }
		if perr != .None && m.err == "" { m.err = strings.clone(fmt.tprintf("The decoder stopped (%v).", perr)) }
	case .System:
		if m.playing && m.duration > 0 && pos >= m.duration - 0.05 { m.playing, m.ended = false, true }
	case .None:
	}
	if m.playing { request_frames(app, 2) }
	if dt_bar("###dt_pm_bar", dtm.bar) {
		dt_gap(4)
		if dt_btn("###dt_pm_play", m.playing ? .Pause : .Play, tooltip = m.playing ? "Pause" : "Play", shortcut = "Space").clicked { set_playing(m, !m.playing) }
		ui.next({width = ui.px(dt_px(88)), height = ui.pct(1)})
		ui.custom("###dt_pm_time", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_text(dc, dtm.mono, dtm.mono_fs, b.rect.min.x + dt_px(6), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.text, (^string)(user)^)
		}, new_clone(dt_frame_str(fmt.tprintf("%s / %s", time_text(pos), time_text(m.duration))), ui.frame_allocator()))
		if f, changed := slider("###dt_pm_seek", m.duration > 0 ? f32(pos / m.duration) : 0, 0); changed && m.duration > 0 { seek_to(m, f64(f) * m.duration) }
		if dt_btn("###dt_pm_mute", m.muted || m.volume == 0 ? .Block : .Eye, tooltip = m.muted ? "Unmute" : "Mute", on = m.muted).clicked { m.muted = !m.muted; apply_volume(m) }
		if f, changed := slider("###dt_pm_vol", m.muted ? 0 : m.volume, dt_px(70)); changed { m.volume, m.muted = f, false; apply_volume(m) }
		dt_gap(6)
	}
	if m.err != "" {
		ui.next({width = ui.fill(), height = ui.px(dtm.row)})
		eb := ui.build_box({}, "###dt_pm_note")
		eb.custom, eb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(10), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.bad, (^string)(user)^, b.rect.max.x - b.rect.min.x - dt_px(14))
		}, new_clone(dt_frame_str(m.err), ui.frame_allocator())
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	stage := ui.build_box({.Clip, .Clickable}, "###dt_pm_stage")
	sig := ui.signal(stage)
	stage.custom = video_stage_paint
	if sig.clicked { set_playing(m, !m.playing) }
	if ui.key_press(.Space) && ui.focus_key() == stage.key { set_playing(m, !m.playing) }
	info := fmt.tprintf("%s%s%s, %s", m.video ? fmt.tprintf("%d \u00d7 %d video", m.w, m.h) : "", m.video && m.audio ? " + " : "", m.audio ? "audio" : "", dt_size_text(i64(len(e.body))))
	_ = info
}

// Called every frame by devtools_panel after its tabs: a media whose preview was not built is closed (the tab was changed,
// the request is no longer chosen).
net_media_frame_end :: proc() {
	if net_media.mode == .None || net_media.owner != dev() { return }   // (another window's panel builds its own frames)
	if !net_media.seen { net_media_release() }
	net_media.seen = false
}

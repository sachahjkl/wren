package browser

// The sound of a tab, as in Chrome: a speaker on the tab that plays sound (its pages' and its frames' media elements that play
// an audio track, not muted, at a volume above 0), crossed out on a tab the user muted; a click on it mutes or unmutes the tab
// (also its menu, the command `tab.mute` and `wren ctl tabs --json`: `audible`, `muted`).
//
// Muting a tab silences its players from the browser's side (media.player_set_host_muted): the page's volume and muted are
// untouched and it is not told, as in other browsers. A player made later in the tab (a new element, a new page) is silenced
// as it appears (tab_sound_frame). The speaker stays browser.tabs.audio_hold_ms after the sound stops, so a gap between two
// sounds does not make it blink; a wake shows its end when nothing else draws.

import "core:math"
import "toolkit:draw"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:i18n"
import "wb:media"
import "wb:page"

TAB_SOUND_PREFS := [?]config.Def{
	{name = "browser.tabs.audio_indicator", kind = .Bool, default = {b = true},
		description = i18n.tr("Show a speaker on a tab that plays sound (a click on it mutes the tab), and a crossed-out one on a muted tab.")},
	{name = "browser.tabs.audio_hold_ms", kind = .Int, default = {i = 2000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = i18n.tr("How long the speaker of a tab stays after its sound stops (a pause between two sounds does not make it blink).")},
}

// What a tab's sound was at the last frame.
Tab_Sound :: struct {
	playing:  bool,   // one of its media elements plays sound now
	heard_ms: f64,    // the loop clock when it last did (0: never)
}

// The tab plays sound now: a media element of its page or of one of its frames plays, with an audio track, not muted, at a
// volume above 0. (The tab's own mute does not count: a muted tab still "plays", its speaker is crossed out.)
tab_playing :: proc(t: ^Tab) -> bool {
	return t.page != nil && page_playing(t.page, 0)
}

@(private = "file")
page_playing :: proc(p: ^page.Page, depth: int) -> bool {
	if p == nil || depth > 32 { return false }
	if p.media != nil {
		for _, el in p.media.elements {
			if el.player != nil && !el.paused && !el.ended_flag && el.has_ainfo && !el.muted && el.volume > 0 { return true }
		}
	}
	if p.frames != nil {
		for n in page.frames_children(p) { if page_playing(n.page, depth + 1) { return true } }
	}
	return false
}

// The players of the tab's pages follow its mute (those that do not yet).
@(private = "file")
page_mute :: proc(p: ^page.Page, on: bool, depth: int) {
	if p == nil || depth > 32 { return }
	if p.media != nil {
		for _, el in p.media.elements {
			if el.player != nil && el.player.host_muted != on { media.player_set_host_muted(el.player, on) }   // (only this thread writes it)
		}
	}
	if p.frames != nil {
		for n in page.frames_children(p) { page_mute(n.page, on, depth + 1) }
	}
}

// Once per frame for the window's tabs: what each one plays, its mute applied to the players it has now.
tab_sound_frame :: proc(app: ^App) {
	now := f64(host.now_ns(&app.loop)) / 1e6
	hold := f64(config.int_of(&app.prefs, "browser.tabs.audio_hold_ms"))
	for t in active_window(app).tabs {
		if t.page == nil { t.sound.playing = false; continue }
		if t.muted || t.page.media != nil || t.page.frames != nil { page_mute(t.page, t.muted, 0) }
		was := tab_audible(t, now, hold)
		t.sound.playing = tab_playing(t)
		if t.sound.playing { t.sound.heard_ms = now }
		if was && !t.sound.playing && hold > 0 {
			// the speaker goes when the hold is over: a frame then
			_ = host.set_timer(&app.loop, max(hold - (now - t.sound.heard_ms), 1) + 1, 0, proc(data: rawptr) { request_frames((^App)(data), 1) }, app)
		}
	}
}

// The speaker shows: the tab plays, or did less than `hold` ms ago.
tab_audible :: proc(t: ^Tab, now, hold: f64) -> bool {
	return t.sound.playing || (t.sound.heard_ms > 0 && now - t.sound.heard_ms < hold)
}

// What the tab's speaker shows now (none, sound, muted), for the tab bar and the remote.
Tab_Speaker :: enum u8 { None, Sound, Muted }

tab_speaker :: proc(app: ^App, t: ^Tab) -> Tab_Speaker {
	if !config.bool_of(&app.prefs, "browser.tabs.audio_indicator") { return .None }
	if t.muted { return .Muted }
	if tab_audible(t, f64(host.now_ns(&app.loop)) / 1e6, f64(config.int_of(&app.prefs, "browser.tabs.audio_hold_ms"))) { return .Sound }
	return .None
}

tab_set_muted :: proc(app: ^App, t: ^Tab, on: bool) {
	if t.muted == on { return }
	t.muted = on
	if t.page != nil { page_mute(t.page, on, 0) }
	if w, _ := window_of_tab(app, t); w != nil { window_request(app, w, 2) }
}

// The speaker as a button `size` square (the tab bar's rows): a click mutes or unmutes the tab. Returns true when clicked.
tab_speaker_button :: proc(app: ^App, t: ^Tab, s: Tab_Speaker, size: f32, id: string) -> bool {
	ui.next({width = ui.px(size), height = ui.px(size), radius = size * 0.5})
	b: ^ui.Box
	if ui.tags("icon_button") {
		b = ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, id)
		d := ui.frame_new(Speaker_Draw)
		d^ = {color = ui.color("text"), muted = s == .Muted}
		b.custom, b.custom_user = speaker_draw, d
	}
	ui.a11y_set(b, {name = s == .Muted ? i18n.tr("Unmute tab") : i18n.tr("Mute tab")})
	sig := ui.signal(b)
	tip(sig, s == .Muted ? i18n.tr("Unmute tab") : i18n.tr("Mute tab"))
	if sig.clicked { tab_set_muted(app, t, !t.muted); return true }
	return false
}

// The speaker as a badge over the corner of an icon (a pinned tab, the narrow sidebar): drawn, not clicked.
tab_speaker_badge :: proc(s: Tab_Speaker, at: [2]f32, size: f32, id: string) {
	if s == .None { return }
	d := ui.frame_new(Speaker_Draw)
	d^ = {color = ui.color("text"), muted = s == .Muted, badge = true, back = ui.color("background")}
	ui.next({fixed_x = at.x, fixed_y = at.y, width = ui.px(size), height = ui.px(size)})
	ui.custom(id, speaker_draw, d)
}

Speaker_Draw :: struct {
	color, back: draw.Color,
	muted:       bool,
	badge:       bool,   // small, at the bottom right of the box, on a disc of the background
}

// A speaker: its body and cone, then two arcs (sound) or a cross (muted).
speaker_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Speaker_Draw)(user)
	r := b.rect
	s := min(r.max.x - r.min.x, r.max.y - r.min.y) * 0.62
	c := draw.rect_center(r)
	if d.badge {
		s = (r.max.x - r.min.x) * 0.7
		c = {r.max.x - s * 0.5, r.max.y - s * 0.5}
		draw.rect(dc, {c - s * 0.62, c + s * 0.62}, d.back, s * 0.62)
		s *= 0.9
	}
	o := c - s * 0.5
	col := d.color
	// body
	draw.rect(dc, {{o.x, o.y + s * 0.34}, {o.x + s * 0.22, o.y + s * 0.66}}, col)
	// cone (a trapezoid: a rectangle clipped to it)
	cone := [4]draw.Vec2{{o.x + s * 0.2, o.y + s * 0.34}, {o.x + s * 0.5, o.y + s * 0.08}, {o.x + s * 0.5, o.y + s * 0.92}, {o.x + s * 0.2, o.y + s * 0.66}}
	draw.push_clip_polygon(dc, cone[:])
	draw.rect(dc, {{o.x + s * 0.2, o.y}, {o.x + s * 0.5, o.y + s}}, col)
	draw.pop_clip(dc)
	th := max(math.round(s * 0.09), 1)
	if d.muted {
		m := draw.Vec2{o.x + s * 0.8, c.y}
		arm := s * 0.16
		for angle in ([2]f32{math.PI / 4, -math.PI / 4}) {
			draw.push_transform(dc, draw.affine_around(draw.affine_rotate(angle), m))
			draw.rect(dc, {{m.x - arm, m.y - th * 0.5}, {m.x + arm, m.y + th * 0.5}}, col, th * 0.5)
			draw.pop_transform(dc)
		}
		return
	}
	// the waves: rings clipped to their right half
	draw.push_clip(dc, {{o.x + s * 0.56, o.y}, {o.x + s * 1.2, o.y + s}})
	for k in 0 ..< 2 {
		rad := s * (0.2 + 0.18 * f32(k))
		cc := draw.Vec2{o.x + s * 0.5, c.y}
		draw.rect(dc, {cc - rad, cc + rad}, col, rad, th)
	}
	draw.pop_clip(dc)
}

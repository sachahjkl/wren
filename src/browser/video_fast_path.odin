package browser

// 1.14 — the video fast path (browser.video.fast_path).
//
// A video is painted inside the page's paint pass (video_shell.odin, video_paint_content). When a long script holds the
// interface thread, the whole page — the video with it — freezes: the chrome keeps drawing (shell_frames.odin), but the
// page area shows the page's last captured frame (Page_Snapshot), a still image. YouTube runs a ~85 ms task every 5 s,
// so a playing video visibly stutters while the rest of the window stays live.
//
// The fast path keeps the video moving without running any script or re-laying-out the page: during a chrome frame,
// right after the page's last frame is drawn, the video's *newest* decoded picture (its decode threads are still alive
// and player_present is thread-safe) is drawn over the page's last frame at the video's box. The page's last frame is
// the "below + above" layers already composited with the old picture; overlaying the fresh picture at the same place
// recomposes the visible result with only the video changed — the smallest correct change.
//
// It runs only for a video that filled its box opaquely with nothing drawn over it (recorded as `eligible` at paint
// time), so the overlay cannot show a pixel the normal path would not have: if the clip moved or something covers the
// video, the picture is left frozen rather than risk a wrong frame (a freeze beats a lie). The box is remembered in the
// snapshot's own coordinates and shifted exactly as shell_paint_page shifts the snapshot, so asynchronous scrolling of
// a busy page keeps the video in place.
//
// Candidate for the toolkit: the general shape — a cache of composited layers with recomposition of one changed
// sublayer over the rest — is reusable by any app with a surface that must stay fluid during a long computation. The
// glue here (the video player, the page snapshot, the chrome-frame loop) is Wren's; the reusable primitive would be a
// render/layers helper. Left in the browser for now (noted in the report).

import "core:fmt"
import "toolkit:draw"
import "toolkit:render"
import "wb:base"
import "wb:config"
import "wb:page"

Video_Fast_Mode :: enum u8 { Auto, Off, Verify }

@(private = "file")
Video_Fast_Record :: struct {
	tab:      u64,          // the tab whose page this video is in
	page:     u64,
	node:     base.Handle,
	tex:      render.Texture,
	dst:      draw.Rect,    // the video's rectangle in screen pixels, as painted this frame
	page_rect: draw.Rect,   // the page area when it was recorded (to shift like the snapshot)
	scroll:   f32,
	frame:    u64,          // chrome_frames.frame_no it was recorded in (a record older than the snapshot is dropped)
	eligible: bool,
}

@(private = "file")
Video_Fast :: struct {
	mode:    Video_Fast_Mode,
	watch:   int,
	records: [dynamic]Video_Fast_Record,
	overlaid: u64,          // statistics: pictures drawn by the fast path
}

@(private = "file")
vfast: Video_Fast

video_fast_path_init :: proc(app: ^App) {
	vfast.mode = video_fast_mode(&app.prefs)
	vfast.watch = config.watch(&app.prefs, "browser.video.fast_path", proc(user: rawptr, name: string, p: ^config.Prefs) {
		vfast.mode = video_fast_mode(p)
	}, app)
}

video_fast_path_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, vfast.watch)
	delete(vfast.records)
	vfast = {}
}

@(private = "file")
video_fast_mode :: proc(p: ^config.Prefs) -> Video_Fast_Mode {
	switch config.string_of(p, "browser.video.fast_path") {
	case "off": return .Off
	case "verify": return .Verify
	}
	return .Auto
}

// At the start of a full (non-chrome) frame: the records of the previous frame are stale.
video_fast_path_begin_frame :: proc(app: ^App) {
	if chrome_frames.nested { return }   // a chrome frame reads the records; it does not clear them
	clear(&vfast.records)
}

// Called from video_paint_content for each video painted in the real page pass: remembers its picture and box so a
// chrome frame can keep it moving.
video_fast_path_record :: proc(app: ^App, p: ^page.Page, node: base.Handle, tex: render.Texture, dst: draw.Rect, eligible: bool) {
	if vfast.mode == .Off || chrome_frames.nested { return }
	t := current_tab(app)
	if t == nil || t.page != p { return }
	wnd := active_window(app)
	append(&vfast.records, Video_Fast_Record{
		tab = t.id, page = page.page_id(p), node = node, tex = tex, dst = dst,
		page_rect = wnd.page_rect, scroll = t.scroll, frame = chrome_frames.frame_no, eligible = eligible,
	})
}

// During a chrome frame, after shell_paint_page drew the tab's last frame in `rect`: draw each eligible video's newest
// picture over it, shifted the same way the snapshot was, so the video keeps playing while the page is frozen. Returns
// how many were drawn.
video_fast_path_overlay :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect) -> int {
	if vfast.mode == .Off { return 0 }
	s := shell_snapshot_of(t.id)
	if s == nil { return 0 }   // no page frame to overlay onto
	drawn := 0
	// the snapshot's shift this chrome frame (same as shell_paint_page): the page area moved and the wheel scrolled it
	scroll := t.scroll + (chrome_frames.pending_tab == t.id ? chrome_frames.pending_scroll : 0)
	for &r in vfast.records {
		if r.tab != t.id || !r.eligible || r.tex == 0 { continue }
		// the newest picture the player has now (its decode threads kept running under the script)
		tex, size, ok := video_fast_live_texture(app, r.page, r.node)
		if !ok || tex == 0 { tex = r.tex }   // nothing newer: the last one, still moving the box with the snapshot
		_ = size
		shift := (rect.min - r.page_rect.min) - draw.Vec2{0, scroll - r.scroll}
		dst := draw.Rect{r.dst.min + shift, r.dst.max + shift}
		covered := draw.rect_intersect(rect, dst)
		if covered.max.x <= covered.min.x || covered.max.y <= covered.min.y { continue }
		draw.push_clip(dc, rect)
		draw.image(dc, tex, dst, {}, draw.Color{1, 1, 1, 1})
		draw.pop_clip(dc)
		drawn += 1
		vfast.overlaid += 1
		if vfast.mode == .Verify { video_fast_verify(app, &r, dst) }
	}
	return drawn
}

// verify mode: a diagnostic that the lead can turn on to confirm the fast path matches the normal one. It cannot run
// the normal path here (that needs the page, which is busy), so it reports the box it recomposed and the picture it
// used; the lead compares the result on screen. A full pixel diff would capture the next real frame and compare the
// overlaid region — left as a hook the lead can extend once the feature is validated.
@(private = "file")
video_fast_verify :: proc(app: ^App, r: ^Video_Fast_Record, dst: draw.Rect) {
	// one line per recomposition, rate-limited to the start of a freeze so the console is not flooded
	if chrome_frames.frames % 60 != 0 { return }
	fmt.printf("[video.fast_path verify] recomposed video node %v over the page's last frame at %.0f,%.0f %.0fx%.0f (fast path active; compare with browser.video.fast_path=off)\n",
		r.node, dst.min.x, dst.min.y, dst.max.x - dst.min.x, dst.max.y - dst.min.y)
}

// The live texture of a video right now (its newest picture converted), without running the page: the same path the
// real paint uses, safe from the chrome-frame thread because the player is thread-safe and the converter only touches
// the GPU. nil when there is nothing new to show.
@(private = "file")
video_fast_live_texture :: proc(app: ^App, page_id: u64, node: base.Handle) -> (tex: render.Texture, size: [2]int, ok: bool) {
	p := page.page_by_id(page_id)
	if p == nil { return }
	return video_texture_for_canvas(app, p, node)
}

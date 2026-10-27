package page

// HTMLVideoElement.requestVideoFrameCallback / cancelVideoFrameCallback (api/media_element.widl, the rVFC specification).
//
// A callback registered on a <video> runs once, the next time a new decoded picture is actually presented on screen —
// the same moment getVideoPlaybackQuality's counters advance (media_view bumps paint_gen and calls media_rvfc_present).
// This is the native hook into the real presentation path, not a timer poll: a callback fires in step with the frames
// the shell draws.
//
// The callback is handed `now` (the page's performance timeline) and reads the rest of its VideoFrameCallbackMetadata
// back through HTMLVideoElement_videoFrameMetadata, which the engine (native/js/runtime/web_mediaobjects.c) turns into
// the dictionary. The metadata is snapshotted at presentation into the element, keyed by the callback id, so a callback
// that reads it synchronously sees the frame it fired for even though several may fire in the same turn.

import "wb:media"

Rvfc_Callback :: struct {
	id:       u64,
	instance: u32,   // the realm that registered it (its index in the page)
	callback: u32,   // the guest function table index
	user:     i32,
}

// The seven numbers of VideoFrameCallbackMetadata, plus a mask of which optional fields are present (always 0 for now:
// captureTime / receiveTime / rtpTimestamp are never defined — Wren is not a WebRTC endpoint).
Rvfc_Metadata :: struct {
	presentation_time:    f64,   // DOMHighResTimeStamp when the frame was sent for composition
	expected_display_time: f64,  // when it is expected to be visible (now + the screen-ahead)
	width:    f64,
	height:   f64,
	media_time: f64,             // the frame's media timestamp, seconds
	presented_frames: f64,       // getVideoPlaybackQuality totalVideoFrames-style count of presented pictures
	processing_duration: f64,    // not measured: 0
	present_mask: f64,           // bit 0 captureTime, 1 receiveTime, 2 rtpTimestamp (all absent)
}

HTMLVideoElement_requestVideoFrameCallback :: proc(c: ^Call, e: Api_HTMLMediaElement, callback: u32, user: i32) -> u64 {
	el := e.data
	if el == nil || !el.is_video { return 0 }
	if len(el.rvfc) >= el.page.settings.media.max_video_frame_callbacks { return 0 }
	el.rvfc_next_id += 1
	append(&el.rvfc, Rvfc_Callback{id = el.rvfc_next_id, instance = c.owner, callback = callback, user = user})
	// a registered callback wants the shell to keep drawing this video even if nothing else changed: the player's own
	// present path drives it, but the element is kept busy so a headless embedder does not settle too early
	el.viewed_ms = page_now_ms(el.page)
	return el.rvfc_next_id
}

HTMLVideoElement_cancelVideoFrameCallback :: proc(c: ^Call, e: Api_HTMLMediaElement, id: u64) {
	el := e.data
	if el == nil { return }
	for cb, i in el.rvfc {
		if cb.id == id { ordered_remove(&el.rvfc, i); return }
	}
}

// The metadata of the callback currently running (the engine asks for it from inside the callback). Empty bytes when
// the id is not the one being dispatched.
HTMLVideoElement_videoFrameMetadata :: proc(c: ^Call, e: Api_HTMLMediaElement, id: u64) -> []u8 {
	el := e.data
	if el == nil || el.rvfc_meta_id == 0 || el.rvfc_meta_id != id { return nil }
	q := el.rvfc_meta
	out := make([]u8, size_of(q), context.temp_allocator)
	(^Rvfc_Metadata)(raw_data(out))^ = q
	return out
}

// A new picture is on screen (media_view): fire every waiting callback, in order, with the frame's metadata. Each one
// runs as its own guest call (so a microtask checkpoint follows); callbacks registered from inside one wait for the
// next frame, exactly like requestAnimationFrame.
@(private)
media_rvfc_present :: proc(el: ^Media_Element, frame: ^media.Video_Frame, stats: media.Player_Stats, ahead_ns: i64) {
	p := el.page
	if p.closed || len(el.rvfc) == 0 { return }
	now := page_now_ms(p)
	meta := Rvfc_Metadata{
		presentation_time     = now,
		expected_display_time = now + f64(ahead_ns) / 1e6,
		width                 = f64(frame.width),
		height                = f64(frame.height),
		media_time            = media.time_seconds(frame.pts),
		presented_frames      = f64(stats.presented),
		processing_duration   = 0,
		present_mask          = 0,
	}
	// the frame's visible size follows the element's rotation, as videoWidth/videoHeight do
	if frame.rotation == 90 || frame.rotation == 270 { meta.width, meta.height = meta.height, meta.width }
	batch := el.rvfc
	el.rvfc = make([dynamic]Rvfc_Callback)
	el.rvfc_meta = meta
	defer el.rvfc_meta_id = 0
	for cb in batch {
		if p.closed { break }
		inst := instance_by_index(p, cb.instance)
		if inst == nil { continue }
		el.rvfc_meta_id = cb.id
		bits := transmute(u64)now
		argv := [3]u32{u32(cb.user), u32(bits), u32(bits >> 32)}   // (user: i32, now: f64)
		call_guest(p, inst, cb.callback, argv[:])
	}
	delete(batch)
}

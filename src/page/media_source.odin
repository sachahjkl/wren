package page

// Media Source Extensions (api/media_source.widl): MediaSource, SourceBuffer and SourceBufferList as host objects.
//
// A MediaSource is attached to a media element by its object URL (URL.createObjectURL registers it here, the element's
// src names it). Each SourceBuffer has a container parser (src/media mp4.odin / webm.odin) and one Track_Store per track
// kind; what a script appends is parsed into coded frames and stored with the timestamp offset and append window applied,
// replacing what they overlap. The element's player decodes from those stores exactly as from a download.
//
// State machines follow the specification: readyState closed / open / ended; updating, with updatestart / update /
// updateend (or error, abort) fired from tasks; the initialization segment received flags that let the element reach
// HAVE_METADATA once every source buffer has had one; end of stream; the coded frame removal and eviction when a
// buffer is full. Limits are preferences: media.mse.*.
//
// Lifetime: the script engine releases a MediaSource with its wrapper, but a source that is attached keeps playing
// (specification: the media element holds it). Its data then outlives the object handle ("orphan") and goes with the
// element's detach. SourceBuffers are released with their MediaSource; one that was removed keeps a husk (its parser and
// stores are gone) so that a script still holding it gets InvalidStateError.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:media"

MS_State :: enum u8 { Closed, Open, Ended }
Append_Mode :: enum u8 { Segments, Sequence }

Media_Source_Object :: struct {
	page:      ^Page,
	self:      u64,
	owner:     u32,
	state:     MS_State,
	duration:  f64,
	buffers:   [dynamic]^Source_Buffer_Object,
	dead:      [dynamic]^Source_Buffer_Object,   // removed from the source, kept until it goes
	list_all, list_active: u64,
	el_node:   base.Handle,        // the element it is attached to (NIL: none)
	el_serial: u64,
	url:       string,
	live:      [2]f64,
	has_live:  bool,
	orphan:    bool,               // its handle was released while attached: freed when the element lets go
	// a dedicated worker's MediaSource (mse_worker.odin): the worker's object mirrors the one the element plays in
	// the page (`remote_ui`); both are tied by the channel
	remote:    ^Mse_Channel,
	remote_ui: bool,
	handle_obj: u64,               // the worker's: its MediaSourceHandle (0: not asked yet)
	next_rid:  u32,                // the worker's: the next source buffer's id
	seq:       u32,                // the worker's: commands sent; the page's: commands done
	// ManagedMediaSource (media_managed.odin): the user agent says when to stream
	managed:   bool,
	streaming: bool,               // the current streaming flag (startstreaming / endstreaming when it flips)
}

// What an element holds of its Media Source.
Media_Source_Link :: struct { ms: ^Media_Source_Object }

Source_Buffer_List_Object :: struct {
	ms:     ^Media_Source_Object,
	active: bool,
}

Sb_Op_Kind :: enum u8 { None, Append, Remove }

Source_Buffer_Object :: struct {
	page:      ^Page,
	self:      u64,
	ms:        ^Media_Source_Object,   // nil once removed
	mime:      string,
	mode:      Append_Mode,
	updating:  bool,
	ts_offset: f64,
	win_start, win_end: f64,
	mp4:       ^media.Mp4_Demuxer,
	webm:      ^media.Webm_Demuxer,
	is_webm:   bool,
	want_video, want_audio: bool,   // the kinds of track its type names (the others in a muxed file are ignored)
	vstore, astore: ^media.Track_Store,
	vtrack, atrack: int,
	vinfo, ainfo: media.Track,
	has_vinfo, has_ainfo: bool,
	config_base: u32,               // the parsers number their initialization segments from 1; a new parser continues after the old
	cfg_count:   u32,               // initialization segments the current parser reported
	init_received: bool,
	op:        Sb_Op_Kind,
	op_data:   []byte,              // heap
	op_range:  [2]f64,
	op_gen:    u32,                 // bumps when an operation is aborted: its task does nothing
	group_end: f64,                 // sequence mode: where the next group of frames starts
	seq_first: bool,
	parse_error: bool,
	init_duration: f64,
	rid:       u32,                 // a worker's MediaSource: the id both sides know the buffer by
	ranges:    [dynamic][2]f64,     // the worker's mirror of what the page's buffer holds (buffered)
	// ManagedSourceBuffer (media_managed.odin): the ranges last reported, to diff for bufferedchange
	managed:   bool,
	last_ranges: [dynamic][2]f64,
}

media_source_vt := Object_VTable{
	name = "MediaSource",
	destroy = proc(p: ^Page, data: rawptr) {
		ms := (^Media_Source_Object)(data)
		if p.media != nil && ms.url != "" { delete_key(&p.media.urls, ms.url) }
		// attached and playing: it stays until the element lets go
		if !p.closed && ms_element(ms) != nil {
			ms.orphan = true
			ms.self = 0
			return
		}
		ms_free(ms, !p.closed)
	},
}

source_buffer_vt := Object_VTable{
	name = "SourceBuffer",
	destroy = proc(p: ^Page, data: rawptr) {
		sb := (^Source_Buffer_Object)(data)
		sb_free_resources(sb)
		delete(sb.op_data)
		delete(sb.mime)
		delete(sb.ranges)
		delete(sb.last_ranges)
		free(sb)
	},
}

source_buffer_list_vt := Object_VTable{
	name = "SourceBufferList",
	destroy = proc(p: ^Page, data: rawptr) { free((^Source_Buffer_List_Object)(data)) },
}

lookup_MediaSource :: proc(c: ^Call, h: u64) -> ^Media_Source_Object { return (^Media_Source_Object)(object_data(c.page, h, &media_source_vt)) }
lookup_SourceBuffer :: proc(c: ^Call, h: u64) -> ^Source_Buffer_Object { return (^Source_Buffer_Object)(object_data(c.page, h, &source_buffer_vt)) }
lookup_SourceBufferList :: proc(c: ^Call, h: u64) -> ^Source_Buffer_List_Object { return (^Source_Buffer_List_Object)(object_data(c.page, h, &source_buffer_list_vt)) }

// Frees a MediaSource whose handle is gone. `release_children`: its source buffers and lists are released too (not when
// the page is closing: the objects are all destroyed then).
@(private)
ms_free :: proc(ms: ^Media_Source_Object, release_children: bool) {
	p := ms.page
	if release_children {
		for sb in ms.buffers { sb.ms = nil; object_release(p, sb.self) }
		for sb in ms.dead { object_release(p, sb.self) }
		if ms.list_all != 0 { object_release(p, ms.list_all) }
		if ms.list_active != 0 { object_release(p, ms.list_active) }
	}
	delete(ms.buffers)
	delete(ms.dead)
	delete(ms.url)
	if ms.remote != nil { mse_unbind(ms) }   // mse_worker.odin
	free(ms)
}

@(private)
sb_free_resources :: proc(sb: ^Source_Buffer_Object) {
	if sb.mp4 != nil { media.mp4_destroy(sb.mp4); free(sb.mp4); sb.mp4 = nil }
	if sb.webm != nil { media.webm_destroy(sb.webm); free(sb.webm); sb.webm = nil }
	media.store_destroy(sb.vstore); media.store_destroy(sb.astore)
	sb.vstore, sb.astore = nil, nil
	if sb.has_vinfo { media.track_destroy(&sb.vinfo); sb.has_vinfo = false }
	if sb.has_ainfo { media.track_destroy(&sb.ainfo); sb.has_ainfo = false }
}

@(private)
ms_element :: proc(ms: ^Media_Source_Object) -> ^Media_Element {
	p := ms.page
	if ms.el_node == base.NIL_HANDLE || p.media == nil { return nil }
	el, ok := p.media.elements[ms.el_node]
	if !ok || el.serial != ms.el_serial || el.ms == nil || el.ms.ms != ms { return nil }
	return el
}

// Fires an event at an object from a task of its own.
@(private)
Mse_Event :: struct {
	handle: u64,
	type:   string,
}

@(private)
mse_fire :: proc(p: ^Page, handle: u64, type: string) {
	if handle == 0 || p.closed { return }
	if mse_forward(p, handle, type) { return }   // the page's side of a worker's MediaSource: to the worker (mse_worker.odin)
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		ev := (^Mse_Event)(data)
		defer { delete(ev.type); free(ev) }
		if pg == nil || pg.closed { return }
		object_dispatch(pg, ev.handle, dom.Event{type = ev.type})
	}, new_clone(Mse_Event{handle, strings.clone(type)}))
}

////////////////////////////////
// MediaSource

MediaSource_create :: proc(c: ^Call) -> (u64, Api_Error) { return media_source_make(c, false) }

// new ManagedMediaSource(): a MediaSource the user agent streams when it needs data (media_managed.odin).
ManagedMediaSource_create :: proc(c: ^Call) -> (u64, Api_Error) { return media_source_make(c, true) }

@(private)
media_source_make :: proc(c: ^Call, managed: bool) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.media.enabled || !p.settings.media.mse_enabled { return 0, fail(c, .Not_Supported, "Media Source Extensions are disabled (media.mse.enabled)") }
	if p.worker != nil && (p.worker.shared || p.worker.sw.version != 0) { return 0, fail(c, .Not_Supported, "MediaSource is available in windows and dedicated workers only") }
	ms := new(Media_Source_Object)
	ms.page, ms.owner = p, c.owner
	ms.duration = math.nan_f64()
	ms.managed = managed
	if p.worker != nil { mse_bind_worker(p, ms) }   // mse_worker.odin: its element will be in the page
	h := object_create(p, &media_source_vt, ms, c.owner)
	ms.self = h
	ms.list_all = object_create(p, &source_buffer_list_vt, new_clone(Source_Buffer_List_Object{ms = ms}), c.owner)
	ms.list_active = object_create(p, &source_buffer_list_vt, new_clone(Source_Buffer_List_Object{ms = ms, active = true}), c.owner)
	return h, .None
}

MediaSource_registerObjectURL :: proc(c: ^Call, source: Api_MediaSource, url: string) -> Api_Error {
	ms := source.data
	// a worker's MediaSource: the URL is made but names nothing (MSE: a media element of the page cannot load it, it
	// takes the transferred handle as srcObject instead)
	if c.page.worker != nil || ms.remote != nil { return .None }
	pm := media_pm(c.page)
	if ms.url != "" { delete_key(&pm.urls, ms.url); delete(ms.url) }
	ms.url = strings.clone(url)
	pm.urls[ms.url] = ms.self
	return .None
}

MediaSource_revokeObjectURL :: proc(c: ^Call, url: string) {
	if c.page.worker != nil { return }
	pm := c.page.media
	if pm == nil { return }
	h, ok := pm.urls[url]
	if !ok { return }
	if ms := (^Media_Source_Object)(object_data(c.page, h, &media_source_vt)); ms != nil && ms.url == url {
		delete_key(&pm.urls, ms.url)
		delete(ms.url)
		ms.url = ""
	}
}

MediaSource_isTypeSupported :: proc(c: ^Call, type: string) -> bool {
	st := &c.page.settings.media
	return st.enabled && st.mse_enabled && mse_type_ok(type, st^)
}

// An MP4 type may leave the codecs out (the movie box names them); a WebM one must name them (WPT:
// mediasource-is-type-supported.html), so a container alone is not enough there.
@(private)
mse_type_ok :: proc(type: string, st: media.Settings) -> bool {
	switch media.type_support(type, st) {
	case .Probably: return true
	case .Maybe:
		pt, ok := media.parse_type(type)
		defer media.parsed_type_destroy(&pt)
		return ok && pt.container == .MP4
	case .No:
	}
	return false
}

MediaSource_sourceBuffers :: proc(c: ^Call, source: Api_MediaSource) -> u64 { return source.data.list_all }
MediaSource_activeSourceBuffers :: proc(c: ^Call, source: Api_MediaSource) -> u64 { return source.data.list_active }

MediaSource_readyState :: proc(c: ^Call, source: Api_MediaSource) -> string {
	switch source.data.state {
	case .Closed: return "closed"
	case .Open: return "open"
	case .Ended: return "ended"
	}
	return "closed"
}

MediaSource_duration :: proc(c: ^Call, source: Api_MediaSource) -> f64 { return source.data.duration }

@(private)
ms_updating :: proc(ms: ^Media_Source_Object) -> bool {
	for sb in ms.buffers { if sb.updating { return true } }
	return false
}

// A script touching a source that had ended makes it open again (the specification's "open" algorithm).
@(private)
ms_reopen :: proc(ms: ^Media_Source_Object) {
	if ms.state != .Ended { return }
	ms.state = .Open
	if mse_proxy(ms) { return }   // (the page's side reopens with the command and its sourceopen comes from there)
	mse_fire(ms.page, ms.self, "sourceopen")
	if el := ms_element(ms); el != nil && el.player != nil { media.player_set_source_ended(el.player, false) }
}

MediaSource_set_duration :: proc(c: ^Call, source: Api_MediaSource, value: f64) -> Api_Error {
	ms := source.data
	if value < 0 || math.is_nan(value) { return fail(c, .Type, "The duration provided is negative or not a number.") }
	if ms.state != .Open { return fail(c, .Invalid_State, "The MediaSource's readyState is not 'open'.") }
	if ms_updating(ms) { return fail(c, .Invalid_State, "A SourceBuffer is still updating.") }
	// a duration below what is buffered is refused: the script removes that range first (SourceBuffer.remove)
	if hi := ms_highest_pts(ms); value < hi { return fail(c, .Invalid_State, "The duration provided is less than the highest presentation timestamp of the buffered coded frames.") }
	if mse_proxy(ms) { ms.duration = value; mse_command(ms, .Duration, 0, value); return .None }
	ms_set_duration(ms, value)
	return .None
}

// The highest presentation time of a coded frame of any source buffer (seconds; the start of the last one).
@(private)
ms_highest_pts :: proc(ms: ^Media_Source_Object) -> f64 {
	hi: f64
	for sb in ms.buffers {
		for s in ([2]^media.Track_Store{sb.vstore, sb.astore}) {
			if s == nil { continue }
			if v, ok := media.store_highest_pts(s); ok { hi = max(hi, media.time_seconds(v)) }
		}
	}
	return hi
}

// duration changes: what lies past a shorter one is removed, the element is told.
@(private)
ms_set_duration :: proc(ms: ^Media_Source_Object, value: f64) {
	if value == ms.duration || (math.is_nan(value) && math.is_nan(ms.duration)) { return }
	if !math.is_nan(value) && (math.is_nan(ms.duration) || value < ms.duration) {
		for sb in ms.buffers {
			if sb.vstore != nil { media.store_remove(sb.vstore, media.seconds_time(value), media.Time(max(i64))) }
			if sb.astore != nil { media.store_remove(sb.astore, media.seconds_time(value), media.Time(max(i64))) }
		}
	}
	ms.duration = value
	if el := ms_element(ms); el != nil {
		el.duration = value
		media_fire(el, "durationchange")
		media_update(el)
	}
}

MediaSource_addSourceBuffer :: proc(c: ^Call, source: Api_MediaSource, type: string) -> (u64, Api_Error) {
	ms := source.data
	p := c.page
	st := &p.settings.media
	if type == "" { return 0, fail(c, .Type, "The type provided is empty.") }
	if ms.state != .Open { return 0, fail(c, .Invalid_State, "The MediaSource's readyState is not 'open'.") }
	if !mse_type_ok(type, st^) { return 0, fail(c, .Not_Supported, fmt.tprintf("The type provided ('%s') is unsupported.", type)) }
	if len(ms.buffers) >= st.mse_max_buffers { return 0, fail(c, .Quota, "This MediaSource has reached the limit of SourceBuffer objects it can handle.") }
	pt, _ := media.parse_type(type)
	defer media.parsed_type_destroy(&pt)
	sb := new(Source_Buffer_Object)
	sb.page, sb.ms = p, ms
	sb.mime = strings.clone(type)
	sb.managed = ms.managed
	sb.win_end = math.inf_f64(1)
	sb.vtrack, sb.atrack = -1, -1
	sb.is_webm = pt.container == .WebM
	sb.want_video, sb.want_audio = media.type_tracks(pt)
	h := object_create(p, &source_buffer_vt, sb, c.owner)
	sb.self = h
	append(&ms.buffers, sb)
	if mse_proxy(ms) {
		// a worker's: the page's side makes the real one (its addsourcebuffer comes back from there)
		ms.next_rid += 1
		sb.rid = ms.next_rid
		mse_command(ms, .Add, sb.rid, text = type)
		return h, .None
	}
	sb_new_parser(sb)
	if ms.remote_ui { sb.rid = ms.next_rid }   // (the page's side of a worker's: the id the worker gave it, before its event)
	mse_fire(p, ms.list_all, "addsourcebuffer")
	return h, .None
}

@(private)
sb_new_parser :: proc(sb: ^Source_Buffer_Object) {
	if sb.mp4 != nil { media.mp4_destroy(sb.mp4); free(sb.mp4); sb.mp4 = nil }
	if sb.webm != nil { media.webm_destroy(sb.webm); free(sb.webm); sb.webm = nil }
	sink := media.Demux_Sink{user = sb, tracks = sb_sink_tracks, sample = sb_sink_sample}
	if sb.is_webm {
		sb.webm = new(media.Webm_Demuxer)
		media.webm_init(sb.webm, sink)
	} else {
		sb.mp4 = new(media.Mp4_Demuxer)
		media.mp4_init(sb.mp4, sink)
	}
	// the frames of the old parser keep their configurations: the new one counts on from where it ended
	sb.config_base += sb.cfg_count
	sb.cfg_count = 0
	sb.seq_first = true
}

// Takes a source buffer out of its source: its operation stops, what the element plays from it with it, its parser and
// frames go. `events`: removesourcebuffer is fired (a removal by script or the element's detach, not the source's end).
@(private)
ms_remove_buffer :: proc(ms: ^Media_Source_Object, idx: int, events: bool) {
	p := ms.page
	sb := ms.buffers[idx]
	proxy := mse_proxy(ms)   // (a worker's: the events come from the page's side)
	fire := events && !proxy
	if sb.updating {
		sb.op_gen += 1
		sb.updating = false
		sb.op = .None
		delete(sb.op_data)
		sb.op_data = nil
		if !proxy {
			mse_fire(p, sb.self, "abort")
			mse_fire(p, sb.self, "updateend")
		}
	}
	ordered_remove(&ms.buffers, idx)
	sb.ms = nil
	if el := ms_element(ms); el != nil {
		uses := (el.vstore != nil && el.vstore == sb.vstore) || (el.astore != nil && el.astore == sb.astore)
		if uses {
			if el.player != nil { media.player_destroy(el.player); el.player = nil }
			if el.vstore == sb.vstore { el.vstore = nil }
			if el.astore == sb.astore { el.astore = nil }
		}
	}
	sb_free_resources(sb)
	was_active := sb.init_received
	sb.init_received = false
	append(&ms.dead, sb)
	if fire {
		mse_fire(p, ms.list_all, "removesourcebuffer")
		if was_active { mse_fire(p, ms.list_active, "removesourcebuffer") }
	}
}

MediaSource_removeSourceBuffer :: proc(c: ^Call, source: Api_MediaSource, buffer: Api_SourceBuffer) -> Api_Error {
	ms, sb := source.data, buffer.data
	idx := -1
	for b, i in ms.buffers { if b == sb { idx = i; break } }
	if idx < 0 { return fail(c, .Not_Found, "The SourceBuffer provided is not contained in this MediaSource.") }
	if mse_proxy(ms) { mse_command(ms, .Remove_Buffer, sb.rid) }
	ms_remove_buffer(ms, idx, true)
	return .None
}

MediaSource_endOfStream :: proc(c: ^Call, source: Api_MediaSource, error: string) -> Api_Error {
	ms := source.data
	if error != "" && error != "network" && error != "decode" { return fail(c, .Type, "The provided value is not a valid enum value of type EndOfStreamError.") }
	if ms.state != .Open { return fail(c, .Invalid_State, "The MediaSource's readyState is not 'open'.") }
	if ms_updating(ms) { return fail(c, .Invalid_State, "A SourceBuffer is still updating.") }
	if mse_proxy(ms) { ms.state = .Ended; mse_command(ms, .End, 0, text = error); return .None }
	ms_end_of_stream(ms, error)
	return .None
}

@(private)
ms_end_of_stream :: proc(ms: ^Media_Source_Object, error: string) {
	p := ms.page
	ms.state = .Ended
	el := ms_element(ms)
	if error == "network" || error == "decode" {
		if el != nil { media_error(el, error == "network" ? MEDIA_ERR_NETWORK : MEDIA_ERR_DECODE, "the media source ended with an error") }
	} else {
		// the duration becomes the highest end of what is buffered
		hi: f64
		for sb in ms.buffers {
			if sb.vstore != nil { if _, e, ok := media.store_extent(sb.vstore); ok { hi = max(hi, media.time_seconds(e)) } }
			if sb.astore != nil { if _, e, ok := media.store_extent(sb.astore); ok { hi = max(hi, media.time_seconds(e)) } }
		}
		if hi > 0 { ms_set_duration(ms, hi) }
	}
	mse_fire(p, ms.self, "sourceended")
	if el != nil {
		if el.player != nil { media.player_set_source_ended(el.player, true) }
		media_update(el)
	}
}

MediaSource_setLiveSeekableRange :: proc(c: ^Call, source: Api_MediaSource, start, end: f64) -> Api_Error {
	ms := source.data
	if ms.state != .Open { return fail(c, .Invalid_State, "The MediaSource's readyState is not 'open'.") }
	if start < 0 || start > end { return fail(c, .Type, "The start and end values are invalid.") }
	ms.live, ms.has_live = {start, end}, true
	if mse_proxy(ms) { mse_command(ms, .Live, 0, start, end) }
	return .None
}

MediaSource_clearLiveSeekableRange :: proc(c: ^Call, source: Api_MediaSource) -> Api_Error {
	if source.data.state != .Open { return fail(c, .Invalid_State, "The MediaSource's readyState is not 'open'.") }
	source.data.has_live = false
	if mse_proxy(source.data) { mse_command(source.data, .Clear_Live, 0) }
	return .None
}

// The buffers a list shows: every one, or for activeSourceBuffers those that had an initialization segment (their
// tracks are the ones the element plays).
@(private)
sbl_nth :: proc(l: ^Source_Buffer_List_Object, index: int) -> (sb: ^Source_Buffer_Object, count: int) {
	if l.ms == nil { return nil, 0 }
	for b in l.ms.buffers {
		if l.active && !b.init_received { continue }
		if count == index { sb = b }
		count += 1
	}
	return
}

SourceBufferList_length :: proc(c: ^Call, list: Api_SourceBufferList) -> u32 {
	_, n := sbl_nth(list.data, -1)
	return u32(n)
}

SourceBufferList_item :: proc(c: ^Call, list: Api_SourceBufferList, index: u32) -> (u64, Api_Error) {
	sb, _ := sbl_nth(list.data, int(index))
	if sb == nil { return 0, .Not_Found }
	return sb.self, .None
}

////////////////////////////////
// The element's side

// URL.createObjectURL's result as an element's src: this Media Source plays. false: not a Media Source URL.
@(private)
media_source_attach_url :: proc(el: ^Media_Element, href: string) -> bool {
	p := el.page
	if p.media == nil { return false }
	h, ok := p.media.urls[href]
	if !ok && el.blob_href == href && el.blob_ms != 0 { h, ok = el.blob_ms, true }   // (revoked since the src was set)
	if !ok { return false }
	ms := (^Media_Source_Object)(object_data(p, h, &media_source_vt))
	if ms == nil { return false }
	ms_attach(el, ms)
	return true
}

// The element plays `ms` (an object URL's, or the page's side of a worker's: mse_worker.odin).
@(private)
ms_attach :: proc(el: ^Media_Element, ms: ^Media_Source_Object) {
	p := el.page
	if ms.state != .Closed || ms.el_node != base.NIL_HANDLE {
		media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the MediaSource is already attached")
		return
	}
	link := new(Media_Source_Link)
	link.ms = ms
	el.ms = link
	el.kind = .Media_Source
	ms.el_node, ms.el_serial = el.node, el.serial
	ms.state = .Open
	el.network_state = NETWORK_LOADING
	mse_fire(p, ms.self, "sourceopen")
}

// The element lets go of its Media Source (a new load, removal): it is closed, its buffers removed.
@(private)
media_source_detach :: proc(el: ^Media_Element) {
	link := el.ms
	el.ms = nil
	el.vstore, el.astore = nil, nil   // (the source buffers own them)
	if link == nil { return }
	ms := link.ms
	free(link)
	if ms == nil { return }
	ms.el_node = base.NIL_HANDLE
	if ms.managed { ms_managed_closed(ms) }
	if ms.state != .Closed {
		ms.state = .Closed
		ms.duration = math.nan_f64()
		ms.has_live = false
		quiet := el.page.closed
		for len(ms.buffers) > 0 { ms_remove_buffer(ms, len(ms.buffers) - 1, !quiet) }
		if !quiet { mse_fire(el.page, ms.self, "sourceclose") }
	}
	if ms.remote_ui {
		// the page's side of a worker's MediaSource has no script of the page holding it: it goes now
		if !el.page.closed { object_release(el.page, ms.self) }
		return
	}
	if ms.orphan { ms_free(ms, !el.page.closed) }
}

@(private)
media_source_ended :: proc(el: ^Media_Element) -> bool { return el.ms != nil && el.ms.ms.state == .Ended }

@(private)
media_source_buffered :: proc(el: ^Media_Element) -> [][2]f64 {
	r := media_buffered_ranges(el)
	if el.ms.ms.state == .Ended && len(r) > 0 {
		hi: f64
		for sb in el.ms.ms.buffers { hi = max(hi, sb_highest_end(sb)) }
		r[len(r) - 1][1] = max(r[len(r) - 1][1], hi)
	}
	return r
}

@(private)
media_source_seekable :: proc(el: ^Media_Element) -> [][2]f64 {
	ms := el.ms.ms
	out := make([dynamic][2]f64, context.temp_allocator)
	if ms.has_live {
		append(&out, ms.live)
	} else if !math.is_nan(ms.duration) {
		end := ms.duration
		if math.is_inf(end) {
			end = 0
			for r in media_buffered_ranges(el) { end = max(end, r[1]) }
		}
		append(&out, [2]f64{0, end})
	}
	return out[:]
}

// Every source buffer has had an initialization segment: the element has its metadata.
@(private)
ms_check_ready :: proc(ms: ^Media_Source_Object) {
	el := ms_element(ms)
	if el == nil || el.got_tracks || len(ms.buffers) == 0 { return }
	for sb in ms.buffers { if !sb.init_received { return } }
	p := ms.page
	for sb in ms.buffers {
		if sb.vstore != nil && el.vstore == nil && el.is_video {
			el.vstore = sb.vstore
			el.vinfo, el.has_vinfo = media.track_clone(sb.vinfo), true
			el.vw, el.vh = media_picture_size(sb.vinfo)
		}
		if sb.astore != nil && el.astore == nil {
			el.astore = sb.astore
			el.ainfo, el.has_ainfo = media.track_clone(sb.ainfo), true
		}
	}
	if el.vstore == nil && el.astore == nil {
		media_error(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the source buffers hold nothing playable")
		return
	}
	el.got_tracks = true
	if math.is_nan(ms.duration) {
		d := 0.0
		for sb in ms.buffers { d = max(d, sb.init_duration) }
		ms.duration = d > 0 ? d : math.inf_f64(1)
	}
	el.duration = ms.duration
	media_make_player(el)
	images_init(p)
	p.images.sizes = next_serial()
	el.ready_state = HAVE_METADATA
	media_fire(el, "durationchange")
	media_fire(el, "loadedmetadata")
	el.fired += {.Loadedmetadata}
	if el.is_video { media_fire(el, "resize") }
}

// The size a picture is shown at: the container's display size, turned by its rotation.
@(private)
media_picture_size :: proc(t: media.Track) -> (w, h: int) {
	w, h = t.display_width, t.display_height
	if w == 0 { w, h = t.width, t.height }
	if t.rotation == 90 || t.rotation == 270 { w, h = h, w }
	return
}

////////////////////////////////
// SourceBuffer

@(private)
sb_check :: proc(c: ^Call, sb: ^Source_Buffer_Object) -> Api_Error {
	if sb.ms == nil { return fail(c, .Invalid_State, "This SourceBuffer has been removed from the parent media source.") }
	return .None
}

@(private)
sb_check_idle :: proc(c: ^Call, sb: ^Source_Buffer_Object) -> Api_Error {
	if e := sb_check(c, sb); e != .None { return e }
	if sb.updating { return fail(c, .Invalid_State, "This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.") }
	return .None
}

SourceBuffer_mode :: proc(c: ^Call, b: Api_SourceBuffer) -> string { return b.data.mode == .Sequence ? "sequence" : "segments" }

SourceBuffer_set_mode :: proc(c: ^Call, b: Api_SourceBuffer, mode: string) -> Api_Error {
	sb := b.data
	if e := sb_check_idle(c, sb); e != .None { return e }
	m := mode == "sequence" ? Append_Mode.Sequence : Append_Mode.Segments
	ms_reopen(sb.ms)
	if m == .Sequence && sb.mode != .Sequence { sb.group_end = sb_highest_end(sb) }
	sb.mode = m
	sb.seq_first = true
	if mse_proxy(sb.ms) { mse_command(sb.ms, .Mode, sb.rid, text = mode) }
	return .None
}

SourceBuffer_updating :: proc(c: ^Call, b: Api_SourceBuffer) -> bool { return b.data.updating }

// The end of the latest frame the buffer holds (seconds).
@(private)
sb_highest_end :: proc(sb: ^Source_Buffer_Object) -> f64 {
	hi: f64
	for s in ([2]^media.Track_Store{sb.vstore, sb.astore}) {
		if s == nil { continue }
		if _, e, ok := media.store_extent(s); ok { hi = max(hi, media.time_seconds(e)) }
	}
	return hi
}

// (start, end) pairs, seconds: the ranges of the tracks the buffer has in common.
@(private)
sb_ranges :: proc(sb: ^Source_Buffer_Object) -> [][2]f64 {
	gap := sb.page.settings.media.gap_tolerance
	out := make([dynamic][2]f64, context.temp_allocator)
	a, v: []media.Range
	if sb.vstore != nil { v = media.store_ranges(sb.vstore, gap, context.temp_allocator) }
	if sb.astore != nil { a = media.store_ranges(sb.astore, gap, context.temp_allocator) }
	switch {
	case sb.vstore != nil && sb.astore != nil:
		for x in v { for y in a {
			s, e := max(x.start, y.start), min(x.end, y.end)
			if e > s { append(&out, [2]f64{media.time_seconds(s), media.time_seconds(e)}) }
		} }
	case sb.vstore != nil: for x in v { append(&out, [2]f64{media.time_seconds(x.start), media.time_seconds(x.end)}) }
	case sb.astore != nil: for x in a { append(&out, [2]f64{media.time_seconds(x.start), media.time_seconds(x.end)}) }
	}
	// once the stream has ended its last range reaches the end of the longest track
	if sb.ms != nil && sb.ms.state == .Ended && len(out) > 0 {
		out[len(out) - 1][1] = max(out[len(out) - 1][1], sb_highest_end(sb))
	}
	return out[:]
}

SourceBuffer_ranges :: proc(c: ^Call, b: Api_SourceBuffer) -> ([]u8, Api_Error) {
	sb := b.data
	if e := sb_check(c, sb); e != .None { return nil, e }
	if mse_proxy(sb.ms) { return ranges_bytes(sb.ranges[:]), .None }   // the mirror of the page's buffer
	return ranges_bytes(sb_ranges(sb)), .None
}

SourceBuffer_timestampOffset :: proc(c: ^Call, b: Api_SourceBuffer) -> f64 { return b.data.ts_offset }

SourceBuffer_set_timestampOffset :: proc(c: ^Call, b: Api_SourceBuffer, value: f64) -> Api_Error {
	sb := b.data
	if e := sb_check_idle(c, sb); e != .None { return e }
	ms_reopen(sb.ms)
	sb.ts_offset = value
	if mse_proxy(sb.ms) { mse_command(sb.ms, .Ts_Offset, sb.rid, value) }
	return .None
}

SourceBuffer_appendWindowStart :: proc(c: ^Call, b: Api_SourceBuffer) -> f64 { return b.data.win_start }
SourceBuffer_appendWindowEnd :: proc(c: ^Call, b: Api_SourceBuffer) -> f64 { return b.data.win_end }

SourceBuffer_set_appendWindowStart :: proc(c: ^Call, b: Api_SourceBuffer, value: f64) -> Api_Error {
	sb := b.data
	if e := sb_check_idle(c, sb); e != .None { return e }
	if math.is_nan(value) || value < 0 || value >= sb.win_end { return fail(c, .Type, "The value provided is outside the range [0, appendWindowEnd).") }
	sb.win_start = value
	if mse_proxy(sb.ms) { mse_command(sb.ms, .Window, sb.rid, sb.win_start, sb.win_end) }
	return .None
}

SourceBuffer_set_appendWindowEnd :: proc(c: ^Call, b: Api_SourceBuffer, value: f64) -> Api_Error {
	sb := b.data
	if e := sb_check_idle(c, sb); e != .None { return e }
	if math.is_nan(value) || value <= sb.win_start { return fail(c, .Type, "The value provided is not greater than appendWindowStart.") }
	sb.win_end = value
	if mse_proxy(sb.ms) { mse_command(sb.ms, .Window, sb.rid, sb.win_start, sb.win_end) }
	return .None
}

@(private)
sb_budget :: proc(sb: ^Source_Buffer_Object) -> int {
	st := &sb.page.settings.media
	return sb.vstore != nil || sb.vtrack >= 0 ? st.mse_video_bytes : st.mse_audio_bytes
}

// Room for `need` more bytes: removes what is far behind the playback position (and far ahead, if need be). false: no.
@(private)
sb_make_room :: proc(sb: ^Source_Buffer_Object, need: int) -> bool {
	st := &sb.page.settings.media
	limit := sb_budget(sb)
	used := 0
	if sb.vstore != nil { used += media.store_bytes(sb.vstore) }
	if sb.astore != nil { used += media.store_bytes(sb.astore) }
	if used + need <= limit { return true }
	pos: f64
	if el := ms_element(sb.ms); el != nil && el.player != nil { pos = media.time_seconds(media.player_time(el.player)) } else if el != nil { pos = el.position }
	// behind the position first
	keep := max(limit - need, 0)
	behind := media.seconds_time(max(pos - media.time_seconds(st.mse_behind), 0))
	for s in ([2]^media.Track_Store{sb.vstore, sb.astore}) {
		if s == nil { continue }
		used -= media.store_evict_before(s, behind, keep / 2)
	}
	if used + need <= limit { return true }
	// then what is far ahead (past what the page may use)
	ahead_from := media.seconds_time(pos) + st.mse_ahead
	for s in ([2]^media.Track_Store{sb.vstore, sb.astore}) {
		if s == nil { continue }
		used -= media.store_remove(s, ahead_from, media.Time(max(i64)))
	}
	if used + need <= limit { return true }
	// as a last resort, anything behind the position at all
	for s in ([2]^media.Track_Store{sb.vstore, sb.astore}) {
		if s == nil { continue }
		used -= media.store_evict_before(s, media.seconds_time(pos), keep / 2)
	}
	return used + need <= limit
}

SourceBuffer_appendBuffer :: proc(c: ^Call, b: Api_SourceBuffer, data: []u8) -> Api_Error {
	sb := b.data
	if e := sb_check_idle(c, sb); e != .None { return e }
	ms_reopen(sb.ms)
	if mse_proxy(sb.ms) {
		// a worker's: the page's buffer parses it; updating until its updateend comes back (with its buffered ranges)
		sb.updating = true
		mse_command(sb.ms, .Append, sb.rid, data = data)
		return .None
	}
	if !sb_make_room(sb, len(data)) { return fail(c, .Quota, "The SourceBuffer is full, and cannot free space to append additional buffers.") }
	sb.updating = true
	sb.op = .Append
	delete(sb.op_data)
	sb.op_data = make([]byte, len(data))
	copy(sb.op_data, data)
	sb_schedule(sb)
	return .None
}

SourceBuffer_remove :: proc(c: ^Call, b: Api_SourceBuffer, start, end: f64) -> Api_Error {
	sb := b.data
	if e := sb_check_idle(c, sb); e != .None { return e }
	d := sb.ms.duration
	if math.is_nan(end) || start < 0 || start > end || (!math.is_nan(d) && start > d) { return fail(c, .Type, "The start and end times are invalid.") }
	ms_reopen(sb.ms)
	if mse_proxy(sb.ms) { sb.updating = true; mse_command(sb.ms, .Remove_Range, sb.rid, start, end); return .None }
	sb.updating = true
	sb.op = .Remove
	sb.op_range = {start, end}
	sb_schedule(sb)
	return .None
}

SourceBuffer_abort :: proc(c: ^Call, b: Api_SourceBuffer) -> Api_Error {
	sb := b.data
	if e := sb_check(c, sb); e != .None { return e }
	if sb.ms.state != .Open { return fail(c, .Invalid_State, "The MediaSource's readyState is not 'open'.") }
	if mse_proxy(sb.ms) {
		// (the page's side fires abort and updateend when an operation was running)
		sb.updating = false
		sb.win_start, sb.win_end = 0, math.inf_f64(1)
		mse_command(sb.ms, .Abort, sb.rid)
		return .None
	}
	if sb.updating {
		sb.op_gen += 1
		sb.updating = false
		sb.op = .None
		delete(sb.op_data)
		sb.op_data = nil
		mse_fire(sb.page, sb.self, "abort")
		mse_fire(sb.page, sb.self, "updateend")
	}
	// the parser starts again at a segment boundary, the append window goes back to its defaults
	if sb.mp4 != nil { media.mp4_reset_parser(sb.mp4) }
	if sb.webm != nil { media.webm_reset_parser(sb.webm) }
	sb.win_start, sb.win_end = 0, math.inf_f64(1)
	sb.seq_first = true
	return .None
}

SourceBuffer_changeType :: proc(c: ^Call, b: Api_SourceBuffer, type: string) -> Api_Error {
	sb := b.data
	st := &c.page.settings.media
	if type == "" { return fail(c, .Type, "The type provided is empty.") }
	if e := sb_check_idle(c, sb); e != .None { return e }
	if !mse_type_ok(type, st^) { return fail(c, .Not_Supported, fmt.tprintf("The type provided ('%s') is unsupported.", type)) }
	pt, _ := media.parse_type(type)
	defer media.parsed_type_destroy(&pt)
	ms_reopen(sb.ms)
	set_string(&sb.mime, type)
	sb.is_webm = pt.container == .WebM
	sb.want_video, sb.want_audio = media.type_tracks(pt)
	sb.init_received = false   // (a new initialization segment is expected)
	if mse_proxy(sb.ms) { mse_command(sb.ms, .Change_Type, sb.rid, text = type); return .None }
	sb_new_parser(sb)
	return .None
}

// The operation runs in a task; updatestart first, then update + updateend (or error + updateend).
@(private)
Sb_Task :: struct {
	handle: u64,
	gen:    u32,
}

@(private)
sb_schedule :: proc(sb: ^Source_Buffer_Object) {
	p := sb.page
	mse_fire(p, sb.self, "updatestart")
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Sb_Task)(data)
		defer free(t)
		if pg == nil || pg.closed { return }
		sb := (^Source_Buffer_Object)(object_data(pg, t.handle, &source_buffer_vt))
		if sb == nil || sb.op_gen != t.gen || !sb.updating { return }
		sb_run(sb)
	}, new_clone(Sb_Task{sb.self, sb.op_gen}))
}

@(private)
sb_run :: proc(sb: ^Source_Buffer_Object) {
	p := sb.page
	ok := true
	switch sb.op {
	case .Append:
		err: media.Parse_Error
		if sb.is_webm { err = media.webm_feed(sb.webm, sb.op_data) } else { err = media.mp4_feed(sb.mp4, sb.op_data) }
		if err != .None || sb.parse_error {
			ok = false
			sb.parse_error = false
			if sb.mp4 != nil { media.mp4_reset_parser(sb.mp4) }
			if sb.webm != nil { media.webm_reset_parser(sb.webm) }
		}
		delete(sb.op_data)
		sb.op_data = nil
	case .Remove:
		a := media.seconds_time(sb.op_range[0])
		b := math.is_inf(sb.op_range[1]) ? media.Time(max(i64)) : media.seconds_time(sb.op_range[1])
		if sb.vstore != nil { media.store_remove(sb.vstore, a, b) }
		if sb.astore != nil { media.store_remove(sb.astore, a, b) }
	case .None:
	}
	sb.op = .None
	sb.updating = false
	if ok {
		mse_fire(p, sb.self, "update")
		mse_fire(p, sb.self, "updateend")
	} else {
		mse_fire(p, sb.self, "error")
		mse_fire(p, sb.self, "updateend")
		if sb.ms != nil && sb.ms.state == .Open { ms_end_of_stream(sb.ms, "decode") }
	}
	// a ManagedSourceBuffer whose ranges changed fires bufferedchange with what was added / removed (media_managed.odin)
	if sb.managed { sb_fire_buffered_change(sb) }
	if sb.ms != nil {
		if el := ms_element(sb.ms); el != nil {
			if el.player != nil { media.player_wake(el.player) }
			media_update(el)
		}
	}
}

////////////////////////////////
// What the container parser reports

@(private)
sb_sink_tracks :: proc(user: rawptr, tracks: []media.Track, duration: media.Time) {
	sb := (^Source_Buffer_Object)(user)
	p := sb.page
	st := p.settings.media
	if sb.ms == nil { return }
	vt, at := -1, -1
	for t, i in tracks {
		switch t.kind {
		case .Video: if vt < 0 && sb.want_video && media.codec_supported(t.codec, st) { vt = i }
		case .Audio: if at < 0 && sb.want_audio && media.codec_supported(t.codec, st) { at = i }
		case .Other:
		}
	}
	if vt < 0 && at < 0 {
		sb.parse_error = true
		return
	}
	sb.vtrack, sb.atrack = vt, at
	sb.cfg_count += 1
	cfg := sb.config_base + sb.cfg_count
	if vt >= 0 {
		if sb.vstore == nil { sb.vstore = media.store_create() }
		media.store_set_config(sb.vstore, cfg, tracks[vt])
		if sb.has_vinfo { media.track_destroy(&sb.vinfo) }
		sb.vinfo, sb.has_vinfo = media.track_clone(tracks[vt]), true
	}
	if at >= 0 {
		if sb.astore == nil { sb.astore = media.store_create() }
		media.store_set_config(sb.astore, cfg, tracks[at])
		if sb.has_ainfo { media.track_destroy(&sb.ainfo) }
		sb.ainfo, sb.has_ainfo = media.track_clone(tracks[at]), true
	}
	if duration > 0 { sb.init_duration = media.time_seconds(duration) }
	if !sb.init_received { mse_fire(p, sb.ms.list_active, "addsourcebuffer") }   // (its tracks are active now)
	sb.init_received = true
	sb.seq_first = true
	if el := ms_element(sb.ms); el != nil {
		if el.got_tracks && el.is_video && vt >= 0 {
			// a new picture size (a quality switch): the element says so
			w, h := media_picture_size(tracks[vt])
			if w != el.vw || h != el.vh {
				el.vw, el.vh = w, h
				images_init(p)
				p.images.sizes = next_serial()
				media_fire(el, "resize")
			}
		}
		ms_check_ready(sb.ms)
	}
}

@(private)
sb_sink_sample :: proc(user: rawptr, track: int, s: media.Sample) {
	sb := (^Source_Buffer_Object)(user)
	smp := s
	store: ^media.Track_Store
	switch {
	case track == sb.vtrack: store = sb.vstore
	case track == sb.atrack: store = sb.astore
	}
	if store == nil || sb.ms == nil {
		media.sample_destroy(&smp)
		return
	}
	if sb.mode == .Sequence && sb.seq_first {
		sb.ts_offset = sb.group_end - media.time_seconds(smp.pts)
		sb.seq_first = false
	}
	off := media.seconds_time(sb.ts_offset)
	smp.pts += off
	smp.dts += off
	smp.config += sb.config_base
	start, end := media.time_seconds(smp.pts), media.time_seconds(smp.pts + smp.duration)
	// the append window: frames outside it are dropped
	if start < sb.win_start || end > sb.win_end {
		media.sample_destroy(&smp)
		return
	}
	media.store_replace_overlap(store, smp.pts, smp.dts, smp.pts + max(smp.duration, 1), .Keyframe in smp.flags)
	media.store_append(store, smp)
	if sb.mode == .Sequence { sb.group_end = max(sb.group_end, end) }
}

// element.buffered, played, seekable as (start, end) pairs of f64 (little endian).
@(private)
ranges_bytes :: proc(r: [][2]f64) -> []u8 {
	out := make([]u8, len(r) * 16, context.temp_allocator)
	for x, i in r {
		a, b := x[0], x[1]
		mem.copy(&out[i * 16], &a, 8)
		mem.copy(&out[i * 16 + 8], &b, 8)
	}
	return out
}

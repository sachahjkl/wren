package page

// HTMLMediaElement (<video>, <audio>): the state machine of HTML §4.8.11 over the media package's player.
//
//   * A media element is made when script or the parser first touches it (`media_element`); its state lives here, not in
//     the DOM node. Its load (`media_load`: the resource selection algorithm, fetch, container parser) fills two Track_Stores,
//     one for the video and one for the audio, which a media.Player decodes on its own threads; a Media Source (MSE,
//     media_source.odin) fills the stores instead of a download.
//   * The player tells the page (from any thread: host.post) that something changed; `media_update` then looks at it from
//     the UI thread: readyState from what is buffered ahead of the position, seeking / seeked, waiting / playing, ended,
//     timeupdate on a timer while playing, progress while downloading. Events are queued like the images' load events.
//   * The shell paints the pictures (browser/video_shell.odin): `media_present` hands it the current one.
//   * Preferences: media.* (media/settings.odin).

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:media"
import "wb:url"

NETWORK_EMPTY :: 0
NETWORK_IDLE :: 1
NETWORK_LOADING :: 2
NETWORK_NO_SOURCE :: 3

HAVE_NOTHING :: 0
HAVE_METADATA :: 1
HAVE_CURRENT_DATA :: 2
HAVE_FUTURE_DATA :: 3
HAVE_ENOUGH_DATA :: 4

MEDIA_ERR_ABORTED :: 1
MEDIA_ERR_NETWORK :: 2
MEDIA_ERR_DECODE :: 3
MEDIA_ERR_SRC_NOT_SUPPORTED :: 4

Media_Fired :: enum u8 { Loadedmetadata, Loadeddata, Canplay, Canplaythrough }

Media_Source_Kind :: enum u8 { None, Progressive, Media_Source }

Media_Element :: struct {
	page:     ^Page,
	node:     base.Handle,
	serial:   u64,             // told apart from an element of an earlier document that had the same handle
	is_video: bool,
	// the media element's own state (HTML)
	network_state: i32,
	ready_state:   i32,
	paused:        bool,
	ended_flag:    bool,       // "ended playback"
	seeking:       bool,
	autoplay_ok:   bool,       // the "can autoplay flag"
	default_rate, rate: f64,
	preserves_pitch: bool,
	volume:        f64,
	muted:         bool,
	duration:      f64,        // NaN: unknown
	position:      f64,        // the official playback position, seconds
	current_src:   string,     // owned
	err_code:      i32,
	err_message:   string,     // owned
	fired:         bit_set[Media_Fired],
	pending_play:  [dynamic]u64,
	// the load
	load_gen:      u32,        // bumps with each load algorithm run
	load_ticket:   u32,        // bumps with each request for one (the last request wins)
	kind:          Media_Source_Kind,
	task:          base.Handle,
	source_node:   base.Handle,   // the <source> element being tried
	sniffed:       bool,
	is_webm:       bool,
	mp4:           ^media.Mp4_Demuxer,
	webm:          ^media.Webm_Demuxer,
	vstore, astore: ^media.Track_Store,
	vtrack, atrack: int,       // indices of the chosen tracks in the container (-1: none)
	vinfo, ainfo:  media.Track,
	has_vinfo, has_ainfo: bool,
	got_tracks:    bool,
	downloaded:    int,
	content_length: int,
	download_done: bool,
	player:        ^media.Player,
	// timers and bookkeeping
	timer:         base.Handle,
	last_timeupdate: f64,      // ms of the loop clock
	last_progress: f64,
	last_position: f64,        // the position of the last timeupdate
	played:        [dynamic][2]f64,
	waiting_fired: bool,
	vw, vh:        int,        // the picture's size (rotated)
	ms:            ^Media_Source_Link,   // attached Media Source (media_source.odin)
	// statistics (getVideoPlaybackQuality)
	frames_total, frames_dropped: int,
	created_ms:    f64,
	// the shell
	paint_gen:     u64,        // changes whenever a new picture is current
	user_active_ms: f64,
}

Page_Media :: struct {
	elements: map[base.Handle]^Media_Element,
	doc:      ^dom.Document,
	serial:   u64,
	activated: bool,       // the page had a click or key press
}

Media_Notice :: struct {
	page_id: u64,
	node:    base.Handle,
	serial:  u64,
	ticket:  u32,
}

@(private)
media_pm :: proc(p: ^Page) -> ^Page_Media {
	if p.media == nil {
		p.media = new(Page_Media)
		p.media.elements = make(map[base.Handle]^Media_Element)
		p.media.doc = p.doc
	}
	return p.media
}

media_destroy :: proc(p: ^Page) {
	if p.media == nil { return }
	for _, el in p.media.elements { media_element_free(p, el, true) }
	delete(p.media.elements)
	free(p.media)
	p.media = nil
}

@(private)
is_media_node :: proc(n: ^dom.Node) -> (is_video: bool, ok: bool) {
	if n == nil || n.kind != .Element { return false, false }
	switch n.name {
	case "video": return true, true
	case "audio": return false, true
	}
	return false, false
}

// The state of a <video> / <audio> element, made on first use. nil: not a media element.
media_element :: proc(p: ^Page, node: base.Handle) -> ^Media_Element {
	if p == nil || p.closed || p.worker != nil { return nil }
	n := dom.get(p.doc, node)
	is_video, ok := is_media_node(n)
	if !ok { return nil }
	pm := media_pm(p)
	if pm.doc != p.doc { media_document_adopted(p) }
	if el, found := pm.elements[node]; found { return el }
	pm.serial += 1
	el := new(Media_Element)
	el.page, el.node, el.serial, el.is_video = p, node, pm.serial, is_video
	el.paused = true
	el.autoplay_ok = true
	el.default_rate, el.rate = 1, 1
	el.preserves_pitch = true
	el.volume = 1
	el.duration = math.nan_f64()
	el.vtrack, el.atrack = -1, -1
	el.created_ms = page_now_ms(p)
	el.muted = media_has_attr(p.doc, node, "muted")
	pm.elements[node] = el
	// a <video src>, <video><source>: the resource selection algorithm runs when the element is made (parser-created)
	if media_has_attr(p.doc, node, "src") || media_has_source_child(p, node) {
		media_schedule_load(el)
	}
	return el
}

@(private)
media_has_source_child :: proc(p: ^Page, node: base.Handle) -> bool {
	n := dom.get(p.doc, node)
	if n == nil { return false }
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(p.doc, c)
		if cn == nil { break }
		if cn.kind == .Element && cn.name == "source" { return true }
		c = cn.next
	}
	return false
}

lookup_HTMLMediaElement :: proc(c: ^Call, h: u64) -> ^Media_Element {
	if call_doc(c) == nil { return nil }
	return media_element(c.page, H(h))
}

@(private)
media_element_free :: proc(p: ^Page, el: ^Media_Element, page_closing: bool) {
	media_teardown(el)
	for pr in el.pending_play { if !page_closing { promise_reject(p, pr, i64(Api_Error.Abort), "AbortError: the media element was removed") } }
	delete(el.pending_play)
	delete(el.played)
	delete(el.current_src)
	delete(el.err_message)
	if el.timer != base.NIL_HANDLE { host.clear_timer(p.loop, el.timer) }
	free(el)
}

// The document was replaced: the old elements are gone with it; the new tree is scanned for media elements that load by
// themselves.
media_document_adopted :: proc(p: ^Page) {
	pm := media_pm(p)
	for _, el in pm.elements { media_element_free(p, el, true) }
	clear(&pm.elements)
	pm.doc = p.doc
	if !p.settings.media.enabled { return }
	stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	append(&stack, p.doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(p.doc, h)
		if n == nil { continue }
		if _, ok := is_media_node(n); ok { media_element(p, h) }
		for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(p.doc, c).prev { append(&stack, c) }
	}
}

////////////////////////////////
// DOM hooks (js_load.odin calls these)

media_note_inserted :: proc(p: ^Page, node: base.Handle) {
	if p.media == nil && !p.settings.media.enabled { return }
	n := dom.get(p.doc, node)
	if n == nil || n.kind != .Element { return }
	// a <source> inserted into a media element that has no source yet: its load runs now
	if n.name == "source" {
		parent := dom.get(p.doc, n.parent)
		if _, ok := is_media_node(parent); ok {
			if el := media_element(p, n.parent); el != nil && el.network_state == NETWORK_EMPTY && !media_has_attr(p.doc, n.parent, "src") { media_schedule_load(el) }
		}
		return
	}
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	append(&stack, node)
	for len(stack) > 0 {
		h := pop(&stack)
		x := dom.get(p.doc, h)
		if x == nil { continue }
		if _, ok := is_media_node(x); ok { media_element(p, h) }
		for c := x.last_child; c != base.NIL_HANDLE; c = dom.get(p.doc, c).prev { append(&stack, c) }
	}
}

media_note_attribute :: proc(p: ^Page, node: base.Handle, name: string) {
	if p.media == nil { return }
	el, ok := p.media.elements[node]
	if !ok { return }
	switch name {
	case "src": media_schedule_load(el)
	case "muted":
		// defaultMuted only: the muted attribute changes nothing once the element has played or been set
	case "loop", "controls", "preload", "autoplay", "poster", "width", "height":
	}
}

// A node left the tree: media elements that are no longer in a document pause (HTML "removing steps").
media_note_removed :: proc(p: ^Page) {
	if p.media == nil { return }
	for h, el in p.media.elements {
		if !el.paused && !dom.is_connected(p.doc, h) { media_pause(el) }
	}
}

////////////////////////////////
// The load algorithm

@(private)
media_schedule_load :: proc(el: ^Media_Element) {
	p := el.page
	el.load_ticket += 1
	el.network_state = NETWORK_NO_SOURCE   // (until the algorithm decides)
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		tok := (^Media_Notice)(data)
		defer free(tok)
		if pg == nil || pg.closed || pg.media == nil { return }
		el, ok := pg.media.elements[tok.node]
		if !ok || el.serial != tok.serial || el.load_ticket != tok.ticket { return }   // (a later request supersedes)
		media_load(el)
	}, new_clone(Media_Notice{node = el.node, serial = el.serial, ticket = el.load_ticket}))
}
// Aborts a load in progress and releases everything it made.
@(private)
media_teardown :: proc(el: ^Media_Element) {
	p := el.page
	if el.task != base.NIL_HANDLE { fetch.cancel(p.loader, el.task); el.task = base.NIL_HANDLE }
	if el.player != nil { media.player_destroy(el.player); el.player = nil }
	if el.mp4 != nil { media.mp4_destroy(el.mp4); free(el.mp4); el.mp4 = nil }
	if el.webm != nil { media.webm_destroy(el.webm); free(el.webm); el.webm = nil }
	if el.ms != nil { media_source_detach(el) }
	media.store_destroy(el.vstore); media.store_destroy(el.astore)
	el.vstore, el.astore = nil, nil
	if el.has_vinfo { media.track_destroy(&el.vinfo); el.has_vinfo = false }
	if el.has_ainfo { media.track_destroy(&el.ainfo); el.has_ainfo = false }
	el.vtrack, el.atrack = -1, -1
	el.got_tracks, el.sniffed, el.download_done = false, false, false
	el.downloaded, el.content_length = 0, 0
	el.kind = .None
	el.vw, el.vh = 0, 0
}

// HTML "media element load algorithm", and the resource selection algorithm after it.
@(private)
media_load :: proc(el: ^Media_Element) {
	p := el.page
	if p.closed { return }
	st := &p.settings.media
	had_resource := el.network_state != NETWORK_EMPTY && (el.kind != .None || el.current_src != "")
	media_teardown(el)
	el.load_gen += 1
	// pending play() promises are rejected with AbortError
	for pr in el.pending_play { promise_reject(p, pr, i64(Api_Error.Abort), "AbortError: the play() request was interrupted by a new load request") }
	clear(&el.pending_play)
	if had_resource {
		media_fire(el, "emptied")
	}
	el.err_code = 0
	delete(el.err_message); el.err_message = ""
	el.fired = {}
	el.ready_state = HAVE_NOTHING
	el.seeking = false
	el.ended_flag = false
	el.waiting_fired = false
	el.duration = math.nan_f64()
	el.position = 0
	clear(&el.played)
	if !el.paused { el.paused = true }
	el.autoplay_ok = true
	delete(el.current_src); el.current_src = ""
	el.network_state = NETWORK_NO_SOURCE
	if !st.enabled {
		media_error(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "media is disabled (media.enabled)")
		return
	}
	// the candidate: the src attribute, else the <source> children in order
	el.network_state = NETWORK_LOADING
	media_fire(el, "loadstart")
	if v, ok := dom.get_attribute(p.doc, el.node, "src"); ok {
		el.source_node = base.NIL_HANDLE
		media_try(el, v, "")
		return
	}
	media_next_source(el, base.NIL_HANDLE)
}

// The next <source> child after `after` (NIL: the first) that can be tried.
@(private)
media_next_source :: proc(el: ^Media_Element, after: base.Handle) {
	p := el.page
	n := dom.get(p.doc, el.node)
	if n == nil { return }
	c := after == base.NIL_HANDLE ? n.first_child : dom.get(p.doc, after).next
	for c != base.NIL_HANDLE {
		cn := dom.get(p.doc, c)
		if cn == nil { break }
		if cn.kind == .Element && cn.name == "source" {
			src, has := dom.get_attribute(p.doc, c, "src")
			if has {
				typ, _ := dom.get_attribute(p.doc, c, "type")
				if typ == "" || media.type_support(typ, p.settings.media) != .No {
					el.source_node = c
					media_try(el, src, typ)
					return
				}
			}
			el.source_node = c
			media_fire_at(el, c, "error")
		}
		c = cn.next
	}
	// no usable candidate
	el.network_state = NETWORK_NO_SOURCE
	media_error(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "no supported source was found")
}

// One candidate resource: its URL resolved, the fetch started.
@(private)
media_try :: proc(el: ^Media_Element, raw: string, type: string) {
	p := el.page
	if strings.trim_space(raw) == "" {
		media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the src is empty")
		return
	}
	u, ok := url.parse(strings.trim_space(raw), &p.env.location, context.temp_allocator)
	if !ok {
		media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the src is not a valid URL")
		return
	}
	set_string(&el.current_src, u.href)
	// a Media Source's object URL (blob:...): no download, the source buffers fill the stores
	if strings.has_prefix(u.href, "blob:") {
		if media_source_attach_url(el, u.href) { return }
	}
	mode: fetch.Mode = .No_Cors
	cred: fetch.Credentials = .Include
	if co, has := dom.get_attribute(p.doc, el.node, "crossorigin"); has {
		mode = .Cors
		cred = strings.equal_fold(strings.trim_space(co), "use-credentials") ? .Include : .Same_Origin
	}
	el.kind = .Progressive
	el.task = fetch.start(p.loader, {
		request = {
			url = u.href, mode = mode, credentials = cred, destination = el.is_video ? .Video : .Audio, initiator = &p.env,
			max_body = p.settings.media.progressive_max,
		},
		on_event = media_fetch_event, user = el, scope = p.scope, collect = false,
	})
}

// The candidate failed: the next <source>, or the element's error.
@(private)
media_failed :: proc(el: ^Media_Element, code: i32, message: string) {
	if el.source_node != base.NIL_HANDLE {
		media_fire_at(el, el.source_node, "error")
		media_teardown_keep_gen(el)
		media_next_source(el, el.source_node)
		return
	}
	media_error(el, code, message)
}

@(private)
media_teardown_keep_gen :: proc(el: ^Media_Element) {
	gen := el.load_gen
	media_teardown(el)
	el.load_gen = gen
}

@(private)
media_error :: proc(el: ^Media_Element, code: i32, message: string) {
	p := el.page
	el.err_code = code
	set_string(&el.err_message, message)
	if code == MEDIA_ERR_SRC_NOT_SUPPORTED { el.network_state = NETWORK_NO_SOURCE } else { el.network_state = NETWORK_IDLE }
	for pr in el.pending_play { promise_reject(p, pr, i64(Api_Error.Not_Supported), fmt.tprintf("NotSupportedError: %s", message)) }
	clear(&el.pending_play)
	el.paused = true
	log(p, .Warn, fmt.tprintf("media: %s (%s)", message, el.current_src))
	media_fire(el, "error")
}

@(private)
media_has_attr :: proc(d: ^dom.Document, node: base.Handle, name: string) -> bool {
	_, ok := dom.get_attribute(d, node, name)
	return ok
}

@(private)
media_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	el := (^Media_Element)(user)
	p := el.page
	switch ev.kind {
	case .Response:
		r := ev.response
		if r.type != .Opaque && (r.status < 200 || r.status >= 300) {
			el.task = base.NIL_HANDLE
			fetch.cancel(p.loader, task)
			media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, fmt.tprintf("the server answered HTTP %d", r.status))
			return
		}
		if v, ok := http.get_header(r.headers, "content-length"); ok { el.content_length = parse_int_or(v, 0) }
	case .Data:
		media_feed(el, ev.data)
	case .Done:
		el.task = base.NIL_HANDLE
		el.download_done = true
		el.network_state = NETWORK_IDLE
		media_fire(el, "progress")
		media_fire(el, "suspend")
		if el.player != nil { media.player_set_source_ended(el.player, true) }
		media_update(el)
		if !el.got_tracks { media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the file has no media tracks this browser can play") }
	case .Failed:
		el.task = base.NIL_HANDLE
		if el.got_tracks {
			media_error(el, MEDIA_ERR_NETWORK, ev.detail != "" ? ev.detail : "the download failed")
		} else {
			media_failed(el, MEDIA_ERR_NETWORK, ev.detail != "" ? ev.detail : "the download failed")
		}
	}
}

@(private)
parse_int_or :: proc(s: string, fallback: int) -> int {
	v := 0
	any := false
	for c in strings.trim_space(s) {
		if c < '0' || c > '9' { break }
		v = v * 10 + int(c - '0')
		any = true
	}
	return any ? v : fallback
}

// Download bytes into the container parser.
@(private)
media_feed :: proc(el: ^Media_Element, data: []byte) {
	p := el.page
	if len(data) == 0 { return }
	if !el.sniffed {
		el.sniffed = true
		switch {
		case len(data) >= 4 && data[0] == 0x1A && data[1] == 0x45 && data[2] == 0xDF && data[3] == 0xA3: el.is_webm = true
		case len(data) >= 8:
		case: el.sniffed = false; return   // (needs a few bytes more: delivered chunks are not that small in practice)
		}
		sink := media.Demux_Sink{user = el, tracks = media_sink_tracks, sample = media_sink_sample}
		if el.is_webm {
			el.webm = new(media.Webm_Demuxer)
			media.webm_init(el.webm, sink)
		} else {
			el.mp4 = new(media.Mp4_Demuxer)
			lim := media.MP4_LIMITS_DEFAULT
			lim.max_retain_bytes = p.settings.media.progressive_max
			media.mp4_init(el.mp4, sink, lim)
		}
	}
	el.downloaded += len(data)
	err: media.Parse_Error
	if el.is_webm { err = media.webm_feed(el.webm, data) } else { err = media.mp4_feed(el.mp4, data) }
	if err != .None {
		if el.task != base.NIL_HANDLE { fetch.cancel(p.loader, el.task); el.task = base.NIL_HANDLE }
		if el.got_tracks { media_error(el, MEDIA_ERR_DECODE, "the media file is damaged") } else { media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the file is not a supported media file") }
		return
	}
	if el.player != nil { media.player_wake(el.player) }
	now := page_now_ms(p)
	if now - el.last_progress >= p.settings.media.progress_ms {
		el.last_progress = now
		media_fire(el, "progress")
	}
	media_update(el)
}

@(private)
media_sink_tracks :: proc(user: rawptr, tracks: []media.Track, duration: media.Time) {
	el := (^Media_Element)(user)
	p := el.page
	if el.got_tracks { return }   // (a second moov: ignored)
	st := p.settings.media
	for t, i in tracks {
		switch t.kind {
		case .Video:
			if el.vtrack < 0 && el.is_video && media.codec_supported(t.codec, st) { el.vtrack = i }
		case .Audio:
			if el.atrack < 0 && media.codec_supported(t.codec, st) { el.atrack = i }
		case .Other:
		}
	}
	if el.vtrack < 0 && el.atrack < 0 { return }   // nothing playable: media_fetch_event reports it
	el.got_tracks = true
	if el.vtrack >= 0 {
		el.vstore = media.store_create()
		media.store_set_config(el.vstore, 1, tracks[el.vtrack])
		el.vinfo, el.has_vinfo = media.track_clone(tracks[el.vtrack]), true
		w, h := tracks[el.vtrack].display_width, tracks[el.vtrack].display_height
		if w == 0 { w, h = tracks[el.vtrack].width, tracks[el.vtrack].height }
		if tracks[el.vtrack].rotation == 90 || tracks[el.vtrack].rotation == 270 { w, h = h, w }
		el.vw, el.vh = w, h
	}
	if el.atrack >= 0 {
		el.astore = media.store_create()
		media.store_set_config(el.astore, 1, tracks[el.atrack])
		el.ainfo, el.has_ainfo = media.track_clone(tracks[el.atrack]), true
	}
	if duration > 0 { el.duration = media.time_seconds(duration) }
	media_make_player(el)
	images_init(p)
	p.images.sizes = next_serial()   // (layout reads the natural size of the video again)
	el.network_state = NETWORK_LOADING
	el.ready_state = HAVE_METADATA
	media_fire(el, "durationchange")
	media_fire(el, "loadedmetadata")
	el.fired += {.Loadedmetadata}
	if el.is_video { media_fire(el, "resize") }
}

@(private)
media_sink_sample :: proc(user: rawptr, track: int, s: media.Sample) {
	el := (^Media_Element)(user)
	switch {
	case track == el.vtrack && el.vstore != nil: media.store_append(el.vstore, s)
	case track == el.atrack && el.astore != nil: media.store_append(el.astore, s)
	case:
		smp := s
		media.sample_destroy(&smp)
	}
}

@(private)
media_make_player :: proc(el: ^Media_Element) {
	p := el.page
	if el.player != nil { return }
	el.player = media.player_create(el.vstore, el.astore, p.settings.media.player, media_player_notify, el)
	media.player_set_volume(el.player, f32(el.volume), el.muted)
	if el.rate != 1 { media.player_set_rate(el.player, el.rate) }
	// the position the element holds (a seek before the metadata) is where playback starts
	if el.position > 0 { media.player_seek(el.player, media.seconds_time(el.position)) }
}

// Called by the player from any of its threads.
@(private)
media_player_notify :: proc(user: rawptr) {
	el := (^Media_Element)(user)
	p := el.page
	tok := new(Media_Notice)
	tok^ = Media_Notice{page_id = p.web.id, node = el.node, serial = el.serial}
	host.post(p.loop, proc(d: rawptr) {
		tok := (^Media_Notice)(d)
		defer free(tok)
		p := page_by_id(tok.page_id)
		if p == nil || p.closed || p.media == nil { return }
		el, ok := p.media.elements[tok.node]
		if !ok || el.serial != tok.serial { return }
		if el.player != nil { media.player_seen(el.player) }
		media_update(el)
	}, tok)
}

////////////////////////////////
// Events

@(private)
media_fire :: proc(el: ^Media_Element, type: string) {
	queue_element_event(el.page, el.node, type)
}

@(private)
media_fire_at :: proc(el: ^Media_Element, node: base.Handle, type: string) {
	queue_element_event(el.page, node, type)
}

////////////////////////////////
// Looking at the player

// How much is buffered ahead of `t`, in seconds, over the tracks that play.
@(private)
media_buffered_ahead :: proc(el: ^Media_Element, t: f64) -> f64 {
	gap := p_settings(el).gap_tolerance
	ahead := math.inf_f64(1)
	any := false
	tt := media.seconds_time(t)
	if el.vstore != nil { ahead = min(ahead, media.time_seconds(media.store_buffered_ahead(el.vstore, tt, gap))); any = true }
	if el.astore != nil { ahead = min(ahead, media.time_seconds(media.store_buffered_ahead(el.astore, tt, gap))); any = true }
	if !any { return 0 }
	return ahead
}

@(private)
p_settings :: proc(el: ^Media_Element) -> ^media.Settings { return &el.page.settings.media }

// What an element is told when something changed: readyState, events, the end.
media_update :: proc(el: ^Media_Element) {
	p := el.page
	if p.closed || el.player == nil { return }
	st := &p.settings.media
	media.player_tick(el.player)
	playing, stalled, ended, perr := media.player_state(el.player)
	t := media.time_seconds(media.player_time(el.player))
	if perr != .None && el.err_code == 0 {
		switch perr {
		case .No_Video_Decoder, .No_Audio_Decoder: media_error(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "no decoder for this media")
		case .Decode_Failed: media_error(el, MEDIA_ERR_DECODE, "the media could not be decoded")
		case .Audio_Lost: media_error(el, MEDIA_ERR_DECODE, "the audio device is gone")
		case .None:
		}
		return
	}
	// a seek finished
	if el.seeking && media.player_seek_done(el.player) {
		el.seeking = false
		el.position = media.time_seconds(media.player_time(el.player))
		media_fire(el, "timeupdate")
		media_fire(el, "seeked")
	}
	// readyState
	old := el.ready_state
	if el.got_tracks {
		ahead := media_buffered_ahead(el, t)
		have_picture := !el.is_video || el.vstore == nil || media.player_has_picture(el.player)
		complete := el.download_done || (el.ms != nil && media_source_ended(el))
		dur := el.duration
		at_end := !math.is_nan(dur) && !math.is_inf(dur) && t >= dur - 0.05
		rs: i32 = HAVE_METADATA
		if have_picture && (ahead > 0 || complete) { rs = HAVE_CURRENT_DATA }
		if have_picture && (ahead * 1e9 >= f64(st.future_ahead) || at_end || (complete && ahead > 0)) && !stalled { rs = HAVE_FUTURE_DATA }
		if rs == HAVE_FUTURE_DATA && (ahead * 1e9 >= f64(st.enough_ahead) || complete || at_end) { rs = HAVE_ENOUGH_DATA }
		if el.seeking { rs = HAVE_METADATA }   // (a seek: back to the metadata until the new position has data)
		el.ready_state = rs
	}
	media_ready_events(el, old, el.ready_state, playing, stalled)
	// playing state
	if !el.paused && !ended {
		if stalled && !el.waiting_fired && el.ready_state <= HAVE_CURRENT_DATA {
			el.waiting_fired = true
			media_fire(el, "waiting")
		}
	}
	// timeupdate and played ranges
	now := page_now_ms(p)
	if playing && !el.paused {
		if now - el.last_timeupdate >= st.timeupdate_ms {
			el.last_timeupdate = now
			el.position = t
			media_fire(el, "timeupdate")
			media_note_played(el, el.last_position, t)
			el.last_position = t
		}
		media_arm_timer(el)
	}
	// the end
	if ended && !el.ended_flag && !el.paused {
		el.position = math.is_nan(el.duration) ? t : max(t, el.duration)
		if el.duration > 0 && !math.is_nan(el.duration) && !math.is_inf(el.duration) { el.position = el.duration }
		media_note_played(el, el.last_position, el.position)
		if media_has_attr(p.doc, el.node, "loop") {
			media_seek(el, 0)
			media.player_play(el.player)
		} else {
			el.ended_flag = true
			el.paused = true
			media_fire(el, "timeupdate")
			media_fire(el, "pause")
			media_fire(el, "ended")
		}
	}
	// autoplay
	if el.paused && el.autoplay_ok && el.ready_state == HAVE_ENOUGH_DATA && media_has_attr(p.doc, el.node, "autoplay") && !el.ended_flag {
		el.autoplay_ok = false
		if media_autoplay_allowed(el) {
			el.paused = false
			media_fire(el, "play")
			media_fire(el, "playing")
			media.player_play(el.player)
			media_arm_timer(el)
		}
	}
	el.frames_total = media.player_stats(el.player).decoded
}

@(private)
media_note_played :: proc(el: ^Media_Element, from, to: f64) {
	if to <= from { return }
	n := len(el.played)
	if n > 0 && from <= el.played[n - 1][1] + 0.5 && to >= el.played[n - 1][0] {
		el.played[n - 1][1] = max(el.played[n - 1][1], to)
		el.played[n - 1][0] = min(el.played[n - 1][0], from)
	} else {
		append(&el.played, [2]f64{from, to})
	}
}

// loadeddata, canplay, playing, canplaythrough, as the ready state moves.
@(private)
media_ready_events :: proc(el: ^Media_Element, old, now: i32, playing, stalled: bool) {
	if now >= HAVE_CURRENT_DATA && .Loadeddata not_in el.fired {
		el.fired += {.Loadeddata}
		media_fire(el, "loadeddata")
	}
	if now >= HAVE_FUTURE_DATA && old < HAVE_FUTURE_DATA {
		if .Canplay not_in el.fired || !el.paused || true {
			media_fire(el, "canplay")
			el.fired += {.Canplay}
		}
		if !el.paused {
			// playback was waiting for data: it plays
			if el.waiting_fired || len(el.pending_play) > 0 {
				el.waiting_fired = false
				media_fire(el, "playing")
				media_resolve_play(el)
			}
		}
	}
	if now == HAVE_ENOUGH_DATA && .Canplaythrough not_in el.fired {
		el.fired += {.Canplaythrough}
		media_fire(el, "canplaythrough")
	}
	if now < HAVE_FUTURE_DATA && old >= HAVE_FUTURE_DATA && !el.paused && !el.ended_flag {
		// ("waiting" is fired by the stall itself)
	}
}

@(private)
media_resolve_play :: proc(el: ^Media_Element) {
	for pr in el.pending_play { promise_resolve(el.page, pr, 0) }
	clear(&el.pending_play)
}

@(private)
media_arm_timer :: proc(el: ^Media_Element) {
	p := el.page
	if el.timer != base.NIL_HANDLE { return }
	el.timer = host.set_timer(p.loop, max(p.settings.media.timeupdate_ms / 2, 8), 0, proc(data: rawptr) {
		tok := (^Media_Notice)(data)
		defer free(tok)
		p := page_by_id(tok.page_id)
		if p == nil || p.closed || p.media == nil { return }
		el, ok := p.media.elements[tok.node]
		if !ok || el.serial != tok.serial { return }
		el.timer = base.NIL_HANDLE
		media_update(el)
	}, new_clone(Media_Notice{page_id = p.web.id, node = el.node, serial = el.serial}), p.scope)
}

@(private)
media_autoplay_allowed :: proc(el: ^Media_Element) -> bool {
	p := el.page
	switch p.settings.media.autoplay {
	case .Allow_All: return true
	case .Block: return media_has_activation(p)
	case .Allow_Muted:
		if el.muted || el.volume == 0 { return true }
		return media_has_activation(p)
	}
	return false
}

// The page had a click or a key press (sticky activation).
@(private)
media_has_activation :: proc(p: ^Page) -> bool {
	return p.media != nil && p.media.activated
}

// A click or a key press in the page: autoplay with sound is allowed from now on (HTML sticky activation).
media_note_input :: proc(p: ^Page, ev: dom.Event) {
	switch ev.type {
	case "keydown": if ev.key == 27 { return }
	case "mousedown", "pointerdown", "touchend":
	case: return
	}
	media_pm(p).activated = true
}

////////////////////////////////
// Operations

@(private)
media_pause :: proc(el: ^Media_Element) {
	p := el.page
	if !el.paused {
		el.paused = true
		el.autoplay_ok = false
		for pr in el.pending_play { promise_reject(p, pr, i64(Api_Error.Abort), "AbortError: the play() request was interrupted by a call to pause()") }
		clear(&el.pending_play)
		if el.player != nil { media.player_pause(el.player); el.position = media.time_seconds(media.player_time(el.player)) }
		media_fire(el, "timeupdate")
		media_fire(el, "pause")
	}
	el.waiting_fired = false
}

@(private)
media_seek :: proc(el: ^Media_Element, t: f64) {
	p := el.page
	if el.ready_state == HAVE_NOTHING || el.player == nil {
		el.position = max(t, 0)   // (taken at the start of playback)
		return
	}
	target := t
	if !math.is_nan(el.duration) && !math.is_inf(el.duration) { target = min(target, el.duration) }
	target = max(target, 0)
	el.seeking = true
	el.ended_flag = false
	el.position = target
	el.last_position = target
	el.waiting_fired = false
	media_fire(el, "seeking")
	media.player_seek(el.player, media.seconds_time(target))
	if !el.paused { media.player_play(el.player) }
	media_arm_seek_poll(el)
	_ = p
}

// A seek finishes when the player says so; a timer looks until then.
@(private)
media_arm_seek_poll :: proc(el: ^Media_Element) { media_arm_timer(el) }

////////////////////////////////
// API (api/media_element.widl)

HTMLMediaElement_currentSrc :: proc(c: ^Call, e: Api_HTMLMediaElement) -> string { return e.data.current_src }
HTMLMediaElement_networkState :: proc(c: ^Call, e: Api_HTMLMediaElement) -> i32 { return e.data.network_state }
HTMLMediaElement_readyState :: proc(c: ^Call, e: Api_HTMLMediaElement) -> i32 { return e.data.ready_state }
HTMLMediaElement_seeking :: proc(c: ^Call, e: Api_HTMLMediaElement) -> bool { return e.data.seeking }
HTMLMediaElement_duration :: proc(c: ^Call, e: Api_HTMLMediaElement) -> f64 { return e.data.duration }
HTMLMediaElement_paused :: proc(c: ^Call, e: Api_HTMLMediaElement) -> bool { return e.data.paused }
HTMLMediaElement_ended :: proc(c: ^Call, e: Api_HTMLMediaElement) -> bool { return e.data.ended_flag }
HTMLMediaElement_defaultPlaybackRate :: proc(c: ^Call, e: Api_HTMLMediaElement) -> f64 { return e.data.default_rate }
HTMLMediaElement_playbackRate :: proc(c: ^Call, e: Api_HTMLMediaElement) -> f64 { return e.data.rate }
HTMLMediaElement_preservesPitch :: proc(c: ^Call, e: Api_HTMLMediaElement) -> bool { return e.data.preserves_pitch }
HTMLMediaElement_volume :: proc(c: ^Call, e: Api_HTMLMediaElement) -> f64 { return e.data.volume }
HTMLMediaElement_muted :: proc(c: ^Call, e: Api_HTMLMediaElement) -> bool { return e.data.muted }

HTMLMediaElement_currentTime :: proc(c: ^Call, e: Api_HTMLMediaElement) -> f64 {
	el := e.data
	if el.player != nil && el.ready_state > HAVE_NOTHING {
		if el.seeking { return el.position }
		return media.time_seconds(media.player_time(el.player))
	}
	return el.position
}

HTMLMediaElement_set_currentTime :: proc(c: ^Call, e: Api_HTMLMediaElement, value: f64) {
	if math.is_nan(value) || math.is_inf(value) { return }
	media_seek(e.data, value)
}

HTMLMediaElement_set_defaultPlaybackRate :: proc(c: ^Call, e: Api_HTMLMediaElement, value: f64) {
	el := e.data
	if value == el.default_rate { return }
	el.default_rate = value
	media_fire(el, "ratechange")
}

HTMLMediaElement_set_playbackRate :: proc(c: ^Call, e: Api_HTMLMediaElement, value: f64) {
	el := e.data
	if value == el.rate { return }
	el.rate = clamp(value, 0.0625, 16)
	if el.player != nil { media.player_set_rate(el.player, el.rate); el.seeking = true; media_arm_timer(el) }
	media_fire(el, "ratechange")
}

HTMLMediaElement_set_preservesPitch :: proc(c: ^Call, e: Api_HTMLMediaElement, value: bool) { e.data.preserves_pitch = value }

HTMLMediaElement_set_volume :: proc(c: ^Call, e: Api_HTMLMediaElement, value: f64) -> Api_Error {
	if value < 0 || value > 1 || math.is_nan(value) { return fail(c, .Index_Size, "The volume provided is outside the range [0, 1].") }
	el := e.data
	if value != el.volume {
		el.volume = value
		if el.player != nil { media.player_set_volume(el.player, f32(el.volume), el.muted) }
		media_fire(el, "volumechange")
	}
	return .None
}

HTMLMediaElement_set_muted :: proc(c: ^Call, e: Api_HTMLMediaElement, value: bool) {
	el := e.data
	if value != el.muted {
		el.muted = value
		if el.player != nil { media.player_set_volume(el.player, f32(el.volume), el.muted) }
		media_fire(el, "volumechange")
	}
}

HTMLMediaElement_load :: proc(c: ^Call, e: Api_HTMLMediaElement) { media_load(e.data) }
HTMLMediaElement_pause :: proc(c: ^Call, e: Api_HTMLMediaElement) { media_pause(e.data) }

HTMLMediaElement_canPlayType :: proc(c: ^Call, e: Api_HTMLMediaElement, type: string) -> string {
	switch media.type_support(type, c.page.settings.media) {
	case .Probably: return "probably"
	case .Maybe: return "maybe"
	case .No:
	}
	return ""
}

HTMLMediaElement_play :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	p := c.page
	pr := promise_create(p, c.owner)
	if el.err_code == MEDIA_ERR_SRC_NOT_SUPPORTED || (el.network_state == NETWORK_NO_SOURCE && el.load_gen > 0 && el.kind == .None && el.ms == nil && !media_has_attr(p.doc, el.node, "src") && !media_has_source_child(p, el.node)) {
		promise_reject(p, pr, i64(Api_Error.Not_Supported), "NotSupportedError: the media element has no supported source")
		return pr
	}
	if !media_autoplay_allowed(el) && el.paused {
		promise_reject(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: play() failed because the user didn't interact with the document first (media.autoplay.policy)")
		return pr
	}
	if el.network_state == NETWORK_EMPTY { media_load(el) }
	if el.ended_flag && el.player != nil { media_seek(el, 0) }
	if el.paused {
		el.paused = false
		el.autoplay_ok = false
		media_fire(el, "play")
		if el.player != nil { media.player_play(el.player); media_arm_timer(el) }
		if el.ready_state <= HAVE_CURRENT_DATA {
			el.waiting_fired = true
			media_fire(el, "waiting")
			append(&el.pending_play, pr)
		} else {
			media_fire(el, "playing")
			promise_resolve(p, pr, 0)
		}
	} else if el.ready_state <= HAVE_CURRENT_DATA {
		append(&el.pending_play, pr)
	} else {
		promise_resolve(p, pr, 0)
	}
	return pr
}

HTMLVideoElement_videoWidth :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u32 { return u32(e.data.vw) }
HTMLVideoElement_videoHeight :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u32 { return u32(e.data.vh) }

////////////////////////////////
// TimeRanges, MediaError, VideoPlaybackQuality

Time_Ranges :: struct { ranges: [dynamic][2]f64 }

time_ranges_vt := Object_VTable{
	name = "TimeRanges",
	destroy = proc(p: ^Page, data: rawptr) {
		t := (^Time_Ranges)(data)
		delete(t.ranges)
		free(t)
	},
}

lookup_TimeRanges :: proc(c: ^Call, h: u64) -> ^Time_Ranges { return (^Time_Ranges)(object_data(c.page, h, &time_ranges_vt)) }

@(private)
make_time_ranges :: proc(c: ^Call, ranges: [][2]f64) -> u64 {
	t := new(Time_Ranges)
	for r in ranges { append(&t.ranges, r) }
	return object_create(c.page, &time_ranges_vt, t, c.owner)
}

TimeRanges_length :: proc(c: ^Call, r: Api_TimeRanges) -> u32 { return u32(len(r.data.ranges)) }

TimeRanges_start :: proc(c: ^Call, r: Api_TimeRanges, index: u32) -> (f64, Api_Error) {
	if int(index) >= len(r.data.ranges) { return 0, fail(c, .Index_Size, "The index provided is greater than or equal to the number of ranges.") }
	return r.data.ranges[index][0], .None
}

TimeRanges_end :: proc(c: ^Call, r: Api_TimeRanges, index: u32) -> (f64, Api_Error) {
	if int(index) >= len(r.data.ranges) { return 0, fail(c, .Index_Size, "The index provided is greater than or equal to the number of ranges.") }
	return r.data.ranges[index][1], .None
}

// The ranges (seconds) the tracks that play have in common.
@(private)
media_buffered_ranges :: proc(el: ^Media_Element) -> [][2]f64 {
	gap := el.page.settings.media.gap_tolerance
	out := make([dynamic][2]f64, context.temp_allocator)
	var_a, var_b: []media.Range
	if el.vstore != nil { var_a = media.store_ranges(el.vstore, gap, context.temp_allocator) }
	if el.astore != nil { var_b = media.store_ranges(el.astore, gap, context.temp_allocator) }
	switch {
	case el.vstore != nil && el.astore != nil:
		// the intersection
		for a in var_a {
			for b in var_b {
				s, e := max(a.start, b.start), min(a.end, b.end)
				if e > s { append(&out, [2]f64{media.time_seconds(s), media.time_seconds(e)}) }
			}
		}
	case el.vstore != nil: for a in var_a { append(&out, [2]f64{media.time_seconds(a.start), media.time_seconds(a.end)}) }
	case el.astore != nil: for b in var_b { append(&out, [2]f64{media.time_seconds(b.start), media.time_seconds(b.end)}) }
	}
	slice.sort_by(out[:], proc(a, b: [2]f64) -> bool { return a[0] < b[0] })
	return out[:]
}

HTMLMediaElement_buffered :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	if el.ms != nil { return make_time_ranges(c, media_source_buffered(el)) }
	return make_time_ranges(c, media_buffered_ranges(el))
}

HTMLMediaElement_played :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	return make_time_ranges(c, e.data.played[:])
}

HTMLMediaElement_seekable :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	if !el.got_tracks { return make_time_ranges(c, nil) }
	if el.ms != nil { return make_time_ranges(c, media_source_seekable(el)) }
	end := el.duration
	if math.is_nan(end) || math.is_inf(end) {
		r := media_buffered_ranges(el)
		return make_time_ranges(c, r)
	}
	// a progressive file is seekable over what is downloaded
	r := media_buffered_ranges(el)
	if el.download_done { r = {{0, end}} }
	return make_time_ranges(c, r)
}

Media_Error_Object :: struct { code: u32, message: string }

media_error_vt := Object_VTable{
	name = "MediaError",
	destroy = proc(p: ^Page, data: rawptr) {
		m := (^Media_Error_Object)(data)
		delete(m.message)
		free(m)
	},
}

lookup_MediaError :: proc(c: ^Call, h: u64) -> ^Media_Error_Object { return (^Media_Error_Object)(object_data(c.page, h, &media_error_vt)) }

HTMLMediaElement_error :: proc(c: ^Call, e: Api_HTMLMediaElement) -> (u64, Api_Error) {
	el := e.data
	if el.err_code == 0 { return 0, .Not_Found }
	m := new(Media_Error_Object)
	m.code, m.message = u32(el.err_code), strings.clone(el.err_message)
	return object_create(c.page, &media_error_vt, m, c.owner), .None
}

MediaError_code :: proc(c: ^Call, e: Api_MediaError) -> u32 { return e.data.code }
MediaError_message :: proc(c: ^Call, e: Api_MediaError) -> string { return e.data.message }

Video_Quality_Object :: struct { creation: f64, dropped, total: u32 }

video_quality_vt := Object_VTable{
	name = "VideoPlaybackQuality",
	destroy = proc(p: ^Page, data: rawptr) { free((^Video_Quality_Object)(data)) },
}

lookup_VideoPlaybackQuality :: proc(c: ^Call, h: u64) -> ^Video_Quality_Object { return (^Video_Quality_Object)(object_data(c.page, h, &video_quality_vt)) }

HTMLVideoElement_getVideoPlaybackQuality :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	q := new(Video_Quality_Object)
	q.creation = page_now_ms(c.page)
	if el.player != nil {
		s := media.player_stats(el.player)
		q.total, q.dropped = u32(s.decoded), u32(s.dropped)
	}
	return object_create(c.page, &video_quality_vt, q, c.owner)
}

VideoPlaybackQuality_creationTime :: proc(c: ^Call, q: Api_VideoPlaybackQuality) -> f64 { return q.data.creation }
VideoPlaybackQuality_droppedVideoFrames :: proc(c: ^Call, q: Api_VideoPlaybackQuality) -> u32 { return q.data.dropped }
VideoPlaybackQuality_totalVideoFrames :: proc(c: ^Call, q: Api_VideoPlaybackQuality) -> u32 { return q.data.total }
VideoPlaybackQuality_corruptedVideoFrames :: proc(c: ^Call, q: Api_VideoPlaybackQuality) -> u32 { return 0 }
VideoPlaybackQuality_totalFrameDelay :: proc(c: ^Call, q: Api_VideoPlaybackQuality) -> f64 { return 0 }

////////////////////////////////
// The shell

Media_View :: struct {
	frame:    ^media.Video_Frame,   // the picture to show (valid until the next call), nil: nothing decoded
	changed:  bool,                  // it is not the one the last call returned
	width, height: int,              // the video's size (rotation applied)
	ready:    bool,                  // the metadata is known
	paused:   bool,
	ended:    bool,
	position, duration: f64,
	buffered_end: f64,
	volume:   f64,
	muted:    bool,
	stalled:  bool,
	next_due_ns: i64,                // until the next picture is due (< 0: none known)
	has_audio: bool,
	hardware: bool,
	decoder:  string,
	dropped, decoded: int,
}

// What the shell paints for a <video>: the current picture and the state its controls show.
media_view :: proc(p: ^Page, node: base.Handle, present := true) -> (v: Media_View, ok: bool) {
	if p == nil || p.closed || p.media == nil { return {}, false }
	el, found := p.media.elements[node]
	if !found { return {}, false }
	v.width, v.height = el.vw, el.vh
	v.ready = el.ready_state >= HAVE_METADATA
	v.paused, v.ended = el.paused, el.ended_flag
	v.duration = el.duration
	v.volume, v.muted = el.volume, el.muted
	v.has_audio = el.astore != nil
	v.next_due_ns = -1
	if el.player == nil { return v, true }
	media.player_tick(el.player)
	if present { v.frame, v.changed = media.player_present(el.player) }
	v.position = media.time_seconds(media.player_time(el.player))
	if el.seeking { v.position = el.position }
	_, v.stalled, _, _ = media.player_state(el.player)
	if due, has := media.player_next_due(el.player); has { v.next_due_ns = due }
	s := media.player_stats(el.player)
	v.hardware, v.decoder, v.dropped, v.decoded = s.hardware, s.decoder, s.dropped, s.decoded
	if v.frame != nil && v.changed { el.paint_gen += 1 }
	return v, true
}

// The shell's "is this a playing video": the intrinsic size for layout, from the metadata.
media_intrinsic :: proc(p: ^Page, node: base.Handle) -> (w, h: f32, ok: bool) {
	if p == nil || p.media == nil { return 0, 0, false }
	el, found := p.media.elements[node]
	if !found || el.vw <= 0 || el.vh <= 0 { return 0, 0, false }
	return f32(el.vw), f32(el.vh), true
}

// Play / pause / seek / volume from the shell's controls (the same operations a script does).
media_control :: proc(p: ^Page, node: base.Handle, action: Media_Action, value: f64 = 0) {
	if p == nil || p.media == nil { return }
	el, found := p.media.elements[node]
	if !found { return }
	switch action {
	case .Toggle_Play:
		if el.paused {
			if el.ended_flag { media_seek(el, 0) }
			el.paused = false
			el.autoplay_ok = false
			media_fire(el, "play")
			if el.player != nil { media.player_play(el.player); media_arm_timer(el) }
			if el.ready_state <= HAVE_CURRENT_DATA { el.waiting_fired = true; media_fire(el, "waiting") } else { media_fire(el, "playing") }
		} else {
			media_pause(el)
		}
	case .Seek: media_seek(el, value)
	case .Set_Volume:
		el.volume = clamp(value, 0, 1)
		if el.player != nil { media.player_set_volume(el.player, f32(el.volume), el.muted) }
		media_fire(el, "volumechange")
	case .Toggle_Mute:
		el.muted = !el.muted
		if el.player != nil { media.player_set_volume(el.player, f32(el.volume), el.muted) }
		media_fire(el, "volumechange")
	}
}

Media_Action :: enum u8 { Toggle_Play, Seek, Set_Volume, Toggle_Mute }

// Whether any media element is playing (the shell keeps the frame loop awake for its pictures).
media_playing :: proc(p: ^Page) -> bool {
	if p == nil || p.media == nil { return false }
	for _, el in p.media.elements { if !el.paused && !el.ended_flag { return true } }
	return false
}

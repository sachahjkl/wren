package page

// Text tracks of a media element (api/media_tracks.widl, HTML §4.8.11.11 and the WebVTT model): TextTrackList,
// TextTrack, TextTrackCue / VTTCue, TextTrackCueList, the <track> element and addTextTrack. The WebVTT file is parsed
// natively (media.vtt_parse); a TextTrack is filled from the cues, their active set is tracked by the player's time
// (no script polling), and the shell draws the showing tracks' active cues over the video (video_shell.odin).
//
// Everything is a host object. TextTrack and TextTrackCue are EventTargets (cuechange on a track; enter / exit on a
// cue). A <track> element drives one TextTrack: loading its src, the readyState and the load / error events.

import "core:math"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:media"
import "wb:url"

Text_Track_Ready :: enum u8 { None = 0, Loading = 1, Loaded = 2, Error = 3 }
Text_Track_Mode :: enum u8 { Disabled, Hidden, Showing }

Text_Cue_Object :: struct {
	page:      ^Page,
	self:      u64,
	track:     ^Text_Track_Object,   // nil once removed
	id:        string,               // owned
	start, end: f64,                 // seconds (end may be +Inf)
	pause_on_exit: bool,
	text:      string,               // owned: the raw cue payload (cue.text)
	active:    bool,                 // currently in the active set (drives enter / exit)
	// VTT settings (used by the renderer and the VTTCue members)
	vtt:       media.Vtt_Cue,        // owned copy of the parsed cue (runs for rendering); empty for a plain TextTrackCue
	has_vtt:   bool,
}

Text_Track_Object :: struct {
	page:      ^Page,
	self:      u64,
	el_node:   base.Handle,          // the media element it belongs to
	el_serial: u64,
	track_node: base.Handle,         // the <track> element that drives it (NIL: an addTextTrack track)
	kind:      string,               // owned: "subtitles" / "captions" / ...
	label:     string,               // owned
	language:  string,               // owned
	id:        string,               // owned
	mode:      Text_Track_Mode,
	ready:     Text_Track_Ready,
	cues:      [dynamic]^Text_Cue_Object,
	cue_list, active_list: u64,      // the TextTrackCueList host objects (0: not made)
	fetch_task: base.Handle,         // the <track> src download (NIL: none)
	buf:       [dynamic]u8,          // the VTT bytes as they download
}

Text_Cue_List_Object :: struct {
	page:   ^Page,
	track:  ^Text_Track_Object,
	active: bool,
}

text_track_vt := Object_VTable{
	name = "TextTrack",
	destroy = proc(p: ^Page, data: rawptr) {
		// freed through text_track_destroy, which the element's teardown calls; a direct release (none happens today)
		// still frees the owned strings
		tt := (^Text_Track_Object)(data)
		text_track_free_fields(tt)
		free(tt)
	},
}

text_cue_vt := Object_VTable{
	name = "TextTrackCue",
	destroy = proc(p: ^Page, data: rawptr) {
		cue := (^Text_Cue_Object)(data)
		delete(cue.id); delete(cue.text)
		if cue.has_vtt { media.vtt_cue_destroy(&cue.vtt) }
		free(cue)
	},
}

text_cue_list_vt := Object_VTable{
	name = "TextTrackCueList",
	destroy = proc(p: ^Page, data: rawptr) { free((^Text_Cue_List_Object)(data)) },
}

lookup_TextTrackList :: proc(c: ^Call, h: u64) -> ^Track_List_Object { return (^Track_List_Object)(object_data(c.page, h, &track_list_vt)) }
lookup_TextTrack :: proc(c: ^Call, h: u64) -> ^Text_Track_Object { return (^Text_Track_Object)(object_data(c.page, h, &text_track_vt)) }
lookup_TextTrackCue :: proc(c: ^Call, h: u64) -> ^Text_Cue_Object { return (^Text_Cue_Object)(object_data(c.page, h, &text_cue_vt)) }
lookup_TextTrackCueList :: proc(c: ^Call, h: u64) -> ^Text_Cue_List_Object { return (^Text_Cue_List_Object)(object_data(c.page, h, &text_cue_list_vt)) }

@(private)
text_track_free_fields :: proc(tt: ^Text_Track_Object) {
	delete(tt.kind); delete(tt.label); delete(tt.language); delete(tt.id)
	delete(tt.cues)
	delete(tt.buf)
}

// Frees a text track and its cues / lists (the element's teardown). page_closing: the objects are destroyed wholesale.
@(private)
text_track_destroy :: proc(p: ^Page, tt: ^Text_Track_Object, page_closing: bool) {
	if tt.fetch_task != base.NIL_HANDLE { fetch.cancel(p.loader, tt.fetch_task); tt.fetch_task = base.NIL_HANDLE }
	if !page_closing {
		for cue in tt.cues { cue.track = nil; object_release(p, cue.self) }
		if tt.cue_list != 0 { object_release(p, tt.cue_list) }
		if tt.active_list != 0 { object_release(p, tt.active_list) }
		object_release(p, tt.self)
	}
	// text_track_vt.destroy frees the fields and the struct when the object is released (or at page close)
}

////////////////////////////////
// The text track list

HTMLMediaElement_textTracks :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	if el == nil || !c.page.settings.media.tracks { return 0 }
	mt := media_tracks(el)
	if mt.text_list == 0 { mt.text_list = object_create(c.page, &track_list_vt, new_clone(Track_List_Object{page = c.page, tracks = mt, kind = .Text}), c.owner) }
	return mt.text_list
}

TextTrackList_length :: proc(c: ^Call, list: Api_TextTrackList) -> u32 { return list.data == nil ? 0 : u32(len(list.data.tracks.text)) }

TextTrackList_item :: proc(c: ^Call, list: Api_TextTrackList, index: u32) -> (u64, Api_Error) {
	if list.data == nil || int(index) >= len(list.data.tracks.text) { return 0, .Not_Found }
	return list.data.tracks.text[index].self, .None
}

TextTrackList_getTrackById :: proc(c: ^Call, list: Api_TextTrackList, id: string) -> u64 {
	if list.data == nil { return 0 }
	for t in list.data.tracks.text { if t.id == id { return t.self } }
	return 0
}

////////////////////////////////
// addTextTrack and the <track> element

// element.addTextTrack(kind, label, language): a script-made text track (HTML).
HTMLMediaElement_addTextTrack :: proc(c: ^Call, e: Api_HTMLMediaElement, kind, label, language: string) -> (u64, Api_Error) {
	el := e.data
	if el == nil || !c.page.settings.media.tracks { return 0, fail(c, .Not_Supported, "text tracks are disabled (media.tracks.enabled)") }
	// kind is a TextTrackKind Web IDL enum: an unknown value (including a wrong case, or the "undefined"/"null"
	// strings a missing/null argument converts to) is a TypeError, not a silent default.
	if !is_text_track_kind(kind) { return 0, fail(c, .Type, "Failed to execute 'addTextTrack' on 'HTMLMediaElement': The provided value is not a valid enum value of type TextTrackKind.") }
	tt := text_track_new(el, kind, label, language, base.NIL_HANDLE)
	tt.mode = .Hidden   // addTextTrack starts hidden (HTML)
	tt.ready = .Loaded
	text_track_added(el, tt)
	return tt.self, .None
}

// Makes a TextTrack object (not yet in the element's list).
@(private)
text_track_new :: proc(el: ^Media_Element, kind, label, language: string, track_node: base.Handle) -> ^Text_Track_Object {
	p := el.page
	tt := new(Text_Track_Object)
	tt.page = p
	tt.el_node, tt.el_serial = el.node, el.serial
	tt.track_node = track_node
	tt.kind = strings.clone(text_track_kind(kind))
	tt.label = strings.clone(label)
	tt.language = strings.clone(language)
	tt.id = strings.clone("")
	tt.cues = make([dynamic]^Text_Cue_Object)
	tt.self = object_create(p, &text_track_vt, tt, media_tracks_owner(p))
	return tt
}

@(private)
text_track_kind :: proc(k: string) -> string {
	switch k {
	case "subtitles", "captions", "descriptions", "chapters", "metadata": return k
	}
	return "subtitles"   // HTML: an unknown kind on a <track> becomes "metadata", on addTextTrack it is validated by Web IDL; default to subtitles
}

// Exactly the TextTrackKind Web IDL enum values (case-sensitive), for addTextTrack's argument validation.
@(private)
is_text_track_kind :: proc(k: string) -> bool {
	switch k {
	case "subtitles", "captions", "descriptions", "chapters", "metadata": return true
	}
	return false
}

// Adds a finished track to the element's list and fires addtrack.
@(private)
text_track_added :: proc(el: ^Media_Element, tt: ^Text_Track_Object) {
	mt := media_tracks(el)
	append(&mt.text, tt)
	if mt.text_list != 0 { track_fire(el.page, mt.text_list, "addtrack") }
}

// A <track> element was inserted into a media element (media_note_inserted hooks here): make its text track and load it.
@(private)
media_track_element_added :: proc(p: ^Page, media_node, track_node: base.Handle) {
	if !p.settings.media.tracks { return }
	el := media_element(p, media_node)
	if el == nil { return }
	// one TextTrack per <track>; a second insertion of the same node is ignored
	if el.tracks != nil { for tt in el.tracks.text { if tt.track_node == track_node { return } } }
	kind, _ := dom.get_attribute(p.doc, track_node, "kind")
	label, _ := dom.get_attribute(p.doc, track_node, "label")
	lang, _ := dom.get_attribute(p.doc, track_node, "srclang")
	tt := text_track_new(el, kind == "" ? "subtitles" : kind, label, lang, track_node)
	// a default track is showing when nothing else is yet (HTML "honor user preferences for automatic text track selection")
	if media_has_attr(p.doc, track_node, "default") { tt.mode = .Showing }
	text_track_added(el, tt)
	text_track_load(p, tt)
}

// The src of the <track> is fetched and parsed as WebVTT.
@(private)
text_track_load :: proc(p: ^Page, tt: ^Text_Track_Object) {
	if tt.track_node == base.NIL_HANDLE { return }
	src, ok := dom.get_attribute(p.doc, tt.track_node, "src")
	if !ok || strings.trim_space(src) == "" {
		text_track_set_ready(p, tt, .Error)
		return
	}
	u, uok := url.parse(strings.trim_space(src), &p.env.location, context.temp_allocator)
	if !uok { text_track_set_ready(p, tt, .Error); return }
	tt.ready = .Loading
	clear(&tt.buf)
	// <track> fetch: CORS, no credentials (the track crossorigin rules); destination Empty avoids touching the fetch hub
	tt.fetch_task = fetch.start(p.loader, {
		request = {
			url = u.href, mode = .Cors, credentials = .Same_Origin, destination = .Empty, initiator = &p.env,
		},
		on_event = text_track_fetch_event, user = tt, scope = p.scope, collect = false,
	})
}

@(private)
text_track_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	tt := (^Text_Track_Object)(user)
	p := tt.page
	switch ev.kind {
	case .Response:
		r := ev.response
		if r.type != .Opaque && (r.status < 200 || r.status >= 300) {
			tt.fetch_task = base.NIL_HANDLE
			fetch.cancel(p.loader, task)
			text_track_set_ready(p, tt, .Error)
		}
	case .Data:
		append(&tt.buf, ..ev.data)
	case .Done:
		tt.fetch_task = base.NIL_HANDLE
		text_track_parse(p, tt, string(tt.buf[:]))
		text_track_set_ready(p, tt, .Loaded)
	case .Failed:
		tt.fetch_task = base.NIL_HANDLE
		text_track_set_ready(p, tt, .Error)
	}
}

// Parses the downloaded WebVTT into the track's cues.
@(private)
text_track_parse :: proc(p: ^Page, tt: ^Text_Track_Object, text: string) {
	f := media.vtt_parse(text)
	defer media.vtt_destroy(&f)
	if !f.ok { return }
	for &vc in f.cues {
		cue := new(Text_Cue_Object)
		cue.page = p
		cue.track = tt
		cue.id = strings.clone(vc.id)
		cue.start = media.time_seconds(vc.start)
		cue.end = media.time_seconds(vc.end)
		cue.text = strings.clone(vc.raw)
		cue.vtt = media_vtt_cue_clone(vc)   // owns its own copy; f is destroyed here
		cue.has_vtt = true
		cue.self = object_create(p, &text_cue_vt, cue, media_tracks_owner(p))
		append(&tt.cues, cue)
	}
}

// A deep copy of a parsed cue, owned by the Text_Cue_Object (so vtt_destroy of the parse result does not take it).
@(private)
media_vtt_cue_clone :: proc(c: media.Vtt_Cue) -> media.Vtt_Cue {
	al := base.process_allocator()
	out := c
	out.id = strings.clone(c.id, al)
	out.region = strings.clone(c.region, al)
	out.raw = strings.clone(c.raw, al)
	runs := make([]media.Vtt_Run, len(c.runs), al)
	for r, i in c.runs {
		nr := r
		nr.text = strings.clone(r.text, al)
		nr.voice = strings.clone(r.voice, al)
		nr.lang = strings.clone(r.lang, al)
		cls := make([]string, len(r.classes), al)
		for s, j in r.classes { cls[j] = strings.clone(s, al) }
		nr.classes = cls
		runs[i] = nr
	}
	out.runs = runs
	return out
}

@(private)
text_track_set_ready :: proc(p: ^Page, tt: ^Text_Track_Object, ready: Text_Track_Ready) {
	tt.ready = ready
	// the <track> element's load / error events
	if tt.track_node != base.NIL_HANDLE {
		queue_element_event(p, tt.track_node, ready == .Error ? "error" : "load")
	}
	// the showing track just got its cues: the element re-evaluates active cues and repaints
	if el := text_track_element(p, tt); el != nil { media_update(el) }
}

////////////////////////////////
// TextTrack members

TextTrack_kind :: proc(c: ^Call, t: Api_TextTrack) -> string { return t.data == nil ? "" : t.data.kind }
TextTrack_label :: proc(c: ^Call, t: Api_TextTrack) -> string { return t.data == nil ? "" : t.data.label }
TextTrack_language :: proc(c: ^Call, t: Api_TextTrack) -> string { return t.data == nil ? "" : t.data.language }
TextTrack_id :: proc(c: ^Call, t: Api_TextTrack) -> string { return t.data == nil ? "" : t.data.id }

TextTrack_mode :: proc(c: ^Call, t: Api_TextTrack) -> string {
	if t.data == nil { return "disabled" }
	switch t.data.mode {
	case .Disabled: return "disabled"
	case .Hidden: return "hidden"
	case .Showing: return "showing"
	}
	return "disabled"
}

TextTrack_set_mode :: proc(c: ^Call, t: Api_TextTrack, value: string) {
	tt := t.data
	if tt == nil { return }
	old := tt.mode
	switch value {
	case "disabled": tt.mode = .Disabled
	case "hidden": tt.mode = .Hidden
	case "showing": tt.mode = .Showing
	case: return
	}
	if tt.mode != old {
		if el := text_track_element(c.page, tt); el != nil { media_update(el) }
	}
}

TextTrack_cues :: proc(c: ^Call, t: Api_TextTrack) -> u64 {
	tt := t.data
	if tt == nil || tt.mode == .Disabled { return 0 }   // a disabled track exposes no cues (HTML)
	if tt.cue_list == 0 { tt.cue_list = object_create(c.page, &text_cue_list_vt, new_clone(Text_Cue_List_Object{page = c.page, track = tt, active = false}), c.owner) }
	return tt.cue_list
}

TextTrack_activeCues :: proc(c: ^Call, t: Api_TextTrack) -> u64 {
	tt := t.data
	if tt == nil || tt.mode == .Disabled { return 0 }
	if tt.active_list == 0 { tt.active_list = object_create(c.page, &text_cue_list_vt, new_clone(Text_Cue_List_Object{page = c.page, track = tt, active = true}), c.owner) }
	return tt.active_list
}

TextTrack_addCue :: proc(c: ^Call, t: Api_TextTrack, cue: Api_TextTrackCue) -> Api_Error {
	tt, cu := t.data, cue.data
	if tt == nil || cu == nil { return fail(c, .Invalid_State, "the text track or cue is gone") }
	if cu.track != nil && cu.track != tt {
		// the cue belongs to another track: remove it there first (HTML)
		text_cue_remove(c.page, cu.track, cu)
	}
	cu.track = tt
	append(&tt.cues, cu)
	if el := text_track_element(c.page, tt); el != nil { media_update(el) }
	return .None
}

TextTrack_removeCue :: proc(c: ^Call, t: Api_TextTrack, cue: Api_TextTrackCue) -> Api_Error {
	tt, cu := t.data, cue.data
	if tt == nil || cu == nil { return fail(c, .Invalid_State, "the text track or cue is gone") }
	if cu.track != tt { return fail(c, .Not_Found, "the cue is not in this text track") }
	text_cue_remove(c.page, tt, cu)
	return .None
}

@(private)
text_cue_remove :: proc(p: ^Page, tt: ^Text_Track_Object, cu: ^Text_Cue_Object) {
	for x, i in tt.cues {
		if x == cu { ordered_remove(&tt.cues, i); break }
	}
	cu.track = nil
	cu.active = false
	if el := text_track_element(p, tt); el != nil { media_update(el) }
}

////////////////////////////////
// TextTrackCue / VTTCue members

TextTrackCue_id :: proc(c: ^Call, cue: Api_TextTrackCue) -> string { return cue.data == nil ? "" : cue.data.id }
TextTrackCue_set_id :: proc(c: ^Call, cue: Api_TextTrackCue, value: string) { if cue.data != nil { set_string(&cue.data.id, value) } }
TextTrackCue_startTime :: proc(c: ^Call, cue: Api_TextTrackCue) -> f64 { return cue.data == nil ? 0 : cue.data.start }
TextTrackCue_endTime :: proc(c: ^Call, cue: Api_TextTrackCue) -> f64 { return cue.data == nil ? 0 : cue.data.end }
TextTrackCue_pauseOnExit :: proc(c: ^Call, cue: Api_TextTrackCue) -> bool { return cue.data == nil ? false : cue.data.pause_on_exit }

TextTrackCue_set_startTime :: proc(c: ^Call, cue: Api_TextTrackCue, value: f64) {
	if cue.data == nil || math.is_nan(value) { return }
	cue.data.start = value
	text_cue_touched(c.page, cue.data)
}

TextTrackCue_set_endTime :: proc(c: ^Call, cue: Api_TextTrackCue, value: f64) {
	if cue.data == nil { return }
	cue.data.end = value
	text_cue_touched(c.page, cue.data)
}

TextTrackCue_set_pauseOnExit :: proc(c: ^Call, cue: Api_TextTrackCue, value: bool) { if cue.data != nil { cue.data.pause_on_exit = value } }

// cue.track: the TextTrack it belongs to (0: none).
TextTrackCue_track :: proc(c: ^Call, cue: Api_TextTrackCue) -> u64 { return (cue.data != nil && cue.data.track != nil) ? cue.data.track.self : 0 }

// VTTCue extras (the cue payload and the main settings): the engine reads text; the rest feed the renderer.
VTTCue_text :: proc(c: ^Call, cue: Api_TextTrackCue) -> string { return cue.data == nil ? "" : cue.data.text }
VTTCue_set_text :: proc(c: ^Call, cue: Api_TextTrackCue, value: string) {
	if cue.data == nil { return }
	set_string(&cue.data.text, value)
	// a changed payload re-flattens the runs so the renderer shows the new text
	if cue.data.has_vtt { media.vtt_cue_destroy(&cue.data.vtt) }
	cue.data.vtt = media.vtt_cue_from_text(value)
	cue.data.has_vtt = true
}

// new VTTCue(startTime, endTime, text): a script-made cue (MediaObjects.c builds the object around this handle).
VTTCue_create :: proc(c: ^Call, start, end: f64, text: string) -> (u64, Api_Error) {
	cue := new(Text_Cue_Object)
	cue.page = c.page
	cue.start = math.is_nan(start) ? 0 : start
	cue.end = end
	cue.id = strings.clone("")
	cue.text = strings.clone(text)
	cue.vtt = media.vtt_cue_from_text(text)
	cue.has_vtt = true
	cue.self = object_create(c.page, &text_cue_vt, cue, c.owner)
	return cue.self, .None
}

@(private)
text_cue_touched :: proc(p: ^Page, cu: ^Text_Cue_Object) {
	if cu.track == nil { return }
	if el := text_track_element(p, cu.track); el != nil { media_update(el) }
}

////////////////////////////////
// TextTrackCueList

TextTrackCueList_length :: proc(c: ^Call, list: Api_TextTrackCueList) -> u32 {
	l := list.data
	if l == nil || l.track == nil { return 0 }
	if !l.active { return u32(len(l.track.cues)) }
	n := 0
	for cue in l.track.cues { if cue.active { n += 1 } }
	return u32(n)
}

TextTrackCueList_item :: proc(c: ^Call, list: Api_TextTrackCueList, index: u32) -> (u64, Api_Error) {
	l := list.data
	if l == nil || l.track == nil { return 0, .Not_Found }
	if !l.active {
		if int(index) >= len(l.track.cues) { return 0, .Not_Found }
		return l.track.cues[index].self, .None
	}
	i := 0
	for cue in l.track.cues {
		if !cue.active { continue }
		if i == int(index) { return cue.self, .None }
		i += 1
	}
	return 0, .Not_Found
}

TextTrackCueList_getCueById :: proc(c: ^Call, list: Api_TextTrackCueList, id: string) -> u64 {
	l := list.data
	if l == nil || l.track == nil || id == "" { return 0 }
	for cue in l.track.cues { if cue.id == id { return cue.self } }
	return 0
}

////////////////////////////////
// Active cue tracking (called from media_update by the player's time)

// Updates which cues of the element's showing / hidden tracks are active at `t` (seconds), fires enter / exit on cues
// and cuechange on tracks whose active set changed. Returns whether a showing track changed (the shell repaints).
@(private)
media_text_cues_update :: proc(el: ^Media_Element, t: f64) -> (showing_changed: bool) {
	p := el.page
	if el.tracks == nil { return false }
	for tt in el.tracks.text {
		if tt.mode == .Disabled { continue }
		changed := false
		for cue in tt.cues {
			now_active := t >= cue.start && t < cue.end
			if now_active == cue.active { continue }
			cue.active = now_active
			changed = true
			text_cue_fire(p, cue.self, now_active ? "enter" : "exit")
			if !now_active && cue.pause_on_exit && !el.paused { media_pause(el) }
		}
		if changed {
			text_cue_fire(p, tt.self, "cuechange")
			if tt.mode == .Showing { showing_changed = true }
		}
	}
	return
}

@(private)
text_cue_fire :: proc(p: ^Page, handle: u64, type: string) {
	if handle == 0 || p.closed || !object_has_listener(p, handle, type) { return }
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		ev := (^Mse_Event)(data)
		defer { delete(ev.type); free(ev) }
		if pg == nil || pg.closed { return }
		object_dispatch(pg, ev.handle, dom.Event{type = ev.type})
	}, new_clone(Mse_Event{handle, strings.clone(type)}))
}

////////////////////////////////
// What the shell draws (video_shell.odin): the active cues of the showing text tracks.

// One line of subtitle text for the shell, already flattened with its formatting.
Subtitle_Run :: struct {
	text:   string,         // borrowed from the cue (valid while the page lives and the cue is not replaced)
	bold:   bool,
	italic: bool,
	underline: bool,
}

Subtitle_Line :: struct {
	runs:  []Subtitle_Run,  // temp-allocated
	align: u8,              // 0 center, 1 start/left, 2 end/right
}

// The lines to paint over a <video>: the active cues of its showing text tracks, newest track last, each cue split into
// lines on its forced breaks. Empty when subtitles are off, there is no showing track, or nothing is active. The result
// is temp-allocated (valid for the frame).
media_subtitle_lines :: proc(p: ^Page, node: base.Handle) -> []Subtitle_Line {
	if p == nil || p.media == nil || !p.settings.media.subtitles { return nil }
	el, ok := p.media.elements[node]
	if !ok || el.tracks == nil { return nil }
	out := make([dynamic]Subtitle_Line, context.temp_allocator)
	limit := p.settings.media.subtitle_lines
	for tt in el.tracks.text {
		if tt.mode != .Showing { continue }
		for cue in tt.cues {
			if !cue.active || !cue.has_vtt { continue }
			line := make([dynamic]Subtitle_Run, context.temp_allocator)
			align: u8 = 0
			#partial switch cue.vtt.align {
			case .Start, .Left: align = 1
			case .End, .Right: align = 2
			}
			flush := proc(out: ^[dynamic]Subtitle_Line, line: ^[dynamic]Subtitle_Run, align: u8, limit: int) {
				if len(line) == 0 || len(out) >= limit { return }
				append(out, Subtitle_Line{runs = line[:], align = align})
			}
			for r in cue.vtt.runs {
				if r.newline {
					flush(&out, &line, align, limit)
					line = make([dynamic]Subtitle_Run, context.temp_allocator)
					continue
				}
				if r.rt { continue }   // ruby annotations are not drawn as a separate line
				append(&line, Subtitle_Run{text = r.text, bold = r.bold, italic = r.italic, underline = r.underline})
			}
			flush(&out, &line, align, limit)
		}
	}
	return out[:]
}

// The element a text track belongs to.
@(private)
text_track_element :: proc(p: ^Page, tt: ^Text_Track_Object) -> ^Media_Element {
	if p.media == nil { return nil }
	el, ok := p.media.elements[tt.el_node]
	if !ok || el.serial != tt.el_serial { return nil }
	return el
}

////////////////////////////////
// HTMLTrackElement

lookup_HTMLTrackElement :: proc(c: ^Call, h: u64) -> ^dom.Node {
	n := dom.get(c.page.doc, H(h))
	if n == nil || n.kind != .Element || n.name != "track" { return nil }
	return n
}

// The <track>'s TextTrack (track.track), made now if the element is not yet in a media element's list.
HTMLTrackElement_track :: proc(c: ^Call, t: Api_HTMLTrackElement) -> u64 {
	n := t.data
	if n == nil { return 0 }
	p := c.page
	parent := dom.get(p.doc, n.parent)
	if parent == nil { return 0 }
	if _, ok := is_media_node(parent); !ok { return 0 }
	el := media_element(p, n.parent)
	if el == nil || el.tracks == nil { return 0 }
	for tt in el.tracks.text { if tt.track_node == H(t.handle) { return tt.self } }
	return 0
}

HTMLTrackElement_readyState :: proc(c: ^Call, t: Api_HTMLTrackElement) -> i32 {
	n := t.data
	if n == nil { return 0 }
	p := c.page
	if p.media == nil { return 0 }
	el, ok := p.media.elements[n.parent]
	if !ok || el.tracks == nil { return 0 }
	for tt in el.tracks.text { if tt.track_node == H(t.handle) { return i32(tt.ready) } }
	return 0
}

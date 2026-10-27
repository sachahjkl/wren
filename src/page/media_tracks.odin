package page

// audioTracks / videoTracks of a media element (api/media_tracks.widl, HTML §4.8.11.10 "audio and video tracks").
// AudioTrackList and VideoTrackList are EventTargets (addtrack / removetrack / change); AudioTrack and VideoTrack are
// plain host objects. The tracks are built from what the container demuxer announced — the host already has every
// track's id, kind, codec and language (media.Track); it never walks the DOM. The chosen tracks (the ones the player
// decodes) start enabled / selected.
//
// Changing which audio track is enabled or which video track is selected is reflected to the player when it can honour
// it (media_player_select_*); for a progressive single-stream player today that is a no-op beyond the state the script
// reads, so the attributes behave exactly as the spec requires even where the decoder cannot switch mid-stream.
//
// The text track list lives alongside here (media_texttracks.odin) so that a media element's three track lists share
// one Media_Tracks and one teardown.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:media"

Track_Entry :: struct {
	self:     u64,          // this track's host object handle
	id:       string,       // owned
	kind:     string,       // owned (HTML "track kind": "main", "alternative", "captions", ...; we use codec-derived)
	label:    string,       // owned
	language: string,       // owned
	enabled:  bool,         // audio: the enabled flag; video: the selected flag
	index:    int,          // the container track index, for the player
}

Media_Tracks :: struct {
	el_node:   base.Handle,
	el_serial: u64,
	audio_list, video_list, text_list: u64,   // the EventTarget list objects (0: not made yet)
	audio:     [dynamic]^Track_Entry,
	video:     [dynamic]^Track_Entry,
	text:      [dynamic]^Text_Track_Object,    // media_texttracks.odin
}

Track_List_Object :: struct {
	page:  ^Page,
	tracks: ^Media_Tracks,
	kind:  Track_List_Kind,
}

Track_List_Kind :: enum u8 { Audio, Video, Text }

track_vt := Object_VTable{
	name = "MediaTrack",
	destroy = proc(p: ^Page, data: rawptr) {
		t := (^Track_Entry)(data)
		delete(t.id); delete(t.kind); delete(t.label); delete(t.language)
		free(t)
	},
}

track_list_vt := Object_VTable{
	name = "MediaTrackList",
	destroy = proc(p: ^Page, data: rawptr) { free((^Track_List_Object)(data)) },
}

lookup_AudioTrack :: proc(c: ^Call, h: u64) -> ^Track_Entry { return (^Track_Entry)(object_data(c.page, h, &track_vt)) }
lookup_VideoTrack :: proc(c: ^Call, h: u64) -> ^Track_Entry { return (^Track_Entry)(object_data(c.page, h, &track_vt)) }
lookup_AudioTrackList :: proc(c: ^Call, h: u64) -> ^Track_List_Object { return (^Track_List_Object)(object_data(c.page, h, &track_list_vt)) }
lookup_VideoTrackList :: proc(c: ^Call, h: u64) -> ^Track_List_Object { return (^Track_List_Object)(object_data(c.page, h, &track_list_vt)) }

// The Media_Tracks of an element, made on first access.
@(private)
media_tracks :: proc(el: ^Media_Element) -> ^Media_Tracks {
	if el.tracks == nil {
		el.tracks = new(Media_Tracks)
		el.tracks.el_node, el.tracks.el_serial = el.node, el.serial
		el.tracks.audio = make([dynamic]^Track_Entry)
		el.tracks.video = make([dynamic]^Track_Entry)
		el.tracks.text = make([dynamic]^Text_Track_Object)
	}
	return el.tracks
}

@(private)
media_tracks_free :: proc(p: ^Page, el: ^Media_Element, page_closing: bool) {
	mt := el.tracks
	if mt == nil { return }
	for t in mt.audio { if !page_closing { object_release(p, t.self) } }
	for t in mt.video { if !page_closing { object_release(p, t.self) } }
	for tt in mt.text { text_track_destroy(p, tt, page_closing) }
	if !page_closing {
		if mt.audio_list != 0 { object_release(p, mt.audio_list) }
		if mt.video_list != 0 { object_release(p, mt.video_list) }
		if mt.text_list != 0 { object_release(p, mt.text_list) }
	}
	delete(mt.audio); delete(mt.video); delete(mt.text)
	free(mt)
	el.tracks = nil
}

// HTML "media track kind" from the codec kind (a container without richer metadata).
@(private)
track_kind_label :: proc(t: media.Track, chosen: bool) -> string {
	switch t.kind {
	case .Video: return "main"
	case .Audio: return chosen ? "main" : "alternative"
	case .Other: return ""
	}
	return ""
}

// Builds the audio / video track lists from the container's tracks. The chosen track of each kind is enabled/selected.
@(private)
media_tracks_from_container :: proc(el: ^Media_Element, tracks: []media.Track, vtrack, atrack: int) {
	p := el.page
	mt := media_tracks(el)
	// a load replaces the tracks of a previous resource
	for t in mt.audio { object_release(p, t.self) }
	for t in mt.video { object_release(p, t.self) }
	clear(&mt.audio); clear(&mt.video)
	for t, i in tracks {
		#partial switch t.kind {
		case .Audio:
			e := new(Track_Entry)
			e.id = track_id_string(t, i)
			e.kind = strings.clone(track_kind_label(t, i == atrack))
			e.label = strings.clone("")
			e.language = strings.clone(t.language)
			e.enabled = i == atrack
			e.index = i
			e.self = object_create(p, &track_vt, e, media_tracks_owner(p))
			append(&mt.audio, e)
			if mt.audio_list != 0 { track_fire(p, mt.audio_list, "addtrack") }
		case .Video:
			e := new(Track_Entry)
			e.id = track_id_string(t, i)
			e.kind = strings.clone(track_kind_label(t, i == vtrack))
			e.label = strings.clone("")
			e.language = strings.clone(t.language)
			e.enabled = i == vtrack
			e.index = i
			e.self = object_create(p, &track_vt, e, media_tracks_owner(p))
			append(&mt.video, e)
			if mt.video_list != 0 { track_fire(p, mt.video_list, "addtrack") }
		}
	}
}

// The owner (instance index) of objects the host makes outside a call, during a load: the page's JavaScript realm when
// there is one, else 0 (the embedder / Wasm guest; objects are freed with the page regardless).
@(private)
media_tracks_owner :: proc(p: ^Page) -> u32 {
	if p.js != nil && p.js.inst != nil { return p.js.inst.index }
	return 0
}

@(private)
track_id_string :: proc(t: media.Track, index: int) -> string {
	if t.id != 0 {
		buf: [24]u8
		return strings.clone(uint_to_string(u64(t.id), buf[:]))
	}
	buf: [24]u8
	return strings.clone(uint_to_string(u64(index + 1), buf[:]))
}

@(private)
uint_to_string :: proc(v: u64, buf: []u8) -> string {
	if v == 0 { buf[0] = '0'; return string(buf[:1]) }
	i := len(buf)
	x := v
	for x > 0 { i -= 1; buf[i] = u8('0' + x % 10); x /= 10 }
	return string(buf[i:])
}

// Fires an event at a track list from a task of its own (same shape as mse_fire).
@(private)
track_fire :: proc(p: ^Page, handle: u64, type: string) {
	if handle == 0 || p.closed { return }
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		ev := (^Mse_Event)(data)
		defer { delete(ev.type); free(ev) }
		if pg == nil || pg.closed { return }
		object_dispatch(pg, ev.handle, dom.Event{type = ev.type})
	}, new_clone(Mse_Event{handle, strings.clone(type)}))
}

////////////////////////////////
// API: the track lists (api/media_tracks.widl)

HTMLMediaElement_audioTracks :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	if el == nil || !c.page.settings.media.tracks { return 0 }
	mt := media_tracks(el)
	if mt.audio_list == 0 { mt.audio_list = object_create(c.page, &track_list_vt, new_clone(Track_List_Object{page = c.page, tracks = mt, kind = .Audio}), c.owner) }
	return mt.audio_list
}

HTMLMediaElement_videoTracks :: proc(c: ^Call, e: Api_HTMLMediaElement) -> u64 {
	el := e.data
	if el == nil || !c.page.settings.media.tracks { return 0 }
	mt := media_tracks(el)
	if mt.video_list == 0 { mt.video_list = object_create(c.page, &track_list_vt, new_clone(Track_List_Object{page = c.page, tracks = mt, kind = .Video}), c.owner) }
	return mt.video_list
}

AudioTrackList_length :: proc(c: ^Call, list: Api_AudioTrackList) -> u32 { return list.data == nil ? 0 : u32(len(list.data.tracks.audio)) }
VideoTrackList_length :: proc(c: ^Call, list: Api_VideoTrackList) -> u32 { return list.data == nil ? 0 : u32(len(list.data.tracks.video)) }

AudioTrackList_item :: proc(c: ^Call, list: Api_AudioTrackList, index: u32) -> (u64, Api_Error) {
	if list.data == nil || int(index) >= len(list.data.tracks.audio) { return 0, .Not_Found }
	return list.data.tracks.audio[index].self, .None
}

VideoTrackList_item :: proc(c: ^Call, list: Api_VideoTrackList, index: u32) -> (u64, Api_Error) {
	if list.data == nil || int(index) >= len(list.data.tracks.video) { return 0, .Not_Found }
	return list.data.tracks.video[index].self, .None
}

AudioTrackList_getTrackById :: proc(c: ^Call, list: Api_AudioTrackList, id: string) -> u64 {
	if list.data == nil { return 0 }
	for t in list.data.tracks.audio { if t.id == id { return t.self } }
	return 0
}

VideoTrackList_getTrackById :: proc(c: ^Call, list: Api_VideoTrackList, id: string) -> u64 {
	if list.data == nil { return 0 }
	for t in list.data.tracks.video { if t.id == id { return t.self } }
	return 0
}

// videoTrackList.selectedIndex: the index of the selected video track, -1 when none.
VideoTrackList_selectedIndex :: proc(c: ^Call, list: Api_VideoTrackList) -> i32 {
	if list.data == nil { return -1 }
	for t, i in list.data.tracks.video { if t.enabled { return i32(i) } }
	return -1
}

////////////////////////////////
// API: the tracks themselves

AudioTrack_id :: proc(c: ^Call, t: Api_AudioTrack) -> string { return t.data == nil ? "" : t.data.id }
AudioTrack_kind :: proc(c: ^Call, t: Api_AudioTrack) -> string { return t.data == nil ? "" : t.data.kind }
AudioTrack_label :: proc(c: ^Call, t: Api_AudioTrack) -> string { return t.data == nil ? "" : t.data.label }
AudioTrack_language :: proc(c: ^Call, t: Api_AudioTrack) -> string { return t.data == nil ? "" : t.data.language }
AudioTrack_enabled :: proc(c: ^Call, t: Api_AudioTrack) -> bool { return t.data == nil ? false : t.data.enabled }

AudioTrack_set_enabled :: proc(c: ^Call, t: Api_AudioTrack, value: bool) {
	e := t.data
	if e == nil || e.enabled == value { return }
	e.enabled = value
	// the enabled set changed: the list fires change, and the player selects the new audio track if it can
	if el := media_tracks_element(c.page, e); el != nil {
		media_player_select_audio(el, e.index, value)
		if el.tracks != nil && el.tracks.audio_list != 0 { track_fire(c.page, el.tracks.audio_list, "change") }
	}
}

VideoTrack_id :: proc(c: ^Call, t: Api_VideoTrack) -> string { return t.data == nil ? "" : t.data.id }
VideoTrack_kind :: proc(c: ^Call, t: Api_VideoTrack) -> string { return t.data == nil ? "" : t.data.kind }
VideoTrack_label :: proc(c: ^Call, t: Api_VideoTrack) -> string { return t.data == nil ? "" : t.data.label }
VideoTrack_language :: proc(c: ^Call, t: Api_VideoTrack) -> string { return t.data == nil ? "" : t.data.language }
VideoTrack_selected :: proc(c: ^Call, t: Api_VideoTrack) -> bool { return t.data == nil ? false : t.data.enabled }

// Selecting a video track clears the others (at most one is selected), fires change and tells the player.
VideoTrack_set_selected :: proc(c: ^Call, t: Api_VideoTrack, value: bool) {
	e := t.data
	if e == nil { return }
	el := media_tracks_element(c.page, e)
	if el == nil || el.tracks == nil { e.enabled = value; return }
	if value {
		for v in el.tracks.video { v.enabled = v == e }
	} else {
		e.enabled = false
	}
	media_player_select_video(el, e.index, value)
	if el.tracks.video_list != 0 { track_fire(c.page, el.tracks.video_list, "change") }
}

// The element a track belongs to (by matching its handle against the element's lists).
@(private)
media_tracks_element :: proc(p: ^Page, t: ^Track_Entry) -> ^Media_Element {
	if p.media == nil { return nil }
	for _, el in p.media.elements {
		if el.tracks == nil { continue }
		for a in el.tracks.audio { if a == t { return el } }
		for v in el.tracks.video { if v == t { return el } }
	}
	return nil
}

// Tell the player a different audio track is wanted. The progressive and MSE players decode one stream today; where a
// demuxer can switch the active audio track this is the single place to wire it. A no-op otherwise, the state the
// script reads is already updated.
@(private)
media_player_select_audio :: proc(el: ^Media_Element, index: int, enabled: bool) {
	if el.player == nil { return }
	media.player_select_audio(el.player, index, enabled)
}

@(private)
media_player_select_video :: proc(el: ^Media_Element, index: int, selected: bool) {
	if el.player == nil { return }
	media.player_select_video(el.player, index, selected)
}

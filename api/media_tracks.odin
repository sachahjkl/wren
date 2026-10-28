// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=mediatracks order=56 exposed=Window
/// The track lists of a media element (src/page/media_tracks.odin, media_texttracks.odin): AudioTrackList, VideoTrackList
/// and TextTrackList (EventTargets: addtrack / removetrack / change), the AudioTrack / VideoTrack / TextTrack they hold,
/// the TextTrackCue / VTTCue and TextTrackCueList of a text track, and the <track> element. The audio and video tracks
/// are built from what the container demuxer announced; text tracks come from <track src> (WebVTT, parsed natively by
/// media.vtt_parse) or addTextTrack. Which cues are active is tracked by the player's time and the shell draws the
/// showing tracks over the video.
package api_media_tracks

//@wb handle parent=Object host=Track_List_Object lookup=lookup_AudioTrackList
AudioTrackList :: distinct Handle

//@wb handle parent=Object host=Track_List_Object lookup=lookup_VideoTrackList
VideoTrackList :: distinct Handle

//@wb handle parent=Object host=Track_List_Object lookup=lookup_TextTrackList
TextTrackList :: distinct Handle

//@wb handle parent=Object host=Track_Entry lookup=lookup_AudioTrack
AudioTrack :: distinct Handle

//@wb handle parent=Object host=Track_Entry lookup=lookup_VideoTrack
VideoTrack :: distinct Handle

//@wb handle parent=Object host=Text_Track_Object lookup=lookup_TextTrack
TextTrack :: distinct Handle

//@wb handle parent=Object host=Text_Cue_Object lookup=lookup_TextTrackCue
TextTrackCue :: distinct Handle

//@wb handle parent=Object host=Text_Cue_List_Object lookup=lookup_TextTrackCueList
TextTrackCueList :: distinct Handle

//@wb handle parent=Element host=dom.Node lookup=lookup_HTMLTrackElement
HTMLTrackElement :: distinct Handle

//@wb fn
AudioTrackList_length :: proc(list: AudioTrackList) -> u32

/// list[index]: Not_Found past the end.
//@wb fn raises
AudioTrackList_item :: proc(list: AudioTrackList, index: u32) -> AudioTrack

/// list.getTrackById(id): 0 (null) when none matches.
//@wb fn
AudioTrackList_getTrackById :: proc(list: AudioTrackList, id: string) -> AudioTrack

//@wb fn
VideoTrackList_length :: proc(list: VideoTrackList) -> u32

//@wb fn raises
VideoTrackList_item :: proc(list: VideoTrackList, index: u32) -> VideoTrack

//@wb fn
VideoTrackList_getTrackById :: proc(list: VideoTrackList, id: string) -> VideoTrack

/// videoTrackList.selectedIndex: the index of the selected track, -1 when none.
//@wb fn
VideoTrackList_selectedIndex :: proc(list: VideoTrackList) -> i32

//@wb fn
TextTrackList_length :: proc(list: TextTrackList) -> u32

//@wb fn raises
TextTrackList_item :: proc(list: TextTrackList, index: u32) -> TextTrack

//@wb fn
TextTrackList_getTrackById :: proc(list: TextTrackList, id: string) -> TextTrack

//@wb fn
AudioTrack_id :: proc(track: AudioTrack) -> string

//@wb fn
AudioTrack_kind :: proc(track: AudioTrack) -> string

//@wb fn
AudioTrack_label :: proc(track: AudioTrack) -> string

//@wb fn
AudioTrack_language :: proc(track: AudioTrack) -> string

//@wb fn
AudioTrack_enabled :: proc(track: AudioTrack) -> bool

//@wb fn
AudioTrack_set_enabled :: proc(track: AudioTrack, value: bool)

//@wb fn
VideoTrack_id :: proc(track: VideoTrack) -> string

//@wb fn
VideoTrack_kind :: proc(track: VideoTrack) -> string

//@wb fn
VideoTrack_label :: proc(track: VideoTrack) -> string

//@wb fn
VideoTrack_language :: proc(track: VideoTrack) -> string

//@wb fn
VideoTrack_selected :: proc(track: VideoTrack) -> bool

//@wb fn
VideoTrack_set_selected :: proc(track: VideoTrack, value: bool)

/// track.kind / label / language / id (TextTrack).
//@wb fn
TextTrack_kind :: proc(track: TextTrack) -> string

//@wb fn
TextTrack_label :: proc(track: TextTrack) -> string

//@wb fn
TextTrack_language :: proc(track: TextTrack) -> string

//@wb fn
TextTrack_id :: proc(track: TextTrack) -> string

/// track.mode: "disabled", "hidden" or "showing".
//@wb fn
TextTrack_mode :: proc(track: TextTrack) -> string

//@wb fn
TextTrack_set_mode :: proc(track: TextTrack, value: string)

/// track.cues / activeCues: a TextTrackCueList (0: the track is disabled).
//@wb fn
TextTrack_cues :: proc(track: TextTrack) -> TextTrackCueList

//@wb fn
TextTrack_activeCues :: proc(track: TextTrack) -> TextTrackCueList

/// track.addCue(cue) / removeCue(cue).
//@wb fn raises
TextTrack_addCue :: proc(track: TextTrack, cue: TextTrackCue)

//@wb fn raises
TextTrack_removeCue :: proc(track: TextTrack, cue: TextTrackCue)

//@wb fn
TextTrackCue_id :: proc(cue: TextTrackCue) -> string

//@wb fn
TextTrackCue_set_id :: proc(cue: TextTrackCue, value: string)

//@wb fn
TextTrackCue_startTime :: proc(cue: TextTrackCue) -> f64

//@wb fn
TextTrackCue_set_startTime :: proc(cue: TextTrackCue, value: f64)

//@wb fn
TextTrackCue_endTime :: proc(cue: TextTrackCue) -> f64

//@wb fn
TextTrackCue_set_endTime :: proc(cue: TextTrackCue, value: f64)

//@wb fn
TextTrackCue_pauseOnExit :: proc(cue: TextTrackCue) -> bool

//@wb fn
TextTrackCue_set_pauseOnExit :: proc(cue: TextTrackCue, value: bool)

/// cue.track: the TextTrack it is in (0: none).
//@wb fn
TextTrackCue_track :: proc(cue: TextTrackCue) -> TextTrack

/// new VTTCue(startTime, endTime, text): a script-made cue.
//@wb fn raises
VTTCue_create :: proc(start: f64, end: f64, text: string) -> TextTrackCue

/// vttCue.text (the cue payload).
//@wb fn
VTTCue_text :: proc(cue: TextTrackCue) -> string

//@wb fn
VTTCue_set_text :: proc(cue: TextTrackCue, value: string)

//@wb fn
TextTrackCueList_length :: proc(list: TextTrackCueList) -> u32

//@wb fn raises
TextTrackCueList_item :: proc(list: TextTrackCueList, index: u32) -> TextTrackCue

//@wb fn
TextTrackCueList_getCueById :: proc(list: TextTrackCueList, id: string) -> TextTrackCue

/// track.track: the <track> element's TextTrack (0: not attached to a media element).
//@wb fn
HTMLTrackElement_track :: proc(track: HTMLTrackElement) -> TextTrack

/// track.readyState: 0 NONE, 1 LOADING, 2 LOADED, 3 ERROR.
//@wb fn
HTMLTrackElement_readyState :: proc(track: HTMLTrackElement) -> i32


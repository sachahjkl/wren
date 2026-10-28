// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=htmlmedia order=54 exposed=Window
/// HTMLMediaElement (<video>, <audio>): the media element state machine of HTML §4.8.11 (src/page/media_element.odin) on the
/// media package's player. The events (loadstart ... ended) are plain events fired at the element; TimeRanges, MediaError and
/// VideoPlaybackQuality are made by the engine (native/js/runtime/web_mediaobjects.c) from the numbers below.
package api_media_element

//@wb handle parent=Element host=Media_Element lookup=lookup_HTMLMediaElement
/// A <video> or <audio> element; anything else is not a live HTMLMediaElement.
HTMLMediaElement :: distinct Handle

/// element.currentSrc: the absolute URL of the resource being played ("" when none).
//@wb fn
HTMLMediaElement_currentSrc :: proc(element: HTMLMediaElement) -> string

/// element.networkState: 0 empty, 1 idle, 2 loading, 3 no source.
//@wb fn
HTMLMediaElement_networkState :: proc(element: HTMLMediaElement) -> i32

/// element.readyState: 0 nothing ... 4 enough data.
//@wb fn
HTMLMediaElement_readyState :: proc(element: HTMLMediaElement) -> i32

/// element.seeking
//@wb fn
HTMLMediaElement_seeking :: proc(element: HTMLMediaElement) -> bool

/// element.currentTime, in seconds.
//@wb fn
HTMLMediaElement_currentTime :: proc(element: HTMLMediaElement) -> f64

/// element.currentTime = value: a seek (a NaN or infinite value is refused by Web IDL before).
//@wb fn
HTMLMediaElement_set_currentTime :: proc(element: HTMLMediaElement, value: f64)

/// element.duration: NaN until the metadata is known, Infinity for a stream with no end.
//@wb fn
HTMLMediaElement_duration :: proc(element: HTMLMediaElement) -> f64

/// element.paused
//@wb fn
HTMLMediaElement_paused :: proc(element: HTMLMediaElement) -> bool

/// element.ended
//@wb fn
HTMLMediaElement_ended :: proc(element: HTMLMediaElement) -> bool

//@wb fn
HTMLMediaElement_defaultPlaybackRate :: proc(element: HTMLMediaElement) -> f64

//@wb fn
HTMLMediaElement_set_defaultPlaybackRate :: proc(element: HTMLMediaElement, value: f64)

//@wb fn
HTMLMediaElement_playbackRate :: proc(element: HTMLMediaElement) -> f64

//@wb fn
HTMLMediaElement_set_playbackRate :: proc(element: HTMLMediaElement, value: f64)

//@wb fn
HTMLMediaElement_preservesPitch :: proc(element: HTMLMediaElement) -> bool

//@wb fn
HTMLMediaElement_set_preservesPitch :: proc(element: HTMLMediaElement, value: bool)

//@wb fn
HTMLMediaElement_volume :: proc(element: HTMLMediaElement) -> f64

/// element.volume = value: IndexSize outside [0, 1].
//@wb fn raises
HTMLMediaElement_set_volume :: proc(element: HTMLMediaElement, value: f64)

//@wb fn
HTMLMediaElement_muted :: proc(element: HTMLMediaElement) -> bool

//@wb fn
HTMLMediaElement_set_muted :: proc(element: HTMLMediaElement, value: bool)

/// element.buffered (0), played (1) or seekable (2) as pairs of f64 (start, end), seconds, little endian: the engine
/// makes the TimeRanges object of them.
//@wb fn
HTMLMediaElement_ranges :: proc(element: HTMLMediaElement, which: i32) -> bytes

/// element.srcObject = a MediaSourceHandle (its object handle; 0: null): the element loads it, srcObject before src
/// (HTML "media provider object"). Type for another kind of object.
//@wb fn raises
HTMLMediaElement_setSourceHandle :: proc(element: HTMLMediaElement, handle: u64)

/// element.error: the code (0 when null) and the message.
//@wb fn
HTMLMediaElement_errorCode :: proc(element: HTMLMediaElement) -> i32

//@wb fn
HTMLMediaElement_errorMessage :: proc(element: HTMLMediaElement) -> string

/// element.play(): a promise settled when playback starts (NotAllowedError when the autoplay policy forbids it,
/// NotSupportedError when there is no usable source, AbortError when a pause or a load interrupts it).
//@wb fn
HTMLMediaElement_play :: proc(element: HTMLMediaElement) -> Promise

//@wb fn
HTMLMediaElement_pause :: proc(element: HTMLMediaElement)

/// element.load(): the media element load algorithm.
//@wb fn
HTMLMediaElement_load :: proc(element: HTMLMediaElement)

/// element.canPlayType(type): "", "maybe" or "probably".
//@wb fn
HTMLMediaElement_canPlayType :: proc(element: HTMLMediaElement, type: string) -> string

/// video.videoWidth / videoHeight: the size of the picture (0 before the metadata).
//@wb fn
HTMLVideoElement_videoWidth :: proc(element: HTMLMediaElement) -> u32

//@wb fn
HTMLVideoElement_videoHeight :: proc(element: HTMLMediaElement) -> u32

/// video.getVideoPlaybackQuality(): five f64 (creationTime, droppedVideoFrames, totalVideoFrames, corruptedVideoFrames,
/// totalFrameDelay in seconds).
//@wb fn
HTMLVideoElement_playbackQuality :: proc(element: HTMLMediaElement) -> bytes

/// requestVideoFrameCallback's callback: `now` is the current time on the page's performance timeline (the callback
/// reads the rest of the metadata back with HTMLVideoElement_videoFrameMetadata, keyed by the id this call made).
//@wb callback
VideoFrameRequestCallback :: #type proc "contextless" (user: i32, now: f64)

/// video.requestVideoFrameCallback(callback): the callback runs once, when a new video frame is presented (the same
/// moment the playback-quality counters advance). Returns an id for cancelVideoFrameCallback (0: too many waiting,
/// media.max_video_frame_callbacks).
//@wb fn
HTMLVideoElement_requestVideoFrameCallback :: proc(element: HTMLMediaElement, callback: VideoFrameRequestCallback, user: i32 = 0) -> u64

/// video.cancelVideoFrameCallback(id).
//@wb fn
HTMLVideoElement_cancelVideoFrameCallback :: proc(element: HTMLMediaElement, id: u64)

/// The VideoFrameCallbackMetadata of the frame that fired callback `id`, snapshotted at presentation: eight f64
/// (presentationTime, expectedDisplayTime, width, height, mediaTime, presentedFrames, processingDuration, and a
/// bitmask of which of the optional fields are present; here always 0 — captureTime/receiveTime/rtpTimestamp absent).
/// Empty when the id is unknown.
//@wb fn
HTMLVideoElement_videoFrameMetadata :: proc(element: HTMLMediaElement, id: u64) -> bytes

/// element.audioTracks / videoTracks / textTracks: the handle of the list object (an AudioTrackList / VideoTrackList /
/// TextTrackList of the mediatracks module; the engine wraps it). 0 when media.tracks.enabled is off. The same object
/// each time (SameObject).
//@wb fn
HTMLMediaElement_audioTracks :: proc(element: HTMLMediaElement) -> u64

//@wb fn
HTMLMediaElement_videoTracks :: proc(element: HTMLMediaElement) -> u64

//@wb fn
HTMLMediaElement_textTracks :: proc(element: HTMLMediaElement) -> u64

/// element.addTextTrack(kind, label, language): the handle of a new (hidden) TextTrack. NotSupported when off.
//@wb fn raises
HTMLMediaElement_addTextTrack :: proc(element: HTMLMediaElement, kind: string, label: string = "", language: string = "") -> u64


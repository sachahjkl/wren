// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=mse order=55 exposed=(Window,Worker)
/// Media Source Extensions: MediaSource, SourceBuffer and SourceBufferList (src/page/media_source.odin). A SourceBuffer holds
/// the coded frames a container parser made of what scripts appended (src/media), which a media element plays; the objects
/// are EventTargets: sourceopen / sourceended / sourceclose, updatestart / update / updateend / error / abort,
/// addsourcebuffer / removesourcebuffer are events of the host objects. In a dedicated worker the same functions drive
/// a MediaSource whose media element is in the page (src/page/mse_worker.odin): its MediaSourceHandle is transferred to
/// the page and set as the element's srcObject.
package api_media_source

//@wb handle parent=Object host=Media_Source_Object lookup=lookup_MediaSource
MediaSource :: distinct Handle

//@wb handle parent=Object host=Source_Buffer_Object lookup=lookup_SourceBuffer
SourceBuffer :: distinct Handle

//@wb handle parent=Object host=Source_Buffer_List_Object lookup=lookup_SourceBufferList
SourceBufferList :: distinct Handle

//@wb handle parent=Object host=Mse_Handle_Object lookup=lookup_MediaSourceHandle
MediaSourceHandle :: distinct Handle

/// new MediaSource(): closed until an element attaches it (in a dedicated worker too; not in other workers).
//@wb fn raises
MediaSource_create :: proc() -> MediaSource

/// new ManagedMediaSource(): a MediaSource whose user agent says when to stream (startstreaming / endstreaming).
//@wb fn raises
ManagedMediaSource_create :: proc() -> MediaSource

/// managedMediaSource.streaming: whether the user agent currently wants the page to append data.
//@wb fn
ManagedMediaSource_streaming :: proc(source: MediaSource) -> bool

/// URL.createObjectURL(mediaSource): the URL (of the page's origin) is registered, so that a media element whose src is
/// that URL plays this source. Called by the engine with the URL it made. NotSupported for a worker's MediaSource.
//@wb fn raises
MediaSource_registerObjectURL :: proc(source: MediaSource, url: string)

/// mediaSource.handle: the same MediaSourceHandle each time (a dedicated worker's MediaSource; NotSupported else).
//@wb fn raises
MediaSource_handle :: proc(source: MediaSource) -> MediaSourceHandle

/// A MediaSourceHandle in the transfer list of a message: the token the receiving realm adopts (DataClone when it
/// was transferred before or its MediaSource is attached already).
//@wb fn raises
MediaSourceHandle_take :: proc(h: MediaSourceHandle) -> u64

/// The receiving realm's MediaSourceHandle for a token.
//@wb fn raises
MediaSourceHandle_adopt :: proc(token: u64) -> MediaSourceHandle

/// URL.revokeObjectURL(url): the URL no longer names a Media Source (one already attached keeps playing).
//@wb fn
MediaSource_revokeObjectURL :: proc(url: string)

/// MediaSource.isTypeSupported(type)
//@wb fn
MediaSource_isTypeSupported :: proc(type: string) -> bool

/// source.sourceBuffers, activeSourceBuffers: the same object each time.
//@wb fn
MediaSource_sourceBuffers :: proc(source: MediaSource) -> SourceBufferList

//@wb fn
MediaSource_activeSourceBuffers :: proc(source: MediaSource) -> SourceBufferList

/// source.readyState: "closed", "open" or "ended".
//@wb fn
MediaSource_readyState :: proc(source: MediaSource) -> string

//@wb fn
MediaSource_duration :: proc(source: MediaSource) -> f64

/// source.duration = value: InvalidState unless open or updating buffers, Type for a negative value or NaN.
//@wb fn raises
MediaSource_set_duration :: proc(source: MediaSource, value: f64)

/// source.addSourceBuffer(type): NotSupported, InvalidState (not open), Quota.
//@wb fn raises
MediaSource_addSourceBuffer :: proc(source: MediaSource, type: string) -> SourceBuffer

//@wb fn raises
MediaSource_removeSourceBuffer :: proc(source: MediaSource, buffer: SourceBuffer)

/// source.endOfStream(error): "" (none), "network" or "decode".
//@wb fn raises
MediaSource_endOfStream :: proc(source: MediaSource, error: string = "")

//@wb fn raises
MediaSource_setLiveSeekableRange :: proc(source: MediaSource, start: f64, end: f64)

//@wb fn raises
MediaSource_clearLiveSeekableRange :: proc(source: MediaSource)

//@wb fn
SourceBufferList_length :: proc(list: SourceBufferList) -> u32

/// list[index]: Not_Found past the end (undefined).
//@wb fn raises
SourceBufferList_item :: proc(list: SourceBufferList, index: u32) -> SourceBuffer

/// buffer.mode: "segments" or "sequence".
//@wb fn
SourceBuffer_mode :: proc(buffer: SourceBuffer) -> string

//@wb fn raises
SourceBuffer_set_mode :: proc(buffer: SourceBuffer, mode: string)

//@wb fn
SourceBuffer_updating :: proc(buffer: SourceBuffer) -> bool

/// buffer.buffered as pairs of f64 (start, end), seconds (InvalidState for a removed buffer): the engine makes the TimeRanges.
//@wb fn raises
SourceBuffer_ranges :: proc(buffer: SourceBuffer) -> bytes

//@wb fn
SourceBuffer_timestampOffset :: proc(buffer: SourceBuffer) -> f64

//@wb fn raises
SourceBuffer_set_timestampOffset :: proc(buffer: SourceBuffer, value: f64)

//@wb fn
SourceBuffer_appendWindowStart :: proc(buffer: SourceBuffer) -> f64

//@wb fn raises
SourceBuffer_set_appendWindowStart :: proc(buffer: SourceBuffer, value: f64)

//@wb fn
SourceBuffer_appendWindowEnd :: proc(buffer: SourceBuffer) -> f64

//@wb fn raises
SourceBuffer_set_appendWindowEnd :: proc(buffer: SourceBuffer, value: f64)

/// buffer.appendBuffer(data): InvalidState while updating or removed, Quota when full.
//@wb fn raises
SourceBuffer_appendBuffer :: proc(buffer: SourceBuffer, data: bytes)

//@wb fn raises
SourceBuffer_abort :: proc(buffer: SourceBuffer)

//@wb fn raises
SourceBuffer_changeType :: proc(buffer: SourceBuffer, type: string)

//@wb fn raises
SourceBuffer_remove :: proc(buffer: SourceBuffer, start: f64, end: f64)


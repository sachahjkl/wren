// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webcodecs_image order=73 exposed=(Window,Worker)
/// WebCodecs ImageDecoder (src/page/bindings_image_decoder.odin, native/js/runtime/web_webcodecs_image.c). The decode
/// is native: the host decodes the encoded bytes once with src/images (every frame composed) and wraps each frame as a
/// VideoFrame. The engine holds the ImageDecoder wrapper, builds the ImageDecoderInit dictionary, resolves decode()'s
/// and completed's promises, and exposes the ImageTrackList / ImageTrack. One track (the primary image) is exposed.
package api_webcodecs_image

//@wb handle parent=Object host=Image_Decoder_Obj lookup=lookup_ImageDecoder
ImageDecoder :: distinct Handle

//@wb handle parent=Object host=Image_Track_Obj lookup=lookup_ImageTrackList
ImageTrackList :: distinct Handle

//@wb handle parent=Object host=Image_Track_Obj lookup=lookup_ImageTrack
ImageTrack :: distinct Handle

/// new ImageDecoder({data, type, ...}): `data` is the encoded bytes (a BufferSource; the engine also reads a Blob or
/// a ReadableStream to bytes first), `mime` the `type` option. Quota past the image limits / page memory, Type for
/// empty data, Not_Supported when WebCodecs is off.
//@wb fn raises owned
ImageDecoder_create :: proc(data: bytes, mime: string, prefer_animation: bool) -> ImageDecoder

/// ImageDecoder.isTypeSupported(type): honest — true only for a format we decode (not SVG).
//@wb fn
ImageDecoder_isTypeSupported :: proc(mime: string) -> bool

/// decoder.type.
//@wb fn
ImageDecoder_type :: proc(decoder: ImageDecoder) -> string

/// decoder.complete: the bytes are all available (always true for a BufferSource / Blob).
//@wb fn
ImageDecoder_complete :: proc(decoder: ImageDecoder) -> bool

/// The decoded frame count (0 before a successful decode).
//@wb fn
ImageDecoder_frameCount :: proc(decoder: ImageDecoder) -> u32

/// decoder.decode({frameIndex}): the frame wrapped as a VideoFrame (the engine wraps it in the ImageDecodeResult and
/// the promise). Range when frameIndex is past the frame count, Encoding when the image cannot be decoded,
/// Invalid_State when the decoder is closed.
//@wb fn raises owned
ImageDecoder_decode :: proc(decoder: ImageDecoder, frame_index: u32) -> VideoFrame

/// decoder.reset() / close().
//@wb fn
ImageDecoder_reset :: proc(decoder: ImageDecoder)

//@wb fn
ImageDecoder_close :: proc(decoder: ImageDecoder)

/// decoder.tracks: the ImageTrackList (made on first access).
//@wb fn
ImageDecoder_tracks :: proc(decoder: ImageDecoder) -> ImageTrackList

//@wb fn
ImageTrackList_length :: proc(list: ImageTrackList) -> u32

/// list[index]: Not_Found past the end (one track).
//@wb fn raises owned
ImageTrackList_item :: proc(list: ImageTrackList, index: u32) -> ImageTrack

/// list.selectedIndex: -1 when none / not decoded yet.
//@wb fn
ImageTrackList_selectedIndex :: proc(list: ImageTrackList) -> i32

//@wb fn
ImageTrack_animated :: proc(track: ImageTrack) -> bool

//@wb fn
ImageTrack_frameCount :: proc(track: ImageTrack) -> u32

/// track.repetitionCount: 0 play once, -1 the engine maps to Infinity (loops forever), else the repeat count.
//@wb fn
ImageTrack_repetitionCount :: proc(track: ImageTrack) -> i32

//@wb fn
ImageTrack_selected :: proc(track: ImageTrack) -> bool


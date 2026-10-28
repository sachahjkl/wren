package page

// WebCodecs ImageDecoder (api/webcodecs_image.widl, native/js/runtime/web_webcodecs_image.c). Decodes an encoded image
// (PNG / JPEG / GIF / WebP / AVIF / BMP / ICO / TIFF, animations included) into VideoFrames with src/images. The whole
// decode is native: the host decodes the bytes once (images.decode_now, every frame composed), holds the Image, and
// each decode({frameIndex}) wraps that frame's RGBA pixels as a VideoFrame (webcodecs_frame.odin). The ImageTrackList /
// ImageTrack report the frame count, the animation flag and the repetition count the container announced.
//
// The decode runs on the page thread (the built-in decoders are memory-safe and the inputs are bounded by the image
// limits); the decode() promise still resolves from a task of its own, so its reactions run at a clean checkpoint.

import "wb:images"

// An ImageDecoder: its source bytes and, once decoded, the Image. One track (the primary image) is exposed; the format
// mirrors the sniffed type. `complete` is true once the bytes are fully available (always, for a BufferSource / Blob).
Image_Decoder_Obj :: struct {
	page:      ^Page,
	self:      u64,
	mime:      string,       // the `type` option (owned)
	data:      []u8,         // the encoded bytes (owned, page allocator), freed on close
	opts:      images.Decode_Options,
	decoded:   bool,         // a decode was attempted
	img:       ^images.Image,// the decoded image (nil until decoded, or on failure)
	info:      images.Info,  // the header info (format, frames, animated, plays), known after the first decode
	err:       images.Error,
	closed:    bool,
	track_list: u64,         // the ImageTrackList object (0 until .tracks is read)
	completed: u64,          // the `completed` promise (0 until read)
	selected_track: int,     // the selected track index (always 0: one track)
}

image_decoder_vt := Object_VTable{
	name = "ImageDecoder",
	destroy = proc(p: ^Page, data: rawptr) {
		d := (^Image_Decoder_Obj)(data)
		image_decoder_drop(p, d)
		delete(d.mime)
		if d.data != nil { if !p.closed { p.held -= len(d.data) }; delete(d.data) }
		if d.track_list != 0 && !p.closed { object_release(p, d.track_list) }
		free(d)
	},
}

lookup_ImageDecoder :: proc(c: ^Call, h: u64) -> ^Image_Decoder_Obj { return (^Image_Decoder_Obj)(object_data(c.page, h, &image_decoder_vt)) }

@(private)
image_decoder_drop :: proc(p: ^Page, d: ^Image_Decoder_Obj) {
	if d.img != nil { images.image_destroy(d.img); d.img = nil }
}

// An ImageTrackList / ImageTrack is a view onto the decoder; it holds the decoder's handle so the attributes read its
// state. One track is made (the primary image).
Image_Track_Obj :: struct {
	page:    ^Page,
	decoder: u64,     // the ImageDecoder object handle
	index:   int,
}

image_track_vt := Object_VTable{
	name = "ImageTrack",
	destroy = proc(p: ^Page, data: rawptr) { free((^Image_Track_Obj)(data)) },
}

image_track_list_vt := Object_VTable{
	name = "ImageTrackList",
	destroy = proc(p: ^Page, data: rawptr) { free((^Image_Track_Obj)(data)) },   // same shape; index is ignored for the list
}

lookup_ImageTrack :: proc(c: ^Call, h: u64) -> ^Image_Track_Obj { return (^Image_Track_Obj)(object_data(c.page, h, &image_track_vt)) }
lookup_ImageTrackList :: proc(c: ^Call, h: u64) -> ^Image_Track_Obj { return (^Image_Track_Obj)(object_data(c.page, h, &image_track_list_vt)) }

////////////////////////////////
// Construction

// new ImageDecoder({data, type, ...}): the engine passes the encoded bytes and the MIME type. The bytes are copied and
// held against the page's memory ceiling. The decode is deferred to the first decode() / track access.
ImageDecoder_create :: proc(c: ^Call, data: []u8, mime: string, prefer_animation: bool) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.webcodecs.enabled { return 0, fail(c, .Not_Supported, "WebCodecs is disabled.") }
	if len(data) == 0 { return 0, fail(c, .Type, "TypeError: no image data.") }
	if len(data) > p.settings.images.limits.max_encoded_bytes { return 0, fail(c, .Quota, "QuotaExceededError: the image is too large.") }
	if p.held + len(data) > p.settings.max_fetch_bytes { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit.") }
	d := new(Image_Decoder_Obj)
	d.page = p
	d.mime = clone_str_heap(mime)
	d.data = make([]u8, len(data))
	copy(d.data, data)
	p.held += len(data)
	s := &p.settings.images
	d.opts = images.Decode_Options{ limits = s.limits, mime = d.mime, downscale_below = 0, first_frame_only = false, allow_truncated = false }
	d.self = object_create(p, &image_decoder_vt, d, c.owner)
	return d.self, .None
}

@(private)
clone_str_heap :: proc(s: string) -> string {
	if s == "" { return "" }
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}

// Decodes the image if it has not been yet. Idempotent. Keeps the Image (every frame composed).
@(private)
image_decoder_ensure :: proc(d: ^Image_Decoder_Obj) {
	if d.decoded || d.closed { return }
	d.decoded = true
	img, info, err := images.decode_now(d.data, d.opts)
	d.img, d.info, d.err = img, info, err
}

////////////////////////////////
// isTypeSupported (static) and type

// ImageDecoder.isTypeSupported(type): whether we decode this MIME type. The built-in and system decoders cover the
// raster formats; SVG is not an ImageDecoder source. Honest: a type we do not decode returns false.
ImageDecoder_isTypeSupported :: proc(c: ^Call, mime: string) -> bool {
	return image_mime_supported(mime)
}

@(private)
image_mime_supported :: proc(mime: string) -> bool {
	f := images.format_of_mime(image_mime_essence(mime))
	if f == .Unknown || f == .Svg { return false }   // SVG is not an ImageDecoder source
	return images.codec_supported(f)
}

// The lower-case essence of a MIME type ("image/png" from "image/png; charset=..."); a small local trim to avoid pulling
// a parser in. Not allocating: returns a slice of `mime` for the common clean case, else a temp copy.
@(private)
image_mime_essence :: proc(mime: string) -> string {
	end := len(mime)
	for i in 0 ..< len(mime) { if mime[i] == ';' || mime[i] == ' ' { end = i; break } }
	// lower-case into a temp buffer only when needed
	has_upper := false
	for i in 0 ..< end { if mime[i] >= 'A' && mime[i] <= 'Z' { has_upper = true; break } }
	if !has_upper { return mime[:end] }
	b := make([]u8, end, context.temp_allocator)
	for i in 0 ..< end {
		c := mime[i]
		b[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return string(b)
}

ImageDecoder_type :: proc(c: ^Call, d: Api_ImageDecoder) -> string { return d.data == nil ? "" : d.data.mime }

// complete: the bytes are all here. For a BufferSource / Blob source that is always true (we hold the full bytes).
ImageDecoder_complete :: proc(c: ^Call, d: Api_ImageDecoder) -> bool { return d.data != nil }

////////////////////////////////
// decode

// decode({frameIndex, completeFramesOnly}): decode the image (once) and wrap the requested frame as a VideoFrame. The
// result is packed into out_frame (the VideoFrame handle) with out_complete. Negative return is an Api_Error; the
// engine rejects the promise. A frameIndex past the frame count raises Range.
ImageDecoder_decode :: proc(c: ^Call, d: Api_ImageDecoder, frame_index: u32) -> (u64, Api_Error) {
	dec := d.data
	if dec == nil || dec.closed { return 0, fail(c, .Invalid_State, "InvalidStateError: the ImageDecoder is closed.") }
	image_decoder_ensure(dec)
	if dec.img == nil { return 0, fail(c, .Encoding, image_decode_message(dec.err)) }
	if int(frame_index) >= len(dec.img.frames) { return 0, fail(c, .Range, "RangeError: frameIndex is out of range.") }
	fr := dec.img.frames[frame_index]
	w, h := dec.img.width, dec.img.height
	fp, ok := frame_pixels_from_rgba(c.page, fr.pixels, w, h)
	if !ok { return 0, fail(c, .Quota, "QuotaExceededError: VideoFrame too large.") }
	// the frame's timestamp is the cumulative animation delay to its start (microseconds)
	ts := i64(0)
	for i in 0 ..< int(frame_index) { ts += i64(dec.img.frames[i].delay_ms) * 1000 }
	dur := i64(fr.delay_ms) * 1000
	return video_frame_new(c.page, c.owner, fp, ts, dur, dec.info.animated), .None
}

// The number of frames decode() can return (0 until a successful decode; the engine reports a pending ImageTrack
// frameCount of 0 before that). Also drives the ImageTrack.frameCount.
ImageDecoder_frameCount :: proc(c: ^Call, d: Api_ImageDecoder) -> u32 {
	dec := d.data
	if dec == nil { return 0 }
	image_decoder_ensure(dec)
	return dec.img == nil ? 0 : u32(len(dec.img.frames))
}

@(private)
image_decode_message :: proc(e: images.Error) -> string { return images.error_message(e) }

////////////////////////////////
// reset / close

ImageDecoder_reset :: proc(c: ^Call, d: Api_ImageDecoder) {
	dec := d.data
	if dec == nil || dec.closed { return }
	// reset abandons in-flight decode requests; our decode is synchronous, so there is nothing pending to drop. The
	// decoded Image is kept (a later decode() reuses it).
}

ImageDecoder_close :: proc(c: ^Call, d: Api_ImageDecoder) {
	dec := d.data
	if dec == nil || dec.closed { return }
	dec.closed = true
	image_decoder_drop(c.page, dec)
	if dec.data != nil { c.page.held -= len(dec.data); delete(dec.data); dec.data = nil }
}

////////////////////////////////
// tracks: ImageTrackList / ImageTrack

ImageDecoder_tracks :: proc(c: ^Call, d: Api_ImageDecoder) -> u64 {
	dec := d.data
	if dec == nil { return 0 }
	if dec.track_list == 0 {
		dec.track_list = object_create(c.page, &image_track_list_vt, new_clone(Image_Track_Obj{page = c.page, decoder = dec.self, index = 0}), c.owner)
	}
	return dec.track_list
}

ImageTrackList_length :: proc(c: ^Call, list: Api_ImageTrackList) -> u32 {
	// one track once the type is decodable; 0 before a decode succeeds or when it failed
	if list.data == nil { return 0 }
	dec := image_decoder_from(c.page, list.data.decoder)
	if dec == nil { return 0 }
	image_decoder_ensure(dec)
	return dec.img != nil && len(dec.img.frames) > 0 ? 1 : 0
}

ImageTrackList_item :: proc(c: ^Call, list: Api_ImageTrackList, index: u32) -> (u64, Api_Error) {
	if list.data == nil || index != 0 { return 0, .Not_Found }
	dec := image_decoder_from(c.page, list.data.decoder)
	if dec == nil { return 0, .Not_Found }
	return object_create(c.page, &image_track_vt, new_clone(Image_Track_Obj{page = c.page, decoder = list.data.decoder, index = 0}), c.owner), .None
}

// The selected track index (-1 when none / not decoded yet).
ImageTrackList_selectedIndex :: proc(c: ^Call, list: Api_ImageTrackList) -> i32 {
	if list.data == nil { return -1 }
	dec := image_decoder_from(c.page, list.data.decoder)
	if dec == nil || dec.img == nil || len(dec.img.frames) == 0 { return -1 }
	return i32(dec.selected_track)
}

ImageTrack_animated :: proc(c: ^Call, t: Api_ImageTrack) -> bool {
	dec := track_decoder(c.page, t.data)
	if dec == nil { return false }
	image_decoder_ensure(dec)
	return dec.info.animated
}

ImageTrack_frameCount :: proc(c: ^Call, t: Api_ImageTrack) -> u32 {
	dec := track_decoder(c.page, t.data)
	if dec == nil { return 0 }
	image_decoder_ensure(dec)
	return dec.img == nil ? 0 : u32(len(dec.img.frames))
}

// repetitionCount: how many times an animation repeats. 0 = play once (no repeat); the host's info.plays is the total
// plays (0 = forever -> Infinity, reported as -1 which the engine maps to Infinity).
ImageTrack_repetitionCount :: proc(c: ^Call, t: Api_ImageTrack) -> i32 {
	dec := track_decoder(c.page, t.data)
	if dec == nil { return 0 }
	image_decoder_ensure(dec)
	if !dec.info.animated { return 0 }
	if dec.info.plays == 0 { return -1 }   // forever -> Infinity
	return i32(max(dec.info.plays - 1, 0))
}

ImageTrack_selected :: proc(c: ^Call, t: Api_ImageTrack) -> bool {
	dec := track_decoder(c.page, t.data)
	return dec != nil && t.data != nil && t.data.index == dec.selected_track
}

@(private)
track_decoder :: proc(p: ^Page, t: ^Image_Track_Obj) -> ^Image_Decoder_Obj {
	if t == nil { return nil }
	return image_decoder_from(p, t.decoder)
}

@(private)
image_decoder_from :: proc(p: ^Page, h: u64) -> ^Image_Decoder_Obj { return (^Image_Decoder_Obj)(object_data(p, h, &image_decoder_vt)) }

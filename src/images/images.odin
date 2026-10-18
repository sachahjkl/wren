// Package images: image files into pixels. Decoding is done by the platform, Windows Imaging Component (WIC), on
// threads of this package (pool.odin) that each join the COM multithreaded apartment; nothing here runs on the UI thread
// unless a caller asks for the synchronous entry points (tests, tools).
//
// What comes out is always RGBA8 with straight (non-premultiplied) alpha, in sRGB, rows top-down, `stride` bytes apart:
// the byte order R, G, B, A. That is the layout the graphics toolkit uploads (render.update_texture_rgba). Embedded
// colour profiles are not applied: pixels are taken as sRGB, as most browsers do for untagged images.
//
// Formats: PNG (first frame: WIC does not animate APNG), JPEG (EXIF orientation applied), GIF (every frame of an
// animation composed onto the logical screen with its delay and disposal method, plus the loop count), BMP, ICO / CUR
// (the best size), TIFF (first page), and WebP, AVIF, HEIF when the Windows codecs are installed (Microsoft Store: "WebP
// Image Extensions", "AV1 Video Extension", "HEIF Image Extensions"); without them those fail with Codec_Missing. SVG is
// recognised and refused with Unsupported_Format: it is a document, not a raster format, and this browser has no SVG
// renderer yet.
//
// The type is found from the bytes (MIME Sniffing §6.1 image patterns), never trusted from the Content-Type, except that
// an XML type (image/svg+xml) means SVG, and with `X-Content-Type-Options: nosniff` a non-image type is refused.
//
// Hostile input: every limit (Limits) is checked from the headers before a pixel is allocated: encoded bytes, width and
// height, pixel count, frame count, and the memory the decoded frames would take. A file that announces 100 000 x
// 100 000 pixels fails with Too_Many_Pixels without allocating; a truncated or malformed one with Corrupt.
package images

import "base:runtime"
import "core:strings"

Format :: enum u8 { Unknown, Png, Jpeg, Gif, Webp, Bmp, Ico, Tiff, Avif, Heif, Svg }

Error :: enum u8 {
	None,
	Empty,
	Unknown_Format,       // no image signature (or nosniff with a type that is not an image)
	Unsupported_Format,   // recognised, not decoded here (SVG)
	Codec_Missing,        // WebP / AVIF / HEIF and the Windows codec is not installed
	Too_Many_Bytes,       // the encoded file is over Limits.max_encoded_bytes
	Too_Large_Dimension,  // a side is over Limits.max_dimension
	Too_Many_Pixels,      // width x height over Limits.max_pixels
	Too_Many_Frames,
	Too_Much_Memory,      // the decoded frames would take more than Limits.max_image_bytes
	Corrupt,              // the decoder refused the data: truncated, malformed
	Platform,             // COM or WIC could not be used on this thread
	Cancelled,
}

error_message :: proc(e: Error) -> string {
	switch e {
	case .None: return "no error"
	case .Empty: return "empty file"
	case .Unknown_Format: return "not an image (unrecognised format)"
	case .Unsupported_Format: return "unsupported image format (SVG is not supported)"
	case .Codec_Missing: return "no decoder installed for this format (Windows codec extension missing)"
	case .Too_Many_Bytes: return "image file too large (images.max_encoded_bytes)"
	case .Too_Large_Dimension: return "image too wide or too tall (images.max_dimension)"
	case .Too_Many_Pixels: return "image has too many pixels (images.max_pixels)"
	case .Too_Many_Frames: return "animation has too many frames (images.max_frames)"
	case .Too_Much_Memory: return "decoded image would use too much memory (images.max_image_bytes)"
	case .Corrupt: return "image data is corrupt or truncated"
	case .Platform: return "the imaging component of the system is unavailable"
	case .Cancelled: return "cancelled"
	}
	return "error"
}

format_name :: proc(f: Format) -> string {
	switch f {
	case .Unknown: return "unknown"
	case .Png: return "PNG"
	case .Jpeg: return "JPEG"
	case .Gif: return "GIF"
	case .Webp: return "WebP"
	case .Bmp: return "BMP"
	case .Ico: return "ICO"
	case .Tiff: return "TIFF"
	case .Avif: return "AVIF"
	case .Heif: return "HEIF"
	case .Svg: return "SVG"
	}
	return "?"
}

// Every bound a decode respects. Filled from preferences (settings.odin).
Limits :: struct {
	max_encoded_bytes: int,
	max_dimension:     int,
	max_pixels:        i64,
	max_frames:        int,
	max_image_bytes:   i64,   // decoded size of one image, every frame included
	min_delay_ms:      int,   // animation frames shorter than this get default_delay_ms (what browsers do with 0 / 10 ms)
	default_delay_ms:  int,
}

LIMITS_DEFAULT :: Limits{
	max_encoded_bytes = 64 << 20, max_dimension = 32768, max_pixels = 64_000_000, max_frames = 2000,
	max_image_bytes = 512 << 20, min_delay_ms = 11, default_delay_ms = 100,
}

// What the headers say, known before (or without) decoding the pixels.
Info :: struct {
	format:      Format,
	width:       int,     // natural size in image pixels, EXIF orientation applied (GIF: the logical screen)
	height:      int,
	frames:      int,     // what the container holds (GIF: animation frames; ICO: icon sizes; TIFF: pages)
	animated:    bool,    // more than one frame to show in turn (GIF only)
	orientation: u8,      // EXIF orientation 1..8 (1 = as stored)
	plays:       int,     // animated: how many times the animation runs, 0 = forever
}

// One frame of an image, full size: animation frames are already composed (disposal applied), ready to show as is.
Frame :: struct {
	pixels:   []u8,   // RGBA8, straight alpha, sRGB, top-down, Image.stride bytes per row
	delay_ms: int,    // how long it stays (animations), already normalised by the limits
}

Image :: struct {
	info:        Info,
	width:       int,     // of the pixels: equal to info.width / height, or smaller when decoded at a reduced size
	height:      int,
	stride:      int,
	frames:      []Frame,
	duration_ms: int,     // one play of the animation (sum of the delays)
	bytes:       int,     // memory the pixels hold
	reduced:     bool,    // decoded smaller than the natural size
	allocator:   runtime.Allocator,
}

image_destroy :: proc(img: ^Image) {
	if img == nil { return }
	context.allocator = img.allocator
	for f in img.frames { delete(f.pixels) }
	delete(img.frames)
	free(img)
}

Decode_Options :: struct {
	limits:    Limits,
	// The size it will be shown at, in image pixels after orientation; 0 = natural size. An image much larger than that
	// (reduction factor under `downscale_below`) is decoded directly at the smaller size. Animations always decode at
	// their natural size.
	target_w, target_h: int,
	downscale_below: f32,
	first_frame_only: bool,   // animations: only the first frame (Info still reports them all)
	allow_truncated: bool,    // show what a file cut short contains instead of failing with Corrupt
	mime:      string,        // the Content-Type essence the server sent ("" = none)
	nosniff:   bool,          // X-Content-Type-Options: nosniff came with the response
}

////////////////////////////////
// Sniffing (MIME Sniffing §6.1, §7.1 "rules for sniffing images specifically")

@(private)
is_xml_mime :: proc(m: string) -> bool {
	return strings.has_suffix(m, "+xml") || m == "text/xml" || m == "application/xml"
}

// Format of `data`, from its signature. `supplied` is the Content-Type essence (lower case), "" if none.
sniff :: proc(data: []byte, supplied := "", nosniff := false) -> Format {
	m := strings.to_lower(strings.trim_space(supplied), context.temp_allocator)
	if is_xml_mime(m) { return m == "image/svg+xml" || looks_like_svg(data) ? .Svg : .Unknown }
	if nosniff && m != "" && !strings.has_prefix(m, "image/") { return .Unknown }
	f := sniff_signature(data)
	if f == .Unknown && looks_like_svg(data) { f = .Svg }
	return f
}

@(private)
has_prefix_bytes :: proc(data: []byte, sig: string) -> bool {
	return len(data) >= len(sig) && string(data[:len(sig)]) == sig
}

sniff_signature :: proc(data: []byte) -> Format {
	switch {
	case has_prefix_bytes(data, "\x89PNG\r\n\x1a\n"): return .Png
	case has_prefix_bytes(data, "\xff\xd8\xff"): return .Jpeg
	case has_prefix_bytes(data, "GIF87a"), has_prefix_bytes(data, "GIF89a"): return .Gif
	case has_prefix_bytes(data, "BM"): return .Bmp
	case has_prefix_bytes(data, "\x00\x00\x01\x00"), has_prefix_bytes(data, "\x00\x00\x02\x00"): return .Ico
	case len(data) >= 14 && string(data[:4]) == "RIFF" && string(data[8:14]) == "WEBPVP": return .Webp
	case has_prefix_bytes(data, "II*\x00"), has_prefix_bytes(data, "MM\x00*"): return .Tiff
	}
	// ISO base media file: [size][ftyp][major brand][minor version][compatible brands...]
	if len(data) >= 16 && string(data[4:8]) == "ftyp" {
		box := int(data[0]) << 24 | int(data[1]) << 16 | int(data[2]) << 8 | int(data[3])
		end := min(max(box, 16), len(data), 256)
		heif := false
		for at := 8; at + 4 <= end; at += 4 {
			if at == 12 { continue }   // minor version
			switch string(data[at:at + 4]) {
			case "avif", "avis": return .Avif
			case "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1": heif = true
			}
		}
		if heif { return .Heif }
	}
	return .Unknown
}

@(private)
looks_like_svg :: proc(data: []byte) -> bool {
	s := string(data[:min(len(data), 1024)])
	s = strings.trim_prefix(s, "\xef\xbb\xbf")
	s = strings.trim_left_space(s)
	return strings.has_prefix(s, "<svg") || (strings.has_prefix(s, "<?xml") && strings.contains(s, "<svg"))
}

////////////////////////////////
// Limits

@(private)
check_size :: proc(w, h: int, l: Limits) -> Error {
	if w <= 0 || h <= 0 { return .Corrupt }
	if w > l.max_dimension || h > l.max_dimension { return .Too_Large_Dimension }
	if i64(w) * i64(h) > l.max_pixels { return .Too_Many_Pixels }
	if i64(w) * i64(h) * 4 > l.max_image_bytes { return .Too_Much_Memory }
	return .None
}

// Size to decode at for a display size: the natural size, or a smaller one keeping the aspect ratio.
reduced_size :: proc(w, h, target_w, target_h: int, below: f32) -> (int, int, bool) {
	if target_w <= 0 || target_h <= 0 || below <= 0 || w <= 0 || h <= 0 { return w, h, false }
	s := max(f64(target_w) / f64(w), f64(target_h) / f64(h))
	if s >= f64(below) || s >= 1 { return w, h, false }
	rw := max(int(f64(w) * s + 0.999), 1)
	rh := max(int(f64(h) * s + 0.999), 1)
	return rw, rh, true
}

////////////////////////////////
// Orientation (EXIF tag 274): the stored pixels are turned into the upright image

// Dimensions after orientation.
oriented :: proc(w, h: int, o: u8) -> (int, int) { return o >= 5 && o <= 8 ? h : w, o >= 5 && o <= 8 ? w : h }

// A new buffer with the pixels of `src` (w x h, tightly packed RGBA) upright. Orientation 1 (or unknown) copies.
apply_orientation :: proc(src: []u8, w, h: int, o: u8, allocator := context.allocator) -> (dst: []u8, dw, dh: int) {
	dw, dh = oriented(w, h, o)
	dst = make([]u8, len(src), allocator)
	if o <= 1 || o > 8 { copy(dst, src); return }
	for y in 0 ..< h {
		for x in 0 ..< w {
			// where the stored pixel (x, y) lands in the upright image
			nx, ny: int
			switch o {
			case 2: nx, ny = w - 1 - x, y              // mirrored horizontally
			case 3: nx, ny = w - 1 - x, h - 1 - y      // rotated 180
			case 4: nx, ny = x, h - 1 - y              // mirrored vertically
			case 5: nx, ny = y, x                      // transposed
			case 6: nx, ny = h - 1 - y, x              // rotated 90 clockwise
			case 7: nx, ny = h - 1 - y, w - 1 - x      // transversed
			case 8: nx, ny = y, w - 1 - x              // rotated 90 counter-clockwise
			}
			s := (y * w + x) * 4
			d := (ny * dw + nx) * 4
			dst[d], dst[d + 1], dst[d + 2], dst[d + 3] = src[s], src[s + 1], src[s + 2], src[s + 3]
		}
	}
	return
}

////////////////////////////////
// GIF composition (GIF89a §23: disposal methods). Pure, so it is tested on its own.

Disposal :: enum u8 { Unspecified = 0, Keep = 1, Background = 2, Previous = 3 }

// One frame as the file stores it: a rectangle of the logical screen.
Raw_Frame :: struct {
	x, y, w, h: int,
	pixels:     []u8,   // RGBA, w x h, tightly packed; alpha 0 = transparent index
	delay_cs:   int,    // hundredths of a second, as in the Graphic Control Extension
	disposal:   Disposal,
}

// State of the composition across frames: the canvas and what disposal method 3 restores.
Composer :: struct {
	w, h:     int,
	canvas:   []u8,
	saved:    []u8,
	prev:     Raw_Frame,   // geometry and disposal of the previous frame (pixels not kept)
	has_prev: bool,
}

composer_init :: proc(c: ^Composer, w, h: int, allocator := context.allocator) {
	c.w, c.h = w, h
	c.canvas = make([]u8, w * h * 4, allocator)   // the background is transparent, as in every browser
	c.has_prev = false
}

composer_destroy :: proc(c: ^Composer, allocator := context.allocator) {
	delete(c.canvas, allocator)
	delete(c.saved, allocator)
	c^ = {}
}

// Draws `f` after disposing of the previous frame; the canvas is then the full picture of this frame.
composer_add :: proc(c: ^Composer, f: Raw_Frame, allocator := context.allocator) {
	if c.has_prev {
		p := c.prev
		switch p.disposal {
		case .Unspecified, .Keep:
		case .Background: clear_rect(c, p.x, p.y, p.w, p.h)
		case .Previous: if c.saved != nil { copy(c.canvas, c.saved) }
		}
	}
	if f.disposal == .Previous {
		if c.saved == nil { c.saved = make([]u8, len(c.canvas), allocator) }
		copy(c.saved, c.canvas)
	}
	x0, y0 := max(f.x, 0), max(f.y, 0)
	x1, y1 := min(f.x + f.w, c.w), min(f.y + f.h, c.h)
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			s := ((y - f.y) * f.w + (x - f.x)) * 4
			if f.pixels[s + 3] == 0 { continue }
			d := (y * c.w + x) * 4
			copy(c.canvas[d:d + 4], f.pixels[s:s + 4])
		}
	}
	c.prev = Raw_Frame{x = f.x, y = f.y, w = f.w, h = f.h, disposal = f.disposal}
	c.has_prev = true
}

@(private)
clear_rect :: proc(c: ^Composer, x, y, w, h: int) {
	x0, y0 := max(x, 0), max(y, 0)
	x1, y1 := min(x + w, c.w), min(y + h, c.h)
	for yy in y0 ..< y1 {
		row := c.canvas[(yy * c.w + x0) * 4:(yy * c.w + x1) * 4]
		for &b in row { b = 0 }
	}
}

// Delay of a frame in ms, with the limits' treatment of the (very common) 0 and 10 ms delays.
frame_delay_ms :: proc(delay_cs: int, l: Limits) -> int {
	ms := delay_cs * 10
	if ms < l.min_delay_ms { ms = l.default_delay_ms }
	return max(ms, 1)
}

// Loop count of the NETSCAPE2.0 / ANIMEXTS1.0 application extension, as total plays (0 = forever). `data` is the
// extension's data sub-blocks as WIC returns them: [size=3][1][count lo][count hi]...
plays_from_loop_extension :: proc(data: []u8) -> (plays: int, ok: bool) {
	if len(data) < 4 || data[0] < 3 || data[1] != 1 { return 0, false }
	n := int(data[2]) | int(data[3]) << 8
	return n == 0 ? 0 : n + 1, true   // "loop n times" repeats after the first play
}

// The frame to show `t_ms` after the animation started, and when the next change is due (ms after start; < 0 = never:
// the animation ended or is still).
animation_frame_at :: proc(img: ^Image, t_ms: f64) -> (index: int, next_ms: f64) {
	n := len(img.frames)
	if n <= 1 || img.duration_ms <= 0 { return 0, -1 }
	t := max(t_ms, 0)
	d := f64(img.duration_ms)
	play := int(t / d)
	if img.info.plays > 0 && play >= img.info.plays { return n - 1, -1 }
	at := t - f64(play) * d
	acc: f64
	for f, i in img.frames {
		acc += f64(f.delay_ms)
		if at < acc { return i, f64(play) * d + acc }
	}
	return n - 1, f64(play + 1) * d
}

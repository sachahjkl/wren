package blocker

import "core:encoding/base64"
import "core:hash"
import "core:strings"
import "wb:fetch"

// The neutral stand-ins a blocked request can be answered with (`$redirect=noop.js`, `$redirect=1x1.gif`...). Scripts
// are small stand-ins written for this browser: they define the global objects pages expect from the real thing
// (analytics, tag managers, ad slots) with functions that do nothing, so a page that waits for them carries on. Images
// and media are generated (a transparent PNG of any size, a silent MP3 frame run).

@(private) JS_NOOP         :: #load("resources/noop.js", string)
@(private) JS_GA           :: #load("resources/ga.js", string)
@(private) JS_ANALYTICS    :: #load("resources/analytics.js", string)
@(private) JS_GTM          :: #load("resources/gtm.js", string)
@(private) JS_GPT          :: #load("resources/gpt.js", string)
@(private) JS_ADSBYGOOGLE  :: #load("resources/adsbygoogle.js", string)
@(private) JS_BEACON       :: #load("resources/beacon.js", string)
@(private) JS_APSTAG       :: #load("resources/apstag.js", string)
@(private) JS_NOBAB        :: #load("resources/nobab.js", string)
@(private) JS_CHARTBEAT    :: #load("resources/chartbeat.js", string)
@(private) JS_LINKID       :: #load("resources/inpage_linkid.js", string)
@(private) JS_INSTREAM     :: #load("resources/instream.js", string)
@(private) JS_OUTBRAIN     :: #load("resources/outbrain.js", string)
@(private) CSS_NOOP        :: #load("resources/noop.css", string)
@(private) HTML_NOOP       :: #load("resources/noop.html", string)

Resource_Kind :: enum u8 { Js, Css, Html, Text, Gif, Png, Mp3, Mp4, Empty }

Stand_In :: struct {
	name:  string,         // canonical
	kind:  Resource_Kind,
	text:  string,         // Js / Css / Html / Text
	w, h:  int,            // Png
}

STAND_INS := [?]Stand_In{
	{"noop.js", .Js, JS_NOOP, 0, 0},
	{"google-analytics.com/ga.js", .Js, JS_GA, 0, 0},
	{"google-analytics.com/analytics.js", .Js, JS_ANALYTICS, 0, 0},
	{"google-analytics.com/inpage_linkid.js", .Js, JS_LINKID, 0, 0},
	{"googletagmanager.com/gtm.js", .Js, JS_GTM, 0, 0},
	{"googletagservices.com/gpt.js", .Js, JS_GPT, 0, 0},
	{"googlesyndication.com/adsbygoogle.js", .Js, JS_ADSBYGOOGLE, 0, 0},
	{"scorecardresearch.com/beacon.js", .Js, JS_BEACON, 0, 0},
	{"amazon_apstag.js", .Js, JS_APSTAG, 0, 0},
	{"doubleclick.net/instream/ad_status.js", .Js, JS_INSTREAM, 0, 0},
	{"nobab.js", .Js, JS_NOBAB, 0, 0},
	{"chartbeat.js", .Js, JS_CHARTBEAT, 0, 0},
	{"outbrain-widget.js", .Js, JS_OUTBRAIN, 0, 0},
	{"noop.css", .Css, CSS_NOOP, 0, 0},
	{"noop.html", .Html, HTML_NOOP, 0, 0},
	{"noop.txt", .Text, "", 0, 0},
	{"empty", .Empty, "", 0, 0},
	{"noop-0.1s.mp3", .Mp3, "", 0, 0},
	{"noop-1s.mp4", .Mp4, "", 0, 0},
	{"1x1.gif", .Gif, "", 1, 1},
	{"2x2.png", .Png, "", 2, 2},
	{"3x2.png", .Png, "", 3, 2},
	{"32x32.png", .Png, "", 32, 32},
}

// uBO's and ABP's other names for the same stand-ins.
@(private)
resource_alias :: proc(n: string) -> string {
	switch n {
	case "noopjs", "noop.js": return "noop.js"
	case "noopcss": return "noop.css"
	case "noopframe", "noop.html": return "noop.html"
	case "nooptext", "noop.txt": return "noop.txt"
	case "noopmp3-0.1s", "noop-0.1s.mp3": return "noop-0.1s.mp3"
	case "noopmp4-1s", "noop-1s.mp4": return "noop-1s.mp4"
	case "1x1-transparent.gif", "1x1.gif": return "1x1.gif"
	case "2x2-transparent.png", "2x2.png": return "2x2.png"
	case "3x2-transparent.png", "3x2.png": return "3x2.png"
	case "32x32-transparent.png", "32x32.png": return "32x32.png"
	case "google-analytics_ga.js", "ga.js", "google-analytics.com/ga.js": return "google-analytics.com/ga.js"
	case "google-analytics_analytics.js", "analytics.js", "google-analytics.com/analytics.js": return "google-analytics.com/analytics.js"
	case "google-analytics_inpage_linkid.js", "google-analytics.com/inpage_linkid.js": return "google-analytics.com/inpage_linkid.js"
	case "googletagmanager_gtm.js", "googletagmanager.com/gtm.js": return "googletagmanager.com/gtm.js"
	case "googletagservices_gpt.js", "googletagservices.com/gpt.js", "google-ima.js": return "googletagservices.com/gpt.js"
	case "googlesyndication_adsbygoogle.js", "googlesyndication.com/adsbygoogle.js": return "googlesyndication.com/adsbygoogle.js"
	case "scorecardresearch_beacon.js", "scorecardresearch.com/beacon.js": return "scorecardresearch.com/beacon.js"
	case "amazon_ads.js", "amazon_apstag.js": return "amazon_apstag.js"
	case "doubleclick_instream_ad_status.js", "doubleclick.net/instream/ad_status.js": return "doubleclick.net/instream/ad_status.js"
	case "nobab.js", "nobab", "bab-defuser.js", "fuckadblock.js-3.2.0", "fuckadblock.js", "prebid-ads.js": return "nobab.js"
	case "chartbeat.js": return "chartbeat.js"
	case "outbrain-widget.js": return "outbrain-widget.js"
	}
	return n
}

Resource_Data :: struct {
	mime: string,
	data: []byte,
}

// Resource bytes by name (any alias). `dest` picks the type of `empty`. ok = false for a name nobody defines.
resource_find :: proc(name_in: string, dest: fetch.Destination) -> (res: Resource_Data, ok: bool) {
	name := name_in
	if c := strings.last_index_byte(name, ':'); c > 0 && c + 1 < len(name) && name[c + 1] >= '0' && name[c + 1] <= '9' { name = name[:c] }
	name = resource_alias(name)
	for &s in STAND_INS {
		if s.name != name { continue }
		return resource_bytes(&s, dest), true
	}
	return {}, false
}

@(private) resource_cache: map[string][]byte

@(private)
resource_bytes :: proc(s: ^Stand_In, dest: fetch.Destination) -> Resource_Data {
	switch s.kind {
	case .Js: return {"text/javascript; charset=utf-8", transmute([]byte)s.text}
	case .Css: return {"text/css; charset=utf-8", transmute([]byte)s.text}
	case .Html: return {"text/html; charset=utf-8", transmute([]byte)s.text}
	case .Text: return {"text/plain; charset=utf-8", nil}
	case .Empty:
		#partial switch dest {
		case .Script, .Worker: return {"text/javascript; charset=utf-8", nil}
		case .Style: return {"text/css; charset=utf-8", nil}
		case .Document, .Iframe, .Frame: return {"text/html; charset=utf-8", nil}
		case .Image: return {"image/gif", generated("1x1.gif", .Gif, 1, 1)}
		}
		return {"text/plain; charset=utf-8", nil}
	case .Gif: return {"image/gif", generated(s.name, .Gif, 1, 1)}
	case .Png: return {"image/png", generated(s.name, .Png, s.w, s.h)}
	case .Mp3: return {"audio/mpeg", generated(s.name, .Mp3, 0, 0)}
	case .Mp4: return {"video/mp4", generated(s.name, .Mp4, 0, 0)}
	}
	return {}
}

// Generated once, kept for the life of the process (a few hundred bytes each).
@(private)
generated :: proc(name: string, kind: Resource_Kind, w, h: int) -> []byte {
	if b, ok := resource_cache[name]; ok { return b }
	if resource_cache == nil { resource_cache = make(map[string][]byte) }
	out: []byte
	switch kind {
	case .Gif:
		d, _ := base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
		out = d
	case .Png: out = make_png(w, h)
	case .Mp3: out = make_silent_mp3(5)
	case .Mp4: out = make_empty_mp4()
	case .Js, .Css, .Html, .Text, .Empty:
	}
	resource_cache[strings.clone(name)] = out
	return out
}

// A fully transparent RGBA PNG (stored deflate blocks: no compressor needed).
@(private)
make_png :: proc(w, h: int) -> []byte {
	raw := make([]byte, h * (1 + w * 4), context.temp_allocator)   // each row: filter 0 + RGBA zeros
	out := make([dynamic]byte)
	append(&out, 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a)
	chunk :: proc(out: ^[dynamic]byte, kind: string, data: []byte) {
		n := u32(len(data))
		append(out, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n))
		start := len(out^)
		append(out, kind)
		append(out, ..data)
		crc := hash.crc32(out[start:])
		append(out, byte(crc >> 24), byte(crc >> 16), byte(crc >> 8), byte(crc))
	}
	ihdr := []byte{byte(w >> 24), byte(w >> 16), byte(w >> 8), byte(w), byte(h >> 24), byte(h >> 16), byte(h >> 8), byte(h), 8, 6, 0, 0, 0}
	chunk(&out, "IHDR", ihdr)
	z := make([dynamic]byte, context.temp_allocator)
	append(&z, 0x78, 0x01)
	rest := raw
	for len(rest) > 0 || len(z) == 2 {
		n := min(len(rest), 65535)
		final: byte = n == len(rest) ? 1 : 0
		append(&z, final, byte(n), byte(n >> 8), byte(~n), byte(~n >> 8))
		append(&z, ..rest[:n])
		rest = rest[n:]
		if final == 1 { break }
	}
	a := hash.adler32(raw)
	append(&z, byte(a >> 24), byte(a >> 16), byte(a >> 8), byte(a))
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return out[:]
}

// MPEG-1 Layer III, 44.1 kHz, 128 kbit/s, stereo frames of zeros: silence.
@(private)
make_silent_mp3 :: proc(frames: int) -> []byte {
	out := make([]byte, frames * 417)
	for i in 0 ..< frames {
		o := i * 417
		out[o], out[o + 1], out[o + 2], out[o + 3] = 0xff, 0xfb, 0x90, 0x04
	}
	return out
}

// An MP4 with a file-type box and an empty movie box: a player opens it and finds nothing to play.
@(private)
make_empty_mp4 :: proc() -> []byte {
	ftyp := []byte{0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 2, 0, 'i', 's', 'o', 'm', 'm', 'p', '4', '1'}
	mvhd := make([]byte, 108, context.temp_allocator)
	mvhd[3] = 108
	copy(mvhd[4:8], "mvhd")
	mvhd[20], mvhd[21], mvhd[22], mvhd[23] = 0, 0, 0x03, 0xe8   // timescale 1000
	mvhd[32], mvhd[33] = 0x01, 0x00                              // rate 1.0
	mvhd[36] = 0x01                                              // volume 1.0
	mvhd[40], mvhd[56], mvhd[72] = 0x00, 0x00, 0x00
	mvhd[44], mvhd[60], mvhd[76], mvhd[92] = 0x01, 0x01, 0x40, 0x00
	moov := make([]byte, 8 + len(mvhd), context.temp_allocator)
	moov[3] = byte(len(moov))
	copy(moov[4:8], "moov")
	copy(moov[8:], mvhd)
	out := make([dynamic]byte, 0, len(ftyp) + len(moov))
	append(&out, ..ftyp)
	append(&out, ..moov)
	return out[:]
}

resources_destroy :: proc() {
	for k, v in resource_cache { delete(k); delete(v) }
	delete(resource_cache)
	resource_cache = nil
}

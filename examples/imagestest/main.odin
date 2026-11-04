// Guest of the images end-to-end tests (src/tools/webtests/images.odin), loaded into examples/site/images.html. It records the
// load / error events of every image (attribute data-events of #r, in the order they arrive), answers questions about
// HTMLImageElement state, and exercises decode() and Image_decode.
package imagestest

import "wren:core"
import "wren:dom"
import "wren:images"

r: dom.Element

IDS := [?]string{
	"simple", "sized", "dup1", "dup2", "jpeg", "ico", "tiff", "anim", "fit", "srcset", "wdesc", "pic",
	"broken", "missing", "empty", "bomb", "svg", "trunc", "nocors", "cors", "corsfail", "lazy", "late",
}

RED_PNG :: #load("../site/images/red.png")

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[len(buf) - 1] = '0'; return string(buf[len(buf) - 1:]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

Log :: struct { buf: [4096]u8, n: int }

note :: proc "contextless" (l: ^Log, s: string) {
	for i in 0 ..< len(s) { if l.n < len(l.buf) { l.buf[l.n] = s[i]; l.n += 1 } }
}
note_int :: proc "contextless" (l: ^Log, v: i64) { b: [24]u8; note(l, itoa(v, b[:])) }
text :: proc "contextless" (l: ^Log) -> string { return string(l.buf[:l.n]) }

set :: proc "contextless" (name, value: string) { dom.Element_setAttribute(r, name, value) }

events: Log

on_image_event :: proc "contextless" (user: i32, ev: core.Event) {
	tb: [16]u8
	ty, _ := core.Event_type(ev, tb[:])
	note(&events, IDS[user])
	note(&events, ":")
	note(&events, ty)
	note(&events, " ")
	set("data-events", text(&events))
}

listen :: proc "contextless" (i: int) {
	img := dom.Document_getElementById(IDS[i])
	if img == 0 { return }
	core.EventTarget_addEventListener(img, "load", on_image_event, i32(i))
	core.EventTarget_addEventListener(img, "error", on_image_event, i32(i))
}

@(export)
wb_main :: proc "contextless" () {
	r, _ = dom.Document_createElement("div")
	dom.Element_setAttribute(r, "id", "r")
	dom.Node_appendChild(dom.Document_body(), r)
	for _, i in IDS { listen(i) }
}

el :: proc "contextless" (i: i32) -> images.HTMLImageElement { return images.HTMLImageElement(dom.Document_getElementById(IDS[i])) }

@(export)
natural_width :: proc "contextless" (i: i32) -> i32 { return images.HTMLImageElement_naturalWidth(el(i)) }
@(export)
natural_height :: proc "contextless" (i: i32) -> i32 { return images.HTMLImageElement_naturalHeight(el(i)) }
@(export)
complete :: proc "contextless" (i: i32) -> i32 { return images.HTMLImageElement_complete(el(i)) ? 1 : 0 }

// currentSrc into data-src of #r.
@(export)
current_src :: proc "contextless" (i: i32) -> i32 {
	buf: [512]u8
	s, _ := images.HTMLImageElement_currentSrc(el(i), buf[:])
	set("data-src", s)
	n, _ := images.HTMLImageElement_currentSrc_len(el(i))
	return i32(n)
}

// Changes #simple's source, and returns its `complete` right after (0: the new image is not there yet).
@(export)
change_src :: proc "contextless" (which: i32) -> i32 {
	img := el(0)
	switch which {
	case 0: dom.Element_setAttribute(img, "src", "/images/f/blue.bmp?again")
	case 1: dom.Element_setAttribute(img, "src", "/images/f/fake.png")
	}
	return images.HTMLImageElement_complete(img) ? 1 : 0
}

// An <img> made by script and appended later (its events are recorded as "late").
@(export)
add_late :: proc "contextless" () {
	img, _ := dom.Document_createElement("img")
	dom.Element_setAttribute(img, "id", "late")
	core.EventTarget_addEventListener(img, "load", on_image_event, i32(len(IDS) - 1))
	core.EventTarget_addEventListener(img, "error", on_image_event, i32(len(IDS) - 1))
	dom.Element_setAttribute(img, "src", "/images/f/still.gif?late")
	dom.Node_appendChild(dom.Document_body(), img)
}

on_decoded :: proc "contextless" (user: i32, p: core.Promise, state: core.PromiseState) {
	name := user == 0 ? "data-decode-ok" : "data-decode-broken"
	set(name, state == .Fulfilled ? "fulfilled" : "rejected")
}

@(export)
decode_probe :: proc "contextless" () {
	core.Promise_then(images.HTMLImageElement_decode(el(0)), on_decoded, 0)    // #simple
	core.Promise_then(images.HTMLImageElement_decode(el(12)), on_decoded, 1)   // #broken
}

on_image_decoded :: proc "contextless" (user: i32, p: core.Promise, state: core.PromiseState) {
	if user == 1 {
		set("data-idecode-bad", state == .Rejected ? "rejected" : "fulfilled")
		return
	}
	if state != .Fulfilled { set("data-idecode", "rejected"); return }
	buf := core.Buffer(core.Promise_value(p))
	w, h := decode_size(p)
	px: [4]u8
	core.Buffer_read(buf, 0, px[:])
	l: Log
	note_int(&l, i64(w)); note(&l, "x"); note_int(&l, i64(h)); note(&l, " ")
	note_int(&l, core.Buffer_length(buf)); note(&l, " ")
	for v, i in px { if i > 0 { note(&l, ",") }; note_int(&l, i64(v)) }
	set("data-idecode", text(&l))
	core.Object_release(buf)
}

@(export)
image_decode_probe :: proc "contextless" () {
	good, _ := core.Buffer_create(RED_PNG)
	core.Promise_then(images.Image_decode(good), on_image_decoded, 0)
	junk := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	bad, _ := core.Buffer_create(junk[:])
	core.Promise_then(images.Image_decode(bad), on_image_decoded, 1)
}

// The "<width>x<height>" text of an Image_decode promise.
decode_size :: proc "contextless" (p: core.Promise) -> (w, h: int) {
	tb: [32]u8
	s, _ := core.Promise_text(p, tb[:])
	cur := &w
	for c in transmute([]u8)s {
		if c == 'x' { cur = &h; continue }
		if c >= '0' && c <= '9' { cur^ = cur^ * 10 + int(c - '0') }
	}
	return
}
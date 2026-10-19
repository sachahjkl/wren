package browser

import "toolkit:font"

// Text measurement for layout. Layout measures one word (or one space) at a time, the same words tens of thousands of
// times per page, from several threads at once (lay.Text_Api.concurrent): the toolkit shapes each word once
// (DirectWrite: fallback, ligatures, kerning, complex scripts) and keeps it in its sharded word cache, which is what this
// reads; the toolkit is free-threaded, so nothing here is locked.
//
// A per-character table of advances (what this file used to keep) would be wrong as soon as a font has ligatures or
// contextual kerning: the word cache is exact, and a hit costs a hash and a short lock of one shard of 64.

Measure :: struct {}

measure_destroy :: proc(m: ^Measure) { m^ = {} }

// Width of one line of text (one directional run); equal to `font.text_width`.
measure_width :: proc(m: ^Measure, fonts: ^font.State, id: font.Font_Id, size: f32, text: string) -> f32 {
	return font.measure(fonts, id, size, text)
}

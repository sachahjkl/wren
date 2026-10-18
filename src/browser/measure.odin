package browser

import "core:math"
import "toolkit:font"

// Text measurement for layout. The toolkit measures a string glyph by glyph, with a hash lookup, a kerning-table lookup
// (two glyph-index searches) and a scale computation per character; a page measures the same few hundred characters
// tens of thousands of times. This keeps, per (font, pixel size), the advance of each ASCII character and the kerning of
// each ASCII pair, computed once through the toolkit so the results are identical. Anything else falls back to the toolkit.

ASCII :: 128

Measure_Size :: struct {
	font: font.Font_Id,
	size: u16,
	adv:  [ASCII]f32,       // NaN = not computed yet
	kern: []f32,            // ASCII * ASCII, NaN = not computed yet
}

Measure :: struct {
	sizes: [dynamic]^Measure_Size,
	last:  ^Measure_Size,
}

measure_destroy :: proc(m: ^Measure) {
	for s in m.sizes { delete(s.kern); free(s) }
	delete(m.sizes)
	m^ = {}
}

@(private)
measure_size_for :: proc(m: ^Measure, id: font.Font_Id, size: f32) -> ^Measure_Size {
	px := u16(clamp(math.round(size), 1, 512))   // the toolkit rounds the same way
	if m.last != nil && m.last.font == id && m.last.size == px { return m.last }
	for s in m.sizes { if s.font == id && s.size == px { m.last = s; return s } }
	s := new(Measure_Size)
	s.font, s.size = id, px
	for i in 0 ..< ASCII { s.adv[i] = math.nan_f32() }
	s.kern = make([]f32, ASCII * ASCII)
	for i in 0 ..< len(s.kern) { s.kern[i] = math.nan_f32() }
	append(&m.sizes, s)
	m.last = s
	return s
}

// Width of one line of text; equal to `font.text_width`.
measure_width :: proc(m: ^Measure, fonts: ^font.State, id: font.Font_Id, size: f32, text: string) -> f32 {
	for i in 0 ..< len(text) { if text[i] >= ASCII { return font.text_width(fonts, id, size, text) } }
	s := measure_size_for(m, id, size)
	x: f32
	prev: u8
	for i in 0 ..< len(text) {
		c := text[i]
		if prev != 0 {
			k := s.kern[int(prev) * ASCII + int(c)]
			if k != k {   // NaN
				k = font.kern(fonts, id, f32(s.size), rune(prev), rune(c))
				s.kern[int(prev) * ASCII + int(c)] = k
			}
			x += k
		}
		a := s.adv[c]
		if a != a {
			a = font.glyph(fonts, id, size, rune(c)).advance
			s.adv[c] = a
		}
		x += a
		prev = c
	}
	return x
}

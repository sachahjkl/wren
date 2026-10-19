package browser

import "base:intrinsics"
import "core:math"
import "core:sync"
import "toolkit:font"

// Text measurement for layout. The toolkit measures a string glyph by glyph, with a hash lookup, a kerning-table lookup
// (two glyph-index searches) and a scale computation per character; a page measures the same few hundred characters
// tens of thousands of times. This keeps, per (font, pixel size), the advance of each Latin-1 character (ASCII and the
// accented letters of western languages) and the kerning of each pair of them, computed once through the toolkit so the
// results are identical. Anything else falls back to the toolkit.
//
// Layout measures from several threads at once (lay.Text_Api.concurrent): the tables are read without a lock, an entry
// not computed yet is filled under `mu`, which also serializes every call into the toolkit (its font state is not
// thread-safe). Each thread remembers the last table it used.

LATIN1 :: 256

Measure_Size :: struct {
	font: font.Font_Id,
	size: u16,
	adv:  [LATIN1]f32,      // NaN = not computed yet
	kern: []f32,            // LATIN1 * LATIN1, NaN = not computed yet
}

Measure :: struct {
	sizes: [dynamic]^Measure_Size,
	mu:    sync.Mutex,
	gen:   u64,             // tells a thread's remembered table apart from one of an earlier Measure (0: not yet)
}

@(private = "file")
measure_gens: u64

@(private = "file", thread_local)
tl_gen: u64
@(private = "file", thread_local)
tl_last: ^Measure_Size

measure_destroy :: proc(m: ^Measure) {
	for s in m.sizes { delete(s.kern); free(s) }
	delete(m.sizes)
	m^ = {}
}

@(private)
measure_size_for :: proc(m: ^Measure, id: font.Font_Id, size: f32) -> ^Measure_Size {
	px := u16(clamp(math.round(size), 1, 512))   // the toolkit rounds the same way
	gen := sync.atomic_load(&m.gen)
	if gen != 0 && tl_gen == gen && tl_last != nil && tl_last.font == id && tl_last.size == px { return tl_last }
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if m.gen == 0 { sync.atomic_store(&m.gen, sync.atomic_add(&measure_gens, 1) + 1) }
	found: ^Measure_Size
	for s in m.sizes { if s.font == id && s.size == px { found = s; break } }
	if found == nil {
		found = new(Measure_Size)
		found.font, found.size = id, px
		for i in 0 ..< LATIN1 { found.adv[i] = math.nan_f32() }
		found.kern = make([]f32, LATIN1 * LATIN1)
		for i in 0 ..< len(found.kern) { found.kern[i] = math.nan_f32() }
		append(&m.sizes, found)
	}
	tl_gen, tl_last = m.gen, found
	return found
}

@(private = "file")
load_f32 :: #force_inline proc(p: ^f32) -> f32 { return transmute(f32)intrinsics.atomic_load_explicit((^u32)(p), .Relaxed) }
@(private = "file")
store_f32 :: #force_inline proc(p: ^f32, v: f32) { intrinsics.atomic_store_explicit((^u32)(p), transmute(u32)v, .Relaxed) }

// Width of one line of text; equal to `font.text_width`.
measure_width :: proc(m: ^Measure, fonts: ^font.State, id: font.Font_Id, size: f32, text: string) -> f32 {
	// Latin-1 only: bytes below 0x80, or two-byte sequences C2 xx / C3 xx (U+0080..U+00FF)
	for i := 0; i < len(text); i += 1 {
		b := text[i]
		if b < 0x80 { continue }
		if (b == 0xC2 || b == 0xC3) && i + 1 < len(text) && text[i + 1] & 0xC0 == 0x80 { i += 1; continue }
		sync.mutex_lock(&m.mu)
		defer sync.mutex_unlock(&m.mu)
		return font.text_width(fonts, id, size, text)
	}
	s := measure_size_for(m, id, size)
	x: f32
	prev: int
	for i := 0; i < len(text); i += 1 {
		c := int(text[i])
		if c >= 0x80 { c = (c & 0x1F) << 6 | int(text[i + 1] & 0x3F); i += 1 }
		if prev != 0 {
			kp := &s.kern[prev * LATIN1 + c]
			k := load_f32(kp)
			if k != k {   // NaN
				sync.mutex_lock(&m.mu)
				k = font.kern(fonts, id, f32(s.size), rune(prev), rune(c))
				sync.mutex_unlock(&m.mu)
				store_f32(kp, k)
			}
			x += k
		}
		ap := &s.adv[c]
		a := load_f32(ap)
		if a != a {
			sync.mutex_lock(&m.mu)
			a = font.glyph(fonts, id, size, rune(c)).advance
			sync.mutex_unlock(&m.mu)
			store_f32(ap, a)
		}
		x += a
		prev = c
	}
	return x
}

package browser

// What the Network tab's font preview reads from a decoded sfnt (TrueType / OpenType) to describe a face without
// drawing it: the human names from the `name` table (family, subfamily, full name, version, copyright, license, the
// URL of the license), the glyph count from `maxp`, and, for a collection (.ttc / .otc, including a WOFF2 of one),
// the list of its faces. Everything is read straight from the bytes the webfont package produced; every offset and
// length is checked against the buffer so a hostile or truncated file is rejected, not trusted. The strings this
// returns are owned copies (UTF-8) that the caller frees.

import "core:strings"
import "core:unicode/utf16"
import "wb:webfont"

// The `name` table ids this preview shows (OpenType `name` Name IDs).
@(private = "file") NAME_COPYRIGHT :: 0
@(private = "file") NAME_FAMILY :: 1
@(private = "file") NAME_SUBFAMILY :: 2
@(private = "file") NAME_FULL :: 4
@(private = "file") NAME_VERSION :: 5
@(private = "file") NAME_TRADEMARK :: 7
@(private = "file") NAME_LICENSE :: 13
@(private = "file") NAME_LICENSE_URL :: 14
@(private = "file") NAME_TYPO_FAMILY :: 16          // the preferred (typographic) family / subfamily, when present
@(private = "file") NAME_TYPO_SUBFAMILY :: 17

// The named facts of a face. Every string is owned (cloned) and freed by Font_Meta_free; "" means absent.
Font_Meta :: struct {
	family:      string,
	subfamily:   string,   // the style ("Bold Italic", "Regular"...)
	full:        string,
	version:     string,
	copyright:   string,
	trademark:   string,
	license:     string,
	license_url: string,
	glyphs:      int,       // numGlyphs from `maxp`, 0 when unknown
}

font_meta_free :: proc(m: ^Font_Meta) {
	delete(m.family); delete(m.subfamily); delete(m.full); delete(m.version)
	delete(m.copyright); delete(m.trademark); delete(m.license); delete(m.license_url)
	m^ = {}
}

@(private = "file") be16 :: #force_inline proc(b: []byte, at: int) -> int { return int(b[at]) << 8 | int(b[at + 1]) }
@(private = "file") be32 :: #force_inline proc(b: []byte, at: int) -> u32 { return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]) }

// Reads the named facts and glyph count of a standalone sfnt. Missing or malformed tables leave their fields empty;
// this never fails (the preview can draw a face whose `name` table is unreadable).
font_meta_read :: proc(sfnt: []byte) -> Font_Meta {
	m: Font_Meta
	tables, err := webfont.read_tables(sfnt, context.temp_allocator)
	if err != .None { return m }
	find :: proc(ts: []webfont.Table, tag: string) -> (off, length: int, ok: bool) {
		t := u32(tag[0]) << 24 | u32(tag[1]) << 16 | u32(tag[2]) << 8 | u32(tag[3])
		for x in ts {
			if x.tag == t { return int(x.offset), int(x.length), true }
		}
		return 0, 0, false
	}
	if off, length, ok := find(tables, "maxp"); ok && length >= 6 && off + 6 <= len(sfnt) {
		m.glyphs = be16(sfnt, off + 4)
	}
	if off, length, ok := find(tables, "name"); ok {
		read_name_table(sfnt, off, length, &m)
	}
	// Prefer the typographic family / subfamily when the file carries them (they name the whole family, not the
	// 4-face Windows grouping); the loop in read_name_table already preferred them, nothing more to do here.
	return m
}

// A `name` table (OpenType `name`): a header, then a record array, then the string storage. Each record names a
// platform, an encoding, a language, a name id, a length and an offset into the storage. The preview keeps the
// English (or first) string of each id it shows, decoding UTF-16BE for the Windows / Unicode platforms and Latin-1
// for the Macintosh Roman platform. Every index is bounded by the table's own length.
@(private = "file")
read_name_table :: proc(sfnt: []byte, off, length: int, m: ^Font_Meta) {
	if off < 0 || length < 6 || off + length > len(sfnt) { return }
	tab := sfnt[off:off + length]
	count := be16(tab, 2)
	storage := be16(tab, 4)
	if count == 0 || count > 16384 { return }
	if 6 + 12 * count > length { return }
	// For each id, keep the string with the highest score (an English Windows/Unicode string beats the rest).
	set :: proc(dst: ^string, score: ^int, cand_score: int, s: string) {
		if s == "" { return }
		if dst^ == "" || cand_score > score^ {
			if dst^ != "" { delete(dst^) }
			dst^ = strings.clone(s)
			score^ = cand_score
		}
	}
	family_sc, sub_sc, full_sc, ver_sc, copy_sc, tm_sc, lic_sc, licurl_sc: int
	family_sc = -1; sub_sc = -1; full_sc = -1; ver_sc = -1; copy_sc = -1; tm_sc = -1; lic_sc = -1; licurl_sc = -1
	for i in 0 ..< count {
		rec := 6 + 12 * i
		platform := be16(tab, rec)
		// the encoding id (rec+2) is not needed: the platform alone decides UTF-16BE vs. single-byte here
		language := be16(tab, rec + 4)
		nid := be16(tab, rec + 6)
		slen := be16(tab, rec + 8)
		soff := be16(tab, rec + 10)
		at := storage + soff
		if slen == 0 || at < 0 || at + slen > length { continue }
		raw := tab[at:at + slen]
		s := decode_name_string(platform, raw)   // temp-allocated; freed with the temp arena
		if s == "" { continue }
		// score: prefer platform 3 (Windows) / 0 (Unicode), then English (0x0409 or Mac English 0).
		sc := 0
		if platform == 3 || platform == 0 { sc += 2 }
		if (platform == 3 && language == 0x0409) || (platform == 1 && language == 0) || (platform == 0) { sc += 1 }
		switch nid {
		case NAME_FAMILY:        set(&m.family, &family_sc, sc, s)
		case NAME_TYPO_FAMILY:   set(&m.family, &family_sc, sc + 10, s)   // typographic family wins over the legacy one
		case NAME_SUBFAMILY:     set(&m.subfamily, &sub_sc, sc, s)
		case NAME_TYPO_SUBFAMILY: set(&m.subfamily, &sub_sc, sc + 10, s)
		case NAME_FULL:          set(&m.full, &full_sc, sc, s)
		case NAME_VERSION:       set(&m.version, &ver_sc, sc, s)
		case NAME_COPYRIGHT:     set(&m.copyright, &copy_sc, sc, s)
		case NAME_TRADEMARK:     set(&m.trademark, &tm_sc, sc, s)
		case NAME_LICENSE:       set(&m.license, &lic_sc, sc, s)
		case NAME_LICENSE_URL:   set(&m.license_url, &licurl_sc, sc, s)
		}
	}
}

// A `name` string's bytes as UTF-8. Windows (3) and Unicode (0) platforms store UTF-16BE; Macintosh (1) Roman is
// read as Latin-1 (good enough for the ASCII that dominates font names). Returns an owned, temp-allocated string.
@(private = "file")
decode_name_string :: proc(platform: int, raw: []byte) -> string {
	is_utf16 := platform == 3 || platform == 0 || (platform == 2)
	if is_utf16 {
		n := len(raw) / 2
		if n == 0 { return "" }
		units := make([]u16, n, context.temp_allocator)
		for i in 0 ..< n { units[i] = u16(raw[2 * i]) << 8 | u16(raw[2 * i + 1]) }
		buf := make([]byte, n * 4 + 4, context.temp_allocator)
		w := utf16.decode_to_utf8(buf, units)
		return clean_name(string(buf[:w]))
	}
	// Macintosh Roman and the rest: treat high bytes as Latin-1 code points.
	b := strings.builder_make(context.temp_allocator)
	for c in raw { strings.write_rune(&b, rune(c)) }
	return clean_name(strings.to_string(b))
}

// Trims whitespace and drops NUL and control characters a `name` record may carry.
@(private = "file")
clean_name :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if t == "" { return "" }
	has_bad := false
	for c in t { if c < 0x20 && c != '\t' { has_bad = true; break } }
	if !has_bad { return t }
	b := strings.builder_make(context.temp_allocator)
	for c in t { if c >= 0x20 || c == '\t' { strings.write_rune(&b, c) } }
	return strings.trim_space(strings.to_string(b))
}

////////////////////////////////
// Collections

// The number of faces a TrueType / OpenType collection (`ttcf`) holds, or 0 when `data` is not a collection or its
// header is malformed. Bounds-checked: the count and the face-offset array must lie inside the buffer.
font_collection_count :: proc(data: []byte) -> int {
	if len(data) < 12 { return 0 }
	if be32(data, 0) != webfont.TAG_TTCF { return 0 }
	n := int(be32(data, 8))
	if n <= 0 || n > 65536 || 12 + 4 * n > len(data) { return 0 }
	return n
}

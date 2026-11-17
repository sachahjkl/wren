package fuzz

import "wb:webfont"

// The bound the browser gives a decoded font (webfont preferences): large enough for real fonts, small enough that a
// WOFF2 that announces gigabytes is refused.
WEBFONT_MAX_BYTES :: 16 << 20

WEBFONT_FILES := []Seed_Files{{dir = "examples/site/fonts", suffixes = {".ttf", ".otf", ".woff", ".woff2", ".ttc"}}, {dir = "native/media/tests", suffixes = {".ttf", ".otf", ".woff", ".woff2", ".ttc"}}}

WEBFONT_SEEDS := []string{
	"\x00\x01\x00\x00\x00\x01\x00\x10\x00\x00\x00\x00head\x00\x00\x00\x00\x00\x00\x00\x1c\x00\x00\x00\x36",
	"OTTO\x00\x00\x00\x00\x00\x00\x00\x00",
	"ttcf\x00\x01\x00\x00\x00\x00\x00\x02\x00\x00\x00\x14\xff\xff\xff\xf0",
	"wOFF\x00\x01\x00\x00\x00\x00\x00\x40\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00head\x00\x00\x00\x2c\x00\x00\x00\x10\x00\x00\x00\x36\x00\x00\x00\x00",
	"wOF2\x00\x01\x00\x00\x00\x00\x00\x40\x00\x01\x00\x00\x7f\xff\xff\xff\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
}

WEBFONT_TOKENS := []string{
	"\x00\x01\x00\x00", "OTTO", "true", "ttcf", "wOFF", "wOF2", "head", "hhea", "maxp", "cmap", "glyf", "loca", "hmtx", "name", "post",
	"OS/2", "CFF ", "CFF2", "COLR", "CPAL", "sbix", "SVG ", "GSUB", "GPOS", "\xff\xff\xff\xff", "\x7f\xff\xff\xff", "\x00\x00\x00\x00",
}

target_webfont :: proc(data: []u8) {
	sfnt, _, _ := webfont.decode(data, WEBFONT_MAX_BYTES)
	if sfnt != nil { _, _ = webfont.read_tables(sfnt, context.temp_allocator) }
	delete(sfnt)
	_, _ = webfont.read_tables(data, context.temp_allocator)
	// (a collection's other faces: the browser asks for the face a @font-face names)
	face, _ := webfont.collection_face(data, len(data) % 4, WEBFONT_MAX_BYTES)
	delete(face)
}

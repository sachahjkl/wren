package style

import "core:fmt"
import "core:strings"
import "wb:css"

// `cursor` (CSS Basic User Interface 4 §5.1.1): a list of images, each with an optional hotspot, then a keyword.
//   cursor: [ [ <url> | <url-set> ] [ <x> <y> ]? ]#? , <keyword>      (<url-set>: image-set() / -webkit-image-set())
// The keyword is Computed.cursor; the images, in order, Computed.cursor_images (nil: none). The shell shows the first
// image that loads and is usable as a cursor, else the keyword.

// One candidate of an image: its URL as written (resolved against its sheet by the loader, as background images are)
// and its density (image pixels per CSS pixel: 1 for url(), the resolution of an image-set() candidate).
Cursor_Image_Src :: struct {
	url:     string,
	density: f32,
}

Cursor_Image :: struct {
	srcs:        []Cursor_Image_Src,   // url(): one; image-set(): the candidates whose type is supported
	hotspot:     [2]f32,               // image pixels at density 1 (CSS pixels of the image)
	has_hotspot: bool,                 // else the image's own (a .cur file's), else 0 0
}

// The keyword as CSS writes it.
cursor_keyword_name :: proc(c: Cursor) -> string {
	name := fmt.tprint(c)
	b := make([]u8, len(name), context.temp_allocator)
	for i in 0 ..< len(name) {
		ch := name[i]
		switch {
		case ch == '_': b[i] = '-'
		case ch >= 'A' && ch <= 'Z': b[i] = ch + 32
		case: b[i] = ch
		}
	}
	return string(b)
}

@(private)
cursor_keyword :: proc(v: css.Value) -> (Cursor, bool) {
	if !tok_is(v, .Ident) { return {}, false }
	id := css.lower_temp(v.tok.text)
	if strings.has_prefix(id, "-webkit-") {
		switch id[8:] {
		case "grab", "grabbing", "zoom-in", "zoom-out": id = id[8:]
		case: return {}, false
		}
	}
	o := single(v)
	return parse_enum(o[:], Cursor)
}

// The resolution of an image-set() candidate (`2x`, `2dppx`, `192dpi`, `75.6dpcm`), in dppx.
@(private)
cursor_resolution :: proc(v: css.Value) -> (f32, bool) {
	if !tok_is(v, .Dimension) { return 0, false }
	n := f32(v.tok.num)
	if n <= 0 { return 0, false }
	switch css.lower_temp(v.tok.text) {
	case "x", "dppx": return n, true
	case "dpi": return n / 96, true
	case "dpcm": return n * 2.54 / 96, true
	}
	return 0, false
}

// image/* types the image decoder reads (an image-set() candidate with another type() is skipped).
@(private)
cursor_type_supported :: proc(t: string) -> bool {
	switch css.lower_temp(t) {
	case "image/png", "image/apng", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/bmp", "image/svg+xml",
	     "image/x-icon", "image/vnd.microsoft.icon", "image/tiff":
		return true
	}
	return false
}

@(private)
cursor_url_of :: proc(v: css.Value) -> (string, bool) {
	if tok_is(v, .Url) { return v.tok.text, true }
	if v.kind == .Function && (strings.equal_fold(v.tok.text, "url") || strings.equal_fold(v.tok.text, "src")) {
		for a in v.children { if tok_is(a, .String) { return a.tok.text, true } }
	}
	return "", false
}

// An image-set(): its candidates `<url> | <string> [<resolution> || type(<string>)]?`.
@(private)
cursor_image_set :: proc(cx: ^Cx, v: css.Value) -> ([]Cursor_Image_Src, bool) {
	out := make([dynamic]Cursor_Image_Src, 0, 2, cx.alloc)
	for part in css.split_commas(v.children, context.temp_allocator) {
		items := split_items(part)
		if len(items) == 0 || len(items) > 3 { return nil, false }
		url: string
		if tok_is(items[0], .String) {
			url = items[0].tok.text
		} else if u, ok := cursor_url_of(items[0]); ok {
			url = u
		} else {
			return nil, false   // gradients and other images cannot be cursors
		}
		density: f32 = 1
		have_res, have_type, supported := false, false, true
		for it in items[1:] {
			if r, ok := cursor_resolution(it); ok && !have_res {
				density, have_res = r, true
			} else if it.kind == .Function && strings.equal_fold(it.tok.text, "type") && !have_type {
				have_type = true
				t := ""
				for a in it.children { if tok_is(a, .String) { t = a.tok.text } }
				if t == "" { return nil, false }
				supported = cursor_type_supported(t)
			} else {
				return nil, false
			}
		}
		if supported { append(&out, Cursor_Image_Src{url = strings.clone(url, cx.alloc), density = density}) }
	}
	if len(out) == 0 && len(css.split_commas(v.children, context.temp_allocator)) == 0 { return nil, false }
	return out[:], true
}

// Parses `cursor` into c.cursor and c.cursor_images. false: the declaration is invalid (and ignored).
parse_cursor :: proc(cx: ^Cx, vs: []css.Value, c: ^Computed) -> bool {
	parts := css.split_commas(css.trim_values(vs), context.temp_allocator)
	if len(parts) == 0 { return false }
	// the last part is the keyword, alone
	last := split_items(parts[len(parts) - 1])
	if len(last) != 1 { return false }
	kw, ok := cursor_keyword(last[0])
	if !ok { return false }
	images := make([dynamic]Cursor_Image, 0, len(parts) - 1, cx.alloc)
	for part in parts[:len(parts) - 1] {
		items := split_items(part)
		if len(items) != 1 && len(items) != 3 { return false }
		img: Cursor_Image
		if u, uok := cursor_url_of(items[0]); uok {
			srcs := make([]Cursor_Image_Src, 1, cx.alloc)
			srcs[0] = {url = strings.clone(u, cx.alloc), density = 1}
			img.srcs = srcs
		} else if items[0].kind == .Function && (strings.equal_fold(items[0].tok.text, "image-set") || strings.equal_fold(items[0].tok.text, "-webkit-image-set")) {
			srcs, sok := cursor_image_set(cx, items[0])
			if !sok { return false }
			img.srcs = srcs
		} else {
			return false
		}
		if len(items) == 3 {
			if !tok_is(items[1], .Number) || !tok_is(items[2], .Number) { return false }
			img.hotspot = {f32(items[1].tok.num), f32(items[2].tok.num)}
			img.has_hotspot = true
		}
		append(&images, img)
	}
	c.cursor = kw
	c.cursor_images = len(images) > 0 ? images[:] : nil
	return true
}

// The candidate of `img` for a screen of `dppx` device pixels per CSS pixel: the smallest density at least that large,
// else the largest (as image-set() selection goes). ok = false: no candidate.
cursor_image_pick :: proc(img: Cursor_Image, dppx: f32) -> (Cursor_Image_Src, bool) {
	if len(img.srcs) == 0 { return {}, false }
	best := -1
	for s, i in img.srcs {
		if s.density >= dppx && (best < 0 || img.srcs[best].density < dppx || s.density < img.srcs[best].density) { best = i }
	}
	if best < 0 || img.srcs[best].density < dppx {
		best = 0
		for s, i in img.srcs { if s.density > img.srcs[best].density { best = i } }
	}
	return img.srcs[best], true
}

// The computed value as getComputedStyle serializes it: `url("a.png") 4 4, image-set("b.png" 2x), pointer`.
cursor_css_text :: proc(c: ^Computed, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	num :: proc(b: ^strings.Builder, v: f32) {
		if v == f32(int(v)) { fmt.sbprintf(b, "%d", int(v)) } else { fmt.sbprintf(b, "%v", v) }
	}
	for img in c.cursor_images {
		if len(img.srcs) == 1 && img.srcs[0].density == 1 {
			fmt.sbprintf(&b, "url(\"%s\")", img.srcs[0].url)
		} else {
			strings.write_string(&b, "image-set(")
			for s, i in img.srcs {
				if i > 0 { strings.write_string(&b, ", ") }
				fmt.sbprintf(&b, "url(\"%s\") ", s.url)
				num(&b, s.density)
				strings.write_string(&b, "x")
			}
			strings.write_string(&b, ")")
		}
		if img.has_hotspot {
			strings.write_string(&b, " ")
			num(&b, img.hotspot.x)
			strings.write_string(&b, " ")
			num(&b, img.hotspot.y)
		}
		strings.write_string(&b, ", ")
	}
	strings.write_string(&b, cursor_keyword_name(c.cursor))
	return strings.to_string(b)
}

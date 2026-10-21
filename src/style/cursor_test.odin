package style

import "core:testing"
import "wb:dom"
import "wb:html"

// `cursor`: every keyword, the image list with hotspots and image-set(), invalid declarations ignored, inheritance,
// serialization (cursor.odin).

@(private = "file")
Doc :: struct { doc: ^dom.Document, eng: ^Engine, st: ^Styled }

@(private = "file")
open_doc :: proc(src: string) -> Doc {
	d: Doc
	d.doc = dom.document_create(nil)
	html.parse_into(d.doc, d.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	d.eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(d.eng, d.doc, "about:test")
	d.st = compute_styles(d.eng, d.doc, {})
	return d
}

@(private = "file")
close_doc :: proc(d: ^Doc) { styled_destroy(d.st); engine_destroy(d.eng); dom.document_destroy(d.doc) }

@(private = "file")
el :: proc(d: ^Doc, id: string) -> ^Computed { return style_of(d.st, dom.find_by_id(d.doc, id)) }

@(test)
cursor_keywords :: proc(t: ^testing.T) {
	for k in Cursor {
		name := cursor_keyword_name(k)
		d := open_doc(fmt_doc(name))
		defer close_doc(&d)
		c := el(&d, "x")
		testing.expectf(t, c != nil && c.cursor == k && c.cursor_images == nil, "cursor: %s -> %v", name, c != nil ? c.cursor : Cursor.Auto)
		testing.expectf(t, cursor_css_text(c) == name, "%s serializes as %q", name, cursor_css_text(c))
	}
}

@(private = "file")
fmt_doc :: proc(value: string) -> string {
	return concat(`<style>#x { cursor: `, value, ` }</style><p id=x></p>`)
}

@(private = "file")
concat :: proc(parts: ..string) -> string {
	n := 0
	for p in parts { n += len(p) }
	b := make([]u8, n, context.temp_allocator)
	i := 0
	for p in parts { copy(b[i:], p); i += len(p) }
	return string(b)
}

@(test)
cursor_values :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		#a { cursor: url(a.png), pointer }
		#b { cursor: url("b.cur") 3 4, url(c.svg) 0.5 7, -webkit-grab }
		#c { cursor: image-set("d.png" 1x, url(d2.png) 2x, "d.avif" type("image/avif") 3x) 8 9, zoom-in }
		#d { cursor: image-set("e.png" 192dpi, "e.foo" type("image/foo") 1x), wait }
		#e { cursor: pointer; cursor: url(x.png) }          /* no keyword: invalid, pointer stays */
		#f { cursor: pointer; cursor: hand }                 /* not CSS: invalid */
		#g { cursor: pointer; cursor: url(x.png) 1, move }   /* one coordinate: invalid */
		#h { cursor: pointer; cursor: grab, move }           /* a keyword before the end: invalid */
		#i { cursor: pointer; cursor: linear-gradient(red, blue), move }   /* not an image cursors can be */
		#j { cursor: -WEBKIT-ZOOM-OUT }
		#p { cursor: help } #p span { }
		#q { cursor: url(q.png) 1 2, copy }
	</style>
	<p id=a></p><p id=b></p><p id=c></p><p id=d></p><p id=e></p><p id=f></p><p id=g></p><p id=h></p><p id=i></p><p id=j></p>
	<div id=p><span id=kid>x</span></div><div id=q><span id=qkid>x</span></div><p id=z></p>`)
	defer close_doc(&d)

	a := el(&d, "a")
	testing.expect(t, a.cursor == .Pointer && len(a.cursor_images) == 1, "url() then a keyword")
	if len(a.cursor_images) == 1 {
		img := a.cursor_images[0]
		testing.expect(t, len(img.srcs) == 1 && img.srcs[0].url == "a.png" && img.srcs[0].density == 1 && !img.has_hotspot, "a.png, no hotspot")
	}
	testing.expect_value(t, cursor_css_text(a), `url("a.png"), pointer`)

	b := el(&d, "b")
	testing.expect(t, b.cursor == .Grab && len(b.cursor_images) == 2, "two images, -webkit-grab")
	if len(b.cursor_images) == 2 {
		testing.expect(t, b.cursor_images[0].has_hotspot && b.cursor_images[0].hotspot == {3, 4}, "hotspot 3 4")
		testing.expect(t, b.cursor_images[1].srcs[0].url == "c.svg" && b.cursor_images[1].hotspot == {0.5, 7}, "fractional hotspot")
	}
	testing.expect_value(t, cursor_css_text(b), `url("b.cur") 3 4, url("c.svg") 0.5 7, grab`)

	c := el(&d, "c")
	testing.expect(t, c.cursor == .Zoom_In && len(c.cursor_images) == 1, "image-set")
	if len(c.cursor_images) == 1 {
		img := c.cursor_images[0]
		testing.expectf(t, len(img.srcs) == 3 && img.srcs[1].url == "d2.png" && img.srcs[1].density == 2 && img.srcs[2].density == 3, "candidates %v", img.srcs)
		testing.expect(t, img.has_hotspot && img.hotspot == {8, 9}, "image-set's hotspot")
		s1, _ := cursor_image_pick(img, 1)
		s2, _ := cursor_image_pick(img, 1.75)
		s4, _ := cursor_image_pick(img, 4)
		testing.expect(t, s1.url == "d.png" && s2.url == "d2.png" && s4.url == "d.avif", "picked by density")
	}
	dd := el(&d, "d")
	if testing.expect(t, len(dd.cursor_images) == 1, "image-set with a resolution in dpi") {
		srcs := dd.cursor_images[0].srcs
		testing.expectf(t, len(srcs) == 1 && srcs[0].url == "e.png" && srcs[0].density == 2, "192dpi = 2x, the unknown type left out (%v)", srcs)
	}
	for id in ([]string{"e", "f", "g", "h", "i"}) {
		x := el(&d, id)
		testing.expectf(t, x.cursor == .Pointer && x.cursor_images == nil, "#%s: invalid, the earlier declaration stands (%v)", id, x.cursor)
	}
	testing.expect(t, el(&d, "j").cursor == .Zoom_Out, "-webkit-zoom-out, any case")
	testing.expect(t, el(&d, "kid").cursor == .Help, "inherited")
	qk := el(&d, "qkid")
	testing.expect(t, qk.cursor == .Copy && len(qk.cursor_images) == 1 && qk.cursor_images[0].srcs[0].url == "q.png", "images inherited with the keyword")
	testing.expect(t, el(&d, "z").cursor == .Auto, "initial: auto")
}

package style

import "core:testing"
import "wb:dom"
import "wb:html"

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
mask_longhands_and_layers :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		#a { mask-image: url(a.svg), linear-gradient(black, transparent); mask-mode: luminance, alpha;
		     mask-repeat: no-repeat; mask-position: center; mask-size: 1em 2em, contain; mask-origin: content-box;
		     mask-clip: no-clip, padding-box; mask-composite: subtract, intersect }
		#b { -webkit-mask-image: url(icon.svg); -webkit-mask-size: cover; -webkit-mask-composite: source-in;
		     -webkit-mask-repeat: no-repeat; -webkit-mask-position: 50% 50% }
		#c { mask-clip: text }
		#n { mask: none }
	</style><p id=a></p><p id=b></p><p id=c></p><p id=n></p><p id=z></p>`)
	defer close_doc(&d)
	a := el(&d, "a")
	testing.expect(t, has_mask(a))
	ls := mask_layers(a)
	testing.expect_value(t, len(ls), 2)
	if len(ls) == 2 {
		testing.expect(t, ls[0].image.kind == .Url && ls[0].image.url == "a.svg" && ls[1].image.kind == .Gradient)
		testing.expect(t, ls[0].mode == .Luminance && ls[1].mode == .Alpha)
		testing.expect(t, ls[0].repeat == {.No_Repeat, .No_Repeat} && ls[1].repeat == {.No_Repeat, .No_Repeat}, "lists repeat")
		testing.expect(t, ls[0].position[0] == pct(50) && ls[0].position[1] == pct(50))
		testing.expect(t, ls[0].size.kind == .Length && ls[0].size.w.v == 16 && ls[1].size.kind == .Contain)
		testing.expect(t, ls[0].origin == .Content_Box && ls[0].clip == .No_Clip && ls[1].clip == .Padding_Box)
		testing.expect(t, ls[0].composite == .Subtract && ls[1].composite == .Intersect)
	}
	b := el(&d, "b")
	lb := mask_layers(b)
	testing.expect(t, has_mask(b) && len(lb) == 1 && lb[0].image.url == "icon.svg" && lb[0].size.kind == .Cover, "-webkit-mask-*")
	testing.expect(t, lb[0].composite == .Intersect && lb[0].repeat[0] == .No_Repeat && lb[0].position[0] == pct(50), "-webkit-mask-composite: source-in")
	testing.expect(t, !has_mask(el(&d, "c")) && el(&d, "c").mask_clips[0] == .Border_Box, "mask-clip: text is not a mask-clip value")
	testing.expect(t, !has_mask(el(&d, "n")) && !has_mask(el(&d, "z")), "mask: none and the initial value mask nothing")
	testing.expect(t, structure_sig(a) != structure_sig(el(&d, "z")), "a mask makes a stacking context")
}

@(test)
mask_shorthand :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		#a { mask: url(m.png) right 10px top / 20px auto no-repeat padding-box luminance exclude, linear-gradient(red, blue) }
		#b { -webkit-mask: url(i.svg) center / contain no-repeat }
		#c { mask: url(x.svg) content-box no-clip }
		#bad { mask: url(a.svg) url(b.svg) }
	</style><p id=a></p><p id=b></p><p id=c></p><p id=bad></p>`)
	defer close_doc(&d)
	ls := mask_layers(el(&d, "a"))
	testing.expect_value(t, len(ls), 2)
	if len(ls) == 2 {
		l := ls[0]
		testing.expect(t, l.image.url == "m.png" && l.repeat == {.No_Repeat, .No_Repeat} && l.mode == .Luminance && l.composite == .Exclude)
		testing.expect(t, l.origin == .Padding_Box && l.clip == .Padding_Box, "one box: origin and clip")
		testing.expect(t, l.size.kind == .Length && l.size.w.v == 20 && l.size.h.kind == .Auto)
		testing.expect(t, ls[1].image.kind == .Gradient && ls[1].mode == .Match_Source && ls[1].origin == .Border_Box && ls[1].repeat == {.Repeat, .Repeat}, "defaults of a layer")
	}
	lb := mask_layers(el(&d, "b"))
	testing.expect(t, len(lb) == 1 && lb[0].size.kind == .Contain && lb[0].position[0] == pct(50), "-webkit-mask")
	lc := mask_layers(el(&d, "c"))
	testing.expect(t, len(lc) == 1 && lc[0].origin == .Content_Box && lc[0].clip == .No_Clip)
	testing.expect(t, !has_mask(el(&d, "bad")), "two images in one layer: invalid")
}

@(test)
text_fill_color :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		#a { color: rgb(255, 0, 0); -webkit-text-fill-color: transparent }
		#c { color: rgb(0, 0, 255); -webkit-text-fill-color: currentcolor }
		#d { text-fill-color: red }
	</style><div id=a><span id=b></span></div><p id=c></p><p id=d></p>`)
	defer close_doc(&d)
	a, b, c := el(&d, "a"), el(&d, "b"), el(&d, "c")
	testing.expect(t, text_fill(a).a == 0 && a.color.r == 1, "transparent fill, red color")
	testing.expect(t, text_fill(b).a == 0, "inherited")
	testing.expect(t, text_fill(c).b == 1 && text_fill(c).a == 1, "currentcolor follows color")
	testing.expect(t, el(&d, "d").text_fill_color.auto, "no unprefixed name")
}

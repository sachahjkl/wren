package page

// Inline <svg> elements of HTML documents. The layout treats an <svg> as a replaced element (its subtree makes no
// boxes); its picture is the subtree serialised back to an SVG document and drawn by the same renderer as SVG images
// (package images: parsed once, rasterised on the decoding threads at the size it is shown at), through the process
// image cache: identical markup (the same icon a hundred times) is one entry, parsed once.
//
// The DOM keeps names in lower case and has no namespaces: the serialisation restores SVG's mixed-case element and
// attribute names (the HTML parser's "adjust SVG" tables), declares the SVG and XLink namespaces, and adds what the
// document around it contributes:
//   * the element's computed `color` (currentColor) and font (font-family, font-size, font-weight, font-style), as a
//     style on the root (a `color` presentation attribute of the <svg> itself is kept instead);
//   * the elements outside the subtree it references by id (`<use href="#icon">` into a sprite sheet elsewhere in the
//     page, `fill="url(#gradient)"`), copied into a <defs>, transitively;
//   * without a viewBox, the size of its box (the document's coordinates are then CSS px, not scaled).
// Scripts and event handler attributes are left out; <foreignObject> content is not drawn (as in SVG images). The
// markup is made again when the document mutates or styles change, and a new entry is used when it differs.
// Limits: images.svg.inline_max_bytes on the markup, then the images.svg.* limits of every SVG document.

import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:style"

Inline_Svg :: struct {
	node:         base.Handle,
	request:      ^Img_Request,   // holds the cache entry of the markup
	hash:         u64,
	mutations:    u64,            // document mutation count the markup was made at
	style_serial: u64,
	css_w, css_h: f32,            // box size it was made for (matters only without a viewBox)
	has_view_box: bool,
	error:        string,         // owned: why there is no picture
}

@(private)
inline_svg_free :: proc(s: ^Inline_Svg, live: bool) {
	if live { request_release(s.request) }
	delete(s.error)
	free(s)
}

@(private)
inline_svgs_destroy :: proc(p: ^Page) {
	for _, s in p.images.svgs { inline_svg_free(s, false) }   // the page's requests are freed with its table
	delete(p.images.svgs)
	for k in p.images.svg_ids { delete(k) }
	delete(p.images.svg_ids)
}

// A new document: handles of the old one mean nothing any more.
@(private)
inline_svgs_reset :: proc(p: ^Page) {
	for _, s in p.images.svgs { inline_svg_free(s, true) }
	clear(&p.images.svgs)
	for k in p.images.svg_ids { delete(k) }
	clear(&p.images.svg_ids)
	p.images.svg_ids_at = 0
}

// After a mutation: records of elements that are gone (or are no longer <svg>) go.
@(private)
inline_svgs_prune :: proc(p: ^Page) {
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for h in p.images.svgs {
		n := dom.get(p.doc, h)
		if n == nil || n.kind != .Element || n.name != "svg" { append(&gone, h) }
	}
	for h in gone {
		s := p.images.svgs[h]
		delete_key(&p.images.svgs, h)
		inline_svg_free(s, true)
	}
}

////////////////////////////////
// Natural size, for the layout (Replaced_Api)

// width / height attributes in CSS px (absolute lengths only: a percentage or `auto` is no natural size).
@(private)
svg_attr_length :: proc(d: ^dom.Document, h: base.Handle, name: string) -> (f32, bool) {
	v, ok := dom.get_attribute(d, h, name)
	if !ok { return 0, false }
	t := strings.trim_space(v)
	end := 0
	for end < len(t) && ((t[end] >= '0' && t[end] <= '9') || t[end] == '.' || t[end] == '-' || t[end] == '+') { end += 1 }
	n, nok := strconv.parse_f32(t[:end])
	if !nok || n < 0 { return 0, false }
	k: f32
	switch strings.to_lower(strings.trim_space(t[end:]), context.temp_allocator) {
	case "", "px": k = 1
	case "pt": k = 4.0 / 3
	case "pc": k = 16
	case "in": k = 96
	case "cm": k = 96 / 2.54
	case "mm": k = 96 / 25.4
	case "em": k = 16
	case "ex": k = 8
	case: return 0, false
	}
	return n * k, true
}

@(private)
svg_view_box :: proc(d: ^dom.Document, h: base.Handle) -> (vb: [4]f32, ok: bool) {
	v, has := dom.get_attribute(d, h, "viewbox")
	if !has { return }
	i := 0
	for f in strings.fields_proc(v, proc(r: rune) -> bool { return r == ' ' || r == ',' || r == '\t' || r == '\n' || r == '\r' }, context.temp_allocator) {
		if i >= 4 { return {}, false }
		n, nok := strconv.parse_f32(f)
		if !nok { return {}, false }
		vb[i] = n
		i += 1
	}
	return vb, i == 4 && vb[2] > 0 && vb[3] > 0
}

// Natural size of an inline <svg> (CSS px): its width / height attributes, a missing one from the viewBox's ratio,
// else 300 x 150. ok = false: a ratio and no size (inline_svg_ratio; the layout stretches it).
inline_svg_intrinsic :: proc(p: ^Page, node: base.Handle) -> (w, h: f32, ok: bool) {
	d := p.doc
	aw, has_w := svg_attr_length(d, node, "width")
	ah, has_h := svg_attr_length(d, node, "height")
	vb, has_vb := svg_view_box(d, node)
	r := has_vb ? vb[2] / vb[3] : 0
	switch {
	case has_w && has_h: return aw, ah, true
	case has_w: return aw, r > 0 ? aw / r : 150, true
	case has_h: return r > 0 ? ah * r : 300, ah, true
	case r > 0: return 0, 0, false
	}
	return 300, 150, true
}

inline_svg_ratio :: proc(p: ^Page, node: base.Handle) -> f32 {
	vb, ok := svg_view_box(p.doc, node)
	return ok ? vb[2] / vb[3] : 0
}

////////////////////////////////
// The picture

// What the inline <svg> `node` shows, for a box of `css_w` x `css_h` CSS px. UI thread, while painting.
inline_svg_view :: proc(p: ^Page, node: base.Handle, css_w, css_h: f32) -> Image_View {
	if p == nil || p.closed || p.worker != nil || p.doc == nil { return {} }
	s := &p.settings.images
	if !s.enabled || !s.svg_inline_enabled || !s.limits.svg.enabled { return {} }
	images_init(p)
	images_adopt_document(p)
	pi := &p.images
	if pi.svgs == nil { pi.svgs = make(map[base.Handle]^Inline_Svg) }
	rec, found := pi.svgs[node]
	if !found {
		rec = new(Inline_Svg)
		rec.node = node
		pi.svgs[node] = rec
	}
	style_serial := p.styled != nil ? p.styled.serial : 0
	stale := !found || rec.mutations != p.doc.mutations || rec.style_serial != style_serial
	if !rec.has_view_box && (abs(rec.css_w - css_w) > 0.5 || abs(rec.css_h - css_h) > 0.5) { stale = true }
	if stale {
		rec.mutations, rec.style_serial, rec.css_w, rec.css_h = p.doc.mutations, style_serial, css_w, css_h
		_, rec.has_view_box = svg_view_box(p.doc, node)
		markup, ok := svg_serialize(p, node, css_w, css_h)
		if !ok {
			request_release(rec.request)
			rec.request, rec.hash = nil, 0
			set_string(&rec.error, "inline <svg> too large or too deep (images.svg.inline_max_bytes, images.svg.max_depth)")
		} else {
			hv := hash.fnv64a(transmute([]byte)markup)
			if rec.request == nil || hv != rec.hash {
				old := rec.request
				rec.request = inline_request(p, hv, markup)
				rec.hash = hv
				request_release(old)
				set_string(&rec.error, "")
			}
		}
	}
	if rec.request == nil { return Image_View{state = .Broken, error = rec.error} }
	return view_of(rec.request, 1)
}

// The page's request for an inline document, by the hash of its markup: shared with every element of the same markup,
// and with other pages of the site through the cache.
@(private)
inline_request :: proc(p: ^Page, hv: u64, markup: string) -> ^Img_Request {
	key := fmt.tprintf("%s|svg|%x|%d", site_key(p), hv, len(markup))
	if r, ok := p.images.requests[key]; ok { r.refs += 1; return r }
	r := new(Img_Request)
	r.page, r.key, r.url = p, strings.clone(key), strings.clone("about:inline-svg")
	r.mime = strings.clone("image/svg+xml")
	r.refs = 1
	r.distance = 0
	p.images.requests[r.key] = r
	if !cache_init(p) {
		r.state, r.error = .Broken, strings.clone("the image decoder is unavailable")
		return r
	}
	if e, ok := cache.entries[key]; ok && e.state != .Broken {
		r.entry = e
		append(&e.requests, r)
		r.state = e.state == .Ready ? .Ready : .Probing
		return r
	}
	entry_start(p, r, transmute([]byte)markup)
	return r
}

////////////////////////////////
// Serialisation

@(private)
SVG_ELEMENTS := [?][2]string{
	{"altglyph", "altGlyph"}, {"altglyphdef", "altGlyphDef"}, {"altglyphitem", "altGlyphItem"}, {"animatecolor", "animateColor"},
	{"animatemotion", "animateMotion"}, {"animatetransform", "animateTransform"}, {"clippath", "clipPath"}, {"feblend", "feBlend"},
	{"fecolormatrix", "feColorMatrix"}, {"fecomponenttransfer", "feComponentTransfer"}, {"fecomposite", "feComposite"},
	{"feconvolvematrix", "feConvolveMatrix"}, {"fediffuselighting", "feDiffuseLighting"}, {"fedisplacementmap", "feDisplacementMap"},
	{"fedistantlight", "feDistantLight"}, {"fedropshadow", "feDropShadow"}, {"feflood", "feFlood"}, {"fefunca", "feFuncA"},
	{"fefuncb", "feFuncB"}, {"fefuncg", "feFuncG"}, {"fefuncr", "feFuncR"}, {"fegaussianblur", "feGaussianBlur"}, {"feimage", "feImage"},
	{"femerge", "feMerge"}, {"femergenode", "feMergeNode"}, {"femorphology", "feMorphology"}, {"feoffset", "feOffset"},
	{"fepointlight", "fePointLight"}, {"fespecularlighting", "feSpecularLighting"}, {"fespotlight", "feSpotLight"}, {"fetile", "feTile"},
	{"feturbulence", "feTurbulence"}, {"foreignobject", "foreignObject"}, {"glyphref", "glyphRef"}, {"lineargradient", "linearGradient"},
	{"radialgradient", "radialGradient"}, {"textpath", "textPath"},
}

@(private)
SVG_ATTRIBUTES := [?][2]string{
	{"attributename", "attributeName"}, {"attributetype", "attributeType"}, {"basefrequency", "baseFrequency"}, {"baseprofile", "baseProfile"},
	{"calcmode", "calcMode"}, {"clippathunits", "clipPathUnits"}, {"diffuseconstant", "diffuseConstant"}, {"edgemode", "edgeMode"},
	{"filterunits", "filterUnits"}, {"glyphref", "glyphRef"}, {"gradienttransform", "gradientTransform"}, {"gradientunits", "gradientUnits"},
	{"kernelmatrix", "kernelMatrix"}, {"kernelunitlength", "kernelUnitLength"}, {"keypoints", "keyPoints"}, {"keysplines", "keySplines"},
	{"keytimes", "keyTimes"}, {"lengthadjust", "lengthAdjust"}, {"limitingconeangle", "limitingConeAngle"}, {"markerheight", "markerHeight"},
	{"markerunits", "markerUnits"}, {"markerwidth", "markerWidth"}, {"maskcontentunits", "maskContentUnits"}, {"maskunits", "maskUnits"},
	{"numoctaves", "numOctaves"}, {"pathlength", "pathLength"}, {"patterncontentunits", "patternContentUnits"},
	{"patterntransform", "patternTransform"}, {"patternunits", "patternUnits"}, {"pointsatx", "pointsAtX"}, {"pointsaty", "pointsAtY"},
	{"pointsatz", "pointsAtZ"}, {"preservealpha", "preserveAlpha"}, {"preserveaspectratio", "preserveAspectRatio"},
	{"primitiveunits", "primitiveUnits"}, {"refx", "refX"}, {"refy", "refY"}, {"repeatcount", "repeatCount"}, {"repeatdur", "repeatDur"},
	{"requiredextensions", "requiredExtensions"}, {"requiredfeatures", "requiredFeatures"}, {"specularconstant", "specularConstant"},
	{"specularexponent", "specularExponent"}, {"spreadmethod", "spreadMethod"}, {"startoffset", "startOffset"},
	{"stddeviation", "stdDeviation"}, {"stitchtiles", "stitchTiles"}, {"surfacescale", "surfaceScale"},
	{"systemlanguage", "systemLanguage"}, {"tablevalues", "tableValues"}, {"targetx", "targetX"}, {"targety", "targetY"},
	{"textlength", "textLength"}, {"viewbox", "viewBox"}, {"viewtarget", "viewTarget"}, {"xchannelselector", "xChannelSelector"},
	{"ychannelselector", "yChannelSelector"}, {"zoomandpan", "zoomAndPan"},
}

// The mixed-case SVG name of a lower-case one (HTML §13.2.6.5 "adjust SVG" tables).
@(private)
svg_case :: proc(table: [][2]string, name: string) -> string {
	for e in table { if e[0] == name { return e[1] } }
	return name
}

@(private = "file")
write_escaped :: proc(b: ^strings.Builder, s: string, attr: bool) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '&': strings.write_string(b, "&amp;")
		case '<': strings.write_string(b, "&lt;")
		case '>': strings.write_string(b, "&gt;")
		case '"': strings.write_string(b, attr ? "&quot;" : "\"")
		case: strings.write_byte(b, c)
		}
	}
}

// The ids an attribute value references: `#id` (href) and `url(#id)` (paint, clip-path, mask, filter, markers).
@(private = "file")
note_refs :: proc(name, value: string, refs: ^[dynamic]string) {
	if (name == "href" || name == "xlink:href") && strings.has_prefix(value, "#") {
		append(refs, value[1:])
		return
	}
	v := value
	for {
		i := strings.index(v, "url(")
		if i < 0 { return }
		v = v[i + 4:]
		j := strings.index_byte(v, ')')
		if j < 0 { return }
		inner := strings.trim(strings.trim_space(v[:j]), "\"'")
		if strings.has_prefix(inner, "#") { append(refs, inner[1:]) }
		v = v[j + 1:]
	}
}

@(private = "file")
Serializer :: struct {
	p:        ^Page,
	b:        strings.Builder,
	max_bytes: int,
	max_depth: int,
	ids:      map[string]bool,     // ids defined in what was written
	refs:     [dynamic]string,     // ids referenced
	failed:   bool,
}

// One element and its subtree, without recursion. `root_extra` is written into the root's start tag.
@(private = "file")
write_tree :: proc(s: ^Serializer, top: base.Handle, root_extra: string, skip_size: bool) {
	d := s.p.doc
	Item :: struct { h: base.Handle, close: bool, depth: int }
	stack := make([dynamic]Item, 0, 32, context.temp_allocator)
	append(&stack, Item{h = top})
	for len(stack) > 0 {
		if strings.builder_len(s.b) > s.max_bytes { s.failed = true; return }
		it := pop(&stack)
		n := dom.get(d, it.h)
		if n == nil { continue }
		if it.close {
			fmt.sbprintf(&s.b, "</%s>", svg_case(SVG_ELEMENTS[:], n.name))
			continue
		}
		switch n.kind {
		case .Text:
			write_escaped(&s.b, n.text, false)
			continue
		case .Comment, .Document, .Doctype, .Fragment:
			continue
		case .Element:
		}
		if n.name == "script" || n.name == "foreignobject" { continue }
		if it.depth > s.max_depth { s.failed = true; return }
		name := svg_case(SVG_ELEMENTS[:], n.name)
		strings.write_byte(&s.b, '<')
		strings.write_string(&s.b, name)
		if it.h == top { strings.write_string(&s.b, root_extra) }
		for a in n.attrs {
			if strings.has_prefix(a.name, "on") || a.name == "xmlns" || strings.has_prefix(a.name, "xmlns:") { continue }
			if it.h == top && root_extra != "" && (a.name == "style" || (skip_size && (a.name == "width" || a.name == "height"))) { continue }
			if a.name == "id" { s.ids[a.value] = true }
			note_refs(a.name, a.value, &s.refs)
			strings.write_byte(&s.b, ' ')
			strings.write_string(&s.b, svg_case(SVG_ATTRIBUTES[:], a.name))
			strings.write_string(&s.b, "=\"")
			write_escaped(&s.b, a.value, true)
			strings.write_byte(&s.b, '"')
		}
		if n.first_child == base.NIL_HANDLE {
			strings.write_string(&s.b, "/>")
			continue
		}
		strings.write_byte(&s.b, '>')
		append(&stack, Item{h = it.h, close = true})
		for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, Item{h = c, depth = it.depth + 1}) }
	}
}

// The element of the page with `id` (map rebuilt once per document mutation).
@(private = "file")
element_by_id :: proc(p: ^Page, id: string) -> base.Handle {
	pi := &p.images
	if pi.svg_ids == nil || pi.svg_ids_at != p.doc.mutations {
		if pi.svg_ids == nil { pi.svg_ids = make(map[string]base.Handle) }
		for k in pi.svg_ids { delete(k) }
		clear(&pi.svg_ids)
		pi.svg_ids_at = p.doc.mutations
		stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
		append(&stack, p.doc.root)
		for len(stack) > 0 {
			h := pop(&stack)
			n := dom.get(p.doc, h)
			if n == nil { continue }
			if n.kind == .Element {
				if v, ok := dom.get_attribute(p.doc, h, "id"); ok && v != "" && v not_in pi.svg_ids { pi.svg_ids[strings.clone(v)] = h }
			}
			for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(p.doc, c).prev { append(&stack, c) }
		}
	}
	return pi.svg_ids[id] or_else base.NIL_HANDLE
}

@(private = "file")
css_color :: proc(c: [4]f32) -> string {
	to8 :: proc(v: f32) -> int { return int(clamp(v, 0, 1) * 255 + 0.5) }
	return fmt.tprintf("rgba(%d,%d,%d,%.3f)", to8(c[0]), to8(c[1]), to8(c[2]), clamp(c[3], 0, 1))
}

// The SVG document an inline <svg> draws. false: over the limits.
// A style attribute that declares `color` (not `background-color`, `flood-color`...).
@(private)
svg_style_sets_color :: proc(style_attr: string) -> bool {
	rest := style_attr
	for decl in strings.split_iterator(&rest, ";") {
		name, _, _ := strings.partition(decl, ":")
		if strings.equal_fold(strings.trim_space(name), "color") { return true }
	}
	return false
}

svg_serialize :: proc(p: ^Page, node: base.Handle, css_w, css_h: f32) -> (string, bool) {
	d := p.doc
	s := Serializer{p = p, max_bytes = p.settings.images.svg_inline_max_bytes, max_depth = p.settings.images.limits.svg.max_depth}
	s.b = strings.builder_make(context.temp_allocator)
	s.ids = make(map[string]bool, 16, context.temp_allocator)
	s.refs = make([dynamic]string, context.temp_allocator)

	// what the page around it contributes, as a style on the root (computed values: the cascade already ran)
	extra := strings.builder_make(context.temp_allocator)
	strings.write_string(&extra, ` xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"`)
	_, has_vb := svg_view_box(d, node)
	if !has_vb && css_w > 0 && css_h > 0 { fmt.sbprintf(&extra, ` width="%.3f" height="%.3f"`, css_w, css_h) }
	st := strings.builder_make(context.temp_allocator)
	cs: ^style.Computed
	if i := int(base.handle_index(node)); p.styled != nil && i < len(p.styled.by_node) { cs = p.styled.by_node[i] }
	own, has_own := dom.get_attribute(d, node, "style")
	if cs != nil {
		if len(cs.font_family) > 0 {
			strings.write_string(&st, "font-family:")
			for f, i in cs.font_family {
				if i > 0 { strings.write_byte(&st, ',') }
				generic := f == "serif" || f == "sans-serif" || f == "monospace" || f == "cursive" || f == "fantasy" || f == "system-ui"
				if generic { strings.write_string(&st, f) } else { fmt.sbprintf(&st, "'%s'", strings.trim(f, "'\"")) }
			}
			strings.write_byte(&st, ';')
		}
		if cs.font_size > 0 { fmt.sbprintf(&st, "font-size:%.3fpx;", cs.font_size) }
		if cs.font_weight > 0 { fmt.sbprintf(&st, "font-weight:%d;", cs.font_weight) }
		if cs.font_style != .Normal { strings.write_string(&st, "font-style:italic;") }
	}
	if has_own { strings.write_string(&st, own); strings.write_byte(&st, ';') }
	// the root's color, last so that it wins: in the standalone document the root has no parent, so `currentColor` or
	// `inherit` there (attribute or style, DuckDuckGo's icons: <svg color="currentColor">) would be black. The cascade's
	// value already accounts for the element's style attribute; a `color` attribute with a real color is kept.
	if cs != nil {
		attr, has_attr := dom.get_attribute(d, node, "color")
		a := strings.trim_space(attr)
		concrete_attr := has_attr && !strings.equal_fold(a, "currentcolor") && !strings.equal_fold(a, "inherit") && a != ""
		if !concrete_attr || svg_style_sets_color(own) { fmt.sbprintf(&st, "color:%s;", css_color(cs.color)) }
	}
	if strings.builder_len(st) > 0 {
		strings.write_string(&extra, ` style="`)
		write_escaped(&extra, strings.to_string(st), true)
		strings.write_byte(&extra, '"')
	}
	write_tree(&s, node, strings.to_string(extra), !has_vb && css_w > 0 && css_h > 0)
	if s.failed { return "", false }

	// elements referenced from outside the subtree (sprite sheets, shared gradients): copied, transitively
	body := strings.to_string(s.b)
	if len(s.refs) > 0 {
		end := strings.last_index(body, "</svg>")
		self_closing := end < 0
		head := self_closing ? strings.trim_suffix(body, "/>") : body[:end]
		out := strings.builder_make(context.temp_allocator)
		strings.write_string(&out, head)
		if self_closing { strings.write_byte(&out, '>') }
		strings.write_string(&out, "<defs>")
		copied := 0
		for i := 0; i < len(s.refs); i += 1 {
			id := s.refs[i]
			if id in s.ids { continue }
			s.ids[id] = true
			h := element_by_id(p, id)
			if h == base.NIL_HANDLE { continue }
			copied += 1
			if copied > 4096 { break }
			s.b = strings.builder_make(context.temp_allocator)
			write_tree(&s, h, "", false)
			if s.failed { return "", false }
			strings.write_string(&out, strings.to_string(s.b))
			if strings.builder_len(out) > s.max_bytes { return "", false }
		}
		strings.write_string(&out, "</defs></svg>")
		body = strings.to_string(out)
	}
	return body, true
}

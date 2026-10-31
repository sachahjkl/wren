// dom_svg.odin: what scripts use most of the SVG DOM, over the geometry interfaces (SVG 2 makes SVGMatrix, SVGPoint and SVGRect the
// DOMMatrix, DOMPoint and DOMRect): svg.createSVGMatrix() and its kind, element.getBBox(), getCTM(), getScreenCTM().
// The geometry comes from the element's box in the layout. A `transform` attribute between the element and its <svg> is in
// the box of getBBox, not in the matrices: only the <svg>'s own place and viewBox are.
package odin_glue

import "../odin/wj"

@(private = "file")
construct :: proc "contextless" (ctx: ^wj.Context, name: cstring, args: []wj.JSValue) -> wj.JSValue {
	c := wj.global_get(ctx, name)
	defer wj.JS_FreeValue(ctx, c)
	return wj.JS_CallConstructor(ctx, c, i32(len(args)), raw_data(args))
}

@(private = "file")
svg_this :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> bool { return wj.wj_this(ctx, t, ifc("SVGSVGElement")) != nil }

@(export, link_name = "wjr_SVGSVGElement_createSVGMatrix")
wjr_SVGSVGElement_createSVGMatrix :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return svg_this(ctx, t) ? construct(ctx, "DOMMatrix", nil) : wj.EXCEPTION
}

@(export, link_name = "wjr_SVGSVGElement_createSVGPoint")
wjr_SVGSVGElement_createSVGPoint :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return svg_this(ctx, t) ? construct(ctx, "DOMPoint", nil) : wj.EXCEPTION
}

@(export, link_name = "wjr_SVGSVGElement_createSVGRect")
wjr_SVGSVGElement_createSVGRect :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return svg_this(ctx, t) ? construct(ctx, "DOMRect", nil) : wj.EXCEPTION
}

@(private = "file")
number_of :: proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, name: cstring) -> f64 {
	v := wj.JS_GetPropertyStr(ctx, o, name)
	defer wj.JS_FreeValue(ctx, v)
	x: f64
	wj.JS_ToFloat64(ctx, &x, v)
	return x
}

// The box of an element in the viewport.
@(private = "file")
box_of :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue) -> (x, y, w, h: f64, ok: bool) {
	r := wj.invoke(ctx, el, "getBoundingClientRect", nil)
	if wj.is_exception(r) { return }
	defer wj.JS_FreeValue(ctx, r)
	return number_of(ctx, r, "x"), number_of(ctx, r, "y"), number_of(ctx, r, "width"), number_of(ctx, r, "height"), true
}

// From the <svg> around `el` (or `el` itself): its box, and what its viewBox makes of user units.
@(private = "file")
Svg_Map :: struct { scale_x, scale_y, x, y: f64 }

@(private = "file")
svg_map_of :: proc "contextless" (ctx: ^wj.Context, el: wj.JSValue) -> (m: Svg_Map, ok: bool) {
	context = wj.heap_context()
	svg := wj.JS_GetPropertyStr(ctx, el, "ownerSVGElement")
	if wj.is_exception(svg) { return }
	root := wj.is_object(svg) ? svg : wj.JS_DupValue(ctx, el)
	if wj.is_object(svg) {
		// (the outermost: a nested <svg> has only its own viewport)
		for {
			up := wj.JS_GetPropertyStr(ctx, root, "ownerSVGElement")
			if !wj.is_object(up) { wj.JS_FreeValue(ctx, up); break }
			wj.JS_FreeValue(ctx, root)
			root = up
		}
	} else {
		wj.JS_FreeValue(ctx, svg)
	}
	defer wj.JS_FreeValue(ctx, root)
	x, y, w, h: f64
	x, y, w, h, ok = box_of(ctx, root)
	if !ok { return }
	m = Svg_Map{1, 1, x, y}
	attr := [1]wj.JSValue{wj.new_string(ctx, "viewBox")}
	defer wj.JS_FreeValue(ctx, attr[0])
	vb := wj.invoke(ctx, root, "getAttribute", attr[:])
	defer wj.JS_FreeValue(ctx, vb)
	if !wj.is_string(vb) { return m, true }
	text, tc, tok := wj.to_string_view(ctx, vb)
	if !tok { wj.drop_exception(ctx); return m, true }
	defer wj.free_cstring(ctx, tc)
	values: [4]f64
	n, at := 0, 0
	for at < len(text) && n < 4 {
		for at < len(text) && (text[at] == ' ' || text[at] == ',' || text[at] == '\t' || text[at] == '\n') { at += 1 }
		start := at
		for at < len(text) && text[at] != ' ' && text[at] != ',' && text[at] != '\t' && text[at] != '\n' { at += 1 }
		if start == at { break }
		s := wj.new_string_len(ctx, transmute([]u8)text[start:at])
		wj.JS_ToFloat64(ctx, &values[n], s)
		wj.JS_FreeValue(ctx, s)
		n += 1
	}
	if n == 4 && values[2] > 0 && values[3] > 0 {
		m.scale_x, m.scale_y = w / values[2], h / values[3]
		m.x, m.y = x - values[0] * m.scale_x, y - values[1] * m.scale_y
	}
	return m, true
}

@(private = "file")
matrix_of :: proc "contextless" (ctx: ^wj.Context, a, d, e, f: f64) -> wj.JSValue {
	list := wj.JS_NewArray(ctx)
	values := [6]f64{a, 0, 0, d, e, f}
	for v, i in values { wj.array_set(ctx, list, u32(i), wj.new_float64(ctx, v)) }
	defer wj.JS_FreeValue(ctx, list)
	args := [1]wj.JSValue{list}
	return construct(ctx, "DOMMatrix", args[:])
}

@(export, link_name = "wjr_SVGGraphicsElement_getScreenCTM")
wjr_SVGGraphicsElement_getScreenCTM :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("SVGGraphicsElement")) == nil { return wj.EXCEPTION }
	m, ok := svg_map_of(ctx, t)
	if !ok { return wj.NULL }
	return matrix_of(ctx, m.scale_x, m.scale_y, m.x, m.y)
}

@(export, link_name = "wjr_SVGGraphicsElement_getCTM")
wjr_SVGGraphicsElement_getCTM :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("SVGGraphicsElement")) == nil { return wj.EXCEPTION }
	m, ok := svg_map_of(ctx, t)
	if !ok { return wj.NULL }
	return matrix_of(ctx, m.scale_x, m.scale_y, 0, 0)
}

// The box in the element's user units.
@(export, link_name = "wjr_SVGGraphicsElement_getBBox")
wjr_SVGGraphicsElement_getBBox :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, t, ifc("SVGGraphicsElement")) == nil { return wj.EXCEPTION }
	x, y, w, h, ok := box_of(ctx, t)
	if !ok { return wj.EXCEPTION }
	m, mok := svg_map_of(ctx, t)
	if !mok { m = Svg_Map{1, 1, 0, 0} }
	sx, sy := m.scale_x != 0 ? m.scale_x : 1, m.scale_y != 0 ? m.scale_y : 1
	args := [4]wj.JSValue{wj.new_float64(ctx, (x - m.x) / sx), wj.new_float64(ctx, (y - m.y) / sy), wj.new_float64(ctx, w / sx), wj.new_float64(ctx, h / sy)}
	return construct(ctx, "DOMRect", args[:])
}
package page

// Module "canvas": the 2D context and its friends (api/canvas.widl). Every implementation below is a thin step from a
// script's argument to package canvas2d; the rules of the specification that are about the API (ignoring NaN, invalid
// enum strings, the order of save / restore) live in canvas2d or here, never in the JavaScript glue.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:canvas2d"
import "wb:dom"

////////////////////////////////
// HTMLCanvasElement

HTMLCanvasElement_width :: proc(c: ^Call, canvas: Api_HTMLCanvasElement) -> u32 {
	w, _ := canvas_dims(c.page.doc, base.Handle(canvas.handle))
	return u32(w)
}

HTMLCanvasElement_height :: proc(c: ^Call, canvas: Api_HTMLCanvasElement) -> u32 {
	_, h := canvas_dims(c.page.doc, base.Handle(canvas.handle))
	return u32(h)
}

// Setting either attribute clears the canvas and resets its context, even to the value it had (the idiom for clearing).
@(private)
canvas_set_dim :: proc(c: ^Call, canvas: Api_HTMLCanvasElement, name: string, value: u32) {
	node := base.Handle(canvas.handle)
	buf: [16]u8
	dom.set_attribute(c.page.doc, node, name, strconv.write_uint(buf[:], u64(value), 10))
	if b := canvas_element_backing(c.page, node, false); b != nil {
		b.seen = c.page.doc.mutations
		w, h := canvas_dims(c.page.doc, node)
		canvas_backing_resize(b, w, h)
	}
}

HTMLCanvasElement_set_width :: proc(c: ^Call, canvas: Api_HTMLCanvasElement, value: u32) { canvas_set_dim(c, canvas, "width", value) }
HTMLCanvasElement_set_height :: proc(c: ^Call, canvas: Api_HTMLCanvasElement, value: u32) { canvas_set_dim(c, canvas, "height", value) }

HTMLCanvasElement_context2d :: proc(c: ^Call, canvas: Api_HTMLCanvasElement, alpha: bool, will_read_frequently: bool) -> (u64, Api_Error) {
	if !c.page.settings.canvas.enabled || c.page.worker != nil { return 0, .None }
	b := canvas_element_backing(c.page, base.Handle(canvas.handle), true)
	if b == nil { return 0, .None }
	canvas_sync(b)
	return canvas_make_context(c, b, alpha, will_read_frequently), .None
}

CanvasRenderingContext2D_canvas :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> u64 {
	if ctx.data.backing == nil { return 0 }
	return u64(ctx.data.backing.node)
}

OffscreenCanvasRenderingContext2D_canvas :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> u64 {
	if ctx.data.backing == nil || ctx.data.backing.owner == nil { return 0 }
	return ctx.data.backing.owner.self
}

CanvasSettings_alpha :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> bool { return ctx.data.alpha }
CanvasSettings_willReadFrequently :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> bool { return ctx.data.read_freq }

////////////////////////////////
// State and transformation

CanvasState_save :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) {
	if k := cx(ctx.data); k != nil { canvas2d.context_save(k) }
}

CanvasState_restore :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) {
	if k := cx(ctx.data); k != nil { canvas2d.context_restore(k) }
}

CanvasState_reset :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) {
	if k := cx(ctx.data); k != nil {
		canvas2d.context_reset(k)
		ctx.data.fill_obj, ctx.data.stroke_obj = 0, 0
	}
}

CanvasState_isContextLost :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> bool { return false }

CanvasTransform_scale :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x: f64, y: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_scale(k, x, y) }
}

CanvasTransform_rotate :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, angle: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_rotate(k, angle) }
}

CanvasTransform_translate :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x: f64, y: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_translate(k, x, y) }
}

CanvasTransform_transform :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_transform(k, m11, m12, m21, m22, m41, m42) }
}

CanvasTransform_setTransform :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_set_transform(k, m11, m12, m21, m22, m41, m42) }
}

CanvasTransform_resetTransform :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_reset_transform(k) }
}

CanvasTransform_matrixElement :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, index: i32) -> f64 {
	k := cx(ctx.data)
	if k == nil { return index == 0 || index == 3 ? 1 : 0 }
	m := k.state.ctm
	switch index {
	case 0: return m.a
	case 1: return m.b
	case 2: return m.c
	case 3: return m.d
	case 4: return m.e
	case 5: return m.f
	}
	return 0
}

////////////////////////////////
// Compositing, smoothing, shadows

CanvasCompositing_globalAlpha :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.alpha }
	return 1
}

CanvasCompositing_set_globalAlpha :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && value >= 0 && value <= 1 { k.state.alpha = value }
}

CanvasCompositing_globalCompositeOperation :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return canvas2d.OP_NAMES[k.state.op] }
	return "source-over"
}

CanvasCompositing_set_globalCompositeOperation :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	if k := cx(ctx.data); k != nil {
		if op, ok := canvas2d.op_from_name(value); ok { k.state.op = op }
	}
}

CanvasImageSmoothing_imageSmoothingEnabled :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> bool {
	if k := cx(ctx.data); k != nil { return k.state.smoothing }
	return true
}

CanvasImageSmoothing_set_imageSmoothingEnabled :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: bool) {
	if k := cx(ctx.data); k != nil { k.state.smoothing = value }
}

CanvasImageSmoothing_imageSmoothingQuality :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil {
		switch k.state.quality {
		case .Low: return "low"
		case .Medium: return "medium"
		case .High: return "high"
		}
	}
	return "low"
}

CanvasImageSmoothing_set_imageSmoothingQuality :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	switch value {
	case "low": k.state.quality = .Low
	case "medium": k.state.quality = .Medium
	case "high": k.state.quality = .High
	}
}

CanvasShadowStyles_shadowOffsetX :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.shadow.ox }
	return 0
}

CanvasShadowStyles_set_shadowOffsetX :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && !math.is_nan(value) && !math.is_inf(value) { k.state.shadow.ox = value }
}

CanvasShadowStyles_shadowOffsetY :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.shadow.oy }
	return 0
}

CanvasShadowStyles_set_shadowOffsetY :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && !math.is_nan(value) && !math.is_inf(value) { k.state.shadow.oy = value }
}

CanvasShadowStyles_shadowBlur :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.shadow.blur }
	return 0
}

CanvasShadowStyles_set_shadowBlur :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && value >= 0 && !math.is_inf(value) { k.state.shadow.blur = value }
}

CanvasShadowStyles_shadowColor :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return canvas_color_text(k.state.shadow.color) }
	return "rgba(0, 0, 0, 0)"
}

CanvasShadowStyles_set_shadowColor :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	if col, ok := canvas_color(ctx.data, value); ok { k.state.shadow.color = col }
}

CanvasFilters_filter :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil && k.state.filter_text != "" { return k.state.filter_text }
	return "none"
}

CanvasFilters_set_filter :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_set_filter(k, value) }
}

////////////////////////////////
// Styles

CanvasStyle_kind :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, stroke: bool) -> Api_StyleKind {
	k := cx(ctx.data)
	if k == nil { return .Color }
	st := stroke ? &k.state.stroke : &k.state.fill
	#partial switch st.kind {
	case .Gradient: return .Gradient
	case .Pattern: return .Pattern
	}
	return .Color
}

CanvasStyle_color :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, stroke: bool) -> string {
	k := cx(ctx.data)
	if k == nil { return "#000000" }
	return canvas_color_text((stroke ? &k.state.stroke : &k.state.fill).color)
}

CanvasStyle_object :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, stroke: bool) -> u64 {
	o := ctx.data
	k := cx(o)
	if k == nil { return 0 }
	st := stroke ? &k.state.stroke : &k.state.fill
	slot := stroke ? &o.stroke_obj : &o.fill_obj
	if slot^ != 0 {
		if x := canvas_obj_of(c.page, slot^); x != nil {
			if (st.kind == .Gradient && x.kind == .Gradient && x.grad == st.grad) || (st.kind == .Pattern && x.kind == .Pattern && x.pat == st.pat) {
				return slot^
			}
		}
	}
	#partial switch st.kind {
	case .Gradient:
		x, h := canvas_new_object(c.page, c.owner, .Gradient)
		x.grad = canvas2d.gradient_retain(st.grad)
		slot^ = h
		return h
	case .Pattern:
		x, h := canvas_new_object(c.page, c.owner, .Pattern)
		x.pat = canvas2d.pattern_retain(st.pat)
		slot^ = h
		return h
	}
	return 0
}

CanvasStyle_setColor :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, stroke: bool, color: string) -> bool {
	k := cx(ctx.data)
	if k == nil { return true }
	col, ok := canvas_color(ctx.data, color)
	if !ok { return false }
	canvas2d.style_set_color(stroke ? &k.state.stroke : &k.state.fill, col)
	return true
}

CanvasStyle_setObject :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, stroke: bool, object: u64) {
	o := ctx.data
	k := cx(o)
	if k == nil { return }
	x := canvas_obj(c, object)
	if x == nil { return }
	st := stroke ? &k.state.stroke : &k.state.fill
	slot := stroke ? &o.stroke_obj : &o.fill_obj
	#partial switch x.kind {
	case .Gradient: canvas2d.style_set_gradient(st, x.grad); slot^ = object
	case .Pattern:
		canvas2d.style_set_pattern(st, x.pat)
		slot^ = object
		// a pattern made from an image the page may not read paints it: the canvas is tainted from now on
		if x.tainted && o.backing != nil { o.backing.tainted = true }
	}
}

CanvasFillStrokeStyles_createLinearGradient :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x0: f64, y0: f64, x1: f64, y1: f64) -> u64 {
	o, h := canvas_new_object(c.page, c.owner, .Gradient)
	o.grad = canvas2d.gradient_linear(x0, y0, x1, y1)
	return h
}

CanvasFillStrokeStyles_createRadialGradient :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64) -> (u64, Api_Error) {
	if r0 < 0 || r1 < 0 { return 0, fail(c, .Index_Size, "The radius provided is negative.") }
	o, h := canvas_new_object(c.page, c.owner, .Gradient)
	o.grad = canvas2d.gradient_radial(x0, y0, r0, x1, y1, r1)
	return h, .None
}

CanvasFillStrokeStyles_createConicGradient :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, start_angle: f64, x: f64, y: f64) -> u64 {
	o, h := canvas_new_object(c.page, c.owner, .Gradient)
	o.grad = canvas2d.gradient_conic(start_angle, x, y)
	return h
}

CanvasGradient_addColorStop :: proc(c: ^Call, gradient: Api_CanvasGradient, offset: f64, color: string) -> Api_Error {
	if !(offset >= 0 && offset <= 1) { return fail(c, .Index_Size, "The provided value is outside the range (0.0 - 1.0).") }
	col, ok := canvas_color_of_page(c.page, color)
	if !ok { return fail(c, .Syntax, fmt.tprintf("The value provided ('%s') could not be parsed as a color.", color)) }
	canvas2d.gradient_add_stop(gradient.data.grad, offset, col)
	return .None
}

CanvasPattern_setTransformMatrix :: proc(c: ^Call, pattern: Api_CanvasPattern, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64) {
	m := canvas2d.Matrix{m11, m12, m21, m22, m41, m42}
	if canvas2d.matrix_finite(m) { pattern.data.pat.transform = m }
}

// A color string outside any context (a gradient stop): currentcolor is black.
@(private)
canvas_color_of_page :: proc(p: ^Page, s: string) -> ([4]f32, bool) {
	tmp := Canvas_Obj{page = p}
	tmp.ctx.inherit.color = {0, 0, 0, 1}
	return canvas_color(&tmp, s)
}

////////////////////////////////
// Rectangles, paths, drawing

CanvasRect_clearRect :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_clear_rect(k, x, y, w, h) }
}

CanvasRect_fillRect :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_fill_rect(k, x, y, w, h) }
}

CanvasRect_strokeRect :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) {
	if k := cx(ctx.data); k != nil { canvas2d.ctx_stroke_rect(k, x, y, w, h) }
}

CanvasDrawPath_beginPath :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) {
	if k := cx(ctx.data); k != nil { canvas2d.path_clear(&k.path) }
}

@(private)
canvas_rule :: proc(rule: string) -> canvas2d.Fill_Rule { return rule == "evenodd" ? .Evenodd : .Nonzero }

// The Path2D a `path` handle names (0: the current path, nil).
@(private)
canvas_path_arg :: proc(c: ^Call, h: u64) -> (path: ^canvas2d.Path, ok: bool) {
	if h == 0 { return nil, true }
	o := canvas_of_kind(c, h, .Path)
	if o == nil { return nil, false }
	return &o.path, true
}

CanvasDrawPath_fill :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, path: u64, rule: string) {
	k := cx(ctx.data)
	if k == nil { return }
	if p, ok := canvas_path_arg(c, path); ok { canvas2d.ctx_fill(k, canvas_rule(rule), p) }
}

CanvasDrawPath_stroke :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, path: u64) {
	k := cx(ctx.data)
	if k == nil { return }
	if p, ok := canvas_path_arg(c, path); ok { canvas2d.ctx_stroke(k, p) }
}

CanvasDrawPath_clip :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, path: u64, rule: string) {
	k := cx(ctx.data)
	if k == nil { return }
	if p, ok := canvas_path_arg(c, path); ok { canvas2d.ctx_clip(k, canvas_rule(rule), p) }
}

CanvasDrawPath_isPointInPath :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, path: u64, x: f64, y: f64, rule: string) -> bool {
	k := cx(ctx.data)
	if k == nil { return false }
	p, ok := canvas_path_arg(c, path)
	return ok && canvas2d.ctx_is_point_in_path(k, x, y, canvas_rule(rule), p)
}

CanvasDrawPath_isPointInStroke :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, path: u64, x: f64, y: f64) -> bool {
	k := cx(ctx.data)
	if k == nil { return false }
	p, ok := canvas_path_arg(c, path)
	return ok && canvas2d.ctx_is_point_in_stroke(k, x, y, p)
}

////////////////////////////////
// Path members (a context's current path, or a Path2D)

@(private)
canvas_target :: proc(t: ^Canvas_Obj) -> (path: ^canvas2d.Path, m: canvas2d.Matrix, ok: bool) {
	if t.kind == .Path { return &t.path, canvas2d.IDENTITY, true }
	k := cx(t)
	if k == nil { return nil, canvas2d.IDENTITY, false }
	return &k.path, k.state.ctm, true
}

CanvasPath_closePath :: proc(c: ^Call, p: Api_CanvasPathTarget) {
	if path, _, ok := canvas_target(p.data); ok { canvas2d.path_close(path) }
}

CanvasPath_moveTo :: proc(c: ^Call, p: Api_CanvasPathTarget, x: f64, y: f64) {
	if path, m, ok := canvas_target(p.data); ok { canvas2d.path_move_to(path, m, x, y) }
}

CanvasPath_lineTo :: proc(c: ^Call, p: Api_CanvasPathTarget, x: f64, y: f64) {
	if path, m, ok := canvas_target(p.data); ok { canvas2d.path_line_to(path, m, x, y) }
}

CanvasPath_quadraticCurveTo :: proc(c: ^Call, p: Api_CanvasPathTarget, cpx: f64, cpy: f64, x: f64, y: f64) {
	if path, m, ok := canvas_target(p.data); ok { canvas2d.path_quad_to(path, m, cpx, cpy, x, y) }
}

CanvasPath_bezierCurveTo :: proc(c: ^Call, p: Api_CanvasPathTarget, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64) {
	if path, m, ok := canvas_target(p.data); ok { canvas2d.path_cubic_to(path, m, cp1x, cp1y, cp2x, cp2y, x, y) }
}

CanvasPath_arcTo :: proc(c: ^Call, p: Api_CanvasPathTarget, x1: f64, y1: f64, x2: f64, y2: f64, radius: f64) -> Api_Error {
	path, m, ok := canvas_target(p.data)
	if !ok { return .None }
	if canvas2d.path_arc_to(path, m, x1, y1, x2, y2, radius) == .Index_Size { return fail(c, .Index_Size, "The radius provided is negative.") }
	return .None
}

CanvasPath_rect :: proc(c: ^Call, p: Api_CanvasPathTarget, x: f64, y: f64, w: f64, h: f64) {
	if path, m, ok := canvas_target(p.data); ok { canvas2d.path_rect(path, m, x, y, w, h) }
}

CanvasPath_roundRect :: proc(c: ^Call, p: Api_CanvasPathTarget, x: f64, y: f64, w: f64, h: f64, radii: []f64) -> Api_Error {
	if len(radii) != 8 { return fail(c, .Invalid_Argument, "roundRect: eight radii expected") }
	path, m, ok := canvas_target(p.data)
	if !ok { return .None }
	r: [4][2]f64
	for i in 0 ..< 4 {
		r[i] = {radii[2 * i], radii[2 * i + 1]}
		if r[i].x < 0 || r[i].y < 0 { return fail(c, .Range, "Radius value must be non-negative.") }
	}
	canvas2d.path_round_rect(path, m, x, y, w, h, r)
	return .None
}

CanvasPath_arc :: proc(c: ^Call, p: Api_CanvasPathTarget, x: f64, y: f64, radius: f64, start_angle: f64, end_angle: f64, counterclockwise: bool) -> Api_Error {
	path, m, ok := canvas_target(p.data)
	if !ok { return .None }
	if canvas2d.path_arc(path, m, x, y, radius, start_angle, end_angle, counterclockwise) == .Index_Size { return fail(c, .Index_Size, "The radius provided is negative.") }
	return .None
}

CanvasPath_ellipse :: proc(c: ^Call, p: Api_CanvasPathTarget, x: f64, y: f64, radius_x: f64, radius_y: f64, rotation: f64, start_angle: f64, end_angle: f64, counterclockwise: bool) -> Api_Error {
	path, m, ok := canvas_target(p.data)
	if !ok { return .None }
	if canvas2d.path_ellipse(path, m, x, y, radius_x, radius_y, rotation, start_angle, end_angle, counterclockwise) == .Index_Size {
		return fail(c, .Index_Size, "The radius provided is negative.")
	}
	return .None
}

Path2D_create :: proc(c: ^Call, from: u64, svg: string) -> u64 {
	o, h := canvas_new_object(c.page, c.owner, .Path)
	if src := canvas_of_kind(c, from, .Path); src != nil { o.path = canvas2d.path_clone(&src.path) }
	o.path.limit = c.page.settings.canvas.max_path_points
	if svg != "" { canvas2d.path_add_svg(&o.path, svg) }
	return h
}

Path2D_addPath :: proc(c: ^Call, target: Api_Path2D, path: Api_Path2D, m11: f64, m12: f64, m21: f64, m22: f64, m41: f64, m42: f64) {
	m := canvas2d.Matrix{m11, m12, m21, m22, m41, m42}
	if !canvas2d.matrix_finite(m) { return }
	if target.data == path.data {
		copy := canvas2d.path_clone(&path.data.path)
		defer canvas2d.path_destroy(&copy)
		canvas2d.path_append(&target.data.path, &copy, m)
		return
	}
	canvas2d.path_append(&target.data.path, &path.data.path, m)
}

////////////////////////////////
// Line styles

CanvasPathDrawingStyles_lineWidth :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.line_width }
	return 1
}

CanvasPathDrawingStyles_set_lineWidth :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && value > 0 && !math.is_inf(value) { k.state.line_width = value }
}

CanvasPathDrawingStyles_lineCap :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil {
		switch k.state.cap {
		case .Butt: return "butt"
		case .Round: return "round"
		case .Square: return "square"
		}
	}
	return "butt"
}

CanvasPathDrawingStyles_set_lineCap :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	switch value {
	case "butt": k.state.cap = .Butt
	case "round": k.state.cap = .Round
	case "square": k.state.cap = .Square
	}
}

CanvasPathDrawingStyles_lineJoin :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil {
		switch k.state.join {
		case .Miter: return "miter"
		case .Round: return "round"
		case .Bevel: return "bevel"
		}
	}
	return "miter"
}

CanvasPathDrawingStyles_set_lineJoin :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	switch value {
	case "miter": k.state.join = .Miter
	case "round": k.state.join = .Round
	case "bevel": k.state.join = .Bevel
	}
}

CanvasPathDrawingStyles_miterLimit :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.miter_limit }
	return 10
}

CanvasPathDrawingStyles_set_miterLimit :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && value > 0 && !math.is_inf(value) { k.state.miter_limit = value }
}

CanvasPathDrawingStyles_lineDashOffset :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> f64 {
	if k := cx(ctx.data); k != nil { return k.state.dash_offset }
	return 0
}

CanvasPathDrawingStyles_set_lineDashOffset :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: f64) {
	if k := cx(ctx.data); k != nil && !math.is_nan(value) && !math.is_inf(value) { k.state.dash_offset = value }
}

CanvasPathDrawingStyles_setLineDash :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, segments: []f64) {
	k := cx(ctx.data)
	if k == nil { return }
	for s in segments { if s < 0 || math.is_nan(s) || math.is_inf(s) { return } }
	delete(k.state.dash)
	k.state.dash = nil
	if len(segments) == 0 { return }
	// an odd list is repeated so that it alternates dash and gap
	n := len(segments) % 2 == 1 ? 2 * len(segments) : len(segments)
	k.state.dash = make([]f64, n)
	for i in 0 ..< n { k.state.dash[i] = segments[i % len(segments)] }
}

CanvasPathDrawingStyles_lineDashCount :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> i32 {
	if k := cx(ctx.data); k != nil { return i32(len(k.state.dash)) }
	return 0
}

CanvasPathDrawingStyles_lineDashAt :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, index: i32) -> f64 {
	if k := cx(ctx.data); k != nil && index >= 0 && int(index) < len(k.state.dash) { return k.state.dash[index] }
	return 0
}

////////////////////////////////
// Text

CanvasTextDrawingStyles_lang :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil && k.state.lang != "" { return k.state.lang }
	return "inherit"
}

CanvasTextDrawingStyles_set_lang :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	delete(k.state.lang)
	k.state.lang = strings.clone(value)
}

CanvasTextDrawingStyles_font :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return k.state.font.text }
	return canvas2d.DEFAULT_FONT_TEXT
}

CanvasTextDrawingStyles_set_font :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	canvas_refresh_inherit(ctx.data)
	f, ok := canvas2d.font_parse(value, k.inherit.font_size)
	if !ok { return }
	// the stretch and small-caps keywords the specification keeps in their own attributes survive a font assignment
	canvas2d.font_spec_destroy(&k.state.font)
	k.state.font = f
}

CanvasTextDrawingStyles_textAlign :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil {
		switch k.state.text_align {
		case .Start: return "start"
		case .End: return "end"
		case .Left: return "left"
		case .Right: return "right"
		case .Center: return "center"
		}
	}
	return "start"
}

CanvasTextDrawingStyles_set_textAlign :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	switch value {
	case "start": k.state.text_align = .Start
	case "end": k.state.text_align = .End
	case "left": k.state.text_align = .Left
	case "right": k.state.text_align = .Right
	case "center": k.state.text_align = .Center
	}
}

CanvasTextDrawingStyles_textBaseline :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil {
		switch k.state.baseline {
		case .Alphabetic: return "alphabetic"
		case .Top: return "top"
		case .Hanging: return "hanging"
		case .Middle: return "middle"
		case .Ideographic: return "ideographic"
		case .Bottom: return "bottom"
		}
	}
	return "alphabetic"
}

CanvasTextDrawingStyles_set_textBaseline :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	switch value {
	case "alphabetic": k.state.baseline = .Alphabetic
	case "top": k.state.baseline = .Top
	case "hanging": k.state.baseline = .Hanging
	case "middle": k.state.baseline = .Middle
	case "ideographic": k.state.baseline = .Ideographic
	case "bottom": k.state.baseline = .Bottom
	}
}

CanvasTextDrawingStyles_direction :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil {
		switch k.state.direction {
		case .Inherit: return "inherit"
		case .Ltr: return "ltr"
		case .Rtl: return "rtl"
		}
	}
	return "inherit"
}

CanvasTextDrawingStyles_set_direction :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	switch value {
	case "inherit": k.state.direction = .Inherit
	case "ltr": k.state.direction = .Ltr
	case "rtl": k.state.direction = .Rtl
	}
}

@(private)
canvas_spacing_text :: proc(v: f64) -> string {
	buf: [32]u8
	return fmt.tprintf("%spx", strings.trim_prefix(strconv.write_float(buf[:], v, 'f', -1, 64), "+"))
}

CanvasTextDrawingStyles_letterSpacing :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return canvas_spacing_text(k.state.letter_spacing) }
	return "0px"
}

CanvasTextDrawingStyles_set_letterSpacing :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	canvas_refresh_inherit(ctx.data)
	if v, ok := canvas2d.parse_length(value, k.inherit.font_size); ok { k.state.letter_spacing = v }
}

CanvasTextDrawingStyles_wordSpacing :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return canvas_spacing_text(k.state.word_spacing) }
	return "0px"
}

CanvasTextDrawingStyles_set_wordSpacing :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	canvas_refresh_inherit(ctx.data)
	if v, ok := canvas2d.parse_length(value, k.inherit.font_size); ok { k.state.word_spacing = v }
}

@(private)
FONT_KERNING := [?]string{"auto", "normal", "none"}
@(private)
FONT_STRETCH := [?]string{"ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "normal", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded"}
@(private)
FONT_VARIANT_CAPS := [?]string{"normal", "small-caps", "all-small-caps", "petite-caps", "all-petite-caps", "unicase", "titling-caps"}
@(private)
TEXT_RENDERING := [?]string{"auto", "optimizeSpeed", "optimizeLegibility", "geometricPrecision"}

@(private)
enum_index :: proc(names: []string, v: string) -> (int, bool) {
	for n, i in names { if n == v { return i, true } }
	return 0, false
}

CanvasTextDrawingStyles_fontKerning :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return FONT_KERNING[min(int(k.state.font_kerning), len(FONT_KERNING) - 1)] }
	return "auto"
}

CanvasTextDrawingStyles_set_fontKerning :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	if k := cx(ctx.data); k != nil { if i, ok := enum_index(FONT_KERNING[:], value); ok { k.state.font_kerning = u8(i) } }
}

CanvasTextDrawingStyles_fontStretch :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return FONT_STRETCH[min(int(k.state.font_stretch), len(FONT_STRETCH) - 1)] }
	return "normal"
}

CanvasTextDrawingStyles_set_fontStretch :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	k := cx(ctx.data)
	if k == nil { return }
	if i, ok := enum_index(FONT_STRETCH[:], value); ok {
		k.state.font_stretch = u8(i)
		stretches := [9]f32{50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200}
		k.state.font.stretch = stretches[i]
	}
}

CanvasTextDrawingStyles_fontVariantCaps :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return FONT_VARIANT_CAPS[min(int(k.state.variant_caps), len(FONT_VARIANT_CAPS) - 1)] }
	return "normal"
}

CanvasTextDrawingStyles_set_fontVariantCaps :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	if k := cx(ctx.data); k != nil { if i, ok := enum_index(FONT_VARIANT_CAPS[:], value); ok { k.state.variant_caps = u8(i) } }
}

CanvasTextDrawingStyles_textRendering :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D) -> string {
	if k := cx(ctx.data); k != nil { return TEXT_RENDERING[min(int(k.state.text_rendering), len(TEXT_RENDERING) - 1)] }
	return "auto"
}

CanvasTextDrawingStyles_set_textRendering :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, value: string) {
	if k := cx(ctx.data); k != nil { if i, ok := enum_index(TEXT_RENDERING[:], value); ok { k.state.text_rendering = u8(i) } }
}

CanvasText_fillText :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, text: string, x: f64, y: f64, max_width: f64, has_max: bool) {
	k := cx(ctx.data)
	if k == nil { return }
	canvas_refresh_inherit(ctx.data)
	canvas2d.ctx_draw_text(k, text, x, y, max_width, has_max, false)
}

CanvasText_strokeText :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, text: string, x: f64, y: f64, max_width: f64, has_max: bool) {
	k := cx(ctx.data)
	if k == nil { return }
	canvas_refresh_inherit(ctx.data)
	canvas2d.ctx_draw_text(k, text, x, y, max_width, has_max, true)
}

CanvasText_measureText :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, text: string) -> u64 {
	o, h := canvas_new_object(c.page, c.owner, .Metrics)
	if k := cx(ctx.data); k != nil {
		canvas_refresh_inherit(ctx.data)
		if tm, ok := canvas2d.ctx_measure_text(k, text); ok { o.metrics = tm }
	}
	return h
}

TextMetrics_width :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.width }
TextMetrics_actualBoundingBoxLeft :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.bbox_left }
TextMetrics_actualBoundingBoxRight :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.bbox_right }
TextMetrics_fontBoundingBoxAscent :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.font_ascent }
TextMetrics_fontBoundingBoxDescent :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.font_descent }
TextMetrics_actualBoundingBoxAscent :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.bbox_ascent }
TextMetrics_actualBoundingBoxDescent :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.bbox_descent }
TextMetrics_emHeightAscent :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.em_ascent }
TextMetrics_emHeightDescent :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.em_descent }
TextMetrics_hangingBaseline :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.hanging }
TextMetrics_alphabeticBaseline :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.alphabetic }
TextMetrics_ideographicBaseline :: proc(c: ^Call, m: Api_TextMetrics) -> f64 { return m.data.metrics.ideographic }

////////////////////////////////
// Images and pixels

CanvasDrawImage_drawImage :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, source: u64, form: i32, sx: f64, sy: f64, sw: f64, sh: f64, dx: f64, dy: f64, dw: f64, dh: f64) -> Api_Error {
	k := cx(ctx.data)
	src := canvas_source(c.page, source)
	defer canvas_source_done(&src)
	switch src.status {
	case .Ok:
	case .Pending: return .None
	case .Broken: return fail(c, .Invalid_State, "The image argument is broken: it did not load, or cannot be decoded.")
	case .Empty: return fail(c, .Invalid_State, "The image argument is a canvas or bitmap with a width or height of zero.")
	case .Bad: return fail(c, .Type, "The provided value is not of a type that can be drawn.")
	}
	if k == nil { return .None }
	b := ctx.data.backing
	if src.tainted && b != nil { b.tainted = true }
	// coordinates of the source rectangle are in the image's own units (CSS pixels for an <img>), those of the pixels
	// differ for an image of another density
	fx, fy := f64(src.bmp.w) / src.nat.x, f64(src.bmp.h) / src.nat.y
	psx, psy, psw, psh := 0.0, 0.0, f64(src.bmp.w), f64(src.bmp.h)
	ddx, ddy, ddw, ddh := dx, dy, src.nat.x, src.nat.y
	switch form {
	case 2:
	case 4: ddw, ddh = dw, dh
	case 8:
		psx, psy, psw, psh = sx * fx, sy * fy, sw * fx, sh * fy
		ddw, ddh = dw, dh
	case: return fail(c, .Invalid_Argument, "drawImage: 2, 4 or 8 arguments after the image")
	}
	canvas2d.ctx_draw_image(k, src.bmp, psx, psy, psw, psh, ddx, ddy, ddw, ddh)
	return .None
}

CanvasImageData_maxBytes :: proc(c: ^Call) -> u64 { return u64(c.page.settings.canvas.max_image_data_bytes) }

CanvasImageData_get :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, x: i32, y: i32, w: i32, h: i32, data: []u8) -> Api_Error {
	if w == 0 || h == 0 { return fail(c, .Index_Size, "The source width or height is 0.") }
	b := ctx.data.backing
	if b != nil && b.tainted { return fail(c, .Security, "The canvas has been tainted by cross-origin data.") }
	if len(data) < int(w) * int(h) * 4 { return fail(c, .Invalid_Argument, "buffer too small") }
	k := cx(ctx.data)
	if k == nil { for i in 0 ..< len(data) { data[i] = 0 }; return .None }
	canvas2d.ctx_get_image_data(k, int(x), int(y), int(w), int(h), data)
	return .None
}

CanvasImageData_put :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, data: []u8, data_w: i32, data_h: i32, dx: i32, dy: i32, dirty_x: i32, dirty_y: i32, dirty_w: i32, dirty_h: i32) {
	k := cx(ctx.data)
	if k == nil || int(data_w) * int(data_h) * 4 > len(data) { return }
	canvas2d.ctx_put_image_data(k, data, int(data_w), int(data_h), int(dx), int(dy), int(dirty_x), int(dirty_y), int(dirty_w), int(dirty_h))
}

////////////////////////////////
// ImageBitmap

ImageBitmap_width :: proc(c: ^Call, bitmap: Api_ImageBitmap) -> u32 { return u32(bitmap.data.bmp.w) }
ImageBitmap_height :: proc(c: ^Call, bitmap: Api_ImageBitmap) -> u32 { return u32(bitmap.data.bmp.h) }
ImageBitmap_close :: proc(c: ^Call, bitmap: Api_ImageBitmap) { canvas_bitmap_free(c.page, &bitmap.data.bmp) }

_ :: base

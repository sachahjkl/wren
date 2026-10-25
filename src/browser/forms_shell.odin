package browser

// Form controls in the window: keyboard and mouse routing to the page's forms model, painting of control contents
// (text, caret, selection, check marks, slider, color swatch, select box and its drop-down list, validation bubble),
// the platform pickers (file and color dialogs, run on a worker thread) and form submissions turned into navigations.
//
// Integration with the painter (render.odin, rewritten by the layout work):
//   * `control_intrinsic_size` gives the content size of a replaced control (CSS px) when its style says `auto`;
//   * for each control box the painter calls `paint_control` with the content rect (physical pixels, screen space);
//   * after the page, `forms_paint_overlays` draws the open drop-down list and the validation bubble.
// Positions recorded while painting are what mouse input is resolved against (caret placement, list rows).

import "base:runtime"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:host"
import "wb:page"
import lay "wb:layout"
import "wb:style"

foreign import user32 "system:User32.lib"

@(default_calling_convention = "system")
foreign user32 {
	GetCaretBlinkTime :: proc() -> u32 ---
	GetDoubleClickTime :: proc() -> u32 ---
}

Painted :: struct {
	content: draw.Rect,     // physical pixels, in the space it was drawn in (screen space unless a CSS transform applies)
	xform:   draw.Affine,   // that space -> screen (draw.current_transform when painted)
	inv:     draw.Affine,   // screen -> that space: pointer positions go through it before meeting `content`
	size:    f32,           // font size, physical pixels
	font:    font.Font_Id,
	line_h:  f32,           // the control's line-height, physical pixels (0: normal)
	frame:   u64,
	proj_ok:  bool,         // painted in a 3D plane: `proj` is exact where `xform` / `inv` know nothing of the projection
	proj:     [9]f32,       // 3x3 (x, y, 1; then the divide by w): that space -> screen
	proj_inv: [9]f32,       // screen -> that space
}

// A screen position in the space a control was painted in (a field inside a rotated box takes the click where it shows; a
// field in a 3D plane takes it through the inverse of the projection, perspective divide included).
@(private = "file")
painted_local :: proc(pt: Painted, pos: [2]f32) -> [2]f32 {
	if pt.proj_ok {
		if q, ok := lay.h3_apply(pt.proj_inv, pos); ok { return q }
	}
	return draw.affine_apply(pt.inv, pos)
}

// Where the control shows on screen: the bounds of its (possibly transformed) content rect.
@(private = "file")
painted_bounds :: proc(pt: Painted) -> draw.Rect {
	if pt.proj_ok {
		c := pt.content
		pts := [4]lay.Vec2{c.min, {c.max.x, c.min.y}, c.max, {c.min.x, c.max.y}}
		r: draw.Rect
		n := 0
		for p in pts {
			if q, ok := lay.h3_apply(pt.proj, p); ok {
				r = n == 0 ? draw.Rect{q, q} : draw.Rect{{min(r.min.x, q.x), min(r.min.y, q.y)}, {max(r.max.x, q.x), max(r.max.y, q.y)}}
				n += 1
			}
		}
		if n > 0 { return r }
	}
	return draw.affine_bounds(pt.xform, pt.content)
}

Drag_Kind :: enum u8 { None, Text, Range }

Popup :: struct {
	open:    bool,
	sel:     base.Handle,
	page_id: u64,
	hover:   int,           // row index
	first:   int,           // first visible row
	rect:    draw.Rect,     // last painted (screen)
	row_h:   f32,
	anchor:  draw.Rect,     // the select's box
}

Forms_View :: struct {
	frame:        u64,
	page_id:      u64,
	painted:      map[base.Handle]Painted,
	scroll:       map[base.Handle][2]f32,
	page_focus:   bool,
	consumed:     [dynamic]bool,
	drag:         Drag_Kind,
	drag_node:    base.Handle,
	press_target: base.Handle,
	press_down:   bool,
	click_count:  int,
	last_click:   time.Tick,
	last_click_pos: [2]f32,
	popup:        Popup,
	caret_epoch:  time.Tick,
	blink_timer:  base.Handle,
	blink_on:     bool,
	last_serial:  u64,
	autofocus_page: u64,
	report_timer: base.Handle,
}

fview: Forms_View

forms_shell_destroy :: proc() {
	delete(fview.painted)
	delete(fview.scroll)
	delete(fview.consumed)
	fview = {}
}

@(private = "file")
current_page :: proc(app: ^App) -> (^Tab, ^page.Page, ^forms.Forms) {
	t := current_tab(app)
	if t == nil || t.page == nil || t.kind != .Web || t.page.formctl == nil { return t, nil, nil }
	return t, t.page, page.page_forms(t.page)
}

@(private = "file")
request_frames :: proc(app: ^App, n := 2) { app.frames_requested = max(app.frames_requested, n) }

@(private = "file")
caret_reset :: proc() { fview.caret_epoch = time.tick_now() }

@(private = "file")
blink_ms :: proc(app: ^App) -> int {
	if ms := app.page_settings.forms.caret_blink_ms; ms > 0 { return ms }
	sys := GetCaretBlinkTime()
	if sys == 0xFFFFFFFF { return -1 }   // INFINITE: the user turned blinking off
	return int(max(sys, 100))
}

@(private = "file")
double_click_ms :: proc(app: ^App) -> f64 {
	if ms := app.page_settings.forms.double_click_ms; ms > 0 { return f64(ms) }
	return f64(GetDoubleClickTime())
}

////////////////////////////////
// Per frame

// Called once per frame after input routing: attaches the shell to new pages, autofocus, caret blinking, repaints when
// the forms model changed, the lifetime of the validation bubble.
forms_shell_frame :: proc(app: ^App) {
	fview.frame += 1
	for tab in app.tabs {
		if tab.page == nil || tab.page.formctl == nil || tab.page.formctl.embedder.navigate != nil { continue }
		page.set_forms_embedder(tab.page, page.Forms_Embedder{
			user = app, navigate = shell_navigate_submission, pick_files = shell_pick_files, pick_color = shell_pick_color,
			changed = proc(user: rawptr, p: ^page.Page) { request_frames((^App)(user)) },
		})
	}
	t, p, f := current_page(app)
	if f == nil { fview.popup.open = false; return }
	if fview.page_id != f.id {
		clear(&fview.painted)
		clear(&fview.scroll)
		fview.page_id = f.id
		fview.popup.open = false
		fview.drag = .None
		fview.page_focus = true
	}
	// autofocus once the document's scripts had their turn
	if fview.autofocus_page != f.id && (t.load == nil || t.load.next_run >= len(t.load.slots)) {
		fview.autofocus_page = f.id
		if forms.run_autofocus(f) { caret_reset(); scroll_into_view(app, t, f.focus) }
	}
	if f.serial != fview.last_serial { fview.last_serial = f.serial; caret_reset(); request_frames(app) }
	// :focus-visible: a focus that came from the keyboard, or a text field's (the heuristic of browsers)
	if fv := f.focus != base.NIL_HANDLE && (f.focus_by_key || forms.is_text_field(f, f.focus)); p.style_state.focus_visible != fv {
		st := p.style_state
		st.focus_visible = fv
		page.set_style_state(p, st)
		request_frames(app)
	}
	if fview.popup.open && (fview.popup.page_id != f.id || dom.get(p.doc, fview.popup.sel) == nil || forms.is_disabled(f, fview.popup.sel)) { fview.popup.open = false }

	// caret blinking: wake the loop at the next toggle while a text field has the focus
	if fview.page_focus && forms.is_text_field(f, f.focus) {
		period := blink_ms(app)
		if period > 0 {
			elapsed := time.duration_milliseconds(time.tick_since(fview.caret_epoch))
			fview.blink_on = int(elapsed / f64(period)) % 2 == 0
			if fview.blink_timer == base.NIL_HANDLE {
				next := f64(period) - math.mod(elapsed, f64(period))
				fview.blink_timer = host.set_timer(&app.loop, max(next, 1), 0, proc(data: rawptr) { fview.blink_timer = base.NIL_HANDLE }, nil)
			}
		} else {
			fview.blink_on = true
		}
	} else {
		fview.blink_on = false
	}
	if _, _, shown := forms.current_report(f); shown && fview.report_timer == base.NIL_HANDLE {
		fview.report_timer = host.set_timer(&app.loop, 250, 0, proc(data: rawptr) { fview.report_timer = base.NIL_HANDLE }, nil)
	}
}

// The events the page did not consume (the chrome's UI gets these).
forms_unconsumed_events :: proc(events: []platform.Event) -> []platform.Event {
	if len(fview.consumed) == 0 { return events }
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e, i in events { if i >= len(fview.consumed) || !fview.consumed[i] { append(&out, e) } }
	clear(&fview.consumed)
	return out[:]
}

consume :: proc(index: int) {
	for len(fview.consumed) <= index { append(&fview.consumed, false) }
	fview.consumed[index] = true
}

////////////////////////////////
// Geometry helpers

@(private = "file")
is_rendered :: proc(p: ^page.Page, h: base.Handle) -> bool {
	if p.styled == nil { return true }
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil { return false }
		if n.kind == .Element {
			cs := style.style_of(p.styled, cur)
			if cs == nil || cs.display == .None { return false }
			if cur == h && cs.visibility != .Visible { return false }
		}
		cur = n.parent
	}
	return true
}

// Where the border box of `h` shows, in document coordinates (physical pixels, scroll offsets of containers applied):
// the bounds of the transformed box when a CSS transform applies.
@(private = "file")
layout_rect :: proc(t: ^Tab, h: base.Handle) -> (draw.Rect, bool) {
	r, ok := lay.box_of(&t.layout, h, draw.rect_size(the_app.page_rect), t.scroll)
	if !ok { return {}, false }
	return draw.Rect{r.bounds.min, r.bounds.max}, true
}

// A document point relative to the border box of `h`, in the box's own (untransformed) coordinates: offsetX / offsetY.
@(private = "file")
layout_offset :: proc(t: ^Tab, h: base.Handle, doc_pos: [2]f32) -> ([2]f32, bool) {
	r, ok := lay.box_of(&t.layout, h, draw.rect_size(the_app.page_rect), t.scroll)
	if !ok { return {}, false }
	return lay.box_point_to_local(r, doc_pos) - r.border.min, true
}

// The painter of package layout asks us for the content of form controls (render.odin, set_content_painter).
forms_content_painter :: proc(user: rawptr, dc: ^draw.Context, doc: ^dom.Document, node: base.Handle, kind: lay.Item_Kind,
	content, border: draw.Rect, cs: ^style.Computed, font_id: font.Font_Id, font_size: f32) -> bool {
	if kind != .Control { return false }
	app := (^App)(user)
	t := current_tab(app)
	if t == nil { return false }
	p := t.page
	if t.hold.active && t.hold.page != nil && t.hold.page.doc == doc { p = t.hold.page }   // the frame held through a navigation
	if p == nil || p.doc != doc || p.formctl == nil { return false }
	paint_control(dc, &app.fonts, font_id != 0 ? font_id : app.ui_font, node, content, border, cs, p, time.tick_now())
	return true
}

scroll_into_view :: proc(app: ^App, t: ^Tab, h: base.Handle) {
	if t == nil || h == base.NIL_HANDLE { return }
	r, ok := layout_rect(t, h)
	if !ok { return }
	view_h := app.page_rect.max.y - app.page_rect.min.y
	if r.min.y < t.scroll { t.scroll = max(r.min.y - 16, 0) } else if r.max.y > t.scroll + view_h { t.scroll = r.max.y - view_h + 16 }
}

////////////////////////////////
// Text layout of a field (shared by painting and hit testing)

Vis_Line :: struct { start, end: int }   // display bytes

Field_Text :: struct {
	display: string,
	starts:  []int,        // source byte -> display byte, for every source byte (non-boundaries map to their character)
	lines:   []Vis_Line,
	line_h:  f32,
}

@(private = "file")
field_text :: proc(f: ^forms.Forms, h: base.Handle, src: string, width, size: f32, fid: font.Font_Id, fonts: ^font.State, mask: string, multiline: bool) -> Field_Text {
	ft: Field_Text
	starts := make([]int, len(src) + 1, context.temp_allocator)
	if mask != "" {
		sb := strings.builder_make(context.temp_allocator)
		for r, i in src {
			for k in 0 ..< utf8.rune_size(r) { starts[i + k] = strings.builder_len(sb) }
			strings.write_string(&sb, mask)
		}
		starts[len(src)] = strings.builder_len(sb)
		ft.display = strings.to_string(sb)
	} else {
		for i in 0 ..= len(src) { starts[i] = i }
		ft.display = src
	}
	ft.starts = starts
	m := font.metrics(fonts, fid, size)
	ft.line_h = math.ceil((m.ascent + m.descent) * 1.25)
	lines := make([dynamic]Vis_Line, context.temp_allocator)
	if !multiline {
		append(&lines, Vis_Line{0, len(ft.display)})
	} else {
		d := ft.display
		ls := 0
		for ls <= len(d) {
			le := ls
			for le < len(d) && d[le] != '\n' { le += 1 }
			// wrap [ls, le) at the width (greedy, at spaces, characters when a word is too long)
			s := ls
			for {
				if font.text_width(fonts, fid, size, d[s:le]) <= width || s >= le {
					append(&lines, Vis_Line{s, le})
					break
				}
				cut := s
				last_space := -1
				for i := s; i < le; {
					_, w := utf8.decode_rune_in_string(d[i:])
					if font.text_width(fonts, fid, size, d[s:i + w]) > width { break }
					if d[i] == ' ' { last_space = i }
					i += w
					cut = i
				}
				if last_space > s { cut = last_space + 1 }
				if cut <= s { _, w := utf8.decode_rune_in_string(d[s:]); cut = s + max(w, 1) }
				append(&lines, Vis_Line{s, cut})
				s = cut
			}
			if le >= len(d) { break }
			ls = le + 1
		}
		if len(lines) == 0 { append(&lines, Vis_Line{0, 0}) }
	}
	ft.lines = lines[:]
	return ft
}

@(private = "file")
disp_to_src :: proc(ft: Field_Text, d: int) -> int {
	for i in 0 ..< len(ft.starts) { if ft.starts[i] >= d { return i } }
	return len(ft.starts) - 1
}

@(private = "file")
line_of :: proc(ft: Field_Text, d: int) -> int {
	for l, i in ft.lines {
		if d < l.end || (d == l.end && (i == len(ft.lines) - 1 || ft.lines[i + 1].start > d)) { return i }
	}
	return len(ft.lines) - 1
}

// Position (relative to the content box, scroll applied) of a source byte offset.
@(private = "file")
caret_xy :: proc(ft: Field_Text, src_pos: int, size: f32, fid: font.Font_Id, fonts: ^font.State) -> [2]f32 {
	d := ft.starts[clamp(src_pos, 0, len(ft.starts) - 1)]
	li := line_of(ft, d)
	l := ft.lines[li]
	return {font.x_from_index(fonts, fid, size, ft.display[l.start:l.end], d - l.start), f32(li) * ft.line_h}
}

@(private = "file")
hit_text :: proc(ft: Field_Text, local: [2]f32, size: f32, fid: font.Font_Id, fonts: ^font.State) -> int {
	li := clamp(int(math.floor(local.y / ft.line_h)), 0, len(ft.lines) - 1)
	l := ft.lines[li]
	d := l.start + font.index_from_x(fonts, fid, size, ft.display[l.start:l.end], local.x)
	return disp_to_src(ft, d)
}

@(private = "file")
mask_of :: proc(app: ^App, f: ^forms.Forms, h: base.Handle) -> string {
	if forms.kind(f, h) == .Input && forms.input_type(f, h) == .Password { return app.page_settings.forms.password_mask }
	return ""
}

// The field's text as laid out in its painted box, with the vertical origin of the text.
@(private = "file")
layout_field :: proc(app: ^App, f: ^forms.Forms, h: base.Handle, pt: Painted) -> (ft: Field_Text, origin: [2]f32) {
	multiline := forms.kind(f, h) == .Textarea
	w := pt.content.max.x - pt.content.min.x
	ft = field_text(f, h, forms.edit_text(f, h), w, pt.size, pt.font, &app.fonts, mask_of(app, f, h), multiline)
	sc := fview.scroll[h]
	if multiline {
		origin = {pt.content.min.x - sc.x, pt.content.min.y - sc.y}
	} else {
		// the line's own box (ft.line_h) is placed so that the text lands on the baseline the layout gave the field
		m := font.metrics(&app.fonts, pt.font, pt.size)
		base := control_text_baseline(m, pt.line_h, pt.content.min.y, pt.content.max.y - pt.content.min.y)
		origin = {pt.content.min.x - sc.x, base - m.ascent - (ft.line_h - (m.ascent + m.descent)) * 0.5}
	}
	return
}

////////////////////////////////
// Painting

// Content size (CSS px) of a replaced control whose width/height are `auto`: input fields from `size`, textareas from
// cols/rows, buttons and selects from their labels.
control_intrinsic_size :: proc(app: ^App, p: ^page.Page, h: base.Handle, cs: ^style.Computed) -> [2]f32 {
	f := page.page_forms(p)
	size := cs.font_size
	fid := app.ui_font
	m := font.metrics(&app.fonts, fid, size)
	line := math.ceil((m.ascent + m.descent) * 1.25)
	avg := font.text_width(&app.fonts, fid, size, "0")
	n := dom.get(p.doc, h)
	int_attr :: proc(n: ^dom.Node, name: string, def: int) -> int {
		v, ok := forms.attr(n, name)
		if !ok { return def }
		x := 0
		for c in transmute([]u8)strings.trim_space(v) { if c < '0' || c > '9' { return def }; x = min(x * 10 + int(c - '0'), 10000) }
		return x > 0 ? x : def
	}
	switch forms.kind_of(n) {
	case .Input:
		t := forms.input_type_of(n)
		#partial switch t {
		case .Checkbox, .Radio: return {13, 13}
		case .Hidden: return {0, 0}
		case .Range: return {129, 16}
		case .Color: return {44, max(line, 21)}
		case .File: return {font.text_width(&app.fonts, fid, size, "Choose files") + 16 + avg * 14, line + 4}
		case .Submit, .Reset, .Button, .Image:
			return {font.text_width(&app.fonts, fid, size, button_label(f, h)), line}
		}
		cols := int_attr(n, "size", 20)
		return {avg * f32(cols), line}
	case .Textarea:
		return {avg * f32(int_attr(n, "cols", 20)) + 4, line * f32(int_attr(n, "rows", 2))}
	case .Select:
		if forms.is_dropdown(f, h) {
			w: f32 = 0
			for o in forms.select_options(f, h) { w = max(w, font.text_width(&app.fonts, fid, size, forms.option_label(f, o))) }
			return {w + size * 1.6, line}
		}
		w: f32 = 0
		for o in forms.select_options(f, h) { w = max(w, font.text_width(&app.fonts, fid, size, forms.option_label(f, o))) }
		return {w + 18, line * f32(forms.display_size(f, h))}
	case .Button:
		return {font.text_width(&app.fonts, fid, size, forms.collapse_ws(dom.text_content(p.doc, h))), line}
	case .None, .Option, .Optgroup, .Fieldset, .Legend, .Output, .Form, .Label, .Object, .Datalist, .Dialog:
	}
	return {0, 0}
}

@(private = "file")
button_label :: proc(f: ^forms.Forms, h: base.Handle) -> string {
	n := dom.get(f.doc, h)
	if forms.kind_of(n) == .Button { return forms.collapse_ws(dom.text_content(f.doc, h)) }
	if v, ok := forms.attr(n, "value"); ok { return v }
	#partial switch forms.input_type_of(n) {
	case .Submit: return "Submit"
	case .Reset: return "Reset"
	case .Image:
		alt, _ := forms.attr(n, "alt")
		return alt != "" ? alt : "Submit"
	}
	return ""
}

@(private = "file")
centered_text :: proc(dc: ^draw.Context, fonts: ^font.State, fid: font.Font_Id, size: f32, r: draw.Rect, color: draw.Color, s: string, align_center := true, line_h: f32 = 0) {
	m := font.metrics(fonts, fid, size)
	w := font.text_width(fonts, fid, size, s)
	x := align_center ? (r.min.x + r.max.x - w) * 0.5 : r.min.x
	draw.text(dc, fid, size, {x, control_text_baseline(m, line_h, r.min.y, r.max.y - r.min.y)}, color, s)
}

// The baseline of a line of text centered in [top, top + h], where the layout puts a control's text (layout
// control_baseline): the line box of `line_h` (0: line-height normal) centered, the text in it as in any line, with the
// metrics rounded as layout.text.round_font_metrics says.
@(private = "file")
control_text_baseline :: proc(m: font.Metrics, line_h, top, h: f32) -> f32 {
	a, d, gap := m.ascent, m.descent, m.line_gap
	round := page_render.settings.round_metrics
	if round { a, d, gap = math.round(a), math.round(d), math.round(gap) }
	lh := line_h > 0 ? line_h : round ? a + d + gap : m.line_height
	ht := (lh - (a + d)) * 0.5
	if round { ht = math.floor(ht) }
	return top + (h - lh) * 0.5 + ht + a
}

// A check mark made of small squares along two strokes (the renderer only draws axis-aligned rects).
@(private = "file")
check_mark :: proc(dc: ^draw.Context, r: draw.Rect, color: draw.Color) {
	w := r.max.x - r.min.x
	t := max(w * 0.13, 1.5)
	a := draw.Vec2{r.min.x + w * 0.2, r.min.y + w * 0.52}
	b := draw.Vec2{r.min.x + w * 0.42, r.min.y + w * 0.74}
	c := draw.Vec2{r.min.x + w * 0.8, r.min.y + w * 0.28}
	dot_stroke(dc, a, b, t, color)
	dot_stroke(dc, b, c, t, color)
}

// A date field's calendar (a frame, its top bar and rows of days) or a time field's clock, in `r`.
@(private = "file")
picker_indicator :: proc(dc: ^draw.Context, r: draw.Rect, color: draw.Color, clock: bool, scale: f32) {
	w := r.max.x - r.min.x
	t := max(1.25 * scale, 1)
	inner := draw.rect_pad(r, -w * 0.1)
	if clock {
		c := draw.rect_center(inner)
		rad := (inner.max.x - inner.min.x) * 0.5
		draw.rect(dc, inner, color, rad, t)
		dot_stroke(dc, c, {c.x, c.y - rad * 0.6}, t, color)
		dot_stroke(dc, c, {c.x + rad * 0.45, c.y}, t, color)
		return
	}
	iw := inner.max.x - inner.min.x
	draw.rect(dc, inner, color, iw * 0.12, t)
	draw.rect(dc, {inner.min, {inner.max.x, inner.min.y + iw * 0.22}}, color, iw * 0.12)
	// three rows of three days
	d := iw * 0.13
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			x := inner.min.x + iw * (0.24 + 0.26 * f32(col))
			y := inner.min.y + iw * (0.4 + 0.2 * f32(row))
			draw.rect(dc, {{x - d * 0.5, y - d * 0.5}, {x + d * 0.5, y + d * 0.5}}, color)
		}
	}
}

// A drop-down list's arrow: a down-pointing chevron `half_w` either side of `center`, half as high as wide.
@(private = "file")
chevron :: proc(dc: ^draw.Context, center: draw.Vec2, half_w, t: f32, color: draw.Color) {
	a := draw.Vec2{center.x - half_w, center.y - half_w * 0.5}
	b := draw.Vec2{center.x, center.y + half_w * 0.5}
	c := draw.Vec2{center.x + half_w, center.y - half_w * 0.5}
	dot_stroke(dc, a, b, t, color)
	dot_stroke(dc, b, c, t, color)
}

// A stroke of thickness `t` from p to q, as round dots close enough to overlap.
@(private = "file")
dot_stroke :: proc(dc: ^draw.Context, p, q: draw.Vec2, t: f32, color: draw.Color) {
	n := int(max(abs(q.x - p.x), abs(q.y - p.y)) / (t * 0.35)) + 1
	for i in 0 ..= n {
		k := f32(i) / f32(n)
		pt := p + (q - p) * k
		draw.rect(dc, {pt - t * 0.5, pt + t * 0.5}, color, t * 0.5)
	}
}

@(private = "file")
parse_hex_color :: proc(s: string) -> draw.Color {
	if len(s) != 7 { return {0, 0, 0, 1} }
	v: u32
	for c in transmute([]u8)s[1:] {
		d: u32
		switch c {
		case '0' ..= '9': d = u32(c - '0')
		case 'a' ..= 'f': d = u32(c - 'a') + 10
		case 'A' ..= 'F': d = u32(c - 'A') + 10
		}
		v = v * 16 + d
	}
	return draw.hex(v << 8 | 0xff)
}

// Draws what is inside a control's content box: value / placeholder / caret / selection for text fields, the mark of a
// checkbox or radio, the label of a button, the select's chosen option and arrow (or its rows for a list box), the
// slider of a range, the swatch of a color input, the file button and names. Box background and borders are the
// painter's. `content` and `border` (the border box) are in physical pixels, screen space.
paint_control :: proc(dc: ^draw.Context, fonts: ^font.State, fid: font.Font_Id, node: base.Handle, content, border: draw.Rect, cs: ^style.Computed, p: ^page.Page, now: time.Tick) {
	if p == nil || p.formctl == nil || cs == nil { return }
	app := the_app
	f := page.page_forms(p)
	n := dom.get(p.doc, node)
	if n == nil { return }
	scale := page_scale(the_app)
	size := max(cs.font_size * scale, 1)
	fg := to_draw(cs.color)
	pal := control_palette(cs)
	xf := draw.current_transform(dc)
	inv, _ := draw.affine_inverse(xf)
	lh: f32
	switch cs.line_height.kind {
	case .Normal:
	case .Number: lh = size * cs.line_height.v
	case .Length: lh = cs.line_height.v * scale
	}
	pt := Painted{content = content, xform = xf, inv = inv, size = size, font = fid, line_h = lh, frame = fview.frame}
	pt.proj, pt.proj_inv, pt.proj_ok = painted_projection(dc, xf)
	if fview.page_id != f.id { clear(&fview.painted); clear(&fview.scroll); fview.page_id = f.id }
	fview.painted[node] = pt
	focused := f.focus == node && fview.page_focus
	disabled := forms.is_disabled(f, node)
	if disabled { draw.push_alpha(dc, 0.55) }
	defer if disabled { draw.pop_alpha(dc) }
	_ = now

	switch forms.kind_of(n) {
	case .Input:
		t := forms.input_type_of(n)
		#partial switch t {
		case .Hidden:
		case .Checkbox, .Radio:
			side := min(content.max.x - content.min.x, content.max.y - content.min.y)
			c := draw.rect_center(content)
			r := draw.Rect{c - side * 0.5, c + side * 0.5}
			on := forms.checked(f, node)
			radius := t == .Radio ? side * 0.5 : side * 0.18
			draw.rect(dc, r, on ? pal.accent : pal.field, radius)
			draw.rect(dc, r, on ? pal.accent : pal.border, radius, max(scale, 1))
			if t == .Checkbox {
				if forms.indeterminate(f, node) {
					draw.rect(dc, {{r.min.x + side * 0.22, c.y - side * 0.08}, {r.max.x - side * 0.22, c.y + side * 0.08}}, on ? pal.accent_text : pal.mark_off)
				} else if on {
					check_mark(dc, r, pal.accent_text)
				}
			} else if on {
				draw.rect(dc, {c - side * 0.2, c + side * 0.2}, pal.accent_text, side * 0.2)
			}
			if focused { draw.rect(dc, draw.rect_pad(r, 2 * scale), pal.focus_ring, radius + 2 * scale, max(scale, 1)) }
		case .Submit, .Reset, .Button, .Image:
			centered_text(dc, fonts, fid, size, content, fg, button_label(f, node), line_h = lh)
		case .Range:
			lim := forms.limits(f, n, .Range)
			v := forms.value_as_number(f, node)
			k: f32 = lim.max > lim.min ? f32((v - lim.min) / (lim.max - lim.min)) : 0
			k = clamp(k, 0, 1)
			cy := (content.min.y + content.max.y) * 0.5
			th := max(4 * scale, 2)
			thumb := (content.max.y - content.min.y) * 0.8
			x0, x1 := content.min.x + thumb * 0.5, content.max.x - thumb * 0.5
			x := x0 + (x1 - x0) * k
			draw.rect(dc, {{x0, cy - th * 0.5}, {x1, cy + th * 0.5}}, pal.track, th * 0.5)
			draw.rect(dc, {{x0, cy - th * 0.5}, {x, cy + th * 0.5}}, pal.accent, th * 0.5)
			draw.rect(dc, {{x - thumb * 0.5, cy - thumb * 0.5}, {x + thumb * 0.5, cy + thumb * 0.5}}, pal.accent, thumb * 0.5)
			if focused { draw.rect(dc, {{x - thumb * 0.5 - 2 * scale, cy - thumb * 0.5 - 2 * scale}, {x + thumb * 0.5 + 2 * scale, cy + thumb * 0.5 + 2 * scale}}, pal.focus_ring, thumb * 0.5 + 2 * scale, max(scale, 1)) }
		case .Color:
			if !(focused && forms.has_attr(n, "list")) {
				sw := draw.rect_pad(content, -2 * scale)
				draw.rect(dc, sw, parse_hex_color(forms.value(f, node)), 2 * scale)
				draw.rect(dc, sw, pal.border, 2 * scale, max(scale, 1))
			}
		case .File:
			label := "Choose files" if forms.has_attr(n, "multiple") else "Choose file"
			bw := font.text_width(fonts, fid, size, label) + 12 * scale
			b := draw.Rect{content.min, {content.min.x + bw, content.max.y}}
			draw.rect(dc, b, pal.face, 3 * scale)
			draw.rect(dc, b, pal.border, 3 * scale, max(scale, 1))
			centered_text(dc, fonts, fid, size, b, pal.face_text, label, line_h = lh)
			fl := forms.files(f, node)
			names := "No file chosen"
			if len(fl) == 1 { names = fl[0].name } else if len(fl) > 1 { names = strings.concatenate({itoa(len(fl)), " files"}, context.temp_allocator) }
			draw.push_clip(dc, {{b.max.x + 6 * scale, content.min.y}, content.max})
			centered_text(dc, fonts, fid, size, {{b.max.x + 6 * scale, content.min.y}, content.max}, fg, names, false, lh)
			draw.pop_clip(dc)
			if focused { draw.rect(dc, draw.rect_pad(b, 2 * scale), pal.focus_ring, 4 * scale, max(scale, 1)) }
		case:
			if t in forms.DATE_LIKE {
				// the picker indicator at the end, then the value: the user's short format unless it is being edited
				// (date_display.odin)
				room := page_render.settings.picker_indicator * scale
				if room > 0 {
					icon := draw.Rect{{content.max.x - room, (content.min.y + content.max.y - room) * 0.5}, {content.max.x, (content.min.y + content.max.y + room) * 0.5}}
					picker_indicator(dc, icon, fg, t == .Time, scale)
					pt.content.max.x = max(pt.content.min.x, pt.content.max.x - room - 4 * scale)
					fview.painted[node] = pt
				}
				if !focused {
					if shown := date_field_display(t, forms.value(f, node)); shown != "" {
						draw.push_clip(dc, pt.content)
						centered_text(dc, fonts, fid, size, pt.content, fg, shown, false, lh)
						draw.pop_clip(dc)
						break
					}
				}
			}
			paint_text_field(app, dc, fonts, fid, f, node, n, pt, fg, focused, &pal)
		}
	case .Textarea:
		paint_text_field(app, dc, fonts, fid, f, node, n, pt, fg, focused, &pal)
	case .Select:
		if forms.is_dropdown(f, node) {
			label := ""
			for o in forms.select_options_synced(f, node) { if forms.option_selected(f, o) { label = forms.option_label(f, o); break } }
			// as Chromium: the label after an internal start padding, the end of the content box kept for the arrow, the
			// arrow (a chevron half as wide as that room) centered in as much of the right of the border box, whatever
			// the page's padding
			ls := page_render.settings
			start, room := ls.select_start * scale, ls.select_arrow * scale
			text_r := draw.Rect{{content.min.x + start, content.min.y}, {content.max.x - room, content.max.y}}
			draw.push_clip(dc, {content.min, {content.max.x - room, content.max.y}})
			centered_text(dc, fonts, fid, size, text_r, fg, label, false, lh)
			draw.pop_clip(dc)
			if room > 0 {
				cx := border.max.x - room * 0.5
				cy := (border.min.y + border.max.y) * 0.5
				hw := room * 0.25
				chevron(dc, {cx, cy}, hw, max(1.5 * scale, 1), fg)
			}
		} else {
			paint_list_box(app, dc, fonts, fid, f, node, pt, fg, focused, &pal)
		}
	case .Button:
		centered_text(dc, fonts, fid, size, content, fg, button_label(f, node), line_h = lh)
	case .None, .Option, .Optgroup, .Fieldset, .Legend, .Output, .Form, .Label, .Object, .Datalist, .Dialog:
	}
}

@(private = "file")
paint_text_field :: proc(app: ^App, dc: ^draw.Context, fonts: ^font.State, fid: font.Font_Id, f: ^forms.Forms, node: base.Handle, n: ^dom.Node, pt: Painted, fg: draw.Color, focused: bool, pal: ^Control_Palette) {
	content := pt.content
	size := pt.size
	multiline := forms.kind_of(n) == .Textarea
	ft, origin := layout_field(app, f, node, pt)
	m := font.metrics(fonts, fid, size)
	// keep the caret visible (scroll is adjusted here, with the geometry of this frame)
	a, b, _ := forms.selection(f, node)
	cpos := forms.caret(f, node)
	cxy := caret_xy(ft, cpos, size, fid, fonts)
	sc := fview.scroll[node]
	w, h := content.max.x - content.min.x, content.max.y - content.min.y
	if focused {
		if cxy.x - sc.x > w - 2 { sc.x = cxy.x - w + 2 }
		if cxy.x - sc.x < 0 { sc.x = cxy.x }
		if multiline {
			if cxy.y - sc.y + ft.line_h > h { sc.y = cxy.y + ft.line_h - h }
			if cxy.y - sc.y < 0 { sc.y = cxy.y }
		}
	}
	if !multiline {
		total := font.text_width(fonts, fid, size, ft.display)
		sc.x = clamp(sc.x, 0, max(total - w + 2, 0))
	}
	sc.x = max(sc.x, 0)
	sc.y = max(sc.y, 0)
	if multiline { sc.x = 0 }
	fview.scroll[node] = sc
	origin = multiline ? {content.min.x, content.min.y - sc.y} : {content.min.x - sc.x, origin.y}

	draw.push_clip(dc, content)
	defer draw.pop_clip(dc)
	edit := forms.edit_text(f, node)
	if edit == "" {
		if ph, ok := forms.attr(n, "placeholder"); ok && ph != "" {
			pc := fg
			pc.a *= 0.45
			text := multiline ? ph : forms.collapse_ws(ph)
			y := origin.y
			rest := text
			for line in strings.split_lines_iterator(&rest) {
				draw.text(dc, fid, size, {origin.x, y + (ft.line_h - (m.ascent + m.descent)) * 0.5 + m.ascent}, pc, line)
				y += ft.line_h
			}
		}
	}
	// selection
	if a != b {
		da, db := ft.starts[a], ft.starts[b]
		color := focused ? pal.highlight : pal.highlight_dim
		for l, i in ft.lines {
			s0, s1 := max(da, l.start), min(db, l.end)
			if s0 > s1 || (s0 == s1 && !(db > l.end && s0 == l.end)) { continue }
			x0 := font.x_from_index(fonts, fid, size, ft.display[l.start:l.end], s0 - l.start)
			x1 := font.x_from_index(fonts, fid, size, ft.display[l.start:l.end], s1 - l.start)
			if db > l.end && multiline { x1 += size * 0.3 }   // the selected line break
			y := origin.y + f32(i) * ft.line_h
			draw.rect(dc, {{origin.x + x0, y}, {origin.x + x1, y + ft.line_h}}, color)
		}
	}
	for l, i in ft.lines {
		y := origin.y + f32(i) * ft.line_h
		if y > content.max.y || y + ft.line_h < content.min.y { continue }
		draw.text(dc, fid, size, {origin.x, y + (ft.line_h - (m.ascent + m.descent)) * 0.5 + m.ascent}, fg, ft.display[l.start:l.end])
	}
	if focused && fview.blink_on && a == b && forms.is_mutable(f, node) {
		x := math.round(origin.x + cxy.x)
		y := origin.y + cxy.y
		cw := max(page_scale(the_app), 1)
		draw.rect(dc, {{x, y + ft.line_h * 0.1}, {x + cw, y + ft.line_h * 0.9}}, fg)
	}
}

////////////////////////////////
// Select list rows (list boxes and the drop-down popup)

Row :: struct {
	option: base.Handle,   // NIL for an optgroup label
	label:  string,
	indent: bool,
}

@(private = "file")
select_rows :: proc(f: ^forms.Forms, sel: base.Handle) -> []Row {
	rows := make([dynamic]Row, context.temp_allocator)
	n := dom.get(f.doc, sel)
	if n == nil { return nil }
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next {
		cn := dom.get(f.doc, ch)
		#partial switch forms.kind_of(cn) {
		case .Option: append(&rows, Row{option = ch, label = forms.option_label(f, ch)})
		case .Optgroup:
			lbl, _ := forms.attr(cn, "label")
			append(&rows, Row{label = lbl})
			for g := cn.first_child; g != base.NIL_HANDLE; g = dom.get(f.doc, g).next {
				if forms.kind(f, g) == .Option { append(&rows, Row{option = g, label = forms.option_label(f, g), indent = true}) }
			}
		}
	}
	return rows[:]
}

@(private = "file")
paint_rows :: proc(dc: ^draw.Context, fonts: ^font.State, fid: font.Font_Id, f: ^forms.Forms, rows: []Row, first: int, area: draw.Rect, row_h, size: f32, fg: draw.Color, hover: int, focused: bool, pal: ^Control_Palette) {
	scale := page_scale(the_app)
	draw.push_clip(dc, area)
	defer draw.pop_clip(dc)
	for i := first; i < len(rows); i += 1 {
		y := area.min.y + f32(i - first) * row_h
		if y > area.max.y { break }
		r := draw.Rect{{area.min.x, y}, {area.max.x, y + row_h}}
		row := rows[i]
		color := fg
		if row.option != base.NIL_HANDLE {
			sel := forms.option_selected(f, row.option)
			if i == hover { draw.rect(dc, r, pal.hover) }
			if sel { draw.rect(dc, r, focused || hover >= 0 ? pal.selected : pal.inactive); color = focused || hover >= 0 ? pal.selected_text : fg }
			if forms.is_disabled(f, row.option) { color.a *= 0.45 }
		} else {
			color.a *= 0.75
		}
		inset := (row.indent ? 14 : 4) * scale
		centered_text(dc, fonts, fid, size, {{r.min.x + inset, r.min.y}, r.max}, color, row.label, false)
	}
}

@(private = "file")
paint_list_box :: proc(app: ^App, dc: ^draw.Context, fonts: ^font.State, fid: font.Font_Id, f: ^forms.Forms, node: base.Handle, pt: Painted, fg: draw.Color, focused: bool, pal: ^Control_Palette) {
	rows := select_rows(f, node)
	m := font.metrics(fonts, fid, pt.size)
	row_h := math.ceil((m.ascent + m.descent) * 1.25)
	sc := fview.scroll[node]
	first := clamp(int(sc.y), 0, max(len(rows) - 1, 0))
	paint_rows(dc, fonts, fid, f, rows, first, pt.content, row_h, pt.size, fg, -1, focused, pal)
}

////////////////////////////////
// Overlays: drop-down list and validation bubble

forms_paint_overlays :: proc(app: ^App, dc: ^draw.Context, page_rect: draw.Rect) {
	_, p, f := current_page(app)
	if f == nil { return }
	scale := page_scale(the_app)
	fid := app.ui_font
	if fview.popup.open {
		pp := &fview.popup
		pt, ok := fview.painted[pp.sel]
		if ok {
			rows := select_rows(f, pp.sel)
			size := pt.size
			m := font.metrics(&app.fonts, fid, size)
			pp.row_h = math.ceil((m.ascent + m.descent) * 1.4)
			visible := min(len(rows), app.page_settings.forms.select_rows)
			wmax: f32 = 0
			for r in rows { wmax = max(wmax, font.text_width(&app.fonts, fid, size, r.label) + 24 * scale) }
			anchor := pp.anchor
			w := max(anchor.max.x - anchor.min.x, wmax)
			h := f32(visible) * pp.row_h + 2 * scale
			y := anchor.max.y
			if y + h > page_rect.max.y && anchor.min.y - h >= page_rect.min.y { y = anchor.min.y - h }
			x := clamp(anchor.min.x, page_rect.min.x, max(page_rect.max.x - w, page_rect.min.x))
			pp.rect = {{x, y}, {x + w, y + h}}
			pp.first = clamp(pp.first, 0, max(len(rows) - visible, 0))
			pal := control_palette(p.styled != nil ? style.style_of(p.styled, pp.sel) : nil)
			draw.rect(dc, draw.rect_shift(pp.rect, {0, 3 * scale}), pal.shadow, 4 * scale, 0, 8 * scale)
			draw.rect(dc, pp.rect, pal.field, 3 * scale)
			draw.rect(dc, pp.rect, pal.popup_border, 3 * scale, max(scale, 1))
			inner := draw.rect_pad(pp.rect, -scale)
			paint_rows(dc, &app.fonts, fid, f, rows, pp.first, inner, pp.row_h, size, pal.field_text, pp.hover, true, &pal)
			if len(rows) > visible {
				// scroll indicator
				track := draw.Rect{{inner.max.x - 4 * scale, inner.min.y}, inner.max}
				th := (track.max.y - track.min.y) * f32(visible) / f32(len(rows))
				ty := track.min.y + (track.max.y - track.min.y - th) * f32(pp.first) / f32(max(len(rows) - visible, 1))
				draw.rect(dc, {{track.min.x, ty}, {track.max.x, ty + th}}, pal.border, 2 * scale)
			}
		} else {
			pp.open = false
		}
	}
	if node, msg, shown := forms.current_report(f); shown {
		pt, ok := fview.painted[node]
		if ok && msg != "" {
			size := 13 * scale
			m := font.metrics(&app.fonts, fid, size)
			tw := font.text_width(&app.fonts, fid, size, msg)
			pad := 8 * scale
			icon := size * 1.3
			w := tw + icon + pad * 3
			h := m.ascent + m.descent + pad * 2
			x := clamp(painted_bounds(pt).min.x - 4 * scale, page_rect.min.x, max(page_rect.max.x - w, page_rect.min.x))
			y := painted_bounds(pt).max.y + 8 * scale
			r := draw.Rect{{x, y}, {x + w, y + h}}
			pal := control_palette(p.styled != nil ? style.style_of(p.styled, node) : nil)
			bubble := pal.scheme == .Dark ? draw.hex(0x3b3b3bff) : draw.hex(0xffffffff)
			draw.rect(dc, draw.rect_shift(r, {0, 2 * scale}), pal.shadow, 5 * scale, 0, 8 * scale)
			draw.rect(dc, {{x + 14 * scale, y - 5 * scale}, {x + 24 * scale, y + 5 * scale}}, bubble, 2 * scale)
			draw.rect(dc, r, bubble, 5 * scale)
			draw.rect(dc, r, pal.popup_border, 5 * scale, max(scale, 1))
			ic := draw.Rect{{x + pad, y + (h - icon) * 0.5}, {x + pad + icon, y + (h + icon) * 0.5}}
			draw.rect(dc, ic, draw.hex(0xf29d00ff), 3 * scale)
			centered_text(dc, &app.fonts, fid, size, ic, draw.hex(0xffffffff), "!")
			centered_text(dc, &app.fonts, fid, size, {{ic.max.x + pad, y}, {r.max.x, r.max.y}}, pal.field_text, msg, false)
		}
	}
	_ = p
}

////////////////////////////////
// Input

@(private = "file")
mods_of :: proc(m: platform.Modifiers) -> forms.Mods {
	out: forms.Mods
	if .Ctrl in m { out += {.Ctrl} }
	if .Shift in m { out += {.Shift} }
	if .Alt in m { out += {.Alt} }
	return out
}

dom_mods :: proc(m: platform.Modifiers) -> u32 {
	v: u32
	if .Ctrl in m { v |= 1 }
	if .Shift in m { v |= 2 }
	if .Alt in m { v |= 4 }
	return v
}

// KeyboardEvent.keyCode and .key of a platform key.
@(private = "file")
dom_key :: proc(k: platform.Key, shift: bool) -> (code: u32, name: string) {
	#partial switch k {
	case .A ..= .Z:
		i := u32(k) - u32(platform.Key.A)
		c := u8('a' + i)
		if shift { c -= 32 }
		return 65 + i, strings.clone(string([]u8{c}), context.temp_allocator)
	case .N0 ..= .N9:
		i := u32(k) - u32(platform.Key.N0)
		return 48 + i, strings.clone(string([]u8{u8('0' + i)}), context.temp_allocator)
	case .F1 ..= .F12:
		i := u32(k) - u32(platform.Key.F1)
		return 112 + i, strings.concatenate({"F", itoa(int(i) + 1)}, context.temp_allocator)
	case .Escape: return 27, "Escape"
	case .Return: return 13, "Enter"
	case .Tab: return 9, "Tab"
	case .Space: return 32, " "
	case .Backspace: return 8, "Backspace"
	case .Delete: return 46, "Delete"
	case .Insert: return 45, "Insert"
	case .Left: return 37, "ArrowLeft"
	case .Up: return 38, "ArrowUp"
	case .Right: return 39, "ArrowRight"
	case .Down: return 40, "ArrowDown"
	case .Home: return 36, "Home"
	case .End: return 35, "End"
	case .Page_Up: return 33, "PageUp"
	case .Page_Down: return 34, "PageDown"
	case .Comma: return 188, ","
	case .Period: return 190, "."
	case .Slash: return 191, "/"
	case .Minus: return 189, "-"
	case .Equal: return 187, "="
	case .Shift: return 16, "Shift"
	case .Ctrl: return 17, "Control"
	case .Alt: return 18, "Alt"
	}
	return 0, "Unidentified"
}

@(private = "file")
forms_key_of :: proc(k: platform.Key) -> forms.Key {
	#partial switch k {
	case .Left: return .Left
	case .Right: return .Right
	case .Up: return .Up
	case .Down: return .Down
	case .Home: return .Home
	case .End: return .End
	case .Page_Up: return .Page_Up
	case .Page_Down: return .Page_Down
	case .Backspace: return .Backspace
	case .Delete: return .Delete
	case .Return: return .Enter
	case .Space: return .Space
	case .Escape: return .Escape
	case .Tab: return .Tab
	case .A: return .A
	case .Z: return .Z
	case .Y: return .Y
	case .F4: return .F4
	}
	return .None
}

// Keyboard and text events go to the page while it has the keyboard focus (the last click was in the page and no
// chrome widget took the focus since). Returns true when the event was used.
forms_route_event :: proc(app: ^App, t: ^Tab, ev: platform.Event, index: int) -> bool {
	if t == nil || t.page == nil || t.kind != .Web || t.page.formctl == nil { return false }
	p := t.page
	f := page.page_forms(p)
	#partial switch ev.kind {
	case .Mouse_Press:
		inside := draw.rect_contains(app.page_rect, ev.pos)
		fview.page_focus = inside
		if fview.popup.open {
			if draw.rect_contains(fview.popup.rect, ev.pos) {
				popup_pick(app, f, ev.pos, .Ctrl in ev.mods)
			}
			fview.popup.open = false
			request_frames(app)
			return true   // a press that closes the list does nothing else
		}
		return false
	case .Mouse_Move:
		if fview.popup.open && draw.rect_contains(fview.popup.rect, ev.pos) {
			idx := fview.popup.first + int((ev.pos.y - fview.popup.rect.min.y) / max(fview.popup.row_h, 1))
			if idx != fview.popup.hover { fview.popup.hover = idx; request_frames(app) }
		}
		if fview.drag != .None && fview.press_down { pointer_drag(app, t, f, ev.pos); request_frames(app) }
		return false
	case .Scroll:
		if fview.popup.open && draw.rect_contains(fview.popup.rect, ev.pos) {
			rows := len(select_rows(f, fview.popup.sel))
			fview.popup.first = clamp(fview.popup.first + int(ev.delta.y * 3), 0, max(rows - app.page_settings.forms.select_rows, 0))
			request_frames(app)
			return true
		}
		return false
	case .Key_Press:
		if !keyboard_to_page(app) { return false }
		used := route_key(app, t, p, f, ev)
		if used { consume(index); caret_reset(); request_frames(app) }
		return used
	case .Key_Release:
		if !keyboard_to_page(app) { return false }
		code, name := dom_key(ev.key, .Shift in ev.mods)
		target := f.focus != base.NIL_HANDLE ? f.focus : p.body
		page.dispatch_event(p, target, dom.Event{type = "keyup", bubbles = true, cancelable = true, key = code, text = name, mods = dom_mods(ev.mods)})
		return false
	case .Text:
		if !keyboard_to_page(app) { return false }
		if fview.popup.open { consume(index); return true }
		if ev.text < 32 || .Ctrl in ev.mods && .Alt not_in ev.mods { return false }
		buf, n := utf8.encode_rune(ev.text)
		if forms.type_text(f, string(buf[:n])) {
			consume(index)
			caret_reset()
			request_frames(app)
			return true
		}
		if forms.is_text_field(f, f.focus) { consume(index); return true }   // read-only field: still the page's text
		return false
	}
	return false
}

@(private = "file")
keyboard_to_page :: proc(app: ^App) -> bool { return fview.page_focus && ui.focus_key() == 0 && !ui.ctx_menu_any_open() && !setup_captures() }

// Set when Shift+Tab leaves the page before its first element: the chrome takes the focus back from the page area.
page_focus_leave_backward: bool

// The page has the keyboard (its own focus, not the chrome's).
page_has_keyboard :: proc(app: ^App) -> bool { return keyboard_to_page(app) }

// The chrome's Tab order reached the page area: the page takes the keyboard, its first (Tab) or last (Shift+Tab)
// element the focus (none: the page itself, keyboard scrolling works).
forms_focus_from_chrome :: proc(app: ^App, t: ^Tab, dir: int) {
	fview.page_focus = true
	if t == nil || t.page == nil || t.page.formctl == nil { return }
	p := t.page
	f := page.page_forms(p)
	forms.blur(f)
	visible :: proc(user: rawptr, h: base.Handle) -> bool { return is_rendered((^page.Page)(user), h) }
	if forms.focus_next(f, dir < 0 ? -1 : 1, visible, p) { scroll_into_view(app, t, f.focus) }
	request_frames(app)
}

// The page gives up the keyboard (a chrome widget took it).
forms_page_blur :: proc() { fview.page_focus = false }

@(private = "file")
route_key :: proc(app: ^App, t: ^Tab, p: ^page.Page, f: ^forms.Forms, ev: platform.Event) -> bool {
	ctrl, shift, alt := .Ctrl in ev.mods, .Shift in ev.mods, .Alt in ev.mods
	// the open list owns the keyboard
	if fview.popup.open { popup_key(app, f, ev); return true }
	code, name := dom_key(ev.key, shift)
	target := f.focus != base.NIL_HANDLE ? f.focus : p.body
	if !page.dispatch_event(p, target, dom.Event{type = "keydown", bubbles = true, cancelable = true, key = code, text = name, mods = dom_mods(ev.mods)}) {
		return true   // the page cancelled it: no default action (browser shortcuts stay the chrome's, see below)
	}
	if t.page != p { return true }   // a listener navigated
	h := f.focus
	// browser shortcuts are never the page's
	if ctrl && (ev.key == .T || ev.key == .W || ev.key == .L || ev.key == .R) { return false }
	if ev.key == .F5 || (alt && (ev.key == .Left || ev.key == .Right)) { return false }

	if ev.key == .Tab && !ctrl && !alt {
		visible :: proc(user: rawptr, h: base.Handle) -> bool { return is_rendered((^page.Page)(user), h) }
		if forms.focus_next(f, shift ? -1 : 1, visible, p) {
			scroll_into_view(app, t, f.focus)
			return true
		}
		// past the last (or before the first) element: the chrome's Tab order continues, from the address bar onwards
		// or back from the page area
		forms.blur(f)
		fview.page_focus = false
		if shift { page_focus_leave_backward = true } else { app.focus_address = true }
		return true
	}
	if !forms.is_text_field(f, h) && selection_key(app, t, p, ev) { return true }
	// Enter on a focused link follows it (a click, so the page sees it and may cancel)
	if ev.key == .Return && !ctrl && !alt && !shift && h != base.NIL_HANDLE && !forms.is_text_field(f, h) {
		if href, ok := anchor_href(p.doc, h); ok && forms.kind(f, h) == .None {
			if forms.click(f, h, forms.Click_Info{trusted = true}) && t.page == p {
				follow_link(app, t, href)
			}
			return true
		}
	}
	if forms.is_text_field(f, h) && ctrl && !alt {
		#partial switch ev.key {
		case .C, .Insert:
			if page.dispatch_event(p, h, dom.Event{type = "copy", bubbles = true, cancelable = true}) {
				if s := forms.copy_text(f, h); s != "" { clip_set(s) }
			}
			return true
		case .X:
			if page.dispatch_event(p, h, dom.Event{type = "cut", bubbles = true, cancelable = true}) {
				if s := forms.cut(f, h); s != "" { clip_set(s) }
			}
			return true
		case .V:
			text := strings.clone(clip_get(), context.temp_allocator)
			if page.dispatch_event(p, h, dom.Event{type = "paste", bubbles = true, cancelable = true, data = text}) {
				forms.paste(f, h, text)
			}
			return true
		case:
		}
	}
	if forms.is_text_field(f, h) && shift && !ctrl && ev.key == .Insert {
		text := strings.clone(clip_get(), context.temp_allocator)
		if page.dispatch_event(p, h, dom.Event{type = "paste", bubbles = true, cancelable = true, data = text}) { forms.paste(f, h, text) }
		return true
	}
	if forms.is_text_field(f, h) && shift && !ctrl && ev.key == .Delete {
		if page.dispatch_event(p, h, dom.Event{type = "cut", bubbles = true, cancelable = true}) {
			if s := forms.cut(f, h); s != "" { clip_set(s) }
		}
		return true
	}
	// textarea Up/Down follow the visual (wrapped) lines
	if forms.kind(f, h) == .Textarea && !ctrl && !alt && (ev.key == .Up || ev.key == .Down) {
		if pt, ok := fview.painted[h]; ok {
			ft, _ := layout_field(app, f, h, pt)
			cur := caret_xy(ft, forms.caret(f, h), pt.size, pt.font, &app.fonts)
			ny := cur.y + (ev.key == .Up ? -ft.line_h : ft.line_h) + ft.line_h * 0.5
			pos := hit_text(ft, {cur.x, ny}, pt.size, pt.font, &app.fonts)
			if ny < 0 { pos = 0 } else if int(ny / ft.line_h) >= len(ft.lines) { pos = len(forms.edit_text(f, h)) }
			move_to(f, h, pos, shift)
			return true
		}
	}
	// a drop-down opens with Alt+Down / Alt+Up / F4, and Space
	if forms.kind(f, h) == .Select && forms.is_dropdown(f, h) {
		if (alt && (ev.key == .Down || ev.key == .Up)) || ev.key == .F4 || (ev.key == .Space && !ctrl) {
			open_popup(app, f, h)
			return true
		}
	}
	if forms.kind(f, h) == .Select && !forms.is_dropdown(f, h) && ev.key == .A && ctrl {
		for o in forms.select_options(f, h) { if !forms.is_disabled(f, o) { forms.set_option_selected(f, o, true) } }
		return true
	}
	k := forms_key_of(ev.key)
	if k != .None && forms.key_down(f, k, mods_of(ev.mods)) {
		if t.page == p && f.focus != base.NIL_HANDLE { ensure_list_scroll(f, f.focus) }
		return true
	}
	// default action: keyboard scrolling, never while typing in a text field
	if t.page != p || forms.is_text_field(f, h) { return false }
	return keyboard_scroll(app, t, h != base.NIL_HANDLE ? h : t.scroll_target, key_scroll_of(ev))
}

@(private = "file")
move_to :: proc(f: ^forms.Forms, h: base.Handle, pos: int, extend: bool) {
	a, b, d := forms.selection(f, h)
	if !extend { forms.set_selection(f, h, pos, pos); return }
	anchor := d == .Backward ? b : a
	if pos < anchor { forms.set_selection(f, h, pos, anchor, .Backward) } else { forms.set_selection(f, h, anchor, pos, .Forward) }
}

@(private = "file")
ensure_list_scroll :: proc(f: ^forms.Forms, h: base.Handle) {
	if forms.kind(f, h) != .Select || forms.is_dropdown(f, h) { return }
	rows := select_rows(f, h)
	sel := -1
	for r, i in rows { if r.option != base.NIL_HANDLE && forms.option_selected(f, r.option) { sel = i } }
	if sel < 0 { return }
	visible := forms.display_size(f, h)
	sc := fview.scroll[h]
	first := int(sc.y)
	if sel < first { first = sel } else if sel >= first + visible { first = sel - visible + 1 }
	sc.y = f32(first)
	fview.scroll[h] = sc
}

////////////////////////////////
// Drop-down list

@(private = "file")
open_popup :: proc(app: ^App, f: ^forms.Forms, sel: base.Handle) {
	pt, ok := fview.painted[sel]
	if !ok { return }
	rows := select_rows(f, sel)
	hover := -1
	for r, i in rows { if r.option != base.NIL_HANDLE && forms.option_selected(f, r.option) { hover = i } }
	fview.popup = Popup{open = true, sel = sel, page_id = f.id, hover = hover, anchor = draw.rect_pad(painted_bounds(pt), 3 * page_scale(the_app))}
	fview.popup.first = max(hover - app.page_settings.forms.select_rows / 2, 0)
	request_frames(app)
}

@(private = "file")
popup_pick :: proc(app: ^App, f: ^forms.Forms, pos: [2]f32, toggle: bool) {
	pp := &fview.popup
	rows := select_rows(f, pp.sel)
	idx := pp.first + int((pos.y - pp.rect.min.y) / max(pp.row_h, 1))
	if idx < 0 || idx >= len(rows) || rows[idx].option == base.NIL_HANDLE { return }
	forms.choose_option(f, pp.sel, rows[idx].option)
}

@(private = "file")
popup_key :: proc(app: ^App, f: ^forms.Forms, ev: platform.Event) {
	pp := &fview.popup
	rows := select_rows(f, pp.sel)
	move :: proc(rows: []Row, from, dir: int, f: ^forms.Forms) -> int {
		i := from
		for {
			i += dir
			if i < 0 || i >= len(rows) { return from }
			if rows[i].option != base.NIL_HANDLE && !forms.is_disabled(f, rows[i].option) { return i }
		}
	}
	visible := app.page_settings.forms.select_rows
	#partial switch ev.key {
	case .Up: pp.hover = move(rows, pp.hover, -1, f)
	case .Down: pp.hover = move(rows, max(pp.hover, -1), 1, f)
	case .Home: pp.hover = move(rows, -1, 1, f)
	case .End: pp.hover = move(rows, len(rows), -1, f)
	case .Page_Up: for _ in 0 ..< visible - 1 { pp.hover = move(rows, pp.hover, -1, f) }
	case .Page_Down: for _ in 0 ..< visible - 1 { pp.hover = move(rows, pp.hover, 1, f) }
	case .Return, .Space, .Tab:
		if pp.hover >= 0 && pp.hover < len(rows) && rows[pp.hover].option != base.NIL_HANDLE { forms.choose_option(f, pp.sel, rows[pp.hover].option) }
		pp.open = false
	case .Escape, .F4: pp.open = false
	case:
		if .Alt in ev.mods { pp.open = false }
	}
	if pp.hover >= 0 {
		if pp.hover < pp.first { pp.first = pp.hover } else if pp.hover >= pp.first + visible { pp.first = pp.hover - visible + 1 }
	}
}

////////////////////////////////
// Pointer

@(private = "file")
focus_target :: proc(f: ^forms.Forms, target: base.Handle) -> base.Handle {
	for cur := target; cur != base.NIL_HANDLE; cur = forms.parent_element(f, cur) {
		if forms.is_focusable(f, cur) { return cur }
	}
	return base.NIL_HANDLE
}

// A press in the page: mousedown, then (unless cancelled) focus, caret placement or selection start, slider, list box,
// drop-down. Returns false when mousedown was cancelled (no default action: no text selection either).
forms_pointer_down :: proc(app: ^App, t: ^Tab, ev: platform.Event, target: base.Handle, local: [2]f32) -> bool {
	p := t.page
	if p == nil || p.formctl == nil { return true }
	f := page.page_forms(p)
	scale := page_scale(the_app)
	fview.press_target, fview.press_down = target, ev.button == .Left
	if target == base.NIL_HANDLE {
		if ev.button == .Left { forms.blur(f) }
		return true
	}
	cx, cy := page_client_xy(t, local, scale)   // page_input.odin: `local` has the scroll, events want the viewport's
	// pointerdown first (Pointer Events); a cancelled one suppresses the compatibility mousedown, not the default actions
	if page_pointer_button(app, t, "pointerdown", target, ev, cx, cy) {
		if !page.dispatch_event(p, target, dom.Event{type = "mousedown", bubbles = true, cancelable = true, x = cx, y = cy, button = i32(ev.button), mods = dom_mods(ev.mods), buttons = dom_buttons(ev.buttons)}) {
			return false
		}
	}
	if t.page != p { return true }
	if t.page != p || ev.button != .Left { return true }
	// click counting (double click selects a word, triple the whole field)
	now := time.tick_now()
	if time.duration_milliseconds(time.tick_diff(fview.last_click, now)) <= double_click_ms(app) && abs(ev.pos.x - fview.last_click_pos.x) < 4 * scale && abs(ev.pos.y - fview.last_click_pos.y) < 4 * scale {
		fview.click_count += 1
	} else {
		fview.click_count = 1
	}
	fview.last_click, fview.last_click_pos = now, ev.pos

	ft := focus_target(f, target)
	if ft == base.NIL_HANDLE { forms.blur(f); return true }
	if forms.kind(f, ft) != .Label { forms.focus(f, ft) }
	caret_reset()
	request_frames(app)
	pt, painted := fview.painted[ft]
	if !painted { return true }
	switch {
	case forms.is_text_field(f, ft):
		ftext, origin := layout_field(app, f, ft, pt)
		pos := hit_text(ftext, painted_local(pt, ev.pos) - origin, pt.size, pt.font, &app.fonts)
		src := forms.edit_text(f, ft)
		switch {
		case fview.click_count == 2:
			a, b := forms.word_at(src, pos)
			forms.set_selection(f, ft, a, b, .Forward)
		case fview.click_count >= 3:
			forms.select_all(f, ft)
		case .Shift in ev.mods:
			move_to(f, ft, pos, true)
		case:
			forms.set_selection(f, ft, pos, pos)
		}
		fview.drag, fview.drag_node = .Text, ft
	case forms.kind(f, ft) == .Input && forms.input_type(f, ft) == .Range && forms.is_mutable(f, ft):
		fview.drag, fview.drag_node = .Range, ft
		set_range_from_x(p, f, ft, pt, painted_local(pt, ev.pos).x)
	case forms.kind(f, ft) == .Select && !forms.is_disabled(f, ft):
		if forms.is_dropdown(f, ft) {
			if fview.popup.open && fview.popup.sel == ft { fview.popup.open = false } else { open_popup(app, f, ft) }
		} else {
			rows := select_rows(f, ft)
			m := font.metrics(&app.fonts, pt.font, pt.size)
			row_h := math.ceil((m.ascent + m.descent) * 1.25)
			idx := int(fview.scroll[ft].y) + int((painted_local(pt, ev.pos).y - pt.content.min.y) / row_h)
			if idx >= 0 && idx < len(rows) && rows[idx].option != base.NIL_HANDLE {
				forms.choose_option(f, ft, rows[idx].option, extend = .Shift in ev.mods, toggle = .Ctrl in ev.mods)
			}
		}
	}
	return true
}

@(private = "file")
set_range_from_x :: proc(p: ^page.Page, f: ^forms.Forms, h: base.Handle, pt: Painted, x: f32) {
	n := dom.get(f.doc, h)
	lim := forms.limits(f, n, .Range)
	thumb := (pt.content.max.y - pt.content.min.y) * 0.8
	x0, x1 := pt.content.min.x + thumb * 0.5, pt.content.max.x - thumb * 0.5
	k := clamp((x - x0) / max(x1 - x0, 1), 0, 1)
	v := lim.min + f64(k) * (lim.max - lim.min)
	s := forms.sanitize(f, n, .Range, forms.format_float(v))
	if s != forms.value(f, h) {
		forms.set_value(f, h, s, by_user = true)
		page.dispatch_event(p, h, dom.Event{type = "input", bubbles = true})
	}
}

@(private = "file")
pointer_drag :: proc(app: ^App, t: ^Tab, f: ^forms.Forms, pos: [2]f32) {
	h := fview.drag_node
	pt, ok := fview.painted[h]
	if !ok || dom.get(f.doc, h) == nil { fview.drag = .None; return }
	switch fview.drag {
	case .Text:
		if f.focus != h { fview.drag = .None; return }
		ftext, origin := layout_field(app, f, h, pt)
		local := painted_local(pt, pos) - origin
		pos2 := hit_text(ftext, local, pt.size, pt.font, &app.fonts)
		move_to(f, h, pos2, true)
	case .Range:
		set_range_from_x(t.page, f, h, pt, painted_local(pt, pos).x)
	case .None:
	}
}

// A release: mouseup, the end of a drag; returns the click target (the common ancestor of the press and release targets).
forms_pointer_up :: proc(app: ^App, t: ^Tab, ev: platform.Event, target: base.Handle, local: [2]f32) -> (click_target: base.Handle, ok: bool) {
	p := t.page
	if p == nil { return }
	scale := page_scale(the_app)
	was_down := fview.press_down
	fview.press_down = false
	if fview.drag == .Range && p.formctl != nil {
		f := page.page_forms(p)
		if dom.get(p.doc, fview.drag_node) != nil {
			if c := forms.control_peek(f, fview.drag_node); c != nil { c.user_validity = true }
			page.dispatch_event(p, fview.drag_node, dom.Event{type = "change", bubbles = true})
		}
	}
	fview.drag = .None
	cx, cy := page_client_xy(t, local, scale)
	up_target := page_pointer_target(t, target)   // a captured pointer's release goes to the capturing element
	if up_target != base.NIL_HANDLE {
		if page_pointer_button(app, t, "pointerup", up_target, ev, cx, cy) && t.page == p {
			page.dispatch_event(p, up_target, dom.Event{type = "mouseup", bubbles = true, cancelable = true, x = cx, y = cy, button = i32(ev.button), mods = dom_mods(ev.mods), buttons = dom_buttons(ev.buttons)})
		}
	}
	if t.page != p { return }
	if t.page != p || !was_down || target == base.NIL_HANDLE || fview.press_target == base.NIL_HANDLE { return }
	// common ancestor of where the button went down and where it came up
	for a := fview.press_target; a != base.NIL_HANDLE; {
		if dom.is_ancestor_or_self(p.doc, a, target) { return a, true }
		n := dom.get(p.doc, a)
		if n == nil { break }
		a = n.parent
	}
	return
}

// The click with its activation behaviour (checkbox toggling, buttons submitting, labels...). True when not cancelled.
forms_click :: proc(app: ^App, t: ^Tab, target: base.Handle, ev: platform.Event, local: [2]f32) -> bool {
	p := t.page
	scale := page_scale(the_app)
	cx, cy := page_client_xy(t, local, scale)
	info := forms.Click_Info{x = cx, y = cy, button = i32(ev.button), mods = dom_mods(ev.mods), trusted = true}
	if p.formctl == nil {
		return page.dispatch_event(p, target, dom.Event{type = "click", bubbles = true, cancelable = true, x = info.x, y = info.y, button = info.button})
	}
	f := page.page_forms(p)
	if o, ok := layout_offset(t, target, local); ok { info.offset = {i32(o.x / scale), i32(o.y / scale)} }
	ok := forms.click(f, target, info)
	request_frames(app)
	return ok
}

////////////////////////////////
// Submissions -> navigations

@(private = "file")
tab_of_page :: proc(app: ^App, p: ^page.Page) -> ^Tab {
	for t in app.tabs { if t.page == p { return t } }
	return nil
}

@(private = "file")
Post_Job :: struct {
	app:       ^App,
	tab:       ^Tab,
	from:      ^page.Page,
	sub:       ^forms.Submission,
	settings:  forms.Settings,
	cleanup:   base.Cleanup_Id,
	scope:     ^base.Scope,
	cancelled: bool,
	ok:        bool,
	message:   string,
}

// The page planned a navigation (forms.Submission). GET navigates; POST encodes the body (on a worker when files must
// be read) and navigates with it; mailto: goes to the system's mail program.
shell_navigate_submission :: proc(user: rawptr, p: ^page.Page, s: ^forms.Submission) {
	app := (^App)(user)
	if frames_take_submission(app, p, s) { return }
	t := tab_of_page(app, p)
	if t == nil { forms.submission_destroy(s); return }
	if s.mailto {
		open_external(app, s.url)
		forms.submission_destroy(s)
		return
	}
	if s.method == .Get || s.method == .Dialog {
		submit_navigate(app, t, p, s)
		forms.submission_destroy(s)
		return
	}
	job := new(Post_Job)
	job.app, job.tab, job.from, job.sub, job.settings, job.scope = app, t, p, s, app.page_settings.forms, t.nav
	if !forms.needs_file_reads(s.entries[:]) {
		post_work(job)
		post_done(job)
		return
	}
	set_status(t, "sending the form's files...")
	job.cleanup = base.on_close(t.nav, proc(data: rawptr) { (^Post_Job)(data).cancelled = true }, job)
	host.run_blocking(&app.blocking, post_work, proc(data: rawptr) {
		job := (^Post_Job)(data)
		if !job.cancelled { base.forget_cleanup(job.scope, job.cleanup) }
		post_done(job)
	}, job)
}

@(private = "file")
post_work :: proc(data: rawptr) {
	job := (^Post_Job)(data)
	job.ok, job.message = forms.encode_submission(job.sub, job.settings)
}

@(private = "file")
post_done :: proc(job: ^Post_Job) {
	defer {
		forms.submission_destroy(job.sub)
		delete(job.message)
		free(job)
	}
	if job.cancelled { return }
	if !job.ok { tab_log(job.tab, .Error, job.message); set_status(job.tab, "form not sent"); return }
	submit_navigate(job.app, job.tab, job.from, job.sub)
	job.app.frames_requested = max(job.app.frames_requested, 3)
}

@(private = "file")
submit_navigate :: proc(app: ^App, t: ^Tab, from: ^page.Page, s: ^forms.Submission) {
	dest := t
	if strings.equal_fold(s.target, "_blank") {
		dest = tab_open(app, "", origin = .User)
	}
	if s.method == .Post {
		headers := []fetch.Header_Pair{{"Content-Type", s.content_type}}
		navigate(app, dest, s.url, from, user_activation = true, method = "POST", body = s.body, headers = headers)
	} else {
		navigate(app, dest, s.url, from, user_activation = true)
	}
}

// A submission that concerns a frame (frames_shell.odin): from a frame's document, or towards a frame its target names.
// Its sandbox may refuse it (allow-forms); a frame navigates with the submission's method and body (a body with files
// to read is sent from a tab only); the tab's own document with no frame target is not taken (false).
@(private = "file")
frames_take_submission :: proc(app: ^App, p: ^page.Page, s: ^forms.Submission) -> bool {
	in_frame := frame_view_of(p) != nil
	target := strings.trim_space(s.target)
	if !in_frame && (target == "" || strings.equal_fold(target, "_self") || strings.equal_fold(target, "_top") || strings.equal_fold(target, "_blank")) { return false }
	defer forms.submission_destroy(s)
	if sb := page.page_sandbox(p); sb.active && .Forms not_in sb.allow {
		page.log(p, .Error, "Blocked form submission because the form's frame is sandboxed and the 'allow-forms' permission is not set.")
		return true
	}
	if s.mailto { open_external(app, s.url); return true }
	n := page.frames_find_target(p, target)
	if n == nil {
		// _blank, or a name nothing has: a new tab (a GET; a POST's body goes with it only from a tab)
		tab_open(app, s.url, p)
		return true
	}
	if n.parent == nil {
		// the tab's document
		top := page.page_top(p)
		t := tab_of_page(app, top)
		if t == nil { return true }
		if why := page.navigation_allowed(p, n); why != "" { tab_log(t, .Error, why); return true }
		if s.method == .Post && !forms.needs_file_reads(s.entries[:]) {
			if ok, msg := forms.encode_submission(s, app.page_settings.forms); !ok { tab_log(t, .Error, msg); delete(msg); return true }
		}
		submit_navigate(app, t, p, s)
		return true
	}
	method, ctype := "", ""
	if s.method == .Post {
		if forms.needs_file_reads(s.entries[:]) { page.log(p, .Warn, "a form with files is not sent to a frame"); return true }
		ok, msg := forms.encode_submission(s, app.page_settings.forms)
		defer delete(msg)
		if !ok { page.log(p, .Error, msg); return true }
		method, ctype = "POST", s.content_type
	}
	if why := page.frames_navigate_from(p, n, s.url, false, method, s.body, ctype); why != "" { page.log(p, .Error, why) }
	return true
}

// mailto: and other schemes the browser does not handle: the system's handler (on a worker: the shell may block).
@(private = "file")
open_external :: proc(app: ^App, target: string) {
	w := new(string)
	w^ = strings.clone(target)
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		s := (^string)(data)
		_ = win.CoInitializeEx(nil, .APARTMENTTHREADED)
		win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(s^, context.temp_allocator), nil, nil, win.SW_SHOWNORMAL)
		win.CoUninitialize()
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		s := (^string)(data)
		delete(s^)
		free(s)
	}, w)
}

////////////////////////////////
// Pickers (file and color dialogs), on a worker thread so the window keeps painting

@(private = "file")
Picker_Job :: struct {
	app:       ^App,
	page:      ^page.Page,
	input:     base.Handle,
	cleanup:   base.Cleanup_Id,
	cancelled: bool,
	color:     bool,
	multiple:  bool,
	filter:    string,          // owned, UTF-8 with NULs
	owner:     win.HWND,
	files:     [dynamic]forms.File,
	initial:   u32,             // COLORREF
	result:    u32,
	ok:        bool,
	max_files: int,
}

@(private = "file")
start_picker :: proc(app: ^App, p: ^page.Page, input: base.Handle, color: bool) {
	f := page.page_forms(p)
	n := dom.get(p.doc, input)
	if n == nil { return }
	job := new(Picker_Job)
	job.app, job.page, job.input, job.color, job.owner = app, p, input, color, app.win.hwnd
	job.multiple = forms.has_attr(n, "multiple")
	job.max_files = app.page_settings.forms.upload_max_files
	if color {
		v := forms.value(f, input)
		c := parse_hex_bytes(v)
		job.initial = u32(c[0]) | u32(c[1]) << 8 | u32(c[2]) << 16
	} else {
		accept, _ := forms.attr(n, "accept")
		job.filter = accept_filter(accept)
	}
	job.cleanup = base.on_close(p.scope, proc(data: rawptr) { (^Picker_Job)(data).cancelled = true }, job)
	host.run_blocking(&app.blocking, picker_work, picker_done, job)
}

shell_pick_files :: proc(user: rawptr, p: ^page.Page, input: base.Handle) { start_picker((^App)(user), p, input, false) }
shell_pick_color :: proc(user: rawptr, p: ^page.Page, input: base.Handle) { start_picker((^App)(user), p, input, true) }

@(private = "file")
parse_hex_bytes :: proc(s: string) -> [3]u8 {
	out: [3]u8
	if len(s) != 7 { return out }
	hexv :: proc(c: u8) -> u8 {
		switch c {
		case '0' ..= '9': return c - '0'
		case 'a' ..= 'f': return c - 'a' + 10
		case 'A' ..= 'F': return c - 'A' + 10
		}
		return 0
	}
	for i in 0 ..< 3 { out[i] = hexv(s[1 + 2 * i]) * 16 + hexv(s[2 + 2 * i]) }
	return out
}

// The dialog's filter from the `accept` attribute: extensions as given, MIME types through a small table.
@(private = "file")
accept_filter :: proc(accept: string) -> string {
	patterns := make([dynamic]string, context.temp_allocator)
	rest := accept
	for tok in strings.split_iterator(&rest, ",") {
		t := strings.to_lower(strings.trim_space(tok), context.temp_allocator)
		switch {
		case strings.has_prefix(t, "."): append(&patterns, strings.concatenate({"*", t}, context.temp_allocator))
		case t == "image/*": append(&patterns, "*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.svg;*.ico;*.avif")
		case t == "audio/*": append(&patterns, "*.mp3;*.wav;*.ogg;*.flac;*.m4a;*.opus")
		case t == "video/*": append(&patterns, "*.mp4;*.webm;*.mkv;*.mov;*.avi")
		case t == "text/*": append(&patterns, "*.txt;*.csv;*.html;*.htm;*.css;*.md")
		case t == "application/pdf": append(&patterns, "*.pdf")
		case t == "application/json": append(&patterns, "*.json")
		case t == "text/csv": append(&patterns, "*.csv")
		case t == "text/plain": append(&patterns, "*.txt")
		case t == "image/png": append(&patterns, "*.png")
		case t == "image/jpeg": append(&patterns, "*.jpg;*.jpeg")
		}
	}
	sb := strings.builder_make()
	if len(patterns) > 0 {
		joined := strings.join(patterns[:], ";", context.temp_allocator)
		strings.write_string(&sb, "Accepted files (")
		strings.write_string(&sb, joined)
		strings.write_string(&sb, ")\x00")
		strings.write_string(&sb, joined)
		strings.write_byte(&sb, 0)
	}
	strings.write_string(&sb, "All files (*.*)\x00*.*\x00\x00")
	return strings.to_string(sb)
}

// MIME type of a file from the system's registry (HKCR\.ext "Content Type"), else the browser's table.
@(private = "file")
mime_of_path :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := strings.last_index_any(path, "\\/")
	if dot > slash && dot >= 0 {
		ext := win.utf8_to_wstring(path[dot:], context.temp_allocator)
		buf: [128]u16
		size := u32(size_of(buf))
		if win.RegGetValueW(win.HKEY_CLASSES_ROOT, ext, win.L("Content Type"), win.RRF_RT_REG_SZ, nil, &buf, &size) == 0 {
			n := 0
			for n < len(buf) && buf[n] != 0 { n += 1 }
			if s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator); err == nil && s != "" { return strings.clone(s) }
		}
	}
	return strings.clone(fetch.mime_for_extension(path))
}

@(private = "file")
picker_work :: proc(data: rawptr) {
	job := (^Picker_Job)(data)
	_ = win.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer win.CoUninitialize()
	if job.color {
		custom: [16]win.COLORREF
		cc := win.CHOOSECOLORW{lStructSize = size_of(win.CHOOSECOLORW), hwndOwner = job.owner, rgbResult = win.COLORREF(job.initial), lpCustColors = &custom[0], Flags = win.CC_RGBINIT | win.CC_FULLOPEN}
		if win.ChooseColorW(&cc) { job.ok = true; job.result = u32(cc.rgbResult) }
		return
	}
	BUF :: 1 << 16
	buf := make([]u16, BUF)
	defer delete(buf)
	filter := win.utf8_to_wstring(job.filter, context.temp_allocator)
	flags := u32(win.OFN_PATHMUSTEXIST | win.OFN_FILEMUSTEXIST | win.OFN_EXPLORER | win.OFN_NOCHANGEDIR | win.OFN_HIDEREADONLY)
	if job.multiple { flags |= win.OFN_ALLOWMULTISELECT }
	ofn := win.OPENFILENAMEW{lStructSize = size_of(win.OPENFILENAMEW), hwndOwner = job.owner, lpstrFilter = filter, lpstrFile = &buf[0], nMaxFile = BUF, Flags = flags}
	if !win.GetOpenFileNameW(&ofn) { return }
	job.ok = true
	// "dir\0name\0name\0\0" (several) or "full path\0" (one)
	parts := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..< BUF {
		if buf[i] != 0 { continue }
		if i == start { break }
		s, _ := win.utf16_to_utf8(buf[start:i], context.temp_allocator)
		append(&parts, s)
		start = i + 1
	}
	paths := make([dynamic]string, context.temp_allocator)
	if len(parts) == 1 { append(&paths, parts[0]) } else if len(parts) > 1 {
		for name in parts[1:] { append(&paths, strings.concatenate({parts[0], "\\", name}, context.temp_allocator)) }
	}
	for path in paths {
		if len(job.files) >= job.max_files { break }
		info, err := os.stat(path, context.temp_allocator)
		if err != nil { continue }
		slash := strings.last_index_any(path, "\\/")
		append(&job.files, forms.File{
			path = strings.clone(path), name = strings.clone(path[slash + 1:]), mime = mime_of_path(path), size = info.size,
			modified_ms = f64(time.to_unix_nanoseconds(info.modification_time)) / 1e6,
		})
	}
	free_all(context.temp_allocator)
}

@(private = "file")
picker_done :: proc(data: rawptr) {
	job := (^Picker_Job)(data)
	defer {
		for &fl in job.files { forms.file_destroy(&fl) }
		delete(job.files)
		delete(job.filter)
		free(job)
	}
	if job.cancelled { return }
	p := job.page
	base.forget_cleanup(p.scope, job.cleanup)
	if dom.get(p.doc, job.input) == nil || !job.ok {
		if !job.ok && !job.color { page.dispatch_event(p, job.input, dom.Event{type = "cancel", bubbles = true}) }
		return
	}
	f := page.page_forms(p)
	if job.color {
		r, g, b := job.result & 0xff, (job.result >> 8) & 0xff, (job.result >> 16) & 0xff
		HEX := "0123456789abcdef"
		v := string([]u8{'#', HEX[r >> 4], HEX[r & 15], HEX[g >> 4], HEX[g & 15], HEX[b >> 4], HEX[b & 15]})
		if v != forms.value(f, job.input) {
			forms.set_value(f, job.input, v, by_user = true)
			page.dispatch_event(p, job.input, dom.Event{type = "input", bubbles = true})
			page.dispatch_event(p, job.input, dom.Event{type = "change", bubbles = true})
		}
	} else {
		list := job.files[:]
		job.files = nil   // set_files owns them now
		forms.set_files(f, job.input, list)
		delete(list)
	}
	job.app.frames_requested = max(job.app.frames_requested, 3)
}

_ :: runtime

@(private = "file")
itoa :: proc(n: int) -> string { buf: [24]u8; return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator) }
// Controls whose whole look is drawn by paint_control: the layout painter draws no background or border for them.
forms_bare_control :: proc(user: rawptr, doc: ^dom.Document, node: base.Handle) -> bool {
	n := dom.get(doc, node)
	if n == nil || n.kind != .Element || n.name != "input" { return false }
	t, _ := dom.get_attribute(doc, node, "type")
	return strings.equal_fold(t, "checkbox") || strings.equal_fold(t, "radio") || strings.equal_fold(t, "range")
}
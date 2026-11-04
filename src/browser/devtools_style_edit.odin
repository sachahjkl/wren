package browser

// What the Styles pane edits a value with, beside its fields (devtools_styles.odin): the colours in a value (a swatch before
// each, a click opens the toolkit's colour picker on it: the page follows each change, the colour keeps the format it was
// written in, Escape takes the value back, Enter or a click elsewhere keeps it), and the suggestions of a field being edited
// (property names; the keywords the engine takes for the property). The numbers of a value step from the keyboard and the
// wheel in the field (the toolkit's field_num_step).

import "core:fmt"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:css"
import "wb:page"
import "wb:style"

// The functions whose value is a colour (a swatch before them).
STY_COLOR_FUNCTIONS :: [?]string{"rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color", "color-mix", "light-dark"}
// The swatch before a colour: its size, of the value's text, and the room after it (logical px).
STY_SWATCH_EM :: 0.85
STY_SWATCH_GAP :: 5
// The picker's popover: its padding (logical px).
STY_PICK_PAD :: 8
// Suggestions: at most this many are listed, in a list this wide (logical px).
STY_SUGGEST_MAX :: 12
STY_SUGGEST_W :: 220
// The keywords a value is suggested from (each kept when the engine takes it for the property), with the named colours and
// the CSS-wide keywords.
STY_KEYWORDS :: [?]string{
	"auto", "none", "normal", "block", "inline", "inline-block", "flex", "inline-flex", "grid", "inline-grid", "contents", "flow-root",
	"table", "table-row", "table-cell", "list-item", "hidden", "visible", "scroll", "clip", "static", "relative", "absolute", "fixed",
	"sticky", "left", "right", "center", "top", "bottom", "start", "end", "justify", "baseline", "stretch", "space-between",
	"space-around", "space-evenly", "flex-start", "flex-end", "row", "row-reverse", "column", "column-reverse", "wrap", "nowrap",
	"wrap-reverse", "solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset", "bold", "bolder", "lighter",
	"italic", "oblique", "uppercase", "lowercase", "capitalize", "underline", "overline", "line-through", "pre", "pre-wrap",
	"pre-line", "break-spaces", "content-box", "border-box", "padding-box", "pointer", "default", "text", "move", "grab",
	"not-allowed", "wait", "help", "crosshair", "cover", "contain", "fill", "repeat", "no-repeat", "repeat-x", "repeat-y", "round",
	"space", "transparent", "currentcolor", "ellipsis", "break-word", "anywhere", "middle", "sub", "super", "text-top", "text-bottom",
	"both", "ltr", "rtl", "horizontal-tb", "vertical-rl", "vertical-lr", "min-content", "max-content", "fit-content", "dense", "ease",
	"ease-in", "ease-out", "ease-in-out", "linear", "step-start", "step-end", "infinite", "alternate", "forwards", "backwards",
	"running", "paused", "serif", "sans-serif", "monospace", "cursive", "system-ui", "collapse", "separate", "smooth", "thin",
	"medium", "thick", "small", "large", "larger", "smaller", "x-small", "x-large", "xx-small", "xx-large", "inherit", "initial",
	"unset", "revert", "revert-layer",
}

// A colour in a value: its bytes, the colour, how it is written (the picker writes it back so).
Sty_Color :: struct { lo, hi: int, c: ui.Srgba, style: ui.Color_Style }

// The colours of a value, in order (temporary allocator): hex colours, colour functions and the names the engine knows.
sty_colors :: proc(value: string) -> []Sty_Color {
	out := make([dynamic]Sty_Color, context.temp_allocator)
	word :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' }
	i := 0
	for i < len(value) {
		c := value[i]
		switch {
		case c == '"' || c == '\'':   // a string holds no colour
			end := strings.index_byte(value[i + 1:], c)
			i = end < 0 ? len(value) : i + end + 2
		case c == '#':
			j := i + 1
			for j < len(value) && word(value[j]) { j += 1 }
			sty_color_add(&out, value, i, j)
			i = j
		case word(c) && (i == 0 || !word(value[i - 1])):
			j := i
			for j < len(value) && word(value[j]) { j += 1 }
			name := base.ascii_lower(value[i:j])
			if j < len(value) && value[j] == '(' {
				// a function: a colour when it is one of them (its closing parenthesis, nested ones skipped), else past its name
				end := sty_close_paren(value, j)
				is_color := false
				for f in STY_COLOR_FUNCTIONS { if f == name { is_color = true } }
				if is_color && end > j { sty_color_add(&out, value, i, end); i = end; continue }
				if name == "url" && end > j { i = end; continue }
				i = j + 1
				continue
			}
			sty_color_add(&out, value, i, j)
			i = j
		case:
			i += 1
		}
	}
	return out[:]
}

// The end (past its ')') of the parenthesis opened at `open`; `open` itself when it is not closed.
@(private = "file")
sty_close_paren :: proc(s: string, open: int) -> int {
	depth := 0
	for k in open ..< len(s) {
		switch s[k] {
		case '(': depth += 1
		case ')':
			depth -= 1
			if depth == 0 { return k + 1 }
		}
	}
	return open
}

// value[lo:hi] when the engine reads it as a colour (currentcolor and system colours are not one to pick).
@(private = "file")
sty_color_add :: proc(out: ^[dynamic]Sty_Color, value: string, lo, hi: int) {
	text := value[lo:hi]
	vs := css.parse_component_values(text, {max_nesting_depth = 32, max_rules = 1}, context.temp_allocator)
	cv, ok := css.parse_color(vs, nil)
	if !ok || cv.kind != .Rgba { return }
	_, st, known := ui.color_parse(text)
	if !known { st = {.Hex, false} }   // (a name, hwb(), lab()...: written back as hex, as Chrome does)
	append(out, Sty_Color{lo, hi, cv.rgba, st})
}

// The colour a value is, when all of it is one (the Computed view's swatch).
swatch_of :: proc(v: string) -> (draw.Color, bool) {
	s := strings.trim_space(v)
	cs := sty_colors(s)
	if len(cs) != 1 || cs[0].lo != 0 || cs[0].hi != len(s) { return {}, false }
	c := cs[0].c
	return draw.srgb(c.r, c.g, c.b, c.a), true
}

sty_swatch_w :: proc() -> f32 { return the_app.dtm.mono_fs * STY_SWATCH_EM }

// A swatch at `x` (its left), on the line through `cy`.
sty_swatch_draw :: proc(dc: ^draw.Context, x, cy: f32, c: ui.Srgba) {
	sw := sty_swatch_w()
	r := draw.Rect{{x, cy - sw * 0.5}, {x + sw, cy + sw * 0.5}}
	ui.checker_draw(dc, r, sw)
	draw.rect(dc, r, draw.srgb(c.r, c.g, c.b, c.a), dt_px(2))
	draw.rect(dc, r, with_alpha(the_app.dtc.text, 0.4), dt_px(2), the_app.dtm.line)
}

// Where the swatch of colour `ci` of a value is, from the value's left edge.
sty_swatch_x :: proc(value: string, ci: int) -> f32 {
	at: f32
	from := 0
	for c, i in sty_colors(value) {
		at += dt_w(the_app.dtm.mono, the_app.dtm.mono_fs, value[from:c.lo])
		if i == ci { break }
		at += sty_swatch_w() + dt_px(STY_SWATCH_GAP)
		from = c.lo
	}
	return at
}

// The colour of a declaration's value whose swatch is at `x` (from the value's left edge): -1 for none.
sty_swatch_at :: proc(value: string, x: f32) -> int {
	sw := sty_swatch_w()
	at: f32
	from := 0
	for c, i in sty_colors(value) {
		at += dt_w(the_app.dtm.mono, the_app.dtm.mono_fs, value[from:c.lo])
		if x >= at && x < at + sw { return i }
		at += sw + dt_px(STY_SWATCH_GAP)
		from = c.lo
	}
	return -1
}

////////////////////////////////
// The colour picker

// The picker opens on colour `ci` of declaration `di` of block `bi`, under `anchor` (the swatch, window px).
styles_pick_open :: proc(s: ^Dev_Styles, bi, di, ci: int, anchor: draw.Rect) {
	cs := sty_colors(s.blocks[bi].decls[di].value)
	if ci < 0 || ci >= len(cs) { return }
	c := cs[ci]
	ui.color_pick_set(&s.pick, c.c, c.style)
	delete(s.pick_was)
	s.pick_was = strings.clone(s.blocks[bi].decls[di].value)
	s.pick_on, s.pick_b, s.pick_d, s.pick_lo, s.pick_hi, s.pick_at = true, bi, di, c.lo, c.hi, anchor
}

// The picker's popover while it is open: each change writes the colour into the value, and the page follows; Escape takes the
// value back, Enter or a press outside keeps it.
styles_pick_popover :: proc(app: ^App, t: ^Tab, s: ^Dev_Styles) {
	if !s.pick_on { return }
	if s.pick_b >= len(s.blocks) || s.pick_d >= len(s.blocks[s.pick_b].decls) { s.pick_on = false; return }
	d := &s.blocks[s.pick_b].decls[s.pick_d]
	// (before the picker's own field takes them)
	if ui.key_press(.Escape) {
		delete(d.value)
		d.value = strings.clone(s.pick_was)
		apply_block(app, t, s, s.pick_b)
		s.pick_on = false
		return
	}
	if ui.key_press(.Return) { s.pick_on = false; s.rev += 1; return }
	if r, ok := ui.popover_rect("###dt_sty_pick"); ok && ui.mouse_pressed() && !draw.rect_contains(r, ui.mouse_pos()) && !draw.rect_contains(s.pick_at, ui.mouse_pos()) {
		s.pick_on = false
		s.rev += 1
		return
	}
	pad := dt_px(STY_PICK_PAD)
	if ui.popover("###dt_sty_pick", s.pick_at, ui.color_picker_width() + 2 * pad, .Below, align_right = false) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(pad))
			if ui.color_picker("###dt_sty_picker", &s.pick) {
				text := ui.color_pick_text(&s.pick)
				v := strings.concatenate({d.value[:s.pick_lo], text, d.value[s.pick_hi:]})
				delete(d.value)
				d.value = v
				s.pick_hi = s.pick_lo + len(text)
				apply_block(app, t, s, s.pick_b)
			}
		}
		ui.spacer(ui.px(pad))
	}
}

////////////////////////////////
// Suggestions

// What a field being edited is suggested: property names that start with its text (then those that hold it), or the
// keywords the engine takes for the property that start with the word at the caret. `word`: [lo, hi) of what a choice replaces.
styles_suggestions :: proc(t: ^Tab, s: ^Dev_Styles, value: bool) -> (out: []string, lo, hi: int) {
	f := value ? &s.field_v : &s.field_n
	text := ui.field_string(f)
	hi = f.cursor
	lo = hi
	for lo > 0 && (sty_word(text[lo - 1])) { lo -= 1 }
	if !value { lo, hi = 0, len(text) }
	q := base.ascii_lower(text[lo:hi])
	if q == "" || (q[0] >= '0' && q[0] <= '9') || (q[0] == '-' && value) { return }
	list := make([dynamic]string, context.temp_allocator)
	if value {
		prop := base.ascii_lower(strings.trim_space(ui.field_string(&s.field_n)))
		styles_keywords(t, s, prop)
		for k in s.kw { if strings.has_prefix(k, q) && k != q { append(&list, k) } }
	} else {
		names := style.dev_property_names()
		for n in names { if strings.has_prefix(n, q) && n != q { append(&list, n) } }
		for n in names { if !strings.has_prefix(n, q) && strings.contains(n, q) { append(&list, n) } }
	}
	if len(list) > STY_SUGGEST_MAX { resize(&list, STY_SUGGEST_MAX) }
	return list[:], lo, hi
}

@(private = "file")
sty_word :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' }

// The keywords the engine takes for `prop` (made again for another property).
@(private = "file")
styles_keywords :: proc(t: ^Tab, s: ^Dev_Styles, prop: string) {
	if prop == s.kw_prop { return }
	delete(s.kw_prop)
	s.kw_prop = strings.clone(prop)
	clear(&s.kw)
	if t.page == nil { return }
	for k in STY_KEYWORDS { if page.dev_supports(t.page, prop, k) { append(&s.kw, k) } }
	for n in css.NAMED_COLORS { if page.dev_supports(t.page, prop, n.name) { append(&s.kw, n.name) } }
}

// The list under a field being edited (`box`, its line_edit's): Up / Down choose, Enter or Tab take the choice (the caller
// asks `styles_suggest_take`), Escape closes it; the one a click takes (-1: none).
styles_suggest_list :: proc(s: ^Dev_Styles, items: []string, box: ^ui.Box) -> (clicked: int) {
	clicked = -1
	if len(items) == 0 || box == nil || !s.sug_on { return }
	s.sug_sel = clamp(s.sug_sel, 0, len(items) - 1)
	if ui.popover("###dt_sty_sug", box.rect, dt_px(STY_SUGGEST_W), .Below, align_right = false) {
		for it, i in items {
			ui.next({width = ui.fill(), height = ui.px(the_app.dtm.row), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, fmt.tprintf("###sg%d", i))
			sig := ui.signal(rb)
			Sug_Draw :: struct { text: string, on: bool }
			sd := ui.frame_new(Sug_Draw)
			sd.text, sd.on = it, i == s.sug_sel || sig.hovering
			rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Sug_Draw)(user)
				if d.on { draw.rect(dc, b.rect, the_app.dtc.accent_bg) }
				dt_text(dc, the_app.dtm.mono, the_app.dtm.mono_fs, b.rect.min.x + dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, the_app.dtc.text, d.text)
			}, sd
			ui.a11y_set(rb, {role = .List_Box_Option, name = it, selected = i == s.sug_sel})
			if sig.clicked { clicked = i }
		}
	}
	return
}

// The suggestion `it` in place of [lo, hi) of the field.
styles_suggest_take :: proc(f: ^ui.Text_Field, it: string, lo, hi: int) {
	text := ui.field_string(f)
	v := strings.concatenate({text[:lo], it, text[hi:]}, context.temp_allocator)
	ui.field_set(f, v)
	f.cursor, f.mark = lo + len(it), lo + len(it)
}

package e2e_scenarios

// The developer tools as one works in them, driven by the harness's typed input: Ctrl+F in the Elements panel finds a text,
// a CSS selector and an XPath, Enter / F3 / Shift+F3 move through the matches, the matches follow the document, Escape
// closes the search; Escape elsewhere shows the Console under the panel and hides it again (the drawer); the close button is
// the last control of the top strip; a colour edited through the picker changes the page and its rule keeps the colour's
// format (Escape takes it back); Up, Shift+Up, Alt+Up and Ctrl+Up step a length and the layout follows; a name and a keyword are
// taken from the suggestions.

import "core:fmt"
import "core:strings"
import "core:testing"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:browser"
import "wb:e2e"
import "wb:page"

@(private = "file") EDIT_SIZE :: [2]int{1280, 800}
@(private = "file") EDIT_PAGE :: `<!doctype html><meta charset=utf-8><title>edit</title>
<style>body { margin: 0 } #t { color: rgb(255, 0, 0); background-color: #336699; margin-left: 10px }</style>
<body><div id=a class=card><span>one</span><span>two</span></div><div class=card><p>Sale now</p></div><div id=t>target</div>`
// Where a click goes in a row: this far into its first cell (px).
@(private = "file") INTO_ROW :: 40
// A click on a value: this far past its start (px), on its text.
@(private = "file") INTO_VALUE :: 3
// The block of the #t rule in the Styles list (after element.style), its declarations, and the kind of a declaration's row.
@(private = "file") RULE_BLOCK :: 1
@(private = "file") DECL_COLOR :: 0
@(private = "file") DECL_BACKGROUND :: 1
@(private = "file") DECL_MARGIN :: 2
@(private = "file") ROW_DECL :: 2
@(private = "file") LEFT_NEAR :: 0.01

@(private = "file")
devtools_of :: proc(s: ^e2e.Session) -> ^browser.Devtools { return &browser.active_window(s.app).own.devtools }

// The boxes of the window's last build named `name` (the part of their id after ###), in tree order.
@(private = "file")
boxes_named :: proc(s: ^e2e.Session, name: string, under: ^ui.Box = nil) -> []^ui.Box {
	wnd := browser.active_window(s.app)
	ui.use(wnd.ui)
	out := make([dynamic]^ui.Box, context.temp_allocator)
	walk :: proc(b: ^ui.Box, name: string, out: ^[dynamic]^ui.Box) {
		for c := b.first; c != nil; c = c.next {
			if c.name == name && c.rect.max.x > c.rect.min.x { append(out, c) }
			walk(c, name, out)
		}
	}
	walk(under != nil ? under : wnd.ui.root, name, &out)
	return out[:]
}

@(private = "file")
box_named :: proc(s: ^e2e.Session, name: string, under: ^ui.Box = nil, loc := #caller_location) -> ^ui.Box {
	e2e.wait_until(s, name, proc(s: ^e2e.Session, name: string) -> bool { return len(boxes_named(s, name)) > 0 }, fmt.tprintf("a box named %q", name), loc = loc)
	bs := boxes_named(s, name, under)
	testing.expectf(s.t, len(bs) > 0, "a box named %q", name, loc = loc)
	return len(bs) > 0 ? bs[0] : nil
}

@(private = "file")
mid :: proc(r: draw.Rect) -> e2e.Point { return {f64(r.min.x + r.max.x) * 0.5, f64(r.min.y + r.max.y) * 0.5} }

@(private = "file")
handle_of :: proc(s: ^e2e.Session, selector: string) -> base.Handle {
	context = s.ctx   // (the page keeps what it parses: in the browser's memory)
	t := browser.current_tab(s.app)
	hs, _ := page.select_all(t.page, selector)
	return len(hs) > 0 ? hs[0] : base.NIL_HANDLE
}

@(private = "file")
start_elements :: proc(t: ^testing.T, loc := #caller_location) -> ^e2e.Session {
	url := e2e.file_page(e2e.temp_folder(t), "edit.html", EDIT_PAGE)
	s := e2e.start(t, {size = EDIT_SIZE, dpi = e2e.DPI_ONE, url = url,
		prefs = {"browser.devtools.visible=true", "browser.devtools.tab=elements", "browser.devtools.dock=bottom"}}, loc)
	e2e.wait_chrome_still(s)
	// the keyboard in the tree: a click on its first row
	list := box_named(s, "dt_el_list")
	e2e.click_at(s, {f64(list.rect.min.x) + INTO_ROW, f64(list.rect.min.y) + f64(s.app.dtm.row) * 0.5}, .Window)
	e2e.wait_frames(s)
	return s
}

// Ctrl+F, the query typed over what the field had.
@(private = "file")
find :: proc(s: ^e2e.Session, query: string) {
	e2e.key(s, "ctrl+f")
	e2e.key(s, "ctrl+a")
	e2e.type_text(s, query)
	e2e.wait_frames(s)
}

@(test)
devtools_elements_find_by_text_selector_and_xpath :: proc(t: ^testing.T) {
	s := start_elements(t)
	els := &devtools_of(s).els

	find(s, ".card")
	testing.expect(t, els.search_on, "Ctrl+F opens the search")
	testing.expect_value(t, len(els.found), 2)
	testing.expect_value(t, els.selected, handle_of(s, "#a"))   // the first match is chosen
	status := box_named(s, "dt_el_scount")
	testing.expect(t, status != nil && status.a11y != nil && status.a11y.name == "1 of 2", "it says 1 of 2")
	e2e.key(s, "enter")
	testing.expect_value(t, els.selected, handle_of(s, "div.card:nth-of-type(2)"))
	e2e.key(s, "f3")
	testing.expect_value(t, els.selected, handle_of(s, "#a"))   // round again
	e2e.key(s, "shift+f3")
	testing.expect_value(t, els.found_at, 1)
	e2e.key(s, "shift+enter")
	testing.expect_value(t, els.found_at, 0)

	// the matches follow the document
	e2e.eval(s, "document.body.append(Object.assign(document.createElement('div'), {className: 'card'})); 1")
	e2e.wait_frames(s, 3)
	testing.expect_value(t, len(els.found), 3)
	testing.expect_value(t, els.found_at, 0)   // the current one stays

	find(s, "sale")   // a text, any case: its element's row
	testing.expect_value(t, len(els.found), 1)
	testing.expect_value(t, els.selected, handle_of(s, "p"))

	find(s, "//span[2]")   // an XPath
	testing.expect_value(t, len(els.found), 1)
	testing.expect_value(t, els.selected, handle_of(s, "#a > span:nth-of-type(2)"))

	e2e.key(s, "escape")
	testing.expect(t, !els.search_on && len(els.found) == 0, "Escape closes the search")
}

@(test)
devtools_escape_toggles_the_console_drawer :: proc(t: ^testing.T) {
	s := start_elements(t)
	d := devtools_of(s)
	testing.expect(t, !browser.dev_shows(d, .Console), "the Console is behind Elements")

	e2e.key(s, "escape")
	e2e.wait_frames(s)
	testing.expect(t, browser.dev_shows(d, .Console) && browser.dev_shows(d, .Elements), "Escape: the Console under Elements")
	layout := e2e.pref_get(s, "browser.devtools.layout")
	testing.expectf(t, strings.contains(layout, "[*console]") && strings.has_prefix(layout, "dock1 y"), "a stack of its own below: %s", layout)

	e2e.key(s, "escape")
	e2e.wait_frames(s)
	testing.expect(t, !browser.dev_shows(d, .Console) && browser.dev_shows(d, .Elements), "Escape again: hidden")
	testing.expectf(t, strings.contains(e2e.pref_get(s, "browser.devtools.layout"), "f("), "folded: %s", e2e.pref_get(s, "browser.devtools.layout"))

	e2e.key(s, "escape")
	e2e.wait_frames(s)
	testing.expect(t, browser.dev_shows(d, .Console), "and back")

	// the close button is the top strip's last control: right of the stacks' own buttons on its line
	close := box_named(s, "dt_close")
	if close == nil { return }
	for name in ([?]string{"dock_menu_btn", "dock_fold", "dt_settings"}) {   // (the dock-side button is between these; its id is the dock's too)
		for b in boxes_named(s, name) {
			if b.rect.max.y <= close.rect.min.y || b.rect.min.y >= close.rect.max.y { continue }   // (another strip)
			testing.expectf(t, b.rect.max.x <= close.rect.min.x, "%s (%v) is left of the close button (%v)", name, b.rect, close.rect)
		}
	}
}

// The row of declaration `decl` of the #t rule, and where its value begins in it (window px).
@(private = "file")
decl_row :: proc(s: ^e2e.Session, decl: int, loc := #caller_location) -> (row: draw.Rect, value_x: f32, value: string) {
	sty := &devtools_of(s).els.side
	b := box_named(s, fmt.tprintf("sr%d_%d_%d", RULE_BLOCK, decl, ROW_DECL), loc = loc)
	if b == nil || RULE_BLOCK >= len(sty.blocks) || decl >= len(sty.blocks[RULE_BLOCK].decls) { return }
	dc := sty.blocks[RULE_BLOCK].decls[decl]
	app := s.app
	value_x = b.rect.min.x + browser.dt_px(browser.STY_DECL_X + browser.STY_SWITCH_W) + browser.dt_w(app.dtm.mono, app.dtm.mono_fs, dc.name) + browser.dt_w(app.dtm.mono, app.dtm.mono_fs, ": ")
	return b.rect, value_x, strings.clone(dc.value, context.temp_allocator)   // (the pane's string goes with its next build)
}

@(private = "file")
computed :: proc(s: ^e2e.Session, prop: string) -> string {
	for p in e2e.computed_style(s, "#t", {prop}) { if p.name == prop { return p.value } }
	return ""
}

// The #t element chosen (found with Ctrl+F, by a selector the style sheet's text does not hold; Escape closes the search, the
// choice stays).
@(private = "file")
choose_target :: proc(s: ^e2e.Session) {
	find(s, "div#t")
	e2e.key(s, "escape")
	e2e.wait_frames(s, 3)
}

@(test)
devtools_colour_picker_keeps_the_format :: proc(t: ^testing.T) {
	s := start_elements(t)
	choose_target(s)
	sty := &devtools_of(s).els.side

	// rgb() in the comma syntax: a press in the picker's square writes another colour so; the page follows
	row, vx, value := decl_row(s, DECL_COLOR)
	testing.expect_value(t, value, "rgb(255, 0, 0)")
	e2e.click_at(s, {f64(vx + browser.sty_swatch_x(value, 0) + browser.sty_swatch_w() * 0.5), f64(mid(row).y)}, .Window)
	e2e.wait_frames(s)
	testing.expect(t, sty.pick_on, "the swatch opens the picker")
	square := box_named(s, "square", box_named(s, "dt_sty_picker"))
	if square == nil { return }
	e2e.click_at(s, {f64(square.rect.min.x) + f64(square.rect.max.x - square.rect.min.x) * 0.3, mid(square.rect).y}, .Window)
	e2e.wait_frames(s, 3)
	_, _, value = decl_row(s, DECL_COLOR)
	testing.expectf(t, strings.has_prefix(value, "rgb(") && strings.count(value, ", ") == 2 && value != "rgb(255, 0, 0)", "still rgb(r, g, b): %s", value)
	testing.expect_value(t, computed(s, "color"), value)

	// Escape: the colour it had
	e2e.key(s, "escape")
	e2e.wait_frames(s, 3)
	_, _, value = decl_row(s, DECL_COLOR)
	testing.expect_value(t, value, "rgb(255, 0, 0)")
	testing.expect_value(t, computed(s, "color"), "rgb(255, 0, 0)")
	testing.expect(t, !sty.pick_on, "and closes")

	// hex stays hex
	row, vx, value = decl_row(s, DECL_BACKGROUND)
	e2e.click_at(s, {f64(vx + browser.sty_swatch_x(value, 0) + browser.sty_swatch_w() * 0.5), f64(mid(row).y)}, .Window)
	e2e.wait_frames(s)
	square = box_named(s, "square", box_named(s, "dt_sty_picker"))
	if square == nil { return }
	e2e.click_at(s, mid(square.rect), .Window)
	e2e.wait_frames(s, 3)
	_, _, value = decl_row(s, DECL_BACKGROUND)
	c, style, ok := ui.color_parse(value)
	testing.expectf(t, ok && style.format == .Hex && len(value) == len("#rrggbb") && value != "#336699", "still hex: %s", value)
	want := fmt.tprintf("rgb(%d, %d, %d)", int(c.r * 255 + 0.5), int(c.g * 255 + 0.5), int(c.b * 255 + 0.5))
	testing.expect_value(t, computed(s, "background-color"), want)
	e2e.key(s, "enter")   // kept
	e2e.wait_frames(s)
	testing.expect(t, !sty.pick_on, "Enter closes the picker")
	_, _, kept := decl_row(s, DECL_BACKGROUND)
	testing.expect_value(t, kept, value)
}

@(test)
devtools_style_numbers_step_by_the_keyboard :: proc(t: ^testing.T) {
	s := start_elements(t)
	choose_target(s)
	sty := &devtools_of(s).els.side
	left :: proc(s: ^e2e.Session) -> f64 { return e2e.eval_f64(s, "document.getElementById('t').getBoundingClientRect().left") }

	row, vx, value := decl_row(s, DECL_MARGIN)
	testing.expect_value(t, value, "10px")
	e2e.click_at(s, {f64(vx) + INTO_VALUE, f64(mid(row).y)}, .Window)
	e2e.wait_frames(s)
	testing.expect(t, sty.editing && sty.edit_part == 1, "a click on the value edits it")
	Step :: struct { keys, want: string, left: f64 }
	steps := [?]Step{{"up", "11px", 11}, {"down", "10px", 10}, {"shift+up", "20px", 20}, {"shift+down", "10px", 10}, {"alt+up", "10.1px", 10.1}, {"ctrl+up", "110.1px", 110.1}}
	for st in steps {
		e2e.key(s, st.keys)
		e2e.wait_frames(s, 3)
		testing.expect_value(t, ui.line_edit_string(&sty.field_v), st.want)
		testing.expectf(t, abs(left(s) - st.left) < LEFT_NEAR, "%s: the element is %v px from the left (want %v)", st.keys, left(s), st.left)
	}
	// Escape: as it was
	e2e.key(s, "escape")
	e2e.wait_frames(s, 3)
	_, _, value = decl_row(s, DECL_MARGIN)
	testing.expect_value(t, value, "10px")
	testing.expectf(t, abs(left(s) - 10) < LEFT_NEAR, "back at 10 px: %v", left(s))

	// suggestions: a name, then a keyword the engine takes for it, each taken by Tab or Enter
	row, vx, value = decl_row(s, DECL_MARGIN)
	e2e.click_at(s, {f64(row.min.x + browser.dt_px(browser.STY_DECL_X + browser.STY_SWITCH_W)) + INTO_VALUE, f64(mid(row).y)}, .Window)
	e2e.wait_frames(s)
	e2e.key(s, "ctrl+a")
	e2e.type_text(s, "disp")
	e2e.key(s, "tab")
	testing.expect_value(t, ui.line_edit_string(&sty.field_n), "display")
	e2e.type_text(s, "fl")
	e2e.key(s, "enter")
	e2e.wait_frames(s, 3)
	testing.expect_value(t, computed(s, "display"), "flex")
}



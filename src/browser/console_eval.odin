package browser

// The console's "run JavaScript" line: under the console strip of the tab (View > Console), a field whose text runs
// in the page's realm when Enter is pressed (page.js_console_eval, preference javascript.console_eval); the result is
// shown in the console like any message. Up / Down walk the lines run before (cfg.console_max_lines of them).

import "core:strings"
import "wb:page"
import ui "toolkit:ui"

@(private = "file")
Console_Js :: struct {
	field:   ui.Text_Field,
	history: [dynamic]string,
	cursor:  int,   // position in history while walking it (len = the line being typed)
}

@(private = "file")
console_js: Console_Js

// The input row of the console (built when the console is shown and the tab has a page).
console_eval_row :: proc(app: ^App, t: ^Tab, em: f32) {
	if t == nil || t.page == nil || !app.page_settings.js.console_eval { return }
	c := &console_js
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9))})
	res := ui.line_edit("###console_js", &c.field, "Run JavaScript in this page (Enter)")
	if res.focused {
		forms_page_blur()
		if ui.key_press(.Up) && c.cursor > 0 {
			c.cursor -= 1
			ui.field_set(&c.field, c.history[c.cursor])
		} else if ui.key_press(.Down) && c.cursor < len(c.history) {
			c.cursor += 1
			ui.field_set(&c.field, c.cursor < len(c.history) ? c.history[c.cursor] : "")
		}
	}
	if res.committed {
		source := strings.clone(strings.trim_space(ui.field_string(&c.field)), context.temp_allocator)
		if source != "" {
			tab_log(t, .Log, strings.concatenate({"> ", source}, context.temp_allocator))
			if len(c.history) == 0 || c.history[len(c.history) - 1] != source { append(&c.history, strings.clone(source)) }
			for len(c.history) > max(app.cfg.console_max_lines, 1) { delete(c.history[0]); ordered_remove(&c.history, 0) }
			c.cursor = len(c.history)
			ui.field_clear(&c.field)
			page.js_console_eval(t.page, source)
			app.frames_requested = max(app.frames_requested, 3)
		}
	}
	if res.cancelled { ui.field_clear(&c.field); c.cursor = len(c.history) }
}

// Window closing.
console_eval_destroy :: proc() {
	c := &console_js
	ui.field_destroy(&c.field)
	for h in c.history { delete(h) }
	delete(c.history)
	c^ = {}
}

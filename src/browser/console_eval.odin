package browser

// The console's "run JavaScript" line: at the bottom of the developer tools' Console tab (devtools_console.odin), a
// field whose text runs in the page's realm when Enter is pressed (page.js_console_eval, preference
// javascript.console_eval); the result is shown in the console like any message. Up / Down walk the lines run before
// (cfg.console_max_lines of them). While typing, a list of completions (names of the page's globals and members of the
// common objects, and words of the history) opens above the field: Up / Down choose, Tab or Right accept, Escape closes.

import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:page"

Con_Eval :: struct {
	field:   ui.Text_Field,
	history: [dynamic]string,
	cursor:  int,                   // position in history while walking it (len = the line being typed)
	draft:   string,                // owned: what was being typed when the walk began
	items:   [dynamic]string,       // owned: the completions of the word at the caret
	sel:     int,
	open:    bool,
	word:    string,                // owned: the word the completions are for
	shown_for: string,              // owned: the field's text the list was made for
	dismissed: string,              // owned: the text the user closed the list at (it does not reopen until it changes)
	dyn:       [dynamic]string,     // owned: the names the page's realm offered for the last expression
	tab:       ^Tab,
}

// The input row of the console (built when the console is shown and the tab has a page).
console_eval_row :: proc(app: ^App, t: ^Tab, row_h: f32) {
	if t == nil || t.page == nil || !app.page_settings.js.console_eval { return }
	c := &dev.con.eval
	c.tab = t
	h := math.round(row_h * 1.25)
	focused := false
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center, bg = dtc.bar, border = dtc.border})
	box := ui.build_box({.Draw_Background, .Draw_Side_Top}, "###dt_eval")
	var_res: ui.Edit_Result
	if ui.parent(box) {
		// the prompt
		ui.next({width = ui.px(dt_px(24)), height = ui.pct(1)})
		ui.custom("###dt_eval_prompt", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_icon(dc, .Prompt, draw.rect_center(b.rect), dtm.icon, dtc.accent, dtm.sc)
		}, nil)
		ui.next({width = ui.fill(), height = ui.pct(1), radius = 0, bg = draw.Color{}, border = draw.Color{}, font = dtm.mono, font_size = dtm.mono_fs, text_pad = 0})
		var_res = ui.line_edit("###console_js", &c.field, "Run JavaScript in this page (Enter), Tab to complete")
		if var_res.box != nil { var_res.box.flags -= {.Draw_Focus_Ring} }
		focused = var_res.focused
		if c.open && focused { console_complete_popup(app, c, box) }   // (a child of the row: it floats above it)
	}
	if focused { box.border = dtc.accent }
	res := var_res
	if res.focused {
		forms_page_blur(app)
		console_eval_keys(app, t, c)
	}
	if res.changed { console_eval_update(c) }
	if res.committed {
		source := strings.clone(strings.trim_space(ui.field_string(&c.field)), context.temp_allocator)
		if source != "" {
			tab_log(t, .Log, strings.concatenate({"> ", source}, context.temp_allocator))
			if len(c.history) == 0 || c.history[len(c.history) - 1] != source { append(&c.history, strings.clone(source)) }
			for len(c.history) > max(app.cfg.console_max_lines, 1) { delete(c.history[0]); ordered_remove(&c.history, 0) }
			c.cursor = len(c.history)
			ui.field_clear(&c.field)
			c.open = false
			dev.con.evaluating = true
			page.js_console_eval(console_target(t), source)
			dev.con.evaluating = false
			request_frames(app, 3)
		}
	}
	if res.cancelled { if c.open { c.open = false } else { ui.field_clear(&c.field); c.cursor = len(c.history) } }
}

// Up / Down: the completions when they are open, else the history. Tab / Right (at the end): accept.
@(private = "file")
console_eval_keys :: proc(app: ^App, t: ^Tab, c: ^Con_Eval) {
	if c.open && len(c.items) > 0 {
		if ui.key_press(.Down) { c.sel = (c.sel + 1) %% len(c.items) }
		else if ui.key_press(.Up) { c.sel = (c.sel - 1) %% len(c.items) }
		else if ui.key_press(.Tab) || (ui.key_press(.Right) && c.field.cursor == len(c.field.buf)) { console_accept(c) }
		return
	}
	if ui.key_press(.Tab) && con_prefs.autocomplete { console_eval_update(c, force = true); return }
	if ui.key_press(.Up) && c.cursor > 0 {
		if c.cursor == len(c.history) { delete(c.draft); c.draft = strings.clone(ui.field_string(&c.field)) }
		c.cursor -= 1
		ui.field_set(&c.field, c.history[c.cursor])
	} else if ui.key_press(.Down) && c.cursor < len(c.history) {
		c.cursor += 1
		ui.field_set(&c.field, c.cursor < len(c.history) ? c.history[c.cursor] : c.draft)
	}
}

// The word at the end of the text and what completes it.
@(private = "file")
console_eval_update :: proc(c: ^Con_Eval, force := false) {
	text := ui.field_string(&c.field)
	if c.field.cursor != len(text) || !(con_prefs.autocomplete || force) { c.open = false; return }
	for it in c.items { delete(it) }
	clear(&c.items)
	delete(c.word)
	c.word = ""
	if text == "" { c.open = false; return }
	// the expression the member is taken from, and the start of the name
	i := len(text)
	for i > 0 && is_ident_byte(text[i - 1]) { i -= 1 }
	word := text[i:]
	path := ""
	if i > 0 && text[i - 1] == '.' {
		j := i - 1
		for j > 0 && (is_ident_byte(text[j - 1]) || text[j - 1] == '.') { j -= 1 }
		path = text[j:i - 1]
	} else if word == "" && !force { c.open = false; return }
	c.word = strings.clone(word)
	complete_names(c, path, word)
	if text == c.dismissed { c.open = false; return }
	c.open = len(c.items) > 0 && !(len(c.items) == 1 && c.items[0] == word)
	c.sel = 0
	delete(c.shown_for)
	c.shown_for = strings.clone(text)
}

@(private = "file")
is_ident_byte :: proc(b: u8) -> bool { return b == '_' || b == '$' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') }

@(private = "file")
console_accept :: proc(c: ^Con_Eval) {
	if c.sel < 0 || c.sel >= len(c.items) { return }
	text := ui.field_string(&c.field)
	pick := c.items[c.sel]
	base := text[:len(text) - len(c.word)]
	next := strings.concatenate({base, pick}, context.temp_allocator)
	ui.field_set(&c.field, next)
	c.open = false
}

// The popup above the field.
@(private = "file")
console_complete_popup :: proc(app: ^App, c: ^Con_Eval, anchor: ^ui.Box) {
	n := min(len(c.items), 9)
	if n == 0 { return }
	rowh := dtm.row
	w := dt_px(220)
	for it in c.items[:n] { w = max(w, dt_w(dtm.mono, dtm.mono_fs, it) + dt_px(34)) }
	w = min(w, dt_px(460))
	h := f32(n) * rowh + dt_px(4)
	ui.next({width = ui.px(w), height = ui.px(h), axis = .Y, fixed_x = dt_px(24), fixed_y = -h - dt_px(1), bg = dtc.bar, border = dtc.border})
	pb := ui.build_box({.Draw_Background, .Draw_Border, .Draw_Shadow, .Clickable}, "###dt_eval_pop")
	if ui.parent(pb) {
		ui.spacer(ui.px(dt_px(2)))
		first := c.sel - n + 1 > 0 ? c.sel - n + 1 : 0
		for k in first ..< first + n {
			d := ui.frame_new(Comp_Draw)
			d.text, d.sel, d.word = dt_frame_str(c.items[k]), k == c.sel, len(c.word)
			ui.next({width = ui.fill(), height = ui.px(rowh), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, "###dt_cp")
			sig := ui.signal(rb)
			d.hot = sig.hovering
			rb.custom, rb.custom_user = comp_paint, d
			if sig.clicked { c.sel = k; console_accept(c) }
		}
	}
	_ = anchor
}

@(private = "file")
Comp_Draw :: struct { text: string, sel, hot: bool, word: int }

@(private = "file")
comp_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Comp_Draw)(user)
	r := b.rect
	if d.sel { draw.rect(dc, r, dtc.sel_weak); draw.rect(dc, {r.min, {r.min.x + dtm.line * 2, r.max.y}}, dtc.accent) } else if d.hot { draw.rect(dc, r, dtc.hover) }
	cy := (r.min.y + r.max.y) * 0.5
	// the typed part is bold-ish: drawn in the full color, the rest weaker
	typed := d.text[:min(d.word, len(d.text))]
	x := r.min.x + dt_px(10)
	x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.accent, typed)
	dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.text, d.text[len(typed):])
}

// Window closing.
console_eval_destroy :: proc() {
	c := &dev.con.eval
	ui.field_destroy(&c.field)
	for h in c.history { delete(h) }
	delete(c.history)
	for it in c.items { delete(it) }
	delete(c.items)
	delete(c.draft)
	delete(c.word)
	delete(c.shown_for)
	delete(c.dismissed)
	for s in c.dyn { delete(s) }
	delete(c.dyn)
	c^ = {}
}

////////////////////////////////
// The names

@(private = "file")
GLOBALS := [?]string{
	"AbortController", "Array", "ArrayBuffer", "BigInt", "Blob", "Boolean", "CSS", "CustomEvent", "DOMParser", "Date", "Document", "Element", "Error",
	"Event", "EventTarget", "File", "FileReader", "FormData", "Headers", "Infinity", "Intl", "JSON", "Map", "Math", "MutationObserver", "NaN", "Node",
	"Number", "Object", "Promise", "Proxy", "Reflect", "RegExp", "Request", "Response", "Set", "String", "Symbol", "TextDecoder", "TextEncoder", "URL",
	"URLSearchParams", "WebSocket", "Worker", "XMLHttpRequest", "alert", "atob", "btoa", "cancelAnimationFrame", "clearInterval", "clearTimeout",
	"console", "crypto", "document", "fetch", "getComputedStyle", "globalThis", "history", "innerHeight", "innerWidth", "isNaN", "localStorage",
	"location", "matchMedia", "navigator", "parseFloat", "parseInt", "performance", "postMessage", "queueMicrotask", "requestAnimationFrame",
	"screen", "scrollTo", "sessionStorage", "setInterval", "setTimeout", "structuredClone", "undefined", "window",
	"async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "else", "export", "false", "finally", "for",
	"function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "yield",
}

@(private = "file")
Members :: struct { path: string, names: []string }

@(private = "file")
MEMBERS := [?]Members{
	{"console", {"assert", "clear", "count", "countReset", "debug", "dir", "dirxml", "error", "group", "groupCollapsed", "groupEnd", "info", "log", "table", "time", "timeEnd", "timeLog", "trace", "warn"}},
	{"document", {"activeElement", "addEventListener", "body", "characterSet", "childNodes", "cookie", "createElement", "createTextNode", "currentScript", "documentElement", "domain", "elementFromPoint", "forms", "fonts", "getElementById", "getElementsByClassName", "getElementsByTagName", "head", "hidden", "images", "links", "location", "querySelector", "querySelectorAll", "readyState", "referrer", "removeEventListener", "scripts", "styleSheets", "title", "URL", "visibilityState"}},
	{"window", {"addEventListener", "alert", "cancelAnimationFrame", "clearInterval", "clearTimeout", "console", "devicePixelRatio", "document", "fetch", "getComputedStyle", "history", "innerHeight", "innerWidth", "localStorage", "location", "matchMedia", "navigator", "open", "performance", "postMessage", "removeEventListener", "requestAnimationFrame", "screen", "scrollBy", "scrollTo", "scrollX", "scrollY", "sessionStorage", "setInterval", "setTimeout"}},
	{"location", {"assign", "hash", "host", "hostname", "href", "origin", "pathname", "port", "protocol", "reload", "replace", "search"}},
	{"navigator", {"clipboard", "cookieEnabled", "hardwareConcurrency", "language", "languages", "onLine", "platform", "sendBeacon", "serviceWorker", "userAgent"}},
	{"history", {"back", "forward", "go", "length", "pushState", "replaceState", "state"}},
	{"localStorage", {"clear", "getItem", "key", "length", "removeItem", "setItem"}},
	{"sessionStorage", {"clear", "getItem", "key", "length", "removeItem", "setItem"}},
	{"Math", {"E", "PI", "abs", "acos", "asin", "atan", "atan2", "cbrt", "ceil", "clz32", "cos", "exp", "floor", "hypot", "log", "log10", "log2", "max", "min", "pow", "random", "round", "sign", "sin", "sqrt", "tan", "trunc"}},
	{"JSON", {"parse", "stringify"}},
	{"Object", {"assign", "create", "defineProperty", "entries", "freeze", "fromEntries", "getOwnPropertyNames", "getPrototypeOf", "is", "keys", "values"}},
	{"Array", {"from", "isArray", "of"}},
	{"Promise", {"all", "allSettled", "any", "race", "reject", "resolve"}},
	{"Number", {"EPSILON", "MAX_SAFE_INTEGER", "MIN_SAFE_INTEGER", "isFinite", "isInteger", "isNaN", "parseFloat", "parseInt"}},
	{"String", {"fromCharCode", "fromCodePoint", "raw"}},
	{"Date", {"UTC", "now", "parse"}},
	{"performance", {"clearMarks", "getEntries", "getEntriesByName", "getEntriesByType", "mark", "measure", "now", "timeOrigin", "timing"}},
	{"document.body", {"appendChild", "children", "classList", "className", "clientHeight", "clientWidth", "firstChild", "getBoundingClientRect", "id", "innerHTML", "innerText", "insertAdjacentHTML", "lastChild", "querySelector", "querySelectorAll", "remove", "scrollHeight", "setAttribute", "style", "textContent"}},
}

@(private = "file")
complete_names :: proc(c: ^Con_Eval, path, word: string) {
	add :: proc(c: ^Con_Eval, name, word: string) {
		if len(c.items) >= 60 || name == "" { return }
		if !strings.has_prefix(strings.to_lower(name, context.temp_allocator), strings.to_lower(word, context.temp_allocator)) { return }
		for it in c.items { if it == name { return } }
		append(&c.items, strings.clone(name))
	}
	// the page's own realm knows better than any list: its answer comes back as a console line the shell recognizes
	for s in c.dyn { delete(s) }
	clear(&c.dyn)
	if c.tab != nil && c.tab.page != nil { page.dev_console_complete(console_target(c.tab), path) }
	for n in c.dyn { add(c, n, word) }
	if path == "" {
		for g in GLOBALS { add(c, g, word) }
		for h in dev.con.eval.history {
			// identifiers the user used before
			i := 0
			for i < len(h) {
				if is_ident_byte(h[i]) {
					j := i
					for j < len(h) && is_ident_byte(h[j]) { j += 1 }
					if j - i >= 3 { add(c, h[i:j], word) }
					i = j
				} else { i += 1 }
			}
		}
	} else {
		for m in MEMBERS { if m.path == path { for n in m.names { add(c, n, word) } } }
		if path == "document.documentElement" || path == "document.head" { for m in MEMBERS { if m.path == "document.body" { for n in m.names { add(c, n, word) } } } }
	}
	// keep the list sorted: a prefix match with the same case first, then by name
	slice_sort_names(c.items[:], word)
}

@(private = "file")
slice_sort_names :: proc(items: []string, word: string) {
	for i in 1 ..< len(items) {
		j := i
		for j > 0 && name_before(items[j], items[j - 1], word) {
			items[j], items[j - 1] = items[j - 1], items[j]
			j -= 1
		}
	}
}

@(private = "file")
name_before :: proc(a, b, word: string) -> bool {
	ca, cb := strings.has_prefix(a, word), strings.has_prefix(b, word)
	if ca != cb { return ca }
	return a < b
}

package page

// What extensions change in the shell (docs/extensions.md, section 2.2 "Log in and unlock"): tabs.create, update,
// remove; windows.create (the popout window: type "popup"), update, remove; runtime.reload and openOptionsPage; the
// offscreen documents' pages. And the events the shell reports back: tabs.onCreated, onUpdated, onActivated,
// onRemoved; windows.onCreated, onRemoved, onFocusChanged.
//
// A call checks its arguments here, at once, then the shell acts in a task of the loop of its own (Ext_Task): a tab is
// never made or closed inside the call of a page, whose own tab may be the one that goes. The task answers the call.
// An event is built per extension: a tab's URL and title are in it only when that extension may see them (ext_may_see).

import "core:fmt"
import "core:strings"
import "wb:extensions"
import "wb:host"
import "wb:url"

Ext_Task_Op :: enum u8 { Tab_Create, Tab_Update, Tab_Remove, Window_Create, Window_Update, Window_Remove, Offscreen_Open, Offscreen_Close, Reload }

Ext_Task :: struct {
	op:        Ext_Task_Op,
	ext:       string,              // owned
	url:       string,              // owned
	urls:      [dynamic]string,     // owned
	to:        Ext_Target,
	answers:   bool,                // a call waits for the answer
	undefined: bool,                // ... and it is undefined (runtime.openOptionsPage)
	tab:       i64,
	tabs:      [dynamic]i64,
	window:    i64,
	index:     i64,
	activate:  bool,
	popup:     bool,
	focus:     bool,
	move:      bool,
	width, height, left, top: int,
}

ext_loop :: proc() -> ^host.Loop {
	r := ext_router()
	if r.loop == nil { r.loop = the_pages.sw_registry.loop }
	return r.loop
}

@(private = "file")
ext_task_new :: proc(op: Ext_Task_Op, ext: string) -> ^Ext_Task {
	t := new(Ext_Task)
	t.op, t.ext = op, strings.clone(ext)
	t.tab, t.window, t.index = -1, -1, -1
	return t
}

@(private = "file")
ext_task_free :: proc(t: ^Ext_Task) {
	delete(t.ext); delete(t.url)
	for u in t.urls { delete(u) }
	delete(t.urls); delete(t.tabs)
	free(t)
}

// Runs `t` from a task of the loop of its own (no loop: it is dropped, and a call waiting for it fails).
@(private = "file")
ext_task_start :: proc(t: ^Ext_Task) {
	loop := ext_loop()
	if loop == nil {
		if t.answers { ext_answer(t.to, "!the browser cannot do this now") }
		ext_task_free(t)
		return
	}
	host.post(loop, ext_task_run, t)
}

// A task with no answer (offscreen pages, runtime.reload).
ext_task_post :: proc(op: Ext_Task_Op, ext, u: string) {
	t := ext_task_new(op, ext)
	t.url = strings.clone(u)
	ext_task_start(t)
}

// A task that answers the call `x` (x.answered: the task does it).
@(private = "file")
ext_task_for :: proc(x: ^Ext_Call, op: Ext_Task_Op) -> ^Ext_Task {
	t := ext_task_new(op, x.e.id)
	t.to, t.answers = x.to, true
	x.answered = true
	return t
}

@(private = "file")
ext_task_run :: proc(data: rawptr) {
	t := (^Ext_Task)(data)
	defer ext_task_free(t)
	r := ext_router()
	em := &r.embedder
	reg := ext_registry()
	e := extensions.registry_running(reg, extensions.SCHEME_CHROME, t.ext)
	fail :: proc(task: ^Ext_Task, message: string) { if task.answers { ext_answer(task.to, strings.concatenate({"!", message}, context.temp_allocator)) } }
	switch t.op {
	case .Offscreen_Open:
		if e == nil || em.offscreen_open == nil || !em.offscreen_open(em.user, t.ext, t.url) { ext_offscreen_close(t.ext) }
	case .Offscreen_Close:
		if em.offscreen_close != nil { em.offscreen_close(em.user, t.ext) }
	case .Reload:
		if e != nil && em.reload != nil { em.reload(em.user, t.ext) }
	case .Tab_Create:
		if e == nil || em.tab_create == nil { fail(t, "tabs cannot be made now"); return }
		id := em.tab_create(em.user, t.ext, Ext_Tab_Spec{url = t.url, window = t.window, index = t.index, active = t.activate})
		if id < 0 { fail(t, "the tab could not be made"); return }
		if t.undefined { ext_answer(t.to, ""); return }
		ext_answer_tab(t.to, reg, e, id)
	case .Tab_Update:
		if e == nil || em.tab_update == nil { fail(t, "tabs cannot be changed now"); return }
		if !em.tab_update(em.user, t.tab, t.url, t.activate) { fail(t, fmt.tprintf("No tab with id: %d.", t.tab)); return }
		ext_answer_tab(t.to, reg, e, t.tab)
	case .Tab_Remove:
		if em.tab_remove == nil { fail(t, "tabs cannot be closed now"); return }
		for id in t.tabs {
			if !em.tab_remove(em.user, id) { fail(t, fmt.tprintf("No tab with id: %d.", id)); return }
		}
		if t.answers { ext_answer(t.to, "") }
	case .Window_Create:
		if e == nil || em.window_create == nil { fail(t, "windows cannot be made now"); return }
		spec := Ext_Window_Spec{urls = t.urls[:], popup = t.popup, width = t.width, height = t.height, left = t.left, top = t.top, has_position = t.move, focused = t.focus}
		id := em.window_create(em.user, t.ext, spec)
		if id < 0 { fail(t, "the window could not be made"); return }
		ext_answer_window(t.to, reg, e, id)
	case .Window_Update:
		if e == nil || em.window_update == nil { fail(t, "windows cannot be changed now"); return }
		if !em.window_update(em.user, t.window, t.focus, t.left, t.top, t.move) { fail(t, fmt.tprintf("No window with id: %d.", t.window)); return }
		ext_answer_window(t.to, reg, e, t.window)
	case .Window_Remove:
		if em.window_remove == nil || !em.window_remove(em.user, t.window) { fail(t, fmt.tprintf("No window with id: %d.", t.window)); return }
		if t.answers { ext_answer(t.to, "") }
	}
}

@(private = "file")
ext_answer_tab :: proc(to: Ext_Target, reg: ^extensions.Registry, e: ^extensions.Extension, id: i64) {
	for t in ext_tabs_list() {
		if t.id != id { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_tab_json_of(&b, reg, e, t)
		ext_answer(to, strings.to_string(b))
		return
	}
	ext_answer(to, "")   // (it went at once: closed by a page in between)
}

@(private = "file")
ext_answer_window :: proc(to: Ext_Target, reg: ^extensions.Registry, e: ^extensions.Extension, id: i64) {
	for w in ext_windows_list() {
		if w.id != id { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_window_json_of(&b, reg, e, w, true)
		ext_answer(to, strings.to_string(b))
		return
	}
	ext_answer(to, "")
}

// Whether an extension may open `u` in a tab or a window: the web, a blank page, its own files. Never another
// extension's pages, Wren's own pages, files of the disk or script URLs (rule 7 and 9 of section 3.11). Returns the
// absolute URL (temp).
ext_open_url_ok :: proc(e: ^extensions.Extension, u: string) -> (string, bool) {
	if u == "" || u == "about:blank" { return "about:blank", true }
	base_u, bok := url.parse(e.image.base_url, nil, context.temp_allocator)
	if !bok { return "", false }
	abs, ok := url.parse(u, &base_u, context.temp_allocator)
	if !ok { return "", false }
	switch abs.scheme {
	case "http", "https": return abs.href, true
	case extensions.SCHEME_CHROME: return ext_own_file_url(e, abs.href)
	}
	return "", false
}

////////////////////////////////
// tabs

ext_tabs_create :: proc(x: ^Ext_Call, a: Ext_Tabs_Create_Args) {
	props := a.create_properties
	u := props.url.? or_else ""
	abs, uok := ext_open_url_ok(x.e, u)
	if !uok { ext_fail(x, fmt.tprintf("Cannot navigate to %q: only web pages and the extension's own pages can be opened", u)); return }
	t := ext_task_for(x, .Tab_Create)
	t.url = strings.clone(abs)
	t.activate = true
	if v, has := props.active.?; has { t.activate = v }
	if v, has := props.selected.?; has { t.activate = v }
	if n, has := props.window_id.?; has { t.window = n == -2 ? ext_current_window(x) : n }
	if n, has := props.index.?; has { t.index = n }
	ext_task_start(t)
}

ext_tabs_update :: proc(x: ^Ext_Call, a: Ext_Tabs_Update_Args) {
	props := a.update_properties
	tab := a.tab_id.? or_else -1
	if tab < 0 {
		// no id: the selected tab of the current window
		want := ext_current_window(x)
		for t in ext_tabs_list() { if t.window == want && t.active { tab = t.id; break } }
		if tab < 0 { ext_fail(x, "No current tab."); return }
	}
	found := false
	for t in ext_tabs_list() { if t.id == tab { found = true; break } }
	if !found { ext_fail(x, fmt.tprintf("No tab with id: %d.", tab)); return }
	abs := ""
	if u, has := props.url.?; has {
		ok: bool
		abs, ok = ext_open_url_ok(x.e, u)
		if !ok { ext_fail(x, fmt.tprintf("Cannot navigate to %q: only web pages and the extension's own pages can be opened", u)); return }
	}
	t := ext_task_for(x, .Tab_Update)
	t.tab, t.url = tab, strings.clone(abs)
	if v, has := props.active.?; has && v { t.activate = true }
	if v, has := props.highlighted.?; has && v { t.activate = true }
	ext_task_start(t)
}

ext_tabs_remove :: proc(x: ^Ext_Call, a: Ext_Tabs_Remove_Args) {
	ids := make([dynamic]i64, 0, 4, context.temp_allocator)
	switch v in a.tab_ids {
	case nil:
	case i64:   append(&ids, v)
	case []i64: append(&ids, ..v)
	}
	known := ext_tabs_list()
	for id in ids {
		found := false
		for t in known { if t.id == id { found = true; break } }
		if !found { ext_fail(x, fmt.tprintf("No tab with id: %d.", id)); return }
	}
	t := ext_task_for(x, .Tab_Remove)
	append(&t.tabs, ..ids[:])
	ext_task_start(t)
}

////////////////////////////////
// windows

ext_windows_create :: proc(x: ^Ext_Call, a: Ext_Windows_Create_Args) {
	data, _ := a.create_data.?
	urls := make([dynamic]string, 0, 2, context.temp_allocator)
	switch u in data.url {
	case nil:
	case string:   append(&urls, u)
	case []string: append(&urls, ..u)
	}
	if _, has := data.tab_id.?; has { ext_fail(x, "windows.create: moving a tab into the new window (tabId) is not supported"); return }
	if v, has := data.incognito.?; has && v { ext_fail(x, "Incognito mode is not available."); return }
	kind := data.type.? or_else ""
	t := ext_task_for(x, .Window_Create)
	for u in urls {
		abs, ok := ext_open_url_ok(x.e, u)
		if !ok {
			// (the task was made for the answer: it answers the error now and goes)
			ext_answer(t.to, fmt.tprintf("!Cannot navigate to %q: only web pages and the extension's own pages can be opened", u))
			ext_task_free(t)
			return
		}
		append(&t.urls, strings.clone(abs))
	}
	t.popup = kind == "popup" || kind == "panel"
	t.focus = true
	if v, has := data.focused.?; has { t.focus = v }
	if n, has := data.width.?; has { t.width = int(n) }
	if n, has := data.height.?; has { t.height = int(n) }
	l, has_l := data.left.?
	tp, has_t := data.top.?
	if has_l || has_t { t.left, t.top, t.move = int(l), int(tp), true }
	ext_task_start(t)
}

// The window a call names, -2 being the current one; false when no window has that id.
@(private = "file")
ext_window_id_of :: proc(x: ^Ext_Call, n: i64) -> (i64, bool) {
	id := n
	if id == -2 { id = ext_current_window(x) }
	for w in ext_windows_list() { if w.id == id { return id, true } }
	return id, false
}

ext_windows_update :: proc(x: ^Ext_Call, a: Ext_Windows_Update_Args) {
	id, ok := ext_window_id_of(x, a.window_id)
	if !ok { ext_fail(x, fmt.tprintf("No window with id: %d.", id)); return }
	info, _ := a.update_info.?
	t := ext_task_for(x, .Window_Update)
	t.window = id
	if v, has := info.focused.?; has && v { t.focus = true }
	if s, has := info.state.?; has && s == "normal" { t.focus = true }
	l, has_l := info.left.?
	tp, has_t := info.top.?
	if has_l || has_t { t.left, t.top, t.move = int(l), int(tp), true }
	ext_task_start(t)
}

ext_windows_remove :: proc(x: ^Ext_Call, a: Ext_Windows_Remove_Args) {
	id, ok := ext_window_id_of(x, a.window_id)
	if !ok { ext_fail(x, fmt.tprintf("No window with id: %d.", id)); return }
	t := ext_task_for(x, .Window_Remove)
	t.window = id
	ext_task_start(t)
}

////////////////////////////////
// runtime

ext_runtime_reload :: proc(x: ^Ext_Call) {
	ext_ok(x, "")
	ext_task_post(.Reload, x.e.id, "")
}

ext_runtime_open_options_page :: proc(x: ^Ext_Call) {
	m := &x.e.image.manifest
	if m.options_page == "" { ext_fail(x, "Could not create an options page."); return }
	t := ext_task_for(x, .Tab_Create)
	t.url = strings.clone(extensions.image_url(x.e.image, m.options_page))
	t.activate, t.undefined = true, true
	ext_task_start(t)
}

EXT_CONTEXT_TYPES := [Ext_Kind]string{.Background = "BACKGROUND", .Popup = "POPUP", .Tab = "TAB", .Offscreen = "OFFSCREEN_DOCUMENT", .Content = ""}

// runtime.getContexts(filter): the extension's contexts, as the router knows them (the background only while it runs).
ext_runtime_get_contexts :: proc(x: ^Ext_Call, a: Ext_Runtime_Get_Contexts_Args) {
	f := a.filter
	texts :: proc(list: Maybe([]string), text: string) -> bool {
		l, has := list.?
		if !has { return true }
		for v in l { if v == text { return true } }
		return false
	}
	numbers :: proc(list: Maybe([]i64), n: i64) -> bool {
		l, has := list.?
		if !has { return true }
		for v in l { if v == n { return true } }
		return false
	}
	if v, has := f.incognito.?; has && v { ext_ok(x, "[]"); return }
	tabs := ext_tabs_list()
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for _, c in ext_router().contexts {
		if c.ext != x.e.id || c.kind == .Content { continue }
		tab_id, window_id, frame := i64(-1), i64(-1), i64(0)
		if c.kind == .Background {
			frame = -1
			if bg := ext_router().backgrounds[c.ext]; bg == nil || bg.version.worker == nil { continue }
		}
		if c.kind == .Tab {
			for t in tabs { if t.page == c.page { tab_id, window_id = t.id, t.window; break } }
		}
		type_name := EXT_CONTEXT_TYPES[c.kind]
		context_id := fmt.tprintf("%d", c.id)
		origin := fmt.tprintf("%s://%s", extensions.SCHEME_CHROME, c.ext)
		if !texts(f.context_types, type_name) || !texts(f.context_ids, context_id) ||
		   !numbers(f.tab_ids, tab_id) || !numbers(f.window_ids, window_id) ||
		   !numbers(f.frame_ids, frame) || !texts(f.document_urls, c.url) ||
		   !texts(f.document_origins, origin) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		fmt.sbprintf(&b, `{{"contextType":%s,"contextId":%s,"tabId":%d,"windowId":%d,"frameId":%d,"incognito":false`,
			extensions.json_quote(type_name), extensions.json_quote(context_id), tab_id, window_id, frame)
		if c.kind != .Background {
			fmt.sbprintf(&b, `,"documentId":%s,"documentUrl":%s,"documentOrigin":%s`, extensions.json_quote(context_id), extensions.json_quote(c.url), extensions.json_quote(origin))
		}
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

////////////////////////////////
// Events of tabs and windows (the shell reports them: ext_window_api.odin)

// The extensions that run and have a context listening to `event` (temp).
@(private = "file")
ext_listening :: proc(event: string) -> []^extensions.Extension {
	out := make([dynamic]^extensions.Extension, 0, 4, context.temp_allocator)
	reg := ext_registry()
	for e in reg.list {
		if !e.enabled || e.image == nil || !e.image.ok { continue }
		for _, c in ext_router().contexts {
			if c.ext == e.id && c.kind != .Content && ext_listens(c, event) { append(&out, e); break }
		}
	}
	return out[:]
}

ext_tab_event_created :: proc(t: Ext_Tab_Info) {
	for e in ext_listening("tabs.onCreated") {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		ext_tab_json_of(&b, ext_registry(), e, t)
		strings.write_byte(&b, ']')
		ext_emit(e.id, "tabs.onCreated", strings.to_string(b))
	}
}

// A tab started loading (`loading`, with its new URL) or finished (`!loading`).
ext_tab_event_updated :: proc(t: Ext_Tab_Info, loading: bool) {
	for e in ext_listening("tabs.onUpdated") {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `[%d,{{"status":%s`, t.id, loading ? `"loading"` : `"complete"`)
		if loading && ext_may_see_of(ext_registry(), e, t.url) { fmt.sbprintf(&b, `,"url":%s`, extensions.json_quote(t.url)) }
		strings.write_string(&b, "},")
		ext_tab_json_of(&b, ext_registry(), e, t)
		strings.write_byte(&b, ']')
		ext_emit(e.id, "tabs.onUpdated", strings.to_string(b))
	}
}

// A tab's document fired its load event: tabs.onUpdated "complete" (ext_page_loaded).
ext_tab_loaded :: proc(p: ^Page) {
	if len(ext_listening("tabs.onUpdated")) == 0 { return }
	id := page_id(p)
	for t in ext_tabs_list() {
		if t.page != id { continue }
		info := t
		info.loading = false
		ext_tab_event_updated(info, false)
		return
	}
}

ext_tab_event_activated :: proc(tab, window: i64) {
	for e in ext_listening("tabs.onActivated") {
		ext_emit(e.id, "tabs.onActivated", fmt.tprintf(`[{{"tabId":%d,"windowId":%d}}]`, tab, window))
	}
}

ext_tab_event_removed :: proc(tab, window: i64, window_closing: bool) {
	for e in ext_listening("tabs.onRemoved") {
		ext_emit(e.id, "tabs.onRemoved", fmt.tprintf(`[%d,{{"windowId":%d,"isWindowClosing":%s}}]`, tab, window, jbool_text(window_closing)))
	}
}

ext_window_event_created :: proc(w: Ext_Window_Info) {
	for e in ext_listening("windows.onCreated") {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		ext_window_json_of(&b, ext_registry(), e, w, false)
		strings.write_byte(&b, ']')
		ext_emit(e.id, "windows.onCreated", strings.to_string(b))
	}
}

ext_window_event_removed :: proc(window: i64) {
	for e in ext_listening("windows.onRemoved") { ext_emit(e.id, "windows.onRemoved", fmt.tprintf("[%d]", window)) }
}

// The focused window changed (-1: none of the browser's).
ext_window_event_focus :: proc(window: i64) {
	for e in ext_listening("windows.onFocusChanged") { ext_emit(e.id, "windows.onFocusChanged", fmt.tprintf("[%d]", window)) }
}

package browser

// Context menus: the page's (link, image, selection, editable field, the page itself, combined as they apply), the
// tab strip's and the address bar's, built with the toolkit's menus (keyboard, submenus, kept on screen).
//
// The page first gets a cancelable `contextmenu` event at the element under the pointer (or the focused one when the
// menu comes from the keyboard: the Menu key or Shift+F10); when a listener cancels it there is no browser menu, unless
// Shift is held and browser.contextmenu.shift_forces_native is on (as in Firefox). A menu opens from the build (the
// requests made while routing input wait for it) so the press that asked for it is not taken as a press outside.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:host"
import "wb:i18n"
import lay "wb:layout"
import "wb:page"
import "wb:url"

Ctx_Kind :: enum u8 { Page, Tab, Address }

Context_Request :: struct {
	kind:        Ctx_Kind,
	pos:         [2]f32,
	keyboard:    bool,
	tab:         int,
	page:        ^page.Page,     // the page the menu is about (it closes if that page goes away)
	link:        string,         // absolute URL (owned)
	link_text:   string,         // owned
	image:       string,         // absolute URL (owned)
	image_node:  base.Handle,
	editable:    base.Handle,    // the page's text field the menu edits
	target:      base.Handle,    // the element under the pointer (Inspect)
	selection:   string,         // owned
}

// A window's context menu (Window_Own.ctx_menu).
Context_Menu_State :: struct {
	req:     Context_Request,   // asked for, opened by the next build
	pending: bool,
	open:    Context_Request,   // what the open menu is about
}

CTX_MENU_ID :: "###page_context_menu"

@(private = "file")
request_free :: proc(r: ^Context_Request) {
	delete(r.link); delete(r.link_text); delete(r.image); delete(r.selection)
	r^ = {}
}

context_menu_state_destroy :: proc(cm: ^Context_Menu_State) {
	request_free(&cm.req)
	request_free(&cm.open)
	cm.pending = false
}

context_menu_destroy :: proc(app: ^App) { context_menu_state_destroy(&window_own(app).ctx_menu) }

@(private = "file")
request :: proc(app: ^App, r: Context_Request) {
	cm := &window_own(app).ctx_menu
	request_free(&cm.req)
	cm.req = r
	cm.pending = true
	app.frames_requested = max(app.frames_requested, 2)
}

////////////////////////////////
// What is under the pointer

@(private = "file")
resolve :: proc(p: ^page.Page, href: string) -> string {
	u, ok := url.parse(href, &p.env.location, context.temp_allocator)
	return ok ? u.href : ""
}

// The page's context: link, image, editable field, selection around `target`.
@(private = "file")
page_request :: proc(app: ^App, t: ^Tab, target: base.Handle, pos: [2]f32, keyboard: bool) -> Context_Request {
	p := t.page
	r := Context_Request{kind = .Page, pos = pos, keyboard = keyboard, page = p, target = target}
	d := p.doc
	for cur := target; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if n.name == "a" && r.link == "" {
				if href, ok := dom.get_attribute(d, cur, "href"); ok {
					r.link = strings.clone(resolve(p, href))
					r.link_text = strings.clone(strings.trim_space(forms.collapse_ws(dom.text_content(d, cur))))
				}
			}
			if n.name == "img" && r.image == "" {
				if src, ok := dom.get_attribute(d, cur, "src"); ok && src != "" {
					r.image = strings.clone(resolve(p, src))
					r.image_node = cur
				}
			}
		}
		cur = n.parent
	}
	if p.formctl != nil {
		f := page.page_forms(p)
		if forms.is_text_field(f, f.focus) && (target == base.NIL_HANDLE || dom.is_ancestor_or_self(d, f.focus, target) || keyboard) { r.editable = f.focus }
	}
	if page.selection_active(p) { r.selection = strings.clone(page.selection_text(p)) }
	return r
}

// A right button release over the page: contextmenu to the page, then the browser's menu unless cancelled.
page_context_menu :: proc(app: ^App, t: ^Tab, target: base.Handle, pos: [2]f32, local: [2]f32, shift: bool, keyboard := false) {
	p := t.page
	if p == nil { return }
	scale := page_scale(app)
	at := target != base.NIL_HANDLE ? target : p.body
	cx, cy := page_client_xy(t, local, scale)
	allowed := page.dispatch_event(p, at, dom.Event{type = "contextmenu", bubbles = true, cancelable = true, x = cx, y = cy, button = 2})
	if t.page != p { return }
	if !allowed && !(shift && ix.ctx_shift_forces) { return }
	request(app, page_request(app, t, target, pos, keyboard))
}

// A right press in the page: a press outside the selection removes it (inside, the menu is about it).
page_context_press :: proc(app: ^App, t: ^Tab, pos: [2]f32) {
	p := t.page
	if p == nil || !page.selection_active(p) { return }
	tp, ok := position_of(app, t, pos)
	if !ok { return }
	a, b, _ := page.selection_range(p)
	if lay.pos_compare(p.doc, a, tp) <= 0 && lay.pos_compare(p.doc, tp, b) <= 0 { return }
	page.selection_clear(p)
}

// The Menu key / Shift+F10 while the page has the keyboard: at the focused element, else at the selection, else at
// the top left corner of the page.
page_context_menu_keyboard :: proc(app: ^App, t: ^Tab) {
	p := t.page
	if p == nil { return }
	em := ui.font_size()
	pos := app.page_rect.min + {em, em}
	target := p.body
	view := draw.rect_size(app.page_rect)
	if p.formctl != nil {
		f := page.page_forms(p)
		if f.focus != base.NIL_HANDLE {
			target = f.focus
			if r, ok := lay.box_of(&t.layout, f.focus, view, t.scroll); ok {
				// (box_of's rects are document coordinates for every box, position: fixed ones included)
				pos = app.page_rect.min + {r.bounds.min.x, r.bounds.max.y - t.scroll}
			}
		}
	}
	if target == p.body && page.selection_active(p) {
		a, _, _ := page.selection_range(p)
		n := dom.get(p.doc, a.node)
		if n != nil {
			el := n.kind == .Text ? n.parent : a.node
			target = el
			if r, ok := lay.box_of(&t.layout, el, view, t.scroll); ok { pos = app.page_rect.min + {r.bounds.min.x, r.bounds.max.y - t.scroll} }
		}
	}
	pos = {clamp(pos.x, app.page_rect.min.x, app.page_rect.max.x), clamp(pos.y, app.page_rect.min.y, app.page_rect.max.y)}
	page_context_menu(app, t, target, pos, pos - app.page_rect.min + {0, t.scroll}, false, keyboard = true)
}

tab_context_menu :: proc(app: ^App, index: int, pos: [2]f32, keyboard := false) {
	request(app, Context_Request{kind = .Tab, tab = index, pos = pos, keyboard = keyboard})
}

address_context_menu :: proc(app: ^App, pos: [2]f32, keyboard := false) {
	request(app, Context_Request{kind = .Address, pos = pos, keyboard = keyboard})
}

////////////////////////////////
// Building

@(private = "file")
short :: proc(s: string, n: int) -> string {
	t := strings.trim_space(s)
	if strings.count(t, "") <= n { return t }
	i, count := 0, 0
	for _, b in t { if count == n { i = b; break }; count += 1 }
	return strings.concatenate({t[:i], "…"}, context.temp_allocator)
}

// Builds the open context menu (call once per frame, after the chrome and the page area).
context_menus_build :: proc(app: ^App) {
	key := ui.key_from_string(0, CTX_MENU_ID)
	cm := &window_own(app).ctx_menu
	if cm.pending {
		cm.pending = false
		request_free(&cm.open)
		cm.open, cm.req = cm.req, {}
		ui.ctx_menu_open(key, cm.open.pos, from_keyboard = cm.open.keyboard)
	}
	if !ui.ctx_menu_is_open(key) { return }
	t := current_tab(app)
	r := &cm.open
	if r.kind == .Page && (t == nil || t.page != r.page) { ui.ctx_menu_close(); return }
	if ui.ctx_menu(key) {
		switch r.kind {
		case .Page: page_menu_items(app, t, r)
		case .Tab: tab_menu_items(app, r)
		case .Address: address_menu_items(app)
		}
	}
}

@(private = "file")
page_menu_items :: proc(app: ^App, t: ^Tab, r: ^Context_Request) {
	p := t.page
	groups := 0
	sep :: proc(groups: ^int) { if groups^ > 0 { ui.menu_separator() }; groups^ += 1 }
	if r.editable != base.NIL_HANDLE && p.formctl != nil {
		f := page.page_forms(p)
		h := r.editable
		if dom.get(p.doc, h) == nil { ui.ctx_menu_close(); return }
		mutable := forms.is_mutable(f, h)
		a, b, _ := forms.selection(f, h)
		has_sel := a != b
		pw := forms.kind(f, h) == .Input && forms.input_type(f, h) == .Password
		sep(&groups)
		if ui.menu_item("Undo", "Ctrl+Z", enabled = mutable && forms.can_undo(f, h)).clicked { forms.edit(f, h, .History_Undo) }
		if ui.menu_item("Redo", "Ctrl+Y", enabled = mutable && forms.can_redo(f, h)).clicked { forms.edit(f, h, .History_Redo) }
		ui.menu_separator()
		if ui.menu_item("Cut", "Ctrl+X", enabled = mutable && has_sel && !pw).clicked {
			if page.dispatch_event(p, h, dom.Event{type = "cut", bubbles = true, cancelable = true}) { if s := forms.cut(f, h); s != "" { clip_set(s) } }
		}
		if ui.menu_item("Copy", "Ctrl+C", enabled = has_sel && !pw).clicked {
			if page.dispatch_event(p, h, dom.Event{type = "copy", bubbles = true, cancelable = true}) { if s := forms.copy_text(f, h); s != "" { clip_set(s) } }
		}
		clip := clip_get()
		if ui.menu_item("Paste", "Ctrl+V", enabled = mutable && clip != "").clicked {
			text := strings.clone(clip, context.temp_allocator)
			if page.dispatch_event(p, h, dom.Event{type = "paste", bubbles = true, cancelable = true, data = text}) { forms.paste(f, h, text) }
		}
		if ui.menu_item("Delete", "Del", enabled = mutable && has_sel).clicked { forms.edit(f, h, .Delete_Backward) }
		ui.menu_separator()
		if ui.menu_item("Select all", "Ctrl+A", enabled = forms.edit_text(f, h) != "").clicked { forms.select_all(f, h) }
		app.frames_requested = max(app.frames_requested, 2)
	}
	if r.link != "" {
		sep(&groups)
		if ui.menu_item("Open link").clicked { navigate(app, t, strings.clone(r.link, context.temp_allocator), p, user_activation = true) ; return }
		if ui.menu_item("Open link in new tab").clicked { open_in_new_tab(app, r.link, p) }
		ui.menu_separator()
		if ui.menu_item("Copy link address").clicked { clip_set(r.link) }
		if ui.menu_item("Copy link text", enabled = r.link_text != "").clicked { clip_set(r.link_text) }
	}
	if r.image != "" {
		sep(&groups)
		if ui.menu_item("Open image in new tab").clicked { open_in_new_tab(app, r.image, p) }
		if ui.menu_item("Save image as…").clicked { save_as(app, r.image, suggested_name(r.image, "image")) }
		view := page.image_view(p, r.image_node)
		if ui.menu_item("Copy image", enabled = view.state == .Ready && view.id != 0).clicked { copy_image(app, view) }
		if ui.menu_item("Copy image address").clicked { clip_set(r.image) }
	}
	if r.selection != "" && r.editable == base.NIL_HANDLE {
		sep(&groups)
		if ui.menu_item("Copy", "Ctrl+C").clicked { copy_selection(app, t) }
		words := strings.trim_space(r.selection)
		if ui.menu_item(fmt.tprintf("Search %s for “%s”###ctx_search", search_engine_name(&ix), short(words, 28))).clicked {
			open_in_new_tab(app, search_url(&ix, words), origin = .User)
		}
	}
	if groups == 0 {
		can_back := t.hist > 0
		can_forward := t.hist + 1 < len(t.history)
		if ui.menu_item("Back", "Alt+Left", icon = GLYPH_BACK, enabled = can_back).clicked { go_history(app, t, -1); return }
		if ui.menu_item("Forward", "Alt+Right", icon = GLYPH_FORWARD, enabled = can_forward).clicked { go_history(app, t, +1); return }
		if ui.menu_item("Reload", "Ctrl+R", icon = GLYPH_RELOAD).clicked { reload(app, t); return }
		ui.menu_separator()
		if ui.menu_item("Save as…", "Ctrl+S", enabled = savable(t)).clicked { save_page(app, t) }
		ui.menu_separator()
		if ui.menu_item("Select all", "Ctrl+A").clicked { page.selection_select_all(p) }
		if ui.menu_item("Find…", "Ctrl+F").clicked { find_open(app) }
		ui.menu_separator()
		if ui.menu_item("View page source", "Ctrl+U", enabled = !strings.has_prefix(t.url, "view-source:")).clicked { view_source(app, t) }
		if ui.menu_item("Page information", icon = GLYPH_INFO).clicked { window_own(app).page_info_request = true }
	}
	if _, filtered := blocker_page_host(t); filtered && bl.started && bl.b.cfg.enabled {
		sep(&groups)
		if ui.menu_item(i18n.tr("Block element…"), "Ctrl+Shift+K", icon = GLYPH_CLOSE).clicked { blocker_picker_target(app, t, r.target); return }
		res := r.image != "" ? r.image : r.link
		if ui.menu_item(i18n.tr("Block this resource"), enabled = res != "").clicked { blocker_block_resource(app, res) }
		if ui.menu_item(i18n.tr("Content blocker panel…")).clicked { window_own(app).blocker_panel_request = true }
	}
	if r.target != base.NIL_HANDLE || groups == 0 {
		ui.menu_separator()
		if ui.menu_item("Inspect", "Ctrl+Shift+I").clicked { devtools_inspect(app, t, r.target != base.NIL_HANDLE ? r.target : p.body); return }
	}
}

@(private = "file")
tab_menu_items :: proc(app: ^App, r: ^Context_Request) {
	if r.tab < 0 || r.tab >= len(app.tabs) { ui.ctx_menu_close(); return }
	t := app.tabs[r.tab]
	if ui.menu_item("New tab", "Ctrl+T", icon = GLYPH_ADD).clicked { tab_open_new(app); return }
	ui.menu_separator()
	if ui.menu_item("Reload", "Ctrl+R", icon = GLYPH_RELOAD, enabled = t.kind == .Web || t.kind == .Config).clicked { reload(app, t) }
	if ui.menu_item("Duplicate").clicked { open_in_new_tab(app, t.url, origin = .Replay) }
	ui.menu_separator()
	if ui.menu_item("Close tab", "Ctrl+W", icon = GLYPH_CLOSE).clicked { tab_close(app, r.tab); return }
	if ui.menu_item("Close other tabs", enabled = len(app.tabs) > 1).clicked { close_other_tabs(app, r.tab); return }
	if ui.menu_item("Reopen closed tab", "Ctrl+Shift+T", enabled = len(closed_tabs) > 0).clicked { reopen_closed_tab(app) }
	ui.menu_separator()
	menu_command(app, t, "tab.move_to_new_window")
	if len(app.windows) > 1 {
		target: ^Browser_Window
		if ui.menu_submenu(fmt.tprintf("%s###move_to_window_sub", i18n.tr("Move to window"))) {
			for w in app.windows {
				if w == app.active { continue }
				if ui.menu_item(fmt.tprintf("%s###mv_%d", window_label(app, w), w.id)).clicked { target = w }
			}
		}
		if target != nil { tab_move(app, t, target); ui.ctx_menu_close(); return }
	}
	ui.menu_separator()
	if ui.menu_submenu(fmt.tprintf("%s###tabbar_sub", i18n.tr("Tab bar"))) {   // tab_sidebar.odin
		cur := current_tab(app)
		menu_command(app, cur, "view.tabs_position.top")
		menu_command(app, cur, "view.tabs_position.left")
		menu_command(app, cur, "view.tabs_position.right")
		menu_command(app, cur, "view.tabs_sidebar_collapse")
	}
}

@(private = "file")
address_menu_items :: proc(app: ^App) {
	f := &app.address
	sel := ui.field_has_selection(f)
	clip := clip_get()
	if ui.menu_item("Undo", "Ctrl+Z", enabled = ui.field_can_undo(f)).clicked { ui.field_undo(f) }
	if ui.menu_item("Redo", "Ctrl+Y", enabled = ui.field_can_redo(f)).clicked { ui.field_redo(f) }
	ui.menu_separator()
	if ui.menu_item("Cut", "Ctrl+X", enabled = sel).clicked { ui.field_cut(f) }
	if ui.menu_item("Copy", "Ctrl+C", enabled = sel).clicked { ui.field_copy(f) }
	if ui.menu_item("Paste", "Ctrl+V", enabled = clip != "").clicked { ui.field_paste(f) }
	if ui.menu_item("Paste and go", enabled = strings.trim_space(clip) != "").clicked {
		target := strings.clone(strings.trim_space(clip), context.temp_allocator)
		if t := current_tab(app); t != nil { navigate(app, t, address_or_search(target), origin = .User) }
	}
	if ui.menu_item("Delete", "Del", enabled = sel).clicked { ui.field_delete(f) }
	ui.menu_separator()
	if ui.menu_item("Select all", "Ctrl+A", enabled = len(f.buf) > 0).clicked { ui.field_select_all(f) }
}

// What the address bar does with words that are not an address: a search.
address_or_search :: proc(input: string) -> string {
	s := strings.trim_space(input)
	if u, ok := local_path_url(s); ok { return u }   // C:\..., \\server\share, ~ (local_paths.odin)
	looks_like_url := strings.contains(s, "://") || strings.has_prefix(s, "about:") || strings.has_prefix(s, "data:") ||
		strings.has_prefix(s, "view-source:") || strings.has_prefix(s, "file:")
	// a relative path (docs\a.html) names no folder for sure: words to search for
	if !looks_like_url && (strings.contains(s, " ") || !strings.contains(s, ".") || strings.contains(s, "\\")) && !strings.has_prefix(s, "localhost") {
		return search_url(&ix, s)
	}
	return s
}

////////////////////////////////
// Tabs

closed_tabs: [dynamic]string

closed_tabs_destroy :: proc() {
	for s in closed_tabs { delete(s) }
	delete(closed_tabs)
	closed_tabs = nil
}

// A tab closing (tab_close): its address can be reopened.
closed_tabs_push :: proc(address: string) {
	if address == "" || ix.closed_tabs_max <= 0 { return }
	append(&closed_tabs, strings.clone(address))
	for len(closed_tabs) > ix.closed_tabs_max { delete(closed_tabs[0]); ordered_remove(&closed_tabs, 0) }
}

reopen_closed_tab :: proc(app: ^App) {
	if len(closed_tabs) == 0 { return }
	address := pop(&closed_tabs)
	defer delete(address)
	open_in_new_tab(app, address, origin = .Replay)
}

// A link of the page followed (a click, Enter on it): a fragment of the same document scrolls, anything else navigates.
follow_link :: proc(app: ^App, t: ^Tab, href: string) {
	p := t.page
	if p == nil { return }
	resolved, ok := url.parse(href, &p.env.location, context.temp_allocator)
	if !ok { tab_log(t, .Error, fmt.tprintf("invalid link %q", href)); return }
	if page.follow_fragment_link(p, resolved) { return }
	navigate(app, t, resolved.href, p, user_activation = true)
}

// `origin` and `from` as in navigate: the default is a document's choice, which gets no privilege (nav_trust.odin).
open_in_new_tab :: proc(app: ^App, address: string, from: ^page.Page = nil, origin := Nav_Origin.Page) {
	keep := strings.clone(address, context.temp_allocator)
	tab_open(app, keep, from, origin)
}

close_other_tabs :: proc(app: ^App, keep: int) {
	t := app.tabs[keep]
	for i := len(app.tabs) - 1; i >= 0; i -= 1 {
		if app.tabs[i] != t { tab_close(app, i) }
	}
	for x, i in app.tabs { if x == t { app.current = i } }
	ui.field_set(&app.address, current_tab(app).url)
}

////////////////////////////////
// Images

@(private = "file")
copy_image :: proc(app: ^App, v: page.Image_View) {
	fp := page.frame_pixels(v.id, f64(host.now_ns(&app.loop)) / 1e6, v.pixel_size[0], v.pixel_size[1])
	if !fp.ok { return }
	if !clipboard_set_image(app, fp.pixels, fp.width, fp.height, fp.stride) { ui.toast(.Warn, "The image could not be copied") }
}

////////////////////////////////
// Save as (a download of the address, written where the Windows dialog says)

Save_Job :: struct {
	app:       ^App,
	url:       string,   // owned
	suggested: string,   // owned
	path:      string,   // owned: where to write (set by the dialog)
	task:      base.Handle,
	cleanup:   base.Cleanup_Id,   // the process scope frees the job if the browser closes during the download
	bytes:     []byte,   // owned: what was downloaded
	ok:        bool,
	message:   string,   // owned
}

@(private = "file")
savable :: proc(t: ^Tab) -> bool {
	return t.kind == .Web && t.page != nil && (strings.has_prefix(t.url, "http:") || strings.has_prefix(t.url, "https:") || strings.has_prefix(t.url, "file:") || strings.has_prefix(t.url, "data:"))
}

save_page :: proc(app: ^App, t: ^Tab) {
	if !savable(t) { return }
	name := t.title != "" ? t.title : "page"
	save_as(app, t.url, strings.concatenate({clean_file_name(name), ".html"}, context.temp_allocator))
}

// A file name from the last segment of a URL's path (or `fallback`).
suggested_name :: proc(address, fallback: string) -> string {
	s := address
	if i := strings.index_any(s, "?#"); i >= 0 { s = s[:i] }
	if i := strings.last_index_byte(s, '/'); i >= 0 { s = s[i + 1:] }
	if strings.has_prefix(address, "data:") || s == "" { s = fallback }
	return clean_file_name(s)
}

@(private = "file")
clean_file_name :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '\\', '/', ':', '*', '?', '"', '<', '>', '|': strings.write_rune(&sb, '_')
		case: if r >= 32 { strings.write_rune(&sb, r) }
		}
	}
	out := strings.trim_space(strings.to_string(sb))
	if len(out) > 120 { out = out[:120] }
	return out == "" ? "download" : out
}

// Asks where to save `address` (the system's Save dialog, on a worker thread), then downloads it there.
save_as :: proc(app: ^App, address, suggested: string) {
	job := new(Save_Job)
	job.app = app
	job.url = strings.clone(address)
	job.suggested = strings.clone(suggested)
	host.run_blocking(&app.blocking, save_dialog_work, save_dialog_done, job)
}

// Asks where to save `data` (the system's Save dialog, on a worker thread), then writes it there: what the browser already
// holds (a network log as HAR, a response body), with no download.
save_data_as :: proc(app: ^App, suggested: string, data: []byte) {
	job := new(Save_Job)
	job.app = app
	job.suggested = strings.clone(suggested)
	job.bytes = make([]byte, len(data))
	copy(job.bytes, data)
	host.run_blocking(&app.blocking, save_dialog_work, save_dialog_done, job)
}

@(private = "file")
save_job_free :: proc(job: ^Save_Job) {
	delete(job.url); delete(job.suggested); delete(job.path); delete(job.bytes); delete(job.message)
	free(job)
}

@(private = "file")
save_dialog_work :: proc(data: rawptr) {
	job := (^Save_Job)(data)
	if win.CoInitializeEx(nil, .APARTMENTTHREADED) < 0 { return }
	defer win.CoUninitialize()
	dlg: ^win.IFileSaveDialog
	if win.CoCreateInstance(win.CLSID_FileSaveDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileSaveDialog, cast(^rawptr)&dlg) < 0 || dlg == nil { return }
	defer dlg->Release()
	dlg->SetFileName(win.utf8_to_wstring(job.suggested, context.temp_allocator))
	ext := filepath.ext(job.suggested)
	if len(ext) > 1 {
		pattern := win.utf8_to_wstring(strings.concatenate({"*", ext}, context.temp_allocator), context.temp_allocator)
		label := win.utf8_to_wstring(strings.concatenate({strings.to_upper(ext[1:], context.temp_allocator), " file"}, context.temp_allocator), context.temp_allocator)
		types := [2]win.COMDLG_FILTERSPEC{{label, pattern}, {win.L("All files"), win.L("*.*")}}
		dlg->SetFileTypes(2, &types[0])
		dlg->SetDefaultExtension(win.utf8_to_wstring(ext[1:], context.temp_allocator))
	}
	if dlg->Show(job.app.win.hwnd) < 0 { free_all(context.temp_allocator); return }
	item: ^win.IShellItem
	if dlg->GetResult(&item) < 0 || item == nil { free_all(context.temp_allocator); return }
	defer item->Release()
	wpath: win.LPWSTR
	if item->GetDisplayName(.FILESYSPATH, &wpath) >= 0 && wpath != nil {
		n := 0
		for (cast([^]u16)wpath)[n] != 0 { n += 1 }
		if s, err := win.utf16_to_utf8((cast([^]u16)wpath)[:n], context.allocator); err == nil { job.path = s }
		win.CoTaskMemFree(wpath)
	}
	free_all(context.temp_allocator)
}

@(private = "file")
save_dialog_done :: proc(data: rawptr) {
	job := (^Save_Job)(data)
	app := job.app
	if job.path == "" { save_job_free(job); return }
	if job.url == "" {
		// data the browser holds: written without a download
		host.run_blocking(&app.blocking, proc(data: rawptr) {
			j := (^Save_Job)(data)
			j.ok = os.write_entire_file(j.path, j.bytes) == nil
		}, proc(data: rawptr) {
			j := (^Save_Job)(data)
			if j.ok { ui.toast(.Good, "Saved %s", filepath.base(j.path)) } else { ui.toast(.Bad, "Could not write %s", j.path) }
			j.app.frames_requested = max(j.app.frames_requested, 3)
			save_job_free(j)
		}, job)
		return
	}
	set_status_all(app, fmt.tprintf("Downloading %s…", job.url))
	job.task = fetch.start(&app.loader, {
		request = {url = job.url, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Empty},
		on_event = save_fetch_event, user = job, scope = app.process, collect = true,
	})
	job.cleanup = base.on_close(app.process, proc(data: rawptr) { save_job_free((^Save_Job)(data)) }, job)
}

@(private = "file")
save_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	job := (^Save_Job)(user)
	if ev.kind == .Done || ev.kind == .Failed { base.forget_cleanup(job.app.process, job.cleanup) }
	#partial switch ev.kind {
	case .Done:
		job.bytes = make([]byte, len(ev.data))
		copy(job.bytes, ev.data)
		host.run_blocking(&job.app.blocking, proc(data: rawptr) {
			j := (^Save_Job)(data)
			j.ok = os.write_entire_file(j.path, j.bytes) == nil
		}, proc(data: rawptr) {
			j := (^Save_Job)(data)
			if j.ok { ui.toast(.Good, "Saved %s", filepath.base(j.path)) } else { ui.toast(.Bad, "Could not write %s", j.path) }
			j.app.frames_requested = max(j.app.frames_requested, 3)
			save_job_free(j)
		}, job)
	case .Failed:
		ui.toast(.Bad, "Download failed: %s", ev.detail)
		save_job_free(job)
	}
	the_app.frames_requested = max(the_app.frames_requested, 3)
}

@(private = "file")
set_status_all :: proc(app: ^App, s: string) {
	if t := current_tab(app); t != nil { set_status(t, s) }
}

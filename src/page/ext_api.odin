package page

// The extension APIs of phases 1 and 2 (docs/extensions.md, section 2.2 "Start", "Log in and unlock"). Their
// description is api/ext_<namespace>.widl: bindgen makes from it the tables (EXT_METHODS, EXT_EVENTS, EXT_LOCALS,
// EXT_NAMESPACES), the decoders of the arguments and the trampolines to the implementations below
// (ext_api_generated.odin, on ext_decode.odin). ext_info_json lists what a context may use (its chrome.* is built from
// that list: an API outside it is `undefined`); ext_dispatch checks the same rule before it runs anything (ext_allowed:
// the one gate). Arguments arrive as a JSON list, decoded into the method's struct before its implementation runs;
// answers leave as JSON text ("" : undefined, "!" : an error's message). Phase 2's are in ext_tabs.odin (tabs and
// windows that change, runtime.getContexts / reload / openOptionsPage, their events), ext_offscreen.odin and
// ext_idle.odin. Phase 3's: ext_scripting.odin, ext_webnavigation.odin, tabs.sendMessage in ext_tabs.odin; the content
// scripts themselves in ext_inject.odin and ext_worlds.odin.
//
// Not here yet (later phases): webRequest, contextMenus, commands, notifications, dom.openOrClosedShadowRoot,
// tabs.captureVisibleTab, permissions.request (answers false).

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:extensions"
import "wb:host"

Ext_Call :: struct {
	c:        ^Ext_Context,
	e:        ^extensions.Extension,
	reg:      ^extensions.Registry,
	method:   string,
	args:     json.Array,   // as they came (the trampoline decodes them for the implementation)
	to:       Ext_Target,
	answered: bool,
}

// The gate (rule 2 of section 3.11), for a method, an event or a member the realm answers: the kind of context may use
// it, the manifest has what it acts on, and the permission is in the manifest (every required permission is granted at
// install).
ext_allowed :: proc(im: ^extensions.Image, kind: Ext_Kind, contexts: Ext_Contexts, permission: string, action: bool) -> bool {
	if kind not_in contexts { return false }
	if action && !im.manifest.has_action { return false }
	if permission != "" && !extensions.manifest_has_permission(&im.manifest, permission) { return false }
	return true
}

ext_method_find :: proc(name: string) -> ^Ext_Method {
	for &m in EXT_METHODS { if m.name == name { return &m } }
	return nil
}

// Ext_info's answer: what a context of `kind` of this extension may use, and the constants of its namespaces (temp
// allocator).
ext_info_json :: proc(im: ^extensions.Image, kind: Ext_Kind) -> string {
	b := strings.builder_make(context.temp_allocator)
	names := make([dynamic]string, 0, 64, context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":%s,"kind":%s,"base":%s,"flavour":%s,"lang":%s,"methods":[`, extensions.json_quote(im.id), extensions.json_quote(EXT_KIND_NAMES[kind]),
		extensions.json_quote(im.base_url), extensions.json_quote(extensions.FLAVOUR_NAMES[im.manifest.flavour]), extensions.json_quote(im.language))
	first := true
	for m in EXT_METHODS {
		if !ext_allowed(im, kind, m.contexts, m.permission, m.action) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		strings.write_string(&b, extensions.json_quote(m.name))
		append(&names, m.name)
	}
	list :: proc(b: ^strings.Builder, names: ^[dynamic]string, im: ^extensions.Image, kind: Ext_Kind, members: []Ext_Member) {
		first := true
		for m in members {
			if !ext_allowed(im, kind, m.contexts, m.permission, m.action) { continue }
			if !first { strings.write_byte(b, ',') }
			first = false
			strings.write_string(b, extensions.json_quote(m.name))
			append(names, m.name)
		}
	}
	strings.write_string(&b, `],"events":[`)
	list(&b, &names, im, kind, EXT_EVENTS[:])
	strings.write_string(&b, `],"local":[`)
	list(&b, &names, im, kind, EXT_LOCALS[:])
	// the constants of the namespaces this context has (a namespace exists when one of its members does)
	strings.write_string(&b, `],"constants":{`)
	first = true
	for ns in EXT_NAMESPACES {
		prefix := strings.concatenate({ns.name, "."}, context.temp_allocator)
		has := false
		for n in names { if strings.has_prefix(n, prefix) { has = true; break } }
		if !has { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		strings.write_string(&b, extensions.json_quote(ns.name))
		strings.write_byte(&b, ':')
		strings.write_string(&b, ns.constants)
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// Runs one call of context `c` (the loop thread). Every call is answered exactly once, now or later (sendMessage).
ext_dispatch :: proc(c: ^Ext_Context, method, args: string, to: Ext_Target) {
	reg := ext_registry()
	e := extensions.registry_running(reg, extensions.SCHEME_CHROME, c.ext)
	if e == nil { ext_answer(to, "!the extension does not run"); return }
	m := ext_method_find(method)
	if m == nil {
		// counted once by name (about:extensions lists them: the measure of section 5 "API gaps")
		if method not_in e.unknown_calls && len(method) <= 128 { e.unknown_calls[strings.clone(method)] = true; extensions.registry_changed(reg) }
		ext_answer(to, fmt.tprintf("!%s is not supported", method))
		return
	}
	if !ext_allowed(e.image, c.kind, m.contexts, m.permission, m.action) {
		ext_answer(to, fmt.tprintf("!%s is not allowed in this context (permission %q)", method, m.permission))
		return
	}
	if reg.settings.message_max_bytes > 0 && len(args) > reg.settings.message_max_bytes {
		ext_answer(to, "!the arguments are larger than extensions.message.max_bytes")
		return
	}
	v, err := json.parse_string(args, .JSON, false, context.temp_allocator)
	arr, ok := v.(json.Array)
	if err != .None || !ok { ext_answer(to, fmt.tprintf("!Error in invocation of %s: the arguments are not a list", method)); return }
	x := Ext_Call{c = c, e = e, reg = reg, method = method, args = arr, to = to}
	m.invoke(&x)   // decodes the arguments (an error answers the call), then runs the implementation
	if !x.answered { ext_ok(&x, "") }
}

////////////////////////////////
// Helpers

ext_ok :: proc(x: ^Ext_Call, text: string) {
	if x.answered { return }
	x.answered = true
	ext_answer(x.to, text)
}

ext_fail :: proc(x: ^Ext_Call, message: string) { ext_ok(x, strings.concatenate({"!", message}, context.temp_allocator)) }

@(private)
jbool_text :: proc(b: bool) -> string { return b ? "true" : "false" }

////////////////////////////////
// runtime

ext_runtime_send_message :: proc(x: ^Ext_Call, a: Ext_Runtime_Send_Message_Args) {
	x.answered = true   // (answered by the receivers, or by ext_send_message when there is none)
	ext_send_message(x.c, extensions.json_text(a.message), x.to)
}

ext_runtime_get_platform_info :: proc(x: ^Ext_Call) {
	os_name := "linux"
	when ODIN_OS == .Windows { os_name = "win" }
	when ODIN_OS == .Darwin { os_name = "mac" }
	arch := "x86-64"
	when ODIN_ARCH == .arm64 { arch = "arm64" }
	ext_ok(x, fmt.tprintf(`{{"os":"%s","arch":"%s","nacl_arch":"%s"}}`, os_name, arch, arch))
}

// (no page opens when the extension is removed: the URL is not kept)
ext_runtime_set_uninstall_url :: proc(x: ^Ext_Call, a: Ext_Runtime_Set_Uninstall_Url_Args) { ext_ok(x, "") }

////////////////////////////////
// storage

@(private)
ext_area :: proc(x: ^Ext_Call) -> (^extensions.Area, extensions.Area_Kind) {
	parts := strings.split(x.method, ".", context.temp_allocator)
	name := len(parts) > 1 ? parts[1] : ""
	switch name {
	case "local":   return &x.e.local, .Local
	case "sync":    return &x.e.sync, .Sync
	case "session": return &x.e.session, .Session
	}
	return nil, .Managed
}

// The keys an argument names: absent: all (all = true); a string; a list of strings; an object (its keys, with
// defaults).
@(private)
ext_keys_of :: proc(k: Ext_Storage_Keys) -> (keys: []string, defaults: json.Object, all: bool) {
	switch v in k {
	case nil: return nil, nil, true
	case string:
		out := make([]string, 1, context.temp_allocator)
		out[0] = v
		return out, nil, false
	case []string: return v, nil, false
	case json.Object:
		out := make([dynamic]string, 0, len(v), context.temp_allocator)
		for key in v { append(&out, key) }
		return out[:], v, false
	}
	return nil, nil, true
}

ext_storage_get :: proc(x: ^Ext_Call, a: Ext_Storage_Get_Args) {
	area, _ := ext_area(x)
	if area == nil { ext_ok(x, "{}"); return }   // managed: empty (no policy sets it)
	keys, defaults, all := ext_keys_of(a.keys)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	first := true
	item :: proc(b: ^strings.Builder, first: ^bool, k, v: string) {
		if !first^ { strings.write_byte(b, ',') }
		first^ = false
		strings.write_string(b, extensions.json_quote(k))
		strings.write_byte(b, ':')
		strings.write_string(b, v)
	}
	if all {
		for k, v in area.items { item(&b, &first, k, v) }
	} else {
		for k in keys {
			if v, has := area.items[k]; has {
				item(&b, &first, k, v)
			} else if defaults != nil {
				item(&b, &first, k, extensions.json_text(defaults[k]))
			}
		}
	}
	strings.write_byte(&b, '}')
	ext_ok(x, strings.to_string(b))
}

// storage.onChanged and storage.<area>.onChanged for `changes` (none: no event), then the area is saved.
@(private)
ext_storage_changed :: proc(x: ^Ext_Call, kind: extensions.Area_Kind, changes: []extensions.Area_Change) {
	if len(changes) == 0 { return }
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for ch, i in changes {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, extensions.json_quote(ch.key))
		strings.write_string(&b, ":{")
		if ch.had { strings.write_string(&b, `"oldValue":`); strings.write_string(&b, ch.old) }
		if ch.has { if ch.had { strings.write_byte(&b, ',') }; strings.write_string(&b, `"newValue":`); strings.write_string(&b, ch.new) }
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, '}')
	changes_json := strings.to_string(b)
	area := extensions.AREA_NAMES[kind]
	ext_emit(x.e.id, "storage.onChanged", fmt.tprintf("[%s,%s]", changes_json, extensions.json_quote(area)))
	ext_emit(x.e.id, fmt.tprintf("storage.%s.onChanged", area), fmt.tprintf("[%s]", changes_json))
	if kind != .Session { ext_storage_save_soon() }
}

// How long after a change the areas are written: a burst of writes makes one text per area, not one per write (the
// text is the whole area: made on the loop thread, it is made at most this often).
EXT_STORAGE_SAVE_DELAY_MS :: 500

@(private)
ext_storage_save_soon :: proc() {
	r := ext_router()
	loop := r.loop != nil ? r.loop : the_pages.sw_registry.loop
	if loop == nil { ext_storage_save_all(); return }
	r.loop = loop
	if r.save_timer != base.NIL_HANDLE { return }
	r.save_timer = host.set_timer(loop, EXT_STORAGE_SAVE_DELAY_MS, 0, proc(_: rawptr) {
		ext_router().save_timer = base.NIL_HANDLE
		ext_storage_save_all()
	}, nil)
}

// Every area that changed goes to the shell's writer (off the loop thread).
ext_storage_save_all :: proc() {
	reg := ext_registry()
	for e in reg.list { extensions.registry_save_areas(reg, e) }
}

ext_storage_set :: proc(x: ^Ext_Call, a: Ext_Storage_Set_Args) {
	area, kind := ext_area(x)
	if area == nil { ext_fail(x, "storage.managed is read-only"); return }
	keys := make([dynamic]string, 0, len(a.items), context.temp_allocator)
	values := make([dynamic]string, 0, len(a.items), context.temp_allocator)
	for k, v in a.items {
		append(&keys, k)
		append(&values, extensions.json_text(v))
	}
	changes, err := extensions.area_set(area, keys[:], values[:])
	if err != .None { ext_fail(x, extensions.area_error_text(err)); return }
	ext_storage_changed(x, kind, changes)
	ext_ok(x, "")
}

ext_storage_remove :: proc(x: ^Ext_Call, a: Ext_Storage_Remove_Args) {
	area, kind := ext_area(x)
	if area == nil { ext_fail(x, "storage.managed is read-only"); return }
	keys, _, all := ext_keys_of(a.keys)
	if all { ext_fail(x, "Error in invocation of storage.remove: keys must be a string or a list of strings"); return }
	ext_storage_changed(x, kind, extensions.area_remove(area, keys))
	ext_ok(x, "")
}

ext_storage_clear :: proc(x: ^Ext_Call) {
	area, kind := ext_area(x)
	if area == nil { ext_fail(x, "storage.managed is read-only"); return }
	ext_storage_changed(x, kind, extensions.area_clear(area))
	ext_ok(x, "")
}

ext_storage_bytes :: proc(x: ^Ext_Call, a: Ext_Storage_Bytes_Args) {
	area, _ := ext_area(x)
	if area == nil { ext_ok(x, "0"); return }
	keys, _, all := ext_keys_of(a.keys)
	ext_ok(x, fmt.tprintf("%d", extensions.area_bytes_of(area, all ? nil : keys)))
}

// (content scripts keep no access to storage.session whatever the level: the gate's rule)
ext_storage_session_set_access_level :: proc(x: ^Ext_Call, a: Ext_Storage_Session_Set_Access_Level_Args) { ext_ok(x, "") }

ext_storage_keys :: proc(x: ^Ext_Call) {
	a, _ := ext_area(x)
	if a == nil { ext_ok(x, "[]"); return }
	keys := make([dynamic]string, 0, len(a.items), context.temp_allocator)
	for k in a.items { append(&keys, k) }
	slice.sort(keys[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for k, i in keys { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(k)) }
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

////////////////////////////////
// tabs and windows (the shell describes them: Ext_Embedder)

@(private)
ext_tabs_list :: proc() -> []Ext_Tab_Info {
	out := make([dynamic]Ext_Tab_Info, 0, 16, context.temp_allocator)
	if em := &ext_router().embedder; em.tabs != nil { em.tabs(em.user, &out) }
	return out[:]
}

@(private)
ext_windows_list :: proc() -> []Ext_Window_Info {
	out := make([dynamic]Ext_Window_Info, 0, 4, context.temp_allocator)
	if em := &ext_router().embedder; em.windows != nil { em.windows(em.user, &out) }
	return out[:]
}

// The window a context calls "current": its tab's, else the focused one.
@(private)
ext_current_window :: proc(x: ^Ext_Call) -> i64 {
	if x.c.page != 0 { for t in ext_tabs_list() { if t.page == x.c.page { return t.window } } }
	if em := &ext_router().embedder; em.focused_window != nil { return em.focused_window(em.user) }
	return -1
}

// Whether the extension may see a tab's URL and title: the tabs permission, a host grant for its URL, or its own page.
@(private)
ext_may_see :: proc(x: ^Ext_Call, href: string) -> bool { return ext_may_see_of(x.reg, x.e, href) }

// (the same for an event, which has no call: ext_tabs.odin)
ext_may_see_of :: proc(reg: ^extensions.Registry, e: ^extensions.Extension, href: string) -> bool {
	if extensions.manifest_has_permission(&e.image.manifest, "tabs") { return true }
	if strings.has_prefix(href, e.image.base_url) { return true }
	return extensions.extension_host_allowed(reg, e, href)
}

@(private)
ext_tab_json :: proc(b: ^strings.Builder, x: ^Ext_Call, t: Ext_Tab_Info) { ext_tab_json_of(b, x.reg, x.e, t) }

ext_tab_json_of :: proc(b: ^strings.Builder, reg: ^extensions.Registry, e: ^extensions.Extension, t: Ext_Tab_Info) {
	fmt.sbprintf(b, `{{"id":%d,"index":%d,"windowId":%d,"active":%s,"highlighted":%s,"selected":%s,"pinned":%s,"incognito":false,"discarded":false,"autoDiscardable":true,"frozen":false,"groupId":-1,"audible":false,"mutedInfo":{{"muted":false}},"status":"%s"`,
		t.id, t.index, t.window, jbool_text(t.active), jbool_text(t.active), jbool_text(t.active), jbool_text(t.pinned), t.loading ? "loading" : "complete")
	if ext_may_see_of(reg, e, t.url) {
		fmt.sbprintf(b, `,"url":%s,"title":%s`, extensions.json_quote(t.url), extensions.json_quote(t.title))
	}
	strings.write_byte(b, '}')
}

ext_tabs_query :: proc(x: ^Ext_Call, a: Ext_Tabs_Query_Args) {
	q, _ := a.query_info.?
	want_window := i64(-1)
	if v, ok := q.current_window.?; ok && v { want_window = ext_current_window(x) }
	if v, ok := q.last_focused_window.?; ok && v {
		if em := &ext_router().embedder; em.focused_window != nil { want_window = em.focused_window(em.user) }
	}
	if n, ok := q.window_id.?; ok { want_window = n == -2 ? ext_current_window(x) : n }
	patterns := make([dynamic]extensions.Pattern, 0, 4, context.temp_allocator)
	has_url := false
	switch u in q.url {
	case nil:
	case string:
		has_url = true
		if p, ok := extensions.pattern_parse(u); ok { append(&patterns, p) }
	case []string:
		has_url = true
		for s in u { if p, ok := extensions.pattern_parse(s); ok { append(&patterns, p) } }
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for t in ext_tabs_list() {
		if v, ok := q.active.?; ok && v != t.active { continue }
		if v, ok := q.highlighted.?; ok && v != t.active { continue }
		if v, ok := q.pinned.?; ok && v != t.pinned { continue }
		if s, ok := q.status.?; ok && s != (t.loading ? "loading" : "complete") { continue }
		if n, ok := q.index.?; ok && n != t.index { continue }
		if want_window >= 0 && t.window != want_window { continue }
		if has_url && (!ext_may_see(x, t.url) || !extensions.patterns_match_href(patterns[:], t.url)) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		ext_tab_json(&b, x, t)
	}
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

ext_tabs_get :: proc(x: ^Ext_Call, a: Ext_Tabs_Get_Args) {
	for t in ext_tabs_list() {
		if t.id != a.tab_id { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_tab_json(&b, x, t)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_fail(x, fmt.tprintf("No tab with id: %d.", a.tab_id))
}

// The tab of the calling page (undefined for a popup or the background, as in Chrome).
ext_tabs_get_current :: proc(x: ^Ext_Call) {
	if x.c.kind != .Tab { ext_ok(x, ""); return }
	for t in ext_tabs_list() {
		if t.page != x.c.page { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_tab_json(&b, x, t)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_ok(x, "")
}

@(private)
ext_window_json :: proc(b: ^strings.Builder, x: ^Ext_Call, w: Ext_Window_Info, populate: bool) { ext_window_json_of(b, x.reg, x.e, w, populate) }

ext_window_json_of :: proc(b: ^strings.Builder, reg: ^extensions.Registry, e: ^extensions.Extension, w: Ext_Window_Info, populate: bool) {
	fmt.sbprintf(b, `{{"id":%d,"focused":%s,"top":%d,"left":%d,"width":%d,"height":%d,"incognito":false,"type":"%s","state":%s,"alwaysOnTop":false`,
		w.id, jbool_text(w.focused), w.top, w.left, w.width, w.height, w.popup ? "popup" : "normal", extensions.json_quote(w.state != "" ? w.state : "normal"))
	if populate {
		strings.write_string(b, `,"tabs":[`)
		first := true
		for t in ext_tabs_list() {
			if t.window != w.id { continue }
			if !first { strings.write_byte(b, ',') }
			first = false
			ext_tab_json_of(b, reg, e, t)
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '}')
}

@(private)
ext_window_answer :: proc(x: ^Ext_Call, id: i64, populate: bool) {
	for w in ext_windows_list() {
		if w.id != id { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_window_json(&b, x, w, populate)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_fail(x, fmt.tprintf("No window with id: %d.", id))
}

@(private)
ext_populate :: proc(options: Maybe(Ext_Windows_Query_Options)) -> bool {
	o, _ := options.?
	p, _ := o.populate.?
	return p
}

ext_windows_get_current :: proc(x: ^Ext_Call, a: Ext_Windows_Get_Current_Args) {
	ext_window_answer(x, ext_current_window(x), ext_populate(a.query_options))
}

ext_windows_get_last_focused :: proc(x: ^Ext_Call, a: Ext_Windows_Get_Last_Focused_Args) {
	id := ext_current_window(x)
	if em := &ext_router().embedder; em.focused_window != nil { id = em.focused_window(em.user) }
	ext_window_answer(x, id, ext_populate(a.query_options))
}

ext_windows_get :: proc(x: ^Ext_Call, a: Ext_Windows_Get_Args) {
	id := a.window_id
	if id == -2 { id = ext_current_window(x) }
	ext_window_answer(x, id, ext_populate(a.query_options))
}

ext_windows_get_all :: proc(x: ^Ext_Call, a: Ext_Windows_Get_All_Args) {
	populate := ext_populate(a.query_options)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for w, i in ext_windows_list() {
		if i > 0 { strings.write_byte(&b, ',') }
		ext_window_json(&b, x, w, populate)
	}
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

////////////////////////////////
// action (the toolbar button: src/browser/ext_toolbar.odin draws what is set here)

@(private)
ext_action_changed :: proc(x: ^Ext_Call) {
	extensions.registry_changed(x.reg)
	if em := &ext_router().embedder; em.changed != nil { em.changed(em.user, x.e.id) }
}

@(private)
ext_set_text :: proc(slot: ^string, v: string) { delete(slot^); slot^ = strings.clone(v) }

@(private)
ext_set_maybe :: proc(slot: ^Maybe(string), v: string) {
	if s, ok := slot.?; ok { delete(s) }
	slot^ = strings.clone(v)
}

// "#rrggbb", "#rgb", "rgb(...)" names are not parsed here: a colour list [r, g, b, a] or a hex text.
@(private)
ext_color_of :: proc(c: Ext_Action_Color_Array) -> ([4]u8, bool) {
	switch v in c {
	case nil:
	case []i64:
		if len(v) < 3 { return {}, false }
		out := [4]u8{0, 0, 0, 255}
		for i in 0 ..< min(len(v), 4) { out[i] = u8(clamp(v[i], 0, 255)) }
		return out, true
	case string:
		s := strings.trim_prefix(v, "#")
		hex :: proc(ch: u8) -> (u8, bool) {
			switch ch {
			case '0' ..= '9': return ch - '0', true
			case 'a' ..= 'f': return ch - 'a' + 10, true
			case 'A' ..= 'F': return ch - 'A' + 10, true
			}
			return 0, false
		}
		if len(s) == 6 || len(s) == 3 {
			out := [4]u8{0, 0, 0, 255}
			for i in 0 ..< 3 {
				hi, lo: u8
				ok1, ok2: bool
				if len(s) == 6 { hi, ok1 = hex(s[2 * i]); lo, ok2 = hex(s[2 * i + 1]) } else { hi, ok1 = hex(s[i]); lo, ok2 = hi, ok1 }
				if !ok1 || !ok2 { return {}, false }
				out[i] = hi * 16 + lo
			}
			return out, true
		}
	}
	return {}, false
}

// The state of tab `tab` that a setter writes (made when absent); nil: no tab named (the default of every tab).
@(private)
ext_action_slot :: proc(x: ^Ext_Call, tab: Maybe(i64)) -> ^extensions.Action_Tab {
	id, ok := tab.?
	if !ok || id < 0 { return nil }
	a := &x.e.action
	if u64(id) not_in a.tabs { a.tabs[u64(id)] = {} }
	slot, _ := &a.tabs[u64(id)]
	return slot
}

// The state of the tab a getter names (nil: none, or nothing set for it).
@(private)
ext_action_find :: proc(x: ^Ext_Call, details: Maybe(Ext_Action_Tab_Details)) -> ^extensions.Action_Tab {
	d, _ := details.?
	id, ok := d.tab_id.?
	if !ok { return nil }
	slot, found := &x.e.action.tabs[u64(id)]
	return found ? slot : nil
}

ext_action_set_title :: proc(x: ^Ext_Call, a: Ext_Action_Set_Title_Args) {
	if per := ext_action_slot(x, a.details.tab_id); per != nil { ext_set_maybe(&per.title, a.details.title) } else { ext_set_text(&x.e.action.title, a.details.title) }
	ext_action_changed(x)
}

ext_action_set_popup :: proc(x: ^Ext_Call, a: Ext_Action_Set_Popup_Args) {
	p := a.details.popup
	rel := ""
	if p != "" {
		if strings.has_prefix(p, x.e.image.base_url) { p = p[len(x.e.image.base_url):] }
		n, nok := extensions.package_path_normalize(p, context.temp_allocator)
		if !nok || !extensions.image_has_file(x.e.image, n) { ext_fail(x, fmt.tprintf("the popup %q is not a file of the extension", p)); return }
		rel = n
	}
	if per := ext_action_slot(x, a.details.tab_id); per != nil { ext_set_maybe(&per.popup, rel) } else { ext_set_text(&x.e.action.popup, rel) }
	ext_action_changed(x)
}

ext_action_set_badge_text :: proc(x: ^Ext_Call, a: Ext_Action_Set_Badge_Text_Args) {
	t := a.details.text.? or_else ""
	if len(t) > 64 { t = t[:64] }   // (the button shows 4 characters; a longer text is cut here, not kept)
	if per := ext_action_slot(x, a.details.tab_id); per != nil { ext_set_maybe(&per.badge, t) } else { ext_set_text(&x.e.action.badge, t) }
	ext_action_changed(x)
}

ext_action_set_badge_background_color :: proc(x: ^Ext_Call, a: Ext_Action_Set_Badge_Background_Color_Args) {
	col, ok := ext_color_of(a.details.color)
	if !ok { ext_fail(x, "action.setBadgeBackgroundColor: color must be a list [r, g, b, a] or a #rrggbb text"); return }
	if per := ext_action_slot(x, a.details.tab_id); per != nil { per.badge_color = col } else { x.e.action.badge_color = col }
	ext_action_changed(x)
}

// (the text keeps its colour: the toolbar draws it in one colour)
ext_action_set_badge_text_color :: proc(x: ^Ext_Call, a: Ext_Action_Set_Badge_Text_Color_Args) { ext_ok(x, "") }

ext_action_set_icon :: proc(x: ^Ext_Call, a: Ext_Action_Set_Icon_Args) {
	path := ""
	switch p in a.details.path {
	case nil:
	case string: path = p
	case json.Object:
		best := 0
		for size, v in p {
			s, sok := v.(json.String)
			n := 0
			for ch in transmute([]byte)size { if ch >= '0' && ch <= '9' { n = n * 10 + int(ch - '0') } }
			if sok && (path == "" || (n >= 16 && n <= 32 && n > best)) { path, best = s, n }
		}
	}
	per := ext_action_slot(x, a.details.tab_id)
	if path != "" {
		n, nok := extensions.package_path_normalize(path, context.temp_allocator)
		if !nok || !extensions.image_has_file(x.e.image, n) { ext_fail(x, fmt.tprintf("the icon %q is not a file of the extension", path)); return }
		if per != nil { ext_set_maybe(&per.icon, n) } else { ext_set_text(&x.e.action.icon, n) }
	}
	// (imageData: an icon drawn by the extension; shown when the toolbar can show pixels it is given)
	ext_action_changed(x)
}

@(private)
ext_action_switch :: proc(x: ^Ext_Call, tab: Maybe(i64), on: bool) {
	if _, per_tab := tab.?; per_tab { return }   // per tab: the button stays as it is for now
	if x.e.action.enabled != on { x.e.action.enabled = on; ext_action_changed(x) }
}

ext_action_enable :: proc(x: ^Ext_Call, a: Ext_Action_Enable_Args) { ext_action_switch(x, a.tab_id, true) }

ext_action_disable :: proc(x: ^Ext_Call, a: Ext_Action_Disable_Args) { ext_action_switch(x, a.tab_id, false) }

ext_action_is_enabled :: proc(x: ^Ext_Call, a: Ext_Action_Is_Enabled_Args) { ext_ok(x, jbool_text(x.e.action.enabled)) }

ext_action_get_user_settings :: proc(x: ^Ext_Call) { ext_ok(x, `{"isOnToolbar":true}`) }

ext_action_get_title :: proc(x: ^Ext_Call, a: Ext_Action_Get_Title_Args) {
	t := x.e.action.title
	if per := ext_action_find(x, a.details); per != nil { if s, ok := per.title.?; ok { t = s } }
	ext_ok(x, extensions.json_quote(t))
}

ext_action_get_popup :: proc(x: ^Ext_Call, a: Ext_Action_Get_Popup_Args) {
	p := x.e.action.popup
	if per := ext_action_find(x, a.details); per != nil { if s, ok := per.popup.?; ok { p = s } }
	ext_ok(x, extensions.json_quote(p != "" ? extensions.image_url(x.e.image, p) : ""))
}

ext_action_get_badge_text :: proc(x: ^Ext_Call, a: Ext_Action_Get_Badge_Text_Args) {
	t := x.e.action.badge
	if per := ext_action_find(x, a.details); per != nil { if s, ok := per.badge.?; ok { t = s } }
	ext_ok(x, extensions.json_quote(t))
}

ext_action_get_badge_background_color :: proc(x: ^Ext_Call, a: Ext_Action_Get_Badge_Background_Color_Args) {
	c := x.e.action.badge_color
	if per := ext_action_find(x, a.details); per != nil { if s, ok := per.badge_color.?; ok { c = s } }
	ext_ok(x, fmt.tprintf("[%d,%d,%d,%d]", c[0], c[1], c[2], c[3]))
}

// What the toolbar shows for `tab` (temp strings): its title, popup (a package path), badge and colour, icon path.
ext_action_view :: proc(e: ^extensions.Extension, tab: u64) -> (title, popup, badge: string, color: [4]u8, icon: string) {
	a := &e.action
	title, popup, badge, color, icon = a.title, a.popup, a.badge, a.badge_color, a.icon
	if per, ok := &a.tabs[tab]; ok {
		if s, has := per.title.?; has { title = s }
		if s, has := per.popup.?; has { popup = s }
		if s, has := per.badge.?; has { badge = s }
		if c, has := per.badge_color.?; has { color = c }
		if s, has := per.icon.?; has { icon = s }
	}
	if icon == "" && e.image != nil {
		icons := e.image.manifest.action.icons
		if len(icons) == 0 { icons = e.image.manifest.icons }
		for ic in icons { icon = ic.path; if ic.size >= 16 { break } }
	}
	return
}

// A tab closed: its per-tab action state goes (the shell calls it for each extension).
ext_action_tab_closed :: proc(tab: u64) {
	for e in ext_registry().list {
		if per, ok := &e.action.tabs[tab]; ok {
			extensions.action_tab_destroy(per)
			delete_key(&e.action.tabs, tab)
		}
	}
}

////////////////////////////////
// alarms

@(private)
ext_now_ms :: proc() -> f64 { return f64(time.time_to_unix_nano(time.now())) / 1e6 }

@(private)
ext_alarm_json :: proc(b: ^strings.Builder, al: extensions.Alarm) {
	fmt.sbprintf(b, `{{"name":%s,"scheduledTime":%.0f`, extensions.json_quote(al.name), al.when_ms)
	if al.period_ms > 0 { fmt.sbprintf(b, `,"periodInMinutes":%v`, al.period_ms / 60000) }
	strings.write_byte(b, '}')
}

ext_alarms_create :: proc(x: ^Ext_Call, a: Ext_Alarms_Create_Args) {
	name := a.name.? or_else ""
	info, _ := a.alarm_info.?
	min_ms := f64(x.reg.settings.alarms_min_period_ms)
	now := ext_now_ms()
	period, delay := 0.0, -1.0
	if p, ok := info.period_in_minutes.?; ok { period = max(p * 60000, min_ms) }
	when_ms := -1.0
	if w, ok := info.when_.?; ok { when_ms = w }
	if d, ok := info.delay_in_minutes.?; ok { delay = max(d * 60000, min_ms) }
	switch {
	case when_ms >= 0:
	case delay >= 0: when_ms = now + delay
	case period > 0: when_ms = now + period
	case: when_ms = now + min_ms
	}
	if math.is_nan(when_ms) { ext_fail(x, "alarms.create: invalid time"); return }
	// the same name replaces the alarm before it
	for al, i in x.e.alarms { if al.name == name { delete(al.name); ordered_remove(&x.e.alarms, i); break } }
	if x.reg.settings.alarms_max > 0 && len(x.e.alarms) >= x.reg.settings.alarms_max { ext_fail(x, "too many alarms (extensions.alarms.max_per_extension)"); return }
	append(&x.e.alarms, extensions.Alarm{name = strings.clone(name), when_ms = when_ms, period_ms = period})
	ext_alarms_schedule()
	ext_ok(x, "")
}

ext_alarms_get :: proc(x: ^Ext_Call, a: Ext_Alarms_Get_Args) {
	name := a.name.? or_else ""
	for al in x.e.alarms {
		if al.name != name { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_alarm_json(&b, al)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_ok(x, "")
}

ext_alarms_get_all :: proc(x: ^Ext_Call) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for al, i in x.e.alarms { if i > 0 { strings.write_byte(&b, ',') }; ext_alarm_json(&b, al) }
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

ext_alarms_clear :: proc(x: ^Ext_Call, a: Ext_Alarms_Clear_Args) {
	name := a.name.? or_else ""
	cleared := false
	for al, i in x.e.alarms { if al.name == name { delete(al.name); ordered_remove(&x.e.alarms, i); cleared = true; break } }
	ext_alarms_schedule()
	ext_ok(x, jbool_text(cleared))
}

ext_alarms_clear_all :: proc(x: ^Ext_Call) {
	cleared := len(x.e.alarms) > 0
	for al in x.e.alarms { delete(al.name) }
	clear(&x.e.alarms)
	ext_alarms_schedule()
	ext_ok(x, jbool_text(cleared))
}

// One timer for the soonest alarm of every extension (set again after each change and each firing).
ext_alarms_schedule :: proc() {
	r := ext_router()
	loop := r.loop != nil ? r.loop : the_pages.sw_registry.loop
	if loop == nil { return }
	r.loop = loop
	if r.alarm_timer != base.NIL_HANDLE { host.clear_timer(loop, r.alarm_timer); r.alarm_timer = base.NIL_HANDLE }
	soonest := math.F64_MAX
	for e in ext_registry().list {
		if !e.enabled { continue }
		for al in e.alarms { soonest = min(soonest, al.when_ms) }
	}
	if soonest == math.F64_MAX { return }
	delay := max(soonest - ext_now_ms(), 0)
	r.alarm_timer = host.set_timer(loop, delay, 0, proc(_: rawptr) {
		ext_router().alarm_timer = base.NIL_HANDLE
		ext_alarms_fire()
	}, nil)
}

@(private)
ext_alarms_fire :: proc() {
	now := ext_now_ms()
	for e in ext_registry().list {
		if !e.enabled || e.image == nil || !e.image.ok { continue }
		i := 0
		for i < len(e.alarms) {
			al := &e.alarms[i]
			if al.when_ms > now + 1 { i += 1; continue }
			b := strings.builder_make(context.temp_allocator)
			strings.write_byte(&b, '[')
			ext_alarm_json(&b, al^)
			strings.write_byte(&b, ']')
			ext_emit(e.id, "alarms.onAlarm", strings.to_string(b))
			if al.period_ms > 0 {
				for al.when_ms <= now { al.when_ms += al.period_ms }
				i += 1
			} else {
				delete(al.name)
				ordered_remove(&e.alarms, i)
			}
		}
	}
	ext_alarms_schedule()
}

////////////////////////////////
// permissions and management

// Whether a granted pattern covers the asked one: <all_urls>, the same text, or a wider scheme, host and path.
@(private)
ext_pattern_covers :: proc(g, p: extensions.Pattern) -> bool {
	if g.all_urls { return true }
	if g.source == p.source { return true }
	if p.all_urls { return false }
	if g.scheme != "*" && g.scheme != p.scheme { return false }
	if g.scheme == "*" && p.scheme != "*" && p.scheme != "http" && p.scheme != "https" { return false }
	switch {
	case g.any_host:
	case p.any_host: return false
	case g.subdomains:
		if !(p.host == g.host || strings.has_suffix(p.host, strings.concatenate({".", g.host}, context.temp_allocator))) { return false }
	case:
		if p.subdomains || p.host != g.host { return false }
	}
	return extensions.glob_match(g.path, p.path)
}

ext_permissions_get_all :: proc(x: ^Ext_Call) {
	m := &x.e.image.manifest
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"permissions":[`)
	for p, i in m.permissions { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(p)) }
	strings.write_string(&b, `],"origins":[`)
	for g, i in x.e.granted { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(g)) }
	strings.write_string(&b, "]}")
	ext_ok(x, strings.to_string(b))
}

ext_permissions_contains :: proc(x: ^Ext_Call, a: Ext_Permissions_Contains_Args) {
	m := &x.e.image.manifest
	d, _ := a.permissions.?
	if perms, ok := d.permissions.?; ok {
		for s in perms { if !extensions.manifest_has_permission(m, s) { ext_ok(x, "false"); return } }
	}
	if origins, ok := d.origins.?; ok {
		for s in origins {
			p, pok := extensions.pattern_parse(s)
			if !pok { ext_fail(x, fmt.tprintf("Invalid url pattern '%s'", s)); return }
			covered := false
			for g in x.e.grants { if ext_pattern_covers(g, p) { covered = true; break } }
			if !covered { ext_ok(x, "false"); return }
		}
	}
	ext_ok(x, "true")
}

// (optional permissions and their prompt come with phase 6: nothing is added or taken away)
ext_permissions_request :: proc(x: ^Ext_Call, a: Ext_Permissions_Request_Args) { ext_ok(x, "false") }

ext_permissions_remove :: proc(x: ^Ext_Call, a: Ext_Permissions_Remove_Args) { ext_ok(x, "false") }

ext_management_get_self :: proc(x: ^Ext_Call) {
	m := &x.e.image.manifest
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":%s,"name":%s,"shortName":%s,"description":%s,"version":%s,"versionName":%s,"mayDisable":true,"enabled":%s,"installType":"development","type":"extension","offlineEnabled":false,"homepageUrl":%s,"optionsUrl":%s,"permissions":[`,
		extensions.json_quote(x.e.id), extensions.json_quote(m.name), extensions.json_quote(m.short_name != "" ? m.short_name : m.name), extensions.json_quote(m.description),
		extensions.json_quote(m.version), extensions.json_quote(m.version_name != "" ? m.version_name : m.version), jbool_text(x.e.enabled), extensions.json_quote(m.homepage_url),
		extensions.json_quote(m.options_page != "" ? extensions.image_url(x.e.image, m.options_page) : ""))
	for p, i in m.permissions { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(p)) }
	strings.write_string(&b, `],"hostPermissions":[`)
	for g, i in x.e.granted { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(g)) }
	strings.write_string(&b, "]}")
	ext_ok(x, strings.to_string(b))
}

package page

// The extension APIs of phase 1 (docs/extensions.md, section 2.2 "Start"): one table of methods and one of events, each
// with the permission it needs and whether a content script may use it. ext_info_json lists what a context may use
// (its chrome.* is built from that list: an API outside it is `undefined`); ext_dispatch checks the same rule before it
// runs anything (ext_call_allowed: the one gate). Arguments arrive as a JSON list, answers leave as JSON text ("" :
// undefined, "!" : an error's message).
//
// Not here yet (later phases): content scripts, scripting, webRequest, contextMenus, commands, notifications, idle,
// offscreen, tabs.create / update / remove, windows.create, permissions.request (answers false).

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
	args:     json.Array,
	to:       Ext_Target,
	answered: bool,
}

Ext_Method_Proc :: #type proc(x: ^Ext_Call)

Ext_Method :: struct {
	name:       string,
	permission: string,    // "" : none
	content:    bool,      // a content script may call it
	action:     bool,      // the manifest must have an action
	impl:       Ext_Method_Proc,
}

Ext_Event :: struct {
	name:       string,
	permission: string,
	content:    bool,
	action:     bool,
}

EXT_METHODS := [?]Ext_Method{
	{name = "runtime.sendMessage", content = true, impl = ext_runtime_send_message},
	{name = "runtime.getPlatformInfo", impl = ext_runtime_platform},
	{name = "runtime.setUninstallURL", impl = ext_nothing},
	{name = "storage.local.get", permission = "storage", content = true, impl = ext_storage_get},
	{name = "storage.local.set", permission = "storage", content = true, impl = ext_storage_set},
	{name = "storage.local.remove", permission = "storage", content = true, impl = ext_storage_remove},
	{name = "storage.local.clear", permission = "storage", content = true, impl = ext_storage_clear},
	{name = "storage.local.getBytesInUse", permission = "storage", content = true, impl = ext_storage_bytes},
	{name = "storage.local.getKeys", permission = "storage", content = true, impl = ext_storage_keys},
	{name = "storage.sync.get", permission = "storage", content = true, impl = ext_storage_get},
	{name = "storage.sync.set", permission = "storage", content = true, impl = ext_storage_set},
	{name = "storage.sync.remove", permission = "storage", content = true, impl = ext_storage_remove},
	{name = "storage.sync.clear", permission = "storage", content = true, impl = ext_storage_clear},
	{name = "storage.sync.getBytesInUse", permission = "storage", content = true, impl = ext_storage_bytes},
	{name = "storage.sync.getKeys", permission = "storage", content = true, impl = ext_storage_keys},
	{name = "storage.session.get", permission = "storage", impl = ext_storage_get},
	{name = "storage.session.set", permission = "storage", impl = ext_storage_set},
	{name = "storage.session.remove", permission = "storage", impl = ext_storage_remove},
	{name = "storage.session.clear", permission = "storage", impl = ext_storage_clear},
	{name = "storage.session.getBytesInUse", permission = "storage", impl = ext_storage_bytes},
	{name = "storage.session.getKeys", permission = "storage", impl = ext_storage_keys},
	{name = "storage.session.setAccessLevel", permission = "storage", impl = ext_nothing},
	{name = "storage.managed.get", permission = "storage", content = true, impl = ext_storage_get},
	{name = "storage.managed.getBytesInUse", permission = "storage", content = true, impl = ext_storage_bytes},
	{name = "tabs.query", impl = ext_tabs_query},
	{name = "tabs.get", impl = ext_tabs_get},
	{name = "tabs.getCurrent", impl = ext_tabs_current},
	{name = "windows.getCurrent", impl = ext_windows_current},
	{name = "windows.getLastFocused", impl = ext_windows_current},
	{name = "windows.getAll", impl = ext_windows_all},
	{name = "windows.get", impl = ext_windows_get},
	{name = "action.setTitle", action = true, impl = ext_action_set},
	{name = "action.getTitle", action = true, impl = ext_action_get},
	{name = "action.setPopup", action = true, impl = ext_action_set},
	{name = "action.getPopup", action = true, impl = ext_action_get},
	{name = "action.setBadgeText", action = true, impl = ext_action_set},
	{name = "action.getBadgeText", action = true, impl = ext_action_get},
	{name = "action.setBadgeBackgroundColor", action = true, impl = ext_action_set},
	{name = "action.getBadgeBackgroundColor", action = true, impl = ext_action_get},
	{name = "action.setBadgeTextColor", action = true, impl = ext_nothing},
	{name = "action.setIcon", action = true, impl = ext_action_set},
	{name = "action.enable", action = true, impl = ext_action_set},
	{name = "action.disable", action = true, impl = ext_action_set},
	{name = "action.isEnabled", action = true, impl = ext_action_get},
	{name = "action.getUserSettings", action = true, impl = ext_action_get},
	{name = "alarms.create", permission = "alarms", impl = ext_alarms_create},
	{name = "alarms.get", permission = "alarms", impl = ext_alarms_get},
	{name = "alarms.getAll", permission = "alarms", impl = ext_alarms_get},
	{name = "alarms.clear", permission = "alarms", impl = ext_alarms_clear},
	{name = "alarms.clearAll", permission = "alarms", impl = ext_alarms_clear},
	{name = "permissions.contains", impl = ext_permissions},
	{name = "permissions.getAll", impl = ext_permissions},
	{name = "permissions.request", impl = ext_permissions},
	{name = "permissions.remove", impl = ext_permissions},
	{name = "management.getSelf", impl = ext_management_self},
}

EXT_EVENTS := [?]Ext_Event{
	{name = "runtime.onMessage", content = true},
	{name = "runtime.onConnect", content = true},
	{name = "runtime.onInstalled"},
	{name = "runtime.onStartup"},
	{name = "runtime.onSuspend"},
	{name = "runtime.onSuspendCanceled"},
	{name = "runtime.onUpdateAvailable"},
	{name = "storage.onChanged", permission = "storage", content = true},
	{name = "storage.local.onChanged", permission = "storage", content = true},
	{name = "storage.sync.onChanged", permission = "storage", content = true},
	{name = "storage.session.onChanged", permission = "storage"},
	{name = "storage.managed.onChanged", permission = "storage", content = true},
	{name = "alarms.onAlarm", permission = "alarms"},
	{name = "action.onClicked", action = true},
	{name = "tabs.onActivated"}, {name = "tabs.onUpdated"}, {name = "tabs.onRemoved"}, {name = "tabs.onCreated"},
	{name = "tabs.onReplaced"}, {name = "tabs.onAttached"}, {name = "tabs.onDetached"}, {name = "tabs.onMoved"},
	{name = "tabs.onHighlighted"},
	{name = "windows.onFocusChanged"}, {name = "windows.onRemoved"}, {name = "windows.onCreated"}, {name = "windows.onBoundsChanged"},
	{name = "permissions.onAdded"}, {name = "permissions.onRemoved"},
}

// The gate (rule 2 of section 3.11), for a method or an event: the permission is in the manifest (every required
// permission is granted at install), the manifest has what it acts on, the kind of context may use it.
@(private)
ext_allowed :: proc(im: ^extensions.Image, kind: Ext_Kind, permission: string, content, action: bool) -> bool {
	if kind == .Content && !content { return false }
	if action && !im.manifest.has_action { return false }
	if permission != "" && !extensions.manifest_has_permission(&im.manifest, permission) { return false }
	return true
}

ext_method_find :: proc(name: string) -> ^Ext_Method {
	for &m in EXT_METHODS { if m.name == name { return &m } }
	return nil
}

// Ext_info's answer: what a context of `kind` of this extension may use (temp allocator).
ext_info_json :: proc(im: ^extensions.Image, kind: Ext_Kind) -> string {
	b := strings.builder_make(context.temp_allocator)
	lang := im.language
	fmt.sbprintf(&b, `{"id":%s,"kind":%s,"base":%s,"flavour":%s,"lang":%s,"methods":[`, extensions.json_quote(im.id), extensions.json_quote(EXT_KIND_NAMES[kind]),
		extensions.json_quote(im.base_url), extensions.json_quote(extensions.FLAVOUR_NAMES[im.manifest.flavour]), extensions.json_quote(lang))
	first := true
	for m in EXT_METHODS {
		if !ext_allowed(im, kind, m.permission, m.content, m.action) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		strings.write_string(&b, extensions.json_quote(m.name))
	}
	strings.write_string(&b, `],"events":[`)
	first = true
	for ev in EXT_EVENTS {
		if !ext_allowed(im, kind, ev.permission, ev.content, ev.action) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		strings.write_string(&b, extensions.json_quote(ev.name))
	}
	strings.write_string(&b, "]}")
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
	if !ext_allowed(e.image, c.kind, m.permission, m.content, m.action) {
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
	m.impl(&x)
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
ext_arg :: proc(x: ^Ext_Call, i: int) -> json.Value { return i < len(x.args) ? x.args[i] : nil }

@(private)
jbool :: proc(o: json.Object, key: string) -> (bool, bool) {
	v, ok := o[key].(json.Boolean)
	return v, ok
}

@(private)
jnum :: proc(o: json.Object, key: string) -> (f64, bool) {
	#partial switch n in o[key] {
	case json.Float:   return n, true
	case json.Integer: return f64(n), true
	}
	return 0, false
}

@(private)
jstr :: proc(o: json.Object, key: string) -> (string, bool) {
	v, ok := o[key].(json.String)
	return v, ok
}

@(private)
jobj :: proc(v: json.Value) -> json.Object {
	o, _ := v.(json.Object)
	return o
}

@(private)
jbool_text :: proc(b: bool) -> string { return b ? "true" : "false" }

ext_nothing :: proc(x: ^Ext_Call) { ext_ok(x, "") }

////////////////////////////////
// runtime

ext_runtime_send_message :: proc(x: ^Ext_Call) {
	msg := ext_arg(x, 0)
	x.answered = true   // (answered by the receivers, or by ext_send_message when there is none)
	ext_send_message(x.c, extensions.json_text(msg), x.to)
}

ext_runtime_platform :: proc(x: ^Ext_Call) {
	os_name := "linux"
	when ODIN_OS == .Windows { os_name = "win" }
	when ODIN_OS == .Darwin { os_name = "mac" }
	arch := "x86-64"
	when ODIN_ARCH == .arm64 { arch = "arm64" }
	ext_ok(x, fmt.tprintf(`{"os":"%s","arch":"%s","nacl_arch":"%s"}`, os_name, arch, arch))
}

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

// The keys an argument names: nil value: all (all = true); a string; a list of strings; an object (its keys, with
// defaults). False when it is none of these.
@(private)
ext_keys_of :: proc(v: json.Value) -> (keys: []string, defaults: json.Object, all: bool, ok: bool) {
	switch k in v {
	case nil, json.Null: return nil, nil, true, true
	case json.String:
		out := make([]string, 1, context.temp_allocator)
		out[0] = k
		return out, nil, false, true
	case json.Array:
		out := make([dynamic]string, 0, len(k), context.temp_allocator)
		for e in k {
			s, sok := e.(json.String)
			if !sok { return nil, nil, false, false }
			append(&out, s)
		}
		return out[:], nil, false, true
	case json.Object:
		out := make([dynamic]string, 0, len(k), context.temp_allocator)
		for key in k { append(&out, key) }
		return out[:], k, false, true
	case json.Integer, json.Float, json.Boolean:
	}
	return nil, nil, false, false
}

ext_storage_get :: proc(x: ^Ext_Call) {
	a, _ := ext_area(x)
	if a == nil { ext_ok(x, "{}"); return }   // managed: empty (no policy sets it)
	keys, defaults, all, ok := ext_keys_of(ext_arg(x, 0))
	if !ok { ext_fail(x, "Error in invocation of storage.get: keys must be a string, a list of strings or an object"); return }
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
		for k, v in a.items { item(&b, &first, k, v) }
	} else {
		for k in keys {
			if v, has := a.items[k]; has {
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

ext_storage_set :: proc(x: ^Ext_Call) {
	a, kind := ext_area(x)
	if a == nil { ext_fail(x, "storage.managed is read-only"); return }
	o, ok := ext_arg(x, 0).(json.Object)
	if !ok { ext_fail(x, "Error in invocation of storage.set: items must be an object"); return }
	keys := make([dynamic]string, 0, len(o), context.temp_allocator)
	values := make([dynamic]string, 0, len(o), context.temp_allocator)
	for k, v in o {
		append(&keys, k)
		append(&values, extensions.json_text(v))
	}
	changes, err := extensions.area_set(a, keys[:], values[:])
	if err != .None { ext_fail(x, extensions.area_error_text(err)); return }
	ext_storage_changed(x, kind, changes)
	ext_ok(x, "")
}

ext_storage_remove :: proc(x: ^Ext_Call) {
	a, kind := ext_area(x)
	if a == nil { ext_fail(x, "storage.managed is read-only"); return }
	keys, _, all, ok := ext_keys_of(ext_arg(x, 0))
	if !ok || all { ext_fail(x, "Error in invocation of storage.remove: keys must be a string or a list of strings"); return }
	ext_storage_changed(x, kind, extensions.area_remove(a, keys))
	ext_ok(x, "")
}

ext_storage_clear :: proc(x: ^Ext_Call) {
	a, kind := ext_area(x)
	if a == nil { ext_fail(x, "storage.managed is read-only"); return }
	ext_storage_changed(x, kind, extensions.area_clear(a))
	ext_ok(x, "")
}

ext_storage_bytes :: proc(x: ^Ext_Call) {
	a, _ := ext_area(x)
	if a == nil { ext_ok(x, "0"); return }
	keys, _, all, ok := ext_keys_of(ext_arg(x, 0))
	if !ok { ext_fail(x, "Error in invocation of storage.getBytesInUse"); return }
	ext_ok(x, fmt.tprintf("%d", extensions.area_bytes_of(a, all ? nil : keys)))
}

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
ext_may_see :: proc(x: ^Ext_Call, href: string) -> bool {
	if extensions.manifest_has_permission(&x.e.image.manifest, "tabs") { return true }
	if strings.has_prefix(href, x.e.image.base_url) { return true }
	return extensions.extension_host_allowed(x.reg, x.e, href)
}

@(private)
ext_tab_json :: proc(b: ^strings.Builder, x: ^Ext_Call, t: Ext_Tab_Info) {
	fmt.sbprintf(b, `{"id":%d,"index":%d,"windowId":%d,"active":%s,"highlighted":%s,"selected":%s,"pinned":%s,"incognito":false,"discarded":false,"autoDiscardable":true,"frozen":false,"groupId":-1,"audible":false,"mutedInfo":{"muted":false},"status":"%s"`,
		t.id, t.index, t.window, jbool_text(t.active), jbool_text(t.active), jbool_text(t.active), jbool_text(t.pinned), t.loading ? "loading" : "complete")
	if ext_may_see(x, t.url) {
		fmt.sbprintf(b, `,"url":%s,"title":%s`, extensions.json_quote(t.url), extensions.json_quote(t.title))
	}
	strings.write_byte(b, '}')
}

ext_tabs_query :: proc(x: ^Ext_Call) {
	q := jobj(ext_arg(x, 0))
	want_window := i64(-1)
	if v, ok := jbool(q, "currentWindow"); ok && v { want_window = ext_current_window(x) }
	if v, ok := jbool(q, "lastFocusedWindow"); ok && v {
		if em := &ext_router().embedder; em.focused_window != nil { want_window = em.focused_window(em.user) }
	}
	if n, ok := jnum(q, "windowId"); ok { want_window = n == -2 ? ext_current_window(x) : i64(n) }
	patterns := make([dynamic]extensions.Pattern, 0, 4, context.temp_allocator)
	has_url := false
	#partial switch u in q["url"] {
	case json.String:
		has_url = true
		if p, ok := extensions.pattern_parse(u); ok { append(&patterns, p) }
	case json.Array:
		has_url = true
		for e in u { if s, ok := e.(json.String); ok { if p, pok := extensions.pattern_parse(s); pok { append(&patterns, p) } } }
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	for t in ext_tabs_list() {
		if v, ok := jbool(q, "active"); ok && v != t.active { continue }
		if v, ok := jbool(q, "highlighted"); ok && v != t.active { continue }
		if v, ok := jbool(q, "pinned"); ok && v != t.pinned { continue }
		if s, ok := jstr(q, "status"); ok && s != (t.loading ? "loading" : "complete") { continue }
		if n, ok := jnum(q, "index"); ok && i64(n) != t.index { continue }
		if want_window >= 0 && t.window != want_window { continue }
		if has_url && (!ext_may_see(x, t.url) || !extensions.patterns_match_href(patterns[:], t.url)) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		ext_tab_json(&b, x, t)
	}
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

ext_tabs_get :: proc(x: ^Ext_Call) {
	n, ok := ext_arg(x, 0).(json.Float)
	if !ok { ext_fail(x, "Error in invocation of tabs.get: tabId must be an integer"); return }
	for t in ext_tabs_list() {
		if t.id != i64(n) { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_tab_json(&b, x, t)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_fail(x, fmt.tprintf("No tab with id: %d.", i64(n)))
}

// The tab of the calling page (undefined for a popup or the background, as in Chrome).
ext_tabs_current :: proc(x: ^Ext_Call) {
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
ext_window_json :: proc(b: ^strings.Builder, x: ^Ext_Call, w: Ext_Window_Info, populate: bool) {
	fmt.sbprintf(b, `{"id":%d,"focused":%s,"top":%d,"left":%d,"width":%d,"height":%d,"incognito":false,"type":"normal","state":%s,"alwaysOnTop":false`,
		w.id, jbool_text(w.focused), w.top, w.left, w.width, w.height, extensions.json_quote(w.state != "" ? w.state : "normal"))
	if populate {
		strings.write_string(b, `,"tabs":[`)
		first := true
		for t in ext_tabs_list() {
			if t.window != w.id { continue }
			if !first { strings.write_byte(b, ',') }
			first = false
			ext_tab_json(b, x, t)
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '}')
}

@(private)
ext_window_answer :: proc(x: ^Ext_Call, id: i64, info: json.Value) {
	populate, _ := jbool(jobj(info), "populate")
	for w in ext_windows_list() {
		if w.id != id { continue }
		b := strings.builder_make(context.temp_allocator)
		ext_window_json(&b, x, w, populate)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_fail(x, fmt.tprintf("No window with id: %d.", id))
}

ext_windows_current :: proc(x: ^Ext_Call) {
	id := ext_current_window(x)
	if strings.has_suffix(x.method, "getLastFocused") {
		if em := &ext_router().embedder; em.focused_window != nil { id = em.focused_window(em.user) }
	}
	ext_window_answer(x, id, ext_arg(x, 0))
}

ext_windows_get :: proc(x: ^Ext_Call) {
	n, ok := ext_arg(x, 0).(json.Float)
	if !ok { ext_fail(x, "Error in invocation of windows.get: windowId must be an integer"); return }
	id := i64(n)
	if id == -2 { id = ext_current_window(x) }
	ext_window_answer(x, id, ext_arg(x, 1))
}

ext_windows_all :: proc(x: ^Ext_Call) {
	populate, _ := jbool(jobj(ext_arg(x, 0)), "populate")
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
ext_color_of :: proc(v: json.Value) -> ([4]u8, bool) {
	#partial switch c in v {
	case json.Array:
		if len(c) < 3 { return {}, false }
		out := [4]u8{0, 0, 0, 255}
		for i in 0 ..< min(len(c), 4) {
			n, ok := c[i].(json.Float)
			if !ok { return {}, false }
			out[i] = u8(clamp(n, 0, 255))
		}
		return out, true
	case json.String:
		s := strings.trim_prefix(c, "#")
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

ext_action_set :: proc(x: ^Ext_Call) {
	a := &x.e.action
	name := strings.trim_prefix(x.method, "action.")
	if name == "enable" || name == "disable" {
		on := name == "enable"
		if _, ok := ext_arg(x, 0).(json.Float); ok { ext_ok(x, ""); return }   // per tab: the button stays as it is for now
		if a.enabled != on { a.enabled = on; ext_action_changed(x) }
		ext_ok(x, "")
		return
	}
	d, ok := ext_arg(x, 0).(json.Object)
	if !ok { ext_fail(x, fmt.tprintf("Error in invocation of action.%s: details must be an object", name)); return }
	tab := i64(-1)
	if n, has := jnum(d, "tabId"); has { tab = i64(n) }
	per: ^extensions.Action_Tab
	if tab >= 0 {
		if u64(tab) not_in a.tabs { a.tabs[u64(tab)] = {} }
		if slot, found := &a.tabs[u64(tab)]; found { per = slot }
	}
	switch name {
	case "setTitle":
		t, _ := jstr(d, "title")
		if per != nil { ext_set_maybe(&per.title, t) } else { ext_set_text(&a.title, t) }
	case "setPopup":
		p, _ := jstr(d, "popup")
		rel := ""
		if p != "" {
			if strings.has_prefix(p, x.e.image.base_url) { p = p[len(x.e.image.base_url):] }
			n, nok := extensions.package_path_normalize(p, context.temp_allocator)
			if !nok || !extensions.image_has_file(x.e.image, n) { ext_fail(x, fmt.tprintf("the popup %q is not a file of the extension", p)); return }
			rel = n
		}
		if per != nil { ext_set_maybe(&per.popup, rel) } else { ext_set_text(&a.popup, rel) }
	case "setBadgeText":
		t, _ := jstr(d, "text")
		if len(t) > 64 { t = t[:64] }   // (the button shows 4 characters; a longer text is cut here, not kept)
		if per != nil { ext_set_maybe(&per.badge, t) } else { ext_set_text(&a.badge, t) }
	case "setBadgeBackgroundColor":
		col, cok := ext_color_of(d["color"])
		if !cok { ext_fail(x, "action.setBadgeBackgroundColor: color must be a list [r, g, b, a] or a #rrggbb text"); return }
		if per != nil { per.badge_color = col } else { a.badge_color = col }
	case "setIcon":
		path := ""
		#partial switch p in d["path"] {
		case json.String: path = p
		case json.Object:
			best := 0
			for size, v in p {
				s, sok := v.(json.String)
				n := 0
				for ch in transmute([]byte)size { if ch >= '0' && ch <= '9' { n = n * 10 + int(ch - '0') } }
				if sok && (path == "" || (n >= 16 && n <= 32 && n > best)) { path, best = s, n }
			}
		}
		if path != "" {
			n, nok := extensions.package_path_normalize(path, context.temp_allocator)
			if !nok || !extensions.image_has_file(x.e.image, n) { ext_fail(x, fmt.tprintf("the icon %q is not a file of the extension", path)); return }
			if per != nil { ext_set_maybe(&per.icon, n) } else { ext_set_text(&a.icon, n) }
		}
		// (imageData: an icon drawn by the extension; shown when the toolbar can show pixels it is given)
	}
	ext_action_changed(x)
	ext_ok(x, "")
}

ext_action_get :: proc(x: ^Ext_Call) {
	a := &x.e.action
	name := strings.trim_prefix(x.method, "action.")
	if name == "getUserSettings" { ext_ok(x, `{"isOnToolbar":true}`); return }
	if name == "isEnabled" { ext_ok(x, jbool_text(a.enabled)); return }
	d := jobj(ext_arg(x, 0))
	per: ^extensions.Action_Tab
	if n, has := jnum(d, "tabId"); has {
		if t, found := &a.tabs[u64(n)]; found { per = t }
	}
	switch name {
	case "getTitle":
		t := a.title
		if per != nil { if s, ok := per.title.?; ok { t = s } }
		ext_ok(x, extensions.json_quote(t))
	case "getPopup":
		p := a.popup
		if per != nil { if s, ok := per.popup.?; ok { p = s } }
		ext_ok(x, extensions.json_quote(p != "" ? extensions.image_url(x.e.image, p) : ""))
	case "getBadgeText":
		t := a.badge
		if per != nil { if s, ok := per.badge.?; ok { t = s } }
		ext_ok(x, extensions.json_quote(t))
	case "getBadgeBackgroundColor":
		c := a.badge_color
		if per != nil { if s, ok := per.badge_color.?; ok { c = s } }
		ext_ok(x, fmt.tprintf("[%d,%d,%d,%d]", c[0], c[1], c[2], c[3]))
	}
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
	fmt.sbprintf(b, `{"name":%s,"scheduledTime":%.0f`, extensions.json_quote(al.name), al.when_ms)
	if al.period_ms > 0 { fmt.sbprintf(b, `,"periodInMinutes":%v`, al.period_ms / 60000) }
	strings.write_byte(b, '}')
}

ext_alarms_create :: proc(x: ^Ext_Call) {
	name := ""
	info: json.Object
	if s, ok := ext_arg(x, 0).(json.String); ok { name, info = s, jobj(ext_arg(x, 1)) } else { info = jobj(ext_arg(x, 0)) }
	min_ms := f64(x.reg.settings.alarms_min_period_ms)
	now := ext_now_ms()
	period, delay := 0.0, -1.0
	if p, ok := jnum(info, "periodInMinutes"); ok { period = max(p * 60000, min_ms) }
	when_ms := -1.0
	if w, ok := jnum(info, "when"); ok { when_ms = w }
	if d, ok := jnum(info, "delayInMinutes"); ok { delay = max(d * 60000, min_ms) }
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

ext_alarms_get :: proc(x: ^Ext_Call) {
	b := strings.builder_make(context.temp_allocator)
	if strings.has_suffix(x.method, "getAll") {
		strings.write_byte(&b, '[')
		for al, i in x.e.alarms { if i > 0 { strings.write_byte(&b, ',') }; ext_alarm_json(&b, al) }
		strings.write_byte(&b, ']')
		ext_ok(x, strings.to_string(b))
		return
	}
	name, _ := ext_arg(x, 0).(json.String)
	for al in x.e.alarms {
		if al.name != name { continue }
		ext_alarm_json(&b, al)
		ext_ok(x, strings.to_string(b))
		return
	}
	ext_ok(x, "")
}

ext_alarms_clear :: proc(x: ^Ext_Call) {
	cleared := false
	if strings.has_suffix(x.method, "clearAll") {
		cleared = len(x.e.alarms) > 0
		for al in x.e.alarms { delete(al.name) }
		clear(&x.e.alarms)
	} else {
		name, _ := ext_arg(x, 0).(json.String)
		for al, i in x.e.alarms { if al.name == name { delete(al.name); ordered_remove(&x.e.alarms, i); cleared = true; break } }
	}
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

ext_permissions :: proc(x: ^Ext_Call) {
	name := strings.trim_prefix(x.method, "permissions.")
	m := &x.e.image.manifest
	switch name {
	case "getAll":
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"permissions":[`)
		for p, i in m.permissions { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(p)) }
		strings.write_string(&b, `],"origins":[`)
		for g, i in x.e.granted { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(g)) }
		strings.write_string(&b, "]}")
		ext_ok(x, strings.to_string(b))
	case "contains":
		d := jobj(ext_arg(x, 0))
		if perms, ok := d["permissions"].(json.Array); ok {
			for v in perms {
				s, sok := v.(json.String)
				if !sok || !extensions.manifest_has_permission(m, s) { ext_ok(x, "false"); return }
			}
		}
		if origins, ok := d["origins"].(json.Array); ok {
			for v in origins {
				s, sok := v.(json.String)
				if !sok { ext_ok(x, "false"); return }
				p, pok := extensions.pattern_parse(s)
				if !pok { ext_fail(x, fmt.tprintf("Invalid url pattern '%s'", s)); return }
				covered := false
				for g in x.e.grants { if ext_pattern_covers(g, p) { covered = true; break } }
				if !covered { ext_ok(x, "false"); return }
			}
		}
		ext_ok(x, "true")
	case "request", "remove":
		// (optional permissions and their prompt come with phase 6: nothing is added or taken away)
		ext_ok(x, "false")
	}
}

ext_management_self :: proc(x: ^Ext_Call) {
	m := &x.e.image.manifest
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{"id":%s,"name":%s,"shortName":%s,"description":%s,"version":%s,"versionName":%s,"mayDisable":true,"enabled":%s,"installType":"development","type":"extension","offlineEnabled":false,"homepageUrl":%s,"optionsUrl":%s,"permissions":[`,
		extensions.json_quote(x.e.id), extensions.json_quote(m.name), extensions.json_quote(m.short_name != "" ? m.short_name : m.name), extensions.json_quote(m.description),
		extensions.json_quote(m.version), extensions.json_quote(m.version_name != "" ? m.version_name : m.version), jbool_text(x.e.enabled), extensions.json_quote(m.homepage_url),
		extensions.json_quote(m.options_page != "" ? extensions.image_url(x.e.image, m.options_page) : ""))
	for p, i in m.permissions { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(p)) }
	strings.write_string(&b, `],"hostPermissions":[`)
	for g, i in x.e.granted { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_quote(g)) }
	strings.write_string(&b, "]}")
	ext_ok(x, strings.to_string(b))
}

package extensions

// The installed extensions of one App (docs/extensions.md, section 3.2). The registry is a field of page.Pages, owned by
// the App: no global. It lives on the loop thread; what a worker thread reads is an Image, immutable and counted.
//
//   * An Image is what a package loads into: the manifest, the catalogue, the file index, all in one arena. It is made off
//     the interface thread (image_load: disk reads), handed to the loop thread (registry_adopt) and never changed after.
//     A reload makes a new one; who still holds the old one (a running worker) keeps it alive until it lets go.
//   * An Extension is the record of the registry: id, path, enabled, its grants, its storage areas, its action's state,
//     its alarms. Removing it ends all of these.
//   * The list (<profile>/extensions.txt) and the storage areas are written by the shell's writer (off the thread).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:url"

SCHEME_CHROME :: "chrome-extension"
SCHEME_FIREFOX :: "moz-extension"

Source_Kind :: enum u8 { Directory, Zip, Crx }
SOURCE_NAMES := [Source_Kind]string{.Directory = "dir", .Zip = "zip", .Crx = "crx"}

Image :: struct {
	refs:      i32,                       // atomic
	arena:     base.Arena,
	ok:        bool,                      // the manifest loaded without an error: the extension may run
	id:        string,
	root:      string,                    // the package's folder (absolute)
	base_url:  string,                    // "chrome-extension://<id>/"
	manifest:  Manifest,
	catalogue: Catalogue,
	files:     map[string]File_Entry,
	problems:  [dynamic]Problem,
	page_csp:  string,                    // the policy of its pages and of its background
	background_source: []byte,            // the background service worker's script, read with the package (never on the loop thread)
	language:  string,                    // the UI language it was loaded for ("en-US"): i18n.getUILanguage
}

image_retain :: proc(im: ^Image) -> ^Image {
	if im != nil { sync.atomic_add(&im.refs, 1) }
	return im
}

image_release :: proc(im: ^Image) {
	if im == nil { return }
	if sync.atomic_sub(&im.refs, 1) != 1 { return }
	base.arena_destroy(&im.arena)
	free(im, base.process_allocator())
}

// Whether `rel` (normalised) is a file of the package.
image_has_file :: proc(im: ^Image, rel: string) -> bool { return rel in im.files }

// The absolute URL of `rel` in the extension (temp allocator).
image_url :: proc(im: ^Image, rel: string) -> string {
	return strings.concatenate({im.base_url, strings.trim_prefix(rel, "/")}, context.temp_allocator)
}

// What image_load gives the loop thread. Strings are allocated with the process allocator (freed by load_result_destroy).
Load_Result :: struct {
	image:      ^Image,    // nil when the folder could not be read at all
	path:       string,    // the absolute folder
	source:     Source_Kind,   // a packed install (archive_install) says which kind it came from
	error:      string,    // why it does not run ("" : it runs)
	local_text: string,    // the stored areas, as area_serialize wrote them
	sync_text:  string,
	state_text: string,    // state.txt (state_serialize): the events its background listens to
}

load_result_destroy :: proc(r: ^Load_Result) {
	a := base.process_allocator()
	image_release(r.image)
	delete(r.path, a); delete(r.error, a); delete(r.local_text, a); delete(r.sync_text, a); delete(r.state_text, a)
	r^ = {}
}

// The folder of an extension's own files in the profile (temp allocator).
extension_profile_dir :: proc(profile_dir, id: string) -> string {
	return fmt.tprintf("%s/extensions/%s", profile_dir, id)
}

area_file :: proc(profile_dir, id: string, kind: Area_Kind) -> string {
	return fmt.tprintf("%s/extensions/%s/storage/%s.txt", profile_dir, id, AREA_NAMES[kind])
}

// Loads an unpacked extension from `path` (a blocking call: run it off the interface thread). `ui_language` chooses the
// catalogue ("en-US"); `profile_dir` is where its storage is kept ("" : none). `forced_id`: the id a packed extension
// got at install (archive_id); "" : the manifest's key, else the folder's path.
image_load :: proc(path: string, s: Settings, ui_language: string, profile_dir: string, forced_id := "") -> (r: Load_Result) {
	pa := base.process_allocator()
	abs, aerr := os.get_absolute_path(path, context.temp_allocator)
	if aerr != nil { abs = path }
	abs, _ = strings.replace_all(abs, "\\", "/", context.temp_allocator)
	abs = strings.trim_right(abs, "/")
	r.path = strings.clone(abs, pa)
	settings := s

	im := new(Image, pa)
	im.refs = 1
	if base.arena_init_growing(&im.arena) != .None { free(im, pa); r.error = strings.clone("out of memory", pa); return }
	r.image = im
	a := base.arena_allocator(&im.arena)
	im.root = strings.clone(abs, a)
	im.language = strings.clone(ui_language != "" ? ui_language : "en-US", a)
	im.files = make(map[string]File_Entry, 64, a)
	im.problems = make([dynamic]Problem, 0, 8, a)

	if e := package_index_dir(abs, &settings, &im.files, a); e != .None {
		r.error = strings.clone(package_error_text(e), pa)
		return
	}
	raw, ok := package_read(abs, &im.files, "manifest.json", settings.manifest_max_bytes, context.temp_allocator)
	if !ok { r.error = strings.clone("the folder has no manifest.json (or it is too large)", pa); return }
	text := string(raw)

	// the id first: the catalogue's @@extension_id and the storage need it. A first look at the manifest finds its key
	// and default_locale (a second, typed, parse follows with the messages put in).
	probe_problems := make([dynamic]Problem, 0, 4, context.temp_allocator)
	probe, _ := manifest_parse(text, nil, &settings, &probe_problems, context.temp_allocator)
	id := ""
	if forced_id != "" && id_valid(forced_id) {
		id = strings.clone(forced_id, a)
	} else if probe.key != "" {
		if kid, kok := id_from_key(probe.key, a); kok { id = kid } else { append(&im.problems, Problem{false, strings.clone("key is not base64: the id comes from the folder", a)}) }
	}
	if id == "" { id = id_from_path(abs, a) }
	im.id = id
	im.base_url = strings.concatenate({SCHEME_CHROME, "://", id, "/"}, a)

	catalogue_load(im, probe.default_locale, ui_language, &settings, a)
	localized := manifest_localize(text, &im.catalogue, id)
	m, mok := manifest_parse(localized, &im.files, &settings, &im.problems, a)
	im.manifest = m
	im.ok = mok
	for p in im.problems { if p.error { im.ok = false } }   // (a missing default catalogue too)
	im.page_csp = m.csp_pages != "" ? m.csp_pages : DEFAULT_PAGE_CSP
	if !im.ok {
		for p in im.problems { if p.error { r.error = strings.clone(p.text, pa); break } }
	}
	if im.ok && m.background_worker != "" {
		src, sok := package_read(abs, &im.files, m.background_worker, int(settings.package_max_bytes), a)
		if sok { im.background_source = src } else { im.ok = false; r.error = strings.clone("background.service_worker cannot be read", pa) }
	}
	if profile_dir != "" {
		if data, err := os.read_entire_file(area_file(profile_dir, id, .Local), pa); err == nil { r.local_text = string(data) }
		if data, err := os.read_entire_file(area_file(profile_dir, id, .Sync), pa); err == nil { r.sync_text = string(data) }
		if data, err := os.read_entire_file(state_file(profile_dir, id), pa); err == nil { r.state_text = string(data) }
	}
	return
}

// The catalogue of the UI language, then default_locale behind it (a missing catalogue is a warning).
@(private)
catalogue_load :: proc(im: ^Image, default_locale, ui_language: string, s: ^Settings, a: runtime.Allocator) {
	im.catalogue.messages = make(map[string]Message, 16, a)
	im.catalogue.fallback = make(map[string]Message, 16, a)
	if default_locale == "" { return }
	read :: proc(im: ^Image, locale: string, into: ^map[string]Message, s: ^Settings, a: runtime.Allocator) -> bool {
		rel := fmt.tprintf("_locales/%s/messages.json", locale)
		data, ok := package_read(im.root, &im.files, rel, s.manifest_max_bytes, context.temp_allocator)
		if !ok { return false }
		if !catalogue_parse(string(data), into, a) { append(&im.problems, Problem{false, fmt.aprintf("%s is not valid JSON", rel, allocator = a)}); return false }
		return true
	}
	if !read(im, default_locale, &im.catalogue.fallback, s, a) {
		append(&im.problems, Problem{true, fmt.aprintf("default_locale is %q but _locales/%s/messages.json is missing", default_locale, default_locale, allocator = a)})
	}
	for loc in locale_candidates(ui_language, default_locale) {
		if loc == default_locale {
			im.catalogue.locale = strings.clone(loc, a)
			for k, v in im.catalogue.fallback { im.catalogue.messages[k] = v }
			break
		}
		if read(im, loc, &im.catalogue.messages, s, a) { im.catalogue.locale = strings.clone(loc, a); break }
	}
}

////////////////////////////////
// The registry

Action_Tab :: struct {
	title, popup, badge: Maybe(string),   // owned; nil: the extension's default
	badge_color:         Maybe([4]u8),
	icon:                Maybe(string),   // a package path (owned)
}

Action_State :: struct {
	title, popup, badge: string,          // owned (title and popup start as the manifest's)
	badge_color:         [4]u8,
	icon:                string,          // a package path set by action.setIcon ("" : the manifest's)
	enabled:             bool,
	tabs:                map[u64]Action_Tab,
}

Alarm :: struct {
	name:      string,   // owned
	when_ms:   f64,      // unix ms of its next firing
	period_ms: f64,      // 0: once
}

Extension :: struct {
	id:        string,
	path:      string,
	source:    Source_Kind,
	enabled:   bool,
	loading:   bool,                // a load (or a reload) runs
	image:     ^Image,              // nil until loaded, or when the package cannot be read
	error:     string,              // why it does not run (owned)
	granted:   [dynamic]string,     // the host patterns granted, as written (owned)
	grants:    [dynamic]Pattern,    // the same, compiled when they change (slices of `granted`): matching never parses
	granted_known: bool,            // the grants were decided (install accepted them, or the list had them)
	local, sync, session: Area,
	action:    Action_State,
	alarms:    [dynamic]Alarm,
	installed: string,              // "install", "update" or "" : runtime.onInstalled waits for its background
	unknown_calls: map[string]bool, // API methods it called that Wren does not have (owned names): about:extensions lists them
	// the events its background listened to when its script last ran (state.txt): at the browser's start the background
	// is known without running it, and an event it does not listen to does not start it
	listeners:       [dynamic]string,   // owned
	listeners_known: bool,
	idle_interval:   int,               // idle.setDetectionInterval, in seconds (0: IDLE_DEFAULT_INTERVAL)
	idle_state:      Idle_State,        // what idle.onStateChanged said last
}

Registry :: struct {
	settings:    Settings,
	list:        [dynamic]^Extension,
	dir:         string,      // the profile folder (owned; "" : nothing is kept)
	ui_language: string,      // owned
	generation:  u64,         // changes with anything the shell shows of the extensions
	// the shell's writer: writes (or removes, text "" and remove) a file of the profile off the interface thread
	write:       proc(user: rawptr, path, text: string, remove: bool),
	write_user:  rawptr,
}

registry_init :: proc(reg: ^Registry, s: Settings, profile_dir, ui_language: string) {
	reg.settings = s
	reg.dir = strings.clone(profile_dir)
	reg.ui_language = strings.clone(ui_language)
}

registry_destroy :: proc(reg: ^Registry) {
	for e in reg.list { extension_free(e) }
	delete(reg.list)
	delete(reg.dir)
	delete(reg.ui_language)
	reg^ = {}
}

extension_free :: proc(e: ^Extension) {
	image_release(e.image)
	delete(e.id); delete(e.path); delete(e.error)
	for g in e.granted { delete(g) }
	delete(e.granted)
	delete(e.grants)
	area_destroy(&e.local); area_destroy(&e.sync); area_destroy(&e.session)
	action_state_destroy(&e.action)
	for al in e.alarms { delete(al.name) }
	delete(e.alarms)
	for k in e.unknown_calls { delete(k) }
	delete(e.unknown_calls)
	listeners_clear(e)
	delete(e.listeners)
	free(e)
}

listeners_clear :: proc(e: ^Extension) {
	for l in e.listeners { delete(l) }
	clear(&e.listeners)
	e.listeners_known = false
}

// The background's listeners, as its script left them (the router keeps them while it is stopped). The caller saves
// state.txt when the text changed (registry_save_state).
listeners_set :: proc(e: ^Extension, names: []string) {
	listeners_clear(e)
	for n in names { append(&e.listeners, strings.clone(n)) }
	e.listeners_known = true
}

action_tab_destroy :: proc(t: ^Action_Tab) {
	if s, ok := t.title.?; ok { delete(s) }
	if s, ok := t.popup.?; ok { delete(s) }
	if s, ok := t.badge.?; ok { delete(s) }
	if s, ok := t.icon.?; ok { delete(s) }
	t^ = {}
}

action_state_destroy :: proc(a: ^Action_State) {
	delete(a.title); delete(a.popup); delete(a.badge); delete(a.icon)
	for _, &t in a.tabs { action_tab_destroy(&t) }
	delete(a.tabs)
	a^ = {}
}

registry_find :: proc(reg: ^Registry, id: string) -> ^Extension {
	if reg == nil { return nil }
	for e in reg.list { if e.id == id { return e } }
	return nil
}

// The extension a URL of its origin belongs to, when it is enabled and its image loaded (nil otherwise).
registry_running :: proc(reg: ^Registry, scheme, host: string) -> ^Extension {
	if reg == nil || !reg.settings.enabled || scheme != SCHEME_CHROME || !id_valid(host) { return nil }
	e := registry_find(reg, host)
	if e == nil || !e.enabled || e.image == nil || !e.image.ok { return nil }
	return e
}

registry_changed :: proc(reg: ^Registry) { reg.generation += 1 }

// Takes the result of image_load (the result's image moves into the registry; the rest is the caller's to destroy).
// Returns the extension (new, or the one of that id, reloaded). `grant_hosts`: the install prompt was accepted, the
// manifest's host permissions are granted (Chrome's rule).
registry_adopt :: proc(reg: ^Registry, r: ^Load_Result, grant_hosts: bool) -> ^Extension {
	im := r.image
	if im == nil { return nil }
	e := registry_find(reg, im.id)
	fresh := e == nil
	if fresh {
		e = new(Extension)
		e.id = strings.clone(im.id)
		e.path = strings.clone(r.path)
		e.source = r.source
		e.enabled = true
		append(&reg.list, e)
	}
	first := e.image == nil   // its first image since the browser started (a listed one, or a fresh install)
	image_release(e.image)
	e.image, r.image = im, nil
	e.loading = false
	delete(e.error)
	e.error = strings.clone(r.error)
	if im.ok {
		m := &im.manifest
		if fresh || !e.granted_known {
			if grant_hosts {
				for p in m.host_permissions { append(&e.granted, strings.clone(p.source)) }
				for cs in m.content_scripts { for p in cs.matches { grant_add(e, p.source) } }
			}
			e.granted_known = true
		}
		unlimited := manifest_has_permission(m, "unlimitedStorage")
		if first {
			area_load(&e.local, r.local_text)
			area_load(&e.sync, r.sync_text)
		}
		// the stored listeners are those of the script that ran last: a browser start keeps them, an install or a
		// reload (a new script) learns them again from its first run
		if first && !fresh && r.state_text != "" {
			listeners_set(e, state_parse(r.state_text))
		} else {
			listeners_clear(e)
		}
		e.local.max_bytes = unlimited ? 0 : reg.settings.storage_local_max
		e.sync.max_bytes, e.sync.max_item, e.sync.max_items = reg.settings.storage_sync_max, reg.settings.storage_sync_item_max, reg.settings.storage_sync_max_items
		e.session.max_bytes = reg.settings.storage_session_max
		// a reload starts the action and the alarms over (Chrome's reload is a new install of the same id)
		action_state_destroy(&e.action)
		e.action.title = strings.clone(m.action.title)
		e.action.popup = strings.clone(m.action.popup)
		e.action.badge = strings.clone("")
		e.action.badge_color = {0xD9, 0x30, 0x25, 0xFF}
		e.action.enabled = true
		area_destroy(&e.session)
		// runtime.onInstalled: an install, or a reload (Chrome: an update of the same id); none at the browser's start
		e.installed = fresh ? "install" : (first ? "" : "update")
	}
	grants_compile(e)
	registry_changed(reg)
	return e
}

@(private)
grant_add :: proc(e: ^Extension, source: string) {
	for g in e.granted { if g == source { return } }
	append(&e.granted, strings.clone(source))
}

// Removes the extension from the registry (its record is freed: the caller stopped everything that ran for it).
registry_remove :: proc(reg: ^Registry, id: string) -> bool {
	for e, i in reg.list {
		if e.id != id { continue }
		ordered_remove(&reg.list, i)
		extension_free(e)
		registry_changed(reg)
		return true
	}
	return false
}

// Whether the extension may act on `href` (docs/extensions.md 3.11 rule 2 and 4): a granted host pattern covers it, and
// it is not a restricted document (Wren's own pages, another extension's pages, extensions.restricted_hosts).
extension_host_allowed :: proc(reg: ^Registry, e: ^Extension, href: string) -> bool {
	u, ok := url.parse(href, nil, context.temp_allocator)
	if !ok { return false }
	switch u.scheme {
	case "http", "https", "ws", "wss", "ftp", "file":
	case: return false
	}
	if reg.settings.restricted_hosts != "" {
		rest := reg.settings.restricted_hosts
		for h in strings.fields_iterator(&rest) { if ascii_fold_equal(h, u.host) { return false } }
	}
	if u.scheme == "file" { return false }   // file URLs need the switch "allow access to file URLs" (off; not offered yet)
	for p in e.grants { if pattern_matches(p, u) { return true } }
	return false
}

// Compiles the grants again (after a change of `granted`).
grants_compile :: proc(e: ^Extension) {
	clear(&e.grants)
	for g in e.granted { if p, ok := pattern_parse(g); ok { append(&e.grants, p) } }
}

// Grants or withdraws one host pattern (about:extensions' switch). The caller saves the list.
grant_set :: proc(reg: ^Registry, e: ^Extension, source: string, on: bool) {
	if on {
		grant_add(e, source)
	} else {
		for g, i in e.granted { if g == source { ordered_remove(&e.granted, i); delete(g); break } }
	}
	grants_compile(e)
	registry_changed(reg)
}

////////////////////////////////
// The list (<profile>/extensions.txt)

LIST_FILE :: "extensions.txt"

// One line per extension: "1", id, flavour, source, path, enabled, grants (space-separated patterns), each field escaped
// (base.field_escaped). A line of another version is skipped.
List_Entry :: struct {
	id:      string,
	source:  Source_Kind,
	path:    string,
	enabled: bool,
	granted: []string,
}

registry_list_text :: proc(reg: ^Registry, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for e in reg.list {
		flavour := e.image != nil ? FLAVOUR_NAMES[e.image.manifest.flavour] : FLAVOUR_NAMES[.Chrome]
		grants := strings.join(e.granted[:], " ", context.temp_allocator)
		fmt.sbprintf(&b, "1\t%s\t%s\t%s\t%s\t%d\t%s\n", e.id, flavour, SOURCE_NAMES[e.source], base.field_escaped(e.path), e.enabled ? 1 : 0, base.field_escaped(grants))
	}
	return strings.to_string(b)
}

// The entries of a list text (temp allocator).
registry_list_parse :: proc(text: string) -> []List_Entry {
	out := make([dynamic]List_Entry, 0, 8, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 7 || f[0] != "1" || !id_valid(f[1]) { continue }
		le := List_Entry{id = f[1], path = base.field_unescape(f[4], context.temp_allocator), enabled = f[5] == "1"}
		for name, k in SOURCE_NAMES { if name == f[3] { le.source = k } }
		grants := base.field_unescape(f[6], context.temp_allocator)
		le.granted = strings.fields(grants, context.temp_allocator)
		append(&out, le)
	}
	return out[:]
}

// A placeholder record for a listed extension, before its package is loaded (registry_adopt fills it).
registry_add_listed :: proc(reg: ^Registry, le: List_Entry) -> ^Extension {
	if e := registry_find(reg, le.id); e != nil { return e }
	e := new(Extension)
	e.id = strings.clone(le.id)
	e.path = strings.clone(le.path)
	e.source = le.source
	e.enabled = le.enabled
	e.loading = true
	for g in le.granted { append(&e.granted, strings.clone(g)) }
	grants_compile(e)
	e.granted_known = true
	append(&reg.list, e)
	registry_changed(reg)
	return e
}

// Asks the shell's writer to save the list.
registry_save_list :: proc(reg: ^Registry) {
	if reg.dir == "" || reg.write == nil { return }
	reg.write(reg.write_user, fmt.tprintf("%s/%s", reg.dir, LIST_FILE), registry_list_text(reg), false)
}

////////////////////////////////
// state.txt: the events the background listens to

STATE_FILE :: "state.txt"

state_file :: proc(profile_dir, id: string) -> string {
	return fmt.tprintf("%s/extensions/%s/%s", profile_dir, id, STATE_FILE)
}

// "1", tab, "listeners", tab, the event names separated by spaces (sorted: the same set gives the same text). A line
// of another version or kind is skipped (temp allocator).
state_serialize :: proc(listeners: []string) -> string {
	names := slice.clone(listeners, context.temp_allocator)
	slice.sort(names)
	return fmt.tprintf("1\tlisteners\t%s\n", strings.join(names, " ", context.temp_allocator))
}

state_parse :: proc(text: string) -> []string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 || f[0] != "1" || f[1] != "listeners" { continue }
		out := make([dynamic]string, 0, 8, context.temp_allocator)
		for name in strings.fields(f[2], context.temp_allocator) {
			// (an event name is a dotted identifier: anything else in the file is not ours)
			if len(name) <= 128 && strings.contains_rune(name, '.') { append(&out, name) }
		}
		return out[:]
	}
	return nil
}

// Asks the shell's writer to save state.txt (the extension's listeners changed).
registry_save_state :: proc(reg: ^Registry, e: ^Extension) {
	if reg.dir == "" || reg.write == nil { return }
	reg.write(reg.write_user, state_file(reg.dir, e.id), state_serialize(e.listeners[:]), false)
}

////////////////////////////////
// idle (the data model of idle.queryState and idle.onStateChanged; the shell gives the time since the last input)

Idle_State :: enum u8 { Active, Idle, Locked }
IDLE_STATE_NAMES := [Idle_State]string{.Active = "active", .Idle = "idle", .Locked = "locked"}

IDLE_DEFAULT_INTERVAL :: 60   // seconds (Chrome's)
IDLE_MIN_INTERVAL :: 15       // seconds: a shorter interval is raised to this (Chrome's)

// The state for `idle_seconds` since the last input and a detection interval (seconds). `locked`: the system says the
// screen is locked (Wren does not know it on every system: false there).
idle_state_of :: proc(idle_seconds: f64, interval: int, locked: bool) -> Idle_State {
	if locked { return .Locked }
	n := interval > 0 ? max(interval, IDLE_MIN_INTERVAL) : IDLE_DEFAULT_INTERVAL
	return idle_seconds >= f64(n) ? .Idle : .Active
}

// Asks the shell's writer to save the areas that changed (local, sync).
registry_save_areas :: proc(reg: ^Registry, e: ^Extension) {
	if reg.dir == "" || reg.write == nil { return }
	if e.local.dirty { e.local.dirty = false; reg.write(reg.write_user, area_file(reg.dir, e.id, .Local), area_serialize(&e.local), false) }
	if e.sync.dirty { e.sync.dirty = false; reg.write(reg.write_user, area_file(reg.dir, e.id, .Sync), area_serialize(&e.sync), false) }
}

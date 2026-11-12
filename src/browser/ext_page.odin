package browser

// about:extensions (docs/extensions.md, section 3.10): the extensions installed, their state, warnings and errors, their
// granted hosts; "Load unpacked" (a folder dialog, or a path typed in the form), the install prompt, enable, disable,
// reload, remove, and a switch per host pattern. Built like about:sites: an HTML page made from the registry when it is
// shown (never per frame), whose links act only when the person or the page itself follows them (nav_trust.odin).
//
//   about:extensions?load=pick                  the folder dialog, then the package is read off the loop thread
//   about:extensions?load=file                  the file dialog for a .zip or .crx package, unpacked off the loop thread
//   about:extensions?path=<folder or file>      the same with a path typed in (a .zip or .crx file is unpacked)
//   about:extensions?accept=<id> / cancel=<id>  the install prompt's answer
//   about:extensions?enable= / disable= / reload= / remove=<id>
//   about:extensions?grant=<id>&host=<pattern> / revoke=<id>&host=<pattern>

import "core:fmt"
import "core:strings"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:extensions"
import "wb:host"
import "wb:page"
import "wb:url"

EXTENSIONS_URL :: "about:extensions"

is_extensions_address :: proc(a: string) -> bool { return a == EXTENSIONS_URL || strings.has_prefix(a, EXTENSIONS_URL + "?") }

@(private = "file")
EXT_PAGE_STYLE :: `
  html { background-color: #0d1017; }
  body { margin: 0; color: #c9d1e3; font-family: system-ui; font-size: 14px; }
  .main { max-width: 900px; box-sizing: border-box; margin: 0 auto; padding: 28px 20px; }
  h1 { font-size: 26px; margin: 0 0 6px; color: #f1f4fb; }
  .intro { color: #8993ad; margin: 0 0 18px; }
  .notice { margin: 0 0 16px; padding: 8px 14px; border-radius: 8px; background-color: #10213f; border: 1px solid #2f5ea8; color: #c9dcf7; }
  form { display: flex; gap: 8px; margin: 0 0 20px; }
  input[type=text] { flex: 1; padding: 6px 10px; background-color: #131825; color: #c9d1e3; border: 1px solid #2c3550; border-radius: 6px; }
  button, .btn { padding: 6px 14px; border-radius: 6px; border: 1px solid #2f5ea8; background-color: #10213f; color: #9cc0f2; text-decoration: none; display: inline-block; }
  .btn.bad { border-color: #a83a2f; background-color: #3f1410; color: #f2a59c; }
  .btn.good { border-color: #2f8a4a; background-color: #10301b; color: #9ce2b0; }
  .card { margin: 12px 0; padding: 14px 18px; background-color: #131825; border: 1px solid #232b40; border-radius: 12px; }
  .card.prompt { border-color: #a8862f; }
  .card h3 { margin: 0 0 4px; font-size: 17px; color: #f1f4fb; }
  .card h3 .v { color: #8993ad; font-weight: normal; font-size: 14px; margin-left: 8px; }
  .meta { color: #8993ad; margin: 2px 0; word-break: break-all; }
  .err { color: #f2a59c; margin: 4px 0; }
  .warn { color: #e8c77a; margin: 2px 0; font-size: 13px; }
  .acts { margin: 10px 0 0; display: flex; gap: 8px; flex-wrap: wrap; }
  ul { margin: 4px 0; padding-left: 20px; }
  li { margin: 2px 0; }
  li a { color: #ffb84d; text-decoration: none; margin-left: 8px; font-size: 13px; }
  code { color: #c9d1e3; background-color: #1b2132; padding: 0 3px; border-radius: 3px; }
  .off { opacity: 0.6; }
`

@(private = "file")
ext_param :: proc(query, name: string) -> string {
	sp := url.params_make(context.temp_allocator)
	url.params_parse(&sp, query)
	v, _ := url.params_get(sp, name)
	return v
}

@(private = "file")
EXT_KEEP :: url.UNRESERVED

@(private = "file")
ext_link :: proc(sb: ^strings.Builder, query, label, class: string) {
	fmt.sbprintf(sb, `<a class="btn %s" href="%s?%s">%s</a>`, class, EXTENSIONS_URL, query, escape_html(label))
}

// What a permission lets an extension do, in plain words (the install prompt).
@(private = "file")
ext_permission_words :: proc(p: string) -> string {
	switch p {
	case "storage", "unlimitedStorage": return "Store data on this computer"
	case "tabs":                        return "Read the addresses and titles of your tabs"
	case "activeTab":                   return "Act on the page you are on when you click its button"
	case "alarms":                      return "Run on a schedule"
	case "scripting":                   return "Insert scripts into pages"
	case "webRequest":                  return "See your browsing requests"
	case "webRequestAuthProvider":      return "Answer sign-in requests of sites"
	case "clipboardRead":               return "Read what you copy"
	case "clipboardWrite":              return "Write to the clipboard"
	case "contextMenus":                return "Add entries to the context menu"
	case "notifications":               return "Show notifications"
	case "idle":                        return "Know when the computer is idle"
	case "webNavigation":               return "See the pages you open"
	case "offscreen":                   return "Run hidden pages"
	case "nativeMessaging":             return "Talk to programs of this computer"
	}
	return p
}

@(private = "file")
ext_hosts_words :: proc(p: extensions.Pattern) -> string {
	if p.all_urls || (p.any_host && p.scheme == "*") { return "Read and change your data on all sites" }
	if p.any_host && (p.scheme == "https" || p.scheme == "http") { return fmt.tprintf("Read and change your data on all %s sites", p.scheme) }
	return fmt.tprintf("Read and change your data on %s", p.source)
}

ext_page_html :: proc(app: ^App) -> string {
	reg := ext_reg(app)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Extensions</title>\n<style>%s</style>\n</head>\n<body>\n<div class=\"main\">\n<h1>Extensions</h1>\n", EXT_PAGE_STYLE)
	strings.write_string(&sb, "<p class=\"intro\">Browser extensions (Manifest V3, Chrome builds). Load an unpacked extension from its folder (the one that holds its <code>manifest.json</code>), or install a <code>.zip</code> or <code>.crx</code> package.</p>\n")
	if !reg.settings.enabled { strings.write_string(&sb, "<p class=\"notice\">Extensions are off (<code>extensions.enabled</code> in about:config).</p>\n") }
	if app.ext.notice != "" { fmt.sbprintf(&sb, "<p class=\"notice\">%s</p>\n", escape_html(app.ext.notice)) }
	if app.ext.loading > 0 { strings.write_string(&sb, "<p class=\"notice\">Loading…</p>\n") }
	fmt.sbprintf(&sb, "<form action=\"%s\" method=\"get\"><input type=\"text\" name=\"path\" placeholder=\"Folder of an unpacked extension, or a .zip or .crx file\"><button type=\"submit\">Load</button>", EXTENSIONS_URL)
	ext_link(&sb, "load=pick", "Load unpacked…", "")
	ext_link(&sb, "load=file", "Install from file…", "")
	strings.write_string(&sb, "</form>\n")

	// the install prompts: what the extension may do, in plain words
	for p in app.ext.pending {
		im := p.image
		m := &im.manifest
		fmt.sbprintf(&sb, "<div class=\"card prompt\"><h3>Add %s?<span class=\"v\">%s</span></h3>", escape_html(m.name), escape_html(m.version))
		strings.write_string(&sb, "<p class=\"meta\">It will be able to:</p><ul>")
		for h in m.host_permissions { fmt.sbprintf(&sb, "<li>%s</li>", escape_html(ext_hosts_words(h))) }
		seen := make(map[string]bool, 8, context.temp_allocator)
		for perm in m.permissions {
			w := ext_permission_words(perm)
			if seen[w] { continue }
			seen[w] = true
			fmt.sbprintf(&sb, "<li>%s</li>", escape_html(w))
		}
		strings.write_string(&sb, "</ul>")
		fmt.sbprintf(&sb, "<p class=\"meta\">From %s</p>", escape_html(p.path))
		for pr in im.problems { if !pr.error { fmt.sbprintf(&sb, "<p class=\"warn\">%s</p>", escape_html(pr.text)) } }
		strings.write_string(&sb, "<div class=\"acts\">")
		ext_link(&sb, fmt.tprintf("accept=%s", im.id), "Add extension", "good")
		ext_link(&sb, fmt.tprintf("cancel=%s", im.id), "Cancel", "")
		strings.write_string(&sb, "</div></div>\n")
	}

	if len(reg.list) == 0 && len(app.ext.pending) == 0 { strings.write_string(&sb, "<p class=\"meta\">No extension is installed.</p>\n") }
	for e in reg.list {
		im := e.image
		name := im != nil ? im.manifest.name : e.id
		version := im != nil ? im.manifest.version : ""
		fmt.sbprintf(&sb, "<div class=\"card%s\"><h3>%s<span class=\"v\">%s</span></h3>", e.enabled ? "" : " off", escape_html(name), escape_html(version))
		if im != nil && im.manifest.description != "" { fmt.sbprintf(&sb, "<p class=\"meta\">%s</p>", escape_html(im.manifest.description)) }
		fmt.sbprintf(&sb, "<p class=\"meta\">ID <code>%s</code> · %s · %s · <code>%s</code></p>", e.id, im != nil ? extensions.FLAVOUR_NAMES[im.manifest.flavour] : "chrome", extensions.SOURCE_NAMES[e.source], escape_html(e.path))
		state := !e.enabled ? "Disabled" : (e.loading ? "Loading" : "Enabled")
		bg_text := ""
		if exists, running, starts := page.ext_bg_state(e.id); exists {
			bg_text = fmt.tprintf(" · background: %s, started %d time(s)", running ? "running" : "stopped", starts)
		}
		fmt.sbprintf(&sb, "<p class=\"meta\">%s%s</p>", state, bg_text)
		if e.error != "" { fmt.sbprintf(&sb, "<p class=\"err\">%s</p>", escape_html(e.error)) }
		if im != nil { for pr in im.problems { fmt.sbprintf(&sb, "<p class=\"%s\">%s</p>", pr.error ? "err" : "warn", escape_html(pr.text)) } }
		if len(e.unknown_calls) > 0 {
			names := make([dynamic]string, 0, len(e.unknown_calls), context.temp_allocator)
			for k in e.unknown_calls { append(&names, k) }
			fmt.sbprintf(&sb, "<p class=\"warn\">It called methods Wren does not have yet: %s</p>", escape_html(strings.join(names[:], ", ", context.temp_allocator)))
		}
		// host permissions: granted ones can be withdrawn, the manifest's others granted again
		if im != nil && (len(e.granted) > 0 || len(im.manifest.host_permissions) > 0) {
			strings.write_string(&sb, "<p class=\"meta\">Site access:</p><ul>")
			for g in e.granted {
				fmt.sbprintf(&sb, "<li><code>%s</code><a href=\"%s?revoke=%s&amp;host=%s\">withdraw</a></li>", escape_html(g), EXTENSIONS_URL, e.id, url.percent_encoded(g, EXT_KEEP))
			}
			for h in im.manifest.host_permissions {
				granted := false
				for g in e.granted { if g == h.source { granted = true } }
				if granted { continue }
				fmt.sbprintf(&sb, "<li class=\"off\"><code>%s</code><a href=\"%s?grant=%s&amp;host=%s\">grant</a></li>", escape_html(h.source), EXTENSIONS_URL, e.id, url.percent_encoded(h.source, EXT_KEEP))
			}
			strings.write_string(&sb, "</ul>")
		}
		strings.write_string(&sb, "<div class=\"acts\">")
		if e.enabled { ext_link(&sb, fmt.tprintf("disable=%s", e.id), "Disable", "") } else { ext_link(&sb, fmt.tprintf("enable=%s", e.id), "Enable", "good") }
		ext_link(&sb, fmt.tprintf("reload=%s", e.id), "Reload", "")
		ext_link(&sb, fmt.tprintf("remove=%s", e.id), "Remove", "bad")
		strings.write_string(&sb, "</div></div>\n")
	}
	strings.write_string(&sb, "<p class=\"meta\">Limits are preferences in about:config: <code>extensions.*</code>.</p>\n</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

// about:extensions and its actions (`acts`: from nav_judge, the person or the page's own links).
show_extensions_page :: proc(app: ^App, t: ^Tab, target: string, acts: bool) {
	query := ""
	if i := strings.index_byte(target, '?'); i >= 0 { query = target[i + 1:] }
	if query != "" && acts && app.ext.started {
		switch {
		case ext_param(query, "load") == "pick":   ext_pick_folder(app)
		case ext_param(query, "load") == "file":   ext_pick_folder(app, archive = true)
		case ext_param(query, "path") != "":       ext_notice(app, ""); ext_load(app, strings.trim_space(ext_param(query, "path")), .Install)
		case ext_param(query, "accept") != "":     ext_accept(app, ext_param(query, "accept"))
		case ext_param(query, "cancel") != "":     ext_cancel(app, ext_param(query, "cancel"))
		case ext_param(query, "enable") != "":     ext_set_enabled(app, ext_param(query, "enable"), true)
		case ext_param(query, "disable") != "":    ext_set_enabled(app, ext_param(query, "disable"), false)
		case ext_param(query, "reload") != "":     ext_reload(app, ext_param(query, "reload"))
		case ext_param(query, "remove") != "":     ext_remove(app, ext_param(query, "remove"))
		case ext_param(query, "grant") != "":      ext_grant(app, ext_param(query, "grant"), ext_param(query, "host"), true)
		case ext_param(query, "revoke") != "":     ext_grant(app, ext_param(query, "revoke"), ext_param(query, "host"), false)
		}
		// the entry is about:extensions again: going back here must not act once more
		page.session_replace(&t.session, EXTENSIONS_URL)
		sync_history(app, t)
	}
	ext_page_show(app, t)
}

@(private = "file")
ext_page_show :: proc(app: ^App, t: ^Tab) {
	nav_show_page(app, t, EXTENSIONS_URL)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	for l in t.console { delete(l) }
	clear(&t.console)
	page.load_html(t.page, transmute([]byte)ext_page_html(app))
	delete(t.url); t.url = strings.clone(EXTENSIONS_URL)
	delete(t.title); t.title = strings.clone("Extensions")
	set_status(t, EXTENSIONS_URL)
}

// The tabs that show about:extensions show it again (a load or the folder dialog ended): a navigation of their own,
// never inside another one (it is called from tasks of the loop only).
ext_page_refresh :: proc(app: ^App) {
	ids := make([dynamic]u64, 0, 2, context.temp_allocator)
	for t in tabs_all(app) { if is_extensions_address(t.url) { append(&ids, t.id) } }
	for id in ids { if t := tab_find(app, id); t != nil { navigate(app, t, EXTENSIONS_URL, record = false, origin = .User) } }
}

// "Load unpacked" (`archive`: "Install from file"): the system's folder (file) dialog on a thread of its own; what is
// chosen is loaded off the loop thread.
@(private = "file")
Ext_Pick_Job :: struct { app: ^App, owner: ^platform.Window, chosen: string, archive: bool }

@(private = "file")
EXT_PACKAGE_PATTERNS := [?]string{"*.zip", "*.crx"}

ext_pick_folder :: proc(app: ^App, archive := false) {
	if app.ext.picking { return }
	job := new(Ext_Pick_Job)
	job.app = app
	job.owner = active_window(app).win
	job.archive = archive
	started := host.run_dialog(&app.dialogs, proc(data: rawptr) {
		j := (^Ext_Pick_Job)(data)
		res: platform.Dialog_Result
		if j.archive {
			filters := [1]platform.File_Filter{{name = "Extension packages (.zip, .crx)", patterns = EXT_PACKAGE_PATTERNS[:]}}
			dlg := platform.File_Dialog{owner = j.owner, title = "Extension package", filters = filters[:], all_files = true, remember_id = "extension_file"}
			res = platform.open_file_dialog(dlg, context.allocator)
		} else {
			dlg := platform.File_Dialog{owner = j.owner, title = "Folder of an unpacked extension", remember_id = "extension_dir"}
			res = platform.pick_folder_dialog(dlg, context.allocator)
		}
		defer platform.dialog_result_destroy(&res, context.allocator)
		if res.status == .Chosen && len(res.paths) > 0 { j.chosen = strings.clone(res.paths[0]) }
	}, proc(data: rawptr) {
		j := (^Ext_Pick_Job)(data)
		j.app.ext.picking = false
		if j.chosen != "" && j.app.ext.started { ext_load(j.app, j.chosen, .Install); ext_page_refresh(j.app) }   // ("Loading…" until the load ends)
		delete(j.chosen); free(j)
	}, job, proc(data: rawptr) {
		j := (^Ext_Pick_Job)(data)
		delete(j.chosen); free(j)
	})
	if !started {
		ui.toast(.Bad, "The folder dialog could not be opened")
		free(job)
		return
	}
	app.ext.picking = true
}

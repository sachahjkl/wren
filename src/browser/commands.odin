package browser

// The browser's commands, in one registry: the keyboard shortcuts of the chrome (chrome_shortcuts), the main menu and
// the command palette (palette.odin) all act through it, so a command has one label, one set of keys, one
// condition and one action wherever it is offered.
//
// A command's `name` is its stable identity (the palette's usage memory is keyed by it): dotted, lower case, never
// reused for something else. Its first key is the one shown in menus and in the palette (ui.command_shortcut); the others
// are aliases.

import "core:fmt"
import "core:strings"
import "toolkit:platform"
import prefs_page "toolkit:prefs_page"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:i18n"
import "wb:page"

Command_Proc :: proc(app: ^App, t: ^Tab, c: ^Command)
Command_Test :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool

// A command is the toolkit's (ui.Command: its label, group, tags, keys and icon, which the menus, the palette and the key
// handling read) with what only the browser has: its stable name, its condition and its action.
Command :: struct {
	using spec:  ui.Command,
	name:        string,           // stable identity: "tab.new"
	url:         string,           // the command opens this page: Ctrl+Enter in the palette opens it in a new tab
	arg:         string,           // parameter of a generated command (the theme's name)
	enabled:     Command_Test,     // nil: always
	checked:     Command_Test,     // nil: not a toggle
	run:         Command_Proc,
	hidden:      bool,             // not offered by the palette (its own shortcut, for instance)
	guarded:     bool,             // its keys act (and take the key) only while it is enabled
	chrome_only: bool,             // acts on the chrome alone (the address bar, which tab is shown): done at once in a chrome frame too, under a busy page
	// (a ui.Chord has no condition and a ui.Command two keys: these two say what the toolkit cannot yet)
	key_pref:    string,           // not "": its second key acts only while this boolean preference is on
	third_key:   ui.Chord,         // a third key, never shown (Ctrl+Shift+= for Zoom in: the + of a US keyboard)
}

Command_Registry :: struct {
	list:  [dynamic]Command,
	index: map[string]int,
	arena: base.Arena,       // generated names and labels, and the tags of the commands
	built: bool,
}

// The registry, built at first use.
commands :: proc(app: ^App) -> []Command {
	if !app.cmds.built { commands_build(&app.cmds) }
	return app.cmds.list[:]
}

command :: proc(app: ^App, name: string) -> ^Command {
	if !app.cmds.built { commands_build(&app.cmds) }
	if i, ok := app.cmds.index[name]; ok { return &app.cmds.list[i] }
	return nil
}

commands_destroy :: proc(r: ^Command_Registry) {
	if !r.built { return }
	delete(r.list)
	delete(r.index)
	base.arena_destroy(&r.arena)
	r^ = {}
}

command_enabled :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return c.enabled == nil || c.enabled(app, t, c) }

// Runs `c` when it is enabled; true when it ran.
command_run :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool {
	if c == nil || c.run == nil || !command_enabled(app, t, c) { return false }
	// during a chrome frame (shell_frames.odin) once the page holding the thread is done, but what acts on the chrome alone
	if shell_nested() && !c.chrome_only { shell_defer({kind = .Command, tab = t != nil ? t.id : 0, text = strings.clone(c.name)}); return true }
	c.run(app, t, c)
	request_frames(app, 2)
	return true
}

// The words of `text` (spaces between them) as a command's tags, in the registry's memory.
command_words :: proc(r: ^Command_Registry, text: string) -> []string {
	return strings.fields(text, base.arena_allocator(&r.arena))
}

// The shortcuts of the chrome that are not commands of the registry (they depend on what has the keyboard, or are a
// family): the registry's own must not take them (palette_test.odin).
RESERVED_SHORTCUTS := [?]ui.Chord{
	{key = .Escape},                   // stops a load / closes the frame statistics, when nothing has the keyboard
	{key = .Menu}, {key = .F10, mods = {.Shift}},   // the context menu of what has the keyboard
	{key = .N1, mods = {.Ctrl}}, {key = .N2, mods = {.Ctrl}}, {key = .N3, mods = {.Ctrl}}, {key = .N4, mods = {.Ctrl}},
	{key = .N5, mods = {.Ctrl}}, {key = .N6, mods = {.Ctrl}}, {key = .N7, mods = {.Ctrl}}, {key = .N8, mods = {.Ctrl}},
	{key = .N9, mods = {.Ctrl}},       // tab 1..8, the last tab
}

// The registry's keys that were pressed this frame run their command (the first one found takes the key, as the
// chrome's single switch did). True when one ran.
commands_dispatch :: proc(app: ^App) -> bool {
	t := current_tab(app)
	for &c in commands(app) {
		if !command_pressed(app, &c, !c.guarded || command_enabled(app, t, &c)) { continue }
		command_run(app, t, &c)
		return true
	}
	return false
}

// One of the command's keys was pressed this frame (ui.command_pressed: the press is taken), the second only while its
// key_pref is on, the third too. `enabled` false: none is taken.
command_pressed :: proc(app: ^App, c: ^Command, enabled := true) -> bool {
	spec := c.spec
	if c.key_pref != "" && !config.bool_of(&app.prefs, c.key_pref) { spec.keys[1] = {} }
	if ui.command_pressed(spec, enabled) { return true }
	return enabled && c.third_key.key != .None && ui.key_press(c.third_key.key, c.third_key.mods)
}

// A menu item for a command: its title, first shortcut, glyph, check mark and condition. True when it ran.
menu_command :: proc(app: ^App, t: ^Tab, name: string, title := "", force_disabled := false) -> bool {
	c := command(app, name)
	if c == nil { return false }
	checked := c.checked != nil && c.checked(app, t, c)
	if ui.menu_item(title != "" ? title : c.label, ui.command_shortcut(c.spec), checked = checked, icon = c.icon, enabled = !force_disabled && command_enabled(app, t, c)).clicked {
		return command_run(app, t, c)
	}
	return false
}

////////////////////////////////
// The commands

@(private = "file")
web_tab :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web }
@(private = "file")
has_tab :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil }
@(private = "file")
web_page :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web && t.page != nil }

// The host of the tab's document ("" for about:, file:, data: documents and other views).
tab_host :: proc(t: ^Tab) -> string {
	if t == nil || t.kind != .Web || t.page == nil { return "" }
	return base.ascii_lower(t.page.env.location.host)
}

// Registers a command: its name is new, its icon comes from command_icons.odin.
command_add :: proc(r: ^Command_Registry, c: Command) {
	assert(c.name not_in r.index, "commands: duplicate name")
	r.index[c.name] = len(r.list)
	c := c
	c.icon = command_icon(c.name)
	append(&r.list, c)
}

commands_build :: proc(r: ^Command_Registry) {
	if r.built { return }
	r.built = true
	_ = base.arena_init_growing(&r.arena)
	a := base.arena_allocator(&r.arena)
	r.index = make(map[string]int)
	r.list = make([dynamic]Command)
	add :: command_add
	ctrl, cs, alt, shift := platform.Modifiers{.Ctrl}, platform.Modifiers{.Ctrl, .Shift}, platform.Modifiers{.Alt}, platform.Modifiers{.Shift}

	// --- tabs
	add(r, {name = "tab.new", label = "New tab", group = "Tabs", keys = {{key = .T, mods = ctrl}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_open_new(app) }})
	add(r, {name = "tab.reopen_closed", label = "Reopen closed tab", group = "Tabs", tags = command_words(r, "undo close restore"), keys = {{key = .T, mods = cs}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(closed_items(app)) > 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { reopen_closed_tab(app) }})
	add(r, {name = "tab.close", label = "Close tab", group = "Tabs", keys = {{key = .W, mods = ctrl}, {key = .F4, mods = ctrl}},
		// (the tab it is given: the current one from its shortcut, the one right-clicked from the tab's menu)
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_close_by_user(app, t) }})
	add(r, {name = "tab.close_others", label = "Close other tabs", group = "Tabs",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(active_window(app).tabs) > 1 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			w := active_window(app)
			for x, i in w.tabs { if x == t { close_other_tabs(app, i); return } }
		}})
	add(r, {name = "tab.duplicate", label = "Duplicate tab", group = "Tabs", tags = command_words(r, "copy clone"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.url != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { open_in_new_tab(app, t.url, origin = .Replay) }})
	add(r, {name = "tab.next", label = "Next tab", group = "Tabs", tags = command_words(r, "switch"), keys = {{key = .Tab, mods = ctrl}, {key = .Page_Down, mods = ctrl}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(active_window(app).tabs) > 1 },
		chrome_only = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { n := len(active_window(app).tabs); if n > 0 { tab_select(app, (active_window(app).current + 1) % n) } }})
	add(r, {name = "tab.previous", label = "Previous tab", group = "Tabs", tags = command_words(r, "switch"), keys = {{key = .Tab, mods = cs}, {key = .Page_Up, mods = ctrl}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(active_window(app).tabs) > 1 },
		chrome_only = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { n := len(active_window(app).tabs); if n > 0 { tab_select(app, (active_window(app).current + n - 1) % n) } }})
	add(r, {name = "tab.move_right", label = "Move tab right", group = "Tabs", keys = {{key = .Page_Down, mods = cs}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return active_window(app).current + 1 < len(active_window(app).tabs) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_move_current(app, +1) }})
	add(r, {name = "tab.move_left", label = "Move tab left", group = "Tabs", keys = {{key = .Page_Up, mods = cs}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return active_window(app).current > 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_move_current(app, -1) }})
	add(r, {name = "tab.move_to_new_window", label = "Move tab to a new window", group = "Tabs", tags = command_words(r, "detach pop out separate window"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool {
			w, _ := window_of_tab(app, t)
			return w != nil && len(window_tabs(app, w)) > 1
		},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_detach(app, t) }})
	// pinned tabs and groups (tab_groups.odin)
	add(r, {name = "tab.pin", label = i18n.tr("Pin or unpin tab"), group = "Tabs", tags = command_words(r, "pinned app tab sticky keep"),
		enabled = has_tab, checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.pinned },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_set_pinned(app, t, !t.pinned) }})
	add(r, {name = "tab.mute", label = i18n.tr("Mute or unmute tab"), group = "Tabs", tags = command_words(r, "sound audio silence speaker volume"),
		enabled = has_tab, checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.muted },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_set_muted(app, t, !t.muted) }})
	add(r, {name = "tab.fold", label = i18n.tr("Fold or show the tabs this tab opened"), group = "Tabs", tags = command_words(r, "tree children collapse expand fold"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && tab_tree_has_children(app, t) },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.fold },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_tree_toggle(app, t) }})
	add(r, {name = "tab.group_new", label = i18n.tr("Add tab to a new group"), group = "Tabs", tags = command_words(r, "group tabs together organize"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { _ = tab_group_new(app, t) }})
	add(r, {name = "tab.group_leave", label = i18n.tr("Remove tab from its group"), group = "Tabs", tags = command_words(r, "ungroup group"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_group_leave(app, t) }})
	add(r, {name = "tab.group_collapse", label = i18n.tr("Collapse or expand the tab's group"), group = "Tabs", tags = command_words(r, "group fold hide"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			w, _ := window_of_tab(app, t)
			if gi := group_index(w.groups[:], t.group); gi >= 0 { group_set_collapsed(app, w, t.group, !w.groups[gi].collapsed) }
		}})
	add(r, {name = "tab.group_rename", label = i18n.tr("Rename the tab's group"), group = "Tabs", tags = command_words(r, "group name title"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 && app.favs.cfg.position != .Top },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { group_rename_begin(app, t.group) }})
	for gc in Group_Color {
		add(r, {name = fmt.aprintf("tab.group_color.%s", GROUP_COLOR_NAMES[gc], allocator = a), label = fmt.aprintf("%s: %s", i18n.tr("Tab group colour"), GROUP_COLOR_NAMES[gc], allocator = a),
			group = "Tabs", tags = command_words(r, "group colour color"), arg = GROUP_COLOR_NAMES[gc],
			enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 },
			run = proc(app: ^App, t: ^Tab, c: ^Command) {
				w, _ := window_of_tab(app, t)
				if col, ok := group_color_of(c.arg); ok { group_set_color(app, w, t.group, col) }
			}})
	}
	add(r, {name = "window.new", label = "New window", group = "Window", tags = command_words(r, "open another"), keys = {{key = .N, mods = ctrl}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { window_new(app) }})
	add(r, {name = "window.new_private", label = i18n.tr("New private window"), group = "Window", tags = command_words(r, "incognito private browsing inprivate"),
		keys = {{key = .N, mods = cs}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { private_window_open(app) }})
	add(r, {name = "browser.session_restore", label = i18n.tr("Restore tabs at start-up"), group = "Tabs", tags = command_words(r, "session reopen previous startup"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return config.bool_of(&app.prefs, "browser.session.restore") },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "browser.session.restore", !config.bool_of(&app.prefs, "browser.session.restore")) }})
	add(r, {name = "tab.restore_crashed", label = "Restore the tabs of the session that crashed", group = "Tabs", tags = command_words(r, "crash recovery reopen saved"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.recovery.backup != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { recovery_restore_backup(app) }})

	// --- navigation
	add(r, {name = "nav.back", label = "Back", group = "Navigation", tags = command_words(r, "history previous page"), keys = {{key = .Left, mods = alt}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.hist > 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { go_history(app, t, -1) }})
	add(r, {name = "nav.forward", label = "Forward", group = "Navigation", tags = command_words(r, "history next page"), keys = {{key = .Right, mods = alt}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.hist + 1 < len(t.history) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { go_history(app, t, +1) }})
	add(r, {name = "nav.reload", label = "Reload", group = "Navigation", tags = command_words(r, "refresh"), keys = {{key = .F5}, {key = .R, mods = ctrl}},
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if t.page != nil && page.navigation_user_reload(t.page) { return }   // the page's navigate listener took it
			reload(app, t)
		}})
	// the document and everything it loads from the network (cache mode reload); F5 only revalidates the document
	add(r, {name = "nav.reload_bypass_cache", label = "Reload without the cache", group = "Navigation", tags = command_words(r, "hard refresh force"),
		keys = {{key = .F5, mods = ctrl}, {key = .R, mods = cs}},
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if t.page != nil && page.navigation_user_reload(t.page) { return }
			reload(app, t, bypass_cache = true)
		}})
	add(r, {name = "nav.stop", label = "Stop loading", group = "Navigation", tags = command_words(r, "cancel abort"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.load != nil && t.load.task != base.NIL_HANDLE },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { stop_loading(app, t) }})
	add(r, {name = "nav.home", label = "Home", group = "Navigation", tags = command_words(r, "start page homepage"), keys = {{key = .Home, mods = alt}, {}},
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, app.cfg.homepage, origin = .User) }})
	add(r, {name = "nav.focus_address", label = "Focus the address bar", group = "Navigation", tags = command_words(r, "location url edit"), keys = {{key = .L, mods = ctrl}, {key = .D, mods = alt}},
		chrome_only = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_ask(app, .Address_Focus) }})
	add(r, {name = "nav.focus_toggle", label = "Address bar or page", group = "Navigation", tags = command_words(r, "focus switch keyboard"), keys = {{key = .F6}, {key = .F6, mods = shift}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if keyboard_owner(app) == .Chrome_Field { forms_focus_from_chrome(app, t, 1) } else { window_ask(app, .Address_Focus) }
		}})

	// --- the interface's own zoom (chrome_zoom.odin)
	add(r, {name = "view.chrome_zoom_in", label = "Zoom the interface in", group = "View", tags = command_words(r, "bigger larger chrome ui toolbar"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { chrome_zoom_step(app, 1) }})
	add(r, {name = "view.chrome_zoom_out", label = "Zoom the interface out", group = "View", tags = command_words(r, "smaller chrome ui toolbar"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { chrome_zoom_step(app, -1) }})
	add(r, {name = "view.chrome_zoom_reset", label = "Interface at actual size", group = "View", tags = command_words(r, "zoom reset 100 chrome ui toolbar"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { chrome_zoom_step(app, 0) }})

	// --- page
	add(r, {name = "page.zoom_in", label = "Zoom in", group = "Page", tags = command_words(r, "bigger larger magnify"),
		keys = {{key = .Equal, mods = ctrl}, {key = .Num_Add, mods = ctrl}}, third_key = {key = .Equal, mods = cs},
		enabled = web_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { zoom_step(app, t, 1) }})
	add(r, {name = "page.zoom_out", label = "Zoom out", group = "Page", tags = command_words(r, "smaller"), keys = {{key = .Minus, mods = ctrl}, {key = .Num_Subtract, mods = ctrl}},
		enabled = web_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { zoom_step(app, t, -1) }})
	add(r, {name = "page.zoom_reset", label = "Actual size", group = "Page", tags = command_words(r, "zoom reset 100"), keys = {{key = .N0, mods = ctrl}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web && zoom_percent(t) != 100 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { zoom_set(app, t, 1) }})
	add(r, {name = "page.find", label = "Find in page…", group = "Page", tags = command_words(r, "search text"), keys = {{key = .F, mods = ctrl}, {key = .F3}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && (t.kind == .Web || t.kind == .Config || t.kind == .History) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if t.kind == .Config { app.config_view.focus_search = true } else if t.kind == .History { app.hview.focus_search = true } else if fs := find_state(app); fs.open { fs.focus = true } else { find_open(app) }
		}})
	add(r, {name = "page.save", label = "Save page as…", group = "Page", tags = command_words(r, "download file"), keys = {{key = .S, mods = ctrl}, {}},
		enabled = web_page, run = proc(app: ^App, t: ^Tab, c: ^Command) { save_page(app, t) }})
	add(r, {name = "page.view_source", label = "View page source", group = "Page", tags = command_words(r, "html code"), keys = {{key = .U, mods = ctrl}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web && !strings.has_prefix(t.url, VIEW_SOURCE) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { view_source(app, t) }})
	// printing is not available (print.odin): the shortcut says so
	add(r, {name = "page.print", label = "Print…", group = "Page", keys = {{key = .P, mods = ctrl}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { print_request(app) }})
	add(r, {name = "page.copy_address", label = "Copy the page's address", group = "Page", tags = command_words(r, "url link clipboard"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.url != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { clip_set(t.url); announce(app, .Info, "Address copied") }})
	add(r, {name = "page.qr_code", label = "QR code of the page's address", group = "Page", tags = command_words(r, "share phone scan camera url link mobile"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web && t.url != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { qr_open(app, t.url) }})
	add(r, {name = "page.info", label = "Page information", group = "Page", tags = command_words(r, "security certificate cookies connection"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_ask(app, .Page_Info) }})
	add(r, {name = "page.javascript_site", label = "JavaScript on this site", group = "Page", tags = command_words(r, "script js enable disable block allow"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return tab_host(t) != "" },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return js_on_for(&app.prefs, tab_host(t)) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { js_toggle_site(app, t) }})

	// --- view
	// the frame rate (pacing.odin): the choices of browser.frame.cap, in their order
	cap_titles := [?][2]string{{FRAME_CAP_AUTO, i18n.tr("Frame rate: auto")}, {"60", i18n.tr("Frame rate: 60")}, {"120", i18n.tr("Frame rate: 120")}, {"240", i18n.tr("Frame rate: 240")}, {FRAME_CAP_CUSTOM, i18n.tr("Frame rate: custom (browser.frame.cap_custom_hz)")}, {FRAME_CAP_UNCAPPED, i18n.tr("Frame rate: uncapped")}}
	for x in cap_titles {
		add(r, {name = fmt.aprintf("view.frame_cap.%s", x[0], allocator = a), label = x[1], group = "View", arg = x[0], tags = command_words(r, "fps limit cap uncapped unlimited vsync frames per second"),
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.pacing.cfg.cap == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_string(app, "browser.frame.cap", c.arg) }})
	}
	add(r, {name = "view.status_bar", label = "Status bar", group = "View", keys = {{key = .B, mods = ctrl}, {}},
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.hud.cfg.bar_visible },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { toggle_status_bar(app) }})
	// (off, or back to following the system's animations: the standard scrolling.smooth)
	add(r, {name = "view.smooth_scrolling", label = "Smooth scrolling", group = "View", tags = command_words(r, "animated scroll wheel motion scrolling.smooth"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.smooth_cfg.mode != .Off },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_string(app, "scrolling.smooth", app.smooth_cfg.mode == .Off ? "follow" : "off") }})
	add(r, {name = "view.autoscroll", label = "Autoscroll (middle-click)", group = "View", tags = command_words(r, "middle button wheel drag pan speed scrolling.autoscroll.enabled"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.autoscroll_cfg.enabled },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "scrolling.autoscroll.enabled", !app.autoscroll_cfg.enabled) }})
	add(r, {name = "view.frame_statistics", label = "Frame statistics", group = "View", tags = command_words(r, "fps performance hud timing"), keys = {{key = .F, mods = cs}, {}},
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.hud.panel_open },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { toggle_frame_stats(app) }})
	add(r, {name = "view.title_statistics", label = "Statistics in the title", group = "View", tags = command_words(r, "fps"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.hud.cfg.title_stats },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "browser.title.stats", !app.hud.cfg.title_stats) }})
	add(r, {name = "view.devtools", label = "Developer tools", group = "View", tags = command_words(r, "inspect console elements network dom debug f12"),
		keys = {{key = .F12}, {key = .I, mods = cs}},
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_toggle(app) }})
	add(r, {name = "view.console", label = "Console", group = "View", tags = command_words(r, "log javascript eval devtools"),
		keys = {{key = .J, mods = cs}, {}},
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev_shows(dev(), .Console) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_toggle_panel(app, .Console) }})
	add(r, {name = "view.devtools_elements", label = "Developer tools: Elements", group = "View", tags = command_words(r, "inspect dom document tree html"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev_shows(dev(), .Elements) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Elements) }})
	add(r, {name = "view.devtools_network", label = "Developer tools: Network", group = "View", tags = command_words(r, "requests http fetch log"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev_shows(dev(), .Network) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Network) }})
	add(r, {name = "view.devtools_dock_bottom", label = "Developer tools: dock at the bottom", group = "View", tags = command_words(r, "devtools panel position"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Bottom },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_set_dock(app, .Bottom) }})
	add(r, {name = "view.devtools_dock_right", label = "Developer tools: dock at the right", group = "View", tags = command_words(r, "devtools panel position side"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Right },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_set_dock(app, .Right) }})
	add(r, {name = "view.devtools_dock_floating", label = "Developer tools: undock into a floating panel", group = "View", tags = command_words(r, "devtools panel position window"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Floating },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_set_dock(app, .Floating) }})
	add(r, {name = "view.devtools_application", label = "Developer tools: Application", group = "View", tags = command_words(r, "storage cookies local session cache manifest"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev_shows(dev(), .Application) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Application) }})
	add(r, {name = "view.devtools_performance", label = "Developer tools: Performance", group = "View", tags = command_words(r, "frames timing fps cpu gpu profile"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev_shows(dev(), .Performance) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Performance) }})
	add(r, {name = "view.devtools_memory", label = "Developer tools: Memory", group = "View", tags = command_words(r, "heap allocation leak usage"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev_shows(dev(), .Memory) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Memory) }})
	add(r, {name = "view.devtools_pick", label = "Developer tools: select an element in the page", group = "View", tags = command_words(r, "inspect picker element select eyedropper"),
		keys = {{key = .C, mods = cs}, {}}, enabled = has_tab,
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().picking },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_pick(app) }})
	add(r, {name = "view.devtools_dock_left", label = "Developer tools: dock at the left", group = "View", tags = command_words(r, "devtools panel position side"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Left && !devtools_detached() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { if devtools_detached() { devtools_attach(app) }; devtools_set_dock(app, .Left) }})
	add(r, {name = "view.devtools_detach", label = "Developer tools: open in a separate window", group = "View", tags = command_words(r, "devtools panel undock detach window second"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return devtools_detached() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { if devtools_detached() { devtools_attach(app) } else { devtools_detach(app) } }})
	add(r, {name = "view.devtools_larger", label = "Developer tools: larger text", group = "View", tags = command_words(r, "devtools zoom font size"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_zoom(app, 1) }})
	add(r, {name = "view.devtools_smaller", label = "Developer tools: smaller text", group = "View", tags = command_words(r, "devtools zoom font size"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_zoom(app, -1) }})
	add(r, {name = "view.devtools_reset_layout", label = "Developer tools: reset the layout", group = "View", tags = command_words(r, "devtools sizes columns panes default"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_reset_layout(app) }})
	add(r, {name = "view.devtools_clear_console", label = "Developer tools: clear the console", group = "View", tags = command_words(r, "devtools log messages empty"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { console_clear(app, t) }})
	add(r, {name = "view.devtools_clear_network", label = "Developer tools: clear the network log", group = "View", tags = command_words(r, "devtools requests empty"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { net_clear(&t.net); dev().net.has_sel = false }})
	for p in NET_BUILTIN {
		add(r, {name = fmt.aprintf("view.devtools_speed.%s", p.id, allocator = a), label = fmt.aprintf("Developer tools: network speed: %s", p.name, allocator = a), group = "View",
			tags = command_words(r, "devtools throttle throttling network speed slow offline 3g bandwidth latency"), arg = p.id, enabled = has_tab,
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return net_profile_of(app, t).id == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { net_profile_set(app, t, c.arg) }})
	}
	add(r, {name = "view.full_screen", label = "Full screen", group = "View", tags = command_words(r, "fullscreen kiosk"), keys = {{key = .F11}, {}},
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return platform.is_fullscreen(active_window(app).win) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { toggle_fullscreen(app) }})
	add(r, {name = "view.tabs_in_title_bar", label = "Tabs in the title bar", group = "View", tags = command_words(r, "integrated titlebar window"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.wchrome.cfg.integrated },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, prefs_page.SYSTEM_TITLE_PREF, app.wchrome.cfg.integrated) }})
	// the tabs along the top or in a sidebar (tab_sidebar.odin)
	pos_titles := [Tabs_Position]string{.Top = i18n.tr("Tabs: at the top"), .Left = i18n.tr("Tabs: in a sidebar at the left"), .Right = i18n.tr("Tabs: in a sidebar at the right")}
	for pos in Tabs_Position {
		add(r, {name = fmt.aprintf("view.tabs_position.%s", TABS_POSITION_NAMES[pos], allocator = a), label = pos_titles[pos], group = "View", arg = TABS_POSITION_NAMES[pos],
			tags = command_words(r, "tabs sidebar vertical side bar position left right top row horizontal layout"),
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return TABS_POSITION_NAMES[app.favs.cfg.position] == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { tabs_set_position(app, tabs_position_of(c.arg)) }})
	}
	add(r, {name = "view.tabs_sidebar_collapse", label = i18n.tr("Tab sidebar: icons only"), group = "View", tags = command_words(r, "tabs sidebar vertical collapse narrow compact titles"),
		keys = {{key = .Comma, mods = cs}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.favs.cfg.position != .Top },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.favs.cfg.side_collapsed },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tabs_toggle_collapsed(app) }})
	for th in ui.THEMES {
		slug, _ := strings.replace_all(base.ascii_lower(th.name, context.temp_allocator), " ", "_", a)
		add(r, {name = fmt.aprintf("view.theme.%s", slug, allocator = a), label = fmt.aprintf("Theme: %s", th.name, allocator = a), group = "View",
			tags = command_words(r, "colors appearance palette"), arg = th.name,
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return base.ascii_equal_fold(app.cfg.look.theme, c.arg) },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_string(app, prefs_page.THEME_PREF, c.arg) }})
	}

	for mode in ui.Theme_Mode {
		name := ui.THEME_MODE_NAMES[mode]
		add(r, {name = fmt.aprintf("view.theme_mode.%s", name, allocator = a), label = fmt.aprintf("Theme version: %s", name, allocator = a), group = "View",
			tags = command_words(r, "colors appearance dark light system mode"), arg = name,
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return ui.THEME_MODE_NAMES[app.cfg.look.mode] == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_string(app, prefs_page.MODE_PREF, c.arg) }})
	}

	for style in Chrome_Style {
		titles := [Chrome_Style]string{.Classic = i18n.tr("Appearance: classic tabs"), .Modern = i18n.tr("Appearance: modern tabs")}
		add(r, {name = fmt.aprintf("view.chrome_style.%s", CHROME_STYLE_NAMES[style], allocator = a), group = "View", arg = CHROME_STYLE_NAMES[style],
			label = titles[style],
			tags = command_words(r, "chrome tabs style look trapezoid sloped angular gradient pill appearance interface"),
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return CHROME_STYLE_NAMES[app.chrome_cfg.style] == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_string(app, "browser.ui.chrome_style", c.arg) }})
	}
	// the finish of the interface's widgets (the standard appearance.finish): machined bevels the modern tabs too
	for finish in ui.Finish {
		name := ui.FINISH_NAMES[finish]
		add(r, {name = fmt.aprintf("view.finish.%s", name, allocator = a), label = fmt.aprintf("%s: %s", i18n.tr("Finish"), name, allocator = a), group = "View", arg = name,
			tags = command_words(r, "appearance look style machined bevel metal edged flat gradient glass interface"),
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return ui.FINISH_NAMES[app.cfg.look.finish] == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_string(app, prefs_page.FINISH_PREF, c.arg) }})
	}

	// --- browser
	add(r, {name = "browser.command_palette", label = "Command palette…", group = "Browser", keys = {{key = .P, mods = cs}, {key = .K, mods = ctrl}}, key_pref = "browser.palette.ctrl_k",
		hidden = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { palette_toggle(app) }})
	add(r, {name = "browser.main_menu", label = "Open the main menu", group = "Browser", keys = {{key = .F, mods = alt}, {key = .E, mods = alt}},
		hidden = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_ask(app, .Main_Menu) }})
	add(r, {name = "browser.history", label = "History", group = "Browser", tags = command_words(r, "about:history visited pages past"), url = HISTORY_URL, keys = {{key = .H, mods = ctrl}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { open_history(app, t, false) }})
	add(r, {name = "browser.bookmarks", label = i18n.tr("Bookmarks"), group = "Browser", tags = command_words(r, "about:bookmarks favorites saved pages folders"), url = BOOKMARKS_URL, keys = {{key = .O, mods = cs}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { open_bookmarks(app) }})
	add(r, {name = "bookmark.page", label = i18n.tr("Bookmark this page"), group = "Page", tags = command_words(r, "star favorite save keep"), keys = {{key = .D, mods = ctrl}, {}},
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return bookmarkable(t) },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && bookmark_of_url(app.bms.items[:], t.url) >= 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { bookmark_star(app, t) }})
	add(r, {name = "view.bookmarks_bar", label = i18n.tr("Show the bookmarks bar"), group = "View", tags = command_words(r, "favorites toolbar bookmarks bar"),
		keys = {{key = .B, mods = cs}, {}},
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return bookmarks_bar_shown(app) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { bookmarks_bar_toggle(app) }})
	add(r, {name = "bookmarks.import", label = i18n.tr("Import bookmarks…"), group = "Browser", tags = command_words(r, "html netscape chrome firefox edge favorites"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { bookmarks_import_pick(app) }})
	add(r, {name = "bookmarks.export", label = i18n.tr("Export bookmarks…"), group = "Browser", tags = command_words(r, "html netscape backup save favorites"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { bookmarks_export_pick(app) }})
	add(r, {name = "browser.downloads", label = "Downloads", group = "Browser", tags = command_words(r, "about:downloads files saved folder progress"), url = DOWNLOADS_URL, keys = {{key = .J, mods = ctrl}, {}},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { open_downloads(app) }})
	add(r, {name = "browser.history_tree", label = "Tab history tree", group = "Browser", tags = command_words(r, "branches back forward graph session"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { open_history(app, t, true) }})
	add(r, {name = "browser.settings", label = "Settings", group = "Browser", tags = command_words(r, "about:settings preferences options"), url = SETTINGS_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, SETTINGS_URL, origin = .User) }})
	add(r, {name = "browser.setup", label = "Setup\u2026", group = "Browser", tags = command_words(r, "install uninstall installer shortcut start menu path update repair standalone portable manage this installation"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_available() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { setup_open(app) }})
	// the content blocker (blocker_shell.odin, blocker_ui.odin)
	blocker_on := proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return app.bl.started && app.bl.b.cfg.enabled }
	web_http := proc(app: ^App, t: ^Tab, c: ^Command) -> bool { _, ok := blocker_page_host(t); return ok && app.bl.started }
	add(r, {name = "blocker.panel", label = i18n.tr("Blocker: open the panel"), group = "Blocker", tags = command_words(r, "ads adblock shield tracker matrix"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_ask(app, .Blocker_Panel); request_frames(app, 3) }})
	add(r, {name = "blocker.picker", label = i18n.tr("Blocker: block an element\u2026"), group = "Blocker", tags = command_words(r, "ads element picker zapper hide"),
		keys = {{key = .K, mods = cs}, {}}, enabled = web_http, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_picker_begin(app, t) }})
	add(r, {name = "blocker.dashboard", label = i18n.tr("Blocker: dashboard"), group = "Blocker", tags = command_words(r, "lists filters rules whitelist statistics"), url = "about:blocker",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_open_dashboard(app) }})
	add(r, {name = "blocker.journal", label = i18n.tr("Blocker: request log"), group = "Blocker", tags = command_words(r, "logger journal requests blocked"), url = "about:blocker#journal",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_open_dashboard(app, "journal") }})
	add(r, {name = "blocker.filters", label = i18n.tr("Blocker: my filters"), group = "Blocker", tags = command_words(r, "custom rules editor"), url = "about:blocker#filters",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_open_dashboard(app, "filters") }})
	add(r, {name = "blocker.site", label = i18n.tr("Blocker: switch off / on for this site"), group = "Blocker", tags = command_words(r, "whitelist broken site disable allow"),
		enabled = web_http, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if host, ok := blocker_page_host(t); ok { blocker_set_site_enabled(app, t, host, !blocker_site_enabled(host)) }
		}})
	add(r, {name = "blocker.update", label = i18n.tr("Blocker: update the filter lists now"), group = "Blocker", tags = command_words(r, "download refresh easylist"),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_update_now() }})
	add(r, {name = "blocker.toggle", label = i18n.tr("Blocker: on"), group = "Blocker", tags = command_words(r, "ads adblock enable disable"),
		checked = blocker_on, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			config.set_from_string(&app.prefs, "blocker.enabled", app.bl.b.cfg.enabled ? "false" : "true", .User)
			if t != nil && t.kind == .Web { reload(app, t) }
		}})
	add(r, {name = "browser.check_updates", label = "Check for updates", group = "Browser", tags = command_words(r, "update upgrade new version release github latest"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { update_check_now(app) }})
	add(r, {name = "browser.install_update", label = "Install the update", group = "Browser", tags = command_words(r, "update upgrade install new version signed release"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return update_install_ready(app) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { update_install(app) }})
	add(r, {name = "browser.desktop_integration", label = "Integrate Wren with the desktop", group = "Browser", tags = command_words(r, "start menu shortcut default apps browser application menu desktop entry install uninstall"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_available() },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_checked(app) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { desktop_command_toggle(app) }})
	add(r, {name = "browser.default_apps", label = "Open the default apps settings", group = "Browser", tags = command_words(r, "default browser windows settings choose"),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_has_default_apps() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { desktop_open_default_apps() }})
	add(r, {name = "browser.demos", label = "Demos", group = "Browser", tags = command_words(r, "about:demos examples"), url = DEMOS_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, DEMOS_URL, origin = .User) }})
	add(r, {name = "browser.about_pages", label = "Built-in pages", group = "Browser", tags = command_words(r, "about:about list"), url = ABOUT_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, ABOUT_URL, origin = .User) }})
	add(r, {name = "browser.about", label = "About Wren", group = "Browser", tags = command_words(r, "about:wren version build info license license registered support credits third-party"), url = WREN_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_open(app, WREN_URL, origin = .User) }})
	add(r, {name = "browser.about_licenses", label = "Third-party licenses", group = "Browser", tags = command_words(r, "about:licenses credits slug open source notices"), url = LICENSES_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, LICENSES_URL, origin = .User) }})
	add(r, {name = "browser.about_cache", label = "HTTP cache", group = "Browser", tags = command_words(r, "about:cache stored responses statistics"), url = CACHE_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, CACHE_URL, origin = .User) }})
	add(r, {name = "browser.about_sites", label = "Site data", group = "Browser", tags = command_words(r, "about:sites cookies local storage indexeddb clear site data cache forget"), url = SITES_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, SITES_URL, origin = .User) }})
	add(r, {name = "browser.clear_cache", label = "Clear the cache", group = "Browser", tags = command_words(r, "http cache empty delete purge stored responses"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { http_cache_clear(app) }})
	add(r, {name = "browser.javascript", label = "JavaScript", group = "Browser", tags = command_words(r, "script js enable disable everywhere global"),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return config.bool_of(&app.prefs, "javascript.enabled") },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "javascript.enabled", !config.bool_of(&app.prefs, "javascript.enabled")) }})
	add(r, {name = "browser.downloads_folder", label = "Open the downloads folder", group = "Browser", tags = command_words(r, "explorer files"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { shell_open_folder(download_dir(app)) }})
	add(r, {name = "browser.profile_folder", label = "Open the profile folder", group = "Browser", tags = command_words(r, "explorer files cookies prefs data"),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { shell_open_folder(app.profile_dir) }})
	vault_commands_add(r)   // vault_fill.odin: fill, lock, unlock, sync, the panel, the search
}

// The system's file manager on `dir` (platform.open_path: ShellExecute on Windows, xdg / the portal on Linux).
shell_open_folder :: proc(dir: string) {
	if dir == "" { return }
	ui.open(dir)   // (on the toolkit's chores: a launch can wait on the shell)
}

////////////////////////////////
// JavaScript per site (the lists of javascript.sites.*, js/settings.odin: the disabled list wins)

// The sites of a list preference (lower case).
site_list :: proc(v: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := v
	for len(rest) > 0 {
		i := strings.index_any(rest, ", \t;")
		item := strings.trim_space(i < 0 ? rest : rest[:i])
		rest = i < 0 ? "" : rest[i + 1:]
		if item != "" { append(&out, base.ascii_lower_clone(item, allocator)) }
	}
	return out[:]
}

site_matches :: proc(host, pattern: string) -> bool {
	if strings.has_prefix(pattern, "*.") {
		b := pattern[2:]
		return host == b || strings.has_suffix(host, strings.concatenate({".", b}, context.temp_allocator))
	}
	return host == pattern
}

site_listed :: proc(list: string, host: string) -> bool {
	for p in site_list(list) { if site_matches(host, p) { return true } }
	return false
}

// `list` with `host` added (when not there yet) or removed (that exact entry), comma separated.
site_list_edit :: proc(list, host: string, add: bool, allocator := context.temp_allocator) -> string {
	items := make([dynamic]string, context.temp_allocator)
	found := false
	for s in site_list(list) {
		if s == host { found = true; if !add { continue } }
		append(&items, s)
	}
	if add && !found { append(&items, host) }
	return strings.join(items[:], ", ", allocator)
}

js_on_for :: proc(p: ^config.Prefs, host: string) -> bool {
	if site_listed(config.string_of(p, "javascript.sites.disabled"), host) { return false }
	if config.bool_of(p, "javascript.enabled") { return true }
	return site_listed(config.string_of(p, "javascript.sites.enabled"), host)
}

// Turns JavaScript off (on) for the tab's site, then reloads it (the setting applies to documents loaded after it).
js_toggle_site :: proc(app: ^App, t: ^Tab) {
	host := tab_host(t)
	if host == "" { return }
	p := &app.prefs
	set :: proc(p: ^config.Prefs, name, value: string) -> bool {
		if err := config.set_from_string(p, name, value, .User); err != .None { ui.toast(.Warn, "%s: %s", name, config.set_error_text(err)); return false }
		return true
	}
	if js_on_for(p, host) {
		if !set(p, "javascript.sites.enabled", site_list_edit(config.string_of(p, "javascript.sites.enabled"), host, false)) { return }
		if js_on_for(p, host) && !set(p, "javascript.sites.disabled", site_list_edit(config.string_of(p, "javascript.sites.disabled"), host, true)) { return }
	} else {
		if !set(p, "javascript.sites.disabled", site_list_edit(config.string_of(p, "javascript.sites.disabled"), host, false)) { return }
		if !js_on_for(p, host) && !site_listed(config.string_of(p, "javascript.sites.disabled"), host) {
			if !set(p, "javascript.sites.enabled", site_list_edit(config.string_of(p, "javascript.sites.enabled"), host, true)) { return }
		}
		if !js_on_for(p, host) { ui.toast(.Warn, "A pattern of javascript.sites.disabled still blocks %s", host); return }
	}
	ui.toast(.Info, "JavaScript %s on %s", js_on_for(p, host) ? "on" : "off", host)
	reload(app, t)
}

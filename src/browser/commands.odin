package browser

// The browser's commands, in one registry: the keyboard shortcuts of the chrome (chrome_shortcuts), the main menu and
// the command palette (palette.odin) all act through it, so a command has one title, one set of shortcuts, one
// condition and one action wherever it is offered.
//
// A command's `name` is its stable identity (the palette's usage memory is keyed by it): dotted, lower case, never
// reused for something else. Its first shortcut is the one shown in menus and in the palette; the others are aliases.

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import win "core:sys/windows"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:i18n"
import "wb:page"

Shortcut :: struct {
	key:  platform.Key,
	mods: platform.Modifiers,
	pref: string,   // not "": the shortcut acts only while this boolean preference is on
}

Command_Proc :: proc(app: ^App, t: ^Tab, c: ^Command)
Command_Test :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool

Command :: struct {
	name:     string,           // stable identity: "tab.new"
	title:    string,
	category: string,           // the palette's grouping: "Tabs", "Navigation", "View"...
	glyph:    string,           // icon-font glyph ("" = none)
	keywords: string,           // other words the palette finds it by (not shown)
	keys:     []Shortcut,
	url:      string,           // the command opens this page: Ctrl+Enter in the palette opens it in a new tab
	arg:      string,           // parameter of a generated command (the theme's name)
	enabled:  Command_Test,     // nil: always
	checked:  Command_Test,     // nil: not a toggle
	run:      Command_Proc,
	hidden:   bool,             // not offered by the palette (its own shortcut, for instance)
	guarded:  bool,             // its shortcuts act (and take the key) only while it is enabled
}

Command_Registry :: struct {
	list:  [dynamic]Command,
	index: map[string]int,
	arena: virtual.Arena,       // titles, keywords and shortcut lists of the commands
	built: bool,
}

cmds: Command_Registry

// The registry, built at first use.
commands :: proc() -> []Command {
	if !cmds.built { commands_build(&cmds) }
	return cmds.list[:]
}

command :: proc(name: string) -> ^Command {
	if !cmds.built { commands_build(&cmds) }
	if i, ok := cmds.index[name]; ok { return &cmds.list[i] }
	return nil
}

commands_destroy :: proc(r: ^Command_Registry) {
	if !r.built { return }
	delete(r.list)
	delete(r.index)
	virtual.arena_destroy(&r.arena)
	r^ = {}
}

command_enabled :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return c.enabled == nil || c.enabled(app, t, c) }

// Runs `c` when it is enabled; true when it ran.
command_run :: proc(app: ^App, t: ^Tab, c: ^Command) -> bool {
	if c == nil || c.run == nil || !command_enabled(app, t, c) { return false }
	// during a chrome frame (shell_frames.odin) once the page holding the thread is done
	if shell_nested() { shell_defer({kind = .Command, tab = t != nil ? t.id : 0, text = strings.clone(c.name)}); return true }
	c.run(app, t, c)
	request_frames(app, 2)
	return true
}

// "Ctrl+Shift+T" (the first shortcut of the command; "" when it has none).
command_shortcut_text :: proc(c: ^Command) -> string {
	if len(c.keys) == 0 { return "" }
	return shortcut_text(c.keys[0])
}

shortcut_text :: proc(s: Shortcut, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if .Ctrl in s.mods { strings.write_string(&sb, "Ctrl+") }
	if .Alt in s.mods { strings.write_string(&sb, "Alt+") }
	if .Shift in s.mods { strings.write_string(&sb, "Shift+") }
	strings.write_string(&sb, key_name(s.key))
	return strings.to_string(sb)
}

key_name :: proc(k: platform.Key) -> string {
	#partial switch k {
	case .A ..= .Z: return fmt.tprintf("%c", 'A' + rune(int(k) - int(platform.Key.A)))
	case .N0 ..= .N9: return fmt.tprintf("%c", '0' + rune(int(k) - int(platform.Key.N0)))
	case .F1 ..= .F12: return fmt.tprintf("F%d", int(k) - int(platform.Key.F1) + 1)
	case .Escape: return "Esc"
	case .Return: return "Enter"
	case .Page_Up: return "Page Up"
	case .Page_Down: return "Page Down"
	case .Equal: return "Plus"
	case .Minus: return "Minus"
	case .Num_Add: return "Num +"
	case .Num_Subtract: return "Num -"
	case .Comma: return ","
	case .Period: return "."
	case .Slash: return "/"
	}
	return fmt.tprintf("%v", k)
}

// The shortcuts of the chrome that are not commands of the registry (they depend on what has the keyboard, or are a
// family): the registry's own must not take them (commands_test.odin).
RESERVED_SHORTCUTS := [?]Shortcut{
	{key = .Escape},                   // stops a load / closes the frame statistics, when nothing has the keyboard
	{key = .Menu}, {key = .F10, mods = {.Shift}},   // the context menu of what has the keyboard
	{key = .N1, mods = {.Ctrl}}, {key = .N2, mods = {.Ctrl}}, {key = .N3, mods = {.Ctrl}}, {key = .N4, mods = {.Ctrl}},
	{key = .N5, mods = {.Ctrl}}, {key = .N6, mods = {.Ctrl}}, {key = .N7, mods = {.Ctrl}}, {key = .N8, mods = {.Ctrl}},
	{key = .N9, mods = {.Ctrl}},       // tab 1..8, the last tab
}

// The registry's shortcuts that were pressed this frame run their command (the first one found takes the key, as the
// chrome's single switch did). True when one ran.
commands_dispatch :: proc(app: ^App) -> bool {
	t := current_tab(app)
	for &c in commands() {
		for s in c.keys {
			if s.pref != "" && !config.bool_of(&app.prefs, s.pref) { continue }
			if c.guarded && !command_enabled(app, t, &c) { continue }
			if !ui.key_press(s.key, s.mods) { continue }
			command_run(app, t, &c)
			return true
		}
	}
	return false
}

// A menu item for a command: its title, first shortcut, glyph, check mark and condition. True when it ran.
menu_command :: proc(app: ^App, t: ^Tab, name: string, title := "", force_disabled := false) -> bool {
	c := command(name)
	if c == nil { return false }
	checked := c.checked != nil && c.checked(app, t, c)
	if ui.menu_item(title != "" ? title : c.title, command_shortcut_text(c), checked = checked, icon = c.glyph, enabled = !force_disabled && command_enabled(app, t, c)).clicked {
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
	return strings.to_lower(t.page.env.location.host, context.temp_allocator)
}

commands_build :: proc(r: ^Command_Registry) {
	if r.built { return }
	r.built = true
	_ = virtual.arena_init_growing(&r.arena)
	a := virtual.arena_allocator(&r.arena)
	r.index = make(map[string]int)
	r.list = make([dynamic]Command)
	keys :: proc(a: ^virtual.Arena, list: ..Shortcut) -> []Shortcut {
		out := make([]Shortcut, len(list), virtual.arena_allocator(a))
		copy(out, list)
		return out
	}
	add :: proc(r: ^Command_Registry, c: Command) {
		assert(c.name not_in r.index, "commands: duplicate name")
		r.index[c.name] = len(r.list)
		append(&r.list, c)
	}
	ctrl, cs, alt, shift := platform.Modifiers{.Ctrl}, platform.Modifiers{.Ctrl, .Shift}, platform.Modifiers{.Alt}, platform.Modifiers{.Shift}

	// --- tabs
	add(r, {name = "tab.new", title = "New tab", category = "Tabs", glyph = GLYPH_ADD, keys = keys(&r.arena, {key = .T, mods = ctrl}),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_open_new(app) }})
	add(r, {name = "tab.reopen_closed", title = "Reopen closed tab", category = "Tabs", keywords = "undo close restore", keys = keys(&r.arena, {key = .T, mods = cs}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(closed_tabs) > 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { reopen_closed_tab(app) }})
	add(r, {name = "tab.close", title = "Close tab", category = "Tabs", glyph = GLYPH_CLOSE, keys = keys(&r.arena, {key = .W, mods = ctrl}, {key = .F4, mods = ctrl}),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_close(app, active_window(app).current) }})
	add(r, {name = "tab.close_others", title = "Close other tabs", category = "Tabs",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(active_window(app).tabs) > 1 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { close_other_tabs(app, active_window(app).current) }})
	add(r, {name = "tab.duplicate", title = "Duplicate tab", category = "Tabs", keywords = "copy clone",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.url != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { open_in_new_tab(app, t.url, origin = .Replay) }})
	add(r, {name = "tab.next", title = "Next tab", category = "Tabs", keywords = "switch", keys = keys(&r.arena, {key = .Tab, mods = ctrl}, {key = .Page_Down, mods = ctrl}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(active_window(app).tabs) > 1 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { n := len(active_window(app).tabs); if n > 0 { tab_select(app, (active_window(app).current + 1) % n) } }})
	add(r, {name = "tab.previous", title = "Previous tab", category = "Tabs", keywords = "switch", keys = keys(&r.arena, {key = .Tab, mods = cs}, {key = .Page_Up, mods = ctrl}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return len(active_window(app).tabs) > 1 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { n := len(active_window(app).tabs); if n > 0 { tab_select(app, (active_window(app).current + n - 1) % n) } }})
	add(r, {name = "tab.move_right", title = "Move tab right", category = "Tabs", keys = keys(&r.arena, {key = .Page_Down, mods = cs}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return active_window(app).current + 1 < len(active_window(app).tabs) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_move_current(app, +1) }})
	add(r, {name = "tab.move_left", title = "Move tab left", category = "Tabs", keys = keys(&r.arena, {key = .Page_Up, mods = cs}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return active_window(app).current > 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_move_current(app, -1) }})
	add(r, {name = "tab.move_to_new_window", title = "Move tab to a new window", category = "Tabs", keywords = "detach pop out separate window",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool {
			w, _ := window_of_tab(app, t)
			return w != nil && len(window_tabs(app, w)) > 1
		},
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_detach(app, t) }})
	// pinned tabs and groups (tab_groups.odin)
	add(r, {name = "tab.pin", title = i18n.tr("Pin or unpin tab"), category = "Tabs", keywords = "pinned app tab sticky keep",
		enabled = has_tab, checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.pinned },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_set_pinned(app, t, !t.pinned) }})
	add(r, {name = "tab.mute", title = i18n.tr("Mute or unmute tab"), category = "Tabs", keywords = "sound audio silence speaker volume",
		enabled = has_tab, checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.muted },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_set_muted(app, t, !t.muted) }})
	add(r, {name = "tab.group_new", title = i18n.tr("Add tab to a new group"), category = "Tabs", keywords = "group tabs together organize",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { _ = tab_group_new(app, t) }})
	add(r, {name = "tab.group_leave", title = i18n.tr("Remove tab from its group"), category = "Tabs", keywords = "ungroup group",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_group_leave(app, t) }})
	add(r, {name = "tab.group_collapse", title = i18n.tr("Collapse or expand the tab's group"), category = "Tabs", keywords = "group fold hide",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			w, _ := window_of_tab(app, t)
			if gi := group_index(w.groups[:], t.group); gi >= 0 { group_set_collapsed(app, w, t.group, !w.groups[gi].collapsed) }
		}})
	add(r, {name = "tab.group_rename", title = i18n.tr("Rename the tab's group"), category = "Tabs", keywords = "group name title",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 && favs.cfg.position != .Top },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { group_rename_begin(app, t.group) }})
	for gc in Group_Color {
		add(r, {name = fmt.aprintf("tab.group_color.%s", GROUP_COLOR_NAMES[gc], allocator = a), title = fmt.aprintf("%s: %s", i18n.tr("Tab group colour"), GROUP_COLOR_NAMES[gc], allocator = a),
			category = "Tabs", keywords = "group colour color", arg = GROUP_COLOR_NAMES[gc],
			enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.group != 0 },
			run = proc(app: ^App, t: ^Tab, c: ^Command) {
				w, _ := window_of_tab(app, t)
				if col, ok := group_color_of(c.arg); ok { group_set_color(app, w, t.group, col) }
			}})
	}
	add(r, {name = "window.new", title = "New window", category = "Window", keywords = "open another", keys = keys(&r.arena, {key = .N, mods = ctrl}),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { window_new(app) }})
	add(r, {name = "tab.restore_crashed", title = "Restore the tabs of the session that crashed", category = "Tabs", keywords = "crash recovery reopen saved",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return recovery.backup != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { recovery_restore_backup(app) }})

	// --- navigation
	add(r, {name = "nav.back", title = "Back", category = "Navigation", glyph = GLYPH_BACK, keywords = "history previous page", keys = keys(&r.arena, {key = .Left, mods = alt}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.hist > 0 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { go_history(app, t, -1) }})
	add(r, {name = "nav.forward", title = "Forward", category = "Navigation", glyph = GLYPH_FORWARD, keywords = "history next page", keys = keys(&r.arena, {key = .Right, mods = alt}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.hist + 1 < len(t.history) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { go_history(app, t, +1) }})
	add(r, {name = "nav.reload", title = "Reload", category = "Navigation", glyph = GLYPH_RELOAD, keywords = "refresh", keys = keys(&r.arena, {key = .F5}, {key = .R, mods = ctrl}),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if t.page != nil && page.navigation_user_reload(t.page) { return }   // the page's navigate listener took it
			reload(app, t)
		}})
	// the document and everything it loads from the network (cache mode reload); F5 only revalidates the document
	add(r, {name = "nav.reload_bypass_cache", title = "Reload without the cache", category = "Navigation", glyph = GLYPH_RELOAD, keywords = "hard refresh force",
		keys = keys(&r.arena, {key = .F5, mods = ctrl}, {key = .R, mods = cs}),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if t.page != nil && page.navigation_user_reload(t.page) { return }
			reload(app, t, bypass_cache = true)
		}})
	add(r, {name = "nav.stop", title = "Stop loading", category = "Navigation", keywords = "cancel abort",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.load != nil && t.load.task != base.NIL_HANDLE },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { stop_loading(app, t) }})
	add(r, {name = "nav.home", title = "Home", category = "Navigation", glyph = GLYPH_HOME, keywords = "start page homepage", keys = keys(&r.arena, {key = .Home, mods = alt}),
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, app.cfg.homepage, origin = .User) }})
	add(r, {name = "nav.focus_address", title = "Focus the address bar", category = "Navigation", keywords = "location url edit", keys = keys(&r.arena, {key = .L, mods = ctrl}, {key = .D, mods = alt}),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { active_window(app).focus_address = true }})
	add(r, {name = "nav.focus_toggle", title = "Address bar or page", category = "Navigation", keywords = "focus switch keyboard", keys = keys(&r.arena, {key = .F6}, {key = .F6, mods = shift}),
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if ui.focus_key() != 0 && ui.focus_key() == address_key(app) { ui.set_focus(0); forms_focus_from_chrome(app, t, 1) } else { active_window(app).focus_address = true }
		}})

	// --- page
	add(r, {name = "page.zoom_in", title = "Zoom in", category = "Page", keywords = "bigger larger magnify",
		keys = keys(&r.arena, {key = .Equal, mods = ctrl}, {key = .Num_Add, mods = ctrl}, {key = .Equal, mods = cs}),
		enabled = web_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { zoom_step(app, t, 1) }})
	add(r, {name = "page.zoom_out", title = "Zoom out", category = "Page", keywords = "smaller", keys = keys(&r.arena, {key = .Minus, mods = ctrl}, {key = .Num_Subtract, mods = ctrl}),
		enabled = web_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { zoom_step(app, t, -1) }})
	add(r, {name = "page.zoom_reset", title = "Actual size", category = "Page", keywords = "zoom reset 100", keys = keys(&r.arena, {key = .N0, mods = ctrl}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web && zoom_percent(t) != 100 },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { zoom_set(app, t, 1) }})
	add(r, {name = "page.find", title = "Find in page…", category = "Page", keywords = "search text", keys = keys(&r.arena, {key = .F, mods = ctrl}, {key = .F3}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && (t.kind == .Web || t.kind == .Config || t.kind == .History) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if t.kind == .Config { app.config_view.focus_search = true } else if t.kind == .History { hview.focus_search = true } else if fs := find_state(app); fs.open { fs.focus = true } else { find_open(app) }
		}})
	add(r, {name = "page.save", title = "Save page as…", category = "Page", keywords = "download file", keys = keys(&r.arena, {key = .S, mods = ctrl}),
		enabled = web_page, run = proc(app: ^App, t: ^Tab, c: ^Command) { save_page(app, t) }})
	add(r, {name = "page.view_source", title = "View page source", category = "Page", keywords = "html code", keys = keys(&r.arena, {key = .U, mods = ctrl}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.kind == .Web && !strings.has_prefix(t.url, VIEW_SOURCE) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { view_source(app, t) }})
	// printing is not available (print.odin): the shortcut says so
	add(r, {name = "page.print", title = "Print…", category = "Page", keys = keys(&r.arena, {key = .P, mods = ctrl}),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { print_request(app) }})
	add(r, {name = "page.copy_address", title = "Copy the page's address", category = "Page", glyph = GLYPH_COPY, keywords = "url link clipboard",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return t != nil && t.url != "" },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { clip_set(t.url); ui.toast(.Info, "Address copied") }})
	add(r, {name = "page.info", title = "Page information", category = "Page", glyph = GLYPH_INFO, keywords = "security certificate cookies connection",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_own(app).page_info_request = true }})
	add(r, {name = "page.javascript_site", title = "JavaScript on this site", category = "Page", keywords = "script js enable disable block allow",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return tab_host(t) != "" },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return js_on_for(&app.prefs, tab_host(t)) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { js_toggle_site(app, t) }})

	// --- view
	add(r, {name = "view.status_bar", title = "Status bar", category = "View", keys = keys(&r.arena, {key = .B, mods = ctrl}),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return hud.cfg.bar_visible },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { toggle_status_bar(app) }})
	add(r, {name = "view.smooth_scrolling", title = "Smooth scrolling", category = "View", keywords = "animated scroll wheel motion browser.scroll.smooth.enabled",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return smooth_cfg.enabled },
		run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if err := config.set_from_string(&app.prefs, "browser.scroll.smooth.enabled", smooth_cfg.enabled ? "false" : "true", .User); err != .None { ui.toast(.Warn, "browser.scroll.smooth.enabled: %s", config.set_error_text(err)) }
		}})
	add(r, {name = "view.frame_statistics", title = "Frame statistics", category = "View", keywords = "fps performance hud timing", keys = keys(&r.arena, {key = .B, mods = cs}),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return hud.panel_open },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { toggle_frame_stats(app) }})
	add(r, {name = "view.title_statistics", title = "Statistics in the title", category = "View", keywords = "fps",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return hud.cfg.title_stats },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "browser.title.stats", !hud.cfg.title_stats) }})
	add(r, {name = "view.devtools", title = "Developer tools", category = "View", keywords = "inspect console elements network dom debug f12",
		keys = keys(&r.arena, {key = .F12}, {key = .I, mods = cs}),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_toggle(app) }})
	add(r, {name = "view.console", title = "Console", category = "View", keywords = "log javascript eval devtools",
		keys = keys(&r.arena, {key = .J, mods = cs}),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible && dev().panel == .Console },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_toggle_panel(app, .Console) }})
	add(r, {name = "view.devtools_elements", title = "Developer tools: Elements", category = "View", keywords = "inspect dom document tree html",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible && dev().panel == .Elements },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Elements) }})
	add(r, {name = "view.devtools_network", title = "Developer tools: Network", category = "View", keywords = "requests http fetch log",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible && dev().panel == .Network },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Network) }})
	add(r, {name = "view.devtools_dock_bottom", title = "Developer tools: dock at the bottom", category = "View", keywords = "devtools panel position",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Bottom },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_set_dock(app, .Bottom) }})
	add(r, {name = "view.devtools_dock_right", title = "Developer tools: dock at the right", category = "View", keywords = "devtools panel position side",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Right },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_set_dock(app, .Right) }})
	add(r, {name = "view.devtools_dock_floating", title = "Developer tools: undock into a floating panel", category = "View", keywords = "devtools panel position window",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Floating },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_set_dock(app, .Floating) }})
	add(r, {name = "view.devtools_application", title = "Developer tools: Application", category = "View", keywords = "storage cookies local session cache manifest",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible && dev().panel == .Application },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Application) }})
	add(r, {name = "view.devtools_performance", title = "Developer tools: Performance", category = "View", keywords = "frames timing fps cpu gpu profile",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible && dev().panel == .Performance },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Performance) }})
	add(r, {name = "view.devtools_memory", title = "Developer tools: Memory", category = "View", keywords = "heap allocation leak usage",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().visible && dev().panel == .Memory },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_open(app, .Memory) }})
	add(r, {name = "view.devtools_pick", title = "Developer tools: select an element in the page", category = "View", keywords = "inspect picker element select eyedropper",
		keys = keys(&r.arena, {key = .C, mods = cs}), enabled = has_tab,
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().picking },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_pick(app) }})
	add(r, {name = "view.devtools_dock_left", title = "Developer tools: dock at the left", category = "View", keywords = "devtools panel position side",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return dev().dock == .Left && !devtools_detached() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { if devtools_detached() { devtools_attach(app) }; devtools_set_dock(app, .Left) }})
	add(r, {name = "view.devtools_detach", title = "Developer tools: open in a separate window", category = "View", keywords = "devtools panel undock detach window second",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return devtools_detached() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { if devtools_detached() { devtools_attach(app) } else { devtools_detach(app) } }})
	add(r, {name = "view.devtools_larger", title = "Developer tools: larger text", category = "View", keywords = "devtools zoom font size",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_zoom(app, 1) }})
	add(r, {name = "view.devtools_smaller", title = "Developer tools: smaller text", category = "View", keywords = "devtools zoom font size",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_zoom(app, -1) }})
	add(r, {name = "view.devtools_reset_layout", title = "Developer tools: reset the layout", category = "View", keywords = "devtools sizes columns panes default",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { devtools_reset_layout(app) }})
	add(r, {name = "view.devtools_clear_console", title = "Developer tools: clear the console", category = "View", keywords = "devtools log messages empty",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { console_clear(app, t) }})
	add(r, {name = "view.devtools_clear_network", title = "Developer tools: clear the network log", category = "View", keywords = "devtools requests empty",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { net_clear(&t.net); dev().net.has_sel = false }})
	for p in NET_BUILTIN {
		add(r, {name = fmt.aprintf("view.devtools_speed.%s", p.id, allocator = a), title = fmt.aprintf("Developer tools: network speed: %s", p.name, allocator = a), category = "View",
			keywords = "devtools throttle throttling network speed slow offline 3g bandwidth latency", arg = p.id, enabled = has_tab,
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return net_profile_of(t).id == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { net_profile_set(app, t, c.arg) }})
	}	add(r, {name = "view.full_screen", title = "Full screen", category = "View", keywords = "fullscreen kiosk", keys = keys(&r.arena, {key = .F11}),
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return platform.is_fullscreen(active_window(app).win) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { toggle_fullscreen(app) }})
	add(r, {name = "view.tabs_in_title_bar", title = "Tabs in the title bar", category = "View", keywords = "integrated titlebar window",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return wchrome.cfg.integrated },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "browser.window.integrated_titlebar", !wchrome.cfg.integrated) }})
	// the tabs along the top or in a sidebar (tab_sidebar.odin)
	pos_titles := [Tabs_Position]string{.Top = i18n.tr("Tabs: at the top"), .Left = i18n.tr("Tabs: in a sidebar at the left"), .Right = i18n.tr("Tabs: in a sidebar at the right")}
	for pos in Tabs_Position {
		add(r, {name = fmt.aprintf("view.tabs_position.%s", TABS_POSITION_NAMES[pos], allocator = a), title = pos_titles[pos], category = "View", arg = TABS_POSITION_NAMES[pos],
			keywords = "tabs sidebar vertical side bar position left right top row horizontal layout",
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return TABS_POSITION_NAMES[favs.cfg.position] == c.arg },
			run = proc(app: ^App, t: ^Tab, c: ^Command) { tabs_set_position(app, tabs_position_of(c.arg)) }})
	}
	add(r, {name = "view.tabs_sidebar_collapse", title = i18n.tr("Tab sidebar: icons only"), category = "View", keywords = "tabs sidebar vertical collapse narrow compact titles",
		keys = keys(&r.arena, {key = .Comma, mods = cs}),
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return favs.cfg.position != .Top },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return favs.cfg.side_collapsed },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { tabs_toggle_collapsed(app) }})
	for np in ui.NAMED_PALETTES {
		name := strings.to_lower(np.name, virtual.arena_allocator(&r.arena))
		slug, _ := strings.replace_all(name, " ", "_", context.temp_allocator)
		add(r, {name = fmt.aprintf("view.theme.%s", slug, allocator = a), title = fmt.aprintf("Theme: %s", np.name, allocator = a), category = "View",
			keywords = np.palette.dark ? "colors appearance palette dark" : "colors appearance palette light", arg = name,
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return strings.equal_fold(app.cfg.ui_theme, c.arg) },
			run = proc(app: ^App, t: ^Tab, c: ^Command) {
				if err := config.set_from_string(&app.prefs, "browser.ui.theme", c.arg, .User); err != .None { ui.toast(.Warn, "browser.ui.theme: %s", config.set_error_text(err)) }
			}})
	}

	for style in ([2]string{"classic", "modern"}) {
		add(r, {name = fmt.aprintf("view.chrome_style.%s", style, allocator = a), category = "View", arg = style,
			title = style == "classic" ? i18n.tr("Appearance: classic tabs") : i18n.tr("Appearance: modern tabs"),
			keywords = "chrome tabs style look trapezoid sloped angular gradient flat pill appearance interface",
			checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return (c.arg == "classic") == (chrome_cfg.style == .Classic) },
			run = proc(app: ^App, t: ^Tab, c: ^Command) {
				if err := config.set_from_string(&app.prefs, "browser.ui.chrome_style", c.arg, .User); err != .None { ui.toast(.Warn, "browser.ui.chrome_style: %s", config.set_error_text(err)) }
			}})
	}

	// --- browser
	add(r, {name = "browser.command_palette", title = "Command palette…", category = "Browser", keys = keys(&r.arena, {key = .P, mods = cs}, {key = .K, mods = ctrl, pref = "browser.palette.ctrl_k"}),
		hidden = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { palette_toggle(app) }})
	add(r, {name = "browser.main_menu", title = "Open the main menu", category = "Browser", keys = keys(&r.arena, {key = .F, mods = alt}, {key = .E, mods = alt}),
		hidden = true, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_own(app).main_menu_request = true }})
	add(r, {name = "browser.history", title = "History", category = "Browser", keywords = "about:history visited pages past", url = HISTORY_URL, keys = keys(&r.arena, {key = .H, mods = ctrl}),
		run = proc(app: ^App, t: ^Tab, c: ^Command) { open_history(app, t, false) }})
	add(r, {name = "browser.history_tree", title = "Tab history tree", category = "Browser", keywords = "branches back forward graph session",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { open_history(app, t, true) }})
	add(r, {name = "browser.settings", title = "Settings", category = "Browser", glyph = GLYPH_GEAR, keywords = "about:config preferences options", url = "about:config",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, "about:config", origin = .User) }})
	add(r, {name = "browser.setup", title = "Setup\u2026", category = "Browser", keywords = "install uninstall installer shortcut start menu path update repair standalone portable manage this installation",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_available() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { setup_open(app) }})
	// the content blocker (blocker_shell.odin, blocker_ui.odin)
	blocker_on := proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return bl.started && bl.b.cfg.enabled }
	web_http := proc(app: ^App, t: ^Tab, c: ^Command) -> bool { _, ok := blocker_page_host(t); return ok && bl.started }
	add(r, {name = "blocker.panel", title = i18n.tr("Blocker: open the panel"), category = "Blocker", keywords = "ads adblock shield tracker matrix",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { window_own(app).blocker_panel_request = true; request_frames(app, 3) }})
	add(r, {name = "blocker.picker", title = i18n.tr("Blocker: block an element\u2026"), category = "Blocker", keywords = "ads element picker zapper hide",
		keys = keys(&r.arena, {key = .K, mods = cs}), enabled = web_http, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_picker_begin(app, t) }})
	add(r, {name = "blocker.dashboard", title = i18n.tr("Blocker: dashboard"), category = "Blocker", keywords = "lists filters rules whitelist statistics", url = "about:blocker",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_open_dashboard(app) }})
	add(r, {name = "blocker.journal", title = i18n.tr("Blocker: request log"), category = "Blocker", keywords = "logger journal requests blocked", url = "about:blocker#journal",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_open_dashboard(app, "journal") }})
	add(r, {name = "blocker.filters", title = i18n.tr("Blocker: my filters"), category = "Blocker", keywords = "custom rules editor", url = "about:blocker#filters",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_open_dashboard(app, "filters") }})
	add(r, {name = "blocker.site", title = i18n.tr("Blocker: switch off / on for this site"), category = "Blocker", keywords = "whitelist broken site disable allow",
		enabled = web_http, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			if host, ok := blocker_page_host(t); ok { blocker_set_site_enabled(app, t, host, !blocker_site_enabled(host)) }
		}})
	add(r, {name = "blocker.update", title = i18n.tr("Blocker: update the filter lists now"), category = "Blocker", keywords = "download refresh easylist",
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { blocker_update_now() }})
	add(r, {name = "blocker.toggle", title = i18n.tr("Blocker: on"), category = "Blocker", keywords = "ads adblock enable disable",
		checked = blocker_on, run = proc(app: ^App, t: ^Tab, c: ^Command) {
			config.set_from_string(&app.prefs, "blocker.enabled", bl.b.cfg.enabled ? "false" : "true", .User)
			if t != nil && t.kind == .Web { reload(app, t) }
		}})
	add(r, {name = "browser.check_updates", title = "Check for updates", category = "Browser", keywords = "update upgrade new version release github latest",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { update_check_now(app) }})
	add(r, {name = "browser.desktop_integration", title = "Integrate Wren with the desktop", category = "Browser", keywords = "start menu shortcut default apps browser application menu desktop entry install uninstall",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_available() },
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_checked(app) },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { desktop_command_toggle(app) }})
	add(r, {name = "browser.default_apps", title = "Open the default apps settings", category = "Browser", keywords = "default browser windows settings choose",
		enabled = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return desktop_has_default_apps() },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { desktop_open_default_apps() }})
	add(r, {name = "browser.demos", title = "Demos", category = "Browser", keywords = "about:demos examples", url = DEMOS_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, DEMOS_URL, origin = .User) }})
	add(r, {name = "browser.about_pages", title = "Built-in pages", category = "Browser", keywords = "about:about list", url = ABOUT_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, ABOUT_URL, origin = .User) }})
	add(r, {name = "browser.about", title = "About Wren", category = "Browser", keywords = "about:wren version build info licence license registered support credits third-party", url = WREN_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { tab_open(app, WREN_URL, origin = .User) }})
	add(r, {name = "browser.about_licenses", title = "Third-party licences", category = "Browser", keywords = "about:licenses credits slug open source notices", url = LICENSES_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, LICENSES_URL, origin = .User) }})
	add(r, {name = "browser.about_cache", title = "HTTP cache", category = "Browser", keywords = "about:cache stored responses statistics", url = CACHE_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, CACHE_URL, origin = .User) }})
	add(r, {name = "browser.about_sites", title = "Site data", category = "Browser", keywords = "about:sites cookies local storage indexeddb clear site data cache forget", url = SITES_URL,
		enabled = has_tab, run = proc(app: ^App, t: ^Tab, c: ^Command) { navigate(app, t, SITES_URL, origin = .User) }})
	add(r, {name = "browser.clear_cache", title = "Clear the cache", category = "Browser", keywords = "http cache empty delete purge stored responses",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { http_cache_clear(app) }})
	add(r, {name = "browser.javascript", title = "JavaScript", category = "Browser", keywords = "script js enable disable everywhere global",
		checked = proc(app: ^App, t: ^Tab, c: ^Command) -> bool { return config.bool_of(&app.prefs, "javascript.enabled") },
		run = proc(app: ^App, t: ^Tab, c: ^Command) { set_pref_bool(app, "javascript.enabled", !config.bool_of(&app.prefs, "javascript.enabled")) }})
	add(r, {name = "browser.downloads_folder", title = "Open the downloads folder", category = "Browser", glyph = GLYPH_FILE, keywords = "explorer files",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { shell_open_folder(download_dir(app)) }})
	add(r, {name = "browser.profile_folder", title = "Open the profile folder", category = "Browser", glyph = GLYPH_FILE, keywords = "explorer files cookies prefs data",
		run = proc(app: ^App, t: ^Tab, c: ^Command) { shell_open_folder(app.profile_dir) }})
}

// Explorer on `dir`.
shell_open_folder :: proc(dir: string) {
	if dir == "" { return }
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(dir, context.temp_allocator), nil, nil, win.SW_SHOWNORMAL)
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
		if item != "" { append(&out, strings.to_lower(item, allocator)) }
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

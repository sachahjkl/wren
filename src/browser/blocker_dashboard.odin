package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:adblock"
import "wb:base"
import "wb:blocker"
import "wb:config"
import "wb:i18n"

// about:blocker: the content blocker's dashboard. A native view like about:config and about:history (not a web page: it
// edits the blocker of the browser itself and has no document, origin or scripts). Dense and compact like a tool:
//
//   Settings      the switches of blocker.* and the actions on the configuration (update now, export, import, reset)
//   Filter lists  the catalogue by group with a switch, the rule count, the size and the date of each list; a custom list by URL
//   My filters    an editor for the user's own filters, checked as they are typed; import and export
//   My rules      the dynamic rules (the matrix of the panel, as a table): add, change, remove
//   Whitelist     the sites where filtering is off, and the other per-site switches
//   Journal       the live request log: time, type, URL, document, rule, outcome; filters, search, and a menu per row
//   Statistics    totals, the engine, the lists, this tab's hosts
//   About         the syntax that is understood, and how it works

BLOCKER_URL :: "about:blocker"
// Height of a row of controls, in em.
BLOCKER_ROW_H_EM :: 2.4

is_blocker_address :: proc(a: string) -> bool { return a == BLOCKER_URL || strings.has_prefix(a, BLOCKER_URL + "#") }

Dash_Tab :: enum { Settings, Lists, My_Filters, My_Rules, Whitelist, Journal, Statistics, About }

DASH_NAMES := [Dash_Tab]string{
	.Settings = "settings", .Lists = "lists", .My_Filters = "filters", .My_Rules = "rules", .Whitelist = "whitelist",
	.Journal = "journal", .Statistics = "statistics", .About = "about",
}

Dash :: struct {
	tab:         int,
	my:          ui.Text_Edit,
	my_loaded:   bool,
	my_dirty:    bool,
	my_diag:     []string,
	my_errors:   map[int]string,   // paragraph index (0-based) -> message, for the editor's underline and tooltip
	my_valid, my_ignored: int,
	my_checked:  string,
	custom_url:  ui.Line_Edit,
	custom_name: ui.Line_Edit,
	wl_add:      ui.Line_Edit,
	rule_src, rule_dst: ui.Line_Edit,
	rule_type, rule_action: int,
	log_search:  ui.Line_Edit,
	log_outcome: int,
	log_type:    int,
	log_list:    ui.Virtual_List,
	log_rows:    [dynamic]int,
	log_ids:     [dynamic]u64,
	log_labels:  [dynamic]string,
	log_sel:     [dynamic]bool,
	log_version: u64,
	log_query:   string,
	log_menu:    int,
	log_pause:   bool,
	log_shown:   u64,
	lists_scroll: bool,
	opened:      bool,
	status:      string,
}


dash_destroy :: proc() {
	ui.text_edit_destroy(&the_app.dash.my)
	ui.line_edit_destroy(&the_app.dash.custom_url); ui.line_edit_destroy(&the_app.dash.custom_name); ui.line_edit_destroy(&the_app.dash.wl_add)
	ui.line_edit_destroy(&the_app.dash.rule_src); ui.line_edit_destroy(&the_app.dash.rule_dst); ui.line_edit_destroy(&the_app.dash.log_search)
	ui.vlist_destroy(&the_app.dash.log_list)
	delete(the_app.dash.my_diag); delete(the_app.dash.log_rows); delete(the_app.dash.log_ids); delete(the_app.dash.log_labels); delete(the_app.dash.log_sel)
	delete(the_app.dash.log_query); delete(the_app.dash.status); delete(the_app.dash.my_checked)
	for _, v in the_app.dash.my_errors { delete(v) }
	delete(the_app.dash.my_errors)
	the_app.dash = {}
}

show_blocker :: proc(app: ^App, t: ^Tab, address: string) {
	nav_show_view(app, t, .Blocker)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	for l in t.console { delete(l) }
	clear(&t.console)
	delete(t.url); t.url = strings.clone(address)
	delete(t.title); t.title = strings.clone(i18n.tr("Content blocker"))
	set_status(t, "about:blocker")
	if i := strings.index_byte(address, '#'); i >= 0 {
		frag := address[i + 1:]
		for n, tb in DASH_NAMES { if n == frag { app.dash.tab = int(tb) } }
	}
	app.dash.my_loaded = false
}

////////////////////////////////
// Small widgets

cell :: proc(text: string, id: string, w: f32, weak := false, align := ui.Text_Align.Left) {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.pct(1), text_align = align, font_size = em * 0.92})
	label := tid(text, id)
	if weak { if ui.tags("weak") { ui.label(label) } } else { ui.label(label) }
}

section :: proc(text, id: string) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.0))})
	if ui.row(.End) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5)), font_size = em * 0.95})
		if ui.tags("weak") { ui.label(fmt.aprintf("%s###sec_%s", strings.to_upper(text, context.temp_allocator), id, allocator = ui.frame_allocator())) }
	}
	ui.hline(ui.fill())
}

@(private = "file")
pref_row :: proc(app: ^App, label, name, id: string) {
	em := ui.font_size()
	v := config.bool_of(&app.prefs, name)
	ui.next({width = ui.px(em * 26), height = ui.px(ui.dense(em * 1.8))})
	if ui.toggle(fmt.tprintf("###pt_%s", id), label, &v) {
		config.set_from_string(&app.prefs, name, v ? "true" : "false", .User)
		blocker.touch(&app.bl.b)
	}
}

@(private = "file")
fmt_bytes :: proc(n: int) -> string {
	switch {
	case n >= 1 << 20: return fmt.tprintf("%.1f MB", f64(n) / f64(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%.0f KB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

@(private = "file")
fmt_date :: proc(unix_s: i64) -> string {
	if unix_s == 0 { return i18n.tr("never") }
	lt := local_time(unix_s * MS_PER_SECOND)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", lt.year, lt.month, lt.day, lt.hour, lt.minute)
}

////////////////////////////////
// The page

blocker_page :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	if !app.bl.started { return }
	b := &app.bl.b
	// the journal records only while it is on screen
	b.journal.armed = app.dash.tab == int(Dash_Tab.Journal)
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###blocker_page")
		if ui.parent(root) {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BLOCKER_ROW_H_EM))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
				ui.label(tid(i18n.tr("Content blocker"), "bd_title"))
				ui.spacer(ui.px(em * 1.2))
				state, count, rules := blocker_shield(app, t)
				_ = state; _ = count
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					ui.label(tid(fmt.tprintf(i18n.tr("state, filter count, total blocked", "%s · %d filters · %d blocked in all"), b.cfg.enabled ? i18n.tr("blocker state", "on") : i18n.tr("blocker state", "off"), rules, b.totals.blocked), "bd_sub"))
				}
				ui.spacer(ui.px(em * 0.8))
			}
			labels := []string{i18n.tr("Settings"), i18n.tr("Filter lists"), i18n.tr("My filters"), i18n.tr("My rules"), i18n.tr("Whitelist"), i18n.tr("Journal"), i18n.tr("Statistics"), i18n.tr("About")}
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
			if ui.row(.Start, {}, "###bd_tabs_row") {
				if ui.tabs("###bd_tabs", labels, nil, &app.dash.tab) {
					a := fmt.tprintf("about:blocker#%s", DASH_NAMES[Dash_Tab(app.dash.tab)])
					delete(t.url); t.url = strings.clone(a)
				}
			}
			ui.hline(ui.fill())
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.column() {
				switch Dash_Tab(app.dash.tab) {
				case .Settings: tab_settings(app, t)
				case .Lists: tab_lists(app, t)
				case .My_Filters: tab_my_filters(app, t)
				case .My_Rules: tab_my_rules(app, t)
				case .Whitelist: tab_whitelist(app, t)
				case .Journal: tab_journal(app, t)
				case .Statistics: tab_statistics(app, t)
				case .About: tab_about(app, t)
				}
			}
		}
	}
}

////////////////////////////////
// Settings

@(private = "file")
tab_settings :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &app.bl.b
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###bs_scroll") {
		section(i18n.tr("Blocking"), "block")
		pref_row(app, i18n.tr("Block advertising, tracking and malware requests"), "blocker.enabled", "enabled")
		pref_row(app, i18n.tr("Hide the elements ads leave behind (element hiding)"), "blocker.cosmetic.enabled", "cos")
		pref_row(app, i18n.tr("Run scriptlets: anti-blocker defusers, YouTube ads"), "blocker.scriptlets.enabled", "scr")
		pref_row(app, i18n.tr("Collapse blocked frames and images"), "blocker.collapse.enabled", "col")
		pref_row(app, i18n.tr("Answer blocked scripts with neutral stand-ins"), "blocker.redirects.enabled", "red")
		pref_row(app, i18n.tr("Remove tracking parameters from URLs"), "blocker.removeparam.enabled", "rp")
		section(i18n.tr("Every site"), "every")
		pref_row(app, i18n.tr("Hard mode: block third-party scripts and frames"), "blocker.hard_mode", "hard")
		pref_row(app, i18n.tr("Block remote web fonts"), "blocker.remote_fonts", "fonts")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { cell(i18n.tr("Large media are blocked on sites that ask for it above"), "bs_lm_l", em * 28, true); cell(fmt.tprintf("%d KB (blocker.large_media_kb)", b.cfg.large_media_kb), "bs_lm_v", em * 14) }
		}
		section(i18n.tr("Updates"), "app.upd")
		pref_row(app, i18n.tr("Download and update the filter lists in the background"), "blocker.update.enabled", "app.upd")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			ui.next({width = ui.px(em * 14), height = ui.pct(1)})
			if ui.tags("weak") { ui.label(tid(i18n.tr("Check the lists every"), "bs_int_l")) }
			opts := []string{fmt.tprintf(i18n.tr(1, "%d hour", "%d hours"), 1), fmt.tprintf(i18n.tr(6, "%d hour", "%d hours"), 6), fmt.tprintf(i18n.tr(12, "%d hour", "%d hours"), 12), fmt.tprintf(i18n.tr(1, "%d day", "%d days"), 1), fmt.tprintf(i18n.tr(3, "%d day", "%d days"), 3), fmt.tprintf(i18n.tr(7, "%d day", "%d days"), 7), fmt.tprintf(i18n.tr(30, "%d day", "%d days"), 30)}
			hours := []int{1, 6, 12, 24, 72, 168, 720}
			sel := 3
			for h, i in hours { if h == b.cfg.update_hours { sel = i } }
			ui.next({width = ui.px(em * 9), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
			if ui.dropdown("###bs_interval", opts, &sel) { config.set_from_string(&app.prefs, "blocker.update.interval_hours", fmt.tprintf("%d", hours[sel]), .User) }
			ui.spacer(ui.px(em * 0.8))
			if ui.button("bs_update_now", i18n.tr("Update now"), lucide.REFRESH_CW, {intent = .Primary, tip = i18n.tr("Ask every enabled list for a newer version now"), width = ui.px(em * 8)}).clicked { blocker.updater_round(b, true) }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(tid(b.upd.status != "" ? b.upd.status : (b.upd.last_round > 0 ? fmt.tprintf(i18n.tr("last check %s"), fmt_date(b.upd.last_round)) : i18n.tr("no check yet")), "bs_upd_st")) }
		}
		section(i18n.tr("Display"), "disp")
		pref_row(app, i18n.tr("Number of blocked requests on the icon"), "blocker.badge.enabled", "badge")
		pref_row(app, i18n.tr("Console line for each blocked request (net::ERR_BLOCKED_BY_CLIENT)"), "blocker.console.enabled", "cons")
		pref_row(app, i18n.tr("Keep the request log even when this page is closed"), "blocker.log.always", "logall")
		section(i18n.tr("Configuration"), "conf")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.button("bs_export", i18n.tr("Export…"), lucide.FOLDER_OUTPUT, {tip = i18n.tr("Save the lists, rules, sites and filters as one file"), width = ui.px(em * 8)}).clicked { dash_export(app) }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("bs_import", i18n.tr("Import…"), lucide.FOLDER_INPUT, {tip = i18n.tr("Load a configuration file (replaces the lists chosen, rules, sites and filters)"), width = ui.px(em * 8)}).clicked { dash_import(app) }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("bs_reset_stats", i18n.tr("Reset statistics"), lucide.ROTATE_CCW, {intent = .Danger, width = ui.px(em * 10)}).clicked { b.totals = {since = blocker.unix_ms() / 1000}; blocker.conf_save(b) }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(tid(app.dash.status, "bs_conf_st")) }
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(tid(i18n.tr("More preferences: about:config, search blocker."), "bs_more")) }
		}
	}
}

////////////////////////////////
// Filter lists

group_title :: proc(group: string) -> string {
	switch group {
	case "Ads": return i18n.tr("list group", "Ads")
	case "Privacy": return i18n.tr("list group", "Privacy")
	case "Malware": return i18n.tr("list group", "Malware")
	case "Annoyances": return i18n.tr("list group", "Annoyances")
	case "Regions": return i18n.tr("list group", "Regions")
	case "Custom": return i18n.tr("list group", "Custom")
	}
	return group
}

@(private = "file")
tab_lists :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &app.bl.b
	// toolbar
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BLOCKER_ROW_H_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.button("bl_update", i18n.tr("Update now"), lucide.REFRESH_CW, {intent = .Primary, width = ui.px(em * 8)}).clicked { blocker.updater_round(b, true) }
		ui.spacer(ui.px(em * 0.5))
		if ui.button("bl_apply", i18n.tr("Apply"), lucide.CHECK, {intent = .Success, tip = i18n.tr("Rebuild the filter index from the lists switched on"), width = ui.px(em * 6)}).clicked { blocker.rebuild(b) }
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(tid(fmt.tprintf(i18n.tr("status, filters in force, build time", "%s · %d filters in force · built in %.0f ms"), b.upd.status != "" ? b.upd.status : i18n.tr("up to date"), b.engine != nil ? b.engine.rules : 0, b.upd.last_compile_ms), "bl_status"))
		}
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###bl_scroll") {
		for group in ([?]string{"Ads", "Privacy", "Malware", "Annoyances", "Regions", "Custom"}) {
		section(group_title(group), fmt.tprintf("lg_%s", group))
		for &l in b.conf.lists {
			if l.group != group { continue }
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.0))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				v := l.enabled
				ui.next({width = ui.px(em * 25), height = ui.pct(1)})
				if ui.checkbox(fmt.tprintf("###lc_%s", l.id), l.title, &v) {
					l.enabled = v
					blocker.conf_save(b)
					if v { blocker.updater_round(b, false); blocker.rebuild(b) } else { blocker.rebuild(b) }
				}
				cell(l.rules > 0 ? fmt.tprintf("%d", l.rules) : "–", fmt.tprintf("lr_%s", l.id), em * 5.5, true, .Right)
				cell(l.size > 0 ? fmt_bytes(l.size) : "–", fmt.tprintf("ls_%s", l.id), em * 5.5, true, .Right)
				cell(fmt_date(l.updated), fmt.tprintf("lu_%s", l.id), em * 10, true, .Right)
				status := ""
				switch {
				case l.error != "": status = l.error
				case l.state == .Downloading: status = i18n.tr("downloading…")
				case l.state == .Queued: status = i18n.tr("waiting")
				case l.state == .Compiling: status = i18n.tr("compiling…")
				case l.enabled && l.size == 0: status = i18n.tr("not downloaded yet")
				case l.invalid > 0: status = fmt.tprintf(i18n.tr(int(l.invalid), "%d line not understood", "%d lines not understood"), l.invalid)
				}
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.pct(1), font_size = em * 0.85})
				l_err := l.error != ""
				if l_err { ui.label(fmt.aprintf("%s###le_%s", status, l.id, allocator = ui.frame_allocator())) } else if ui.tags("weak") { ui.label(fmt.aprintf("%s###le_%s", status, l.id, allocator = ui.frame_allocator())) }
				if l.custom && ui.button(strings.concatenate({"###", fmt.tprintf("lx_%s", l.id)}, ui.frame_allocator()), i18n.tr("Remove"), lucide.TRASH_2, {intent = .Danger, width = ui.px(em * 6)}).clicked {
					id := strings.clone(l.id, context.temp_allocator)
					blocker.list_remove(b, id)
					blocker.conf_save(b)
					blocker.rebuild(b)
					break
				}
				ui.spacer(ui.px(em * 0.6))
			}
		}
		}
		section(i18n.tr("Custom list"), "custom")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			ui.next({width = ui.px(em * 12), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
			ui.line_edit("###bl_cname", &app.dash.custom_name, {placeholder = i18n.tr("Name (optional)")})
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.px(em * 36), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
			res := ui.line_edit("###bl_curl", &app.dash.custom_url, {placeholder = "https://example.org/filters.txt"})
			ui.spacer(ui.px(em * 0.5))
			url := strings.trim_space(ui.line_edit_string(&app.dash.custom_url))
			valid := strings.has_prefix(url, "https://") || strings.has_prefix(url, "http://")
			if ui.disabled(!valid) {
				if ui.button("bl_cadd", i18n.tr("Add list"), lucide.PLUS, {intent = .Success, width = ui.px(em * 7)}).clicked || (res.committed && valid) {
					blocker.list_add_custom(b, strings.trim_space(ui.line_edit_string(&app.dash.custom_name)), url)
					ui.line_edit_clear(&app.dash.custom_url); ui.line_edit_clear(&app.dash.custom_name)
					blocker.conf_save(b)
					blocker.updater_round(b, false)
				}
			}
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(tid(i18n.tr("A list is downloaded from its address, checked, and kept in the profile. Nothing is sent about you."), "bl_note")) }
		}
	}
}

////////////////////////////////
// My filters

@(private = "file")
diagnose :: proc(text: string) {
	delete(the_app.dash.my_diag)
	for _, v in the_app.dash.my_errors { delete(v) }
	clear(&the_app.dash.my_errors)
	if the_app.dash.my_errors == nil { the_app.dash.my_errors = make(map[int]string) }
	diags := make([dynamic]string)
	valid, ignored := 0, 0
	line_no := 0        // 1-based, for the message
	para := 0           // 0-based paragraph index, for the editor's underline map
	rest := text
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line: string
		if nl < 0 { line, rest = rest, "" } else { line, rest = rest[:nl], rest[nl + 1:] }
		line_no += 1
		defer para += 1
		t := strings.trim_space(line)
		if t == "" || t[0] == '!' || strings.has_prefix(t, "!#") || t[0] == '[' { continue }
		p := adblock.parse_line(t, 0, 0, context.temp_allocator)
		if p.kind == .None {
			ignored += 1
			msg := fmt.aprintf(i18n.tr("line number, the line", "line %d: not understood or not supported: %s"), line_no, t[:min(len(t), 70)])
			if len(diags) < 8 { append(&diags, msg) }
			the_app.dash.my_errors[para] = strings.clone(i18n.tr("not understood or not supported (uBlock Origin ignores it too)"))
		} else { valid += 1 }
	}
	the_app.dash.my_diag = diags[:]
	the_app.dash.my_valid, the_app.dash.my_ignored = valid, ignored
}

@(private = "file")
tab_my_filters :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &app.bl.b
	if !app.dash.my_loaded {
		ui.text_edit_set(&app.dash.my, b.conf.my_filters)
		app.dash.my_loaded, app.dash.my_dirty = true, false
		diagnose(b.conf.my_filters)
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BLOCKER_ROW_H_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.disabled(!app.dash.my_dirty) {
			if ui.button("mf_apply", i18n.tr("Apply changes"), lucide.CHECK, {intent = .Success, tip = i18n.tr("Compile the filters into the index (Ctrl+S)"), width = ui.px(em * 10)}).clicked { dash_apply_filters(app) }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("mf_revert", i18n.tr("Revert"), lucide.UNDO_2, {intent = .Cancel, width = ui.px(em * 6)}).clicked { app.dash.my_loaded = false }
		}
		ui.spacer(ui.px(em * 0.5))
		if ui.button("mf_import", i18n.tr("Import…"), lucide.FOLDER_INPUT, {tip = i18n.tr("Add the lines of a text file"), width = ui.px(em * 7)}).clicked { dash_import_filters(app) }
		ui.spacer(ui.px(em * 0.5))
		if ui.button("mf_export", i18n.tr("Export…"), lucide.FOLDER_OUTPUT, {tip = i18n.tr("Save these filters as a text file"), width = ui.px(em * 7)}).clicked { dash_export_filters(app) }
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(tid(app.dash.my_dirty ? fmt.tprintf(i18n.tr("filters, lines not understood", "%d filters, %d lines not understood · changes not applied"), app.dash.my_valid, app.dash.my_ignored) : fmt.tprintf(i18n.tr("filters, lines not understood", "%d filters, %d lines not understood"), app.dash.my_valid, app.dash.my_ignored), "mf_status"))
		}
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	hl := filter_highlight()
	res := ui.text_edit("###mf_edit", &app.dash.my, {placeholder = i18n.tr("! One filter per line. Examples:\n||ads.example.com^\nexample.com##.banner\nexample.com##+js(set-constant, adsEnabled, false)\nexample.com##^script:has-text(ads)\n@@||example.com^$document"), line_numbers = true, highlight = &hl})
	if res.changed {
		app.dash.my_dirty = true
		diagnose(ui.text_edit_string(&app.dash.my))
	}
	// a tooltip over an invalid line: the engine's reason for dropping it
	if res.hover_line >= 0 {
		if msg, bad := app.dash.my_errors[res.hover_line]; bad {
			if ui.tooltip() { ui.label(label_text(msg)) }
		}
	}
	if res.focused && ui.key_press(.S, {.Ctrl}) && app.dash.my_dirty { dash_apply_filters(app) }
	if len(app.dash.my_diag) > 0 {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5 * f32(min(len(app.dash.my_diag), 5)) + em * 0.6))})
		if ui.column() {
			for d, i in app.dash.my_diag[:min(len(app.dash.my_diag), 5)] {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5)), font_size = em * 0.88})
				ui.label(fmt.aprintf("%s###mf_d%d", label_text(d), i, allocator = ui.frame_allocator()))
			}
		}
	}
}

@(private = "file")
dash_apply_filters :: proc(app: ^App) {
	b := &app.bl.b
	delete(b.conf.my_filters)
	b.conf.my_filters = strings.clone(ui.text_edit_string(&app.dash.my))
	app.dash.my_dirty = false
	blocker.conf_save(b)
	blocker.rebuild(b)
	announce(app, .Good, i18n.tr("Filters applied"))
}

////////////////////////////////
// My rules

@(private = "file")
tab_my_rules :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &app.bl.b
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BLOCKER_ROW_H_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		ui.line_edit("###mr_src", &app.dash.rule_src, {placeholder = i18n.tr("site or *")})
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(em * 15), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		ui.line_edit("###mr_dst", &app.dash.rule_dst, {placeholder = i18n.tr("destination host or *")})
		ui.spacer(ui.px(em * 0.4))
		names := make([]string, len(blocker.DYN_TYPE_NAMES), context.temp_allocator)
		for n, i in blocker.DYN_TYPE_NAMES { names[i] = n }
		ui.next({width = ui.px(em * 8.5), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		ui.dropdown("###mr_type", names, &app.dash.rule_type)
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(em * 7), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		ui.dropdown("###mr_action", []string{i18n.tr("rule action", "block"), i18n.tr("rule action", "allow")}, &app.dash.rule_action)
		ui.spacer(ui.px(em * 0.4))
		src := base.ascii_lower(strings.trim_space(ui.line_edit_string(&app.dash.rule_src)))
		dst := base.ascii_lower(strings.trim_space(ui.line_edit_string(&app.dash.rule_dst)))
		if src == "" { src = "*" }
		if ui.disabled(dst == "") {
			if ui.button("mr_add", i18n.tr("Add rule"), lucide.PLUS, {intent = .Success, width = ui.px(em * 7)}).clicked {
				blocker.dyn_set(&b.dyn, src, dst, blocker.Dyn_Type(app.dash.rule_type), app.dash.rule_action == 0 ? .Block : .Allow)
				blocker_rules_saved()
				ui.line_edit_clear(&app.dash.rule_dst)
			}
		}
		ui.spacer(ui.px(em * 0.5))
		if ui.button("mr_clear", i18n.tr("Remove all"), lucide.TRASH_2, {intent = .Danger, width = ui.px(em * 8)}).clicked { blocker.dyn_clear(&b.dyn); blocker_rules_saved() }
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.tags("weak") {
			cell(i18n.tr("source"), "mrh_s", em * 11); cell(i18n.tr("destination"), "mrh_d", em * 15); cell(i18n.tr("kind"), "mrh_t", em * 8.5); cell(i18n.tr("action"), "mrh_a", em * 7)
		}
	}
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###mr_scroll") {
		rules := blocker.dyn_sorted(&b.dyn)
		remove: int = -1
		for r, i in rules {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				cell(r.src, fmt.tprintf("mrs_%d", i), em * 11)
				cell(r.dst, fmt.tprintf("mrd_%d", i), em * 15)
				cell(blocker.DYN_TYPE_NAMES[r.type], fmt.tprintf("mrt_%d", i), em * 8.5)
				ui.next({width = ui.px(em * 7), height = ui.pct(1)})
				if r.action == .Block { ui.next({width = ui.px(em * 7), height = ui.pct(1), fg = BLOCK_RED}) } else { ui.next({width = ui.px(em * 7), height = ui.pct(1), fg = SHIELD_GREEN}) }
				ui.label(fmt.aprintf("%s###mra_%d", r.action == .Block ? i18n.tr("rule action", "block") : i18n.tr("rule action", "allow"), i, allocator = ui.frame_allocator()))
				if remove_cross(fmt.tprintf("###mrx_%d", i), true, em, i18n.tr("Remove this rule")).clicked { remove = i }
			}
		}
		if remove >= 0 { r := rules[remove]; blocker.dyn_set(&b.dyn, strings.clone(r.src, context.temp_allocator), strings.clone(r.dst, context.temp_allocator), r.type, .Noop); blocker_rules_saved() }
		if len(rules) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(tid(i18n.tr("No rule. Click the cells of the matrix in the panel of the icon, or add one above."), "mr_none")) } }
		}
	}
}

blocker_rules_saved :: proc() {
	the_app.bl.b.dyn.version += 1
	the_app.bl.b.conf_ver += 1
	blocker.conf_save(&the_app.bl.b)
	blocker.touch(&the_app.bl.b)
}

////////////////////////////////
// Whitelist

@(private = "file")
tab_whitelist :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &app.bl.b
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BLOCKER_ROW_H_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 26), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		res := ui.line_edit("###wl_add", &app.dash.wl_add, {placeholder = i18n.tr("example.org: a site where the blocker stays off")})
		ui.spacer(ui.px(em * 0.5))
		host := base.ascii_lower(strings.trim_space(ui.line_edit_string(&app.dash.wl_add)))
		host = strings.trim_prefix(strings.trim_prefix(host, "https://"), "http://")
		if i := strings.index_any(host, "/?#"); i >= 0 { host = host[:i] }
		if ui.disabled(host == "") {
			if ui.button("wl_btn", i18n.tr("Add"), lucide.PLUS, {intent = .Success, width = ui.px(em * 5)}).clicked || (res.committed && host != "") {
				blocker.site_toggle(b, strings.clone(host, context.temp_allocator), .Off, true)
				ui.line_edit_clear(&app.dash.wl_add)
			}
		}
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(tid(i18n.tr("A site here is not filtered at all (subdomains too)."), "wl_note")) }
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###wl_scroll") {
		hosts := make([dynamic]string, context.temp_allocator)
		for h in b.conf.sites { append(&hosts, h) }
		slice_sort_strings(hosts[:])
		any := false
		for h, i in hosts {
			f := b.conf.sites[h]
			if f == {} { continue }
			any = true
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				cell(h, fmt.tprintf("wlh_%d", i), em * 24)
				flags := make([dynamic]string, context.temp_allocator)
				for fl in blocker.Site_Flag { if fl in f { append(&flags, blocker.SITE_FLAG_NAMES[fl]) } }
				cell(.Off in f ? i18n.tr("filtering off") : strings.join(flags[:], ", ", context.temp_allocator), fmt.tprintf("wlf_%d", i), em * 40, true)
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.spacer(ui.fill())
				if remove_cross(fmt.tprintf("###wlx_%d", i), true, em, i18n.tr("Remove this site")).clicked {
					blocker.site_set_flags(b, h, {})
					blocker.conf_save(b)
					break
				}
			}
		}
		if !any {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(tid(i18n.tr("No site. Turn the blocker off for a site with the power button of the panel."), "wl_none")) } }
		}
	}
}

@(private = "file")
slice_sort_strings :: proc(s: []string) {
	for i in 1 ..< len(s) {
		j := i
		for j > 0 && s[j] < s[j - 1] { s[j], s[j - 1] = s[j - 1], s[j]; j -= 1 }
	}
}

////////////////////////////////
// Journal

outcome_name :: proc(o: blocker.Outcome) -> string {
	switch o {
	case .Allowed: return i18n.tr("allowed")
	case .Blocked: return i18n.tr("blocked")
	case .Redirected: return i18n.tr("redirected")
	case .Rewritten: return i18n.tr("rewritten")
	case .Excepted: return i18n.tr("excepted")
	case .Dyn_Blocked: return i18n.tr("blocked (rule)")
	case .Dyn_Allowed: return i18n.tr("allowed (rule)")
	case .Site_Off: return i18n.tr("site off")
	case .Policy: return i18n.tr("blocked (policy)")
	case .Header: return i18n.tr("blocked (header)")
	case .Html_Filtered: return i18n.tr("element removed (HTML filter)")
	case .Popup: return i18n.tr("popup blocked")
	}
	return ""
}

@(private = "file")
outcome_color :: proc(o: blocker.Outcome) -> (c: ui.Color, tone: bool) {
	#partial switch o {
	case .Blocked, .Dyn_Blocked, .Policy, .Header, .Popup: return BLOCK_RED, true
	case .Redirected, .Rewritten, .Html_Filtered: return SHIELD_AMBER, true
	case .Excepted, .Dyn_Allowed: return SHIELD_GREEN, true
	}
	return {}, false
}

@(private = "file")
log_model :: proc(b: ^blocker.Blocker, query: string) {
	j := &b.journal
	if j.version == the_app.dash.log_version && query == the_app.dash.log_query && !the_app.dash.log_pause { /* same rows */ }
	if the_app.dash.log_pause && query == the_app.dash.log_query { return }
	if j.version == the_app.dash.log_version && query == the_app.dash.log_query { return }
	the_app.dash.log_version = j.version
	delete(the_app.dash.log_query); the_app.dash.log_query = strings.clone(query)
	clear(&the_app.dash.log_rows); clear(&the_app.dash.log_ids); clear(&the_app.dash.log_labels); clear(&the_app.dash.log_sel)
	q := strings.to_lower(query, context.temp_allocator)
	n := blocker.journal_len(j)
	for k := n - 1; k >= 0; k -= 1 {   // newest first
		e := blocker.journal_get(j, k)
		if the_app.dash.log_outcome > 0 {
			o := blocker.Outcome(the_app.dash.log_outcome - 1)
			if e.outcome != o { continue }
		}
		if the_app.dash.log_type > 0 && e.type != adblock.Resource(the_app.dash.log_type - 1) { continue }
		if q != "" && !strings.contains(strings.to_lower(e.url, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.rule, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.doc, context.temp_allocator), q) { continue }
		append(&the_app.dash.log_rows, k)
		append(&the_app.dash.log_ids, u64(j.total) - u64(n - k))
		append(&the_app.dash.log_labels, e.url)
		append(&the_app.dash.log_sel, true)
		if len(the_app.dash.log_rows) >= 20000 { break }
	}
}

@(private = "file")
tab_journal :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &app.bl.b
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BLOCKER_ROW_H_EM))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 22), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		ui.line_edit("###lg_search", &app.dash.log_search, {placeholder = i18n.tr("Search URL, rule or document")})
		ui.spacer(ui.px(em * 0.5))
		outs := make([]string, len(blocker.Outcome) + 1, context.temp_allocator)
		outs[0] = i18n.tr("all outcomes")
		for o in blocker.Outcome { outs[int(o) + 1] = outcome_name(o) }
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		if ui.dropdown("###lg_outcome", outs, &app.dash.log_outcome) { app.dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.4))
		types := make([]string, 22, context.temp_allocator)
		types[0] = i18n.tr("all types")
		k := 1
		for r in adblock.Resource { if r <= .Webrtc { types[k] = adblock.resource_name(r); k += 1 } }
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * TOOL_CONTROL_H_EM))})
		if ui.dropdown("###lg_type", types[:k], &app.dash.log_type) { app.dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.5))
		if ui.button("lg_pause", app.dash.log_pause ? i18n.tr("Resume") : i18n.tr("Pause"), app.dash.log_pause ? lucide.PLAY : lucide.PAUSE, {width = ui.px(em * 7)}).clicked { app.dash.log_pause = !app.dash.log_pause; app.dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.4))
		if ui.button("lg_clear", i18n.tr("Clear"), lucide.TRASH_2, {intent = .Danger, width = ui.px(em * 6)}).clicked { blocker.journal_clear(&b.journal); app.dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(tid(fmt.tprintf(i18n.tr("rows shown, rows in all", "%d shown of %d"), len(app.dash.log_rows), blocker.journal_len(&b.journal)), "lg_count")) }
	}
	log_model(b, strings.trim_space(ui.line_edit_string(&app.dash.log_search)))
	// header
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.tags("weak") {
			cell(i18n.tr("time"), "lgh_t", em * 6.5); cell(i18n.tr("type"), "lgh_y", em * 6.5); cell(i18n.tr("outcome"), "lgh_o", em * 8.5); cell(i18n.tr("URL"), "lgh_u", em * 38); cell(i18n.tr("document"), "lgh_d", em * 13); cell(i18n.tr("rule"), "lgh_r", em * 20)
		}
	}
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if rows, ok := ui.vlist("###lg_list", &app.dash.log_list, app.dash.log_ids[:], app.dash.log_labels[:], app.dash.log_sel[:]); ok {
		for i in rows.first ..< rows.last {
			e := blocker.journal_get(&b.journal, app.dash.log_rows[i])
			if e == nil { continue }
			ui.next({height = ui.px(ui.dense(em * 1.75))})
			row := ui.list_row(&app.dash.log_list.list, i, app.dash.log_labels[i])
			if ui.parent(row.box) {
				ui.spacer(ui.px(em * 0.9))
				lt := local_time(e.time)
				cell(fmt.tprintf("%02d:%02d:%02d", lt.hour, lt.minute, lt.second), fmt.tprintf("lgt_%d", i), em * 6.5, true)
				cell(adblock.resource_name(e.type), fmt.tprintf("lgy_%d", i), em * 6.5, true)
				col, tone := outcome_color(e.outcome)
				ui.next({width = ui.px(em * 8.5), height = ui.pct(1), font_size = em * 0.92, fg = tone ? col : ui.color("text")})
				ui.label(fmt.aprintf("%s###lgo_%d", outcome_name(e.outcome), i, allocator = ui.frame_allocator()))
				cell(e.url, fmt.tprintf("lgu_%d", i), em * 38)
				cell(address_host(e.doc), fmt.tprintf("lgd_%d", i), em * 13, true)
				cell(e.rule, fmt.tprintf("lgr_%d", i), em * 20, true)
			}
			if row.right_clicked {
				app.dash.log_menu = app.dash.log_rows[i]
				ui.menu_open("###lg_menu", ui.mouse_pos())
			}
		}
		if len(app.dash.log_rows) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(tid(i18n.tr("Nothing yet: load a page. The log records while this tab is shown."), "lg_none")) } }
		}
	}
	journal_menu(app, t)
}

@(private = "file")
journal_menu :: proc(app: ^App, t: ^Tab) {
	if ui.menu("###lg_menu") { journal_menu_items(app, t) }
}

@(private = "file")
journal_menu_items :: proc(app: ^App, t: ^Tab) {
	b := &app.bl.b
	e := blocker.journal_get(&b.journal, app.dash.log_menu)
	if e == nil { return }
	host := adblock.url_host(e.url)
	if ui.menu_item(i18n.tr("Copy the URL"), icon = lucide.COPY).clicked { clip_set(e.url) }
	if ui.menu_item(i18n.tr("Copy the rule"), disabled = e.rule == "", icon = lucide.COPY).clicked { clip_set(e.rule) }
	ui.menu_separator()
	if ui.menu_item(fmt.tprintf(i18n.tr("Create an exception for %s"), host), disabled = host == "", icon = lucide.SHIELD).clicked {
		line := fmt.tprintf("@@||%s^%s", host, e.type == .Document ? "$document" : "")
		dash_add_filter(app, line)
	}
	if ui.menu_item(i18n.tr("Create an exception for this URL only"), disabled = e.url == "", icon = lucide.SHIELD).clicked { dash_add_filter(app, fmt.tprintf("@@%s", e.url)) }
	if ui.menu_item(fmt.tprintf(i18n.tr("Block %s on every site"), host), disabled = host == "", icon = lucide.SHIELD).clicked { dash_add_filter(app, fmt.tprintf("||%s^", host)) }
	if ui.menu_item(fmt.tprintf(i18n.tr("Allow %s (dynamic rule, every site)"), host), disabled = host == "", icon = lucide.SHIELD).clicked {
		blocker.dyn_set(&b.dyn, "*", host, .All, .Allow)
		blocker_rules_saved()
		announce(app, .Good, fmt.tprintf(i18n.tr("Rule added: * %s * allow"), host))
	}
	ui.menu_separator()
	if ui.menu_item(i18n.tr("Open the document"), disabled = e.doc == "", icon = lucide.EXTERNAL_LINK).clicked { tab_open(app, strings.clone(e.doc, context.temp_allocator), origin = .Replay) }
}

dash_add_filter :: proc(app: ^App, line: string) {
	b := &app.bl.b
	sb := strings.builder_make()
	strings.write_string(&sb, b.conf.my_filters)
	if b.conf.my_filters != "" && !strings.has_suffix(b.conf.my_filters, "\n") { strings.write_byte(&sb, '\n') }
	strings.write_string(&sb, line)
	strings.write_byte(&sb, '\n')
	delete(b.conf.my_filters)
	b.conf.my_filters = strings.to_string(sb)
	app.dash.my_loaded = false
	blocker.conf_save(b)
	blocker.rebuild(b)
	announce(app, .Good, fmt.tprintf(i18n.tr("Filter added to My filters: %s"), line))
}

////////////////////////////////
// Statistics

@(private = "file")
stat_line :: proc(label, value, id: string) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		cell(label, fmt.tprintf("stl_%s", id), em * 26, true)
		cell(value, fmt.tprintf("stv_%s", id), em * 40)
	}
}

@(private = "file")
tab_statistics :: proc(app: ^App, t: ^Tab) {
	b := &app.bl.b
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###st_scroll") {
		section(i18n.tr("Since"), "since")
		stat_line(i18n.tr("Counting since"), fmt_date(b.totals.since), "since")
		stat_line(i18n.tr("Pages loaded"), fmt.tprintf("%d", b.totals.pages), "pages")
		stat_line(i18n.tr("Requests blocked"), fmt.tprintf("%d", b.totals.blocked), "blocked")
		stat_line(fmt.tprintf("  %s", i18n.tr("of which answered with a stand-in")), fmt.tprintf("%d", b.totals.redirected), "red")
		stat_line(i18n.tr("Requests allowed"), fmt.tprintf("%d", b.totals.allowed), "allowed")
		stat_line(i18n.tr("URLs cleaned of tracking parameters"), fmt.tprintf("%d", b.totals.rewritten), "rewritten")
		total := b.totals.blocked + b.totals.allowed
		if total > 0 { stat_line(i18n.tr("Share of requests blocked"), fmt.tprintf("%.1f %%", 100 * f64(b.totals.blocked) / f64(total)), "share") }
		section(i18n.tr("Filter engine"), "engine")
		if b.engine != nil {
			stat_line(i18n.tr("Filters in force"), fmt.tprintf(i18n.tr("total, network, cosmetic", "%d (network %d, cosmetic %d)"), b.engine.rules, adblock.engine_filter_count(b.engine.engine), adblock.engine_cosmetic_count(b.engine.engine)), "rules")
			stat_line(i18n.tr("Index size"), fmt_bytes(adblock.engine_size(b.engine.engine)), "size")
			stat_line(i18n.tr("Built in"), fmt.tprintf(i18n.tr("%.0f ms (on a background thread; start-up loads the cache)"), b.upd.last_compile_ms), "built")
			for s in b.engine.sources {
				stat_line(fmt.tprintf("  %s", s.name), fmt.tprintf(i18n.tr("network, cosmetic, lines not understood", "%d network · %d cosmetic · %d lines not understood"), s.net, s.cosmetic, s.invalid), fmt.tprintf("src%d", s.id))
			}
		}
	}
}

////////////////////////////////
// About

////////////////////////////////
// Files

dash_export :: proc(app: ^App) { file_dialog(app, true, "wren-blocker.txt", 0) }
dash_import :: proc(app: ^App) { file_dialog(app, false, "", 0) }
dash_export_filters :: proc(app: ^App) { file_dialog(app, true, "my-filters.txt", 1) }
dash_import_filters :: proc(app: ^App) { file_dialog(app, false, "", 1) }

_ :: os
_ :: time

package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "toolkit:ui"
import "wb:adblock"
import "wb:base"
import "wb:blocker"
import "wb:config"

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

is_blocker_address :: proc(a: string) -> bool { return a == BLOCKER_URL || strings.has_prefix(a, BLOCKER_URL + "#") }

Dash_Tab :: enum { Settings, Lists, My_Filters, My_Rules, Whitelist, Journal, Statistics, About }

DASH_NAMES := [Dash_Tab]string{
	.Settings = "settings", .Lists = "lists", .My_Filters = "filters", .My_Rules = "rules", .Whitelist = "whitelist",
	.Journal = "journal", .Statistics = "statistics", .About = "about",
}

Dash :: struct {
	tab:         int,
	my:          ui.Text_Area,
	my_loaded:   bool,
	my_dirty:    bool,
	my_diag:     []string,
	my_valid, my_ignored: int,
	my_checked:  string,
	custom_url:  ui.Text_Field,
	custom_name: ui.Text_Field,
	wl_add:      ui.Text_Field,
	rule_src, rule_dst: ui.Text_Field,
	rule_type, rule_action: int,
	log_search:  ui.Text_Field,
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

dash: Dash

dash_destroy :: proc() {
	ui.area_destroy(&dash.my)
	ui.field_destroy(&dash.custom_url); ui.field_destroy(&dash.custom_name); ui.field_destroy(&dash.wl_add)
	ui.field_destroy(&dash.rule_src); ui.field_destroy(&dash.rule_dst); ui.field_destroy(&dash.log_search)
	ui.vlist_destroy(&dash.log_list)
	delete(dash.my_diag); delete(dash.log_rows); delete(dash.log_ids); delete(dash.log_labels); delete(dash.log_sel)
	delete(dash.log_query); delete(dash.status); delete(dash.my_checked)
	dash = {}
}

show_blocker :: proc(app: ^App, t: ^Tab, address: string) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, .Blocker
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	for l in t.console { delete(l) }
	clear(&t.console)
	delete(t.url); t.url = strings.clone(address)
	delete(t.title); t.title = strings.clone("Content blocker")
	set_status(t, "about:blocker")
	ui.field_set(&app.address, address)
	if i := strings.index_byte(address, '#'); i >= 0 {
		frag := address[i + 1:]
		for n, tb in DASH_NAMES { if n == frag { dash.tab = int(tb) } }
	}
	dash.my_loaded = false
}

////////////////////////////////
// Small widgets

@(private = "file")
cell :: proc(text: string, id: string, w: f32, weak := false, align := ui.Text_Align.Left) {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.pct(1), text_align = align, font_size = em * 0.92})
	label := fmt.aprintf("%s###%s", text, id, allocator = ui.frame_allocator())
	if weak { if ui.tags("weak") { ui.label(label) } } else { ui.label(label) }
}

@(private = "file")
tool_button :: proc(text, id: string, w: f32, tip_text := "") -> bool {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.9)), radius = em * 0.35})
	sig := ui.button(fmt.aprintf("%s###%s", text, id, allocator = ui.frame_allocator()))
	if tip_text != "" { tip(sig, tip_text) }
	return sig.clicked
}

@(private = "file")
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
	if ui.toggle(fmt.aprintf("###pt_%s", id, allocator = ui.frame_allocator()), label, &v).clicked {
		config.set_from_string(&app.prefs, name, v ? "true" : "false", .User)
		blocker.touch(&bl.b)
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
	if unix_s == 0 { return "never" }
	lt := local_time(unix_s * 1000)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", lt.year, lt.month, lt.day, lt.hour, lt.minute)
}

////////////////////////////////
// The page

blocker_page :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	if !bl.started { return }
	b := &bl.b
	// the journal records only while it is on screen
	b.journal.armed = dash.tab == int(Dash_Tab.Journal)
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###blocker_page")
		if ui.parent(root) {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
				ui.label("Content blocker###bd_title")
				ui.spacer(ui.px(em * 1.2))
				state, count, rules := blocker_shield(app, t)
				_ = state; _ = count
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					ui.label(fmt.tprintf("%s · %d filters · %d blocked in all###bd_sub", b.cfg.enabled ? "on" : "off", rules, b.totals.blocked))
				}
				ui.spacer(ui.px(em * 0.8))
			}
			labels := []string{"Settings", "Filter lists", "My filters", "My rules", "Whitelist", "Journal", "Statistics", "About"}
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
			if ui.row(.Start, {}, "###bd_tabs_row") {
				if ui.tabs("###bd_tabs", labels, nil, &dash.tab) {
					a := fmt.tprintf("about:blocker#%s", DASH_NAMES[Dash_Tab(dash.tab)])
					delete(t.url); t.url = strings.clone(a)
					if current_tab(app) == t { ui.field_set(&app.address, a) }
				}
			}
			ui.hline(ui.fill())
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.column() {
				switch Dash_Tab(dash.tab) {
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
	b := &bl.b
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###bs_scroll") {
		section("Blocking", "block")
		pref_row(app, "Block advertising, tracking and malware requests", "blocker.enabled", "enabled")
		pref_row(app, "Hide the elements ads leave behind (element hiding)", "blocker.cosmetic.enabled", "cos")
		pref_row(app, "Run scriptlets: anti-blocker defusers, YouTube ads", "blocker.scriptlets.enabled", "scr")
		pref_row(app, "Collapse blocked frames and images", "blocker.collapse.enabled", "col")
		pref_row(app, "Answer blocked scripts with neutral stand-ins", "blocker.redirects.enabled", "red")
		pref_row(app, "Remove tracking parameters from URLs", "blocker.removeparam.enabled", "rp")
		section("Every site", "every")
		pref_row(app, "Hard mode: block third-party scripts and frames", "blocker.hard_mode", "hard")
		pref_row(app, "Block remote web fonts", "blocker.remote_fonts", "fonts")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { cell("Large media are blocked on sites that ask for it above", "bs_lm_l", em * 28, true); cell(fmt.tprintf("%d KB (blocker.large_media_kb)", b.cfg.large_media_kb), "bs_lm_v", em * 14) }
		}
		section("Updates", "upd")
		pref_row(app, "Download and update the filter lists in the background", "blocker.update.enabled", "upd")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			ui.next({width = ui.px(em * 14), height = ui.pct(1)})
			if ui.tags("weak") { ui.label("Check the lists every###bs_int_l") }
			opts := []string{"1 hour", "6 hours", "12 hours", "1 day", "3 days", "7 days", "30 days"}
			hours := []int{1, 6, 12, 24, 72, 168, 720}
			sel := 3
			for h, i in hours { if h == b.cfg.update_hours { sel = i } }
			ui.next({width = ui.px(em * 9), height = ui.px(ui.dense(em * 1.9))})
			if ui.dropdown("###bs_interval", opts, &sel) { config.set_from_string(&app.prefs, "blocker.update.interval_hours", fmt.tprintf("%d", hours[sel]), .User) }
			ui.spacer(ui.px(em * 0.8))
			if tool_button("Update now", "bs_update_now", em * 8, "Ask every enabled list for a newer version now") { blocker.updater_round(b, true) }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(fmt.tprintf("%s###bs_upd_st", b.upd.status != "" ? b.upd.status : (b.upd.last_round > 0 ? fmt.tprintf("last check %s", fmt_date(b.upd.last_round)) : "no check yet"))) }
		}
		section("Display", "disp")
		pref_row(app, "Number of blocked requests on the icon", "blocker.badge.enabled", "badge")
		pref_row(app, "Console line for each blocked request (net::ERR_BLOCKED_BY_CLIENT)", "blocker.console.enabled", "cons")
		pref_row(app, "Keep the request log even when this page is closed", "blocker.log.always", "logall")
		section("Configuration", "conf")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if tool_button("Export…", "bs_export", em * 8, "Save the lists, rules, sites and filters as one file") { dash_export(app) }
			ui.spacer(ui.px(em * 0.5))
			if tool_button("Import…", "bs_import", em * 8, "Load a configuration file (replaces the lists chosen, rules, sites and filters)") { dash_import(app) }
			ui.spacer(ui.px(em * 0.5))
			if tool_button("Reset statistics", "bs_reset_stats", em * 10) { b.totals = {since = blocker.unix_ms() / 1000}; blocker.conf_save(b) }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(fmt.tprintf("%s###bs_conf_st", dash.status)) }
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label("More preferences: about:config, search blocker.###bs_more") }
		}
	}
}

////////////////////////////////
// Filter lists

@(private = "file")
tab_lists :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &bl.b
	// toolbar
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if tool_button("Update now", "bl_update", em * 8) { blocker.updater_round(b, true) }
		ui.spacer(ui.px(em * 0.5))
		if tool_button("Apply", "bl_apply", em * 6, "Rebuild the filter index from the lists switched on") { blocker.rebuild(b) }
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s · %d filters in force · built in %.0f ms###bl_status", b.upd.status != "" ? b.upd.status : "up to date", b.engine != nil ? b.engine.rules : 0, b.upd.last_compile_ms))
		}
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###bl_scroll") {
		for group in ([?]string{"Ads", "Privacy", "Malware", "Annoyances", "Regions", "Custom"}) {
		section(group, fmt.tprintf("lg_%s", group))
		for &l in b.conf.lists {
			if l.group != group { continue }
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.0))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				v := l.enabled
				ui.next({width = ui.px(em * 25), height = ui.pct(1)})
				if ui.checkbox(fmt.aprintf("###lc_%s", l.id, allocator = ui.frame_allocator()), l.title, &v).clicked {
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
				case l.state == .Downloading: status = "downloading…"
				case l.state == .Queued: status = "waiting"
				case l.state == .Compiling: status = "compiling…"
				case l.enabled && l.size == 0: status = "not downloaded yet"
				case l.invalid > 0: status = fmt.tprintf("%d lines not understood", l.invalid)
				}
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.pct(1), font_size = em * 0.85})
				l_err := l.error != ""
				if l_err { ui.label(fmt.aprintf("%s###le_%s", status, l.id, allocator = ui.frame_allocator())) } else if ui.tags("weak") { ui.label(fmt.aprintf("%s###le_%s", status, l.id, allocator = ui.frame_allocator())) }
				if l.custom && tool_button("Remove", fmt.tprintf("lx_%s", l.id), em * 6) {
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
		section("Custom list", "custom")
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			ui.next({width = ui.px(em * 12), height = ui.px(ui.dense(em * 1.9))})
			ui.line_edit("###bl_cname", &dash.custom_name, "Name (optional)")
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.px(em * 36), height = ui.px(ui.dense(em * 1.9))})
			res := ui.line_edit("###bl_curl", &dash.custom_url, "https://example.org/filters.txt")
			ui.spacer(ui.px(em * 0.5))
			url := strings.trim_space(ui.field_string(&dash.custom_url))
			valid := strings.has_prefix(url, "https://") || strings.has_prefix(url, "http://")
			if ui.disabled(!valid) {
				if tool_button("Add list", "bl_cadd", em * 7) || (res.committed && valid) {
					blocker.list_add_custom(b, strings.trim_space(ui.field_string(&dash.custom_name)), url)
					ui.field_clear(&dash.custom_url); ui.field_clear(&dash.custom_name)
					blocker.conf_save(b)
					blocker.updater_round(b, false)
				}
			}
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.9))
			if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label("A list is downloaded from its address, checked, and kept in the profile. Nothing is sent about you.###bl_note") }
		}
	}
}

////////////////////////////////
// My filters

@(private = "file")
diagnose :: proc(text: string) {
	delete(dash.my_diag)
	diags := make([dynamic]string)
	valid, ignored := 0, 0
	line_no := 0
	rest := text
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line: string
		if nl < 0 { line, rest = rest, "" } else { line, rest = rest[:nl], rest[nl + 1:] }
		line_no += 1
		t := strings.trim_space(line)
		if t == "" || t[0] == '!' || strings.has_prefix(t, "!#") { continue }
		p := adblock.parse_line(t, 0, 0, context.temp_allocator)
		if p.kind == .None {
			ignored += 1
			if len(diags) < 8 { append(&diags, fmt.aprintf("line %d: not understood or not supported: %s", line_no, t[:min(len(t), 70)])) }
		} else { valid += 1 }
	}
	dash.my_diag = diags[:]
	dash.my_valid, dash.my_ignored = valid, ignored
}

@(private = "file")
tab_my_filters :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &bl.b
	if !dash.my_loaded {
		ui.area_set(&dash.my, b.conf.my_filters)
		dash.my_loaded, dash.my_dirty = true, false
		diagnose(b.conf.my_filters)
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.disabled(!dash.my_dirty) {
			if tool_button("Apply changes", "mf_apply", em * 10, "Compile the filters into the index (Ctrl+S)") { dash_apply_filters(app) }
			ui.spacer(ui.px(em * 0.5))
			if tool_button("Revert", "mf_revert", em * 6) { dash.my_loaded = false }
		}
		ui.spacer(ui.px(em * 0.5))
		if tool_button("Import…", "mf_import", em * 7, "Add the lines of a text file") { dash_import_filters(app) }
		ui.spacer(ui.px(em * 0.5))
		if tool_button("Export…", "mf_export", em * 7, "Save these filters as a text file") { dash_export_filters(app) }
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%d filters, %d lines not understood%s###mf_status", dash.my_valid, dash.my_ignored, dash.my_dirty ? " · changes not applied" : ""))
		}
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	res := ui.text_edit("###mf_edit", &dash.my, "! One filter per line. Examples:\n||ads.example.com^\nexample.com##.banner\nexample.com##+js(set-constant, adsEnabled, false)\n@@||example.com^$document", line_numbers = true)
	if res.changed {
		dash.my_dirty = true
		diagnose(ui.area_string(&dash.my))
	}
	if res.focused && ui.key_press(.S, {.Ctrl}) && dash.my_dirty { dash_apply_filters(app) }
	if len(dash.my_diag) > 0 {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5 * f32(min(len(dash.my_diag), 5)) + em * 0.6))})
		if ui.column() {
			for d, i in dash.my_diag[:min(len(dash.my_diag), 5)] {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5)), font_size = em * 0.88})
				ui.label(fmt.aprintf("%s###mf_d%d", d, i, allocator = ui.frame_allocator()))
			}
		}
	}
}

@(private = "file")
dash_apply_filters :: proc(app: ^App) {
	b := &bl.b
	delete(b.conf.my_filters)
	b.conf.my_filters = strings.clone(ui.area_string(&dash.my))
	dash.my_dirty = false
	blocker.conf_save(b)
	blocker.rebuild(b)
	ui.toast(.Good, "Filters applied")
}

////////////////////////////////
// My rules

@(private = "file")
tab_my_rules :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &bl.b
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 1.9))})
		ui.line_edit("###mr_src", &dash.rule_src, "site or *")
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(em * 15), height = ui.px(ui.dense(em * 1.9))})
		ui.line_edit("###mr_dst", &dash.rule_dst, "destination host or *")
		ui.spacer(ui.px(em * 0.4))
		names := make([]string, len(blocker.DYN_TYPE_NAMES), context.temp_allocator)
		for n, i in blocker.DYN_TYPE_NAMES { names[i] = n }
		ui.next({width = ui.px(em * 8.5), height = ui.px(ui.dense(em * 1.9))})
		ui.dropdown("###mr_type", names, &dash.rule_type)
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(em * 7), height = ui.px(ui.dense(em * 1.9))})
		ui.dropdown("###mr_action", []string{"block", "allow"}, &dash.rule_action)
		ui.spacer(ui.px(em * 0.4))
		src := strings.to_lower(strings.trim_space(ui.field_string(&dash.rule_src)), context.temp_allocator)
		dst := strings.to_lower(strings.trim_space(ui.field_string(&dash.rule_dst)), context.temp_allocator)
		if src == "" { src = "*" }
		if ui.disabled(dst == "") {
			if tool_button("Add rule", "mr_add", em * 7) {
				blocker.dyn_set(&b.dyn, src, dst, blocker.Dyn_Type(dash.rule_type), dash.rule_action == 0 ? .Block : .Allow)
				blocker_rules_saved()
				ui.field_clear(&dash.rule_dst)
			}
		}
		ui.spacer(ui.px(em * 0.5))
		if tool_button("Remove all", "mr_clear", em * 8) { blocker.dyn_clear(&b.dyn); blocker_rules_saved() }
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.tags("weak") {
			cell("source", "mrh_s", em * 11); cell("destination", "mrh_d", em * 15); cell("kind", "mrh_t", em * 8.5); cell("action", "mrh_a", em * 7)
		}
	}
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###mr_scroll") {
		rules := blocker.dyn_sorted(&b.dyn)
		remove: int = -1
		for r, i in rules {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				cell(r.src, fmt.tprintf("mrs_%d", i), em * 11)
				cell(r.dst, fmt.tprintf("mrd_%d", i), em * 15)
				cell(blocker.DYN_TYPE_NAMES[r.type], fmt.tprintf("mrt_%d", i), em * 8.5)
				ui.next({width = ui.px(em * 7), height = ui.pct(1)})
				if r.action == .Block { ui.next({width = ui.px(em * 7), height = ui.pct(1), fg = BLOCK_RED}) } else { ui.next({width = ui.px(em * 7), height = ui.pct(1), fg = SHIELD_GREEN}) }
				ui.label(fmt.aprintf("%s###mra_%d", r.action == .Block ? "block" : "allow", i, allocator = ui.frame_allocator()))
				if remove_cross(fmt.tprintf("###mrx_%d", i), true, em, "Remove this rule").clicked { remove = i }
			}
		}
		if remove >= 0 { r := rules[remove]; blocker.dyn_set(&b.dyn, strings.clone(r.src, context.temp_allocator), strings.clone(r.dst, context.temp_allocator), r.type, .Noop); blocker_rules_saved() }
		if len(rules) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("No rule. Click the cells of the matrix in the panel of the icon, or add one above.###mr_none") } }
		}
	}
}

blocker_rules_saved :: proc() {
	bl.b.dyn.version += 1
	bl.b.conf_ver += 1
	blocker.conf_save(&bl.b)
	blocker.touch(&bl.b)
}

////////////////////////////////
// Whitelist

@(private = "file")
tab_whitelist :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &bl.b
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 26), height = ui.px(ui.dense(em * 1.9))})
		res := ui.line_edit("###wl_add", &dash.wl_add, "example.org: a site where the blocker stays off")
		ui.spacer(ui.px(em * 0.5))
		host := strings.to_lower(strings.trim_space(ui.field_string(&dash.wl_add)), context.temp_allocator)
		host = strings.trim_prefix(strings.trim_prefix(host, "https://"), "http://")
		if i := strings.index_any(host, "/?#"); i >= 0 { host = host[:i] }
		if ui.disabled(host == "") {
			if tool_button("Add", "wl_btn", em * 5) || (res.committed && host != "") {
				blocker.site_toggle(b, strings.clone(host, context.temp_allocator), .Off, true)
				ui.field_clear(&dash.wl_add)
			}
		}
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label("A site here is not filtered at all (subdomains too).###wl_note") }
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
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				cell(h, fmt.tprintf("wlh_%d", i), em * 24)
				flags := make([dynamic]string, context.temp_allocator)
				for fl in blocker.Site_Flag { if fl in f { append(&flags, blocker.SITE_FLAG_NAMES[fl]) } }
				cell(.Off in f ? "filtering off" : strings.join(flags[:], ", ", context.temp_allocator), fmt.tprintf("wlf_%d", i), em * 40, true)
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.spacer(ui.fill())
				if remove_cross(fmt.tprintf("###wlx_%d", i), true, em, "Remove this site").clicked {
					blocker.site_set_flags(b, h, {})
					blocker.conf_save(b)
					break
				}
			}
		}
		if !any {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("No site. Turn the blocker off for a site with the power button of the panel.###wl_none") } }
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

OUTCOME_NAMES := [blocker.Outcome]string{
	.Allowed = "allowed", .Blocked = "blocked", .Redirected = "redirected", .Rewritten = "rewritten", .Excepted = "excepted",
	.Dyn_Blocked = "blocked (rule)", .Dyn_Allowed = "allowed (rule)", .Site_Off = "site off", .Policy = "blocked (policy)", .Header = "blocked (header)",
}

@(private = "file")
outcome_color :: proc(o: blocker.Outcome) -> (c: ui.Color, tone: bool) {
	#partial switch o {
	case .Blocked, .Dyn_Blocked, .Policy, .Header: return BLOCK_RED, true
	case .Redirected, .Rewritten: return SHIELD_AMBER, true
	case .Excepted, .Dyn_Allowed: return SHIELD_GREEN, true
	}
	return {}, false
}

@(private = "file")
log_model :: proc(b: ^blocker.Blocker, query: string) {
	j := &b.journal
	if j.version == dash.log_version && query == dash.log_query && !dash.log_pause { /* same rows */ }
	if dash.log_pause && query == dash.log_query { return }
	if j.version == dash.log_version && query == dash.log_query { return }
	dash.log_version = j.version
	delete(dash.log_query); dash.log_query = strings.clone(query)
	clear(&dash.log_rows); clear(&dash.log_ids); clear(&dash.log_labels); clear(&dash.log_sel)
	q := strings.to_lower(query, context.temp_allocator)
	n := blocker.journal_len(j)
	for k := n - 1; k >= 0; k -= 1 {   // newest first
		e := blocker.journal_get(j, k)
		if dash.log_outcome > 0 {
			o := blocker.Outcome(dash.log_outcome - 1)
			if e.outcome != o { continue }
		}
		if dash.log_type > 0 && e.type != adblock.Resource(dash.log_type - 1) { continue }
		if q != "" && !strings.contains(strings.to_lower(e.url, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.rule, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.doc, context.temp_allocator), q) { continue }
		append(&dash.log_rows, k)
		append(&dash.log_ids, u64(j.total) - u64(n - k))
		append(&dash.log_labels, e.url)
		append(&dash.log_sel, true)
		if len(dash.log_rows) >= 20000 { break }
	}
}

@(private = "file")
tab_journal :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	b := &bl.b
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 22), height = ui.px(ui.dense(em * 1.9))})
		ui.line_edit("###lg_search", &dash.log_search, "Search URL, rule or document")
		ui.spacer(ui.px(em * 0.5))
		outs := make([]string, len(OUTCOME_NAMES) + 1, context.temp_allocator)
		outs[0] = "all outcomes"
		for n, i in OUTCOME_NAMES { outs[int(i) + 1] = n }
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 1.9))})
		if ui.dropdown("###lg_outcome", outs, &dash.log_outcome) { dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.4))
		types := make([]string, 22, context.temp_allocator)
		types[0] = "all types"
		k := 1
		for r in adblock.Resource { if r <= .Webrtc { types[k] = adblock.resource_name(r); k += 1 } }
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 1.9))})
		if ui.dropdown("###lg_type", types[:k], &dash.log_type) { dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.5))
		if tool_button(dash.log_pause ? "Resume" : "Pause", "lg_pause", em * 7) { dash.log_pause = !dash.log_pause; dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.4))
		if tool_button("Clear", "lg_clear", em * 6) { blocker.journal_clear(&b.journal); dash.log_version = 0 }
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(fmt.tprintf("%d shown of %d###lg_count", len(dash.log_rows), blocker.journal_len(&b.journal))) }
	}
	log_model(b, strings.trim_space(ui.field_string(&dash.log_search)))
	// header
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		if ui.tags("weak") {
			cell("time", "lgh_t", em * 6.5); cell("type", "lgh_y", em * 6.5); cell("outcome", "lgh_o", em * 8.5); cell("URL", "lgh_u", em * 38); cell("document", "lgh_d", em * 13); cell("rule", "lgh_r", em * 20)
		}
	}
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill()})
	if rows, ok := ui.vlist("###lg_list", &dash.log_list, dash.log_ids[:], dash.log_labels[:], dash.log_sel[:]); ok {
		for i in rows.first ..< rows.last {
			e := blocker.journal_get(&b.journal, dash.log_rows[i])
			if e == nil { continue }
			ui.next({height = ui.px(ui.dense(em * 1.75))})
			row := ui.list_row(&dash.log_list.list, i, dash.log_labels[i])
			if ui.parent(row.box) {
				ui.spacer(ui.px(em * 0.9))
				lt := local_time(e.time)
				cell(fmt.tprintf("%02d:%02d:%02d", lt.hour, lt.minute, lt.second), fmt.tprintf("lgt_%d", i), em * 6.5, true)
				cell(adblock.resource_name(e.type), fmt.tprintf("lgy_%d", i), em * 6.5, true)
				col, tone := outcome_color(e.outcome)
				ui.next({width = ui.px(em * 8.5), height = ui.pct(1), font_size = em * 0.92, fg = tone ? col : ui.color("text")})
				ui.label(fmt.aprintf("%s###lgo_%d", OUTCOME_NAMES[e.outcome], i, allocator = ui.frame_allocator()))
				cell(e.url, fmt.tprintf("lgu_%d", i), em * 38)
				cell(address_host(e.doc), fmt.tprintf("lgd_%d", i), em * 13, true)
				cell(e.rule, fmt.tprintf("lgr_%d", i), em * 20, true)
			}
			if row.right_clicked {
				dash.log_menu = dash.log_rows[i]
				ui.ctx_menu_open(ui.key_from_string(0, "###lg_menu"), ui.mouse_pos())
			}
		}
		if len(dash.log_rows) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("Nothing yet: load a page. The log records while this tab is shown.###lg_none") } }
		}
	}
	journal_menu(app, t)
}

@(private = "file")
journal_menu :: proc(app: ^App, t: ^Tab) {
	b := &bl.b
	if !ui.ctx_menu(ui.key_from_string(0, "###lg_menu")) { return }
	e := blocker.journal_get(&b.journal, dash.log_menu)
	if e == nil { return }
	host := adblock.url_host(e.url)
	if ui.menu_item("Copy the URL").clicked { clip_set(e.url) }
	if ui.menu_item("Copy the rule", enabled = e.rule != "").clicked { clip_set(e.rule) }
	ui.menu_separator()
	if ui.menu_item(fmt.tprintf("Create an exception for %s", host), enabled = host != "").clicked {
		line := fmt.tprintf("@@||%s^%s", host, e.type == .Document ? "$document" : "")
		dash_add_filter(app, line)
	}
	if ui.menu_item("Create an exception for this URL only", enabled = e.url != "").clicked { dash_add_filter(app, fmt.tprintf("@@%s", e.url)) }
	if ui.menu_item(fmt.tprintf("Block %s on every site", host), enabled = host != "").clicked { dash_add_filter(app, fmt.tprintf("||%s^", host)) }
	if ui.menu_item(fmt.tprintf("Allow %s (dynamic rule, every site)", host), enabled = host != "").clicked {
		blocker.dyn_set(&b.dyn, "*", host, .All, .Allow)
		blocker_rules_saved()
		ui.toast(.Good, "Rule added: * %s * allow", host)
	}
	ui.menu_separator()
	if ui.menu_item("Open the document", enabled = e.doc != "").clicked { tab_open(app, strings.clone(e.doc, context.temp_allocator)) }
}

dash_add_filter :: proc(app: ^App, line: string) {
	b := &bl.b
	sb := strings.builder_make()
	strings.write_string(&sb, b.conf.my_filters)
	if b.conf.my_filters != "" && !strings.has_suffix(b.conf.my_filters, "\n") { strings.write_byte(&sb, '\n') }
	strings.write_string(&sb, line)
	strings.write_byte(&sb, '\n')
	delete(b.conf.my_filters)
	b.conf.my_filters = strings.to_string(sb)
	dash.my_loaded = false
	blocker.conf_save(b)
	blocker.rebuild(b)
	ui.toast(.Good, "Filter added to My filters: %s", line)
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
	b := &bl.b
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###st_scroll") {
		section("Since", "since")
		stat_line("Counting since", fmt_date(b.totals.since), "since")
		stat_line("Pages loaded", fmt.tprintf("%d", b.totals.pages), "pages")
		stat_line("Requests blocked", fmt.tprintf("%d", b.totals.blocked), "blocked")
		stat_line("  of which answered with a stand-in", fmt.tprintf("%d", b.totals.redirected), "red")
		stat_line("Requests allowed", fmt.tprintf("%d", b.totals.allowed), "allowed")
		stat_line("URLs cleaned of tracking parameters", fmt.tprintf("%d", b.totals.rewritten), "rewritten")
		total := b.totals.blocked + b.totals.allowed
		if total > 0 { stat_line("Share of requests blocked", fmt.tprintf("%.1f %%", 100 * f64(b.totals.blocked) / f64(total)), "share") }
		section("Filter engine", "engine")
		if b.engine != nil {
			stat_line("Filters in force", fmt.tprintf("%d (network %d, cosmetic %d)", b.engine.rules, adblock.engine_filter_count(b.engine.engine), adblock.engine_cosmetic_count(b.engine.engine)), "rules")
			stat_line("Index size", fmt_bytes(adblock.engine_size(b.engine.engine)), "size")
			stat_line("Built in", fmt.tprintf("%.0f ms (on a background thread; start-up loads the cache)", b.upd.last_compile_ms), "built")
			for s in b.engine.sources {
				stat_line(fmt.tprintf("  %s", s.name), fmt.tprintf("%d network · %d cosmetic · %d lines not understood", s.net, s.cosmetic, s.invalid), fmt.tprintf("src%d", s.id))
			}
		}
	}
}

////////////////////////////////
// About

@(private = "file")
tab_about :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###ab_scroll") {
		section("How it works", "how")
		lines := []string{
			"Every request of a page is judged before it leaves the machine, in a few microseconds: the URL is cut into tokens, each filter",
			"is filed under its rarest token, and only the few filters that share a token with the URL are tried. The lists are compiled once,",
			"on a background thread, into a compact index kept in the profile: start-up loads it in a few milliseconds.",
			"",
			"Blocked requests cost nothing: no DNS lookup, no connection, no script to download or run. Element hiding is in force at the first",
			"paint (no flash of ads); scriptlets run before the page's own scripts. Nothing is ever sent anywhere.",
		}
		for l, i in lines {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
			if ui.row(.Center) { ui.spacer(ui.px(em * 0.9)); ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(fmt.aprintf("%s###ab1_%d", l, i, allocator = ui.frame_allocator())) }
		}
		section("Filter syntax understood", "syntax")
		syn := []string{
			"||example.com^  |http://  *  ^  /regex/        network filters (anchors, wildcards, separators, regular expressions)",
			"$third-party  $script,image,stylesheet,xmlhttprequest,subdocument,media,font,websocket,ping,other,document,popup",
			"$domain=a.com|~b.com  $to=  $denyallow=  $method=  $important  $match-case  $badfilter  $all",
			"$redirect=  $redirect-rule=  $removeparam=  $csp=  $header=  $generichide  $elemhide  $specifichide",
			"@@...                                           exceptions",
			"example.com##.banner   ~example.com##.ad   google.*##.x   ##.generic        element hiding, entities",
			":has()  :has-text()  :contains()  :matches-css()  :matches-attr()  :matches-path()  :min-text-length()  :not()  :upward()",
			":nth-ancestor()  :remove()  :style()  :-abp-contains()  :-abp-has()          procedural selectors",
			"example.com##+js(set-constant, name, value)       scriptlets: set-constant, json-prune, abort-on-property-read/write,",
			"   abort-current-script, no-setTimeout-if, no-setInterval-if, no-fetch-if, no-xhr-if, addEventListener-defuser, window.open-defuser,",
			"   remove-attr, remove-class, click-element, nano-setInterval-booster, json-prune-fetch-response, and more",
			"!#if  !#else  !#endif  !#include                 conditional blocks and includes of the lists",
			"0.0.0.0 host                                     hosts files",
		}
		for l, i in syn {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
			if ui.row(.Center) { ui.spacer(ui.px(em * 0.9)); ui.next({width = ui.fill(), height = ui.pct(1), font_size = em * 0.88}); ui.label(fmt.aprintf("%s###ab2_%d", l, i, allocator = ui.frame_allocator())) }
		}
		section("Panel and shortcuts", "keys")
		keys := []string{
			"The shield at the end of the address bar opens the panel: power button for the site, switches, matrix, element picker, log.",
			"Matrix: a click on a cell blocks, allows, then resets that host and kind for this site; Shift+click does the same for every site.",
			"The page's context menu: Block element…, Block this resource.   Ctrl+Shift+K: element picker.   Command palette: Blocker…",
		}
		for l, i in keys {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
			if ui.row(.Center) { ui.spacer(ui.px(em * 0.9)); ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label(fmt.aprintf("%s###ab3_%d", l, i, allocator = ui.frame_allocator())) }
		}
	}
}

////////////////////////////////
// Files

dash_export :: proc(app: ^App) { file_dialog(app, true, "wren-blocker.txt", 0) }
dash_import :: proc(app: ^App) { file_dialog(app, false, "", 0) }
dash_export_filters :: proc(app: ^App) { file_dialog(app, true, "my-filters.txt", 1) }
dash_import_filters :: proc(app: ^App) { file_dialog(app, false, "", 1) }

_ :: os
_ :: time

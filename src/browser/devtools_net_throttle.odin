package browser

// The Network tab's speed profiles: what a tab's requests, sockets and event streams are held to while the panel is open
// (net/throttle.odin does the holding: a download and an upload rate shared by the tab's traffic, a latency per request, a
// loss rate). The profiles are Fast 3G, Slow 3G, a flaky Wi-Fi, Offline (nothing goes out) and the user's own, made in the
// editor under the toolbar (browser.devtools.network.profiles: "id|name|down kbit/s|up kbit/s|latency ms|loss %;..."). The
// profile of a tab is its own (the toolbar's menu sets it, and the preference is what a tab that chose nothing starts from).

import "core:fmt"
import "core:strconv"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:net"

Net_Profile :: struct {
	id, name:   string,
	down_kbps:  f64,     // kbit/s; 0 = no limit
	up_kbps:    f64,
	latency_ms: f32,
	loss_pct:   f32,     // of the packets
	offline:    bool,
	builtin:    bool,
}

NET_BUILTIN := [?]Net_Profile{
	{id = "none", name = "No throttling", builtin = true},
	{id = "fast_3g", name = "Fast 3G", down_kbps = 1600, up_kbps = 750, latency_ms = 150, builtin = true},
	{id = "slow_3g", name = "Slow 3G", down_kbps = 400, up_kbps = 400, latency_ms = 400, builtin = true},
	{id = "flaky", name = "Flaky Wi-Fi", down_kbps = 5000, up_kbps = 2000, latency_ms = 60, loss_pct = 3, builtin = true},
	{id = "offline", name = "Offline", offline = true, builtin = true},
}

@(private = "file") net_custom: [dynamic]Net_Profile   // owned strings

net_profiles_destroy :: proc() {
	for p in net_custom { delete(p.id); delete(p.name) }
	delete(net_custom)
	net_custom = nil
}

// "id|name|down|up|latency|loss;..." into the custom profiles.
net_profiles_load :: proc(text: string) {
	for p in net_custom { delete(p.id); delete(p.name) }
	clear(&net_custom)
	for item in strings.split(text, ";", context.temp_allocator) {
		f := strings.split(item, "|", context.temp_allocator)
		if len(f) < 6 || strings.trim_space(f[0]) == "" { continue }
		num :: proc(s: string) -> f64 { v, _ := strconv.parse_f64(strings.trim_space(s)); return max(v, 0) }
		append(&net_custom, Net_Profile{id = strings.clone(strings.trim_space(f[0])), name = strings.clone(strings.trim_space(f[1])), down_kbps = num(f[2]), up_kbps = num(f[3]),
			latency_ms = f32(num(f[4])), loss_pct = f32(min(num(f[5]), 100))})
	}
}

net_profiles_text :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for p, i in net_custom { fmt.sbprintf(&b, "%s%s|%s|%g|%g|%g|%g", i > 0 ? ";" : "", p.id, strings.replace_all(p.name, "|", " ", context.temp_allocator), p.down_kbps, p.up_kbps, p.latency_ms, p.loss_pct) }
	return strings.to_string(b)
}

net_profile_find :: proc(id: string) -> (Net_Profile, bool) {
	for p in NET_BUILTIN { if p.id == id { return p, true } }
	for p in net_custom { if p.id == id { return p, true } }
	return NET_BUILTIN[0], false
}

// The profile a tab is held to: its own choice, else the preference's.
net_profile_of :: proc(t: ^Tab) -> Net_Profile {
	id := t != nil && t.net.profile != "" ? t.net.profile : net_prefs.profile
	p, _ := net_profile_find(id)
	return p
}

net_profile_active :: proc(p: Net_Profile) -> bool { return p.offline || p.down_kbps > 0 || p.up_kbps > 0 || p.latency_ms > 0 || p.loss_pct > 0 }

// The tab and the preference take the profile (the preference is what the tabs that did not choose follow).
net_profile_set :: proc(app: ^App, t: ^Tab, id: string) {
	if t != nil { delete(t.net.profile); t.net.profile = strings.clone(id) }
	dev_set_pref(app, "browser.devtools.network.throttle", id)
	app.frames_requested = max(app.frames_requested, 2)
}

net_profile_text :: proc(p: Net_Profile) -> string {
	if p.offline { return "Offline: no request leaves" }
	if !net_profile_active(p) { return "No throttling" }
	return fmt.tprintf("%s: %s down, %s up, %g ms latency%s", p.name, rate_text(p.down_kbps), rate_text(p.up_kbps), p.latency_ms, p.loss_pct > 0 ? fmt.tprintf(", %g %% packet loss", p.loss_pct) : "")
}

@(private = "file")
rate_text :: proc(kbps: f64) -> string {
	if kbps <= 0 { return "unlimited" }
	if kbps >= 1000 { return fmt.tprintf("%g Mbit/s", kbps / 1000) }
	return fmt.tprintf("%g kbit/s", kbps)
}

// fetch.Observer.throttle: the link the requests (and sockets) of `scope` go through; nil when their tab is not throttled
// (or the panel is closed: the speed is a tool of the panel, as in the other browsers).
net_link_for :: proc(user: rawptr, scope: ^base.Scope) -> ^net.Throttle_Link {
	app := (^App)(user)
	if !dev.visible { return nil }
	t, _ := tab_of_scope(app, scope)
	if t == nil { return nil }
	p := net_profile_of(t)
	if p.offline || !net_profile_active(p) { return nil }
	l := &t.net.link
	if t.net.link_id != p.id || l.latency_ms != p.latency_ms {
		delete(t.net.link_id)
		t.net.link_id = strings.clone(p.id)
		l^ = net.Throttle_Link{down_bps = net.throttle_kbps(p.down_kbps), up_bps = net.throttle_kbps(p.up_kbps), latency_ms = p.latency_ms, loss = p.loss_pct / 100}
	}
	return l
}

// fetch.Observer.block: whether the request for `url` is stopped (a pattern the user blocked, or this tab is offline).
net_blocked :: proc(user: rawptr, scope: ^base.Scope, url: string) -> bool {
	app := (^App)(user)
	if dev.visible {
		if t, _ := tab_of_scope(app, scope); t != nil && net_profile_of(t).offline { return true }
	}
	for p in dev.net.blocked { if net_glob(p, url) { return true } }
	return false
}

////////////////////////////////
// The toolbar's menu and the editor of a custom profile

Net_Prof_Edit :: struct {
	open:     bool,
	orig_id:  string,    // owned: the profile being edited ("" = a new one)
	name, down, up, latency, loss: ui.Text_Field,
	focus:    bool,
	bad:      string,
}

net_prof_edit_destroy :: proc(e: ^Net_Prof_Edit) {
	delete(e.orig_id)
	ui.field_destroy(&e.name); ui.field_destroy(&e.down); ui.field_destroy(&e.up); ui.field_destroy(&e.latency); ui.field_destroy(&e.loss)
	e^ = {}
}

net_prof_edit_begin :: proc(e: ^Net_Prof_Edit, p: Net_Profile, new_one: bool) {
	delete(e.orig_id)
	e.orig_id = new_one ? strings.clone("") : strings.clone(p.id)
	ui.field_set(&e.name, new_one ? "My profile" : p.name)
	ui.field_set(&e.down, fmt.tprintf("%g", new_one ? 1000 : p.down_kbps))
	ui.field_set(&e.up, fmt.tprintf("%g", new_one ? 500 : p.up_kbps))
	ui.field_set(&e.latency, fmt.tprintf("%g", new_one ? 100 : p.latency_ms))
	ui.field_set(&e.loss, fmt.tprintf("%g", new_one ? 0 : p.loss_pct))
	e.open, e.focus, e.bad = true, true, ""
}

@(private = "file")
parse_field :: proc(f: ^ui.Text_Field) -> (v: f64, ok: bool) {
	s := strings.trim_space(ui.field_string(f))
	if s == "" { return 0, true }
	return strconv.parse_f64(s)
}

net_prof_edit_save :: proc(app: ^App, t: ^Tab, e: ^Net_Prof_Edit) -> bool {
	name := strings.trim_space(ui.field_string(&e.name))
	down, ok1 := parse_field(&e.down)
	up, ok2 := parse_field(&e.up)
	lat, ok3 := parse_field(&e.latency)
	loss, ok4 := parse_field(&e.loss)
	switch {
	case name == "": e.bad = "Give the profile a name."
	case !(ok1 && ok2 && ok3 && ok4) || down < 0 || up < 0 || lat < 0 || loss < 0: e.bad = "The rates, the latency and the loss are numbers (0 = none)."
	case loss > 100: e.bad = "The loss is a percentage."
	case:
		e.bad = ""
		id := e.orig_id
		if id == "" {
			// a new id from the name that no profile has
			sb := strings.builder_make(context.temp_allocator)
			strings.write_string(&sb, "c_")
			for r in strings.to_lower(name, context.temp_allocator) { strings.write_rune(&sb, (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') ? r : '_') }
			base_id := strings.to_string(sb)
			id = base_id
			for n := 2; ; n += 1 {
				if _, found := net_profile_find(id); !found { break }
				id = fmt.tprintf("%s_%d", base_id, n)
			}
		}
		np := Net_Profile{id = strings.clone(id), name = strings.clone(name), down_kbps = down, up_kbps = up, latency_ms = f32(lat), loss_pct = f32(loss)}
		replaced := false
		for &p in net_custom { if p.id == id { delete(p.id); delete(p.name); p, replaced = np, true; break } }
		if !replaced { append(&net_custom, np) }
		dev_set_pref(app, "browser.devtools.network.profiles", net_profiles_text())
		net_profile_set(app, t, id)
		if t != nil { delete(t.net.link_id); t.net.link_id = "" }   // the link is made again from the edited numbers
		e.open = false
		return true
	}
	return false
}

net_profile_delete :: proc(app: ^App, t: ^Tab, id: string) {
	for p, i in net_custom {
		if p.id != id { continue }
		delete(p.id); delete(p.name)
		ordered_remove(&net_custom, i)
		break
	}
	dev_set_pref(app, "browser.devtools.network.profiles", net_profiles_text())
	if t != nil && t.net.profile == id { net_profile_set(app, t, "none") }
}

// The items of the speed menu.
net_speed_menu :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	cur := net_profile_of(t)
	ui.menu_heading("Network speed")
	for p in NET_BUILTIN {
		if ui.menu_item(fmt.tprintf("%s###dt_th_%s", p.name, p.id), checked = cur.id == p.id).clicked { net_profile_set(app, t, p.id) }
	}
	if len(net_custom) > 0 {
		ui.menu_separator()
		ui.menu_heading("Custom")
		for p in net_custom {
			if ui.menu_item(fmt.tprintf("%s###dt_th_%s", p.name, p.id), checked = cur.id == p.id).clicked { net_profile_set(app, t, p.id) }
		}
	}
	ui.menu_separator()
	if ui.menu_item("Add a custom profile\u2026###dt_th_add").clicked { net_prof_edit_begin(&v.prof, NET_BUILTIN[1], true) }
	if ui.menu_item(cur.builtin ? "Edit the profile\u2026###dt_th_edit" : fmt.tprintf("Edit %s\u2026###dt_th_edit", cur.name), enabled = !cur.builtin).clicked { net_prof_edit_begin(&v.prof, cur, false) }
	if ui.menu_item(cur.builtin ? "Delete the profile###dt_th_del" : fmt.tprintf("Delete %s###dt_th_del", cur.name), enabled = !cur.builtin).clicked { net_profile_delete(app, t, cur.id) }
}

@(private = "file")
field_row :: proc(label: string, id: string, f: ^ui.Text_Field, w: f32, hint: string) -> ui.Edit_Result {
	lw := dt_w(dtm.ui_font, dtm.fs, label) + dt_px(8)
	ui.next({width = ui.px(lw), height = ui.pct(1)})
	ui.custom(fmt.tprintf("###%s_l", id), proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		s := (^string)(user)^
		dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(4), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, s)
	}, new_clone(dt_frame_str(label), ui.frame_allocator()))
	ui.next({width = ui.px(w), height = ui.px(dtm.btn - dt_px(4)), radius = dtm.radius, font = dtm.mono, font_size = dtm.mono_fs, text_pad = dt_px(4)})
	return ui.line_edit(fmt.tprintf("###%s", id), f, hint)
}

// The editor: a bar under the toolbar with the five numbers of a profile, Save and Cancel.
net_prof_editor :: proc(app: ^App, t: ^Tab, v: ^Dev_Network) {
	e := &v.prof
	if !e.open { return }
	if dt_bar("###dt_pe_bar", dtm.bar) {
		dt_gap(5)
		r0 := field_row("Name", "dt_pe_name", &e.name, dt_px(130), "name")
		if e.focus && r0.box != nil { ui.set_focus(r0.box.key); e.focus = false }
		field_row("Download kbit/s", "dt_pe_down", &e.down, dt_px(66), "0")
		field_row("Upload kbit/s", "dt_pe_up", &e.up, dt_px(66), "0")
		field_row("Latency ms", "dt_pe_lat", &e.latency, dt_px(56), "0")
		field_row("Loss %", "dt_pe_loss", &e.loss, dt_px(46), "0")
		dt_gap(6)
		if dt_btn("###dt_pe_save", .Check, "Save", tooltip = "Save the profile and use it on this tab", accent = true).clicked { net_prof_edit_save(app, t, e) }
		if dt_btn("###dt_pe_cancel", .Close, tooltip = "Cancel", shortcut = "Esc").clicked { e.open = false }
		if e.bad != "" {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.custom("###dt_pe_bad", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.bad, (^string)(user)^, b.rect.max.x - b.rect.min.x - dt_px(10))
			}, new_clone(dt_frame_str(e.bad), ui.frame_allocator()))
		}
	}
	if ui.key_press(.Escape) && ui.focus_key() != 0 { e.open = false }
}

package browser

// The Setup dialog (the logic is in setup.odin): a modal panel over the page.
//
//   ┌ <App> Setup ─────────────────────────────────────────────────┐ [x]
//   │ ┌──────────────────────────────────────────────────────────┐ │
//   │ │ Manage this installation                 [Running installed] │
//   │ │ Current version: v0.3.0 -> installed version: v0.3.0     │ │
//   │ └──────────────────────────────────────────────────────────┘ │
//   │ Install location                                             │
//   │ [ C:\Users\you\AppData\Local\Programs\Wren                 ] │
//   │ ▌Options                                                     │
//   │ [x] Add to Start menu          [ ] Create desktop shortcut   │
//   │ [ ] Add Wren to PATH           [ ] Check for updates daily   │
//   │ [x] Register as a web browser (appears in Default apps) [Open default apps]
//   │ ┌ You are running from the installed location. ────────────┐ │
//   │ [Uninstall]                          [Modify] [Close]      ◢ │
//   └──────────────────────────────────────────────────────────────┘
//
// The toolkit's modal gives the dim backdrop, the Escape key, and the Tab key that stays in the dialog; its panel has
// rounded corners the toolkit fixes, so the dialog draws a square frame of its own over it (colors are the theme's:
// the accent is the one of the channel). The corner grip changes the width.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:desktop"

@(private = "file")
Grip_Draw :: struct { color: draw.Color }

@(private = "file")
grip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Grip_Draw)(user)
	r := b.rect
	s := max(math.round(ui.scale()), 1)
	// three diagonal strokes of dots, bottom right
	for i in 0 ..< 3 {
		for j in 0 ..= i {
			x := r.max.x - 2 * s - f32(j) * 3 * s
			y := r.max.y - 2 * s - f32(i - j) * 3 * s
			draw.rect(dc, {{x - s, y - s}, {x, y}}, d.color)
		}
	}
}

@(private = "file")
header_texts :: proc(kind: Setup_Kind) -> (title, badge, tone: string, solid: bool) {
	switch kind {
	case .Loading:           return "Reading the installation…", "…", "weak", false
	case .Not_Installed:     return fmt.tprintf("Install %s", desktop_identity().name), "Not installed", "weak", false
	case .Running_Installed: return "Manage this installation", "Running installed", "accent", true
	case .Other_Copy:        return "Another copy is installed", "Running another copy", "warn", false
	case .Older:             return "A newer copy is installed", "Older than installed", "warn", false
	case .Repair:            return "Repair this installation", "Repair", "bad", false
	}
	return "", "", "weak", false
}

// "v0.3.0 -> installed version: v0.3.0", the line under the title.
@(private = "file")
versions_line :: proc(f: ^Setup_Facts, known: bool) -> string {
	cur := fmt.tprintf("Current version: v%s", APP_VERSION)
	switch {
	case !known: return cur
	case !f.inst.exe_present: return fmt.tprintf("%s \u2192 not installed", cur)
	case f.inst.version == "": return fmt.tprintf("%s \u2192 installed version: unknown", cur)
	}
	return fmt.tprintf("%s \u2192 installed version: v%s", cur, f.inst.version)
}

// The line in the bordered box under the options: what is the case, or the outcome of the last action.
@(private = "file")
status_text :: proc(f: ^Setup_Facts) -> (text, tone: string) {
	switch {
	case stp.busy > 0:
		return "Working\u2026", "weak"
	case stp.confirm_uninstall:
		return fmt.tprintf("Click Confirm uninstall to remove %s: its shortcuts, its PATH entry, its entry in Settings > Apps and the files in %s. Your profile (bookmarks, history, settings) stays.", APP_NAME, f.inst.exe_present ? f.inst.dir : f.installed_dir), "warn"
	case stp.path_problem != "" && stp.path_ready:
		return stp.path_problem, "bad"
	case stp.note != "":
		return stp.note, stp.note_tone
	case !stp.known:
		return "Reading what is installed\u2026", "weak"
	}
	switch f.kind {
	case .Loading:
	case .Not_Installed:
		if f.other_target != "" { return fmt.tprintf("%s is running from %s. Its shortcuts start %s: installing makes them start the installed copy.", APP_NAME, f.running_exe, f.other_target), "weak" }
		return fmt.tprintf("%s is running from %s, without being installed.", APP_NAME, f.running_exe), "weak"
	case .Running_Installed:
		return "You are running from the installed location.", "weak"
	case .Other_Copy:
		return fmt.tprintf("You are running %s. The installed copy is %s: replacing it puts this version there.", f.running_exe, f.inst.exe), "weak"
	case .Older:
		return fmt.tprintf("This copy (v%s) is older than the installed one (v%s). Replacing it goes back to the older version.", APP_VERSION, f.inst.version), "warn"
	case .Repair:
		switch {
		case !f.inst.manifest:        return "The record of the installed files is missing. Repair writes it again.", "warn"
		case f.inst.missing > 0:      return fmt.tprintf("%d installed file%s missing. Repair fixes the shortcuts and keys; to put the files back, run Setup from a complete copy of %s.", f.inst.missing, f.inst.missing == 1 ? " is" : "s are", APP_NAME), "warn"
		case f.other_target != "":    return fmt.tprintf("A shortcut or key starts %s instead of the installed copy. Repair makes them start this one.", f.other_target), "warn"
		}
		if names := missing_parts(f); names != "" { return fmt.tprintf("Missing: %s. Repair puts it back.", names), "warn" }
		return "A shortcut or a key is missing or incomplete. Repair puts it back.", "warn"
	}
	return "", "weak"
}

// The parts the options want that are not (all) there, in words: "Start menu entry, PATH entry".
@(private = "file")
missing_parts :: proc(f: ^Setup_Facts) -> string {
	names := [desktop.Part]string{.Launcher = "Start menu entry", .Registration = "browser registration", .Icons = "icons", .Desktop_Shortcut = "desktop shortcut", .Path = "PATH entry"}
	if desktop.menu_name() != "Start menu" { names[.Launcher] = "application menu entry" }
	out := make([dynamic]string, context.temp_allocator)
	for p in desktop.Part {
		if p in f.integ.wanted && (!f.integ.parts[p].present || f.integ.parts[p].partial) { append(&out, names[p]) }
	}
	return strings.join(out[:], ", ", context.temp_allocator)
}

@(private = "file")
primary_label :: proc(f: ^Setup_Facts, known: bool) -> string {
	if !known { return "Install" }
	switch f.kind {
	case .Loading:           return "Install"
	case .Not_Installed:     return "Install"
	case .Running_Installed: return setup_moving() ? "Move installation" : "Modify"
	case .Other_Copy, .Older: return "Replace installed copy"
	case .Repair:            return "Repair"
	}
	return "Install"
}

@(private = "file")
secondary_label :: proc(kind: Setup_Kind) -> string {
	switch kind {
	case .Running_Installed, .Repair: return "Close"
	case .Loading, .Not_Installed, .Other_Copy, .Older: return "Use standalone"
	}
	return "Close"
}

// One option: a bordered tile with a check box and its label (the whole tile is the check box's row).
@(private = "file")
option_tile :: proc(opt: Setup_Opt, label: string, w: ui.Size, enabled: bool, extra_button := "", extra_id := "") -> bool {
	em := ui.font_size()
	clicked_extra := false
	ui.next({width = w, height = ui.px(ui.dense(em * 2.3))})
	if ui.tags("card") {
		if ui.row(.Center, {.Draw_Background, .Draw_Border}, fmt.aprintf("###setup_tile_%v", opt, allocator = ui.frame_allocator())) {
			if ui.disabled(!enabled) {
				checked := stp.opts[opt]
				ui.next({width = ui.fill(), height = ui.pct(1)})
				if ui.checkbox(fmt.aprintf("###setup_opt_%v", opt, allocator = ui.frame_allocator()), label, &checked).clicked {
					stp.opts[opt] = checked
					stp.confirm_uninstall = false
				}
			}
			if extra_button != "" {
				ui.next({width = ui.text_size(em * 1.4), height = ui.px(ui.dense(em * 1.9))})
				if ui.tags("ghost_button") { if ui.button(fmt.aprintf("%s###%s", extra_button, extra_id, allocator = ui.frame_allocator())).clicked { clicked_extra = true } }
				ui.spacer(ui.px(em * 0.5))
			}
		}
	}
	return clicked_extra
}

// Builds the dialog over everything else. Nothing (and no frame) while it is closed.
setup_build :: proc(app: ^App) {
	if !stp.open { return }
	setup_follow_disk(app)
	setup_sync_inputs(app)
	setup_validate()
	em := ui.font_size()
	win_w, win_h := f32(app.win.size.x), f32(app.win.size.y)
	pad := math.round(em * 1.1)
	max_w := max(win_w - em * 2, 22 * em)
	if stp.width_em == 0 { stp.width_em = 46 }
	width := clamp(math.round(stp.width_em * em), min(36 * em, max_w), max_w)
	inner := width - 2 * pad
	// placed higher than the middle (a third of the room left over is above it); at the top when it takes the whole window
	top := stp.fit_h > 0 ? max((win_h - stp.fit_h) * 0.35, em * 0.6) : win_h * 0.08
	open := true
	if ui.modal("setup", width, &open, top / win_h) {
		if ui.style({radius = 0}) { setup_frame(app, width, inner, pad, win_h) }
	}
	if !open && stp.busy == 0 { setup_dismiss(app) }   // Escape, a click outside (not while it works)
}

@(private = "file")
setup_frame :: proc(app: ^App, width, inner, pad, win_h: f32) {
	// the toolkit's panel (the parent here) has rounded corners it fixes itself: it stays as the box that takes clicks and
	// holds the focus, but does not paint; the square frame below does (this frame's flags: the panel is built again next frame)
	if panel := ui.parent_box(); panel != nil { panel.flags -= {.Draw_Background, .Draw_Border, .Draw_Shadow} }
	ui.next({width = ui.px(width), height = ui.children_sum(), axis = .Y})
	frame := ui.build_box({.Draw_Background, .Draw_Border, .Draw_Shadow}, "###setup_frame")
	stp.fit_h = frame.rect.max.y - frame.rect.min.y   // (last frame's: the window places the next one)
	if ui.parent(frame) { setup_body(app, width, inner, pad, win_h) }
}

@(private = "file")
setup_body :: proc(app: ^App, width, inner, pad, win_h: f32) {
	em := ui.font_size()
	f := &stp.facts
	known := stp.known
	kind := known ? f.kind : Setup_Kind.Loading
	busy := stp.busy > 0
	title, badge, badge_tone, badge_solid := header_texts(kind)

	// the title bar: the name, and the close box
	title_h, buttons_h, grip_h := ui.dense(em * 2.2), ui.dense(em * 2.2), ui.dense(em * 0.8)
	ui.next({width = ui.px(width), height = ui.px(title_h)})
	if ui.tags("bar") {
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###setup_title") {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.aprintf("%s Setup###setup_title_text", desktop_identity().name, allocator = ui.frame_allocator()))
			box := ui.dense(em * 1.5)
			ui.next({width = ui.px(box), height = ui.px(box), text_align = .Center})
			if ui.tags("button") {
				if ui.style({font = app.icons, font_size = em * 0.8}) {
					b := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}, fmt.aprintf("%s###setup_close", ui.ICON_X, allocator = ui.frame_allocator()))
					b.cursor = .Arrow
					if ui.signal(b).clicked && !busy { setup_dismiss(app) }
				}
			}
			ui.spacer(ui.px(em * 0.35))
		}
	}

	// everything between the title bar and the buttons scrolls when the window is too short for all of it
	avail := win_h - title_h - buttons_h - grip_h - em * 1.2
	scroll_key := ui.key_from_string(ui.parent_box().key, "###setup_scroll")
	ui.next({width = ui.px(width), height = stp.mid_h > 0 ? ui.px(min(stp.mid_h, max(avail, em * 8))) : ui.children_sum()})
	if ui.scroll_y("###setup_scroll") {
		ui.spacer(ui.px(em * 0.7))
		setup_middle(app, width, inner, pad, f, known, busy, title, badge, badge_tone, badge_solid)
	}
	if b := ui.box_from_key(scroll_key); b != nil && b.view_bounds.y > 0 { stp.mid_h = b.view_bounds.y }   // (the content's height: last frame's)

	// the buttons
	ui.next({width = ui.fill(), height = ui.px(buttons_h)})
	if ui.row(.Center) {
		ui.spacer(ui.px(pad))
		can_remove := known && !busy && (f.inst.exe_present || f.inst.manifest || f.integ.state != .Absent)
		ui.next({width = ui.text_size(em * 2.2), height = ui.pct(1)})
		if ui.disabled(!can_remove) {
			if ui.tags(stp.confirm_uninstall ? "danger_button" : "button") {
				if ui.button(fmt.aprintf("%s###setup_uninstall", stp.confirm_uninstall ? "Confirm uninstall" : "Uninstall", allocator = ui.frame_allocator())).clicked {
					if stp.confirm_uninstall { setup_uninstall(app) } else { stp.confirm_uninstall = true; app.frames_requested = max(app.frames_requested, 3) }
				}
			}
		}
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.spacer(ui.fill())
		primary_ok := setup_primary_enabled()
		ui.next({width = ui.text_size(em * 2.2), height = ui.pct(1)})
		if ui.disabled(!primary_ok) {
			if ui.tags("accent_button") {
				pb := ui.button(fmt.aprintf("%s###setup_primary", primary_label(f, known), allocator = ui.frame_allocator()))
				if stp.focus_primary && pb.box != nil && known { stp.focus_primary = false; ui.set_focus(pb.box.key) }
				if pb.clicked { setup_primary(app) }
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.text_size(em * 2.2), height = ui.pct(1)})
		if ui.disabled(busy) {
			if ui.button(fmt.aprintf("%s###setup_secondary", secondary_label(kind), allocator = ui.frame_allocator())).clicked {
				if kind == .Running_Installed || kind == .Repair { setup_dismiss(app) } else { setup_use_standalone(app) }
			}
		}
		ui.spacer(ui.px(pad))
	}

	// the grip: the corner that changes the width
	ui.next({width = ui.fill(), height = ui.px(grip_h)})
	if ui.row(.Center) {
		ui.spacer(ui.fill())
		g := ui.frame_new(Grip_Draw)
		if ui.tags("weak") { g.color = ui.color("text") }
		ui.next({width = ui.px(em * 1.1), height = ui.pct(1)})
		gb := ui.custom("###setup_grip", grip_draw, g, {.Clickable})
		gb.cursor = .Resize_NWSE
		sig := ui.signal(gb)
		if sig.pressed { stp.grip_width = stp.width_em }
		if sig.dragging && em > 0 { stp.width_em = clamp(stp.grip_width + 2 * sig.drag_delta.x / em, 36, 90); app.frames_requested = max(app.frames_requested, 2) }
	}
}

// What scrolls: the case (title, versions, badge), where, the options and the sentence.
@(private = "file")
setup_middle :: proc(app: ^App, width, inner, pad: f32, f: ^Setup_Facts, known, busy: bool, title, badge, badge_tone: string, badge_solid: bool) {
	em := ui.font_size()

	ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 3.6))})
	if ui.row(.Center) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.px(inner), height = ui.pct(1)})
		if ui.tags("card") {
			if ui.row(.Center, {.Draw_Background, .Draw_Border}, "###setup_head") {
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3.0)), axis = .Y})
				if ui.column() {
					if ui.style({font_size = math.round(em * 1.2)}) {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7)), text_pad = 0})
						ui.label(fmt.aprintf("%s###setup_head_title", title, allocator = ui.frame_allocator()))
					}
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.3)), text_pad = 0})
						ui.label(fmt.aprintf("%s###setup_head_versions", versions_line(f, known), allocator = ui.frame_allocator()))
					}
				}
				setup_badge(badge, badge_tone, badge_solid)
				ui.spacer(ui.px(em * 0.9))
			}
		}
		ui.spacer(ui.px(pad))
	}
	ui.spacer(ui.px(em * 0.5))

	// where
	ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 1.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(pad))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label("Install location###setup_loc_label")
		}
		ui.spacer(ui.px(pad))
	}
	ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 2.1))})
	if ui.row(.Center) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.px(inner), height = ui.pct(1)})
		res: ui.Edit_Result
		bad := stp.path_problem != "" && stp.path_ready
		if bad { ui.push_tags("bad") }
		if ui.disabled(busy || !known) { res = ui.line_edit("###setup_path", &stp.path, "C:\\path\\to\\install\\folder") }
		if bad { ui.pop_tags() }
		if res.changed { stp.confirm_uninstall = false; setup_note("", "weak"); setup_validate() }
		if res.committed { setup_primary(app) }
		ui.spacer(ui.px(pad))
	}
	ui.spacer(ui.px(em * 0.6))

	// the options
	ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 1.8))})
	if ui.row(.Center) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.px(inner), height = ui.pct(1)})
		if ui.tags("bar") {
			if ui.row(.Center, {.Draw_Background, .Draw_Border}, "###setup_opts_bar") {
				ui.next({width = ui.px(max(math.round(4 * ui.scale()), 3)), height = ui.pct(1), bg = ui.color("accent")})
				ui.build_box({.Draw_Background}, "###setup_opts_accent")
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label("Options###setup_opts_label")
			}
		}
		ui.spacer(ui.px(pad))
	}
	ui.spacer(ui.px(em * 0.4))
	setup_options_grid(width, inner, pad, known && !busy)

	// what is the case, in words
	text, tone := status_text(f)
	ui.next({width = ui.px(width), height = ui.children_sum()})
	if ui.row(.Center) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.px(inner), height = ui.children_sum()})
		if ui.column(.Start, {.Draw_Background, .Draw_Border}, "###setup_status") {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				if ui.tags(tone) {
					ui.next({width = ui.fill(), text_pad = 0})
					ui.paragraph(fmt.aprintf("%s###setup_status_text", text, allocator = ui.frame_allocator()))
				}
				if v, link := update_available(); v != "" && !busy {
					ui.spacer(ui.px(em * 0.6))
					ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 1.9))})
					if ui.tags("ghost_button") { if ui.button(fmt.aprintf("v%s is available###setup_update", v, allocator = ui.frame_allocator())).clicked { tab_open(app, link); app.frames_requested = max(app.frames_requested, 3) } }
				}
				ui.spacer(ui.px(em * 0.9))
			}
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.px(pad))
	}
	ui.spacer(ui.px(em * 0.6))
}
@(private = "file")
setup_badge :: proc(text, tone: string, solid: bool) {
	em := ui.font_size()
	ui.next({width = ui.text_size(em * 1.6), height = ui.px(ui.dense(em * 2.1)), text_align = .Center})
	if solid {
		if ui.tags("accent_button") { ui.build_box({.Draw_Background, .Draw_Border, .Draw_Text}, fmt.aprintf("%s###setup_badge", text, allocator = ui.frame_allocator())) }
		return
	}
	if ui.tags(tone) {
		c := ui.color("text")
		fill := c
		fill.a = 0.16
		ui.next({width = ui.text_size(em * 1.6), height = ui.px(ui.dense(em * 2.1)), text_align = .Center, bg = fill, border = c, fg = c})
		ui.build_box({.Draw_Background, .Draw_Border, .Draw_Text}, fmt.aprintf("%s###setup_badge", text, allocator = ui.frame_allocator()))
	}
}

// The tiles, two to a row; the option that has a button of its own takes a row.
@(private = "file")
setup_options_grid :: proc(width, inner, pad: f32, enabled: bool) {
	em := ui.font_size()
	parts := desktop.supported_parts()
	menu := fmt.tprintf("Add to %s", desktop.menu_name())
	Tile :: struct { opt: Setup_Opt, label: string }
	tiles := make([dynamic]Tile, context.temp_allocator)
	if .Launcher in parts         { append(&tiles, Tile{.Start_Menu, menu}) }
	if .Desktop_Shortcut in parts { append(&tiles, Tile{.Desktop_Shortcut, "Create desktop shortcut"}) }
	if .Path in parts             { append(&tiles, Tile{.Add_To_Path, fmt.tprintf("Add %s to PATH", APP_NAME)}) }
	append(&tiles, Tile{.Check_Daily, "Check for updates once per day"})

	gap := math.round(em * 0.6)
	half := math.floor((inner - gap) * 0.5)
	for i := 0; i < len(tiles); i += 2 {
		ui.next({width = ui.px(width), height = ui.children_sum()})
		if ui.row(.Center) {
			ui.spacer(ui.px(pad))
			option_tile(tiles[i].opt, tiles[i].label, ui.px(i + 1 < len(tiles) ? half : inner), enabled)
			if i + 1 < len(tiles) {
				ui.spacer(ui.px(gap))
				option_tile(tiles[i + 1].opt, tiles[i + 1].label, ui.px(half), enabled)
			}
			ui.spacer(ui.px(pad))
		}
		ui.spacer(ui.px(gap))
	}
	if .Registration in parts {
		ui.next({width = ui.px(width), height = ui.children_sum()})
		if ui.row(.Center) {
			ui.spacer(ui.px(pad))
			label := fmt.tprintf("Register as a web browser (appears in %s)", desktop.default_apps_name())
			if option_tile(.Register_Browser, label, ui.px(inner), enabled, desktop_has_default_apps() ? "Open default apps" : "", "setup_defaults") { desktop_open_default_apps() }
			ui.spacer(ui.px(pad))
		}
	}
}

@(private = "file")
setup_primary_enabled :: proc() -> bool {
	if stp.busy > 0 || !stp.known || stp.path_problem != "" { return false }
	if stp.facts.kind == .Running_Installed && !setup_moving() && stp.opts == stp.baseline { return false }   // nothing to apply
	return true
}

// The main button (and Enter in the folder field).
@(private = "file")
setup_primary :: proc(app: ^App) {
	if !setup_primary_enabled() { return }
	setup_apply(app)
}
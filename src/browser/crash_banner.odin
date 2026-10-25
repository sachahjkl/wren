package browser

// The bar under the toolbar that says the last run ended abnormally (crash_recovery.odin): "Wren closed unexpectedly. Restored 3
// tabs." with [Details] (the crash report in a tab) and [Start fresh] (closes the restored tabs); or, when the start that was
// restoring ended too, "Wren crashed twice while restoring; your tabs are saved in <file>" with [Restore tabs] and [Details].
// It takes a row of the window while it is there and nothing else: no focus, no dialog. The x dismisses it.

import "core:fmt"
import "core:strings"
import "toolkit:ui"
import "wb:i18n"

// The last `n` parts of a path after an ellipsis, so that it fits the bar: "...\Wren\crashed-session 2026-10-25 13-49-23.txt"
// (the bar's Details button and the tab.restore_crashed command know the whole path).
path_tail :: proc(path: string, n: int) -> string {
	cut := len(path)
	if cut == 0 { return "" }
	for seen := 0; cut > 0 && seen < n; seen += 1 {
		i := strings.last_index_any(path[:cut], "\\/")
		if i < 0 { return path }
		cut = i
	}
	return strings.concatenate({"\u2026", path[cut:]}, context.temp_allocator)
}

crash_banner :: proc(app: ^App) {
	if recovery.banner == .None { return }
	em := ui.font_size()
	text: string
	switch recovery.banner {
	case .Closed:
		text = recovery.restored > 0 ? fmt.tprintf(i18n.tr(recovery.restored, "Wren closed unexpectedly. Restored %d tab.", "Wren closed unexpectedly. Restored %d tabs."), recovery.restored) : i18n.tr("Wren closed unexpectedly.")
	case .Twice:
		text = fmt.tprintf(i18n.tr("Wren crashed twice while restoring; your tabs are saved in %s"), path_tail(recovery.backup, 2))
	case .None:
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
	do_details, do_primary, close := false, false, false
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###crash_banner") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.tags("warn") { ui.label(fmt.aprintf("%s###crash_text", text, allocator = ui.frame_allocator())) }
		ui.spacer(ui.px(em * 0.6))
		primary := recovery.banner == .Twice ? i18n.tr("Restore tabs") : i18n.tr("Start fresh")
		do_primary = action_button(primary, "crash_primary", em * 8.5)
		ui.spacer(ui.px(em * 0.4))
		do_details = action_button(i18n.tr("Details"), "crash_details", em * 6.5)
		ui.spacer(ui.px(em * 0.4))
		close = nav_button("###crash_close", GLYPH_CLOSE, i18n.tr("Dismiss"), true)
		ui.spacer(ui.px(em * 0.6))
	}
	// (after the row is built: these open and close tabs)
	switch {
	case do_primary:
		if recovery.banner == .Twice { recovery_restore_backup(app) } else { recovery_start_fresh(app) }
	case do_details: recovery_show_details(app)
	case close:      recovery.banner = .None
	}
	if do_primary || do_details || close { app.frames_requested = max(app.frames_requested, 3) }
}

package browser

// Private browsing: a Wren of its own, started with --private (the command browser.new_private_window, Ctrl+Shift+N, or
// the command line). It runs in a profile made for it in the temporary folder, which holds a copy of the user's
// preferences and search engines and nothing else: no cookie, storage, cache, history or session of the user's comes in,
// and browser.profile.persist is off (set as the command line sets it), so nothing is written for later; the folder goes
// when it ends. It never hands its addresses to the user's Wren nor takes theirs (--no-single-instance). Its windows say
// "Private" in their title and in the toolbar.

import "core:os"
import "core:strings"
import "toolkit:ui"
import lucide "toolkit:lucide"
import process "toolkit:process"
import "wb:base"
import "wb:config"
import "wb:i18n"
import api "wb:remote/api"

// What a private Wren copies from the user's profile: how they set the browser up, not what they did with it.
@(private = "file") PRIVATE_COPIED :: [?]string{"prefs.txt", SEARCH_ENGINES_FILE}

// A profile folder for a private Wren, with the user's settings copied from `user_dir` ("" when it cannot be made).
private_profile_make :: proc(user_dir: string, allocator := context.allocator) -> string {
	dir := strings.concatenate({base.temp_dir(context.temp_allocator), "/wren-private-", base.unique_name(context.temp_allocator)}, allocator)
	if os.make_directory_all(dir) != nil { delete(dir, allocator); return "" }
	for name in PRIVATE_COPIED {
		data, err := os.read_entire_file(strings.concatenate({user_dir, "/", name}, context.temp_allocator), context.temp_allocator)
		if err == nil { _ = os.write_entire_file(strings.concatenate({dir, "/", name}, context.temp_allocator), data) }
	}
	return dir
}

// What a private Wren's preferences must say whatever the copy says: nothing is written to its profile for later.
private_prefs_apply :: proc(p: ^config.Prefs) {
	_ = config.set_from_string(p, "browser.profile.persist", "false", .Command_Line)
	_ = config.set_from_string(p, "browser.session.restore", "false", .Command_Line)
	_ = config.set_from_string(p, "blocker.welcome_toast", "false", .Command_Line)   // (said once in the user's own Wren)
}

// Starts a private Wren (this program, --private): its own process and windows.
private_window_open :: proc(app: ^App) {
	exe := process.executable_path(context.temp_allocator)
	if exe == "" { ui.toast(.Bad, "A private window could not be opened"); return }
	p, _, err := api.process_start({exe, "--private", "--no-single-instance"})
	if err != "" { ui.toast(.Bad, "A private window could not be opened: %s", err); return }
	api.process_detach(&p)
}

// The toolkit's "Private" mark in the toolbar of a private Wren's windows.
private_badge :: proc(app: ^App) {
	if !app.private { return }
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.4))
	ui.push_tags("accent_text")
	ui.next({width = ui.children_sum(), height = ui.pct(1)})
	if ui.row(.Center, {}, "###private_badge") {
		ui.next({width = ui.text_size(), height = ui.pct(1), font = app.lucide, font_size = em * 1.05})
		ui.label(lucide.HAT_GLASSES)
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(), height = ui.pct(1)})
		ui.label(i18n.tr("Private"))
		ui.spacer(ui.px(em * 0.4))
	}
	ui.pop_tags()
}

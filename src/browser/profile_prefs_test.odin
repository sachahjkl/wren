package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import config "toolkit:config"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"

// prefs.txt is written only when the user's layer changed since its last text: the autosave of an idle browser writes
// nothing, a change is written once, and the text has what the user set.
@(test)
prefs_are_written_when_the_user_layer_changed :: proc(t: ^testing.T) {
	app := test_app(t)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	_ = os.make_directory_all("build/tmp")
	path := fmt.tprintf("build/tmp/prefs_written_%d.txt", os.get_pid())
	os.remove(path)
	defer os.remove(path)
	defer profile_writes_destroy(&app.recovery.writes)

	profile_prefs_save(app, path)   // (no blocking pool: written on this thread)
	testing.expect(t, !os.exists(path), "nothing the user set: no file")

	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.profile.autosave_interval_ms", "5000", .User), config.Set_Error.None)
	profile_prefs_save(app, path)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the change is written")
	testing.expect(t, strings.contains(string(data), "browser.profile.autosave_interval_ms\t5000\n"), "with the user's value")

	os.remove(path)
	profile_prefs_save(app, path)
	testing.expect(t, !os.exists(path), "no change since: not written again")
}

// Changing any user preference schedules an immediate background write of prefs.txt (not delayed until the 30 s autosave
// timer or clean shutdown), and reloading into a fresh registry preserves every pref type including network.user_agent.
@(test)
prefs_changes_persist_immediately_and_reload :: proc(t: ^testing.T) {
	app := app_make()
	defer app_free(app)
	app_prefs_init(app)
	app_settings_read(app)
	app_loop_init(app)
	app_pools_init(app, 2)
	defer page.settings_destroy(&app.page_settings)
	defer fetch.profile_destroy(&app.profile)
	defer profile_writes_destroy(&app.recovery.writes)

	_ = os.make_directory_all("build/tmp")
	dir := strings.concatenate({"build/tmp/prefs_immediate_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	app.profile_dir = dir
	defer { app.profile_dir = "" }

	prefs_bind_runtime(app)

	testing.expect_value(t, config.set_from_string(&app.prefs, "network.user_agent", "SavedNow/1.0", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&app.prefs, "privacy.do_not_track", "true", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&app.prefs, "network.max_connections_per_host", "10", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.scroll.key_line_px", "55", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&app.prefs, "network.proxy.mode", "none", .User), config.Set_Error.None)

	// Drain the blocking pool so background Profile_File writes complete without waiting for the autosave timer.
	for _ in 0 ..< host.FILE_FLUSH_ROUNDS {
		host.blocking_settle(&app.blocking)
		if !app.recovery.writes.prefs.busy && !app.recovery.writes.prefs.waiting { break }
	}

	_, _, prefs_path := profile_paths(app)
	testing.expect(t, os.exists(prefs_path), "prefs.txt must be written promptly after pref changes")

	reloaded := config.prefs_make()
	defer config.prefs_destroy(&reloaded)
	config.load_file(&reloaded, prefs_path, .User)
	register_all_prefs(&reloaded)
	testing.expect_value(t, config.string_of(&reloaded, "network.user_agent"), "SavedNow/1.0")
	testing.expect_value(t, config.bool_of(&reloaded, "privacy.do_not_track"), true)
	testing.expect_value(t, config.int_of(&reloaded, "network.max_connections_per_host"), i64(10))
	testing.expect_value(t, config.float_of(&reloaded, "browser.scroll.key_line_px"), f64(55))
	testing.expect_value(t, config.string_of(&reloaded, "network.proxy.mode"), "none")

	ns := net.settings_from_prefs(&reloaded)
	defer net.settings_destroy(&ns)
	testing.expect_value(t, ns.user_agent, "SavedNow/1.0")
	testing.expect_value(t, ns.proxy, net.Proxy_Mode.None)

	// Resetting a preference and syncing writes the removal to prefs.txt so it stays reset after restart.
	testing.expect_value(t, config.reset(&app.prefs, "network.user_agent"), config.Set_Error.None)
	profile_prefs_sync(app)
	for _ in 0 ..< host.FILE_FLUSH_ROUNDS {
		host.blocking_settle(&app.blocking)
		if !app.recovery.writes.prefs.busy && !app.recovery.writes.prefs.waiting { break }
	}
	reloaded2 := config.prefs_make()
	defer config.prefs_destroy(&reloaded2)
	config.load_file(&reloaded2, prefs_path, .User)
	register_all_prefs(&reloaded2)
	testing.expect_value(t, config.string_of(&reloaded2, "network.user_agent"), "")
}

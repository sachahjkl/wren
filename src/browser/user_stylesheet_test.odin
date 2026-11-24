package browser

import "core:os"
import "core:strings"
import "core:testing"
import config "toolkit:config"
import "wb:base"
import "wb:host"
import "wb:page"

// style.user_stylesheet is loaded once off the UI thread and cached on App; later syncs reuse the cached text without disk reads.
@(test)
user_stylesheet_cached_off_thread :: proc(t: ^testing.T) {
	app := app_make()
	defer app_free(app)
	app_prefs_init(app)
	app_settings_read(app)
	app_loop_init(app)
	app_pools_init(app, 2)
	defer page.settings_destroy(&app.page_settings)

	dir := strings.concatenate({"build/tmp/user_css_test_", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	css_path := strings.concatenate({dir, "/user.css"}, context.temp_allocator)
	css_text := "p { color: rgb(11, 22, 33); }"
	testing.expect(t, os.write_entire_file(css_path, transmute([]byte)css_text) == nil)

	testing.expect_value(t, config.set_from_string(&app.prefs, "style.user_stylesheet", css_path, .User), config.Set_Error.None)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	user_stylesheet_sync(app)
	// Async load runs on the blocking pool, not synchronously on the UI thread.
	testing.expect_value(t, app.page_settings.style.user_stylesheet_css, "")
	host.blocking_settle(&app.blocking)
	testing.expect_value(t, app.page_settings.style.user_stylesheet_css, css_text)

	// Removing the file from disk proves subsequent refreshes reuse the cached CSS without touching disk.
	_ = os.remove(css_path)
	page.settings_destroy(&app.page_settings)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	user_stylesheet_sync(app)
	testing.expect_value(t, app.page_settings.style.user_stylesheet_css, css_text)

	// Clearing the preference clears the cache and pre-loaded CSS.
	testing.expect_value(t, config.set_from_string(&app.prefs, "style.user_stylesheet", "", .User), config.Set_Error.None)
	page.settings_destroy(&app.page_settings)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	user_stylesheet_sync(app)
	testing.expect_value(t, app.page_settings.style.user_stylesheet_css, "")
}

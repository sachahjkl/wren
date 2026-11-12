package browser

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:config"

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

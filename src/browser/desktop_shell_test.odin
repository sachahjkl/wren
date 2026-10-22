package browser

import "core:os"
import "core:strings"
import "core:testing"
import "wb:config"

@(test)
desktop_identity_is_well_formed :: proc(t: ^testing.T) {
	id := desktop_identity()
	testing.expect(t, id.name != "" && id.key != "" && id.slug != "" && id.aumid != "", "no empty field")
	testing.expect(t, !strings.contains_any(id.aumid, " \t") && len(id.aumid) <= 128, "an AppUserModelID has no space and at most 128 characters")
	testing.expect(t, strings.has_prefix(id.aumid, "FromentSoftware."), "vendor-prefixed")
	when IS_DEV_BUILD {
		testing.expect(t, strings.contains(id.key, "Dev") && strings.contains(id.slug, "dev") && strings.contains(id.aumid, "Dev"), "a development build has entries of its own")
	} else {
		testing.expect(t, !strings.contains(id.key, "Dev") && !strings.contains(id.aumid, "Dev"), "the release has the plain ones")
	}
}

@(test)
first_run_integration_defaults_to_the_release_channel_only :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_desktop_shell_prefs(&p)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.on_first_run"), APP_CHANNEL == .Release)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.offer_update"), true)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.register_browser"), true)
}

@(test)
disposable_profiles_never_integrate :: proc(t: ^testing.T) {
	app: App
	app.cfg.persist_profile = true
	app.profile_dir = "C:/Users/someone/AppData/Roaming/Wren"
	testing.expect(t, !desktop_profile_is_disposable(&app, false), "the user's own profile")
	testing.expect(t, desktop_profile_is_disposable(&app, true), "given with --profile")
	app.cfg.persist_profile = false
	testing.expect(t, desktop_profile_is_disposable(&app, false), "a profile that is not kept")
	app.cfg.persist_profile = true
	tmp, _ := os.temp_dir(context.temp_allocator)
	app.profile_dir = strings.concatenate({tmp, "\\wren_test_profile"}, context.temp_allocator)
	testing.expect(t, desktop_profile_is_disposable(&app, false), "a profile in the temporary folder")
	app.profile_dir = strings.concatenate({strings.to_upper(tmp, context.temp_allocator), "/x/y"}, context.temp_allocator)
	testing.expect(t, desktop_profile_is_disposable(&app, false), "(case and slash direction do not matter)")
}

package browser

import "core:os"
import "core:strings"
import "core:testing"
import "wb:config"
import "wb:desktop"

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

// What Setup writes as wren.com is what build.bat built from src/tools/wrencom: a console program (PE, subsystem 3) that
// carries the mark by which the integration tells it from another program's file of that name.
@(test)
the_embedded_console_launcher_is_the_launcher :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		exe := CONSOLE_LAUNCHER
		testing.expect(t, len(exe) > 4096 && exe[0] == 'M' && exe[1] == 'Z', "a program")
		testing.expect(t, strings.contains(string(exe), desktop.LAUNCHER_MARK), "it carries the mark")
		pe := int(exe[0x3C]) | int(exe[0x3D]) << 8 | int(exe[0x3E]) << 16 | int(exe[0x3F]) << 24
		testing.expect(t, pe + 0x5C < len(exe), "a PE header")
		if pe + 0x5C < len(exe) {
			testing.expect_value(t, string(exe[pe:pe + 4]), "PE\x00\x00")
			testing.expect_value(t, int(exe[pe + 0x5C]), 3)   // optional header's Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI
		}
		app: App
		app.prefs = config.prefs_make()
		defer config.prefs_destroy(&app.prefs)
		register_desktop_shell_prefs(&app.prefs)
		o := desktop_options(&app)
		testing.expect_value(t, len(o.launcher), len(exe))
	}
}

@(test)
first_run_integration_defaults_to_the_release_channel_only :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_desktop_shell_prefs(&p)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.on_first_run"), APP_CHANNEL == .Release)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.start_menu"), true)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.desktop_shortcut"), false)
	testing.expect_value(t, config.bool_of(&p, "browser.desktop_integration.add_to_path"), false)
	testing.expect_value(t, config.bool_of(&p, "browser.update.check_daily"), false)   // no network request unless asked
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

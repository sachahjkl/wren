package page

import "core:testing"
import config "toolkit:config"

@(test)
navigator_platform_matches_os_default :: proc(t: ^testing.T) {
	test_pages(t)
	testing.expect_value(t, navigator_platform_for_os(.Windows), "Win32")
	testing.expect_value(t, navigator_platform_for_os(.Darwin), "MacIntel")
	testing.expect_value(t, navigator_platform_for_os(.Linux), "Linux x86_64")

	st := settings_default()
	defer settings_destroy(&st)
	testing.expect_value(t, st.js_web.platform, navigator_platform_for_os(ODIN_OS))

	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	config.register(&p, JS_WEB_PREFS[:])
	testing.expect_value(t, config.set_from_string(&p, "navigator.platform", "CustomOS", .User), config.Set_Error.None)
	custom := js_web_settings_from_prefs(&p)
	defer js_web_settings_destroy(&custom)
	testing.expect_value(t, custom.platform, "CustomOS")

	testing.expect_value(t, config.reset(&p, "navigator.platform"), config.Set_Error.None)
	reset := js_web_settings_from_prefs(&p)
	defer js_web_settings_destroy(&reset)
	testing.expect_value(t, reset.platform, navigator_platform_for_os(ODIN_OS))
}

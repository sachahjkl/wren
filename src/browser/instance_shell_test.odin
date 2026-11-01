package browser

import "core:testing"
import "wb:config"

@(test)
single_instance_applies_by_default_and_gives_way_to_the_escapes :: proc(t: ^testing.T) {
	testing.expect(t, instance_wanted(true, false, false, "", true), "the default")
	testing.expect(t, !instance_wanted(false, false, false, "", true), "browser.single_instance off")
	testing.expect(t, !instance_wanted(true, true, false, "", true), "--new-window / --no-single-instance")
	testing.expect(t, !instance_wanted(true, false, false, "off", true), "WREN_SINGLE_INSTANCE=off (every script's environment)")
	testing.expect(t, instance_wanted(false, false, false, "on", true), "=on turns it on whatever the preference says")
	testing.expect(t, !instance_wanted(true, false, true, "", true), "a driven window is its own")
	testing.expect(t, instance_wanted(true, false, true, "on", true), "... unless =on says otherwise: what a scenario of the hand-over runs on")
	testing.expect(t, !instance_wanted(true, true, false, "on", true), "but not against --new-window")
	testing.expect(t, !instance_wanted(true, false, false, "", false), "never for a profile that is not kept: its folder is the user's")
	testing.expect(t, !instance_wanted(true, false, false, "on", false), "(also not when forced)")
	testing.expect(t, instance_wanted(true, false, false, "anything else", true), "an unknown value is not an off switch")
}

@(test)
switches_are_taken_out_of_the_arguments :: proc(t: ^testing.T) {
	found, rest := extract_switch({"--setup", "https://a/", "--pref", "x=y"}, "--setup")
	testing.expect(t, found, "found")
	testing.expect_value(t, len(rest), 3)
	found, rest = extract_switch({"https://a/", "--pref", "x=y"}, "--setup")
	testing.expect(t, !found, "not there")
	testing.expect_value(t, len(rest), 3)
	found, rest = extract_switch({"--new-window", "--new-window", "a"}, "--new-window")
	testing.expect(t, found && len(rest) == 1 && rest[0] == "a", "each occurrence goes")
}

@(test)
single_instance_preference_defaults_on :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_instance_prefs(&p)
	testing.expect_value(t, config.bool_of(&p, "browser.single_instance"), true)
}

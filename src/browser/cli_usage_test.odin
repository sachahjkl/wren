package browser

import "core:strings"
import "core:testing"

@(test)
the_version_and_the_usage_are_asked_by_flags_and_first_words :: proc(t: ^testing.T) {
	testing.expect_value(t, cli_info_of({}), Cli_Info.None)
	testing.expect_value(t, cli_info_of({"https://example.org"}), Cli_Info.None)
	testing.expect_value(t, cli_info_of({"--version"}), Cli_Info.Version)
	testing.expect_value(t, cli_info_of({"-V"}), Cli_Info.Version)
	testing.expect_value(t, cli_info_of({"--profile", "p", "--version"}), Cli_Info.Version)
	testing.expect_value(t, cli_info_of({"--help"}), Cli_Info.Help)
	testing.expect_value(t, cli_info_of({"-h"}), Cli_Info.Help)
	testing.expect_value(t, cli_info_of({"-?"}), Cli_Info.Help)
	testing.expect_value(t, cli_info_of({"--version", "--help"}), Cli_Info.Help)   // (the usage says more)
	// the words are commands only as the first argument
	testing.expect_value(t, cli_info_of({"version"}), Cli_Info.Version)
	testing.expect_value(t, cli_info_of({"help"}), Cli_Info.Help)
	testing.expect_value(t, cli_info_of({"--new-window", "help"}), Cli_Info.None)
	testing.expect_value(t, cli_info_of({"./help"}), Cli_Info.None)
	// a value that only looks like a flag is a value
	testing.expect_value(t, cli_info_of({"--pref", "a=-h"}), Cli_Info.None)
}

@(test)
ctl_help_and_version_are_the_words_that_are_not_addresses :: proc(t: ^testing.T) {
	for w in ([]string{"ctl", "help", "version"}) { testing.expect(t, is_info_word(w), w) }
	for w in ([]string{"./ctl", "ctl.example.org", "https://help", "Help", ""}) { testing.expect(t, !is_info_word(w), w) }
}

@(test)
the_usage_names_every_option_and_the_version_the_build :: proc(t: ^testing.T) {
	usage := cli_usage_text()
	for s in ([]string{"wren ctl", "wren version", "wren help", "--new-window", "--no-single-instance", "--profile", "--policy", "--pref", "--setup", "--remote", "--headless", "--desktop-integration", "./ctl"}) {
		testing.expectf(t, strings.contains(usage, s), "the usage does not mention %q", s)
	}
	ver := cli_version_text()
	testing.expect(t, strings.has_prefix(ver, APP_NAME), "the version starts with the name")
	testing.expect(t, strings.contains(ver, APP_VERSION), "the version has the version")
	testing.expect(t, strings.contains(ver, "build: "), "the version says how it was built")
	testing.expect_value(t, cli_info_text(.None), "")
}

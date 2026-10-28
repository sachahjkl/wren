package browser

import "core:fmt"
import "core:strings"
import "wb:i18n"

////////////////////////////////
// What `wren --version` and `wren --help` say. They are answered before anything is set up (no profile, no window), like
// `wren ctl`: the words `version` and `help` are commands only as the first argument (a file or host named like that is
// written ./help); the flags can be anywhere. wren.com (src/tools/wrencom/plan.odin) waits for them and hands back the
// exit code, so that they print in a terminal.

// The flags that ask for the version or for the usage, anywhere in the line.
VERSION_FLAGS :: [?]string{"--version", "-V"}
HELP_FLAGS    :: [?]string{"--help", "-h", "-?"}

// The first arguments that are commands of their own (`ctl` is the remote control client, main.odin).
INFO_WORDS :: [?]string{"ctl", "help", "version"}

Cli_Info :: enum u8 { None, Version, Help }

// What the line asks for: the version, the usage, or nothing of the kind (the browser starts as usual).
cli_info_of :: proc(args: []string) -> Cli_Info {
	if len(args) > 0 {
		switch args[0] {
		case "version": return .Version
		case "help":    return .Help
		}
	}
	info := Cli_Info.None
	for a in args {
		for f in VERSION_FLAGS { if a == f && info == .None { info = .Version } }
		for f in HELP_FLAGS { if a == f { return .Help } }
	}
	return info
}

// `ctl`, `help` or `version` written where the browser takes it for an address (after an option): it would open https://help.
is_info_word :: proc(s: string) -> bool {
	for w in INFO_WORDS { if s == w { return true } }
	return false
}

cli_version_text :: proc() -> string {
	return fmt.tprintf("%s %s\nbuild: %s\n", APP_NAME, version_long(), build_description())
}

cli_usage_text :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s %s\n\n", APP_NAME, version_long())
	fmt.sbprintf(&sb, "%s\n", i18n.tr("Usage"))
	row :: proc(sb: ^strings.Builder, what, why: string) { fmt.sbprintf(sb, "  %-34s %s\n", what, why) }
	row(&sb, "wren [options] [address ...]", i18n.tr("opens the addresses (a tab of the Wren that runs, else a window)"))
	row(&sb, "wren ctl <command> [options]", i18n.tr("drives a running Wren (wren ctl help lists the commands)"))
	row(&sb, "wren version", i18n.tr("prints the version (also --version, -V)"))
	row(&sb, "wren help", i18n.tr("prints this text (also --help, -h, -?)"))
	fmt.sbprintf(&sb, "\n%s\n", i18n.tr("Options"))
	row(&sb, "--new-window", i18n.tr("a window of its own, not a tab of the Wren that runs"))
	row(&sb, "--no-single-instance", i18n.tr("never hands the addresses to a Wren that runs"))
	row(&sb, "--profile <dir>", i18n.tr("the profile folder to use"))
	row(&sb, "--policy <file>", i18n.tr("a policy file (settings an administrator fixes)"))
	row(&sb, "--pref name=value", i18n.tr("sets a preference for this run (about:config lists them)"))
	row(&sb, "--setup", i18n.tr("opens the Setup dialog"))
	row(&sb, "--remote[=name]", i18n.tr("opens the remote control channel (wren ctl)"))
	row(&sb, "--hidden", i18n.tr("windows are made and never shown (`wren ctl start`; needs a desktop session)"))
	row(&sb, "--headless", i18n.tr("no window at all (it renders all the same); runs without a desktop session"))
	row(&sb, "--remote-debugging-port[=N]", i18n.tr("CDP / WebDriver BiDi on 127.0.0.1 (Puppeteer, Playwright; see docs/cdp.md)"))
	row(&sb, "--desktop-integration=<mode>", i18n.tr("install, remove, status or uninstall: the file types, the menu entry, the PATH"))
	row(&sb, "--uninstall [--purge]", i18n.tr("removes the installed copy silently (--purge also deletes the profile)"))
	fmt.sbprintf(&sb, "\n%s\n", i18n.tr("A file or a host named ctl, help or version is written ./ctl, ./help, ./version."))
	return strings.to_string(sb)
}

// The text for `what`, and the exit code: 0.
cli_info_text :: proc(what: Cli_Info) -> string {
	#partial switch what {
	case .Version: return cli_version_text()
	case .Help:    return cli_usage_text()
	}
	return ""
}

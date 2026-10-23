package remote

import "wb:config"

// The remote control channel's preferences (about:config, `browser.remote.*`). The channel itself is off unless
// `browser.remote.enabled`, `--remote[=name]` or WREN_REMOTE=<name> asks for it; nothing of it exists in a process that
// was not asked (no pipe, no thread, no timer).

Settings :: struct {
	enabled:       bool,
	name:          string,   // "": derived from the profile folder
	max_message:   int,
	max_clients:   int,
	indicator:     bool,
	timeout_ms:    int,
	settle_frames: int,
	poll_ms:       int,
	idle_ms:       int,
}

PREFS := [?]config.Def{
	{name = "browser.remote.enabled", kind = .Bool, default = {b = false}, restart = true,
		description = "Listen on a named pipe for commands from `wren ctl` (navigate, evaluate script, capture the window, send input, read the console and network logs). Only the current Windows user can connect. `--remote` or `--remote=<name>` on the command line, or WREN_REMOTE=<name> in the environment, turn it on for one run. The pipe is \\\\.\\pipe\\wren-remote-<name>; <profile>\\remote.json says which."},
	{name = "browser.remote.name", kind = .String, default = {s = ""}, restart = true,
		description = "Name of the remote control pipe. Empty: derived from the profile folder, so several Wren with different profiles never collide."},
	{name = "browser.remote.max_message_bytes", kind = .Int, default = {i = 8 << 20}, bounded = true, min = 4096, max = 1 << 30, unit = "bytes", bytes = true, restart = true,
		description = "Largest request line a remote client may send. A longer one is answered with an error and the connection is closed."},
	{name = "browser.remote.max_clients", kind = .Int, default = {i = 8}, bounded = true, min = 1, max = 256, restart = true,
		description = "Remote clients connected at once. Another one is turned away."},
	{name = "browser.remote.indicator", kind = .Bool, default = {b = true},
		description = "Show \"remote\" in the status bar while the remote control channel is listening."},
	{name = "browser.remote.timeout_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 100, max = 3_600_000, unit = "ms",
		description = "How long a wait (page load, network idle, selector, script condition) lasts when the command gives no timeout of its own."},
	{name = "browser.remote.settle_frames", kind = .Int, default = {i = 2}, bounded = true, min = 0, max = 60,
		description = "Frames drawn after a command before a capture is taken, so that hover, focus and transitions started by the command are in the picture."},
	{name = "browser.remote.poll_ms", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 1000, unit = "ms",
		description = "While a wait or a capture is pending, how often its condition is looked at when nothing else wakes the browser. Nothing runs when no command is waiting."},
	{name = "browser.remote.idle_ms", kind = .Int, default = {i = 400}, bounded = true, min = 10, max = 60_000, unit = "ms",
		description = "How long the network must stay quiet (no request in flight) for a wait for `idle` to end."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "browser.remote.enabled"),
		name = config.string_of(p, "browser.remote.name"),   // (the registry's: valid while it lives)
		max_message = int(config.int_of(p, "browser.remote.max_message_bytes")),
		max_clients = int(config.int_of(p, "browser.remote.max_clients")),
		indicator = config.bool_of(p, "browser.remote.indicator"),
		timeout_ms = int(config.int_of(p, "browser.remote.timeout_ms")),
		settle_frames = int(config.int_of(p, "browser.remote.settle_frames")),
		poll_ms = int(config.int_of(p, "browser.remote.poll_ms")),
		idle_ms = int(config.int_of(p, "browser.remote.idle_ms")),
	}
}

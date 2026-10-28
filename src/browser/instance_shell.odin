package browser

// One Wren per profile (toolkit:instance, the single-instance mechanism): the shell side, and Wren's own message codec.
//
//   * At the start, before anything costly (the window, the renderer, the network): the first Wren of a profile and a channel
//     takes the name; a second one hands its addresses (the paths it was given are turned into addresses by the command
//     line's own rules), `--setup` and the request to come forward to the first, and ends with exit code 0.
//   * The first one opens one tab per address, restores its window if it is minimized and takes the foreground (the second
//     one allowed it). With nothing to open the window just comes forward.
//   * Only the same executable takes the hand-over (the identity is the executable path): a different copy of Wren (an update
//     just downloaded, another folder) opens its own window as it always did, so that Setup can replace the installed copy
//     while it runs.
//   * A first one that does not answer within three seconds (a page keeps it busy, it is hung) does not hold the second one: that
//     one opens its own window and says so (the console of its first tab, and a notice).
//   * `--new-window` (or `--no-single-instance`) on the command line, browser.single_instance off, WREN_SINGLE_INSTANCE=off in
//     the environment (tools\test_env.ps1 sets it for every script that starts the browser), and a profile that is not kept
//     (browser.profile.persist off: it shares its folder with the user's) all skip it. WREN_SINGLE_INSTANCE=on turns it on
//     for a run of a script that checks it.
//
// The mechanism (named mutex and a message-only window on Windows, a lock file and a Unix socket on POSIX) is the toolkit's,
// platform-neutral; the message (exe / setup / addresses) is Wren's and travels as the opaque bytes `encode_message` writes.
//
// Nothing runs per frame: the first one's window only wakes when a second start sends it something.

import "core:os"
import "core:strings"
import "toolkit:instance"
import "toolkit:ui"
import "wb:config"
import "wb:desktop"
import "wb:host"
import win "core:sys/windows"

INSTANCE_PREFS := [?]config.Def{
	{name = "browser.single_instance", kind = .Bool, default = {b = true},
		description = "Starting Wren again with the same profile (a link opened from another program, a double-clicked .html file, `wren.exe https://...` in a terminal) opens a tab in the Wren that is already running, brings its window to the front and ends, instead of opening a second window on the same profile. Only the same executable does this: another copy of Wren (a newer download, another folder) opens its own window. `--new-window` on the command line opens a separate window for once. WREN_SINGLE_INSTANCE=off in the environment turns it off, =on turns it on whatever this says (for scripts). Never with browser.profile.persist off. Applied at the next start."},
}

register_instance_prefs :: proc(p: ^config.Prefs) { config.register(p, INSTANCE_PREFS[:]) }

// Wren's message: what a second start hands over. Carried as the opaque bytes the toolkit forwards.
Instance_Message :: struct {
	setup:     bool,       // `--setup`: open the Setup dialog
	addresses: []string,   // what was given to open, one tab each (already addresses: paths made into file: URLs)
}

// The bytes of a message: lines "v1", "setup=0|1", then "addr=<address>" for each (an address with a line break in it is
// dropped: it cannot be one). The executable path is the identity, handled by the toolkit, not part of this.
@(private = "file")
encode_message :: proc(m: Instance_Message, allocator := context.temp_allocator) -> []byte {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "v1\n")
	strings.write_string(&sb, m.setup ? "setup=1\n" : "setup=0\n")
	for a in m.addresses {
		if a == "" || strings.contains_any(a, "\r\n\x00") { continue }
		strings.write_string(&sb, "addr="); strings.write_string(&sb, a); strings.write_string(&sb, "\n")
	}
	return transmute([]byte)strings.to_string(sb)
}

// The message those bytes carry (the strings point into `data`; the addresses slice is in `allocator`). ok = false for
// anything that is not a message of this version.
@(private = "file")
decode_message :: proc(data: []byte, allocator := context.temp_allocator) -> (m: Instance_Message, ok: bool) {
	text := string(data)
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) == 0 || lines[0] != "v1" { return {}, false }
	addresses := make([dynamic]string, allocator)
	for l in lines[1:] {
		switch {
		case l == "setup=1":                 m.setup = true
		case l == "setup=0":
		case strings.has_prefix(l, "addr="): append(&addresses, l[len("addr="):])
		case l == "":
		case: return {}, false
		}
	}
	m.addresses = addresses[:]
	return m, true
}

@(private = "file")
Instance_State :: struct {
	owner:        instance.Owner,
	mine:         bool,       // this process owns the profile
	warning:      string,     // the owner did not answer (a static text): said once the interface exists
	warn_pending: bool,
}

@(private = "file") inst: Instance_State

// Does this start take part? `env` is WREN_SINGLE_INSTANCE ("" when unset).
instance_wanted :: proc(pref, new_window: bool, env: string, persisted: bool) -> bool {
	switch {
	case !persisted:        return false   // (its folder is the user's, shared with a Wren that keeps it)
	case new_window:        return false
	case env == "off":      return false
	case env == "on":       return true
	}
	return pref
}

// The single-instance name of this profile and channel: the same name the previous releases used ("Wren.<channel>.<hash>").
@(private = "file")
instance_name :: proc(app: ^App) -> string {
	prefix := strings.concatenate({"Wren.", channel_name()}, context.temp_allocator)
	return instance.key(prefix, app.profile_dir)
}

// Before the window exists. May end the process (exit code 0) when the first Wren took the hand-over.
instance_early :: proc(app: ^App, rest: []string, setup, new_window: bool) {
	env, _ := os.lookup_env("WREN_SINGLE_INSTANCE", context.temp_allocator)
	if !instance_wanted(config.bool_of(&app.prefs, "browser.single_instance"), new_window, env, app.cfg.persist_profile) { return }
	exe := desktop.executable_path()
	addresses := make([dynamic]string, context.temp_allocator)
	for a in rest { if s := command_line_address(a); s != "" { append(&addresses, s) } }
	message := encode_message({setup = setup, addresses = addresses[:]})
	outcome, owner := instance.acquire({name = instance_name(app), identity = exe, wait_ms = 3000}, message)
	switch outcome {
	case .Forwarded:       os.exit(0)
	case .First:           inst.owner, inst.mine = owner, true
	case .Other_Instance:  // another executable owns the profile: this one opens its own window
	case .Unresponsive:
		inst.warning = "Another Wren window of this profile did not answer (it is busy or stuck): this one opens separately, so the two share one profile."
		inst.warn_pending = true
	}
}

// Whether this process holds the profile's single instance: no other Wren of the same executable runs on the profile, so
// what the last run left in it (crash_recovery.odin's marker) is not a running Wren's.
instance_owns_profile :: proc() -> bool { return inst.mine }

// Once the event loop exists: the window that takes the second starts' messages.
instance_begin :: proc(app: ^App) {
	if inst.mine && !instance.owner_start(&inst.owner, instance_handler, app) {
		inst.mine = false   // (no window: later starts will think this one stuck and open their own)
		instance.owner_stop(&inst.owner)
	}
}

// When the loop ends: later starts are told to wait (the window goes, the profile is still this one's until the end of main,
// when the profile has been written: instance_release).
instance_end :: proc() {
	if inst.mine { instance.owner_closing(&inst.owner) }
}

// The very end: the profile is free.
instance_release :: proc() {
	if inst.mine { instance.owner_stop(&inst.owner); inst.mine = false }
}

// The notice of an owner that did not answer, once the interface exists (build_ui).
instance_frame :: proc(app: ^App) {
	if !inst.warn_pending { return }
	inst.warn_pending = false
	ui.toast(.Warn, "%s", inst.warning)
	if t := current_tab(app); t != nil { tab_log(t, .Warn, inst.warning) }
}

@(private = "file")
Instance_Open :: struct {
	addresses: [dynamic]string,
	setup:     bool,
}

// Inside the window's message (the sender waits): decode Wren's message, take a copy and leave the work to the loop.
@(private = "file")
instance_handler :: proc(user: rawptr, message: []byte) {
	if the_app == nil { return }
	m, ok := decode_message(message)
	if !ok { return }
	d := new(Instance_Open)
	d.setup = m.setup
	for a, i in m.addresses {
		if i >= 64 { break }   // (a message from a program that means harm is not a way to open a thousand tabs)
		append(&d.addresses, strings.clone(a))
	}
	host.post(&the_app.loop, instance_open, d)
}

@(private = "file")
instance_open :: proc(data: rawptr) {
	d := (^Instance_Open)(data)
	defer {
		for a in d.addresses { delete(a) }
		delete(d.addresses)
		free(d)
	}
	app := the_app
	if app == nil { return }
	wnd := active_window(app)
	first := -1
	for a in d.addresses {
		tab_open(app, a, origin = .User)
		if first < 0 { first = wnd.current }
	}
	// the first of the new tabs is shown (the others wait, as with files dropped on the window)
	if first >= 0 && first < len(wnd.tabs) {
		wnd.current = first
		if t := current_tab(app); t != nil { ui.field_set(&wnd.address, t.url) }
	}
	if d.setup { setup_open(app, .Command) }
	when ODIN_OS == .Windows { instance.raise_window(rawptr(active_window(app).win.hwnd)) }
	request_frames(app, 4)
}

_ :: win

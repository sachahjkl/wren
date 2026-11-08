// Package client: `wren ctl`, the command line of the remote control channel. It is a sub-command of the browser's own
// executable (the same file is server and client, so their protocol versions cannot differ); the browser's main hands over the
// arguments after `ctl` before anything is initialized (no window, no GPU, no script engine, no profile opened), so a command
// starts and ends in a few milliseconds besides the wait for its answer.
//
// Exit codes: 0 done, 1 the command failed (an error answer, a script exception), 2 timed out, 3 no Wren answers (or the
// connection ended), 4 wrong usage.
package client

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import process "../../../ext/gui_toolkit/src/process"
import "wb:remote"
import "wb:remote/api"

EXIT_OK      :: 0
EXIT_FAILED  :: 1
EXIT_TIMEOUT :: 2
EXIT_NO_SERVER :: 3
EXIT_USAGE   :: 4

Options :: struct {
	vals:  map[string]string,
	flags: map[string]bool,
	pos:   [dynamic]string,
	prefs: [dynamic]string,   // --pref name=value, as many as given (passed to a Wren that `run` or `start` launches)
}

Context :: struct {
	o:               Options,
	s:               api.Session,
	default_profile: string,   // the profile folder a Wren without --profile uses
	exe:             string,   // this executable
}

// How long a command tries to reach a Wren that runs (ms): by default, and at most with --timeout.
CONNECT_WAIT_MS :: 300
CONNECT_WAIT_MOST_MS :: 5000

// Options that take a value; every other `--name` must be in BOOL_OPTIONS.
@(private) VALUE_OPTIONS := [?]string{"remote", "profile", "timeout", "tab-id", "wait", "selector", "rect", "scale", "settle", "size", "dpi",
	"shot", "name", "out", "tolerance", "code", "button", "steps", "since", "dock", "state", "pos", "max-percent", "eval", "repeat", "speed",
	"panel", "limit", "settle-ms", "html", "pref", "cwd", "idle-ms", "quiet-ms", "max-cpu", "count", "interval", "keep", "url", "at", "text", "win-id", "to", "index", "cols", "dump"}
@(private) BOOL_OPTIONS := [?]string{"json", "await", "tab", "window", "clear", "right", "double", "visible", "bytes", "help", "quiet", "override",
	"headless", "middle", "all", "timing", "reset-latency", "reset-frames", "leave", "front", "close", "hold", "resume"}

out :: proc(s: string) { process.console_write(s) }
outln :: proc(s: string) { process.console_write(strings.concatenate({s, "\n"}, context.temp_allocator)) }
errln :: proc(s: string) { process.console_error(strings.concatenate({s, "\n"}, context.temp_allocator)) }

parse_options :: proc(args: []string) -> (o: Options, err: string) {
	o.vals = make(map[string]string, 8, context.temp_allocator)
	o.flags = make(map[string]bool, 8, context.temp_allocator)
	o.pos = make([dynamic]string, context.temp_allocator)
	o.prefs = make([dynamic]string, context.temp_allocator)
	only_positional := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if !only_positional && a == "--" { only_positional = true; continue }
		if only_positional || len(a) < 3 || !strings.has_prefix(a, "--") { append(&o.pos, a); continue }
		name, value, has_value := a[2:], "", false
		if eq := strings.index_byte(a, '='); eq > 2 { name, value, has_value = a[2:eq], a[eq + 1:], true }
		if name == "pref" {
			if !has_value {
				if i + 1 >= len(args) { return o, "--pref needs name=value" }
				i += 1
				value = args[i]
			}
			append(&o.prefs, value)
		} else if contains(VALUE_OPTIONS[:], name) {
			if !has_value {
				if i + 1 >= len(args) { return o, fmt.tprintf("--%s needs a value", name) }
				i += 1
				value = args[i]
			}
			o.vals[name] = value
		} else if contains(BOOL_OPTIONS[:], name) {
			o.flags[name] = !has_value || value != "false"
		} else {
			return o, fmt.tprintf("unknown option --%s", name)
		}
	}
	return
}

@(private)
contains :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

opt :: proc(o: ^Options, name: string, default := "") -> string { return o.vals[name] or_else default }
flag :: proc(o: ^Options, name: string) -> bool { return o.flags[name] }

opt_int :: proc(o: ^Options, name: string, default: int) -> int {
	s, ok := o.vals[name]
	if !ok { return default }
	v, good := strconv.parse_int(s)
	return good ? v : default
}

// The command line after `ctl`. `default_profile`: the folder of the profile this Wren uses without --profile (it decides the
// pipe's name); `exe`: this program's path.
run :: proc(argv: []string, default_profile, exe: string) -> int {
	if len(argv) == 0 { return help_main(nil) }
	o, err := parse_options(argv)
	if err != "" { errln(fmt.tprintf("wren ctl: %s (wren ctl help)", err)); return EXIT_USAGE }
	if len(o.pos) == 0 { return help_main(nil) }
	cmd := o.pos[0]
	args := o.pos[1:]
	if flag(&o, "help") || cmd == "help" {
		if cmd == "help" { return help_main(args) }
		return help_main({cmd})
	}
	ctx := Context{o = o, default_profile = default_profile, exe = exe}
	ctx.s.timeout_ms = opt_int(&o, "timeout", 0)
	ctx.s.idle_ms = opt_int(&o, "idle-ms", 0)
	ctx.s.window = opt_int(&o, "win-id", 0)
	ctx.s.tab = opt_int(&o, "tab-id", 0)
	ctx.s.name = resolve_name(&ctx)
	ctx.s.connect_wait_ms = ctx.s.timeout_ms > 0 ? min(ctx.s.timeout_ms, CONNECT_WAIT_MOST_MS) : CONNECT_WAIT_MS
	defer api.close_session(&ctx.s)
	return dispatch(&ctx, cmd, args)
}

// The name of the pipe to use: --remote, WREN_REMOTE, the folder given by --profile, else the default profile's.
resolve_name :: proc(ctx: ^Context) -> string {
	if n := opt(&ctx.o, "remote"); n != "" { return n }
	if n, ok := os.lookup_env("WREN_REMOTE", context.temp_allocator); ok && n != "" { return n }
	if p := opt(&ctx.o, "profile"); p != "" { return remote.profile_name(p) }
	return remote.profile_name(ctx.default_profile)
}

// A call that failed: said, and the exit code it is.
failed :: proc(ctx: ^Context, e: api.Error) -> int {
	f := api.last_failure()
	switch e {
	case .None: return 0
	case .No_Server:
		errln(fmt.tprintf("wren ctl: no Wren answers on %s. Start one with `wren ctl start` (or `wren --remote`), or name it with --remote <name>.", remote.pipe_path(ctx.s.name)))
		return EXIT_NO_SERVER
	case .Timeout:
		errln(fmt.tprintf("error: %s", f.message))
		if f.data != "" { errln(f.data) }
		return EXIT_TIMEOUT
	case .Closed:
		errln("error: the connection to Wren ended")
		return EXIT_NO_SERVER
	case .Server, .Script, .Bad_Answer:
		errln(fmt.tprintf("error: %s", f.message))
		if f.data != "" { errln(f.data) }
		return EXIT_FAILED
	}
	return EXIT_FAILED
}

// An answer as JSON, for a command that prints parts of it.
parse_result :: proc(result: string) -> json.Object {
	v, _ := json.parse(transmute([]byte)result, json.Specification.JSON, true, context.temp_allocator)
	o, _ := v.(json.Object)
	return o
}

// Prints the last answer as it is (--json, or a command with no friendlier form).
print_answer :: proc(ctx: ^Context) { outln(ctx.s.result) }

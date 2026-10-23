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
import "wb:desktop"
import "wb:remote"

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
	conn:            Conn,
	default_profile: string,   // the profile folder a Wren without --profile uses
	exe:             string,   // this executable
	connected:       bool,
	timeout_ms:      int,
}

// Options that take a value; every other `--name` must be in BOOL_OPTIONS.
@(private) VALUE_OPTIONS := [?]string{"remote", "profile", "timeout", "tab-id", "wait", "selector", "rect", "scale", "settle", "size", "dpi",
	"shot", "name", "out", "tolerance", "code", "button", "steps", "since", "dock", "state", "pos", "max-percent", "eval", "repeat", "speed",
	"panel", "limit", "settle-ms", "html", "pref", "cwd"}
@(private) BOOL_OPTIONS := [?]string{"json", "await", "tab", "window", "clear", "right", "double", "visible", "keep", "bytes", "help", "quiet",
	"headless", "middle", "all", "timing"}

out :: proc(s: string) { desktop.console_write(s) }
outln :: proc(s: string) { desktop.console_write(strings.concatenate({s, "\n"}, context.temp_allocator)) }
errln :: proc(s: string) { desktop.console_error(strings.concatenate({s, "\n"}, context.temp_allocator)) }

parse_options :: proc(args: []string) -> (o: Options, err: string) {
	o.vals = make(map[string]string, 8, context.temp_allocator)
	o.flags = make(map[string]bool, 8, context.temp_allocator)
	o.pos = make([dynamic]string, context.temp_allocator)
	o.prefs = make([dynamic]string, context.temp_allocator)
	only_positional := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if only_positional || len(a) < 3 || !strings.has_prefix(a, "--") { append(&o.pos, a); continue }
		if a == "--" { only_positional = true; continue }
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
	ctx := Context{o = o, default_profile = default_profile, exe = exe, timeout_ms = opt_int(&o, "timeout", 0)}
	defer if ctx.connected { disconnect(&ctx.conn) }
	return dispatch(&ctx, cmd, args)
}

// The name of the pipe to use: --remote, WREN_REMOTE, the folder given by --profile, else the default profile's.
resolve_name :: proc(ctx: ^Context) -> string {
	if n := opt(&ctx.o, "remote"); n != "" { return n }
	if n, ok := os.lookup_env("WREN_REMOTE", context.temp_allocator); ok && n != "" { return n }
	if p := opt(&ctx.o, "profile"); p != "" { return remote.profile_name(p) }
	return remote.profile_name(ctx.default_profile)
}

// Connects once (the commands that need the server call it): false after saying why.
need_server :: proc(ctx: ^Context) -> bool {
	if ctx.connected { return true }
	name := resolve_name(ctx)
	wait := opt_int(&ctx.o, "timeout", 0) > 0 ? min(opt_int(&ctx.o, "timeout", 0), 5000) : 300
	if !connect(&ctx.conn, name, wait) {
		errln(fmt.tprintf("wren ctl: no Wren answers on %s. Start one with `wren ctl start` (or `wren --remote`), or name it with --remote <name>.", remote.pipe_path(name)))
		return false
	}
	ctx.connected = true
	return true
}

// How long this call may wait for its answer: the command's own limit plus a margin for the server's timeout to come first.
call_timeout :: proc(ctx: ^Context) -> int {
	if ctx.timeout_ms > 0 { return ctx.timeout_ms + 5000 }
	return 60_000
}

// One request. On failure the message is printed and `code` is the exit code (0: it worked and `rep.result` is its answer).
request :: proc(ctx: ^Context, method, params: string) -> (rep: Reply, code: int) {
	if !need_server(ctx) { return {}, EXIT_NO_SERVER }
	p := params
	if ctx.timeout_ms > 0 && !strings.contains(p, `"timeout"`) {
		p = p == "" || p == "{}" ? fmt.tprintf(`{{"timeout":%d}}`, ctx.timeout_ms) : strings.concatenate({p[:len(p) - 1], fmt.tprintf(`,"timeout":%d}}`, ctx.timeout_ms)}, context.temp_allocator)
	}
	r, e := call(&ctx.conn, method, p, call_timeout(ctx))
	switch e {
	case .None: return r, 0
	case .Server:
		errln(fmt.tprintf("error: %s", r.message))
		if r.data != "" { errln(r.data) }
		return r, r.code == remote.ERR_TIMEOUT ? EXIT_TIMEOUT : (r.code == remote.ERR_METHOD || r.code == remote.ERR_PARAMS) ? EXIT_FAILED : EXIT_FAILED
	case .Timeout: errln("error: no answer in time"); return {}, EXIT_TIMEOUT
	case .Closed, .No_Server: errln("error: the connection to Wren ended"); return {}, EXIT_NO_SERVER
	}
	return {}, EXIT_FAILED
}

// Parses an answer for a command that prints parts of it.
parse_result :: proc(rep: Reply) -> json.Object {
	v, _ := json.parse(transmute([]byte)rep.result, json.Specification.JSON, true, context.temp_allocator)
	o, _ := v.(json.Object)
	return o
}

// Prints `rep.result` as it is (--json, or a command with no friendlier form).
print_json :: proc(rep: Reply) { outln(rep.result) }

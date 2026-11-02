package client

// The commands: arguments in, one call of the typed API (wb:remote/api), what it says out. No request is written here.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:remote"
import "wb:remote/api"

// What `--steps`, `--count` and the like are when not given.
DEFAULT_DRAG_STEPS :: api.DRAG_STEPS
DEFAULT_QUERY_LIMIT :: 20
DEFAULT_TIMELINE_SCALE :: 0.3
DEFAULT_TIMELINE_COUNT :: 240
DEFAULT_TIMELINE_COLS :: 6
MAX_SHOT_COUNT :: 10_000
// No limit of the API's own: the browser's, or --timeout.
NO_DEADLINE :: time.Duration(0)

@(private)
abs_path :: proc(p: string) -> string {
	if p == "" { return p }
	return remote.full_path(p)
}

// "x,y" or "x,y,w,h" as numbers.
@(private)
parse_numbers :: proc(s: string, n: int) -> (v: [4]f64, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != n { return {}, false }
	for p, i in parts {
		f, good := strconv.parse_f64(strings.trim_space(p))
		if !good { return {}, false }
		v[i] = f
	}
	return v, true
}

@(private)
usage :: proc(cmd, text: string) -> int {
	errln(fmt.tprintf("wren ctl %s: %s", cmd, text))
	return EXIT_USAGE
}

@(private)
wait_option :: proc(ctx: ^Context, default: string) -> (api.Wait, bool) {
	w, ok := api.wait_by_name(opt(&ctx.o, "wait", default))
	if !ok { errln("wren ctl: --wait is none, load, idle, stable or quiet") }
	return w, ok
}

@(private)
space_option :: proc(ctx: ^Context) -> api.Space { return flag(&ctx.o, "window") ? .Window : .Page }

@(private)
button_option :: proc(ctx: ^Context) -> api.Button { return flag(&ctx.o, "right") ? .Right : flag(&ctx.o, "middle") ? .Middle : .Left }

dispatch :: proc(ctx: ^Context, cmd: string, args: []string) -> int {
	s := &ctx.s
	switch cmd {
	case "run":      return cmd_run(ctx, args)
	case "start":    return cmd_start(ctx, args)
	case "stop":     return cmd_stop(ctx, args)
	case "diff":     return cmd_diff(ctx, args)
	case "stacks":   return cmd_stacks(ctx, args)
	case "ping":     _, e := api.ping(s); return simple(ctx, e)
	case "version":  _, e := api.version(s); return simple(ctx, e)
	case "nav", "navigate", "open":
		if len(args) != 1 { return usage(cmd, "usage: nav <url> [--wait load|idle|stable|none]") }
		w, ok := wait_option(ctx, "load")
		if !ok { return EXIT_USAGE }
		return show(ctx, api.navigate(s, args[0], w, NO_DEADLINE), "url")
	case "reload":
		w, ok := wait_option(ctx, "load")
		if !ok { return EXIT_USAGE }
		return show(ctx, api.reload(s, w, false, NO_DEADLINE), "")
	case "back", "forward":
		w, ok := wait_option(ctx, "load")
		if !ok { return EXIT_USAGE }
		return show(ctx, cmd == "back" ? api.go_back(s, w, NO_DEADLINE) : api.go_forward(s, w, NO_DEADLINE), "")
	case "cancel":   return simple(ctx, api.stop_loading(s))
	case "shot", "screenshot": return cmd_shot(ctx, args)
	case "eval":     return cmd_eval(ctx, args)
	case "click":    return cmd_click(ctx, args)
	case "drag":     return cmd_drag(ctx, args)
	case "drop":     return cmd_drop(ctx, args)
	case "hover":
		if len(args) != 1 { return usage(cmd, "usage: hover x,y [--window]") }
		v, ok := parse_numbers(args[0], 2)
		if !ok { return usage(cmd, "usage: hover x,y [--window]") }
		return simple(ctx, api.hover(s, {v[0], v[1]}, space_option(ctx)))
	case "scroll":   return cmd_scroll(ctx, args)
	case "type":
		if len(args) == 0 { return usage(cmd, "usage: type <text>") }
		return simple(ctx, api.type_text(s, strings.join(args, " ", context.temp_allocator)))
	case "key":
		if len(args) == 0 { return usage(cmd, "usage: key <combo>... (Enter, Ctrl+L, Shift+Tab, F5, a)") }
		return simple(ctx, api.key(s, strings.join(args, " ", context.temp_allocator), opt_int(&ctx.o, "repeat", 1)))
	case "wait":     return cmd_wait(ctx, args)
	case "console":  return cmd_console(ctx)
	case "network":  return cmd_network(ctx)
	case "stats":    return cmd_stats(ctx)
	case "pref", "prefs": return cmd_pref(ctx, args)
	case "tabs":     return cmd_tabs(ctx)
	case "tab":      return cmd_tab(ctx, args)
	case "window":   return cmd_window(ctx)
	case "windows":  return cmd_windows(ctx)
	case "reset":    return cmd_reset(ctx, args)
	case "checkpoint": return cmd_checkpoint(ctx, args)
	case "cmds":     return cmd_cmds(ctx, args)
	case "cmd":
		if len(args) != 1 { return usage(cmd, "usage: cmd <name>   (wren ctl cmds lists the names)") }
		return simple(ctx, api.run_command(s, args[0]))
	case "devtools":
		return simple(ctx, api.open_devtools(s, len(args) > 0 ? args[0] : "console", opt(&ctx.o, "dock", "")))
	case "setup":    return simple(ctx, api.open_setup(s))
	case "html":
		text, e := api.outer_html(s, len(args) > 0 ? args[0] : "")
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		outln(text)
		return 0
	case "query":
		if len(args) != 1 { return usage(cmd, "usage: query <selector>") }
		_, e := api.query_all(s, args[0], opt_int(&ctx.o, "limit", DEFAULT_QUERY_LIMIT))
		return simple(ctx, e)
	case "box":
		if len(args) != 1 { return usage(cmd, "usage: box <selector>") }
		_, e := api.box_model(s, args[0])
		return simple(ctx, e)
	case "style":
		if len(args) < 1 { return usage(cmd, "usage: style <selector> [property...]") }
		_, e := api.computed_style(s, args[0], len(args) > 1 ? args[1:] : nil)
		return simple(ctx, e)
	case "snapshot":
		if len(args) != 1 { return usage(cmd, "usage: snapshot <path-prefix>   (writes <prefix>.png, .html and .json)") }
		return simple(ctx, api.snapshot(s, abs_path(args[0]), flag(&ctx.o, "tab")))
	case "record":   return cmd_record(ctx, args)
	case "timeline": return cmd_timeline(ctx, args)
	case "replay":   return cmd_replay(ctx, args)
	case "quit", "close": return cmd_quit(ctx)
	case "raw":
		if len(args) != 1 { return usage(cmd, `usage: raw '{"method":"Page.navigate","params":{"url":"about:blank"}}'`) }
		v, err := json.parse(transmute([]byte)args[0], json.Specification.JSON, true, context.temp_allocator)
		obj, ok := v.(json.Object)
		method, has := remote.param_string(obj, "method")
		if err != .None || !ok || !has { return usage(cmd, "the argument is a JSON object with a \"method\"") }
		params := "{}"
		if p, has_p := obj["params"]; has_p { if t, e := json.marshal(p, {}, context.temp_allocator); e == nil { params = string(t) } }
		if _, e := api.call_raw(s, method, params, ctx.s.timeout_ms); e != .None { return failed(ctx, e) }
		print_answer(ctx)
		return 0
	}
	errln(fmt.tprintf("wren ctl: unknown command %q (wren ctl help)", cmd))
	return EXIT_USAGE
}

// What a call ended in, for a command whose answer is shown as JSON.
@(private)
simple :: proc(ctx: ^Context, e: api.Error) -> int {
	if e != .None { return failed(ctx, e) }
	if !flag(&ctx.o, "quiet") { print_answer(ctx) }
	return 0
}

// ... for one whose answer is the text of one of its fields (or its JSON with --json, or nothing).
@(private)
show :: proc(ctx: ^Context, e: api.Error, field: string) -> int {
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	if field != "" { if t, ok := api.answer_string(&ctx.s, field); ok { outln(t) } }
	return 0
}

// shot <file.png> [--count n [--interval ms]]: with --count the files are numbered (a "%d" in the name takes the number, else "-<n>"
// goes before the extension), taken one after the other over this one connection (a process per picture is 100 ms of start each).
@(private)
cmd_shot :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 1 { return usage("shot", "usage: shot <file.png> [--tab|--window|--rect x,y,w,h|--selector css] [--scale n] [--settle frames] [--count n [--interval ms]]") }
	count := opt_int(&ctx.o, "count", 1)
	if count < 1 || count > MAX_SHOT_COUNT { return usage("shot", "--count is 1 to 10000") }
	if count == 1 { return shot_one(ctx, args[0]) }
	interval := time.Duration(opt_int(&ctx.o, "interval", 0)) * time.Millisecond
	for i in 0 ..< count {
		if code := shot_one(ctx, numbered_name(args[0], i, count)); code != 0 { return code }
		if interval > 0 && i + 1 < count { time.sleep(interval) }
	}
	return 0
}

// `name` for picture `i` of `count`: "%d" replaced by the number, else the number before the extension (zero padded to the width of count).
numbered_name :: proc(name: string, i, count: int) -> string {
	width := len(fmt.tprintf("%d", count - 1))
	num := fmt.tprintf("%0*d", width, i)
	if strings.contains(name, "%d") {
		s, _ := strings.replace(name, "%d", num, 1, context.temp_allocator)
		return s
	}
	dot := strings.last_index_byte(name, '.')
	if dot <= max(strings.last_index_any(name, "\\/"), 0) { return strings.concatenate({name, "-", num}, context.temp_allocator) }
	return strings.concatenate({name[:dot], "-", num, name[dot:]}, context.temp_allocator)
}

@(private)
shot_one :: proc(ctx: ^Context, file: string) -> int {
	o: api.Shot_Options
	switch {
	case opt(&ctx.o, "selector") != "":
		o.target, o.selector = .Selector, opt(&ctx.o, "selector")
	case opt(&ctx.o, "rect") != "":
		r, ok := parse_numbers(opt(&ctx.o, "rect"), 4)
		if !ok { return usage("shot", "--rect x,y,w,h (window pixels)") }
		o.target, o.rect = .Rect, {r[0], r[1], r[2], r[3]}
	case flag(&ctx.o, "tab"): o.target = .Page
	}
	if t := opt(&ctx.o, "scale"); t != "" { o.scale, _ = strconv.parse_f64(t) }
	if t := opt(&ctx.o, "settle"); t != "" { o.settle = opt_int(&ctx.o, "settle", 0); o.has_settle = true }
	r, e := api.screenshot(&ctx.s, abs_path(file), o)
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	outln(fmt.tprintf("%s %dx%d", r.path, r.width, r.height))
	return 0
}

@(private)
cmd_eval :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("eval", "usage: eval <javascript> [--await]") }
	v, e := api.eval_value(&ctx.s, strings.join(args, " ", context.temp_allocator), flag(&ctx.o, "await"), NO_DEADLINE)
	if e == .Script {
		// (with --json the whole answer, as it came)
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		errln(api.last_failure().message)
		return EXIT_FAILED
	}
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	if v.kind != "undefined" { outln(v.text) }
	return 0
}

@(private)
cmd_click :: proc(ctx: ^Context, args: []string) -> int {
	button, count := button_option(ctx), flag(&ctx.o, "double") ? 2 : 1
	if sel := opt(&ctx.o, "selector"); sel != "" { return simple(ctx, api.click(&ctx.s, sel, button, count)) }
	if len(args) != 1 { return usage("click", "usage: click x,y (page pixels; --window for window pixels) | click --selector css") }
	v, ok := parse_numbers(args[0], 2)
	if !ok { return usage("click", "usage: click x,y | click --selector css") }
	return simple(ctx, api.click_at(&ctx.s, {v[0], v[1]}, space_option(ctx), button, count))
}

// drop [files...] --at x,y [--text t] [--url u] [--html h] [--leave]: another application's drag dropped on the window
// (the files are made absolute from the caller's folder).
@(private)
cmd_drop :: proc(ctx: ^Context, args: []string) -> int {
	at, ok := parse_numbers(opt(&ctx.o, "at", "200,200"), 2)
	if !ok { return usage("drop", "usage: drop [files...] --at x,y [--text t] [--url u] [--html h] [--leave]") }
	if len(args) == 0 && opt(&ctx.o, "text") == "" && opt(&ctx.o, "url") == "" && opt(&ctx.o, "html") == "" { return usage("drop", "give files, --text, --url or --html") }
	files := make([]string, len(args), context.temp_allocator)
	for f, i in args {
		full, err := filepath.abs(f, context.temp_allocator)
		files[i] = err != nil ? f : full
	}
	return simple(ctx, api.drop(&ctx.s, {at[0], at[1]}, {files = files, text = opt(&ctx.o, "text"), url = opt(&ctx.o, "url"), html = opt(&ctx.o, "html")}, space_option(ctx), flag(&ctx.o, "leave")))
}

@(private)
cmd_drag :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) < 2 { return usage("drag", "usage: drag x,y [via-x,via-y ...] x2,y2 [--steps n]") }
	a, ok1 := parse_numbers(args[0], 2)
	z, ok2 := parse_numbers(args[len(args) - 1], 2)
	if !ok1 || !ok2 { return usage("drag", "usage: drag x,y [via-x,via-y ...] x2,y2") }
	via := make([dynamic]api.Point, context.temp_allocator)
	for mid in args[1:len(args) - 1] {
		v, ok := parse_numbers(mid, 2)
		if !ok { return usage("drag", "every point is x,y") }
		append(&via, api.Point{v[0], v[1]})
	}
	return simple(ctx, api.drag(&ctx.s, {a[0], a[1]}, {z[0], z[1]}, {via = via[:], steps = opt_int(&ctx.o, "steps", DEFAULT_DRAG_STEPS), space = space_option(ctx), hold = flag(&ctx.o, "hold"), resume = flag(&ctx.o, "resume")}))
}

// scroll <notches> [x,y]: the wheel; positive goes down. Without a point, the middle of the page area.
@(private)
cmd_scroll :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) < 1 { return usage("scroll", "usage: scroll <notches> [x,y]   (one notch is 100 px; negative goes up)") }
	n, ok := strconv.parse_f64(args[0])
	if !ok { return usage("scroll", "usage: scroll <notches> [x,y]") }
	at := api.Point{api.SCROLL_X, api.SCROLL_Y}
	if len(args) > 1 {
		v, good := parse_numbers(args[1], 2)
		if !good { return usage("scroll", "the point is x,y") }
		at = {v[0], v[1]}
	}
	return simple(ctx, api.scroll(&ctx.s, n, at))
}

@(private)
cmd_wait :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) < 1 { return usage("wait", "usage: wait load|idle|stable|quiet | wait selector <css> [--visible] | wait function <js> | wait frames [n]") }
	s := &ctx.s
	switch args[0] {
	case "selector":
		if len(args) != 2 { return usage("wait", "wait selector <css>") }
		return simple(ctx, api.wait_selector(s, args[1], flag(&ctx.o, "visible"), NO_DEADLINE))
	case "function":
		if len(args) < 2 { return usage("wait", "wait function <js>") }
		return simple(ctx, api.wait_js(s, strings.join(args[1:], " ", context.temp_allocator), NO_DEADLINE))
	case "frames":
		n := 2
		if len(args) > 1 { n, _ = strconv.parse_int(args[1]) }
		return simple(ctx, api.wait_frames(s, n, NO_DEADLINE))
	case "load":   return simple(ctx, api.wait_load(s, NO_DEADLINE))
	case "idle":   return simple(ctx, api.wait_idle(s, NO_DEADLINE))
	case "stable": return simple(ctx, api.wait_stable(s, NO_DEADLINE))
	case "quiet":
		cpu := 0.0
		if t := opt(&ctx.o, "max-cpu"); t != "" { cpu, _ = strconv.parse_f64(t) }
		return simple(ctx, api.wait_quiet(s, opt_int(&ctx.o, "quiet-ms", 0), cpu, NO_DEADLINE))
	}
	return usage("wait", "wait load|idle|stable|quiet|selector|function|frames")
}

@(private)
cmd_console :: proc(ctx: ^Context) -> int {
	lines, e := api.console(&ctx.s, opt_int(&ctx.o, "since", 0), flag(&ctx.o, "clear"))
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	for l in lines { outln(l.level == "log" ? l.text : fmt.tprintf("%s: %s", l.level, l.text)) }
	return 0
}

@(private)
cmd_network :: proc(ctx: ^Context) -> int {
	net, e := api.network(&ctx.s, flag(&ctx.o, "clear"))
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	for r in net.requests {
		st := r.failed ? "FAIL" : r.status == 0 ? "..." : fmt.tprintf("%d", r.status)
		outln(fmt.tprintf("%-4s %-6s %-9s %8d B %7s  %s%s", st, r.method, r.mime == "" ? "-" : r.mime, r.bytes, r.has_ms ? fmt.tprintf("%.0f ms", r.ms) : "-", r.url, r.failed ? fmt.tprintf("  (%s)", r.error) : ""))
	}
	return 0
}

@(private)
cmd_stats :: proc(ctx: ^Context) -> int {
	_, e := api.stats(&ctx.s, flag(&ctx.o, "reset-latency"), flag(&ctx.o, "reset-frames"))
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	for k, v in parse_result(ctx.s.result) {
		t, _ := json.marshal(v, {}, context.temp_allocator)
		outln(fmt.tprintf("%s: %s", k, string(t)))
	}
	return 0
}

@(private)
cmd_pref :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("pref", "usage: pref get <name> | pref set <name> <value> [--override] | pref reset <name> | pref reset --all | pref list [prefix]") }
	s := &ctx.s
	text_answer :: proc(ctx: ^Context, text: string, e: api.Error) -> int {
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		outln(text)
		return 0
	}
	switch args[0] {
	case "get":
		if len(args) != 2 { return usage("pref", "usage: pref get <name>") }
		t, e := api.pref_get(s, args[1])
		return text_answer(ctx, t, e)
	case "set":
		if len(args) != 3 { return usage("pref", "usage: pref set <name> <value>") }
		t, e := api.pref_set(s, args[1], args[2], flag(&ctx.o, "override"))
		return text_answer(ctx, t, e)
	case "reset":
		if flag(&ctx.o, "all") {
			if len(args) != 1 { return usage("pref", "usage: pref reset <name> | pref reset --all") }
			n, e := api.pref_reset_all(s)
			return text_answer(ctx, fmt.tprintf("%d preference(s) put back", n), e)
		}
		if len(args) != 2 { return usage("pref", "usage: pref reset <name> | pref reset --all") }
		t, e := api.pref_reset(s, args[1])
		return text_answer(ctx, t, e)
	case "list":
		prefs, e := api.pref_list(s, len(args) > 1 ? args[1] : "")
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		for p in prefs { outln(fmt.tprintf("%s = %s", p.name, p.text)) }
		return 0
	}
	return usage("pref", "get, set, reset or list")
}

@(private)
cmd_tabs :: proc(ctx: ^Context) -> int {
	r, e := api.targets(&ctx.s)
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	for t in r.tabs { outln(fmt.tprintf("%d%s w%d %s%s  %s", t.id, t.active ? "*" : " ", t.window, t.loading ? "[loading] " : "", t.title, t.url)) }
	return 0
}

// windows: one line per window (id, * for the front one, tabs, the current tab, size).
@(private)
cmd_windows :: proc(ctx: ^Context) -> int {
	list, e := api.windows(&ctx.s)
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	for w in list { outln(fmt.tprintf("%d%s %d tab(s), current %d, %dx%d %s", w.id, w.front ? "*" : " ", w.tabs, w.current_tab, w.width, w.height, w.state)) }
	return 0
}

@(private)
cmd_tab :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("tab", "usage: tab new [url] | tab activate <id> | tab close <id> | tab move <id> --to new|<window id> [--index n]") }
	s := &ctx.s
	switch args[0] {
	case "new":
		w, ok := wait_option(ctx, "none")
		if !ok { return EXIT_USAGE }
		id, e := api.new_tab(s, len(args) > 1 ? args[1] : "", w, false, NO_DEADLINE)
		if e != .None { return failed(ctx, e) }
		outln(fmt.tprintf("%d", id))
		return 0
	case "activate", "close":
		if len(args) != 2 { return usage("tab", "tab activate|close <id>") }
		id, _ := strconv.parse_int(args[1])
		return simple(ctx, args[0] == "activate" ? api.activate_tab(s, id) : api.close_tab(s, id))
	case "move":
		if len(args) != 2 || opt(&ctx.o, "to") == "" { return usage("tab", "tab move <id> --to new|<window id> [--index n]") }
		id, _ := strconv.parse_int(args[1])
		to := opt(&ctx.o, "to")
		index := opt_int(&ctx.o, "index", -1)
		wid: int
		e: api.Error
		if to == "new" {
			wid, e = api.move_tab_to_new_window(s, id, index)
		} else {
			dest, _ := strconv.parse_int(to)
			wid, e = api.move_tab(s, id, dest, index)
		}
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		outln(fmt.tprintf("%d", wid))
		return 0
	}
	return usage("tab", "new, activate, close or move")
}

@(private)
cmd_window :: proc(ctx: ^Context) -> int {
	// (the window: --win-id, else the front one)
	s := &ctx.s
	if flag(&ctx.o, "front") { return simple(ctx, api.bring_to_front(s)) }
	if flag(&ctx.o, "close") { return simple(ctx, api.close_window(s)) }
	c: api.Window_Change
	asked := false
	if t := opt(&ctx.o, "size"); t != "" {
		w, h, ok := parse_size(t)
		if !ok { return usage("window", "--size WxH") }
		c.size, asked = [2]int{w, h}, true
	}
	if t := opt(&ctx.o, "pos"); t != "" {
		v, ok := parse_numbers(t, 2)
		if !ok { return usage("window", "--pos x,y") }
		c.pos, asked = [2]int{int(v[0]), int(v[1])}, true
	}
	if t := opt(&ctx.o, "state"); t != "" { c.state, asked = t, true }
	if t := opt(&ctx.o, "dpi"); t != "" {   // (the window as if moved to a monitor of that scale: WM_DPICHANGED)
		v, ok := parse_float(t)
		if !ok || v <= 0 { return usage("window", "--dpi n (96 = 100 %, 144 = 150 %)") }
		c.dpi, asked = int(v + 0.5), true
	}
	if !asked { _, e := api.window_bounds(s); return simple(ctx, e) }
	_, e := api.set_window(s, c)
	return simple(ctx, e)
}

parse_size :: proc(s: string) -> (w, h: int, ok: bool) {
	x := strings.index_any(s, "xX")
	if x <= 0 { return }
	w, ok = strconv.parse_int(s[:x])
	if !ok { return }
	h, ok = strconv.parse_int(s[x + 1:])
	return w, h, ok && w > 0 && h > 0
}

@(private)
cmd_cmds :: proc(ctx: ^Context, args: []string) -> int {
	list, e := api.commands(&ctx.s)
	if e != .None { return failed(ctx, e) }
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	filter := len(args) > 0 ? strings.to_lower(args[0], context.temp_allocator) : ""
	for c in list {
		line := fmt.tprintf("%-34s %s%s%s", c.name, c.title, c.shortcut != "" ? fmt.tprintf("  [%s]", c.shortcut) : "", c.enabled ? "" : "  (not now)")
		if filter == "" || strings.contains(strings.to_lower(line, context.temp_allocator), filter) { outln(line) }
	}
	return 0
}

@(private)
cmd_record :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("record", "usage: record start | record stop <file.json>") }
	switch args[0] {
	case "start": return simple(ctx, api.record_start(&ctx.s))
	case "stop":
		if len(args) != 2 { return usage("record", "usage: record stop <file.json>") }
		text, n, e := api.record_stop(&ctx.s)
		if e != .None { return failed(ctx, e) }
		if err := os.write_entire_file(abs_path(args[1]), transmute([]byte)text); err != nil { errln("cannot write the file"); return EXIT_FAILED }
		outln(fmt.tprintf("%d events -> %s", n, abs_path(args[1])))
		return 0
	}
	return usage("record", "start or stop")
}

@(private)
cmd_timeline :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("timeline", "usage: timeline start [--scale s] [--count n] [--tab] | timeline stop <folder> [--cols n] [--all]") }
	s := &ctx.s
	switch args[0] {
	case "start":
		scale := DEFAULT_TIMELINE_SCALE
		if t := opt(&ctx.o, "scale"); t != "" { scale, _ = strconv.parse_f64(t) }
		return simple(ctx, api.timeline_start(s, scale, opt_int(&ctx.o, "count", DEFAULT_TIMELINE_COUNT), flag(&ctx.o, "tab")))
	case "stop":
		if len(args) != 2 { return usage("timeline", "usage: timeline stop <folder> [--cols n] [--all]") }
		r, e := api.timeline_stop(s, abs_path(args[1]), opt_int(&ctx.o, "cols", DEFAULT_TIMELINE_COLS), flag(&ctx.o, "all"))
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		outln(fmt.tprintf("%d frames (%d of the chrome's, %d A-B-A: a frame unlike both its neighbours, which are alike) -> %s", r.count, r.chrome, r.aba, args[1]))
		outln(fmt.tprintf("contact sheet: %s   (red frame: A-B-A, orange: a chrome frame; the folder has every frame and timeline.json)", r.sheet))
		return 0
	case "status": return simple(ctx, api.timeline_status(s))
	}
	return usage("timeline", "start, stop or status")
}

@(private)
cmd_replay :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 1 { return usage("replay", "usage: replay <file.json> [--speed n]") }
	data, err := os.read_entire_file(abs_path(args[0]), context.temp_allocator)
	if err != nil { errln("cannot read the file"); return EXIT_FAILED }
	v, perr := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	if perr != .None || !ok { errln("the file is not a recording"); return EXIT_FAILED }
	evs, _ := json.marshal(obj["events"], {}, context.temp_allocator)
	speed := 1.0
	if t := opt(&ctx.o, "speed"); t != "" { speed, _ = strconv.parse_f64(t) }
	return simple(ctx, api.replay(&ctx.s, string(evs), speed))
}

@(private)
cmd_stacks :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 1 { return usage("stacks", "usage: stacks <process id> [--out file.txt] [--dump file.dmp]") }
	pid, good := strconv.parse_int(args[0])
	if !good { return usage("stacks", "the process id is a number") }
	text, ok := api.process_stacks(pid, abs_path(opt(&ctx.o, "dump")))
	if !ok { errln(text); return EXIT_FAILED }
	path := opt(&ctx.o, "out")
	if path == "" { outln(text); return EXIT_OK }
	if err := os.write_entire_file(abs_path(path), transmute([]byte)text); err != nil { errln(fmt.tprintf("cannot write %s", path)); return EXIT_FAILED }
	return EXIT_OK
}

@(private)
cmd_quit :: proc(ctx: ^Context) -> int {
	exit, e := api.quit(&ctx.s, opt_int(&ctx.o, "code", 0))
	if e != .None { return failed(ctx, e) }
	if !flag(&ctx.o, "quiet") { outln(fmt.tprintf("exit code %d", exit)) }
	return 0
}

// reset [--keep tabs,data,prefs,window,history] [--url address] [--wait load|idle|quiet|none]
@(private)
cmd_reset :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 0 { return usage("reset", "usage: reset [--keep tabs,data,prefs,window,history] [--url address] [--wait load|idle|stable|quiet|none]") }
	w, ok := wait_option(ctx, "load")
	if !ok { return EXIT_USAGE }
	r, e := api.reset(&ctx.s, opt(&ctx.o, "keep"), opt(&ctx.o, "url"), w)
	if e != .None { return failed(ctx, e) }
	return show_reset(ctx, r)
}

@(private)
show_reset :: proc(ctx: ^Context, r: api.Reset_Report) -> int {
	if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
	if flag(&ctx.o, "quiet") { return 0 }
	outln(fmt.tprintf("%d tab(s) closed, %d cookie(s), %d site(s) of storage, %d cached response(s), %d visit(s) of history, %d preference(s) put back%s, %d command(s) cancelled",
		r.closed_tabs, r.cookies, r.sites, r.cache_entries, r.history_visits, r.prefs_restored, r.window_restored ? ", the window put back" : "", r.cancelled_ops))
	return 0
}

// checkpoint save|restore|delete <name> | checkpoint list
@(private)
cmd_checkpoint :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 || (args[0] == "list" && len(args) != 1) || (args[0] != "list" && len(args) != 2) {
		return usage("checkpoint", "usage: checkpoint save <name> | checkpoint restore <name> [--wait ...] | checkpoint delete <name> | checkpoint list")
	}
	s := &ctx.s
	switch args[0] {
	case "save":
		r, e := api.checkpoint_save(s, args[1])
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		outln(fmt.tprintf("%s: %d tab(s), %d cookie(s), localStorage of %d origin(s)", args[1], r.tabs, r.cookies, r.storage_origins))
		return 0
	case "delete":
		e := api.checkpoint_delete(s, args[1])
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx) }
		return 0
	case "restore":
		w, ok := wait_option(ctx, "load")
		if !ok { return EXIT_USAGE }
		r, e := api.checkpoint_restore(s, args[1], w)
		if e != .None { return failed(ctx, e) }
		return show_reset(ctx, r)
	case "list":
		list, e := api.checkpoint_list(s)
		if e != .None { return failed(ctx, e) }
		if flag(&ctx.o, "json") { print_answer(ctx); return 0 }
		for c in list { outln(fmt.tprintf("%-20s %d tab(s), %d cookie(s), localStorage of %d origin(s)", c.name, c.tabs, c.cookies, c.storage_origins)) }
		return 0
	}
	return usage("checkpoint", "save, restore, delete or list")
}

package client

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:remote"

q :: remote.quote

// {"tabId": n} when --tab-id was given.
@(private)
tab_param :: proc(ctx: ^Context) -> string {
	if id := opt(&ctx.o, "tab-id"); id != "" { return fmt.tprintf(`"tabId":%s,`, id) }
	return ""
}

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

dispatch :: proc(ctx: ^Context, cmd: string, args: []string) -> int {
	switch cmd {
	case "run":      return cmd_run(ctx, args)
	case "start":    return cmd_start(ctx, args)
	case "stop":     return cmd_stop(ctx, args)
	case "diff":     return cmd_diff(ctx, args)
	case "ping":     return simple(ctx, "Remote.ping", "{}")
	case "version":  return simple(ctx, "Browser.getVersion", "{}")
	case "nav", "navigate", "open":
		if len(args) != 1 { return usage(cmd, "usage: nav <url> [--wait load|idle|stable|none]") }
		rep, code := request(ctx, "Page.navigate", fmt.tprintf(`{{%s"url":%s,"wait":%s}}`, tab_param(ctx), q(args[0]), q(opt(&ctx.o, "wait", "load"))))
		if code != 0 { return code }
		return show(ctx, rep, "url")
	case "reload":
		rep, code := request(ctx, "Page.reload", fmt.tprintf(`{{%s"wait":%s}}`, tab_param(ctx), q(opt(&ctx.o, "wait", "load"))))
		if code != 0 { return code }
		return show(ctx, rep, "")
	case "back", "forward":
		rep, code := request(ctx, cmd == "back" ? "Page.goBack" : "Page.goForward", fmt.tprintf(`{{%s"wait":%s}}`, tab_param(ctx), q(opt(&ctx.o, "wait", "load"))))
		if code != 0 { return code }
		return show(ctx, rep, "")
	case "cancel":   return simple(ctx, "Page.stopLoading", fmt.tprintf(`{{%s"x":0}}`, tab_param(ctx)))
	case "shot", "screenshot": return cmd_shot(ctx, args)
	case "eval":     return cmd_eval(ctx, args)
	case "click":    return cmd_click(ctx, args)
	case "drag":     return cmd_drag(ctx, args)
	case "drop":     return cmd_drop(ctx, args)
	case "hover":
		if len(args) != 1 { return usage(cmd, "usage: hover x,y [--window]") }
		v, ok := parse_numbers(args[0], 2)
		if !ok { return usage(cmd, "usage: hover x,y [--window]") }
		return simple(ctx, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseMoved","x":%v,"y":%v,"space":%s}}`, v[0], v[1], q(flag(&ctx.o, "window") ? "window" : "page")))
	case "scroll":   return cmd_scroll(ctx, args)
	case "type":
		if len(args) == 0 { return usage(cmd, "usage: type <text>") }
		return simple(ctx, "Wren.type", fmt.tprintf(`{{"text":%s}}`, q(strings.join(args, " ", context.temp_allocator))))
	case "key":
		if len(args) == 0 { return usage(cmd, "usage: key <combo>... (Enter, Ctrl+L, Shift+Tab, F5, a)") }
		return simple(ctx, "Wren.key", fmt.tprintf(`{{"keys":%s,"repeat":%d}}`, q(strings.join(args, " ", context.temp_allocator)), opt_int(&ctx.o, "repeat", 1)))
	case "wait":     return cmd_wait(ctx, args)
	case "console":  return cmd_console(ctx)
	case "network":  return cmd_network(ctx)
	case "stats":    return cmd_stats(ctx)
	case "pref", "prefs": return cmd_pref(ctx, args)
	case "tabs":     return cmd_tabs(ctx)
	case "tab":      return cmd_tab(ctx, args)
	case "window":   return cmd_window(ctx)
	case "reset":    return cmd_reset(ctx, args)
	case "checkpoint": return cmd_checkpoint(ctx, args)
	case "cmds":     return cmd_cmds(ctx, args)
	case "cmd":
		if len(args) != 1 { return usage(cmd, "usage: cmd <name>   (wren ctl cmds lists the names)") }
		return simple(ctx, "Wren.runCommand", fmt.tprintf(`{{"name":%s}}`, q(args[0])))
	case "devtools":
		return simple(ctx, "Wren.openDevTools", fmt.tprintf(`{{"panel":%s,"dock":%s}}`, q(len(args) > 0 ? args[0] : "console"), q(opt(&ctx.o, "dock", ""))))
	case "setup":    return simple(ctx, "Wren.openSetup", "{}")
	case "html":
		rep, code := request(ctx, "DOM.getOuterHTML", fmt.tprintf(`{{%s"selector":%s}}`, tab_param(ctx), len(args) > 0 ? q(args[0]) : "null"))
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		s, _ := remote.param_string(parse_result(rep), "outerHTML")
		outln(s)
		return 0
	case "query":
		if len(args) != 1 { return usage(cmd, "usage: query <selector>") }
		return simple(ctx, "DOM.querySelectorAll", fmt.tprintf(`{{%s"selector":%s,"limit":%d}}`, tab_param(ctx), q(args[0]), opt_int(&ctx.o, "limit", 20)))
	case "box":
		if len(args) != 1 { return usage(cmd, "usage: box <selector>") }
		return simple(ctx, "DOM.getBoxModel", fmt.tprintf(`{{%s"selector":%s}}`, tab_param(ctx), q(args[0])))
	case "style":
		if len(args) < 1 { return usage(cmd, "usage: style <selector> [property...]") }
		props := "null"
		if len(args) > 1 {
			b := strings.builder_make(context.temp_allocator)
			strings.write_byte(&b, '[')
			for p, i in args[1:] { if i > 0 { strings.write_byte(&b, ',') }; remote.write_json_string(&b, p) }
			strings.write_byte(&b, ']')
			props = strings.to_string(b)
		}
		return simple(ctx, "CSS.getComputedStyleForNode", fmt.tprintf(`{{%s"selector":%s,"properties":%s}}`, tab_param(ctx), q(args[0]), props))
	case "snapshot":
		if len(args) != 1 { return usage(cmd, "usage: snapshot <path-prefix>   (writes <prefix>.png, .html and .json)") }
		return simple(ctx, "Wren.snapshot", fmt.tprintf(`{{%s"path":%s,"target":%s}}`, tab_param(ctx), q(abs_path(args[0])), q(flag(&ctx.o, "tab") ? "page" : "window")))
	case "record":   return cmd_record(ctx, args)
	case "replay":   return cmd_replay(ctx, args)
	case "quit", "close": return cmd_quit(ctx)
	case "raw":
		if len(args) != 1 { return usage(cmd, `usage: raw '{"method":"Page.navigate","params":{"url":"about:blank"}}'`) }
		v, err := json.parse(transmute([]byte)args[0], json.Specification.JSON, true, context.temp_allocator)
		obj, ok := v.(json.Object)
		method, has := remote.param_string(obj, "method")
		if err != .None || !ok || !has { return usage(cmd, "the argument is a JSON object with a \"method\"") }
		params := "{}"
		if p, has_p := obj["params"]; has_p { if s, e := json.marshal(p, {}, context.temp_allocator); e == nil { params = string(s) } }
		rep, code := request(ctx, method, params)
		if code != 0 { return code }
		print_json(rep)
		return 0
	}
	errln(fmt.tprintf("wren ctl: unknown command %q (wren ctl help)", cmd))
	return EXIT_USAGE
}

// A command whose answer is shown as JSON.
@(private)
simple :: proc(ctx: ^Context, method, params: string) -> int {
	rep, code := request(ctx, method, params)
	if code != 0 { return code }
	if !flag(&ctx.o, "quiet") { print_json(rep) }
	return 0
}

// An answer shown as the text of one of its fields (or its JSON with --json, or nothing).
@(private)
show :: proc(ctx: ^Context, rep: Reply, field: string) -> int {
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	if field != "" { if s, ok := remote.param_string(parse_result(rep), field); ok { outln(s) } }
	return 0
}

// shot <file.png> [--count n [--interval ms]]: with --count the files are numbered (a "%d" in the name takes the number, else "-<n>"
// goes before the extension), taken one after the other over this one connection (a process per picture is 100 ms of start each).
@(private)
cmd_shot :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 1 { return usage("shot", "usage: shot <file.png> [--tab|--window|--rect x,y,w,h|--selector css] [--scale n] [--settle frames] [--count n [--interval ms]]") }
	count := opt_int(&ctx.o, "count", 1)
	if count < 1 || count > 10_000 { return usage("shot", "--count is 1 to 10000") }
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
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{%s"path":%s`, tab_param(ctx), q(abs_path(file)))
	switch {
	case opt(&ctx.o, "selector") != "": fmt.sbprintf(&b, `,"target":"selector","selector":%s`, q(opt(&ctx.o, "selector")))
	case opt(&ctx.o, "rect") != "":
		r, ok := parse_numbers(opt(&ctx.o, "rect"), 4)
		if !ok { return usage("shot", "--rect x,y,w,h (window pixels)") }
		fmt.sbprintf(&b, `,"target":"rect","clip":{{"x":%v,"y":%v,"width":%v,"height":%v}}`, r[0], r[1], r[2], r[3])
	case flag(&ctx.o, "tab"): strings.write_string(&b, `,"target":"page"`)
	}
	if s := opt(&ctx.o, "scale"); s != "" { fmt.sbprintf(&b, `,"scale":%s`, s) }
	if s := opt(&ctx.o, "settle"); s != "" { fmt.sbprintf(&b, `,"settle":%s`, s) }
	strings.write_byte(&b, '}')
	rep, code := request(ctx, "Page.captureScreenshot", strings.to_string(b))
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	r := parse_result(rep)
	p, _ := remote.param_string(r, "path")
	w, _ := remote.param_int(r, "width"); h, _ := remote.param_int(r, "height")
	outln(fmt.tprintf("%s %dx%d", p, w, h))
	return 0
}

@(private)
cmd_eval :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("eval", "usage: eval <javascript> [--await]") }
	rep, code := request(ctx, "Runtime.evaluate", fmt.tprintf(`{{%s"expression":%s,"awaitPromise":%v}}`, tab_param(ctx), q(strings.join(args, " ", context.temp_allocator)), flag(&ctx.o, "await")))
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	r := parse_result(rep)
	if ex, has := remote.param_object(r, "exceptionDetails"); has {
		e, _ := remote.param_object(ex, "exception")
		d, _ := remote.param_string(e, "description")
		t, _ := remote.param_string(ex, "text")
		errln(d != "" ? d : t)
		return EXIT_FAILED
	}
	res, _ := remote.param_object(r, "result")
	t, _ := remote.param_string(res, "type")
	switch t {
	case "undefined": return 0
	case "string": s, _ := remote.param_string(res, "value"); outln(s)
	case:
		s, _ := json.marshal(res["value"], {}, context.temp_allocator)
		outln(string(s))
	}
	return 0
}

@(private)
cmd_click :: proc(ctx: ^Context, args: []string) -> int {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{%s"button":%s,"count":%d`, tab_param(ctx), q(flag(&ctx.o, "right") ? "right" : flag(&ctx.o, "middle") ? "middle" : "left"), flag(&ctx.o, "double") ? 2 : 1)
	if sel := opt(&ctx.o, "selector"); sel != "" {
		fmt.sbprintf(&b, `,"selector":%s`, q(sel))
	} else if len(args) == 1 {
		v, ok := parse_numbers(args[0], 2)
		if !ok { return usage("click", "usage: click x,y | click --selector css") }
		fmt.sbprintf(&b, `,"x":%v,"y":%v`, v[0], v[1])
		if flag(&ctx.o, "window") { strings.write_string(&b, `,"space":"window"`) }
	} else {
		return usage("click", "usage: click x,y (page pixels; --window for window pixels) | click --selector css")
	}
	strings.write_byte(&b, '}')
	return simple(ctx, "Wren.click", strings.to_string(b))
}

// drop [files...] --at x,y [--text t] [--url u] [--html h] [--leave]: another application's drag dropped on the window
// (the files are made absolute from the caller's folder).
@(private)
cmd_drop :: proc(ctx: ^Context, args: []string) -> int {
	at, ok := parse_numbers(opt(&ctx.o, "at", "200,200"), 2)
	if !ok { return usage("drop", "usage: drop [files...] --at x,y [--text t] [--url u] [--html h] [--leave]") }
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"x":%v,"y":%v,"space":%s,"files":[`, at[0], at[1], q(flag(&ctx.o, "window") ? "window" : "page"))
	for f, i in args {
		full, err := filepath.abs(f, context.temp_allocator)
		if err != nil { full = f }
		if i > 0 { strings.write_byte(&sb, ',') }
		strings.write_string(&sb, q(full))
	}
	fmt.sbprintf(&sb, `],"text":%s,"url":%s,"html":%s,"leave":%v}}`, q(opt(&ctx.o, "text")), q(opt(&ctx.o, "url")), q(opt(&ctx.o, "html")), flag(&ctx.o, "leave"))
	if len(args) == 0 && opt(&ctx.o, "text") == "" && opt(&ctx.o, "url") == "" && opt(&ctx.o, "html") == "" { return usage("drop", "give files, --text, --url or --html") }
	return simple(ctx, "Wren.drop", strings.to_string(sb))
}

@(private)
cmd_drag :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 2 { return usage("drag", "usage: drag x,y x2,y2 [--steps n]") }
	a, ok1 := parse_numbers(args[0], 2)
	z, ok2 := parse_numbers(args[1], 2)
	if !ok1 || !ok2 { return usage("drag", "usage: drag x,y x2,y2") }
	return simple(ctx, "Wren.drag", fmt.tprintf(`{{"x":%v,"y":%v,"toX":%v,"toY":%v,"steps":%d,"space":%s}}`, a[0], a[1], z[0], z[1], opt_int(&ctx.o, "steps", 8), q(flag(&ctx.o, "window") ? "window" : "page")))
}

// scroll <notches> [x,y]: the wheel; positive goes down. Without a point, the middle of the page area.
@(private)
cmd_scroll :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) < 1 { return usage("scroll", "usage: scroll <notches> [x,y]   (one notch is 100 px; negative goes up)") }
	n, ok := strconv.parse_f64(args[0])
	if !ok { return usage("scroll", "usage: scroll <notches> [x,y]") }
	x, y := 200.0, 200.0
	space := "page"
	if len(args) > 1 {
		v, good := parse_numbers(args[1], 2)
		if !good { return usage("scroll", "the point is x,y") }
		x, y = v[0], v[1]
	}
	return simple(ctx, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%v,"y":%v,"notches":%v,"space":%s}}`, x, y, n, q(space)))
}

@(private)
cmd_wait :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) < 1 { return usage("wait", "usage: wait load|idle|stable|quiet | wait selector <css> [--visible] | wait function <js> | wait frames [n]") }
	what := args[0]
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{%s"for":%s`, tab_param(ctx), q(what))
	switch what {
	case "selector": if len(args) != 2 { return usage("wait", "wait selector <css>") }; fmt.sbprintf(&b, `,"selector":%s,"visible":%v`, q(args[1]), flag(&ctx.o, "visible"))
	case "function": if len(args) < 2 { return usage("wait", "wait function <js>") }; fmt.sbprintf(&b, `,"expression":%s`, q(strings.join(args[1:], " ", context.temp_allocator)))
	case "frames":   if len(args) > 1 { fmt.sbprintf(&b, `,"frames":%s`, args[1]) }
	case "load", "idle", "stable":
	case "quiet":
		if s := opt(&ctx.o, "quiet-ms"); s != "" { fmt.sbprintf(&b, `,"quietMs":%s`, s) }
		if s := opt(&ctx.o, "max-cpu"); s != "" { fmt.sbprintf(&b, `,"maxCpuMs":%s`, s) }
	case: return usage("wait", "wait load|idle|stable|quiet|selector|function|frames")
	}
	strings.write_byte(&b, '}')
	return simple(ctx, "Wren.wait", strings.to_string(b))
}

@(private)
cmd_console :: proc(ctx: ^Context) -> int {
	rep, code := request(ctx, "Wren.console", fmt.tprintf(`{{%s"since":%d,"clear":%v}}`, tab_param(ctx), opt_int(&ctx.o, "since", 0), flag(&ctx.o, "clear")))
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	lines, _ := remote.param_array(parse_result(rep), "lines")
	for l in lines {
		o, _ := l.(json.Object)
		level, _ := remote.param_string(o, "level")
		text, _ := remote.param_string(o, "text")
		outln(level == "log" ? text : fmt.tprintf("%s: %s", level, text))
	}
	return 0
}

@(private)
cmd_network :: proc(ctx: ^Context) -> int {
	rep, code := request(ctx, "Wren.network", fmt.tprintf(`{{%s"clear":%v}}`, tab_param(ctx), flag(&ctx.o, "clear")))
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	reqs, _ := remote.param_array(parse_result(rep), "requests")
	for r in reqs {
		o, _ := r.(json.Object)
		status, _ := remote.param_int(o, "status")
		method, _ := remote.param_string(o, "method")
		url, _ := remote.param_string(o, "url")
		mime, _ := remote.param_string(o, "mime")
		n, _ := remote.param_int(o, "bytes")
		ms, has_ms := remote.param_float(o, "ms")
		failed, _ := remote.param_bool(o, "failed")
		msg, _ := remote.param_string(o, "error")
		st := failed ? "FAIL" : status == 0 ? "..." : fmt.tprintf("%d", status)
		outln(fmt.tprintf("%-4s %-6s %-9s %8d B %7s  %s%s", st, method, mime == "" ? "-" : mime, n, has_ms ? fmt.tprintf("%.0f ms", ms) : "-", url, failed ? fmt.tprintf("  (%s)", msg) : ""))
	}
	return 0
}

@(private)
cmd_stats :: proc(ctx: ^Context) -> int {
	params := fmt.tprintf(`{{"resetLatency":%v,"resetFrames":%v}}`, flag(&ctx.o, "reset-latency"), flag(&ctx.o, "reset-frames"))
	rep, code := request(ctx, "Wren.stats", params)
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	for k, v in parse_result(rep) {
		s, _ := json.marshal(v, {}, context.temp_allocator)
		outln(fmt.tprintf("%s: %s", k, string(s)))
	}
	return 0
}

@(private)
cmd_pref :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("pref", "usage: pref get <name> | pref set <name> <value> [--override] | pref reset <name> | pref reset --all | pref list [prefix]") }
	switch args[0] {
	case "get":
		if len(args) != 2 { return usage("pref", "usage: pref get <name>") }
		rep, code := request(ctx, "Wren.getPref", fmt.tprintf(`{{"name":%s}}`, q(args[1])))
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		s, _ := remote.param_string(parse_result(rep), "text")
		outln(s)
	case "set":
		if len(args) != 3 { return usage("pref", "usage: pref set <name> <value>") }
		rep, code := request(ctx, "Wren.setPref", fmt.tprintf(`{{"name":%s,"value":%s,"override":%v}}`, q(args[1]), q(args[2]), flag(&ctx.o, "override")))
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		s, _ := remote.param_string(parse_result(rep), "text")
		outln(s)
	case "reset":
		if flag(&ctx.o, "all") {
			if len(args) != 1 { return usage("pref", "usage: pref reset <name> | pref reset --all") }
			rep, code := request(ctx, "Wren.resetPref", `{"all":true}`)
			if code != 0 { return code }
			if flag(&ctx.o, "json") { print_json(rep); return 0 }
			n, _ := remote.param_int(parse_result(rep), "restored")
			outln(fmt.tprintf("%d preference(s) put back", n))
			return 0
		}
		if len(args) != 2 { return usage("pref", "usage: pref reset <name> | pref reset --all") }
		rep, code := request(ctx, "Wren.resetPref", fmt.tprintf(`{{"name":%s}}`, q(args[1])))
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		s, _ := remote.param_string(parse_result(rep), "text")
		outln(s)
	case "list":
		rep, code := request(ctx, "Wren.listPrefs", fmt.tprintf(`{{"prefix":%s}}`, q(len(args) > 1 ? args[1] : "")))
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		prefs, _ := remote.param_array(parse_result(rep), "prefs")
		for p in prefs {
			o, _ := p.(json.Object)
			n, _ := remote.param_string(o, "name"); t, _ := remote.param_string(o, "text")
			outln(fmt.tprintf("%s = %s", n, t))
		}
	case: return usage("pref", "get, set, reset or list")
	}
	return 0
}

@(private)
cmd_tabs :: proc(ctx: ^Context) -> int {
	rep, code := request(ctx, "Target.getTargets", "{}")
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	infos, _ := remote.param_array(parse_result(rep), "targetInfos")
	for i in infos {
		o, _ := i.(json.Object)
		id, _ := remote.param_int(o, "targetId"); active, _ := remote.param_bool(o, "active"); loading, _ := remote.param_bool(o, "loading")
		title, _ := remote.param_string(o, "title"); url, _ := remote.param_string(o, "url")
		outln(fmt.tprintf("%d%s %s%s  %s", id, active ? "*" : " ", loading ? "[loading] " : "", title, url))
	}
	return 0
}

@(private)
cmd_tab :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("tab", "usage: tab new [url] | tab activate <id> | tab close <id>") }
	switch args[0] {
	case "new":
		rep, code := request(ctx, "Target.createTarget", fmt.tprintf(`{{"url":%s,"wait":%s}}`, q(len(args) > 1 ? args[1] : ""), q(opt(&ctx.o, "wait", "none"))))
		if code != 0 { return code }
		id, _ := remote.param_int(parse_result(rep), "targetId")
		outln(fmt.tprintf("%d", id))
	case "activate", "close":
		if len(args) != 2 { return usage("tab", "tab activate|close <id>") }
		return simple(ctx, args[0] == "activate" ? "Target.activateTarget" : "Target.closeTarget", fmt.tprintf(`{{"targetId":%s}}`, args[1]))
	case: return usage("tab", "new, activate or close")
	}
	return 0
}

@(private)
cmd_window :: proc(ctx: ^Context) -> int {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	sep := ""
	if s := opt(&ctx.o, "size"); s != "" {
		w, h, ok := parse_size(s)
		if !ok { return usage("window", "--size WxH") }
		fmt.sbprintf(&b, `"width":%d,"height":%d`, w, h); sep = ","
	}
	if s := opt(&ctx.o, "pos"); s != "" {
		v, ok := parse_numbers(s, 2)
		if !ok { return usage("window", "--pos x,y") }
		fmt.sbprintf(&b, `%s"left":%d,"top":%d`, sep, int(v[0]), int(v[1])); sep = ","
	}
	if s := opt(&ctx.o, "state"); s != "" { fmt.sbprintf(&b, `%s"windowState":%s`, sep, q(s)); sep = "," }
	strings.write_byte(&b, '}')
	method := sep == "" ? "Browser.getWindowBounds" : "Browser.setWindowBounds"
	return simple(ctx, method, strings.to_string(b))
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
	rep, code := request(ctx, "Wren.listCommands", "{}")
	if code != 0 { return code }
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	filter := len(args) > 0 ? strings.to_lower(args[0], context.temp_allocator) : ""
	cmds, _ := remote.param_array(parse_result(rep), "commands")
	for c in cmds {
		o, _ := c.(json.Object)
		name, _ := remote.param_string(o, "name"); title, _ := remote.param_string(o, "title"); key, _ := remote.param_string(o, "shortcut")
		en, _ := remote.param_bool(o, "enabled")
		line := fmt.tprintf("%-34s %s%s%s", name, title, key != "" ? fmt.tprintf("  [%s]", key) : "", en ? "" : "  (not now)")
		if filter == "" || strings.contains(strings.to_lower(line, context.temp_allocator), filter) { outln(line) }
	}
	return 0
}

@(private)
cmd_record :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 { return usage("record", "usage: record start | record stop <file.json>") }
	switch args[0] {
	case "start": return simple(ctx, "Wren.recordInput", `{"action":"start"}`)
	case "stop":
		if len(args) != 2 { return usage("record", "usage: record stop <file.json>") }
		rep, code := request(ctx, "Wren.recordInput", `{"action":"stop"}`)
		if code != 0 { return code }
		if err := os.write_entire_file(abs_path(args[1]), transmute([]byte)rep.result); err != nil { errln("cannot write the file"); return EXIT_FAILED }
		n, _ := remote.param_int(parse_result(rep), "count")
		outln(fmt.tprintf("%d events -> %s", n, abs_path(args[1])))
	case: return usage("record", "start or stop")
	}
	return 0
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
	return simple(ctx, "Wren.replayInput", fmt.tprintf(`{{"events":%s,"speed":%s}}`, string(evs), opt(&ctx.o, "speed", "1")))
}

@(private)
cmd_quit :: proc(ctx: ^Context) -> int {
	if !need_server(ctx) { return EXIT_NO_SERVER }
	pid := 0
	if rep, code := request(ctx, "Remote.ping", "{}"); code == 0 { pid, _ = remote.param_int(parse_result(rep), "pid") }
	_, code := request(ctx, "Browser.close", fmt.tprintf(`{{"exitCode":%d}}`, opt_int(&ctx.o, "code", 0)))
	if code != 0 { return code }
	exit, ended := wait_process_exit(pid, 20_000)
	if !ended { errln("error: Wren did not end within 20 s"); return EXIT_TIMEOUT }
	if !flag(&ctx.o, "quiet") { outln(fmt.tprintf("exit code %d", exit)) }
	return 0
}

// reset [--keep tabs,data,prefs,window,history] [--url address] [--wait load|idle|quiet|none]
@(private)
cmd_reset :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 0 { return usage("reset", "usage: reset [--keep tabs,data,prefs,window,history] [--url address] [--wait load|idle|stable|quiet|none]") }
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"wait":%s`, q(opt(&ctx.o, "wait", "load")))
	if keep := opt(&ctx.o, "keep"); keep != "" { fmt.sbprintf(&b, `,"keep":%s`, q(keep)) }
	if u := opt(&ctx.o, "url"); u != "" { fmt.sbprintf(&b, `,"url":%s`, q(u)) }
	strings.write_byte(&b, '}')
	rep, code := request(ctx, "Wren.reset", strings.to_string(b))
	if code != 0 { return code }
	return show_reset(ctx, rep)
}

@(private)
show_reset :: proc(ctx: ^Context, rep: Reply) -> int {
	if flag(&ctx.o, "json") { print_json(rep); return 0 }
	if flag(&ctx.o, "quiet") { return 0 }
	r := parse_result(rep)
	n :: proc(r: json.Object, key: string) -> int { v, _ := remote.param_int(r, key); return v }
	win_back, _ := remote.param_bool(r, "windowRestored")
	outln(fmt.tprintf("%d tab(s) closed, %d cookie(s), %d site(s) of storage, %d cached response(s), %d visit(s) of history, %d preference(s) put back%s, %d command(s) cancelled",
		n(r, "closedTabs"), n(r, "cookies"), n(r, "sites"), n(r, "cacheEntries"), n(r, "historyVisits"), n(r, "prefsRestored"), win_back ? ", the window put back" : "", n(r, "cancelledOps")))
	return 0
}

// checkpoint save|restore|delete <name> | checkpoint list
@(private)
cmd_checkpoint :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) == 0 || (args[0] == "list" && len(args) != 1) || (args[0] != "list" && len(args) != 2) {
		return usage("checkpoint", "usage: checkpoint save <name> | checkpoint restore <name> [--wait ...] | checkpoint delete <name> | checkpoint list")
	}
	switch args[0] {
	case "save", "delete":
		rep, code := request(ctx, "Wren.checkpoint", fmt.tprintf(`{{"action":%s,"name":%s}}`, q(args[0]), q(args[1])))
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		if args[0] == "save" {
			r := parse_result(rep)
			tabs, _ := remote.param_int(r, "tabs"); ck, _ := remote.param_int(r, "cookies"); st, _ := remote.param_int(r, "storageOrigins")
			outln(fmt.tprintf("%s: %d tab(s), %d cookie(s), localStorage of %d origin(s)", args[1], tabs, ck, st))
		}
	case "restore":
		rep, code := request(ctx, "Wren.checkpoint", fmt.tprintf(`{{"action":"restore","name":%s,"wait":%s}}`, q(args[1]), q(opt(&ctx.o, "wait", "load"))))
		if code != 0 { return code }
		return show_reset(ctx, rep)
	case "list":
		rep, code := request(ctx, "Wren.checkpoint", `{"action":"list"}`)
		if code != 0 { return code }
		if flag(&ctx.o, "json") { print_json(rep); return 0 }
		list, _ := remote.param_array(parse_result(rep), "checkpoints")
		for item in list {
			o, _ := item.(json.Object)
			name, _ := remote.param_string(o, "name")
			tabs, _ := remote.param_int(o, "tabs"); ck, _ := remote.param_int(o, "cookies"); st, _ := remote.param_int(o, "storageOrigins")
			outln(fmt.tprintf("%-20s %d tab(s), %d cookie(s), localStorage of %d origin(s)", name, tabs, ck, st))
		}
	case: return usage("checkpoint", "save, restore, delete or list")
	}
	return 0
}
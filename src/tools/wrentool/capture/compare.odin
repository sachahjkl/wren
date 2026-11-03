// Package capture: pages as Wren and as other browsers draw them. `wrentool compare`: the same pages captured in Wren (headless, the typed API) and in headless Microsoft Edge, side by side, and
// how much of the picture differs. Pages change between two loads (news, ads, dates): the number is a hint, the pictures are the judge.
package capture

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"

COMPARE_FLAGS :: "-Urls= -List= -OutDir= -Width= -Height= -Dark -Js -Exe= -WaitMs="
COMPARE_OUT :: "build/cmp"
COMPARE_SUMMARY :: "summary.tsv"
EXIT_USAGE :: 2
// The viewport both browsers are asked for: the size of Wren's page area in a window 1280 x 800 at 96 dpi.
COMPARE_WIDTH :: 1280
COMPARE_HEIGHT :: 690
// How much taller Wren's window is than its page area (tabs and address bar).
COMPARE_CHROME_HEIGHT :: 110
COMPARE_DPI :: 96.0
// A pixel differs when its largest channel difference is over this.
COMPARE_TOLERANCE :: 32
// How long a page may take to be stable in Wren (an animated page never is: the capture is taken then all the same).
COMPARE_NAV_DEADLINE :: 45 * time.Second
// Edge: how long a page may take, the virtual time its scripts get (-Js), the starts when its helper processes still hold a profile.
COMPARE_EDGE_LIMIT :: 2 * time.Minute
COMPARE_EDGE_WAIT_MS :: 10_000
COMPARE_EDGE_ATTEMPTS :: 3
COMPARE_NAME_MAX :: 60
COMPARE_GAP :: "8"
COMPARE_BACKGROUND :: "#282828"
// The JavaScript errors of a page are grouped by their first words.
COMPARE_GROUP_WORDS :: 4
COMPARE_GROUPS_SHOWN :: 3
// When Wren does not say them.
COMPARE_USER_AGENT :: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Wren/0.3.0"
COMPARE_LANGUAGE :: "en-US,en;q=0.9"
// Edge without scripts: the profile's content settings turn them off (--blink-settings=scriptEnabled=false would stop the capture too, which is driven by script).
COMPARE_NO_SCRIPT_PREFERENCES :: `{"profile":{"default_content_setting_values":{"javascript":2}}}`
// No client hints either: Sec-CH-UA would still name Edge.
COMPARE_NO_HINTS :: "--disable-features=UserAgentClientHint,UserAgentClientHintFullVersionList"

Compare_Run :: struct {
	out:       string,   // absolute
	width:     int,
	height:    int,
	dark, js:  bool,
	wait_ms:   int,
	user_agent: string,
	language:  string,
}

Js_Group :: struct { key: string, errors, sites: int }

run_compare :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, COMPARE_FLAGS)
	if !ok { return EXIT_USAGE }
	urls := make([dynamic]string, context.temp_allocator)
	for u in tooling.flag_list(f, "-Urls") { if u != "" { append(&urls, u) } }
	if list := tooling.flag(f, "-List"); list != "" {
		data, err := os.read_entire_file(list, context.temp_allocator)
		if err != nil { fmt.eprintfln("cannot read %s", list); return EXIT_USAGE }
		for raw in strings.split_lines(string(data), context.temp_allocator) {
			line := strings.trim_space(raw)
			if line != "" && !strings.has_prefix(line, "#") { append(&urls, line) }
		}
	}
	if len(urls) == 0 { fmt.eprintln("wrentool compare -Urls a,b | -List file [-OutDir dir] [-Width n] [-Height n] [-Dark] [-Js] [-Exe path] [-WaitMs n]"); return EXIT_USAGE }
	exe := tooling.flag(f, "-Exe", bench.WREN_EXE)
	if !os.exists(exe) { fmt.eprintfln("%s is missing (build.bat)", exe); return 1 }
	if bench.edge_exe() == "" { fmt.eprintln("Microsoft Edge is not installed"); return 1 }
	out, _ := filepath.abs(tooling.flag(f, "-OutDir", COMPARE_OUT), context.allocator)   // (it outlives the temporary memory each page frees)
	_ = os.make_directory_all(out)
	c := Compare_Run{out = out, width = tooling.flag_int(f, "-Width", COMPARE_WIDTH), height = tooling.flag_int(f, "-Height", COMPARE_HEIGHT),
		dark = tooling.flag_has(f, "-Dark"), js = tooling.flag_has(f, "-Js"), wait_ms = tooling.flag_int(f, "-WaitMs", COMPARE_EDGE_WAIT_MS)}
	_, has_magick := bench.run_text({"magick", "-version"})
	if !has_magick { fmt.println("ImageMagick (magick) is not installed: no side-by-side pictures") }

	prefs := []string{fmt.tprintf("style.color_scheme=%s", c.dark ? "dark" : "light"), fmt.tprintf("javascript.enabled=%v", c.js)}
	w: bench.Wren
	if !bench.start(&w, {exe = exe, window = .Headless, size = {c.width, c.height + COMPARE_CHROME_HEIGHT}, dpi = COMPARE_DPI, prefs = prefs}) { return 1 }
	defer bench.stop(&w)
	// Edge sends what Wren sends, so that a server which picks its page by browser gives both the same document.
	c.user_agent, _ = api.pref_get(&w.session, "network.user_agent")
	if c.user_agent == "" { c.user_agent = COMPARE_USER_AGENT }
	c.language, _ = api.pref_get(&w.session, "network.accept_language")
	if c.language == "" { c.language = COMPARE_LANGUAGE }

	summary := strings.builder_make()
	fmt.sbprintfln(&summary, "name\turl\tdiff_pct\twren_size\tedge_size\tjs_errors\ttop_js_errors")
	groups := make(map[string]Js_Group)
	failed := 0
	for url in urls {
		name := compare_slug(url)
		wren_png := fmt.tprintf("%s/%s_wren.png", c.out, name)
		edge_png := fmt.tprintf("%s/%s_edge.png", c.out, name)
		side_png := fmt.tprintf("%s/%s_side.png", c.out, name)
		_ = os.remove(wren_png)
		_ = os.remove(edge_png)
		errors, why := compare_wren_shot(&w, &c, url, wren_png)
		if why == "" && !compare_edge_shot(&c, url, edge_png) { why = "Edge wrote no capture" }
		if why != "" {
			fmt.printfln("%-60s failed: %s", url, why)
			fmt.sbprintfln(&summary, "%s\t%s\t\t\t\t\t%s", name, url, why)
			failed += 1
			free_all(context.temp_allocator)
			continue
		}
		share, sizes, good := compare_diff(wren_png, edge_png)
		if has_magick && good {
			_, _ = bench.run_text({"magick", wren_png, edge_png, "-background", COMPARE_BACKGROUND, "+smush", COMPARE_GAP, side_png})
		}
		top := compare_js_groups(errors, &groups)
		fmt.printfln("%-60s diff %.1f %%  %s%s", url, share, sizes, c.js ? fmt.tprintf("  js errors %d  %s", len(errors), top) : "")
		fmt.sbprintfln(&summary, "%s\t%s\t%.1f\t%s\t%d\t%s", name, url, share, strings.trim_space(sizes), len(errors), top)
		free_all(context.temp_allocator)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/%s", c.out, COMPARE_SUMMARY), strings.to_string(summary))
	if c.js { compare_print_groups(groups) }
	fmt.printfln("\n%s/%s", c.out, COMPARE_SUMMARY)
	return failed > 0 ? 1 : 0
}

// A file name for a page: its address without the scheme, anything but letters, digits and ._- as _.
compare_slug :: proc(url: string) -> string {
	s := url
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] }
	b := strings.builder_make(context.temp_allocator)
	for r in s { strings.write_rune(&b, ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z') || ('0' <= r && r <= '9') || r == '.' || r == '_' || r == '-' ? r : '_') }
	name := strings.trim(strings.to_string(b), "_")
	return len(name) > COMPARE_NAME_MAX ? name[:COMPARE_NAME_MAX] : name
}

// The page in Wren, its page area to `dest`. With -Js the errors its script wrote on the console. why "": it worked.
compare_wren_shot :: proc(w: ^bench.Wren, c: ^Compare_Run, url, dest: string) -> (errors: []api.Console_Line, why: string) {
	if c.js { _, _ = api.console(&w.session, clear = true) }
	if e := api.navigate(&w.session, url, .Stable, COMPARE_NAV_DEADLINE); e != .None && e != .Timeout { return nil, api.last_failure().message }
	if _, e := api.screenshot(&w.session, dest, {target = .Page}); e != .None { return nil, api.last_failure().message }
	if !c.js { return nil, "" }
	lines, _ := api.console(&w.session)
	kept := make([dynamic]api.Console_Line, context.temp_allocator)
	for l in lines { if l.level == "error" { append(&kept, l) } }
	return kept[:], ""
}

// The page in headless Edge, its viewport to `dest`, with a profile of its own. Without scripts: the first load fills the profile's cache (web fonts), the second is the capture.
compare_edge_shot :: proc(c: ^Compare_Run, url, dest: string) -> bool {
	profile := bench.scratch("compare-edge")
	defer base.remove_tree(profile)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, bench.edge_exe())
	append(&cmd, ..bench.EDGE_ARGS)
	language, _, _ := strings.partition(c.language, ",")
	// (with its scroll bars: classic ones, which take room, as Wren's do by default: layout.scrollbar.overlay)
	append(&cmd, fmt.tprintf("--user-data-dir=%s", profile), "--force-device-scale-factor=1", fmt.tprintf("--window-size=%d,%d", c.width, c.height),
		fmt.tprintf("--lang=%s", language), fmt.tprintf("--accept-lang=%s", c.language))
	// (observed with this Edge: no option follows Windows' dark theme, preferredColorScheme=1 gives the light one)
	if !c.dark { append(&cmd, "--blink-settings=preferredColorScheme=1") }
	passes := 1
	if c.js {
		append(&cmd, fmt.tprintf("--virtual-time-budget=%d", c.wait_ms))
	} else {
		_ = os.make_directory_all(fmt.tprintf("%s/Default", profile))
		_ = os.write_entire_file(fmt.tprintf("%s/Default/Preferences", profile), COMPARE_NO_SCRIPT_PREFERENCES)
		append(&cmd, fmt.tprintf("--user-agent=%s", c.user_agent), COMPARE_NO_HINTS)
		passes = 2
	}
	for pass in 0 ..< passes {
		target := pass == passes - 1 ? dest : fmt.tprintf("%s/warmup.png", profile)
		for _ in 0 ..< COMPARE_EDGE_ATTEMPTS {
			full := make([dynamic]string, context.temp_allocator)
			append(&full, ..cmd[:])
			append(&full, fmt.tprintf("--screenshot=%s", target), url)
			_, _ = bench.run_text(full[:], COMPARE_EDGE_LIMIT)
			if os.exists(target) { break }
		}
	}
	return os.exists(dest)
}

// The share of pixels (in percent) that differ over the area both pictures have, and both sizes.
compare_diff :: proc(wren_png, edge_png: string) -> (share: f64, sizes: string, ok: bool) {
	a, good_a := api.load_image(wren_png)
	b, good_b := api.load_image(edge_png)
	if !good_a || !good_b { return 0, "unreadable capture", false }
	sizes = fmt.tprintf("wren %dx%d edge %dx%d", a.width, a.height, b.width, b.height)
	w, h := min(a.width, b.width), min(a.height, b.height)
	if w * h == 0 { return 0, sizes, false }
	count, _, _ := api.diff_pictures(compare_cropped(a, w, h), compare_cropped(b, w, h), w, h, COMPARE_TOLERANCE)
	return 100 * f64(count) / f64(w * h), sizes, true
}

compare_cropped :: proc(p: api.Image, w, h: int) -> []u8 {
	if p.width == w && p.height == h { return p.rgba }
	out := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h { copy(out[y * w * 4:(y + 1) * w * 4], p.rgba[y * p.width * 4:][:w * 4]) }
	return out
}

// The errors of a page by their first words, added to `all`; the most frequent of this page as text.
compare_js_groups :: proc(errors: []api.Console_Line, all: ^map[string]Js_Group) -> string {
	mine := make(map[string]int, context.temp_allocator)
	for e in errors {
		words := strings.fields(e.text, context.temp_allocator)
		key := strings.join(words[:min(len(words), COMPARE_GROUP_WORDS)], " ", context.temp_allocator)
		mine[key] += 1
	}
	list := make([dynamic]Js_Group, context.temp_allocator)
	for key, n in mine {
		append(&list, Js_Group{key = key, errors = n})
		g, known := all[key]
		if !known { g.key = strings.clone(key) }
		g.errors += n
		g.sites += 1
		all[g.key] = g
	}
	slice.sort_by(list[:], proc(a, b: Js_Group) -> bool { return a.errors > b.errors })
	top := make([dynamic]string, context.temp_allocator)
	for g in list[:min(len(list), COMPARE_GROUPS_SHOWN)] { append(&top, fmt.tprintf("%s (%d)", g.key, g.errors)) }
	return strings.join(top[:], ", ", context.temp_allocator)
}

compare_print_groups :: proc(all: map[string]Js_Group) {
	list := make([dynamic]Js_Group, context.temp_allocator)
	for _, g in all { append(&list, g) }
	slice.sort_by(list[:], proc(a, b: Js_Group) -> bool { return a.sites != b.sites ? a.sites > b.sites : a.errors > b.errors })
	fmt.println("\nwhat the JavaScript errors say (sites, errors)")
	for g in list { fmt.printfln("%d sites, %d errors  %s", g.sites, g.errors, g.key) }
}

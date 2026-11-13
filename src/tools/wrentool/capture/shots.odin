// Package capture: pictures of Wren, each the browser's real render read from its frame, in a headless Wren: no window of the system, nothing to cover it, nothing of the machine's taken.
//   wrentool capture -Url u -Out shot.png [-Width n] [-Height n] [-Actions "key:Ctrl+F; type:x; click:600,695"] [-Exe path] [-Pref a=b] [-Page] [-Site url]
//   wrentool shots [-Only home,css-grid] [-Width n] [-Height n] [-NoConvert] [-Exe path] [-Site url]     the README's (docs/screenshots) and the site's (site/img, through ImageMagick)
//   wrentool compare ...                                                                     Wren against Edge (compare.odin)
package capture

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:remote/api"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"

RAW_DIR :: "build/shots"
SHOT_PREFS :: "browser.remote.indicator=false"
SHOT_WIDTH :: 1600
SHOT_HEIGHT :: 1000
// The scale of every picture, whatever the machine's screen (the first Wren of a run got 96 dpi, the next ones the system's)
SHOT_DPI :: 1.5 * api.DPI_ONE
WEBP_QUALITY :: "82"
WEBP_SMALL_QUALITY :: "80"
WEBP_SMALL_WIDTH :: "640x"
HERO_SETTLE_FRAMES :: 6
// What a page may take to settle; a capture is taken at that point even so (a real site's advertising never stops).
PAGE_LIMIT :: 40 * time.Second
AFTER_ACTION_FRAMES :: 3

Shot :: struct {
	name, url: string,
	actions:   string,
	prefs:     []string,
}

SITE :: "site:"
SHOTS := []Shot{
	{name = "home", url = "about:home"},
	{name = "demos", url = "about:demos"},
	{name = "css-effects", url = "site:effects.html"},
	{name = "css-transforms", url = "site:transforms.html"},
	{name = "css-grid", url = "site:grid.html"},
	{name = "css-gradients", url = "site:gradients.html"},
	{name = "masks-and-color-glyphs", url = "site:paint.html"},
	{name = "text", url = "site:text.html"},
	{name = "wasm-counter", url = "site:counter.html"},
	{name = "javascript", url = "site:js.html"},
	{name = "shadow-dom", url = "site:shadow-dom.html"},
	{name = "sacha-house", url = "https://sacha.house"},
	{name = "webassembly-org", url = "https://webassembly.org/news/2026-01-21-states-of-webassembly/"},
	{name = "odin-lang-org", url = "https://odin-lang.org"},
	{name = "frame-statistics", url = "site:transforms.html", actions = "key:Ctrl+Shift+F"},
	{name = "about-config", url = "about:config"},
	{name = "find", url = "https://sacha.house/cv", actions = "key:Ctrl+F; type:Angular"},
	{name = "context-menu", url = "https://sacha.house/cv", actions = "dclick:600,695; rclick:600,695"},
	{name = "tabs", url = "https://webassembly.org", actions = "key:Ctrl+T; key:Ctrl+L; type:https://sacha.house; key:Enter; key:Ctrl+T; key:Ctrl+L; type:about:demos; key:Enter; click:1500,560"},
	{name = "devtools", url = "site:grid.html", actions = "key:F12; click:221,527"},
	{name = "command-palette", url = "site:grid.html", actions = "key:Ctrl+Shift+P; type:dev"},
	{name = "about-wren", url = "about:wren"},
	{name = "content-blocker", url = "https://sacha.house/cv", actions = "key:Ctrl+Shift+P; type:blocker: open; key:Enter"},
	{name = "daylight", url = "https://sacha.house/cv", prefs = {"appearance.theme=daylight"}},
}

HERO_PAGES := [][2]string{{"hero-css", "site:effects.html"}, {"hero-js", "site:js.html"}, {"hero-shadow", "site:shadow-dom.html"}, {"hero-config", "about:config"}}

// -Site http://wren.localhost/site/ (the local test server behind a name, e.g. through portless: docs/testing.md): the demo pages are taken from
// there, and the address bar shows that name, not the path of a checkout.
site_base: string

address :: proc(url: string) -> string {
	if strings.has_prefix(url, SITE) && site_base != "" { return fmt.tprintf("%s%s", site_base, url[len(SITE):]) }
	if strings.has_prefix(url, SITE) { return bench.file_url(fmt.tprintf("examples/site/%s", url[len(SITE):])) }
	return url
}

// A barrier after the page or an action: it is stable, or the limit is over and the picture is what it is (a page whose
// videos play never rests: odin-lang.org). False: the page did not load in time; a picture taken then shows a page that is still blank.
at_rest :: proc(s: ^api.Session) -> bool {
	if api.wait_load(s, PAGE_LIMIT) != .None { return false }
	_ = api.wait_stable(s, PAGE_LIMIT)
	return api.wait_frames(s, AFTER_ACTION_FRAMES) == .None
}

// `key:Ctrl+T; type:text; click:x,y; dclick:x,y; rclick:x,y`, window points. Each is waited for.
run_actions :: proc(s: ^api.Session, actions: string) -> bool {
	for raw in strings.split(actions, ";", context.temp_allocator) {
		a := strings.trim_space(raw)
		if a == "" { continue }
		colon := strings.index_byte(a, ':')
		if colon < 0 { fmt.eprintfln("%s is not an action", a); return false }
		what, arg := a[:colon], a[colon + 1:]
		e: api.Error
		switch what {
		case "key": e = api.key(s, arg)
		case "type": e = api.type_text(s, arg)
		case "click", "dclick", "rclick":
			xy := strings.split(arg, ",", context.temp_allocator)
			if len(xy) != 2 { fmt.eprintfln("%s is not a point", arg); return false }
			x, _ := strconv.parse_f64(xy[0])
			y, _ := strconv.parse_f64(xy[1])
			e = api.click_at(s, {x, y}, .Window, what == "rclick" ? .Right : .Left, what == "dclick" ? 2 : 1)
		case: fmt.eprintfln("no action %s", what); return false
		}
		if e != .None { fmt.eprintfln("%s: %s", a, api.last_failure().message); return false }
		_ = at_rest(s)
	}
	return true
}

absolute :: proc(path: string) -> string {
	if strings.contains(path, ":") || strings.has_prefix(path, "/") { return path }
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fmt.tprintf("%s/%s", cwd, path)
}

take :: proc(s: ^api.Session, path: string, o := api.Shot_Options{}) -> bool {
	if _, e := api.screenshot(s, absolute(path), o); e != .None { fmt.eprintfln("%s: %s", path, api.last_failure().message); return false }
	return true
}

run_capture :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Url= -Out= -Width= -Height= -Actions= -Exe= -Pref= -Page -Site=")
	site_base = tooling.flag(f, "-Site")
	if !ok || !tooling.flag_has(f, "-Url") || !tooling.flag_has(f, "-Out") { fmt.eprintln("wrentool capture -Url u -Out shot.png [-Width n] [-Height n] [-Actions a] [-Exe path] [-Pref a=b] [-Page] [-Site url]"); return EXIT_USAGE }
	w: bench.Wren
	if !bench.start(&w, {exe = tooling.flag(f, "-Exe", bench.WREN_EXE), size = {tooling.flag_int(f, "-Width", bench.DEFAULT_SIZE.x), tooling.flag_int(f, "-Height", bench.DEFAULT_SIZE.y)}, prefs = tooling.flag_list(f, "-Pref"), url = address(tooling.flag(f, "-Url"))}) { return 1 }
	defer bench.stop(&w)
	_ = at_rest(&w.session)
	if !run_actions(&w.session, tooling.flag(f, "-Actions")) { return 1 }
	if !take(&w.session, tooling.flag(f, "-Out"), {target = tooling.flag_has(f, "-Page") ? .Page : .Window}) { return 1 }
	fmt.println(tooling.flag(f, "-Out"))
	return 0
}

run_shots :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Only= -Width= -Height= -NoConvert -Exe= -Site=")
	if !ok { return EXIT_USAGE }
	site_base = tooling.flag(f, "-Site")
	exe := tooling.flag(f, "-Exe", bench.WREN_EXE)
	only := tooling.flag_list(f, "-Only")
	size := [2]int{tooling.flag_int(f, "-Width", SHOT_WIDTH), tooling.flag_int(f, "-Height", SHOT_HEIGHT)}
	convert := !tooling.flag_has(f, "-NoConvert")
	_ = os.make_directory_all(RAW_DIR)
	_ = os.make_directory_all("docs/screenshots")
	missing := 0
	for s in SHOTS {
		if len(only) > 0 && !slice.contains(only, s.name) { continue }
		png := fmt.tprintf("%s/%s.png", RAW_DIR, s.name)
		w: bench.Wren
		// (a picture of the browser as a person sees it: not the label of the remote channel that takes it)
		prefs := make([dynamic]string, context.temp_allocator)
		append(&prefs, SHOT_PREFS)
		append(&prefs, ..s.prefs)
		if !bench.start(&w, {exe = exe, size = size, dpi = SHOT_DPI, prefs = prefs[:], url = address(s.url)}) { return 1 }
		good := at_rest(&w.session) && run_actions(&w.session, s.actions) && take(&w.session, png)
		bench.stop(&w)
		fmt.printfln("%s %s", good ? "shot" : "MISSING", s.name)
		if !good { missing += 1; continue }
		if convert {
			_ = os.copy_file(fmt.tprintf("docs/screenshots/%s.png", s.name), png)
			if !magick({png, "-quality", WEBP_QUALITY, fmt.tprintf("site/img/%s.webp", s.name)}) || !magick({png, "-resize", WEBP_SMALL_WIDTH, "-quality", WEBP_SMALL_QUALITY, fmt.tprintf("site/img/%s-640.webp", s.name)}) { return 1 }
		}
	}
	if len(only) == 0 || slice.contains(only, "hero") {
		if !hero_shots(exe, size, convert) { return 1 }
	}
	return missing > 0 ? 1 : 0
}

magick :: proc(args: []string) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "magick")
	append(&cmd, ..args)
	return tooling.run({command = cmd[:]}) == 0
}

// The four pictures of the home page's hero: one window with the same four tabs open, each picture with another tab in front: index.html puts clickable zones over the tabs of the picture.
hero_shots :: proc(exe: string, size: [2]int, convert: bool) -> bool {
	w: bench.Wren
	if !bench.start(&w, {exe = exe, size = size, dpi = api.DPI_ONE, url = address(HERO_PAGES[0][1])}) { return false }
	defer bench.stop(&w)
	s := &w.session
	_ = at_rest(s)
	for p in HERO_PAGES[1:] {
		if _, e := api.new_tab(s, address(p[1]), .Load); e != .None { fmt.eprintln(api.last_failure().message); return false }
		_ = at_rest(s)
	}
	list, e := api.targets(s)
	if e != .None || len(list.tabs) != len(HERO_PAGES) { fmt.eprintfln("expected %d tabs, got %d", len(HERO_PAGES), len(list.tabs)); return false }
	for p, i in HERO_PAGES {
		if api.activate_tab(s, list.tabs[i].id) != .None { fmt.eprintln(api.last_failure().message); return false }
		_ = at_rest(s)
		png := fmt.tprintf("%s/%s.png", RAW_DIR, p[0])
		if !take(s, png, {settle = HERO_SETTLE_FRAMES, has_settle = true}) { return false }
		fmt.printfln("shot %s", p[0])
		if convert && !magick({png, "-quality", WEBP_QUALITY, fmt.tprintf("site/img/%s.webp", p[0])}) { return false }
	}
	return true
}

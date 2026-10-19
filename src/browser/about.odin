package browser

import "core:fmt"
import "core:strings"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:page"

// Identity of the program. One place, so a rename touches nothing else.
APP_NAME    :: "Wren"
APP_VERSION :: "0.1.0"
APP_TAGLINE :: "A small browser that runs WebAssembly, and nothing else."

// The sources the program was built from, injected by build.bat (-define): the short commit hash, "+" when the tree
// had uncommitted changes, and the commit's date. "dev" / "" when built without git (or by `odin test`).
@(private = "file") COMMIT_DEFINE :: #config(WREN_COMMIT, "dev")
APP_COMMIT_DATE :: #config(WREN_COMMIT_DATE, "")

app_commit :: proc() -> string {
	s := COMMIT_DEFINE
	return len(s) > 1 && s[0] == 'g' ? s[1:] : s   // build.bat writes g<hash>
}

Build_Kind :: enum u8 { Release, Debug, Profile }

// How this executable was built: profile (build.bat profile: optimized, with the profiler), debug (build.bat debug:
// debug information, no optimization), release.
BUILD_KIND :: Build_Kind.Profile when PROFILE else (Build_Kind.Debug when ODIN_DEBUG else Build_Kind.Release)

build_kind_name :: proc(k: Build_Kind) -> string {
	switch k {
	case .Release: return "release"
	case .Debug:   return "debug"
	case .Profile: return "profile"
	}
	return ""
}

// "release", "profile", "debug", with the measurement options compiled in ("+gpu-timing": toolkit -define:GPU_TIMING;
// GPU times are measured without it too, at run time: browser.status_bar.gpu_timing).
describe_build :: proc(k: Build_Kind, gpu_timing_define: bool) -> string {
	s := build_kind_name(k)
	return gpu_timing_define ? fmt.tprintf("%s +gpu-timing", s) : s
}

build_description :: proc() -> string { return describe_build(BUILD_KIND, render.GPU_TIMING) }

// "0.1.0 (1a2b3c4, 2026-10-19)", or "0.1.0 (dev)".
version_long :: proc() -> string {
	if APP_COMMIT_DATE != "" { return fmt.tprintf("%s (%s, %s)", APP_VERSION, app_commit(), APP_COMMIT_DATE) }
	return fmt.tprintf("%s (%s)", APP_VERSION, app_commit())
}

HOME_URL :: "about:home"

@(private)
HOME_TEMPLATE :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>New tab</title>
<style>
  html { background-color: #0d1017; }
  body { margin: 0; color: #c9d1e3; font-family: system-ui; font-size: 16px; }
  .hero { text-align: center; padding: 84px 20px 12px; }
  .logo { font-size: 84px; font-weight: bold; color: #f1f4fb; margin: 0; }
  .logo .w { color: #ffb84d; }
  .tag { font-size: 20px; color: #8993ad; margin: 6px 0 0; }
  .hint { width: 560px; margin: 34px auto 10px; padding: 13px 24px; background-color: #151a26; border: 1px solid #272f45; border-radius: 26px; color: #6f7a96; text-align: center; }
  .hint b { color: #c9d1e3; }
  .grid { width: 640px; margin: 26px auto 0; }
  .card { display: block; margin: 14px 0; padding: 18px 24px 18px; background-color: #131825; border: 1px solid #232b40; border-radius: 14px; color: #c9d1e3; text-decoration: none; }
  .card:hover { background-color: #19203a; border-color: #ffb84d; }
  .card h3 { margin: 0 0 4px; font-size: 19px; color: #ffb84d; }
  .card p { margin: 0; color: #8993ad; }
  .card .where { color: #4f5a78; font-size: 13px; margin-top: 8px; }
  .foot { text-align: center; color: #4f5a78; font-size: 13px; padding: 36px 20px 48px; }
  .foot b { color: #8993ad; }
</style>
</head>
<body>
  <div class="hero">
    <h1 class="logo"><span class="w">W</span>ren</h1>
    <p class="tag">$TAGLINE$</p>
  </div>
  <p class="hint">Type an address in the bar above, or pick something below.</p>
  <div class="grid">
    <a class="card" href="about:config">
      <h3>Configuration</h3>
      <p>Every setting of the browser, searchable and editable. Nothing is hard-wired.</p>
      <p class="where">about:config</p>
    </a>
    <a class="card" href="http://127.0.0.1:8765/site/style.html">
      <h3>Style engine demo</h3>
      <p>Selectors, the cascade, layers, variables, media queries and linked sheets.</p>
      <p class="where">127.0.0.1:8765/site/style.html</p>
    </a>
    <a class="card" href="http://127.0.0.1:8765/site/">
      <h3>WebAssembly page</h3>
      <p>A page whose logic is a Wasm module: no JavaScript anywhere.</p>
      <p class="where">127.0.0.1:8765/site/</p>
    </a>
  </div>
  <p class="foot"><b>$NAME$</b> $VERSION$ &middot; WebAssembly only &middot; written in Odin<br>The demos need <b>build\testserver.exe</b> running.</p>
</body>
</html>
`

home_html :: proc() -> string {
	s, _ := strings.replace_all(HOME_TEMPLATE, "$TAGLINE$", APP_TAGLINE, context.temp_allocator)
	s, _ = strings.replace_all(s, "$NAME$", APP_NAME, context.temp_allocator)
	s, _ = strings.replace_all(s, "$VERSION$", APP_VERSION, context.temp_allocator)
	return s
}

// The start page is an ordinary document, styled by the same engine as every other page.
show_home :: proc(app: ^App, t: ^Tab) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, HOME_URL, console_sink, t)
	attach_page(app, t, t.page)   // links and location work from the start page too
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	for l in t.console { delete(l) }
	clear(&t.console)
	page.load_html(t.page, transmute([]byte)home_html())
	delete(t.url); t.url = strings.clone(HOME_URL)
	delete(t.title); t.title = strings.clone("New tab")
	set_status(t, fmt.tprintf("%s %s", APP_NAME, APP_VERSION))
	ui.field_set(&app.address, "")   // the start page shows an empty address bar
}

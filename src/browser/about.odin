package browser

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:page"

// Identity of the program. One place, so a rename touches nothing else.
APP_NAME    :: "Wren"
APP_VERSION :: "0.4.0"
APP_TAGLINE :: "A small browser where WebAssembly runs everything, JavaScript included."

// A label for a build that is not the release of this version, set when it is built (build.bat: `set WREN_VERSION_LABEL=experimental-2026-10-24`,
// -define:WREN_VERSION_LABEL): "0.3.0-experimental-2026-10-24" is what the user is shown (about:wren, the menu, the status bar, the file's
// Details, Setup). APP_VERSION stays the plain number, because the program compares it (Setup's installed copy, the update check) and
// sends it (the User-Agent): the label never reaches those.
APP_VERSION_LABEL :: #config(WREN_VERSION_LABEL, "")
APP_VERSION_SHOWN :: APP_VERSION + "-" + APP_VERSION_LABEL when APP_VERSION_LABEL != "" else APP_VERSION

// The sources the program was built from, injected by build.bat (-define): the short commit hash, "+" when the tree
// had uncommitted changes, and the commit's date. "dev" / "" when built without git (or by `odin test`).
@(private = "file") COMMIT_DEFINE :: #config(WREN_COMMIT, "dev")
APP_COMMIT_DATE :: #config(WREN_COMMIT_DATE, "")

app_commit :: proc() -> string {
	s := COMMIT_DEFINE
	return len(s) > 1 && s[0] == 'g' ? s[1:] : s   // build.bat writes g<hash>
}

// The channel: every build is a development one but `build.bat release` (-define:WREN_CHANNEL=release), the one the
// release workflow packages. A development build wears the blueprint logo (assets\dev: the exe's icon through
// wren_dev.rc, so the window, the taskbar and the tab strip follow; the start page's logo here) and says so.
App_Channel :: enum u8 { Release, Dev }

@(private = "file") CHANNEL_DEFINE :: #config(WREN_CHANNEL, "dev")
APP_CHANNEL  :: App_Channel.Release when CHANNEL_DEFINE == "release" else App_Channel.Dev
IS_DEV_BUILD :: APP_CHANNEL == .Dev

// The logo of the channel, 256 px (shown at 112 CSS px by the start page and about:about: sharp up to 2x).
APP_LOGO_PNG :: #load("../../assets/dev/logo_256.png") when IS_DEV_BUILD else #load("../../assets/logo_256.png")

// The logo as a data: URL for the built-in pages (in the temporary allocator, like the pages' HTML).
app_logo_url :: proc() -> string {
	return strings.concatenate({"data:image/png;base64,", base64.encode(APP_LOGO_PNG, allocator = context.temp_allocator)}, context.temp_allocator)
}

// "Wren 0.2.1 (1a2b3c4)", "Wren 0.2.1 dev (1a2b3c4)" (the menu's last line).
app_identity :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s %s%s (%s)", APP_NAME, APP_VERSION_SHOWN, IS_DEV_BUILD ? " dev" : "", app_commit(), allocator = allocator)
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
// GPU times are measured without it too, at run time: browser.status_bar.gpu_timing). A development build says "dev"
// first, and only "dev" for the optimized one (it is not the release).
describe_build :: proc(k: Build_Kind, gpu_timing_define: bool, dev := false) -> string {
	s := build_kind_name(k)
	if dev { s = k == .Release ? "dev" : fmt.tprintf("dev %s", s) }
	return gpu_timing_define ? fmt.tprintf("%s +gpu-timing", s) : s
}

build_description :: proc() -> string { return describe_build(BUILD_KIND, render.GPU_TIMING, IS_DEV_BUILD) }

// "0.2.0 (1a2b3c4, 2026-10-20)", or "0.2.0 (dev)".
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
  body { margin: 0; padding: 0 20px; color: #c9d1e3; font-family: system-ui; font-size: 16px; }
  .hero { text-align: center; padding: 56px 20px 12px; }
  .mark { display: block; width: 112px; height: 112px; margin: 0 auto 4px; }
  .logo { font-size: 84px; font-weight: bold; color: #f1f4fb; margin: 0; }
  .logo .w { color: $ACCENT$; }
  .tag { font-size: 20px; color: #8993ad; margin: 6px 0 0; }
  .dev { display: inline-block; margin: 18px 0 0; padding: 5px 16px 5px 6px; border: 1px solid #2f5ea8; border-radius: 16px; background-color: #10213f; color: #9cc0f2; font-size: 14px; }
  .dev b { display: inline-block; margin-right: 10px; padding: 1px 9px; border-radius: 11px; background-color: #2363b8; color: #ffffff; font-size: 12px; letter-spacing: 1px; }
  .hint { max-width: 560px; box-sizing: border-box; margin: 34px auto 10px; padding: 13px 24px; background-color: #151a26; border: 1px solid #272f45; border-radius: 26px; color: #6f7a96; text-align: center; }
  .hint b { color: #c9d1e3; }
  .grid { max-width: 640px; margin: 26px auto 0; }
  .card { display: block; margin: 14px 0; padding: 18px 24px 18px; background-color: #131825; border: 1px solid #232b40; border-radius: 14px; color: #c9d1e3; text-decoration: none; }
  .card:hover { background-color: #19203a; border-color: #ffb84d; }
  .card:active { background-color: #20294a; }
  .card h3 { margin: 0 0 4px; font-size: 19px; color: #ffb84d; }
  .card p { margin: 0; color: #8993ad; }
  .card .where { color: #4f5a78; font-size: 13px; margin-top: 8px; }
  .foot { text-align: center; color: #4f5a78; font-size: 13px; padding: 36px 20px 48px; }
  .foot b { color: #8993ad; }
  @media (prefers-color-scheme: light) {
    html { background-color: #f5f6fa; }
    body { color: #2b3245; }
    .logo { color: #1d2333; }
    .logo .w { color: $ACCENT_LIGHT$; }
    .tag { color: #5d6680; }
    .dev { background-color: #e8f0fc; border-color: #9dbbe8; color: #1d4f91; }
    .hint { background-color: #ffffff; border-color: #dce1ec; color: #6b7590; }
    .hint b { color: #2b3245; }
    .card { background-color: #ffffff; border-color: #e0e4ee; color: #2b3245; }
    .card:hover { background-color: #fff8ec; border-color: #d98200; }
    .card:active { background-color: #ffefd2; }
    .card h3 { color: #b86e00; }
    .card p { color: #5d6680; }
    .card .where { color: #8a93aa; }
    .foot { color: #8a93aa; }
    .foot b { color: #5d6680; }
  }
</style>
</head>
<body>
  <div class="hero">
    <img class="mark" src="$LOGO$" width="112" height="112" alt="">
    <h1 class="logo"><span class="w">W</span>ren</h1>
    <p class="tag">$TAGLINE$</p>
    $DEV$
  </div>
  <p class="hint">Type an address in the bar above, or pick something below.</p>
  <div class="grid">
    <a class="card" href="about:config">
      <h3>Configuration</h3>
      <p>Every setting of the browser, searchable and editable. Nothing is hard-wired.</p>
      <p class="where">about:config</p>
    </a>
    <a class="card" href="about:demos">
      <h3>Demos &amp; tests</h3>
      <p>Every demo and test page that comes with Wren, by theme: CSS, layout, effects, text, images, WebAssembly, JavaScript, network, performance.</p>
      <p class="where">about:demos</p>
    </a>
  </div>
  <p class="foot"><b>$NAME$</b> $VERSION$ &middot; WebAssembly only &middot; written in Odin<br>Some demos need the test server: <b>testserver.exe</b> (demo.bat in the release).</p>
</body>
</html>
`

home_html :: proc() -> string {
	s, _ := strings.replace_all(HOME_TEMPLATE, "$TAGLINE$", APP_TAGLINE, context.temp_allocator)
	s, _ = strings.replace_all(s, "$NAME$", APP_NAME, context.temp_allocator)
	s, _ = strings.replace_all(s, "$VERSION$", APP_VERSION, context.temp_allocator)
	s, _ = strings.replace_all(s, "$ACCENT$", IS_DEV_BUILD ? "#7fb2ff" : "#ffb84d", context.temp_allocator)
	s, _ = strings.replace_all(s, "$ACCENT_LIGHT$", IS_DEV_BUILD ? "#1d5aa8" : "#d98200", context.temp_allocator)
	s, _ = strings.replace_all(s, "$DEV$", dev_badge_html(), context.temp_allocator)
	s, _ = strings.replace_all(s, "$LOGO$", app_logo_url(), context.temp_allocator)   // last: the longest
	return s
}

// What a development build says on the built-in pages: "DEV  Development build · commit 1a2b3c4, 2026-10-20" in a
// pill (class "dev", styled by the page); "" for the release.
dev_badge_html :: proc(with_commit := true) -> string {
	if !IS_DEV_BUILD { return "" }
	if !with_commit { return "<p class=\"dev\"><b>DEV</b>Development build: not a release</p>" }
	date := APP_COMMIT_DATE != "" ? fmt.tprintf(", %s", APP_COMMIT_DATE) : ""
	return fmt.tprintf("<p class=\"dev\"><b>DEV</b>Development build &middot; commit %s%s</p>", app_commit(), date)
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
	console_reset(t)
	page.load_html(t.page, transmute([]byte)home_html())
	delete(t.url); t.url = strings.clone(HOME_URL)
	delete(t.title); t.title = strings.clone("New tab")
	set_status(t, fmt.tprintf("%s %s", APP_NAME, APP_VERSION))
	ui.field_set(&app.address, "")   // the start page shows an empty address bar
}

package browser

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "toolkit:render"
import "wb:base"
import "wb:page"
import "wb:url"

// Identity of the program. One place, so a rename touches nothing else.
APP_NAME    :: "Wren"
APP_VERSION :: "0.6.19"
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

// "0.2.0 (1a2b3c4, 2026-10-20)", or "0.2.0 (dev)"; the version a user is shown, so with the build's label
// ("0.4.0-experimental-2026-10-25 (1a2b3c4, 2026-10-25)").
version_long :: proc() -> string {
	if APP_COMMIT_DATE != "" { return fmt.tprintf("%s (%s, %s)", APP_VERSION_SHOWN, app_commit(), APP_COMMIT_DATE) }
	return fmt.tprintf("%s (%s)", APP_VERSION_SHOWN, app_commit())
}

HOME_URL :: "about:home"

// about:home, with or without the art query (about:home?art=next). A built-in page like the others.
is_home_address :: proc(a: string) -> bool { return a == HOME_URL || strings.has_prefix(a, HOME_URL + "?") }

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
  .search { position: relative; max-width: 580px; margin: 40px auto 0; }
  .search input { display: block; width: 100%; box-sizing: border-box; height: 50px; padding: 0 56px 0 58px; border-radius: 25px; border: 1px solid #262e43;
                  background-color: #131824; color: #f1f4fb; font-family: system-ui; font-size: 16px; outline: none; }
  .search input::placeholder { color: #5f6a86; }
  .search input:hover { border-color: #38425d; }
  .search input:focus { border-color: $ACCENT$; background-color: #161c2a; }
  .search .lens { position: absolute; left: 18px; top: 13px; width: 24px; height: 24px; stroke: #7b86a3; fill: none; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
  .search button { position: absolute; right: 6px; top: 6px; width: 38px; height: 38px; padding: 0; border: 0; border-radius: 19px; background-color: transparent; color: #8993ad; cursor: pointer; }
  .search button:hover { background-color: rgba(255,255,255,0.07); color: #f1f4fb; }
  .search button svg { width: 24px; height: 24px; stroke: currentColor; fill: none; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
  .links { display: flex; justify-content: center; flex-wrap: wrap; gap: 4px 30px; max-width: 680px; margin: 30px auto 0; }
  .links a { display: inline-flex; align-items: center; gap: 9px; padding: 7px 2px; color: #8993ad; text-decoration: none; font-size: 15px; border-bottom: 1px solid transparent; }
  .links a svg, .paint a .ic { width: 17px; height: 17px; stroke: currentColor; fill: none; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
  .links a:hover { color: #f1f4fb; border-bottom-color: $ACCENT$; }
  .paint { text-align: center; margin: 60px 0 0; }
  .paint a { display: inline-flex; align-items: center; gap: 11px; padding: 8px 18px 8px 10px; border-radius: 22px; color: #8993ad; text-decoration: none; font-size: 14px; }
  .paint a:hover { color: #f1f4fb; background-color: rgba(255,255,255,0.06); }
  .paint a small { color: #59647f; font-size: 12px; margin-left: 2px; }
  .foot { text-align: center; color: #4f5a78; font-size: 13px; padding: 30px 20px 48px; }
  .foot b { color: #8993ad; }
  .foot img { width: 16px; height: 16px; vertical-align: -3px; margin: 0 5px; }
  .foot a { color: #8993ad; font-weight: 600; text-decoration: none; }
  .foot a:hover { color: #f1f4fb; }
  @media (prefers-color-scheme: light) {
    html { background-color: #f5f6fa; }
    body { color: #2b3245; }
    .logo { color: #1d2333; }
    .logo .w { color: $ACCENT_LIGHT$; }
    .tag { color: #5d6680; }
    .dev { background-color: #e8f0fc; border-color: #9dbbe8; color: #1d4f91; }
    .search input { background-color: #ffffff; border-color: #d3d8e4; color: #1d2333; }
    .search input::placeholder { color: #8a93aa; }
    .search input:hover { border-color: #b5bdd0; }
    .search input:focus { border-color: $ACCENT_LIGHT$; background-color: #ffffff; }
    .search .lens { stroke: #8a93aa; }
    .search button { color: #5d6680; }
    .search button:hover { background-color: rgba(0,0,0,0.06); color: #1d2333; }
    .links a { color: #5d6680; }
    .links a:hover { color: #1d2333; border-bottom-color: $ACCENT_LIGHT$; }
    .paint a { color: #5d6680; }
    .paint a:hover { color: #1d2333; background-color: rgba(0,0,0,0.05); }
    .paint a small { color: #8a93aa; }
    .foot { color: #8a93aa; }
    .foot b, .foot a { color: #5d6680; }
    .foot a:hover { color: #1d2333; }
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
  <form class="search" action="about:home" method="get" role="search">
    <svg class="lens" viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="7.5"/><path d="M16.2 16.2L21.5 21.5"/></svg>
    <input type="text" name="q" placeholder="$SEARCH$" autocomplete="off" spellcheck="false" aria-label="Search or type an address">
    <button type="submit" aria-label="Search"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 12h17M13.5 5l7 7-7 7"/></svg></button>
  </form>
  <nav class="links">
    <a href="about:config"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>Configuration</a>
    <a href="about:history"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>History</a>
    <a href="about:blocker"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l7 2.6v5.4c0 4.2-3 7.4-7 9-4-1.6-7-4.8-7-9V6.1z"/></svg>Content blocker</a>
    <a href="about:demos"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="6.5" height="6.5" rx="1.3"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.3"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.3"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.3"/></svg>Demos &amp; tests</a>
  </nav>
  <p class="paint"><a href="about:home?art=on"><svg viewBox="0 0 28 22" width="28" height="22" aria-hidden="true"><rect x="1" y="1" width="26" height="20" rx="2.5" fill="#c8923c"/><rect x="3.2" y="3.2" width="21.6" height="15.6" rx="1" fill="#7fb8e8"/><circle cx="19.5" cy="8" r="2.6" fill="#ffd36a"/><path d="M3.2 18.8V13.5Q8 9.5 12.5 13T24.8 12V18.8Z" fill="#4f9d69"/><path d="M3.2 18.8V16Q9 13.8 14 16.2T24.8 15.5V18.8Z" fill="#2f7a6a"/></svg>A painting on every new tab <small>off</small></a></p>
  <p class="foot"><b>$NAME$</b> $VERSION$ &middot; by<img src="$FROMENT_LOGO$" width="16" height="16" alt=""><a href="$FROMENT_URL$">Froment Software</a></p>
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
	s, _ = strings.replace_all(s, "$SEARCH$", escape_html(fmt.tprintf("Search with %s or type an address", search_engine_name())), context.temp_allocator)
	s, _ = strings.replace_all(s, "$FROMENT_URL$", FROMENT_URL, context.temp_allocator)
	s, _ = strings.replace_all(s, "$FROMENT_LOGO$", png_url(FROMENT_LOGO_PNG), context.temp_allocator)
	s, _ = strings.replace_all(s, "$LOGO$", app_logo_url(), context.temp_allocator)   // last: the longest
	return s
}

// The words a submission of the start page's search box carries (about:home?q=cats+and+dogs), decoded; ok when the address has a q.
home_search_words :: proc(target: string) -> (words: string, ok: bool) {
	if !strings.has_prefix(target, HOME_URL + "?") { return }
	query := target[len(HOME_URL) + 1:]
	if i := strings.index_byte(query, '#'); i >= 0 { query = query[:i] }
	sp := url.params_make(context.temp_allocator)
	url.params_parse(&sp, query)
	return url.params_get(sp, "q")
}

// What a development build says on the built-in pages: "DEV  Development build · commit 1a2b3c4, 2026-10-20" in a
// pill (class "dev", styled by the page); "" for the release.
dev_badge_html :: proc(with_commit := true) -> string {
	if !IS_DEV_BUILD { return "" }
	if !with_commit { return "<p class=\"dev\"><b>DEV</b>Development build: not a release</p>" }
	date := APP_COMMIT_DATE != "" ? fmt.tprintf(", %s", APP_COMMIT_DATE) : ""
	return fmt.tprintf("<p class=\"dev\"><b>DEV</b>Development build &middot; commit %s%s</p>", app_commit(), date)
}

// The start page is an ordinary document, styled by the same engine as every other page. When the artistic new tab is
// on (browser.newtab.art.*), it shows a painting instead (newtab_art_page.odin); `want_next` asks for a different one.
show_home :: proc(app: ^App, t: ^Tab, want_next := false) {
	if art_newtab_maybe(app, t, want_next) { return }
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
	address_set(app, t, "")   // the start page shows an empty address bar
}

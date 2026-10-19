package browser

import "core:fmt"
import "core:strings"
import "toolkit:ui"
import "wb:base"
import "wb:page"

// Identity of the program. One place, so a rename touches nothing else.
APP_NAME    :: "Wren"
APP_VERSION :: "0.1"
APP_TAGLINE :: "A small browser that runs WebAssembly, and nothing else."

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

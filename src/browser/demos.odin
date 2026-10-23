package browser

import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:page"

////////////////////////////////
// about:demos: every demo and test page that comes with Wren, by theme, with what each one shows.
//
// The pages are found, in this order: the folder of the preference browser.demos.path (a directory or a URL); demos\
// next to the executable (the release package: wren.exe and demos\ side by side); examples\site\ of the repository the
// executable was built in (build\wren.exe: the repository is a parent of the executable's folder); else the test
// server's /site/ (browser.demos.server_url). Pages that need the test server (images, media, form submission, first
// paint, CSP, generated images...) always link to it: they fetch its endpoints by absolute path.

DEMOS_URL :: "about:demos"

DEMOS_PREFS := [?]config.Def{
	{name = "browser.demos.path", kind = .String, default = {s = ""},
		description = "Where about:demos finds the demo pages: a folder (C:\\wren\\demos) or a URL (http://host/site/). Empty: demos\\ next to wren.exe, else examples\\site\\ of the repository the browser was built in, else the test server."},
	{name = "browser.demos.server_url", kind = .String, default = {s = "http://127.0.0.1:8765/"},
		description = "The test server (testserver.exe) that about:demos links to for the pages that need it (network images, form submission, slow stylesheets, CSP), and for every page when no folder of demos is found."},
}

register_demos_prefs :: proc(p: ^config.Prefs) { config.register(p, DEMOS_PREFS[:]) }

Demo_Theme :: enum u8 { Css, Layout, Rendering, Text, Images, Wasm, JavaScript, Network, Performance, E2e }

@(private)
DEMO_THEME_TITLES := [Demo_Theme]string{
	.Css         = "CSS engine",
	.Layout      = "Layout",
	.Rendering   = "Rendering and effects",
	.Text        = "Text",
	.Images      = "Images",
	.Wasm        = "WebAssembly APIs and workers",
	.JavaScript  = "JavaScript",
	.Network     = "Network and security",
	.Performance = "Performance and stress",
	.E2e         = "End-to-end tests",
}

Demo :: struct {
	theme:  Demo_Theme,
	title:  string,
	path:   string,   // in the demo folder ("images/many.html"); server-only: an absolute path of the server ("/start")
	about:  string,   // what it shows (HTML)
	server: bool,     // needs the test server: linked there
	tool:   string,   // an end-to-end test without a page: what runs it (path is then the page it loads, or "")
	perf:   bool,     // a page tools\perf.ps1 generates into build\perf (linked when it is there)
}

// Every page of examples\site (and the server-only pages of tools\testserver), by theme.
DEMOS := [?]Demo{
	{.Css, "Style engine", "style.html",
		"Selectors and the cascade, <code>@layer</code>, custom properties, <code>:hover</code> on cards, <code>::before</code>, <code>:nth-child</code> lists, a linked sheet with <code>@import</code>, and an <code>@media</code> rule below 600 px.", false, "", false},
	{.Css, "Modern CSS", "modern-css.html",
		"What sites write today: a variable WOFF2 web font, Color 4 and 5 (<code>oklch</code>, relative colors, <code>color-mix</code>), container queries, <code>@property</code> animations, <code>:has()</code> and <code>revert-layer</code>, <code>@supports</code>, math functions and units, <code>&lt;details&gt;</code>. Each section says what to expect.", false, "", false},
	{.Css, "Transitions and animations", "animations.html",
		"CSS only: hover transitions that reverse halfway, endless keyframe animations (spin, pulse, alternate, steps), nested <code>counters()</code>, quotes by depth, gradients, and a web font with <code>font-display: swap</code>. <code>style.animations.mode</code> turns motion down.", false, "", false},
	{.Css, "Cursors", "cursors.html",
		"Every value of <code>cursor</code> in a grid (Windows' own cursors, and those it lacks drawn in the same style), images as cursors (PNG and SVG with their hotspot, <code>image-set()</code>, fallbacks of an image too large or missing), <code>cursor: none</code>, and what <code>auto</code> shows over text, links, fields, <code>contenteditable</code>, <code>user-select: none</code> and scroll bars.", false, "", false},
	{.Css, "Color schemes", "firstpaint.html",
		"A dark theme chosen by <code>prefers-color-scheme</code> from stylesheets in <code>&lt;noscript&gt;</code>, <code>color-scheme</code>, system colors (CanvasText, LinkText, GrayText), <code>light-dark()</code> and form controls in both schemes. Its stylesheets come from the server.", true, "", false},

	{.JavaScript, "Frames: nested documents", "frames.html",
		"&lt;iframe&gt;s with documents of their own (their origin, scripts and JavaScript engine instance): same-origin and cross-origin frames, <code>srcdoc</code>, <code>sandbox</code>, <code>postMessage</code>, a form and links aimed at a named frame.", false, "", false},
	{.E2e, "Frames: the child page", "frames_child.html",
		"The document loaded in the frames of the frames demo.", false, "", false},
	{.E2e, "History: a long page", "history/long.html",
		"Scroll the page and its box, fill the form, follow the link, come back: from the back/forward cache at once, or loaded again and restored once tall enough (its second part arrives late). <code>tools\\history_e2e.ps1</code> does it in the window and times both.", false, "", false},
	{.E2e, "History: the next page", "history/next.html",
		"The page the long one links to: the back button's menu (right click) lists the way back.", false, "", false},
	{.E2e, "History: branches", "history/other.html",
		"Go back twice, then somewhere else: the old way stays as a branch of the tab's history tree (Ctrl+H, Tab history), where a click goes back to it.", false, "", false},

	{.Layout, "Layout engine", "layout.html",
		"Flexbox, floats and clearance, positioning and stacking order, tables, lists, overflow and scroll boxes, borders, preformatted text.", false, "", false},
	{.Layout, "CSS Grid", "grid.html",
		"Named areas, <code>repeat(auto-fill, minmax())</code> galleries, dense packing, alignment, nested grids with positioned boxes, and subgrid rows shared by cards.", false, "", false},
	{.Layout, "Presentational HTML", "legacy-html.html",
		"Old attributes mapped to CSS as the HTML Standard says: <code>&lt;center&gt;</code> and <code>align</code> moving narrower blocks, tables with <code>cellpadding</code>, <code>border</code>, <code>bgcolor</code>, <code>valign</code>, <code>&lt;font&gt;</code>, list types, <code>&lt;hr size noshade&gt;</code>, floated images with <code>hspace</code>, and an image whose square <code>width</code> / <code>height</code> attributes give way to its own ratio under <code>height: auto</code>.", false, "", false},

	{.Rendering, "CSS effects", "effects.html",
		"<code>filter</code> (blur, drop-shadow, color functions), <code>backdrop-filter</code> glass, every <code>mix-blend-mode</code>, animated <code>clip-path</code> shapes and shadows, drawn on the GPU; unchanged results are kept from frame to frame.", false, "", false},
	{.Rendering, "Masks, clipped text, legends, color glyphs", "paint.html",
		"<code>mask-image</code> (gradients, luminance, <code>mask-composite</code>, repetition, under opacity), icons drawn as masks, <code>background-clip: text</code>, fieldset legends on the border, rounded images, <code>scrollbar-color</code>, and COLR v1, sbix, SVG and emoji color glyphs.", false, "", false},
	{.Rendering, "Gradients and shadows", "gradients.html",
		"Linear, radial, conic and repeating gradients, interpolation color spaces, background layers (size, position, repeat, origin, clip) and <code>box-shadow</code>.", false, "", false},
	{.Rendering, "Canvas 2D", "canvas.html",
		"<code>getContext(\"2d\")</code> drawn in software: antialiased paths and strokes (caps, joins, dashes), gradients, patterns, clips, shadows, <code>filter</code>, compositing operators, text from glyph outlines, <code>ImageData</code>, <code>drawImage</code>, <code>ImageBitmap</code>, <code>toDataURL</code> and a <code>requestAnimationFrame</code> animation that uploads one texture per frame.", false, "", false},
	{.Rendering, "Transforms", "transforms.html",
		"Rotated text and blocks, nested rounded clips with a rotated one inside, a form turned by 10 degrees whose clicks land on the right character, group opacity, a transformed scroll box, and 500 cards turning forever over 300 static paragraphs.", false, "", false},
	{.Rendering, "3D transforms", "transforms-3d.html",
		"Real perspective: <code>perspective</code> and <code>perspective-origin</code>, <code>rotateX/Y</code>, <code>translateZ</code>, <code>preserve-3d</code> (a turning cube with six translucent faces sorted by depth, a carousel on a ring), a card that flips over with <code>backface-visibility: hidden</code>, and text on a tilted plane that is hit where it is drawn. Each 3D element is rasterized once into a layer the GPU projects; tilting it again costs one matrix.", false, "", false},

	{.Text, "Text: fallback, shaping, bidi", "text.html",
		"Per-character font fallback, color emoji, ligatures, kerning and OpenType features, complex scripts, bidirectional text, <code>unicode-range</code> (digits from another font), spacing and justification (the page is in French).", false, "", false},
	{.Text, "Text metrics and vertical alignment", "text-metrics.html",
		"Where text sits in its line, as in Chrome and Edge: <code>line-height: normal</code> from each font's rounded ascent, descent and line gap, numeric line heights, every <code>vertical-align</code> for spans and inline blocks, mixed fonts and emoji fallback, Wikipedia's <code>inline-flex</code> tabs with <code>min-height</code>, buttons, form controls on the baseline and table cells (the page is in French).", false, "", false},
	{.Text, "Web fonts: font-display after the first paint", "cache/font_block.html",
		"Text added after the first paint whose web font arrives 3 s later: with <code>font-display: block</code> it stays invisible during the block period instead of showing the fallback font, with <code>swap</code> the fallback shows at once and is swapped (the font is served slowly by the test server).", true, "", false},
	{.Text, "Selection, menus and keyboard", "interaction.html",
		"Double and triple click, drag selection across columns, <code>::selection</code>, <code>user-select</code>, a rotated selectable span, context menus, focus rings, find in page (Ctrl+F) and a scroll box.", false, "", false},

	{.Images, "Images", "images.html",
		"PNG, BMP, JPEG with EXIF orientation, ICO, TIFF, animated GIF, <code>object-fit</code>, <code>srcset</code> and <code>&lt;picture&gt;</code>, broken, missing, truncated and decompression-bomb files, cross-origin images, CSS backgrounds and lazy loading, all counted by the server.", true, "", false},
	{.Images, "Built-in image decoders", "media.html",
		"AVIF (8 and 10 bits, alpha, 4:4:4, rotation and mirroring, Display P3, animation), WebP (lossy, lossless, alpha, animation), Adobe RGB JPEG, <code>&lt;picture&gt;</code> and <code>Accept</code> negotiation, SVG as an image and as a background, inline <code>&lt;svg&gt;</code>.", true, "", false},
	{.Images, "External link icons", "media/dark-links.html",
		"An SVG icon in the <code>::after</code> background of external links, and <code>filter: invert()</code> to show it on a dark page.", true, "", false},

	{.Wasm, "A page with no JavaScript", "counter.html",
		"Real HTML whose behaviour is a WebAssembly module (<code>counter.wasm</code>, written in Odin): buttons, a ticking timer, DOM updates, and a relative link.", false, "", false},
	{.Wasm, "Page lifetime", "about.html",
		"Reached from the counter page: navigating closed the previous page, and freed its Wasm instance, its timer and its DOM with it.", false, "", false},
	{.Wasm, "Form controls", "forms.html",
		"Text, email, number, date, range, color, select and file controls, validation pseudo-classes (<code>:user-invalid</code>, <code>:out-of-range</code>), a Wasm module that reads, fills and validates the form, and a multipart POST to the server.", true, "", false},

	{.JavaScript, "JavaScript in WebAssembly", "js.html",
		"Plain HTML and JavaScript run by QuickJS-ng compiled to WebAssembly, one sandboxed instance per page: a click listener, nodes built with <code>createElement</code>, the bindings' prototype chain (generated from the specifications' Web IDL), ES2023 features and microtasks. Off with <code>javascript.enabled</code>.", false, "", false},
	{.JavaScript, "DOM from JavaScript", "js-dom.html",
		"A to-do list driven by <code>classList</code> and <code>dataset</code>, a <code>MutationObserver</code> log of the changes, a box resized from script and measured with <code>getBoundingClientRect</code>, and a form read through <code>elements</code> and <code>querySelectorAll</code> into a table.", false, "", false},
	{.JavaScript, "Shadow DOM", "shadow-dom.html",
		"Declarative shadow roots (<code>&lt;template shadowrootmode&gt;</code>) that render with JavaScript off: encapsulated styles, <code>:host</code>, <code>::slotted()</code>, <code>::part()</code> themed from the document, named and nested slots. From script: a tabs element with manual slot assignment and <code>delegatesFocus</code>, toggles sharing one constructed stylesheet through <code>adoptedStyleSheets</code> with a <code>:state()</code>, and a closed shadow tree whose events are retargeted to its host.", false, "", false},
	{.JavaScript, "Script loading", "/jsload/files/demo.html",
		"HTML's script processing: a head script before <code>&lt;body&gt;</code> exists, a deferred external script, a module with an import map, <code>document.write</code>, <code>&lt;noscript&gt;</code>, an <code>onclick</code> attribute, <code>setInterval</code>, and the order of <code>DOMContentLoaded</code> and <code>load</code>.", true, "", false},
	{.JavaScript, "Web APIs from JavaScript", "/jsweb/demo",
		"One row per API, run in the page's realm: <code>fetch</code> and response streams, <code>XMLHttpRequest</code>, <code>AbortSignal.timeout</code>, <code>URL</code>, <code>TextEncoder</code>, <code>crypto.subtle</code>, <code>localStorage</code>, <code>history.pushState</code>, <code>FileReader</code>, <code>structuredClone</code>, <code>MessageChannel</code>, <code>WebSocket</code> and <code>EventSource</code>.", true, "", false},

	{.Network, "Content-Security-Policy", "/site-csp/counter.html",
		"The counter page served with a policy that allows scripts only from unreachable hosts: its Wasm module is blocked, and the violation is reported.", true, "", false},
	{.Network, "Cookies and redirects", "/start",
		"Sets a cookie, then redirects to the counter page: the cookie and the redirect show in the page information of the address bar.", true, "", false},

	{.Performance, "Mutation every frame", "mutation.html",
		"A module builds about 10 000 elements, then changes one span's text every 16 ms: only that paragraph is laid out again.", false, "", false},
	{.Performance, "Class toggled every frame", "mutation_class.html",
		"A class toggled every 16 ms on a section among 10 000 elements: only what its rules reach is restyled and laid out again.", false, "", false},
	{.Performance, "200 large images", "images/many.html",
		"200 images of 1000 x 1000 pixels made by the server, shown at 80 px: decoding never runs on the interface thread.", true, "", false},
	{.Performance, "Slow stylesheet", "firstpaint-slow.html",
		"A stylesheet that takes 1.5 s: the previous page stays on screen until the new one can paint styled (paint holding); a print stylesheet blocks nothing.", true, "", false},
	{.Performance, "10 000 elements", "p10k.html",
		"The large page of the profiler's scenarios (load, scroll, hover, resize): made by <code>tools\\perf.ps1</code> in <code>build\\perf\\</code>.", false, "", true},
	{.Performance, "50 000 elements", "p50k.html",
		"The largest page of the profiler's scenarios, made by <code>tools\\perf.ps1</code> in <code>build\\perf\\</code>.", false, "", true},

	{.E2e, "Page test", "counter.html",
		"Loads the counter page headless and checks its DOM, its module and its timers.", true, "pagetest", false},
	{.E2e, "Style run-time test", "",
		"Web fonts, transitions and animations, checked frame by frame.", true, "styletest", false},
	{.E2e, "Forms test", "forms.html",
		"Controls, validation, <code>FormData</code> and submission through the form page.", true, "formstest", false},
	{.E2e, "Images test", "images.html",
		"Image events, <code>srcset</code>, <code>&lt;picture&gt;</code>, lazy loading, CSS images, the cache, cancellation, 200 images of 1 Mpx.", true, "imagestest", false},
	{.E2e, "Image formats test", "media.html",
		"AVIF, WebP and SVG images and backgrounds, inline <code>&lt;svg&gt;</code>, <code>Accept</code>, <code>&lt;picture&gt;</code>.", true, "mediatest", false},
	{.E2e, "Network policy test", "",
		"CORS, cookies, redirects, CSP, schemes and local files.", true, "policytest", false},
	{.E2e, "EventSource and WebSocket test", "",
		"Server-sent events (reconnection, wrong types, statuses) and WebSockets (echo, drops, compression, handshakes).", true, "netapitest", false},
	{.E2e, "Web platform API test", "",
		"Timers, <code>requestAnimationFrame</code>, abort signals, fetch streams, encoding, crypto, storage, URL and history.", true, "webapitest", false},
	{.E2e, "Workers test", "",
		"Dedicated workers: messages, transfers, fetch, termination, 16 in parallel.", true, "workerstest", false},
	{.E2e, "JavaScript test", "js.html",
		"Realms, scripts, the generated bindings, events, wrappers and node lifetime, the bytecode cache, interruption, and the cost of crossing into the browser.", false, "jstest", false},
	{.E2e, "DOM for JavaScript test", "js-dom.html",
		"Tree, elements, markup, selectors, CSSOM, geometry, UI events, <code>MutationObserver</code>, traversal, ranges, leaks and micro-benchmarks.", false, "jsdomtest", false},
	{.E2e, "JavaScript loading test", "/jsload/files/demo.html",
		"Script order, <code>document.write</code>, dynamic scripts, modules, handlers, CSP, <code>&lt;noscript&gt;</code>, timers, errors, workers.", true, "jsloadtest", false},
	{.E2e, "JavaScript web APIs test", "/jsweb/demo",
		"fetch, XHR, streams, URL, encoding, abort, storage, history, navigator, crypto, sockets, messaging.", true, "jswebtest", false},
}

Demos_Source :: enum u8 { Preference, Package, Repository, Server }

// Where the pages are: a base URL ending in '/', and where it came from.
demos_base :: proc(app: ^App, allocator := context.temp_allocator) -> (base_url: string, source: Demos_Source) {
	server := demos_server(app)
	if p := strings.trim_space(config.string_of(&app.prefs, "browser.demos.path")); p != "" {
		if strings.contains(p, "://") { return with_slash(p, allocator), .Preference }
		return file_url_of_dir(p, allocator), .Preference
	}
	exe := exe_directory()
	if exe != "" {
		if d := strings.concatenate({exe, "\\demos"}, context.temp_allocator); is_file(strings.concatenate({d, "\\index.html"}, context.temp_allocator)) {
			return file_url_of_dir(d, allocator), .Package
		}
		if repo := repository_of(exe); repo != "" {
			return file_url_of_dir(strings.concatenate({repo, "\\examples\\site"}, context.temp_allocator), allocator), .Repository
		}
	}
	return strings.concatenate({server, "site/"}, allocator), .Server
}

@(private = "file")
demos_server :: proc(app: ^App) -> string {
	s := strings.trim_space(config.string_of(&app.prefs, "browser.demos.server_url"))
	if s == "" { s = "http://127.0.0.1:8765/" }
	return with_slash(s, context.temp_allocator)
}

@(private = "file")
with_slash :: proc(s: string, allocator := context.temp_allocator) -> string {
	return strings.has_suffix(s, "/") ? strings.clone(s, allocator) : strings.concatenate({s, "/"}, allocator)
}

// The folder of the running executable (no trailing separator).
exe_directory :: proc() -> string {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.GetModuleFileNameW(nil, raw_data(buf[:]), u32(len(buf)))
	if n == 0 || int(n) >= len(buf) { return "" }
	path, err := win.wstring_to_utf8(win.wstring(raw_data(buf[:])), int(n), context.temp_allocator)
	if err != nil { return "" }
	i := strings.last_index_byte(path, '\\')
	return i > 0 ? path[:i] : ""
}

// The repository a development build runs from: the nearest parent (up to three levels) with examples\site\index.html.
@(private = "file")
repository_of :: proc(dir: string) -> string {
	d := dir
	for _ in 0 ..< 4 {
		if is_file(strings.concatenate({d, "\\examples\\site\\index.html"}, context.temp_allocator)) { return d }
		i := strings.last_index_byte(d, '\\')
		if i <= 0 { break }
		d = d[:i]
	}
	return ""
}

is_file :: proc(path: string) -> bool {
	attr := win.GetFileAttributesW(win.utf8_to_wstring(path, context.temp_allocator))
	return attr != win.INVALID_FILE_ATTRIBUTES && attr & win.FILE_ATTRIBUTE_DIRECTORY == 0
}

// "C:\dir\my demos" -> "file:///C:/dir/my%20demos/" ("\\host\share\d" -> "file://host/share/d/"): bytes other than
// unreserved characters, '/' and ':' are percent-encoded (UTF-8).
file_url_of_dir :: proc(dir: string, allocator := context.temp_allocator) -> string {
	return fetch.file_url_from_path(dir, directory = true, allocator = allocator)
}

@(private = "file")
html_escape :: proc(sb: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '&': strings.write_string(sb, "&amp;")
		case '<': strings.write_string(sb, "&lt;")
		case '>': strings.write_string(sb, "&gt;")
		case '"': strings.write_string(sb, "&quot;")
		case: strings.write_rune(sb, r)
		}
	}
}

// The link of a demo ("" for a test without a page, or a generated page that is not there).
demo_href :: proc(app: ^App, d: Demo, base_url: string, allocator := context.temp_allocator) -> string {
	server := demos_server(app)
	switch {
	case d.path == "": return ""
	case d.perf:
		exe := exe_directory()
		if exe == "" { return "" }
		repo := repository_of(exe)
		if repo == "" { return "" }
		file := strings.concatenate({repo, "\\build\\perf\\", d.path}, context.temp_allocator)
		if !is_file(file) { return "" }
		return strings.concatenate({file_url_of_dir(strings.concatenate({repo, "\\build\\perf"}, context.temp_allocator), context.temp_allocator), d.path}, allocator)
	case strings.has_prefix(d.path, "/"): return strings.concatenate({strings.trim_right(server, "/"), d.path}, allocator)
	case d.server: return strings.concatenate({server, "site/", d.path}, allocator)
	}
	return strings.concatenate({base_url, d.path}, allocator)
}

@(private)
DEMOS_STYLE :: `
  html { background-color: #0d1017; }
  body { margin: 0; color: #c9d1e3; font-family: system-ui; font-size: 15px; }
  .head { max-width: 760px; margin: 0 auto; padding: 48px 20px 8px; }
  h1 { font-size: 40px; margin: 0; color: #f1f4fb; }
  h1 .w { color: #ffb84d; }
  .intro { color: #8993ad; margin: 8px 0 0; }
  .from { margin: 16px 0 0; padding: 10px 16px; background-color: #151a26; border: 1px solid #272f45; border-radius: 10px; color: #8993ad; font-size: 13px; }
  .from code { color: #c9d1e3; }
  .main { max-width: 760px; margin: 0 auto; padding: 0 20px 48px; }
  h2 { font-size: 20px; color: #ffb84d; margin: 30px 0 4px; }
  .demo { margin: 10px 0; padding: 12px 18px; background-color: #131825; border: 1px solid #232b40; border-radius: 12px; }
  .demo h3 { margin: 0 0 4px; font-size: 16px; }
  .demo h3 a { color: #f1f4fb; text-decoration: none; }
  .demo h3 a:hover { color: #ffb84d; }
  .demo h3 a:active { color: #ffd699; }
  .demo h3 .off { color: #8993ad; }
  .demo p { margin: 0; color: #8993ad; line-height: 1.4; }
  .demo code { color: #c9d1e3; background-color: #1b2132; padding: 0 3px; border-radius: 3px; }
  .demo .where { color: #4f5a78; font-size: 12px; margin-top: 6px; }
  .badge { display: inline-block; margin-left: 8px; padding: 1px 8px; border-radius: 9px; font-size: 11px; font-weight: normal; vertical-align: middle; }
  .srv { background-color: #3b2a10; color: #ffb84d; border: 1px solid #6b4a14; }
  .tool { background-color: #1a2a3b; color: #74c0fc; border: 1px solid #1c4a6e; }
  .foot { text-align: center; color: #4f5a78; font-size: 13px; padding: 12px 20px 40px; }
  .foot b { color: #8993ad; }
`

demos_html :: proc(app: ^App) -> string {
	base_url, source := demos_base(app)
	server := demos_server(app)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Demos and tests</title>\n<style>")
	strings.write_string(&sb, DEMOS_STYLE)
	strings.write_string(&sb, "</style>\n</head>\n<body>\n<div class=\"head\">\n<h1><span class=\"w\">W</span>ren demos and tests</h1>\n")
	strings.write_string(&sb, "<p class=\"intro\">Every page that comes with the browser, by theme, with what it shows. Pages marked <span class=\"badge srv\">test server</span> fetch from <b>testserver.exe</b> (")
	html_escape(&sb, server)
	strings.write_string(&sb, "): start it first (<code>demo.bat</code> in the release, <code>build\\testserver.exe</code> from the repository).</p>\n<p class=\"from\">Pages from <code>")
	html_escape(&sb, base_url)
	switch source {
	case .Preference: strings.write_string(&sb, "</code> (preference <code>browser.demos.path</code>).")
	case .Package:    strings.write_string(&sb, "</code> (the <code>demos</code> folder next to the browser).")
	case .Repository: strings.write_string(&sb, "</code> (the repository the browser was built in).")
	case .Server:     strings.write_string(&sb, "</code>: no <code>demos</code> folder next to the browser, every page needs the test server. <code>browser.demos.path</code> in about:config points to another folder.")
	}
	strings.write_string(&sb, "</p>\n</div>\n<div class=\"main\">\n")
	for theme in Demo_Theme {
		strings.write_string(&sb, "<h2>")
		strings.write_string(&sb, DEMO_THEME_TITLES[theme])
		strings.write_string(&sb, "</h2>\n")
		if theme == .E2e {
			strings.write_string(&sb, "<p class=\"intro\">Run without a window by <code>tools\\test_all.ps1</code> (from the repository, with the test server it starts itself).</p>\n")
		}
		for d in DEMOS {
			if d.theme != theme { continue }
			href := demo_href(app, d, base_url)
			strings.write_string(&sb, "<div class=\"demo\"><h3>")
			if d.tool == "" && href != "" {
				strings.write_string(&sb, "<a href=\"")
				html_escape(&sb, href)
				strings.write_string(&sb, "\">")
				html_escape(&sb, d.title)
				strings.write_string(&sb, "</a>")
			} else {
				strings.write_string(&sb, "<span class=\"off\">")
				html_escape(&sb, d.title)
				strings.write_string(&sb, "</span>")
			}
			if d.server { strings.write_string(&sb, "<span class=\"badge srv\">test server</span>") }
			if d.tool != "" { fmt.sbprintf(&sb, "<span class=\"badge tool\">%s</span>", d.tool) }
			strings.write_string(&sb, "</h3><p>")
			strings.write_string(&sb, d.about)   // (our own HTML)
			strings.write_string(&sb, "</p>")
			switch {
			case d.tool != "" && href != "":
				strings.write_string(&sb, "<p class=\"where\">page: <a href=\"")
				html_escape(&sb, href)
				strings.write_string(&sb, "\">")
				html_escape(&sb, d.path)
				strings.write_string(&sb, "</a></p>")
			case d.perf && href == "":
				strings.write_string(&sb, "<p class=\"where\">not generated yet: run <code>tools\\perf.ps1</code> from the repository</p>")
			case href != "":
				strings.write_string(&sb, "<p class=\"where\">")
				html_escape(&sb, href)
				strings.write_string(&sb, "</p>")
			}
			strings.write_string(&sb, "</div>\n")
		}
	}
	fmt.sbprintf(&sb, "</div>\n<p class=\"foot\"><b>%s</b> %s &middot; <a href=\"%s\" style=\"color: #8993ad\">home</a></p>\n</body>\n</html>\n", APP_NAME, APP_VERSION, HOME_URL)
	return strings.to_string(sb)
}

// Built like the start page: an ordinary document styled by the engine; its links open the pages as if typed in the
// address bar (navigate: a built-in page is the browser's own UI, so it may open local files).
show_demos :: proc(app: ^App, t: ^Tab) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, DEMOS_URL, console_sink, t)
	attach_page(app, t, t.page)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	for l in t.console { delete(l) }
	clear(&t.console)
	page.load_html(t.page, transmute([]byte)demos_html(app))
	delete(t.url); t.url = strings.clone(DEMOS_URL)
	delete(t.title); t.title = strings.clone("Demos and tests")
	set_status(t, DEMOS_URL)
	ui.field_set(&app.address, DEMOS_URL)
}

// A document of the browser itself (about:home, about:demos): what it opens is opened by the browser's UI.
builtin_document :: proc(p: ^page.Page) -> bool {
	if p == nil { return false }
	h := p.env.location.href
	return h == HOME_URL || h == DEMOS_URL || h == ABOUT_URL || is_wren_address(h)
}

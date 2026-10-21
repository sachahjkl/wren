package browser

import "core:fmt"
import "core:strings"

////////////////////////////////
// examples\site\index.html: the index of every demo, made from the same table as about:demos (DEMOS, demos.odin), so
// that opening the demo folder (the repository's, demos\ of the release, the test server's /site/) shows the list.
// It is a file of the repository: demos_index_test.odin fails when it no longer matches the table, and writes it
// again with -define:WREN_WRITE_DEMOS_INDEX=true.
//
// Links are relative (the page works from any folder); the pages that need the test server link to it
// (DEMOS_INDEX_SERVER), as about:demos does: they fetch its endpoints by absolute path.

DEMOS_INDEX_PATH   :: "examples/site/index.html"
DEMOS_INDEX_SERVER :: "http://127.0.0.1:8765/"   // the default of browser.demos.server_url

@(private = "file")
DEMOS_INDEX_STYLE :: `
  :root { color-scheme: light dark; }
  html { background-color: light-dark(#f6f7fb, #0d1017); }
  body { margin: 0; color: light-dark(#1d2433, #c9d1e3); font-family: system-ui; font-size: 15px; }
  .head, .main { max-width: 800px; margin: 0 auto; padding: 0 20px; }
  .head { padding-top: 44px; }
  h1 { font-size: 36px; margin: 0; color: light-dark(#0f1420, #f1f4fb); }
  h1 .w { color: light-dark(#c26a00, #ffb84d); }
  .intro { color: light-dark(#596278, #8993ad); margin: 8px 0 0; line-height: 1.45; }
  code { background-color: light-dark(#e8ebf2, #1b2132); padding: 0 3px; border-radius: 3px; }
  nav { margin: 18px 0 0; font-size: 14px; }
  nav a { margin-right: 14px; }
  a { color: light-dark(#0b5cad, #74c0fc); text-decoration: none; }
  a:hover { text-decoration: underline; }
  a:active { color: light-dark(#06417a, #a5d8ff); }
  h2 { font-size: 20px; color: light-dark(#c26a00, #ffb84d); margin: 32px 0 6px; }
  .demo { margin: 10px 0; padding: 11px 16px; background-color: light-dark(#ffffff, #131825); border: 1px solid light-dark(#dde1ea, #232b40); border-radius: 10px; }
  .demo h3 { margin: 0 0 3px; font-size: 16px; }
  .demo h3 .off { color: light-dark(#596278, #8993ad); }
  .demo p { margin: 0; color: light-dark(#4a5368, #8993ad); line-height: 1.4; }
  .demo .where { color: light-dark(#7a8296, #4f5a78); font-size: 12px; margin-top: 5px; }
  .badge { display: inline-block; margin-left: 8px; padding: 1px 8px; border-radius: 9px; font-size: 11px; font-weight: normal; vertical-align: middle; }
  .srv { background-color: light-dark(#fff1d6, #3b2a10); color: light-dark(#8a4b00, #ffb84d); border: 1px solid light-dark(#f0c779, #6b4a14); }
  .tool { background-color: light-dark(#dcecfb, #1a2a3b); color: light-dark(#0b5cad, #74c0fc); border: 1px solid light-dark(#9cc7ee, #1c4a6e); }
  .foot { max-width: 800px; margin: 0 auto; padding: 24px 20px 44px; color: light-dark(#7a8296, #4f5a78); font-size: 13px; }
`

@(private = "file")
index_escape :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(sb, "&amp;")
		case '<': strings.write_string(sb, "&lt;")
		case '>': strings.write_string(sb, "&gt;")
		case '"': strings.write_string(sb, "&quot;")
		case: strings.write_byte(sb, s[i])
		}
	}
}

@(private = "file")
theme_anchor :: proc(theme: Demo_Theme) -> string {
	switch theme {
	case .Css:         return "css"
	case .Layout:      return "layout"
	case .Rendering:   return "rendering"
	case .Text:        return "text"
	case .Images:      return "images"
	case .Wasm:        return "wasm"
	case .JavaScript:  return "javascript"
	case .Network:     return "network"
	case .Performance: return "performance"
	case .E2e:         return "tests"
	}
	return "x"
}

// The link of a demo from the index ("" when it has no page here): relative inside the folder, absolute to the test
// server for the pages that need it.
demos_index_href :: proc(d: Demo, allocator := context.temp_allocator) -> string {
	switch {
	case d.path == "" || d.perf: return ""
	case strings.has_prefix(d.path, "/"): return strings.concatenate({strings.trim_right(DEMOS_INDEX_SERVER, "/"), d.path}, allocator)
	case d.server: return strings.concatenate({DEMOS_INDEX_SERVER, "site/", d.path}, allocator)
	}
	return strings.clone(d.path, allocator)
}

// The whole page; the same bytes for the same table (no date, no version).
demos_index_html :: proc(allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "<!doctype html>\n<!-- Made from the DEMOS table of src/browser/demos.odin (demos_index.odin): edit the table, not this file. -->\n")
	strings.write_string(&sb, "<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"color-scheme\" content=\"light dark\">\n<title>Wren demos and tests</title>\n<style>")
	strings.write_string(&sb, DEMOS_INDEX_STYLE)
	strings.write_string(&sb, "</style>\n</head>\n<body>\n<div class=\"head\">\n<h1><span class=\"w\">W</span>ren demos and tests</h1>\n")
	strings.write_string(&sb, "<p class=\"intro\">Every page that comes with the browser, by theme, with what it shows. The pages marked <span class=\"badge srv\">test server</span> load from <b>testserver.exe</b> (")
	index_escape(&sb, DEMOS_INDEX_SERVER)
	strings.write_string(&sb, "): start it first (<code>demo.bat</code> in the release, <code>build\\testserver.exe</code> from the repository). The same list is built into the browser: <a href=\"about:demos\">about:demos</a>.</p>\n<nav>")
	for theme in Demo_Theme {
		fmt.sbprintf(&sb, "<a href=\"#%s\">", theme_anchor(theme))
		index_escape(&sb, DEMO_THEME_TITLES[theme])
		strings.write_string(&sb, "</a>")
	}
	strings.write_string(&sb, "</nav>\n</div>\n<div class=\"main\">\n")
	for theme in Demo_Theme {
		fmt.sbprintf(&sb, "<h2 id=\"%s\">", theme_anchor(theme))
		index_escape(&sb, DEMO_THEME_TITLES[theme])
		strings.write_string(&sb, "</h2>\n")
		if theme == .E2e {
			strings.write_string(&sb, "<p class=\"intro\">Run without a window by <code>tools\\test_all.ps1</code> (from the repository, with the test server it starts itself).</p>\n")
		}
		for d in DEMOS {
			if d.theme != theme { continue }
			href := demos_index_href(d)
			strings.write_string(&sb, "<div class=\"demo\"><h3>")
			if d.tool == "" && href != "" {
				strings.write_string(&sb, "<a href=\"")
				index_escape(&sb, href)
				strings.write_string(&sb, "\">")
				index_escape(&sb, d.title)
				strings.write_string(&sb, "</a>")
			} else {
				strings.write_string(&sb, "<span class=\"off\">")
				index_escape(&sb, d.title)
				strings.write_string(&sb, "</span>")
			}
			if d.server { strings.write_string(&sb, "<span class=\"badge srv\">test server</span>") }
			if d.tool != "" {
				strings.write_string(&sb, "<span class=\"badge tool\">")
				index_escape(&sb, d.tool)
				strings.write_string(&sb, "</span>")
			}
			strings.write_string(&sb, "</h3><p>")
			strings.write_string(&sb, d.about)   // (our own HTML)
			strings.write_string(&sb, "</p>")
			switch {
			case d.tool != "" && href != "":
				strings.write_string(&sb, "<p class=\"where\">page: <a href=\"")
				index_escape(&sb, href)
				strings.write_string(&sb, "\">")
				index_escape(&sb, d.path)
				strings.write_string(&sb, "</a></p>")
			case d.perf:
				strings.write_string(&sb, "<p class=\"where\">made by <code>tools\\perf.ps1</code> in <code>build\\perf\\</code> of the repository; about:demos links to it once it is there</p>")
			}
			strings.write_string(&sb, "</div>\n")
		}
	}
	strings.write_string(&sb, "</div>\n<p class=\"foot\">Wren &middot; WebAssembly only &middot; a folder opened in Wren shows its <code>index.html</code>, or the list of its files.</p>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

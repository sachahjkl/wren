// Assemble one HTML page from a parsed Markdown body: the <head>, the top bar (shared with the main site), a tree
// sidebar, the breadcrumb, the article, its table of contents, the previous/next links and the "Edit on GitHub"
// link. Every href is a root-absolute path under /docs/ so a page at any depth links correctly, and so the search
// index can use the same paths. The conformance page's two directives (<!-- docsite:chart -->, <!-- docsite:wpt-table -->)
// are substituted before the Markdown is parsed.
package docsite

import "core:os"
import "core:strings"

render_page :: proc(p: ^Page, nav: ^Nav, pages: []Page, by_rel: map[string]^Page, search: ^[dynamic]Search_Doc) -> string {
	data, err := os.read_entire_file(p.src_path, context.allocator)
	if err != nil { return "" }
	source := string(data)

	// per-page directive substitution (the conformance page)
	source = apply_directives(source)

	// parse the Markdown; links are rewritten relative to this page's folder
	rc := Rewrite_Ctx{cur = p.rel}
	md := Md_Context{rewrite = rewrite_link, user = &rc, seen_ids = make(map[string]int, context.temp_allocator)}
	body := render_markdown(source, &md, context.allocator)

	// feed the search index
	append(search, Search_Doc{
		url     = url_of(p.out_rel),
		title   = p.title,
		section = p.section,
		text    = collapse_ws(body.plain),
	})

	b := strings.builder_make()
	ws := strings.write_string
	ws(&b, GENERATED_NOTE)
	ws(&b, "\n<!doctype html>\n<html lang=\"en\">\n<head>\n")
	ws(&b, "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
	ws(&b, "<title>")
	write_html_escaped(&b, p.title)
	ws(&b, " · Wren docs</title>\n")
	ws(&b, "<meta name=\"description\" content=\"")
	write_attr_escaped(&b, meta_description(body.plain, p.title))
	ws(&b, "\">\n")
	// icons and CSS live at the site root; from /docs/... that is ../img and ../style.css
	ws(&b, "<link rel=\"icon\" type=\"image/png\" sizes=\"32x32\" href=\"/img/logo-32.png\">\n")
	ws(&b, "<link rel=\"stylesheet\" href=\"/style.css\">\n")
	ws(&b, "<link rel=\"stylesheet\" href=\"/docs/docs.css\">\n")
	ws(&b, "</head>\n<body class=\"docs\">\n")
	ws(&b, "<a class=\"skip\" href=\"#doc-main\">Skip to content</a>\n")

	write_header(&b, "Docs")

	ws(&b, "<div class=\"doc-shell\">\n")

	// sidebar (collapsible on mobile with a checkbox, no script)
	ws(&b, "<input class=\"doc-nav-toggle\" type=\"checkbox\" id=\"doc-nav\">\n")
	ws(&b, "<label class=\"doc-nav-open\" for=\"doc-nav\"><span></span><span></span><span></span> Documentation</label>\n")
	ws(&b, "<aside class=\"doc-side\" aria-label=\"Documentation sections\">\n<nav class=\"doc-tree\">\n")
	write_sidebar(&b, nav, p.rel)
	ws(&b, "</nav>\n</aside>\n")

	// article
	ws(&b, "<main id=\"doc-main\" class=\"doc-main\">\n<article class=\"doc-article\">\n")
	write_breadcrumb(&b, p)
	ws(&b, body.html)
	write_prev_next(&b, nav, p, by_rel)
	write_edit_link(&b, p)
	ws(&b, "</article>\n")

	// table of contents (right rail)
	write_toc(&b, body.headings[:])

	ws(&b, "</main>\n</div>\n")

	write_footer(&b)

	ws(&b, "<script src=\"/docs/search.js\" defer></script>\n")
	ws(&b, "</body>\n</html>\n")
	return strings.to_string(b)
}

// The site's top bar, with "Docs" marked current here. Kept in step with site/*.html by hand (the brief owns those).
write_header :: proc(b: ^strings.Builder, current: string) {
	ws := strings.write_string
	ws(b, "<header class=\"top\">\n<div class=\"wrap\">\n")
	ws(b, "<a class=\"brand\" href=\"/index.html\"><img src=\"/img/logo-64.png\" alt=\"\" width=\"30\" height=\"30\">Wren</a>\n")
	ws(b, "<input class=\"menu-check\" type=\"checkbox\" id=\"menu\">\n")
	ws(b, "<label class=\"burger\" for=\"menu\" aria-label=\"Menu\"><span></span><span></span><span></span></label>\n")
	ws(b, "<ul class=\"nav\">\n")
	items := [?][2]string{
		{"/index.html#features", "Features"},
		{"/gallery.html", "Gallery"},
		{"/architecture.html", "Architecture"},
		{"/docs/index.html", "Docs"},
		{"/write.html", "Write a page"},
		{"/changelog.html", "Changelog"},
		{"/support.html", "Pricing"},
	}
	for it in items {
		ws(b, "<li><a href=\"")
		ws(b, it[0])
		ws(b, "\"")
		if it[1] == current { ws(b, " aria-current=\"page\"") }
		ws(b, ">")
		write_html_escaped(b, it[1])
		ws(b, "</a></li>\n")
	}
	ws(b, "<li><a class=\"btn primary nav-dl\" href=\"")
	ws(b, REPO_URL)
	ws(b, "/releases/latest\">Download</a></li>\n")
	ws(b, "</ul>\n</div>\n</header>\n")
}

write_footer :: proc(b: ^strings.Builder) {
	ws := strings.write_string
	ws(b, "<footer class=\"site-foot\">\n<div class=\"wrap\">\n")
	ws(b, "<p class=\"foot-line\">Wren · a browser where WebAssembly runs everything · by ")
	ws(b, "<span class=\"maker\"><img src=\"/img/froment-software-64.png\" alt=\"\" width=\"16\" height=\"16\"><a href=\"https://froment.software\">Froment Software</a></span></p>\n")
	ws(b, "<nav class=\"foot-links\">\n")
	ws(b, "<a href=\"/docs/index.html\">Docs</a>\n")
	ws(b, "<a href=\"/changelog.html\">Changelog</a>\n")
	ws(b, "<a href=\"/support.html\">Pricing</a>\n")
	ws(b, "<a href=\"/privacy.html\">Privacy</a>\n")
	ws(b, "<a href=\"/terms.html\">Terms</a>\n")
	ws(b, "<a href=\"")
	ws(b, REPO_URL)
	ws(b, "\">GitHub</a>\n")
	ws(b, "</nav>\n</div>\n</footer>\n")
}

write_sidebar :: proc(b: ^strings.Builder, nav: ^Nav, current: string) {
	ws := strings.write_string
	// the search box at the top of the tree
	ws(b, "<form class=\"doc-search\" role=\"search\" onsubmit=\"return false\">\n")
	ws(b, "<input id=\"doc-search-input\" type=\"search\" placeholder=\"Search docs… (press /)\" autocomplete=\"off\" aria-label=\"Search documentation\">\n")
	ws(b, "<div id=\"doc-search-results\" class=\"doc-search-results\" hidden></div>\n")
	ws(b, "</form>\n")
	for sec in nav.roots {
		ws(b, "<div class=\"doc-sec\">\n<p class=\"doc-sec-title\">")
		write_html_escaped(b, sec.title)
		ws(b, "</p>\n")
		write_nav_children(b, sec.children[:], current)
		ws(b, "</div>\n")
	}
}

write_nav_children :: proc(b: ^strings.Builder, items: []^Nav_Item, current: string) {
	ws := strings.write_string
	ws(b, "<ul class=\"doc-links\">\n")
	for it in items {
		if it.rel == "" {
			// a sub-group (a directory like the API): a label then its children
			open := contains_current(it, current)
			ws(b, "<li class=\"doc-group\"><details")
			if open { ws(b, " open") }
			ws(b, "><summary>")
			write_html_escaped(b, it.title)
			ws(b, "</summary>\n")
			write_nav_children(b, it.children[:], current)
			ws(b, "</details></li>\n")
			continue
		}
		ws(b, "<li><a href=\"")
		ws(b, url_of(out_rel_of(it.rel)))
		ws(b, "\"")
		if it.rel == current { ws(b, " aria-current=\"page\" class=\"active\"") }
		ws(b, ">")
		write_html_escaped(b, it.title)
		ws(b, "</a></li>\n")
	}
	ws(b, "</ul>\n")
}

contains_current :: proc(item: ^Nav_Item, current: string) -> bool {
	if item.rel == current { return true }
	for c in item.children { if contains_current(c, current) { return true } }
	return false
}

write_breadcrumb :: proc(b: ^strings.Builder, p: ^Page) {
	ws := strings.write_string
	ws(b, "<nav class=\"doc-crumbs\" aria-label=\"Breadcrumb\"><ol>\n")
	ws(b, "<li><a href=\"/docs/index.html\">Docs</a></li>\n")
	if p.section != "" && p.rel != "index.md" {
		ws(b, "<li>")
		write_html_escaped(b, p.section)
		ws(b, "</li>\n")
	}
	ws(b, "<li aria-current=\"page\">")
	write_html_escaped(b, p.title)
	ws(b, "</li>\n")
	ws(b, "</ol></nav>\n")
}

write_toc :: proc(b: ^strings.Builder, headings: []Heading) {
	// a table of contents of the H2/H3 of the page; skipped when there are too few
	count := 0
	for h in headings { if h.level == 2 || h.level == 3 { count += 1 } }
	if count < 2 { return }
	ws := strings.write_string
	ws(b, "<nav class=\"doc-toc\" aria-label=\"On this page\">\n<p class=\"doc-toc-title\">On this page</p>\n<ul>\n")
	for h in headings {
		if h.level != 2 && h.level != 3 { continue }
		ws(b, h.level == 3 ? "<li class=\"lvl3\"><a href=\"#" : "<li><a href=\"#")
		ws(b, h.id)
		ws(b, "\">")
		write_html_escaped(b, h.text)
		ws(b, "</a></li>\n")
	}
	ws(b, "</ul>\n</nav>\n")
}

write_prev_next :: proc(b: ^strings.Builder, nav: ^Nav, p: ^Page, by_rel: map[string]^Page) {
	idx := -1
	for rel, i in nav.order { if rel == p.rel { idx = i; break } }
	if idx < 0 { return }
	ws := strings.write_string
	ws(b, "<nav class=\"doc-seq\" aria-label=\"Previous and next page\">\n")
	if idx > 0 {
		prev := by_rel[nav.order[idx - 1]]
		if prev != nil {
			ws(b, "<a class=\"doc-prev\" href=\"")
			ws(b, url_of(prev.out_rel))
			ws(b, "\"><span>Previous</span><strong>")
			write_html_escaped(b, prev.title)
			ws(b, "</strong></a>\n")
		}
	}
	if idx < len(nav.order) - 1 {
		next := by_rel[nav.order[idx + 1]]
		if next != nil {
			ws(b, "<a class=\"doc-next\" href=\"")
			ws(b, url_of(next.out_rel))
			ws(b, "\"><span>Next</span><strong>")
			write_html_escaped(b, next.title)
			ws(b, "</strong></a>\n")
		}
	}
	ws(b, "</nav>\n")
}

write_edit_link :: proc(b: ^strings.Builder, p: ^Page) {
	ws := strings.write_string
	ws(b, "<p class=\"doc-edit\"><a href=\"")
	ws(b, REPO_URL)
	ws(b, "/blob/")
	ws(b, REPO_BRANCH)
	ws(b, "/docs/")
	ws(b, p.rel)
	ws(b, "\" rel=\"noopener\">Edit this page on GitHub</a></p>\n")
}

// the root-absolute URL of a generated page: "cdp.html" -> "/docs/cdp.html"
url_of :: proc(out_rel: string) -> string {
	return strings.concatenate({"/docs/", out_rel}, context.allocator)
}

// A short description from the first sentence of the body text.
meta_description :: proc(plain: string, title: string) -> string {
	t := collapse_ws(plain)
	if len(t) == 0 { return strings.concatenate({title, " — Wren documentation."}, context.allocator) }
	// cut at the first sentence end or 160 chars
	limit := min(len(t), 170)
	cut := limit
	for i in 0 ..< limit {
		if t[i] == '.' && i + 1 < len(t) && t[i + 1] == ' ' { cut = i + 1; break }
	}
	return t[:cut]
}

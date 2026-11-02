// Rewriting the relative links the docs use. A link from docs/<cur> to another doc is resolved against <cur>'s
// directory and mapped to the site URL:
//   web.md            (from api/dom.md)        -> /docs/api/web/
//   ../remote.md      (from api/dom.md)        -> /docs/remote/
//   releases/v0.5.0.md                          -> /docs/releases/v0.5.0/
//   ../site/pricing/index.html                  -> /pricing/
// A fragment is carried through (#anchor). Any other relative link (../README.md, ../licence/worker/, an image under
// docs/) is not published with the site, so it becomes a GitHub link at the pinned branch. Absolute URLs, mailto and
// fragments-only are left untouched (rewrite returns "").
package docsite

import "core:strings"

Rewrite_Ctx :: struct {
	cur: string, // the current doc, relative to docs/ ("api/dom.md")
}

rewrite_link :: proc(href: string, user: rawptr) -> string {
	rc := (^Rewrite_Ctx)(user)
	if href == "" { return "" }
	if is_external(href) { return "" }
	if strings.has_prefix(href, "#") { return "" } // same-page anchor
	if strings.has_prefix(href, "/") { return "" } // already absolute on the site

	// split a trailing fragment
	frag := ""
	path := href
	if h := strings.index_byte(href, '#'); h >= 0 {
		path = href[:h]
		frag = href[h:]
	}

	// resolve `path` against the current doc's directory, as POSIX-style segments
	dir := posix_dir(rc.cur)
	joined := posix_join(dir, path)
	normalized := posix_normalize(joined)
	if strings.has_suffix(path, "/") && normalized != "" { normalized = strings.concatenate({normalized, "/"}, context.allocator) }

	if strings.has_suffix(normalized, ".md") && !strings.has_prefix(normalized, "../") {
		return strings.concatenate({url_of(out_rel_of(normalized)), frag}, context.allocator)
	}

	// a page of the site (../site/pricing/index.html): its address on the site, as a folder
	if strings.has_prefix(normalized, "../site/") {
		site := strings.trim_suffix(normalized[len("../site"):], "index.html")
		return strings.concatenate({site, frag}, context.allocator)
	}

	// any other file of the repository (above docs/, or a file under docs/ that is not a page): it is not published
	// with the site, so the link goes to GitHub at the pinned branch, a folder to its tree
	rel := strings.trim_prefix(normalized, "../")
	if !strings.has_prefix(normalized, "../") { rel = strings.concatenate({"docs/", normalized}, context.allocator) }
	kind := strings.has_suffix(rel, "/") ? "/tree/" : "/blob/"
	return strings.concatenate({REPO_URL, kind, REPO_BRANCH, "/", strings.trim_suffix(rel, "/"), frag}, context.allocator)
}

posix_dir :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	if i < 0 { return "" }
	return p[:i]
}

posix_join :: proc(dir, rel: string) -> string {
	if dir == "" { return rel }
	return strings.concatenate({dir, "/", rel}, context.allocator)
}

// Collapse "a/./b", "a/b/../c" etc. A leading run of ".." is preserved (it signals leaving docs/).
posix_normalize :: proc(p: string) -> string {
	parts := strings.split(p, "/", context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for part in parts {
		switch part {
		case "", ".":
			// skip
		case "..":
			if len(out) > 0 && out[len(out) - 1] != ".." {
				ordered_remove(&out, len(out) - 1)
			} else {
				append(&out, "..")
			}
		case:
			append(&out, part)
		}
	}
	return strings.join(out[:], "/", context.allocator)
}

// The conformance page uses two directives that only docsite can fill (git history, the expectations files).
apply_directives :: proc(source: string) -> string {
	if !strings.contains(source, "<!-- docsite:") { return source }
	out := source
	if strings.contains(out, "<!-- docsite:chart -->") {
		chart := build_wpt_chart(".")
		block := strings.concatenate({"<figure class=\"doc-chart\">\n", chart, "\n<figcaption>Passing WPT subtests of Wren over time, rebuilt from the git history.</figcaption>\n</figure>"}, context.allocator)
		out, _ = strings.replace_all(out, "<!-- docsite:chart -->", block, context.allocator)
	}
	if strings.contains(out, "<!-- docsite:wpt-table -->") {
		out, _ = strings.replace_all(out, "<!-- docsite:wpt-table -->", build_wpt_table(".", "build/wpt/report.md"), context.allocator)
	}
	return out
}

collapse_ws :: proc(s: string) -> string {
	b := strings.builder_make(context.allocator)
	space := false
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			space = true
			continue
		}
		if space && strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		space = false
		strings.write_byte(&b, c)
	}
	return strings.trim_space(strings.to_string(b))
}

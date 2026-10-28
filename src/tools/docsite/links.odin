// Rewriting the relative links the docs use. A link from docs/<cur> to another doc is resolved against <cur>'s
// directory and mapped to the site URL:
//   web.md            (from api/dom.md)        -> /docs/api/web.html
//   ../remote.md      (from api/dom.md)        -> /docs/remote.html
//   releases/v0.5.0.md                          -> /docs/releases/v0.5.0.html
// A fragment is carried through (#anchor). A link that leaves docs/ (../README.md, ../native/js/README.md) cannot be
// a page of this site, so it becomes a GitHub blob link at the pinned branch. Absolute URLs, mailto, fragments-only
// and anything that is not a .md are left untouched (rewrite returns "").
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

	if !strings.has_suffix(path, ".md") {
		return "" // an image or a non-doc relative file: leave it for the browser to resolve
	}

	// resolve `path` against the current doc's directory, as POSIX-style segments
	dir := posix_dir(rc.cur)
	joined := posix_join(dir, path)
	normalized := posix_normalize(joined)

	// does it stay under docs/ ? (a leading ".." means it climbed out)
	if strings.has_prefix(normalized, "../") || normalized == ".." {
		// a repo file above docs/: link to GitHub (strip the leading ../ that climbed past docs/)
		rel := strings.trim_prefix(normalized, "../")
		return strings.concatenate({REPO_URL, "/blob/", REPO_BRANCH, "/", rel, frag}, context.allocator)
	}

	out := strings.concatenate({"/docs/", normalized[:len(normalized) - len(".md")], ".html", frag}, context.allocator)
	return out
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

// The releases timeline of site/changelog/index.html, made from docs/releases/v*.md (the highlights written for each release) and the
// dates of CHANGELOG.md: a release adds a file there and the page follows, nobody edits the page. The page holds the markers
// <!-- releases:begin --> and <!-- releases:end -->; what is between them is this tool's.
package docsite

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"

CHANGELOG_PAGE :: "site/changelog/index.html"
MARK_BEGIN     :: "<!-- releases:begin -->"
MARK_END       :: "<!-- releases:end -->"
RELEASE_BULLETS_MAX :: 6   // the highlights a release shows in the timeline

Release :: struct {
	version: string,   // "0.6.1"
	date:    string,   // "2026-10-29"
	bullets: [dynamic]string,
	lead:    string,   // the note's first paragraph, its bold marks dropped (the classic home's news)
}

// Every release note, newest first.
read_releases :: proc() -> []Release {
	dates := changelog_dates()
	infos, derr := os.read_all_directory_by_path("docs/releases", context.allocator)
	if derr != nil { return nil }
	releases := make([dynamic]Release, context.allocator)
	for fi in infos {
		if fi.type == .Directory || !strings.has_prefix(fi.name, "v") || !strings.has_suffix(fi.name, ".md") { continue }
		version := fi.name[1:len(fi.name) - 3]
		data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil { continue }
		r := Release{version = version, date = dates[version] or_else ""}
		release_bullets(string(data), &r)
		append(&releases, r)
	}
	slice.sort_by(releases[:], proc(a, b: Release) -> bool { return version_less(b.version, a.version) })
	return releases[:]
}

build_changelog_page :: proc(releases: []Release) {
	page_bytes, perr := os.read_entire_file(CHANGELOG_PAGE, context.allocator)
	if perr != nil { return }   // a checkout without the site
	page := string(page_bytes)
	b0 := strings.index(page, MARK_BEGIN)
	b1 := strings.index(page, MARK_END)
	if b0 < 0 || b1 < b0 { return }

	out := strings.builder_make(context.allocator)
	strings.write_string(&out, page[:b0 + len(MARK_BEGIN)])
	strings.write_string(&out, "\n")
	for r, i in releases { write_release(&out, r, i == 0) }
	if len(releases) > 0 { stamp_latest_version("site/index.html", releases[0].version) }
	strings.write_string(&out, "    ")
	strings.write_string(&out, page[b1:])
	emit(CHANGELOG_PAGE, strings.to_string(out))
}

// "## [0.6.1] - 2026-10-29" (Keep a Changelog; "## [Unreleased]" has no date)
changelog_dates :: proc() -> map[string]string {
	m := make(map[string]string, context.allocator)
	data, err := os.read_entire_file("CHANGELOG.md", context.allocator)
	if err != nil { return m }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "## [") { continue }
		rest := strings.trim_space(line[4:])
		bracket := strings.index(rest, "] - ")
		if bracket < 0 || len(rest) < bracket + 14 { continue }
		date := rest[bracket + 4:bracket + 14]
		if date[4] == '-' && date[7] == '-' { m[rest[:bracket]] = date }
	}
	return m
}

version_less :: proc(a, b: string) -> bool {
	pa := strings.split(a, ".", context.temp_allocator)
	pb := strings.split(b, ".", context.temp_allocator)
	for i in 0 ..< max(len(pa), len(pb)) {
		x, y := 0, 0
		if i < len(pa) { x, _ = strconv.parse_int(pa[i]) }
		if i < len(pb) { y, _ = strconv.parse_int(pb[i]) }
		if x != y { return x < y }
	}
	return false
}

// The "### Highlights" bullets of a release note (the first RELEASE_BULLETS_MAX, each whole), else the first sentence of its
// first paragraph under the title.
release_bullets :: proc(md: string, r: ^Release) {
	text := md
	in_highlights := false
	first_para := ""
	lead := strings.builder_make(context.temp_allocator)
	lead_done := false
	for line in strings.split_lines_iterator(&text) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "#") {
			if strings.has_prefix(t, "### Highlights") { in_highlights = true } else if in_highlights { break }
			continue
		}
		if !lead_done {
			if t != "" {
				if strings.builder_len(lead) > 0 { strings.write_byte(&lead, ' ') }
				strings.write_string(&lead, t)
			} else if strings.builder_len(lead) > 0 { lead_done = true }
		}
		if in_highlights {
			// a bullet is whole: its first line and the indented lines that go on with it, joined
			if strings.has_prefix(t, "- ") {
				if len(r.bullets) < RELEASE_BULLETS_MAX { append(&r.bullets, strings.clone(t[2:])) } else { in_highlights = false }
			} else if t != "" && line[0] == ' ' && len(r.bullets) > 0 {
				last := &r.bullets[len(r.bullets) - 1]
				last^ = strings.concatenate({last^, " ", t})
			}
		} else if first_para == "" && t != "" {
			first_para = t
		}
	}
	if len(r.bullets) == 0 && first_para != "" { append(&r.bullets, short_sentence(first_para)) }
	whole := strings.to_string(lead)
	if strings.has_prefix(whole, "**") && strings.has_suffix(whole, "**") && strings.count(whole, "**") == 2 { whole = whole[2:len(whole) - 2] }
	r.lead = strings.clone(whole)
}

// The bold lead and the sentence after it, at most 200 characters (cut at a space, with an ellipsis).
short_sentence :: proc(s: string) -> string {
	start := 0
	if strings.has_prefix(s, "**") {
		if c := strings.index(s[2:], "**"); c >= 0 { start = c + 4 }
	}
	in_code := false
	cut := len(s)
	for i := start; i < len(s); i += 1 {
		if s[i] == '`' { in_code = !in_code }
		if !in_code && s[i] == '.' && (i + 1 == len(s) || s[i + 1] == ' ') { cut = i + 1; break }
	}
	out := s[:cut]
	if len(out) > 200 {
		sp := strings.last_index_byte(out[:200], ' ')
		if sp > 40 { return strings.concatenate({out[:sp], "…"}, context.allocator) }
	}
	return out
}
write_release :: proc(b: ^strings.Builder, r: Release, latest: bool) {
	id, _ := strings.replace_all(r.version, ".", "-", context.temp_allocator)
	strings.write_string(b, latest ? "      <article class=\"release latest\" id=\"v" : "      <article class=\"release\" id=\"v")
	strings.write_string(b, id)
	strings.write_string(b, "\">\n        <div class=\"rail\"><span class=\"dot\"></span></div>\n        <div class=\"release-body\">\n")
	if r.date != "" {
		strings.write_string(b, "          <p class=\"release-date\"><time datetime=\"")
		strings.write_string(b, r.date)
		strings.write_string(b, "\">")
		strings.write_string(b, long_date(r.date))
		strings.write_string(b, "</time></p>\n")
	}
	strings.write_string(b, "          <div class=\"release-title\"><h3>")
	strings.write_string(b, r.version)
	strings.write_string(b, "</h3>")
	if latest { strings.write_string(b, "<span class=\"badge\">Latest</span>") }
	strings.write_string(b, "</div>\n          <ul class=\"release-list\">\n")
	for bl in r.bullets {
		strings.write_string(b, "            <li>")
		write_inline(b, bl)
		strings.write_string(b, "</li>\n")
	}
	strings.write_string(b, "          </ul>\n          <p class=\"release-links\"><a href=\"")
	strings.write_string(b, REPO_URL)
	strings.write_string(b, "/blob/")
	strings.write_string(b, REPO_BRANCH)
	strings.write_string(b, "/docs/releases/v")
	strings.write_string(b, r.version)
	strings.write_string(b, ".md\">Release notes</a> ·\n            <a href=\"")
	strings.write_string(b, REPO_URL)
	strings.write_string(b, "/releases/tag/v")
	strings.write_string(b, r.version)
	strings.write_string(b, "\">Download</a></p>\n        </div>\n      </article>\n")
}

long_date :: proc(d: string) -> string {
	months := [?]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
	y, _ := strconv.parse_int(d[0:4])
	m, _ := strconv.parse_int(d[5:7])
	day, _ := strconv.parse_int(d[8:10])
	if m < 1 || m > 12 { return d }
	return fmt.aprintf("%s %d, %d", months[m - 1], day, y)
}

// **bold**, `code` and [text](url) (the text only) of a bullet; everything else is escaped text.
write_inline :: proc(b: ^strings.Builder, s: string) {
	bold, code := false, false
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case !code && c == '*' && i + 1 < len(s) && s[i + 1] == '*':
			strings.write_string(b, bold ? "</strong>" : "<strong>")
			bold = !bold
			i += 2
			continue
		case c == '`':
			strings.write_string(b, code ? "</code>" : "<code>")
			code = !code
		case !code && c == '[':
			if close := strings.index_byte(s[i:], ']'); close > 0 && i + close + 1 < len(s) && s[i + close + 1] == '(' {
				if paren := strings.index_byte(s[i + close:], ')'); paren > 0 {
					base.write_escaped(b, s[i + 1:i + close])
					i += close + paren + 1
					continue
				}
			}
			strings.write_byte(b, c)
		case c == '&': strings.write_string(b, "&amp;")
		case c == '<': strings.write_string(b, "&lt;")
		case c == '>': strings.write_string(b, "&gt;")
		case: strings.write_byte(b, c)
		}
		i += 1
	}
	if code { strings.write_string(b, "</code>") }
	if bold { strings.write_string(b, "</strong>") }
}

// A home page names the latest version between <!-- latest --> and <!-- /latest -->.
stamp_latest_version :: proc(path, version: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	emit(path, stamp(string(data), "<!-- latest -->", "<!-- /latest -->", version))
}

// `page` with what is between the markers `begin` and `end` replaced by `content` (unchanged without them).
stamp :: proc(page, begin, end, content: string) -> string {
	a := strings.index(page, begin)
	if a < 0 { return page }
	a += len(begin)
	b := strings.index(page[a:], end)
	if b < 0 { return page }
	return strings.concatenate({page[:a], content, page[a + b:]}, context.allocator)
}

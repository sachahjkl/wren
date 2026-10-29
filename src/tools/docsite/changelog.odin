// The releases timeline of site/changelog.html, made from docs/releases/v*.md (the highlights written for each release) and the
// dates of CHANGELOG.md: a release adds a file there and the page follows, nobody edits the page. The page holds the markers
// <!-- releases:begin --> and <!-- releases:end -->; what is between them is this tool's.
package docsite

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

CHANGELOG_PAGE :: "site/changelog.html"
MARK_BEGIN     :: "<!-- releases:begin -->"
MARK_END       :: "<!-- releases:end -->"

Release :: struct {
	version: string,   // "0.6.1"
	date:    string,   // "2026-10-29"
	bullets: [dynamic]string,
}

build_changelog_page :: proc() {
	page_bytes, perr := os.read_entire_file(CHANGELOG_PAGE, context.allocator)
	if perr != nil { return }   // a checkout without the site
	page := string(page_bytes)
	b0 := strings.index(page, MARK_BEGIN)
	b1 := strings.index(page, MARK_END)
	if b0 < 0 || b1 < b0 { return }

	dates := changelog_dates()
	infos, derr := os.read_all_directory_by_path("docs/releases", context.allocator)
	if derr != nil { return }
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

	out := strings.builder_make(context.allocator)
	strings.write_string(&out, page[:b0 + len(MARK_BEGIN)])
	strings.write_string(&out, "\n")
	for r, i in releases { write_release(&out, r, i == 0) }
	strings.write_string(&out, "    ")
	strings.write_string(&out, page[b1:])
	emit(CHANGELOG_PAGE, strings.to_string(out))
}

// "## 0.6.1 - 2026-10-29" (older headings carry odd separators: the date is the last 10 characters)
changelog_dates :: proc() -> map[string]string {
	m := make(map[string]string, context.allocator)
	data, err := os.read_entire_file("CHANGELOG.md", context.allocator)
	if err != nil { return m }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "## ") || len(line) < 13 { continue }
		rest := strings.trim_space(line[3:])
		sp := strings.index_byte(rest, ' ')
		if sp < 0 { continue }
		date := rest[len(rest) - 10:]
		if len(date) == 10 && date[4] == '-' && date[7] == '-' { m[rest[:sp]] = date }
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

// The "### Highlights" bullets of a release note, else its first paragraph under the title.
release_bullets :: proc(md: string, r: ^Release) {
	text := md
	in_highlights := false
	first_para := ""
	for line in strings.split_lines_iterator(&text) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "#") {
			if strings.has_prefix(t, "### Highlights") { in_highlights = true } else if in_highlights { break }
			continue
		}
		if in_highlights {
			if strings.has_prefix(t, "- ") && len(r.bullets) < 6 { append(&r.bullets, short_sentence(t[2:])) }
		} else if first_para == "" && t != "" {
			first_para = t
		}
	}
	if len(r.bullets) == 0 && first_para != "" { append(&r.bullets, short_sentence(first_para)) }
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
					write_escaped_text(b, s[i + 1:i + close])
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

write_escaped_text :: proc(b: ^strings.Builder, s: string) {
	for c in s {
		switch c {
		case '&': strings.write_string(b, "&amp;")
		case '<': strings.write_string(b, "&lt;")
		case '>': strings.write_string(b, "&gt;")
		case: strings.write_rune(b, c)
		}
	}
}

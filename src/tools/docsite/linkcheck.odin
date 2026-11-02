package docsite

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Every page of the published site read back (site/, the hand-written pages and the generated docs): the ids it
// defines, the links (href) and files (src) its tags use. Each one, resolved from the page's own folder, must name a
// file that exists, a page by its folder ("pricing/", never "pricing.html": the addresses have no .html), and for a
// #fragment an id that page defines. A link starting with "/" would leave the site, which lives under /wren/.
// The pages left at the old .html addresses only send on, and are checked like the others.

SITE_DIR :: "site"

Page_Text :: struct {
	rel:      string,   // "docs/cdp/index.html", from site/
	text:     string,
	redirect: bool,     // a page left at an old address (meta refresh)
}

@(private = "file")
collect_pages :: proc(dir, prefix: string, out: ^[dynamic]Page_Text) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil { return }
	for e in entries {
		rel := prefix == "" ? e.name : strings.concatenate({prefix, "/", e.name})
		if e.type == .Directory { collect_pages(e.fullpath, rel, out); continue }
		if !strings.has_suffix(e.name, ".html") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { continue }
		text := string(data)
		append(out, Page_Text{rel, text, strings.contains(text, `http-equiv="refresh"`)})
	}
}

Tag_Attr :: struct { name, value: string }

// The attributes of every tag of a page, in order; comments, scripts and styles are skipped, so a URL written in the
// text of a code sample (&lt;script src="..."&gt;) or built by a script is not taken for a link.
@(private = "file")
each_attr :: proc(text: string, visit: proc(a: Tag_Attr, data: rawptr), data: rawptr) {
	i := 0
	for i < len(text) {
		if text[i] != '<' { i += 1; continue }
		if strings.has_prefix(text[i:], "<!--") {
			end := strings.index(text[i:], "-->")
			if end < 0 { return }
			i += end + 3
			continue
		}
		j := i + 1
		if j >= len(text) || !is_letter(text[j]) { i += 1; continue }
		for j < len(text) && is_name_byte(text[j]) { j += 1 }
		tag := strings.to_lower(text[i + 1:j], context.temp_allocator)
		// attributes up to the '>'
		for j < len(text) && text[j] != '>' {
			if !is_name_byte(text[j]) { j += 1; continue }
			n0 := j
			for j < len(text) && is_name_byte(text[j]) { j += 1 }
			name := strings.to_lower(text[n0:j], context.temp_allocator)
			if j < len(text) && text[j] == '=' {
				j += 1
				if j < len(text) && (text[j] == '"' || text[j] == '\'') {
					q := text[j]
					end := strings.index_byte(text[j + 1:], q)
					if end < 0 { return }
					visit({name, text[j + 1:j + 1 + end]}, data)
					j += end + 2
				} else {
					v0 := j
					for j < len(text) && text[j] != ' ' && text[j] != '>' { j += 1 }
					visit({name, text[v0:j]}, data)
				}
			}
		}
		i = j
		if tag == "script" || tag == "style" {
			close := strings.index(text[i:], strings.concatenate({"</", tag}, context.temp_allocator))
			if close < 0 { return }
			i += close
		}
	}
}

@(private = "file")
is_letter :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
@(private = "file")
is_name_byte :: proc(c: u8) -> bool { return is_letter(c) || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == ':' }

Link_Check :: struct {
	ids:   ^map[string]map[string]bool,
	page:  ^Page_Text,
	dead:  ^[dynamic]string,
}

@(private = "file")
visit_link :: proc(a: Tag_Attr, data: rawptr) {
	if a.name != "href" && a.name != "src" { return }
	c := (^Link_Check)(data)
	href := a.value
	if href == "" { return }
	if is_external(href) || strings.has_prefix(href, "data:") || strings.has_prefix(href, "javascript:") { return }
	if strings.has_prefix(href, "/") {
		append(c.dead, fmt.aprintf("%s: %s starts with / and leaves the site (it lives under /wren/): make it relative", c.page.rel, href))
		return
	}
	target, fragment := href, ""
	if hash := strings.index_byte(href, '#'); hash >= 0 { target, fragment = href[:hash], href[hash + 1:] }
	if q := strings.index_byte(target, '?'); q >= 0 { target = target[:q] }

	// resolve from the page's folder
	path := c.page.rel
	if target != "" {
		joined := posix_join(posix_dir(c.page.rel), target)
		path = posix_normalize(joined)
		if strings.has_prefix(path, "..") {
			append(c.dead, fmt.aprintf("%s: %s climbs out of the site", c.page.rel, href))
			return
		}
		if strings.has_suffix(target, "/") || target == "." || target == ".." || strings.has_suffix(target, "/..") || strings.has_suffix(target, "/.") {
			path = path == "" ? "index.html" : strings.concatenate({path, "/index.html"})
		} else if strings.has_suffix(target, ".html") && !c.page.redirect && a.name == "href" {
			append(c.dead, fmt.aprintf("%s: %s names a .html: link the page's folder", c.page.rel, href))
			return
		}
	}

	if strings.has_suffix(path, ".html") {
		page_ids, known := c.ids[path]
		if !known { append(c.dead, fmt.aprintf("%s: link to missing page %s", c.page.rel, href)); return }
		if fragment != "" && fragment not_in page_ids { append(c.dead, fmt.aprintf("%s: link to missing anchor %s", c.page.rel, href)) }
		return
	}
	if !os.exists(strings.concatenate({SITE_DIR, "/", path}, context.temp_allocator)) {
		append(c.dead, fmt.aprintf("%s: link to missing file %s", c.page.rel, href))
	}
}

check_links :: proc() -> bool {
	pages: [dynamic]Page_Text
	collect_pages(SITE_DIR, "", &pages)
	ids := make(map[string]map[string]bool)
	for p in pages {
		set: map[string]bool
		each_attr(p.text, proc(a: Tag_Attr, data: rawptr) { if a.name == "id" { (^map[string]bool)(data)[a.value] = true } }, &set)
		ids[p.rel] = set
	}
	dead: [dynamic]string
	for &p in pages {
		check := Link_Check{&ids, &p, &dead}
		each_attr(p.text, visit_link, &check)
	}
	if len(dead) > 0 {
		slice.sort(dead[:])
		dead_unique := slice.unique(dead[:])
		fmt.printfln("docsite: %d dead link(s)/anchor(s) in site/:", len(dead_unique))
		for d in dead_unique { fmt.printfln("  %s", d) }
		return false
	}
	fmt.printfln("docsite: %d pages of site/, every link, file and anchor resolves", len(pages))
	return true
}

package docsite

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Every generated page read back: the ids it defines, the internal links it uses. Each link must point at a page that exists and, for a #fragment, an id that page defines; an asset under /docs/ must exist.

SITE_PREFIX :: "/docs/"
ASSET_SUFFIXES := []string{".css", ".js", ".json", ".svg", ".png", ".webp", ".gif", ".jpg", ".jpeg"}

Page_Text :: struct { url, name, text: string }

@(private = "file")
collect_pages :: proc(dir: string, out: ^[dynamic]Page_Text) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory { collect_pages(e.fullpath, out); continue }
		if !strings.has_suffix(e.name, ".html") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { continue }
		path, _ := strings.replace_all(e.fullpath, "\\", "/")
		at := strings.index(path, OUT_DIR)
		append(out, Page_Text{strings.concatenate({SITE_PREFIX, path[at + len(OUT_DIR) + 1:]}), e.name, string(data)})
	}
}

// Calls `visit` with what follows each occurrence of `open` up to the closing quote.
@(private = "file")
each_quoted :: proc(text, open: string, visit: proc(value: string, data: rawptr), data: rawptr) {
	rest := text
	for {
		at := strings.index(rest, open)
		if at < 0 { return }
		rest = rest[at + len(open):]
		end := strings.index_byte(rest, '"')
		if end < 0 { return }
		visit(rest[:end], data)
		rest = rest[end + 1:]
	}
}

Link_Check :: struct {
	ids:   ^map[string]map[string]bool,
	page:  ^Page_Text,
	dead:  ^[dynamic]string,
}

@(private = "file")
visit_link :: proc(href: string, data: rawptr) {
	c := (^Link_Check)(data)
	if strings.has_prefix(href, "#") {
		id := href[1:]
		if id != "" && id not_in c.ids[c.page.url] { append(c.dead, fmt.aprintf("%s: link to missing anchor %s", c.page.name, href)) }
		return
	}
	if !strings.has_prefix(href, SITE_PREFIX) { return }
	target, fragment := href, ""
	if hash := strings.index_byte(href, '#'); hash >= 0 { target, fragment = href[:hash], href[hash + 1:] }
	if strings.has_suffix(target, ".html") {
		page_ids, known := c.ids[target]
		if !known { append(c.dead, fmt.aprintf("%s: link to missing page %s", c.page.name, target)); return }
		if fragment != "" && fragment not_in page_ids { append(c.dead, fmt.aprintf("%s: link to missing anchor %s", c.page.name, href)) }
		return
	}
	for s in ASSET_SUFFIXES {
		if strings.has_suffix(target, s) {
			// a non-page asset under /docs/ (the generated css/js/json/svg): it must exist on disk
			path := strings.concatenate({OUT_DIR, "/", target[len(SITE_PREFIX):]}, context.temp_allocator)
			if !os.exists(path) { append(c.dead, fmt.aprintf("%s: link to missing asset %s", c.page.name, target)) }
			return
		}
	}
}

check_links :: proc() -> bool {
	pages: [dynamic]Page_Text
	collect_pages(OUT_DIR, &pages)
	ids := make(map[string]map[string]bool)
	for p in pages {
		set: map[string]bool
		each_quoted(p.text, `id="`, proc(value: string, data: rawptr) { (^map[string]bool)(data)[value] = true }, &set)
		ids[p.url] = set
	}
	dead: [dynamic]string
	for &p in pages {
		check := Link_Check{&ids, &p, &dead}
		each_quoted(p.text, `href="`, visit_link, &check)
	}
	if len(dead) > 0 {
		slice.sort(dead[:])
		dead_unique := slice.unique(dead[:])
		fmt.printfln("docsite: %d dead internal link(s)/anchor(s):", len(dead_unique))
		for d in dead_unique { fmt.printfln("  %s", d) }
		return false
	}
	fmt.printfln("docsite: %d pages, every internal link and anchor resolves", len(pages))
	return true
}

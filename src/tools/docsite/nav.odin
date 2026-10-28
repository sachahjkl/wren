// The sidebar's shape comes from docs/_nav.txt (see its header for the format). A page lands in exactly one place:
// a line names it, a "dir/*" glob pulls a whole directory in, or — if nothing names it — it falls into a "More"
// section at the end so a new doc is never dropped silently. The order of the file is the order of the sidebar.
package docsite

import "core:os"
import "core:slice"
import "core:strings"

Nav_Item :: struct {
	rel:      string,      // the doc's path relative to docs/ ("cdp.md", "api/dom.md"); "" for a pure group heading
	title:    string,      // the label in the sidebar
	children: [dynamic]^Nav_Item,
	depth:    int,
}

Nav :: struct {
	roots: [dynamic]^Nav_Item,          // the top-level sections
	by_rel: map[string]^Nav_Item,       // rel -> item, to resolve a doc's place
	order:  [dynamic]string,            // every doc rel, in sidebar order, for prev/next
}

// Build the navigation tree from the _nav.txt text and the set of docs actually present (rel paths).
build_nav :: proc(nav_text: string, docs: []string) -> ^Nav {
	nav := new(Nav)
	nav.by_rel = make(map[string]^Nav_Item)
	present := make(map[string]bool, context.temp_allocator)
	for d in docs { present[d] = true }
	used := make(map[string]bool, context.temp_allocator)

	section: ^Nav_Item
	for raw in strings.split_lines(nav_text, context.temp_allocator) {
		line := strings.trim_right_space(raw)
		if len(strings.trim_space(line)) == 0 { continue }
		if strings.has_prefix(strings.trim_left_space(line), "#") { continue }

		indent := leading_spaces(line)
		body := strings.trim_left_space(line)

		if indent == 0 {
			// a top-level section heading
			section = new(Nav_Item)
			section.title = body
			section.children = make([dynamic]^Nav_Item)
			append(&nav.roots, section)
			continue
		}
		if section == nil { continue }

		// "page.md  Title" or "dir/*  Title"
		path, title := split_nav_entry(body)
		if strings.has_suffix(path, "/*") {
			dir := path[:len(path) - 2]
			add_glob_group(nav, section, dir, title, present, &used)
		} else {
			if !present[path] { continue } // a named doc that does not exist yet: skip quietly
			item := new(Nav_Item)
			item.rel = path
			item.title = title != "" ? title : ""
			item.children = make([dynamic]^Nav_Item)
			append(&section.children, item)
			nav.by_rel[path] = item
			used[path] = true
		}
	}

	// anything present but not placed goes into a trailing "More" section, sorted
	leftovers := make([dynamic]string, context.temp_allocator)
	for d in docs { if !used[d] { append(&leftovers, d) } }
	if len(leftovers) > 0 {
		slice.sort(leftovers[:])
		more := new(Nav_Item)
		more.title = "More"
		more.children = make([dynamic]^Nav_Item)
		for d in leftovers {
			item := new(Nav_Item)
			item.rel = d
			item.children = make([dynamic]^Nav_Item)
			append(&more.children, item)
			nav.by_rel[d] = item
		}
		append(&nav.roots, more)
	}

	// flatten into the prev/next order
	nav.order = make([dynamic]string)
	for sec in nav.roots { collect_order(nav, sec) }
	return nav
}

// A directory group: a sub-item named `title`, led by its _index.md (or README.md) if present, then the rest sorted.
add_glob_group :: proc(nav: ^Nav, section: ^Nav_Item, dir: string, title: string, present: map[string]bool, used: ^map[string]bool) {
	members := make([dynamic]string, context.temp_allocator)
	prefix := strings.concatenate({dir, "/"}, context.temp_allocator)
	for d in present {
		if strings.has_prefix(d, prefix) && !used[d] { append(&members, d) }
	}
	if len(members) == 0 { return }
	slice.sort(members[:])

	group := new(Nav_Item)
	group.title = title != "" ? title : dir
	group.children = make([dynamic]^Nav_Item)
	append(&section.children, group)

	// lead with an index page if one exists
	lead := ""
	for cand in ([?]string{strings.concatenate({dir, "/README.md"}, context.temp_allocator), strings.concatenate({dir, "/_index.md"}, context.temp_allocator), strings.concatenate({dir, "/index.md"}, context.temp_allocator)}) {
		if present[cand] { lead = cand; break }
	}
	if lead != "" {
		item := new(Nav_Item)
		item.rel = lead
		item.title = "Overview"
		item.children = make([dynamic]^Nav_Item)
		append(&group.children, item)
		nav.by_rel[lead] = item
		used[lead] = true
	}
	for m in members {
		if m == lead { continue }
		item := new(Nav_Item)
		item.rel = m
		item.children = make([dynamic]^Nav_Item)
		append(&group.children, item)
		nav.by_rel[m] = item
		used[m] = true
	}
}

collect_order :: proc(nav: ^Nav, item: ^Nav_Item) {
	if item.rel != "" { append(&nav.order, item.rel) }
	for c in item.children { collect_order(nav, c) }
}

split_nav_entry :: proc(body: string) -> (path, title: string) {
	// the path is the first token; the rest (if any) is the title
	i := 0
	for i < len(body) && body[i] != ' ' && body[i] != '\t' { i += 1 }
	path = body[:i]
	title = strings.trim_space(body[i:])
	return
}

read_docs_tree :: proc(docs_dir: string) -> []string {
	out := make([dynamic]string)
	// `prefix` is the directory part to strip from each file's full path so the result is relative to docs/.
	walk :: proc(dir, prefix: string, out: ^[dynamic]string) {
		infos, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil { return }
		for fi in infos {
			if fi.type == .Directory {
				walk(fi.fullpath, prefix, out)
				continue
			}
			if !strings.has_suffix(fi.name, ".md") { continue }
			full, _ := strings.replace_all(fi.fullpath, "\\", "/", context.allocator)
			rel := strings.trim_prefix(full, prefix)
			rel = strings.trim_prefix(rel, "/")
			if rel == "" || strings.has_prefix(rel, "_") { continue } // _nav.txt etc. are not pages
			append(out, rel)
		}
	}
	// read_all_directory_by_path reports absolute full paths; derive the prefix to strip from the first directory's
	// own full path so the result is relative to docs/, whatever the absolute location.
	prefix := abs_forward(docs_dir)
	walk(docs_dir, prefix, &out)
	slice.sort(out[:])
	return out[:]
}

// The absolute path of `p`, with forward slashes (so it matches the full paths read from the directory).
abs_forward :: proc(p: string) -> string {
	ap, err := os.get_absolute_path(p, context.allocator)
	if err != nil { ap = p }
	f, _ := strings.replace_all(ap, "\\", "/", context.allocator)
	return f
}

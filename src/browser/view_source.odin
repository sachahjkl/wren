package browser

// view-source:URL — the document's bytes as text (decoded with the charset of the response), with tags, attributes,
// comments and doctype colored (browser.view_source.colors). The source is fetched again like a navigation, shown in a
// document of its own built from escaped text: nothing of it runs.

import "core:strings"
import "wb:html"
import "wb:page"

VIEW_SOURCE :: "view-source:"
VIEW_SOURCE_MAX :: 8 << 20   // bytes of source shown (the rest is cut, with a note)

// Opens the source of the tab's page in a new tab.
view_source :: proc(app: ^App, t: ^Tab) {
	if t == nil || t.kind != .Web || t.url == "" || strings.has_prefix(t.url, VIEW_SOURCE) { return }
	open_in_new_tab(app, strings.concatenate({VIEW_SOURCE, t.url}, context.temp_allocator))
}

@(private = "file")
SOURCE_STYLE :: `<style>
body { margin: 0; background: #ffffff; }
pre { margin: 0; padding: 8px 12px; font: 13px/1.45 Consolas, "Cascadia Mono", monospace; white-space: pre-wrap; overflow-wrap: anywhere; color: #1a1a1a; }
.t { color: #881280; } .n { color: #994500; } .v { color: #1a1aa6; } .c { color: #236e25; } .d { color: #808080; } .x { color: #c00000; font-style: italic; }
</style>`

@(private = "file")
put_escaped :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(sb, "&amp;")
		case '<': strings.write_string(sb, "&lt;")
		case '>': strings.write_string(sb, "&gt;")
		case: strings.write_byte(sb, s[i])
		}
	}
}

@(private = "file")
span :: proc(sb: ^strings.Builder, class, s: string, colors: bool) {
	if s == "" { return }
	if colors { strings.write_string(sb, `<span class="`); strings.write_string(sb, class); strings.write_string(sb, `">`) }
	put_escaped(sb, s)
	if colors { strings.write_string(sb, "</span>") }
}

// The markup of the source page: a light HTML tokenizer (tags with their attributes, comments, doctype; text as is).
source_markup :: proc(src: string, colors: bool, truncated: bool) -> string {
	sb := strings.builder_make(0, len(src) * 2 + 1024, context.temp_allocator)
	strings.write_string(&sb, "<!doctype html><meta charset=utf-8>")
	strings.write_string(&sb, SOURCE_STYLE)
	strings.write_string(&sb, "<pre>")
	i := 0
	for i < len(src) {
		c := src[i]
		if c != '<' {
			j := strings.index_byte(src[i:], '<')
			end := j < 0 ? len(src) : i + j
			put_escaped(&sb, src[i:end])
			i = end
			continue
		}
		if strings.has_prefix(src[i:], "<!--") {
			j := strings.index(src[i + 4:], "-->")
			end := j < 0 ? len(src) : i + 4 + j + 3
			span(&sb, "c", src[i:end], colors)
			i = end
			continue
		}
		if strings.has_prefix(src[i:], "<!") || strings.has_prefix(src[i:], "<?") {
			j := strings.index_byte(src[i:], '>')
			end := j < 0 ? len(src) : i + j + 1
			span(&sb, "d", src[i:end], colors)
			i = end
			continue
		}
		// a tag: < name, then attributes until >
		k := i + 1
		if k < len(src) && src[k] == '/' { k += 1 }
		for k < len(src) && !is_space(src[k]) && src[k] != '>' && src[k] != '/' { k += 1 }
		if k == i + 1 { put_escaped(&sb, "<"); i += 1; continue }
		span(&sb, "t", src[i:k], colors)
		for k < len(src) && src[k] != '>' {
			if is_space(src[k]) {
				s := k
				for k < len(src) && is_space(src[k]) { k += 1 }
				put_escaped(&sb, src[s:k])
				continue
			}
			if src[k] == '/' { span(&sb, "t", "/", colors); k += 1; continue }
			// attribute name
			s := k
			for k < len(src) && !is_space(src[k]) && src[k] != '=' && src[k] != '>' && !(src[k] == '/' && k + 1 < len(src) && src[k + 1] == '>') { k += 1 }
			if k == s { k += 1 }
			span(&sb, "n", src[s:k], colors)
			if k < len(src) && src[k] == '=' {
				put_escaped(&sb, "=")
				k += 1
				s = k
				if k < len(src) && (src[k] == '"' || src[k] == '\'') {
					q := src[k]
					e := strings.index_byte(src[k + 1:], q)
					k = e < 0 ? len(src) : k + 1 + e + 1
				} else {
					for k < len(src) && !is_space(src[k]) && src[k] != '>' { k += 1 }
				}
				span(&sb, "v", src[s:k], colors)
			}
		}
		if k < len(src) { span(&sb, "t", ">", colors); k += 1 }
		i = k
	}
	if truncated { span(&sb, "x", "\n[the rest of the source is not shown]", true) }
	strings.write_string(&sb, "</pre>")
	return strings.to_string(sb)
}

@(private = "file")
is_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

// The loaded bytes of a view-source: navigation become the source page.
show_source :: proc(app: ^App, load: ^Doc_Load, data: []byte) {
	d, ok := html.decode_document(data, load.charset, app.page_settings.html.default_encoding)
	text := ok ? string(d.text[:]) : string(data)
	defer if ok { delete(d.text) }
	truncated := len(text) > VIEW_SOURCE_MAX
	if truncated { text = text[:VIEW_SOURCE_MAX] }
	markup := source_markup(text, ix.source_colors, truncated)
	page.load_html(load.page, transmute([]byte)markup)
	t := load.tab
	delete(t.title)
	t.title = strings.clone(t.url)
	set_status(t, "page source")
}

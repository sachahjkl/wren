package desktop

// The text of a freedesktop.org Desktop Entry (https://specifications.freedesktop.org/desktop-entry-spec/latest/): made
// and read here, whatever the platform, so the Linux backend's output is checked by the tests on any machine. Nothing in
// this file touches the disk.

import "core:fmt"
import "core:strings"

// What the file's marker line is called: the Wren backend writes it and trusts only files that carry it (or that run
// the executable) when it removes or repairs one. Keys that begin with X- are for applications' own use.
ENTRY_MARKER :: "X-Wren-Integration"

Content_Type :: struct { ext, mime: string }

// The web documents a browser may be offered for. The extension is what Windows registers, the MIME type what the
// desktop entry lists.
CONTENT_TYPES := [?]Content_Type{
	{".htm", "text/html"}, {".html", "text/html"}, {".shtml", "text/html"},
	{".xhtml", "application/xhtml+xml"}, {".xht", "application/xhtml+xml"},
	{".svg", "image/svg+xml"}, {".webp", "image/webp"}, {".avif", "image/avif"},
	{".png", "image/png"}, {".jpg", "image/jpeg"}, {".jpeg", "image/jpeg"}, {".gif", "image/gif"},
	{".pdf", "application/pdf"}, {".txt", "text/plain"}, {".xml", "text/xml"},
}

SCHEME_MIME_TYPES :: [?]string{"x-scheme-handler/http", "x-scheme-handler/https"}

mime_of_extension :: proc(ext: string) -> string {
	e := normalize_extension(ext)
	for c in CONTENT_TYPES { if c.ext == e { return c.mime } }
	return ""
}

// The MIME types the entry lists: the two web schemes, then those of the file types (each once, in order).
mime_types :: proc(file_types: []string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for s in SCHEME_MIME_TYPES { append(&out, s) }
	for ft in file_types {
		m := mime_of_extension(ft)
		if m == "" { continue }
		seen := false
		for o in out { if o == m { seen = true; break } }
		if !seen { append(&out, m) }
	}
	return out[:]
}

// A string value of the file: backslash, newline, tab and carriage return are escaped.
escape_value :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "\\\n\t\r") { return s }
	sb := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '\\': strings.write_string(&sb, "\\\\")
		case '\n': strings.write_string(&sb, "\\n")
		case '\t': strings.write_string(&sb, "\\t")
		case '\r': strings.write_string(&sb, "\\r")
		case:      strings.write_rune(&sb, r)
		}
	}
	return strings.to_string(sb)
}

unescape_value :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\\') < 0 { return s }
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 >= len(s) { strings.write_byte(&sb, s[i]); continue }
		i += 1
		switch s[i] {
		case 's':  strings.write_byte(&sb, ' ')
		case 'n':  strings.write_byte(&sb, '\n')
		case 't':  strings.write_byte(&sb, '\t')
		case 'r':  strings.write_byte(&sb, '\r')
		case '\\': strings.write_byte(&sb, '\\')
		case:      strings.write_byte(&sb, '\\'); strings.write_byte(&sb, s[i])
		}
	}
	return strings.to_string(sb)
}

// One argument of an Exec line, as the specification quotes it: any of the reserved characters puts it in double
// quotes, with the backslash, quote, dollar and backtick escaped; `%` is doubled (a field code otherwise). The result
// is still to be escaped as a string value (`escape_value`).
quote_exec_argument :: proc(arg: string, allocator := context.temp_allocator) -> string {
	reserved := strings.contains_any(arg, " \t\n\"'\\><~|&;$*?#()`") || arg == ""
	sb := strings.builder_make(allocator)
	if reserved { strings.write_byte(&sb, '"') }
	for r in arg {
		switch r {
		case '"', '`', '$', '\\':
			if reserved { strings.write_byte(&sb, '\\') }
			strings.write_rune(&sb, r)
		case '%': strings.write_string(&sb, "%%")
		case:     strings.write_rune(&sb, r)
		}
	}
	if reserved { strings.write_byte(&sb, '"') }
	return strings.to_string(sb)
}

// The program an Exec value launches (its first argument, unquoted); "" for an empty value.
exec_program :: proc(exec_value: string, allocator := context.temp_allocator) -> string {
	v := strings.trim_left_space(unescape_value(exec_value))
	if v == "" { return "" }
	sb := strings.builder_make(allocator)
	quoted := v[0] == '"'
	for i := quoted ? 1 : 0; i < len(v); i += 1 {
		c := v[i]
		switch {
		case quoted && c == '"': return strings.to_string(sb)
		case !quoted && (c == ' ' || c == '\t'): return strings.to_string(sb)
		case quoted && c == '\\':
			if i + 1 < len(v) { i += 1 }
			strings.write_byte(&sb, v[i])
		case c == '%':
			if i + 1 < len(v) && v[i + 1] == '%' { i += 1 }
			strings.write_byte(&sb, '%')
		case: strings.write_byte(&sb, c)
		}
	}
	return strings.to_string(sb)
}

// The value of `key` in the [Desktop Entry] group ("" when absent). Comments, blank lines, other groups and
// localized keys (Name[fr]) are skipped; the value is returned as written (not unescaped).
entry_value :: proc(text, key: string) -> (value: string, found: bool) {
	in_group := false
	rest := text
	for len(rest) > 0 {
		line: string
		if i := strings.index_byte(rest, '\n'); i >= 0 { line, rest = rest[:i], rest[i + 1:] } else { line, rest = rest, "" }
		line = strings.trim_right(line, "\r")
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' { continue }
		if trimmed[0] == '[' { in_group = trimmed == "[Desktop Entry]"; continue }
		if !in_group { continue }
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 { continue }
		if strings.trim_space(trimmed[:eq]) == key { return strings.trim_left_space(trimmed[eq + 1:]), true }
	}
	return "", false
}

// The desktop entry of an integration of `o`. Lines are LF-terminated and in the order the specification's own examples
// use; every value is escaped, the Exec line quoted.
desktop_entry_text :: proc(o: ^Options, allocator := context.temp_allocator) -> string {
	id := o.identity
	sb := strings.builder_make(allocator)
	line :: proc(sb: ^strings.Builder, key, value: string) { fmt.sbprintf(sb, "%s=%s\n", key, value) }
	strings.write_string(&sb, "[Desktop Entry]\n")
	line(&sb, "Type", "Application")
	line(&sb, "Version", "1.0")
	line(&sb, "Name", escape_value(id.name))
	line(&sb, "GenericName", "Web Browser")
	if id.description != "" { line(&sb, "Comment", escape_value(id.description)) }
	line(&sb, "Exec", escape_value(strings.concatenate({quote_exec_argument(o.exe), " %U"}, context.temp_allocator)))
	line(&sb, "TryExec", escape_value(o.exe))
	line(&sb, "Icon", id.slug)
	line(&sb, "Terminal", "false")
	line(&sb, "StartupNotify", "true")
	line(&sb, "Categories", "Network;WebBrowser;")
	line(&sb, "Keywords", "Internet;WWW;Browser;Web;WebAssembly;")
	if o.register_browser {
		sb2 := strings.builder_make(context.temp_allocator)
		for m in mime_types(o.file_types) { strings.write_string(&sb2, m); strings.write_byte(&sb2, ';') }
		line(&sb, "MimeType", strings.to_string(sb2))
	}
	line(&sb, ENTRY_MARKER, id.slug)
	return strings.to_string(sb)
}

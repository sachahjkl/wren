package fetch

import "core:fmt"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "wb:config"

////////////////////////////////
// file: folders, as browsers show them. A folder URL without its final '/' is redirected to the one with it (so that
// the relative links of what is shown resolve inside the folder); a folder with an index file (file.directory.index:
// index.html, then index.htm) shows it; else the browser makes up a listing of the folder: a parent link, folders
// then files, size and date modified, sortable by its column headers (a query: ?sort=size&order=desc), no script.
// Only a navigation sees any of this: a subresource request for a folder fails, so a document never learns what a
// folder holds, and the navigation itself is subject to the file: rules of file_hop (a web page opens no file).

Listing_Sort :: enum u8 { Name, Size, Modified, Type }

File_Settings :: struct {
	index_names:   []string,   // owned (each string too), tried in order
	listing:       bool,
	max_entries:   int,
	show_hidden:   bool,
	sort:          Listing_Sort,
	descending:    bool,
	folders_first: bool,
}

FILE_PREFS := [?]config.Def{
	{name = "file.directory.index", kind = .String, default = {s = "index.html,index.htm"},
		description = "Comma-separated file names a file: folder opens instead of its listing; the first one present wins. Empty: folders always show their listing."},
	{name = "file.directory.listing", kind = .Bool, default = {b = true},
		description = "Show the contents of a file: folder that has no index file (name, size, date modified), as other browsers do. Off: opening such a folder is an error."},
	{name = "file.directory.max_entries", kind = .Int, default = {i = 5000}, bounded = true, min = 1, max = 1_000_000,
		description = "Entries a folder listing shows: the first ones the file system returns, then sorted; the others are counted, not listed."},
	{name = "file.directory.show_hidden", kind = .Bool, default = {b = false},
		description = "List hidden and system files and folders too (desktop.ini, $RECYCLE.BIN, ...)."},
	{name = "file.directory.sort", kind = .String, default = {s = "name"}, choices = {"name", "size", "modified", "type"},
		description = "How a folder listing is sorted when it opens (its column headers sort it otherwise). Names sort as in Explorer: file2 before file10."},
	{name = "file.directory.sort_descending", kind = .Bool, default = {b = false},
		description = "A folder listing opens in descending order of file.directory.sort."},
	{name = "file.directory.folders_first", kind = .Bool, default = {b = true},
		description = "Folders come before files in a folder listing, whatever the sort."},
}

file_settings_from_prefs :: proc(p: ^config.Prefs, allocator := context.allocator) -> File_Settings {
	s: File_Settings
	names := make([dynamic]string, allocator)
	for part in strings.split(config.string_of(p, "file.directory.index"), ",", context.temp_allocator) {
		n := strings.trim_space(part)
		// a bare file name: an index never climbs out of its folder
		if n == "" || strings.contains_any(n, "/\\:") || n == "." || n == ".." { continue }
		append(&names, strings.clone(n, allocator))
	}
	s.index_names = names[:]
	s.listing = config.bool_of(p, "file.directory.listing")
	s.max_entries = int(config.int_of(p, "file.directory.max_entries"))
	s.show_hidden = config.bool_of(p, "file.directory.show_hidden")
	s.sort = parse_listing_sort(config.string_of(p, "file.directory.sort"))
	s.descending = config.bool_of(p, "file.directory.sort_descending")
	s.folders_first = config.bool_of(p, "file.directory.folders_first")
	return s
}

file_settings_clone :: proc(s: File_Settings, allocator := context.allocator) -> File_Settings {
	c := s
	c.index_names = make([]string, len(s.index_names), allocator)
	for n, i in s.index_names { c.index_names[i] = strings.clone(n, allocator) }
	return c
}

file_settings_destroy :: proc(s: ^File_Settings, allocator := context.allocator) {
	for n in s.index_names { delete(n, allocator) }
	delete(s.index_names, allocator)
	s^ = {}
}

@(private)
parse_listing_sort :: proc(s: string) -> Listing_Sort {
	switch s {
	case "size":     return .Size
	case "modified": return .Modified
	case "type":     return .Type
	}
	return .Name
}

@(private)
listing_sort_name :: proc(s: Listing_Sort) -> string {
	switch s {
	case .Name:     return "name"
	case .Size:     return "size"
	case .Modified: return "modified"
	case .Type:     return "type"
	}
	return "name"
}

// The order a listing is asked for: the query of its URL (?sort=size&order=desc, what its column headers link to),
// else the preferences.
listing_order :: proc(query: string, s: ^File_Settings) -> (sort: Listing_Sort, descending: bool) {
	sort, descending = s.sort, s.descending
	for pair in strings.split(query, "&", context.temp_allocator) {
		eq := strings.index_byte(pair, '=')
		if eq < 0 { continue }
		k, v := pair[:eq], pair[eq + 1:]
		switch k {
		case "sort":  sort = parse_listing_sort(v)
		case "order": descending = v == "desc"
		}
	}
	return
}

////////////////////////////////
// Paths and URLs

// A Windows path as a file: URL (the inverse of file_path_from_url): "C:\dir\a b#1.html" -> "file:///C:/dir/a%20b%231.html",
// "\\host\share\x" -> "file://host/share/x", "C:" -> "file:///C:/". Bytes other than unreserved characters, '/' and
// ':' are percent-encoded (UTF-8). `directory`: the URL ends with '/'. The \\?\ prefix of long paths is dropped.
file_url_from_path :: proc(path: string, directory := false, allocator := context.allocator) -> string {
	p := path
	if strings.has_prefix(p, `\\?\UNC\`) {
		p = strings.concatenate({`\\`, p[len(`\\?\UNC\`):]}, context.temp_allocator)
	} else if strings.has_prefix(p, `\\?\`) {
		p = p[len(`\\?\`):]
	}
	s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
	sb := strings.builder_make(allocator)
	if strings.has_prefix(s, "//") {
		strings.write_string(&sb, "file:")   // the host follows: file://host/share/...
	} else {
		strings.write_string(&sb, "file:///")
		s = strings.trim_left(s, "/")
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '.', '_', '~', '/', ':': strings.write_byte(&sb, c)
		case: fmt.sbprintf(&sb, "%%%02X", c)
		}
	}
	drive_only := len(s) == 2 && s[1] == ':'
	if (directory || drive_only) && !strings.has_suffix(strings.to_string(sb), "/") { strings.write_byte(&sb, '/') }
	return strings.to_string(sb)
}

// One path segment of a relative link: everything but unreserved characters is percent-encoded, so that a name with
// '#', '?', '%', ':' or spaces stays one segment of the folder.
@(private)
write_segment :: proc(sb: ^strings.Builder, name: string) {
	for i in 0 ..< len(name) {
		c := name[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '.', '_', '~': strings.write_byte(sb, c)
		case: fmt.sbprintf(sb, "%%%02X", c)
		}
	}
}

// The href of an entry of a listing, relative to the folder's URL ("my file%231.txt", "sub/").
listing_href :: proc(name: string, folder: bool, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	write_segment(&sb, name)
	if folder { strings.write_byte(&sb, '/') }
	return strings.to_string(sb)
}

// The URL a folder URL without its final '/' is redirected to: the same with it (query and fragment kept).
directory_redirect_href :: proc(scheme, host, path, query, fragment: string, has_query, has_fragment: bool, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, scheme)
	strings.write_string(&sb, "://")
	strings.write_string(&sb, host)
	strings.write_string(&sb, path)
	if !strings.has_suffix(path, "/") { strings.write_byte(&sb, '/') }
	if has_query { strings.write_byte(&sb, '?'); strings.write_string(&sb, query) }
	if has_fragment { strings.write_byte(&sb, '#'); strings.write_string(&sb, fragment) }
	return strings.to_string(sb)
}

// "C:\" and "\\host\share\" have no parent folder to link to.
path_is_root :: proc(path: string) -> bool {
	p := strings.trim_right(path, "\\/")
	if len(p) == 2 && p[1] == ':' { return true }
	if strings.has_prefix(p, `\\`) || strings.has_prefix(p, "//") {
		parts := 0
		for part in strings.split_multi(p[2:], {"\\", "/"}, context.temp_allocator) { if part != "" { parts += 1 } }
		return parts <= 2
	}
	return p == ""
}

// A path Win32 accepts whatever its length: \\?\ (or \\?\UNC\) before a long one. The path is absolute and has no
// dot segments (it comes from a parsed URL).
win_path :: proc(path: string, allocator := context.temp_allocator) -> win.wstring {
	p := path
	if len(p) == 2 && p[1] == ':' { p = strings.concatenate({p, "\\"}, context.temp_allocator) }   // "C:" is the drive's current folder
	if len(p) >= 240 && !strings.has_prefix(p, `\\?\`) {
		p = strings.has_prefix(p, `\\`) ? strings.concatenate({`\\?\UNC\`, p[2:]}, context.temp_allocator) : strings.concatenate({`\\?\`, p}, context.temp_allocator)
	}
	return win.utf8_to_wstring(p, allocator)
}

File_Status :: enum u8 { Ok, Not_Found, Access_Denied, Bad_Path, Failed }

@(private)
file_status_of :: proc(err: win.DWORD) -> File_Status {
	switch err {
	case win.ERROR_FILE_NOT_FOUND, win.ERROR_PATH_NOT_FOUND, 15 /* ERROR_INVALID_DRIVE */, 21 /* ERROR_NOT_READY */, 53 /* ERROR_BAD_NETPATH */, 67 /* ERROR_BAD_NET_NAME */:
		return .Not_Found
	case win.ERROR_ACCESS_DENIED, 32 /* ERROR_SHARING_VIOLATION */:
		return .Access_Denied
	case 123 /* ERROR_INVALID_NAME */, 161 /* ERROR_BAD_PATHNAME */, 206 /* ERROR_FILENAME_EXCED_RANGE */:
		return .Bad_Path
	}
	return .Failed
}

file_status_text :: proc(st: File_Status, path: string) -> string {
	switch st {
	case .Ok:            return ""
	case .Not_Found:     return fmt.tprintf("%s: no such file or folder", path)
	case .Access_Denied: return fmt.tprintf("%s: access denied", path)
	case .Bad_Path:      return fmt.tprintf("%s: not a valid path", path)
	case .Failed:        return fmt.tprintf("%s: cannot be read", path)
	}
	return ""
}

File_Attributes :: struct {
	folder:   bool,
	size:     i64,
	modified: u64,   // FILETIME: 100 ns since 1601, UTC
}

file_attributes :: proc(path: string) -> (File_Attributes, File_Status) {
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(win_path(path), win.GetFileExInfoStandard, &data) { return {}, file_status_of(win.GetLastError()) }
	return {
		folder = data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0,
		size = i64(u64(data.nFileSizeHigh) << 32 | u64(data.nFileSizeLow)),
		modified = u64(data.ftLastWriteTime.dwHighDateTime) << 32 | u64(data.ftLastWriteTime.dwLowDateTime),
	}, .Ok
}

// The path a file or folder really is, links and junctions followed (GetFinalPathNameByHandle), in the form of
// file_path_from_url (C:\... or \\server\share\...). False when it cannot be opened.
final_path :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	FILE_FLAG_BACKUP_SEMANTICS :: 0x0200_0000   // folders open too
	h := win.CreateFileW(win_path(path), 0, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == win.INVALID_HANDLE_VALUE { return "", false }
	defer win.CloseHandle(h)
	buf: [1024]u16
	n := win.GetFinalPathNameByHandleW(h, cstring16(&buf[0]), u32(len(buf)), win.VOLUME_NAME_DOS)
	if n == 0 || int(n) >= len(buf) { return "", false }
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "", false }
	switch {
	case strings.has_prefix(s, `\\?\UNC\`): s = strings.concatenate({`\\`, s[8:]}, context.temp_allocator)
	case strings.has_prefix(s, `\\?\`):     s = s[4:]
	}
	return strings.clone(s, allocator), true
}

////////////////////////////////
// Reading a folder

Dir_Entry :: struct {
	name:     string,   // owned
	wide:     []u16,    // owned: the name, NUL-terminated (Explorer's sort compares these)
	folder:   bool,
	link:     bool,     // a junction or a symbolic link
	size:     i64,
	modified: u64,      // FILETIME, UTC
}

Dir_Listing :: struct {
	entries:   [dynamic]Dir_Entry,
	found:     int,    // entries that would be shown (hidden ones excluded), listed or not
	hidden:    int,    // hidden or system entries left out
	truncated: bool,   // more than file.directory.max_entries
}

dir_listing_destroy :: proc(l: ^Dir_Listing) {
	for e in l.entries { delete(e.name); delete(e.wide) }
	delete(l.entries)
	l^ = {}
}

// The entries of a folder (FindFirstFile: names, sizes and dates in one pass), without "." and "..".
read_directory :: proc(path: string, s: ^File_Settings, allocator := context.allocator) -> (l: Dir_Listing, st: File_Status) {
	context.allocator = allocator
	l.entries = make([dynamic]Dir_Entry)
	pattern := strings.concatenate({strings.trim_right(path, "\\/"), "\\*"}, context.temp_allocator)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(win_path(pattern), &fd)
	if h == win.INVALID_HANDLE_VALUE {
		err := win.GetLastError()
		if err == win.ERROR_FILE_NOT_FOUND { return l, .Ok }   // an empty drive: not even "." comes back
		return l, file_status_of(err)
	}
	defer win.FindClose(h)
	limit := max(s.max_entries, 1)
	for {
		n := 0
		for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
		w := fd.cFileName[:n]
		dots := (n == 1 && w[0] == '.') || (n == 2 && w[0] == '.' && w[1] == '.')
		if !dots {
			attrs := fd.dwFileAttributes
			if attrs & (win.FILE_ATTRIBUTE_HIDDEN | win.FILE_ATTRIBUTE_SYSTEM) != 0 && !s.show_hidden {
				l.hidden += 1
			} else {
				l.found += 1
				if len(l.entries) < limit {
					name, _ := win.utf16_to_utf8(w, allocator)
					wide := make([]u16, n + 1)
					copy(wide, w)
					append(&l.entries, Dir_Entry{
						name = name, wide = wide,
						folder = attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0,
						link = attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0,
						size = i64(u64(fd.nFileSizeHigh) << 32 | u64(fd.nFileSizeLow)),
						modified = u64(fd.ftLastWriteTime.dwHighDateTime) << 32 | u64(fd.ftLastWriteTime.dwLowDateTime),
					})
				} else {
					l.truncated = true
				}
			}
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return l, .Ok
}

foreign import shlwapi "system:Shlwapi.lib"
@(default_calling_convention = "system", private)
foreign shlwapi {
	StrCmpLogicalW :: proc(a, b: win.wstring) -> i32 ---
}

// Names compare as in Explorer: case-insensitive, digits as numbers (file2 < file10).
@(private)
name_cmp :: proc(a, b: Dir_Entry) -> i32 {
	if len(a.wide) == 0 || len(b.wide) == 0 { return i32(strings.compare(a.name, b.name)) }
	return StrCmpLogicalW(win.wstring(raw_data(a.wide)), win.wstring(raw_data(b.wide)))
}

@(private)
extension_of :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	return dot > 0 ? name[dot + 1:] : ""
}

@(private) by_name :: proc(a, b: Dir_Entry) -> bool { return name_cmp(a, b) < 0 }
@(private) by_size :: proc(a, b: Dir_Entry) -> bool {
	if a.size != b.size { return a.size < b.size }
	return name_cmp(a, b) < 0
}
@(private) by_modified :: proc(a, b: Dir_Entry) -> bool {
	if a.modified != b.modified { return a.modified < b.modified }
	return name_cmp(a, b) < 0
}
@(private) by_type :: proc(a, b: Dir_Entry) -> bool {
	ea, eb := extension_of(a.name), extension_of(b.name)
	if c := strings.compare(strings.to_lower(ea, context.temp_allocator), strings.to_lower(eb, context.temp_allocator)); c != 0 { return c < 0 }
	return name_cmp(a, b) < 0
}

// Sorts the entries; with folders_first the folders lead whatever the order, each group sorted on its own.
sort_listing :: proc(l: ^Dir_Listing, sort: Listing_Sort, descending, folders_first: bool) {
	less: proc(a, b: Dir_Entry) -> bool
	switch sort {
	case .Name:     less = by_name
	case .Size:     less = by_size
	case .Modified: less = by_modified
	case .Type:     less = by_type
	}
	groups: [2][]Dir_Entry
	if folders_first {
		// stable partition: folders, then files
		folders := 0
		tmp := make([]Dir_Entry, len(l.entries), context.temp_allocator)
		for e in l.entries { if e.folder { tmp[folders] = e; folders += 1 } }
		k := folders
		for e in l.entries { if !e.folder { tmp[k] = e; k += 1 } }
		copy(l.entries[:], tmp)
		groups = {l.entries[:folders], l.entries[folders:]}
	} else {
		groups = {l.entries[:], nil}
	}
	for g in groups {
		slice.stable_sort_by(g, less)
		if descending { slice.reverse(g) }
	}
}

////////////////////////////////
// The listing page

@(private)
html_text :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(sb, "&amp;")
		case '<': strings.write_string(sb, "&lt;")
		case '>': strings.write_string(sb, "&gt;")
		case '"': strings.write_string(sb, "&quot;")
		case '\'': strings.write_string(sb, "&#39;")
		case: strings.write_byte(sb, s[i])
		}
	}
}

// "0 B", "512 B", "1.4 KB", "3.2 MB" (powers of 1024, as Explorer counts).
size_text :: proc(n: i64, allocator := context.temp_allocator) -> string {
	if n < 1024 { return fmt.aprintf("%d B", n, allocator = allocator) }
	units := [?]string{"KB", "MB", "GB", "TB", "PB"}
	v := f64(n) / 1024
	u := 0
	for v >= 1024 && u + 1 < len(units) { v /= 1024; u += 1 }
	return v < 10 ? fmt.aprintf("%.1f %s", v, units[u], allocator = allocator) : fmt.aprintf("%.0f %s", v, units[u], allocator = allocator)
}

// A FILETIME (UTC) as the local date and time: "2026-10-19 14:32".
local_time_text :: proc(ft: u64, allocator := context.temp_allocator) -> string {
	if ft == 0 { return "" }
	f := win.FILETIME{dwLowDateTime = win.DWORD(ft & 0xFFFF_FFFF), dwHighDateTime = win.DWORD(ft >> 32)}
	utc, loc: win.SYSTEMTIME
	if !win.FileTimeToSystemTime(&f, &utc) { return "" }
	if !win.SystemTimeToTzSpecificLocalTime(nil, &utc, &loc) { loc = utc }
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", loc.year, loc.month, loc.day, loc.hour, loc.minute, allocator = allocator)
}

@(private)
LISTING_STYLE :: `
  :root { color-scheme: light dark; }
  html { background-color: Canvas; }
  body { margin: 0; color: CanvasText; font-family: system-ui; font-size: 14px; }
  .wrap { max-width: 980px; margin: 0 auto; padding: 28px 24px 40px; }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 6px; overflow-wrap: anywhere; }
  .sub { color: GrayText; font-size: 13px; margin: 0 0 18px; }
  .up { margin: 0 0 10px; }
  a { color: LinkText; text-decoration: none; }
  a:hover { text-decoration: underline; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; font-size: 12px; font-weight: 600; color: GrayText; padding: 6px 12px; border-bottom: 1px solid light-dark(#c9ced8, #3b4152); white-space: nowrap; }
  th a { color: GrayText; }
  th.on a { color: CanvasText; }
  td { padding: 5px 12px; border-bottom: 1px solid light-dark(#eceef3, #262b36); white-space: nowrap; }
  td.name { white-space: normal; overflow-wrap: anywhere; width: 100%; }
  tr:hover td { background-color: light-dark(#f3f5f9, #1c2130); }
  .num { text-align: right; }
  .date { color: light-dark(#5b6170, #9aa1b2); }
  a.dir { font-weight: 600; }
  .icon { display: inline-block; width: 1.5em; color: light-dark(#8a909e, #7d8496); }
  .dir .icon { color: light-dark(#c98a12, #e0a53c); }
  .link { color: GrayText; font-size: 12px; }
  .note { margin: 14px 0 0; padding: 8px 12px; border-radius: 6px; background-color: light-dark(#fff4d6, #3a2f12); color: light-dark(#6b4e00, #f2d48a); font-size: 13px; }
  .foot { color: GrayText; font-size: 12px; margin: 14px 0 0; }
  .empty { color: GrayText; padding: 18px 12px; }
`

@(private)
listing_header :: proc(sb: ^strings.Builder, label: string, col: Listing_Sort, sort: Listing_Sort, descending: bool, numeric: bool) {
	on := col == sort
	// a click on the current column flips the order; another column opens ascending (size and dates: largest, newest first)
	desc := on ? !descending : (col == .Size || col == .Modified)
	cls := numeric ? (on ? " class=\"num on\"" : " class=\"num\"") : (on ? " class=\"on\"" : "")
	fmt.sbprintf(sb, "<th%s><a href=\"?sort=%s&amp;order=%s\">%s", cls, listing_sort_name(col), desc ? "desc" : "asc", label)
	if on { strings.write_string(sb, descending ? " \u25BE" : " \u25B4") }
	strings.write_string(sb, "</a></th>")
}

// The page shown for a folder without an index file. `path` is the folder's (with its final separator); the links of
// the entries are relative to the folder's URL.
directory_listing_html :: proc(path: string, l: ^Dir_Listing, sort: Listing_Sort, descending: bool, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	shown := path
	if !strings.has_suffix(shown, "\\") { shown = strings.concatenate({shown, "\\"}, context.temp_allocator) }
	strings.write_string(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"color-scheme\" content=\"light dark\">\n<title>Index of ")
	html_text(&sb, shown)
	strings.write_string(&sb, "</title>\n<style>")
	strings.write_string(&sb, LISTING_STYLE)
	strings.write_string(&sb, "</style>\n</head>\n<body>\n<div class=\"wrap\">\n<h1>Index of ")
	html_text(&sb, shown)
	strings.write_string(&sb, "</h1>\n")
	folders, files := 0, 0
	for e in l.entries { if e.folder { folders += 1 } else { files += 1 } }
	fmt.sbprintf(&sb, "<p class=\"sub\">%d folder%s, %d file%s", folders, folders == 1 ? "" : "s", files, files == 1 ? "" : "s")
	if l.hidden > 0 { fmt.sbprintf(&sb, " &middot; %d hidden item%s not shown", l.hidden, l.hidden == 1 ? "" : "s") }
	strings.write_string(&sb, "</p>\n")
	if !path_is_root(path) { strings.write_string(&sb, "<p class=\"up\"><a href=\"../\">\u2191 Parent folder</a></p>\n") }
	strings.write_string(&sb, "<table>\n<thead><tr>")
	listing_header(&sb, "Name", .Name, sort, descending, false)
	listing_header(&sb, "Size", .Size, sort, descending, true)
	listing_header(&sb, "Date modified", .Modified, sort, descending, false)
	listing_header(&sb, "Type", .Type, sort, descending, false)
	strings.write_string(&sb, "</tr></thead>\n<tbody>\n")
	for e in l.entries {
		strings.write_string(&sb, "<tr><td class=\"name\"><a")
		if e.folder { strings.write_string(&sb, " class=\"dir\"") }
		strings.write_string(&sb, " href=\"")
		html_text(&sb, listing_href(e.name, e.folder))
		strings.write_string(&sb, "\"><span class=\"icon\">")
		strings.write_string(&sb, e.folder ? "\U0001F4C1" : "\U0001F4C4")
		strings.write_string(&sb, "</span>")
		html_text(&sb, e.name)
		if e.folder { strings.write_byte(&sb, '/') }
		strings.write_string(&sb, "</a>")
		if e.link { strings.write_string(&sb, " <span class=\"link\">(link)</span>") }
		strings.write_string(&sb, "</td><td class=\"num\">")
		if !e.folder { strings.write_string(&sb, size_text(e.size)) }
		strings.write_string(&sb, "</td><td class=\"date\">")
		strings.write_string(&sb, local_time_text(e.modified))
		strings.write_string(&sb, "</td><td class=\"date\">")
		if e.folder {
			strings.write_string(&sb, "Folder")
		} else if ext := extension_of(e.name); ext != "" {
			html_text(&sb, strings.to_upper(ext, context.temp_allocator))
		}
		strings.write_string(&sb, "</td></tr>\n")
	}
	strings.write_string(&sb, "</tbody>\n</table>\n")
	if len(l.entries) == 0 { strings.write_string(&sb, "<p class=\"empty\">This folder is empty.</p>\n") }
	if l.truncated {
		fmt.sbprintf(&sb, "<p class=\"note\">Showing %d of %d entries (file.directory.max_entries in about:config).</p>\n", len(l.entries), l.found)
	}
	if l.hidden > 0 { strings.write_string(&sb, "<p class=\"foot\">Hidden and system items are left out (file.directory.show_hidden in about:config).</p>\n") }
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

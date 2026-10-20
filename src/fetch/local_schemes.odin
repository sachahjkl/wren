package fetch

import "core:os"
import "core:strconv"
import "core:strings"
import "wb:http"
import "wb:url"

////////////////////////////////
// data: URLs (RFC 2397 as processed by the Fetch Standard)

Data_URL :: struct {
	mime: string,   // owned
	body: []byte,   // owned
}

data_url_destroy :: proc(d: ^Data_URL) {
	delete(d.mime)
	delete(d.body)
	d^ = {}
}

percent_decode :: proc(s: string, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, len(s), allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) && is_hex(s[i + 1]) && is_hex(s[i + 2]) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok { append(&out, u8(v)); i += 3; continue }
		}
		append(&out, s[i])
		i += 1
	}
	return out[:]
}

@(private)
is_hex :: proc(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

// "forgiving-base64 decode" (WHATWG Infra): ASCII whitespace is removed, padding is optional.
forgiving_base64_decode :: proc(input: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	data := make([dynamic]byte, 0, len(input), context.temp_allocator)
	for c in input { if c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != '\f' { append(&data, c) } }
	if len(data) % 4 == 0 && len(data) >= 1 {
		if data[len(data) - 1] == '=' { pop(&data) }
		if len(data) > 0 && data[len(data) - 1] == '=' { pop(&data) }
	}
	if len(data) % 4 == 1 { return nil, false }
	val :: proc(c: u8) -> int {
		switch {
		case c >= 'A' && c <= 'Z': return int(c - 'A')
		case c >= 'a' && c <= 'z': return int(c - 'a') + 26
		case c >= '0' && c <= '9': return int(c - '0') + 52
		case c == '+': return 62
		case c == '/': return 63
		}
		return -1
	}
	res := make([dynamic]byte, 0, len(data) * 3 / 4, allocator)
	buffer, bits := 0, 0
	for c in data {
		v := val(c)
		if v < 0 { delete(res); return nil, false }
		buffer = buffer << 6 | v
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&res, u8(buffer >> uint(bits) & 0xFF))
			buffer &= (1 << uint(bits)) - 1
		}
	}
	return res[:], true
}

// Processes a `data:` URL (already parsed). ok = false when it is malformed.
process_data_url :: proc(u: url.URL, allocator := context.allocator) -> (d: Data_URL, ok: bool) {
	// everything after "data:" up to the fragment; the query is part of the data
	input := u.href[len("data:"):]
	if i := strings.index_byte(input, '#'); i >= 0 { input = input[:i] }
	comma := strings.index_byte(input, ',')
	if comma < 0 { return {}, false }
	header := strings.trim(input[:comma], "\t\n\r\f ")
	body := percent_decode(input[comma + 1:], context.temp_allocator)

	is_base64 := false
	lower := strings.to_lower(header, context.temp_allocator)
	if strings.has_suffix(lower, ";base64") {
		is_base64 = true
		header = strings.trim_right(header[:len(header) - len(";base64")], " ")
	}
	mime_str := header
	if strings.has_prefix(mime_str, ";") || mime_str == "" { mime_str = strings.concatenate({"text/plain", mime_str}, context.temp_allocator) }
	m, mok := http.parse_mime(mime_str, context.temp_allocator)
	if mok {
		essence := strings.concatenate({m.type, "/", m.subtype}, context.temp_allocator)
		if cs, has := http.mime_param(m, "charset"); has { d.mime = strings.concatenate({essence, ";charset=", cs}, allocator) } else { d.mime = strings.clone(essence, allocator) }
	} else { d.mime = strings.clone("text/plain;charset=US-ASCII", allocator) }

	if is_base64 {
		decoded, good := forgiving_base64_decode(body, allocator)
		if !good { delete(d.mime, allocator); return {}, false }
		d.body = decoded
	} else {
		d.body = make([]byte, len(body), allocator)
		copy(d.body, body)
	}
	return d, true
}

////////////////////////////////
// file: URLs

// "/C:/dir/a b.txt" (URL path) -> "C:\dir\a b.txt"; UNC hosts become \\host\share\...
file_path_from_url :: proc(u: url.URL, allocator := context.allocator) -> (path: string, ok: bool) {
	if u.scheme != "file" { return "", false }
	raw := percent_decode(u.path, context.temp_allocator)
	p := string(raw)
	if strings.contains(p, "\x00") { return "", false }
	// "/C:/x" -> "C:/x"
	if len(p) >= 3 && p[0] == '/' && p[2] == ':' && ((p[1] >= 'a' && p[1] <= 'z') || (p[1] >= 'A' && p[1] <= 'Z')) { p = p[1:] }
	if u.host != "" && u.host != "localhost" { p = strings.concatenate({"//", u.host, p}, context.temp_allocator) }
	if !file_path_safe(p) { return "", false }
	out, allocated := strings.replace_all(p, "/", "\\", allocator)
	if !allocated { out = strings.clone(out, allocator) }   // ("C:" has no '/': the result would be the temporary decoding)
	return out, true
}

// Whether a decoded file: path names the file it says, as Windows will open it. Refused, whoever asks:
//   * a "." or ".." segment: the URL parser removed those of the URL, so one left came from an encoded separator (%5C,
//     %2F) and would climb out of the folder the access check saw (file:///C:/site/a%5C..%5C..%5Csecret);
//   * a ':' past the drive letter (an alternate data stream, file.txt:hidden) and control characters;
//   * segments Windows rewrites: trailing dots or spaces ("a.txt." opens a.txt), device names (CON, NUL, COM1, LPT1...,
//     with an extension or not, which open devices instead of files);
//   * device paths (\\?\, \\.\), which skip the normalization these rules rely on.
file_path_safe :: proc(p: string) -> bool {
	for c, i in transmute([]u8)p {
		if c < 0x20 || c == 0x7f || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*' { return false }
		if c == ':' && !(i == 1 && ((p[0] >= 'a' && p[0] <= 'z') || (p[0] >= 'A' && p[0] <= 'Z'))) { return false }
	}
	rest := p
	for len(rest) > 0 {
		end := strings.index_any(rest, "/\\")
		seg := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end + 1:]
		if seg == "" { continue }
		if seg == "." || seg == ".." { return false }
		if len(p) >= 2 && p[1] == ':' && len(seg) == 2 && seg[1] == ':' { continue }   // the drive
		last := seg[len(seg) - 1]
		if last == '.' || last == ' ' { return false }
		if is_device_name(seg) { return false }
	}
	return true
}

// CON, PRN, AUX, NUL, COM1-9, LPT1-9 (and their superscript-digit forms), CONIN$, CONOUT$: whatever follows a dot or
// trailing spaces, Windows opens the device.
@(private)
is_device_name :: proc(seg: string) -> bool {
	base := seg
	if i := strings.index_byte(base, '.'); i >= 0 { base = base[:i] }
	base = strings.trim_right(base, " ")
	upper := strings.to_upper(base, context.temp_allocator)
	switch upper {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$": return true
	}
	if len(upper) >= 4 && (strings.has_prefix(upper, "COM") || strings.has_prefix(upper, "LPT")) {
		digit := upper[3:]
		if len(digit) == 1 && digit[0] >= '1' && digit[0] <= '9' { return true }
		if digit == "¹" || digit == "²" || digit == "³" { return true }
	}
	return false
}

// The directory of a file: URL's file, without trailing separator.
file_directory :: proc(u: url.URL, allocator := context.allocator) -> string {
	p, ok := file_path_from_url(u, context.temp_allocator)
	if !ok { return "" }
	if i := strings.last_index_byte(p, '\\'); i >= 0 { return strings.clone(p[:i], allocator) }
	return strings.clone(p, allocator)
}

// Is `path` inside the directory tree `root` (case-insensitive, on a separator boundary)?
path_within :: proc(root, path: string) -> bool {
	if root == "" { return false }
	if len(path) < len(root) || !strings.equal_fold(path[:len(root)], root) { return false }
	return len(path) == len(root) || path[len(root)] == '\\' || strings.has_suffix(root, "\\")
}

mime_for_extension :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	if dot < 0 { return "application/octet-stream" }
	switch strings.to_lower(path[dot + 1:], context.temp_allocator) {
	case "html", "htm": return "text/html;charset=utf-8"
	case "css":         return "text/css"
	case "js", "mjs":   return "text/javascript"
	case "json":        return "application/json"
	case "wasm":        return "application/wasm"
	case "txt":         return "text/plain;charset=utf-8"
	case "svg":         return "image/svg+xml"
	case "png":         return "image/png"
	case "jpg", "jpeg": return "image/jpeg"
	case "gif":         return "image/gif"
	case "webp":        return "image/webp"
	case "ico":         return "image/x-icon"
	case "woff2":       return "font/woff2"
	case "woff":        return "font/woff"
	case "ttf":         return "font/ttf"
	case "xml":         return "application/xml"
	case "mp3":         return "audio/mpeg"
	case "mp4":         return "video/mp4"
	}
	return "application/octet-stream"
}

// May `env` read this file? The browser UI may read anything; a file: document may read files in its own directory tree
// (the rule Firefox's strict file origin policy uses); nobody else may.
file_access_allowed :: proc(env: ^Environment, path: string, policy: File_Access) -> bool {
	if env == nil || policy == .All { return true }
	if policy == .None { return false }
	return path_within(env.file_root, path)
}

_ :: os

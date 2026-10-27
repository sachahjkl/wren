package config

// What about:config shows of a preference besides its dotted name: a readable title, the first sentence of its
// description (the rest goes behind a "details" fold), a heading for its category, and the search over all of them.
// Pure functions of the definitions: nothing here allocates outside the given allocator.

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The title of a preference, derived from its name (the definitions stay one name each: no second label to keep in
// step, and every preference gets one). The category's own segment is dropped (the page shows it as the group heading), the remaining segments and words read as a phrase in
// sentence case with acronyms spelt as such, a trailing unit word goes (about:config shows the unit by the value), and so
// does the "enabled" of a switch (its toggle says it):
//
//   blocker.badge.style            -> Badge style
//   blocker.cosmetic.debounce_ms   -> Cosmetic debounce
//   network.http.max_connections   -> HTTP max connections
//   blocker.badge.enabled          -> Badge
//
// `keep_unit`: the unit word stays ("DevTools network max body KB"), for the rare category where two preferences differ
// by their unit only (about:config asks for it then).
title_of :: proc(d: Def, allocator := context.temp_allocator, keep_unit := false) -> string {
	rest := d.name
	cat := d.category != "" ? d.category : first_segment(d.name)
	if len(rest) > len(cat) && strings.has_prefix(rest, cat) && rest[len(cat)] == '.' {
		rest = rest[len(cat) + 1:]
	} else if i := strings.index_byte(rest, '.'); i >= 0 && i + 1 < len(rest) {
		rest = rest[i + 1:]   // a category of its own ("testing"): the first segment still names the subsystem
	}
	words := split_words(rest, context.temp_allocator)
	if !keep_unit && len(words) > 1 && is_unit_word(words[len(words) - 1]) { words = words[:len(words) - 1] }
	if d.kind == .Bool && len(words) > 1 && words[len(words) - 1] == "enabled" { words = words[:len(words) - 1] }
	return phrase(words, allocator)
}

// The heading of a category ("devtools" -> "DevTools", "privacy" -> "Privacy").
category_title :: proc(category: string, allocator := context.temp_allocator) -> string {
	return phrase(split_words(category, context.temp_allocator), allocator)
}

// The first sentence of a description, and what follows it (trimmed; empty when the description is one sentence). A
// sentence ends at a full stop followed by a space and a capital letter, outside parentheses, and not after a common
// abbreviation ("e.g.", "i.e.", "etc.", "vs.", "cf."), so "0.5", "e.g. foo" and "(see below. Then)" do not cut it.
summary_of :: proc(description: string) -> (summary, more: string) {
	s := description
	depth := 0
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '(', '[': depth += 1
		case ')', ']': depth = max(depth - 1, 0)
		case '.', '!', '?':
			if depth > 0 || i + 1 >= len(s) || s[i + 1] != ' ' { continue }
			if s[i] == '.' && after_abbreviation(s[:i]) { continue }
			j := i + 1
			for j < len(s) && s[j] == ' ' { j += 1 }
			if j >= len(s) { return strings.trim_space(s[:i + 1]), "" }
			r, _ := utf8.decode_rune_in_string(s[j:])
			if !unicode.is_upper(r) && r != '(' && r != '"' && r != '\'' && r != '`' { continue }
			return strings.trim_space(s[:i + 1]), strings.trim_space(s[j:])
		}
	}
	return strings.trim_space(s), ""
}

// Whether a preference matches a search: every word of `query` (lower case, separated by spaces) appears in its name,
// its title or its description. An empty query matches everything.
matches :: proc(d: Def, query: string) -> bool {
	q := strings.trim_space(query)
	if q == "" { return true }
	name := strings.to_lower(d.name, context.temp_allocator)
	title := strings.to_lower(title_of(d), context.temp_allocator)
	desc := strings.to_lower(d.description, context.temp_allocator)
	for word in strings.fields_iterator(&q) {
		if !strings.contains(name, word) && !strings.contains(title, word) && !strings.contains(desc, word) { return false }
	}
	return true
}

@(private = "file")
split_words :: proc(s: string, allocator := context.temp_allocator) -> []string {
	words := make([dynamic]string, allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == '.' || s[i] == '_' || s[i] == '-' {
			if i > start { append(&words, s[start:i]) }
			start = i + 1
		}
	}
	return words[:]
}

@(private = "file")
phrase :: proc(words: []string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for w, i in words {
		if i > 0 { strings.write_byte(&sb, ' ') }
		if sp := spelling(w); sp != "" {
			strings.write_string(&sb, sp)
		} else if i == 0 {
			r, n := utf8.decode_rune_in_string(w)
			strings.write_rune(&sb, unicode.to_upper(r))
			strings.write_string(&sb, w[n:])
		} else {
			strings.write_string(&sb, w)
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
is_unit_word :: proc(w: string) -> bool {
	switch w {
	case "ms", "us", "ns", "s", "sec", "secs", "seconds", "minutes", "hours", "days", "kb", "mb", "gb", "kib", "mib", "bytes", "px", "pct", "percent", "hz":
		return true
	}
	return false
}

@(private = "file")
after_abbreviation :: proc(before: string) -> bool {
	for a in ([]string{"e.g", "i.e", "etc", "vs", "cf", "approx"}) {
		if !strings.has_suffix(before, a) { continue }
		k := len(before) - len(a)
		if k == 0 || before[k - 1] == ' ' || before[k - 1] == '(' { return true }
	}
	return false
}

// Words a title spells otherwise than in lower case ("" when it does not).
@(private = "file")
spelling :: proc(w: string) -> string {
	switch w {
	case "kb", "mb", "gb": return strings.to_upper(w, context.temp_allocator)
	case "kib": return "KiB"
	case "mib": return "MiB"
	case "url": return "URL"
	case "urls": return "URLs"
	case "http": return "HTTP"
	case "https": return "HTTPS"
	case "http2", "h2": return "HTTP/2"
	case "http3", "h3": return "HTTP/3"
	case "dns": return "DNS"
	case "doh": return "DoH"
	case "tls": return "TLS"
	case "ssl": return "SSL"
	case "ocsp": return "OCSP"
	case "hsts": return "HSTS"
	case "csp": return "CSP"
	case "cors": return "CORS"
	case "sni": return "SNI"
	case "ech": return "ECH"
	case "quic": return "QUIC"
	case "ip": return "IP"
	case "ipv4": return "IPv4"
	case "ipv6": return "IPv6"
	case "js": return "JS"
	case "javascript": return "JavaScript"
	case "css": return "CSS"
	case "html": return "HTML"
	case "svg": return "SVG"
	case "png": return "PNG"
	case "jpeg", "jpg": return "JPEG"
	case "gif": return "GIF"
	case "pdf": return "PDF"
	case "mime": return "MIME"
	case "json": return "JSON"
	case "xml": return "XML"
	case "id": return "ID"
	case "ids": return "IDs"
	case "ui": return "UI"
	case "ua": return "UA"
	case "api": return "API"
	case "gpu": return "GPU"
	case "cpu": return "CPU"
	case "io": return "I/O"
	case "os": return "OS"
	case "dpi": return "DPI"
	case "fps": return "FPS"
	case "hud": return "HUD"
	case "ttl": return "TTL"
	case "lru": return "LRU"
	case "hdr": return "HDR"
	case "srgb": return "sRGB"
	case "rgb": return "RGB"
	case "msaa": return "MSAA"
	case "sdf": return "SDF"
	case "vsync": return "VSync"
	case "colr": return "COLR"
	case "dwrite": return "DirectWrite"
	case "dxgi": return "DXGI"
	case "d3d", "d3d11", "d3d12": return strings.to_upper(w, context.temp_allocator)
	case "wasm": return "Wasm"
	case "wamr": return "WAMR"
	case "quickjs": return "QuickJS"
	case "webgpu": return "WebGPU"
	case "webgl": return "WebGL"
	case "webauthn": return "WebAuthn"
	case "websocket", "websockets": return w == "websocket" ? "WebSocket" : "WebSockets"
	case "webrtc": return "WebRTC"
	case "devtools": return "DevTools"
	case "idb", "indexeddb": return "IndexedDB"
	case "a11y": return "Accessibility"
	case "utf8": return "UTF-8"
	case "wpt": return "WPT"
	case "uri": return "URI"
	case "dom": return "DOM"
	case "eventsource": return "EventSource"
	case "sse": return "SSE"
	case "xhr": return "XHR"
	case "cjk": return "CJK"
	case "rtl": return "RTL"
	case "ime": return "IME"
	case "uwp": return "UWP"
	case "dwm": return "DWM"
	case "dx": return "DirectX"
	case "png8": return "PNG8"
	case "webp": return "WebP"
	case "avif": return "AVIF"
	case "mp4": return "MP4"
	case "mp3": return "MP3"
	case "aac": return "AAC"
	case "h264": return "H.264"
	case "rss": return "RSS"
	case "ftp": return "FTP"
	case "smtp": return "SMTP"
	case "ws", "wss": return strings.to_upper(w, context.temp_allocator)
	}
	return ""
}

package desktop

// Links that open in Wren from any web page: the integration registers the schemes `<prefix>http`, `<prefix>https` and
// `<prefix>about` (prefix "wren-": wren-https://example.org/a?b#c) with the system, which runs
// `"<exe>" --open-url "%1"` (Windows) or the desktop entry's `%U` (Linux). The link is the address without the prefix,
// opened as a tab of the Wren that runs (the single instance) or of a new one.
//
// A link comes from a page nobody vouches for: only http and https addresses and about:wren come out of one, parsed by
// Wren's own URL parser; anything else (wren-file:, wren-javascript:, wren-data:, wren-blob:, a control character, a link
// longer than LINK_MAX_BYTES) is refused and nothing opens. The address goes to a tab as the command line's addresses do:
// no referrer, nothing of the page that had the link.

import "core:strings"
import "wb:base"
import "wb:url"

LINK_FLAG :: "--open-url"
// The release's prefix, what the web site's links use. A development build registers its own (Identity.link_prefix) and
// opens both from its command line.
LINK_PREFIX :: "wren-"
LINK_MAX_BYTES :: 8 * 1024
LINK_ABOUT :: "about:wren"
// What a refused link ends the program with (the command line's code for a usage error).
LINK_REFUSED_EXIT :: 2

// The schemes a link stands for; each is registered behind the identity's prefix.
LINK_SCHEMES :: [?]string{"http", "https", "about"}

Link_Error :: enum u8 {
	None,
	Not_A_Link,          // no `<prefix><scheme>:` in front (after --open-url, where only a link may be)
	Too_Long,            // more than LINK_MAX_BYTES
	Control_Character,   // a C0 control or DEL
	Scheme,              // a scheme other than http, https, about:wren
	Invalid,             // the URL parser refuses it, or an http(s) address without a host
	Misplaced,           // --open-url is not the one but last argument, or comes more than once
}

// The schemes a prefix registers ("wren-http", "wren-https", "wren-about"); none for "".
link_scheme_names :: proc(prefix: string, allocator := context.temp_allocator) -> []string {
	if prefix == "" { return nil }
	out := make([]string, len(LINK_SCHEMES), allocator)
	for s, i in LINK_SCHEMES { out[i] = strings.concatenate({prefix, s}, allocator) }
	return out
}

link_error_text :: proc(e: Link_Error) -> string {
	switch e {
	case .None:              return "ok"
	case .Not_A_Link:        return "not a link that opens in Wren"
	case .Too_Long:          return "the link is too long"
	case .Control_Character: return "the link has a control character"
	case .Scheme:            return "only http, https and about:wren links open in Wren"
	case .Invalid:           return "not a valid address"
	case .Misplaced:         return "--open-url takes the last argument, once"
	}
	return ""
}

// True when `arg` begins with `<prefix><scheme>:` (the URL parser's leading controls and spaces aside): a link, to open or
// to refuse. A file named wren-notes.html is not one.
is_link :: proc(arg, prefix: string) -> bool {
	s := strings.trim_left_proc(arg, proc(r: rune) -> bool { return r <= ' ' })
	if prefix == "" || !base.ascii_has_prefix_fold(s, prefix) { return false }
	rest := s[len(prefix):]
	for i in 0 ..< len(rest) {
		c := rest[i]
		switch {
		case c == ':':                                                   return i > 0
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'):
		case:                                                            return false
		}
	}
	return false
}

// The address a link opens ("wren-https://a.b/c?d#e" -> "https://a.b/c?d#e", "wren-about:wren" -> "about:wren"), in
// `allocator`; err says why there is none.
link_address :: proc(link, prefix: string, allocator := context.allocator) -> (address: string, err: Link_Error) {
	if !is_link(link, prefix) { return "", .Not_A_Link }
	if len(link) > LINK_MAX_BYTES { return "", .Too_Long }
	for i in 0 ..< len(link) { if link[i] < ' ' || link[i] == 0x7F { return "", .Control_Character } }
	rest := strings.trim_left_space(link)[len(prefix):]
	scheme := rest[:strings.index_byte(rest, ':')]
	known := false
	for s in LINK_SCHEMES { if base.ascii_equal_fold(scheme, s) { known = true } }
	if !known { return "", .Scheme }
	u, ok := url.parse_absolute(rest, context.temp_allocator)
	if !ok { return "", .Invalid }
	switch u.scheme {
	case "http", "https":
		if u.host == "" { return "", .Invalid }
		return strings.clone(u.href, allocator), .None
	case "about":
		if u.href == LINK_ABOUT { return strings.clone(LINK_ABOUT, allocator), .None }
	}
	return "", .Scheme
}

// The command line with its links made addresses: `--open-url <link>` (what the registered schemes run) and every argument
// that is a link of one of `prefixes` (the longest that fits: "wren-dev-" before "wren-"). `--open-url` must be the one
// but last argument: what the system puts in place of %1 is the last one, and a quote in a link it did not encode could
// only add arguments after it. Any refused link refuses the whole command line.
links_in_args :: proc(args: []string, prefixes: []string, allocator := context.temp_allocator) -> (out: [dynamic]string, err: Link_Error) {
	out = make([dynamic]string, allocator)
	flags := 0
	for a in args { if a == LINK_FLAG { flags += 1 } }
	if flags > 1 || (flags == 1 && (len(args) < 2 || args[len(args) - 2] != LINK_FLAG)) { return out, .Misplaced }
	for a, i in args {
		if a == LINK_FLAG { continue }
		prefix := ""
		for p in prefixes { if len(p) > len(prefix) && is_link(a, p) { prefix = p } }
		if prefix == "" && !(flags == 1 && i == len(args) - 1) { append(&out, a); continue }
		address, e := link_address(a, prefix, allocator)
		if e != .None { return out, e }
		append(&out, address)
	}
	return out, .None
}

package fetch

import "core:strconv"
import "core:strings"
import "wb:config"

// Policy knobs of the fetch layer (about:config: `network.*`, `privacy.*`, `security.*`). What the Fetch Standard
// *requires* (CORS rules, the forbidden header list, cookie semantics) is not configurable; limits, defaults, and the
// switches a developer or administrator legitimately needs are.

File_Access :: enum u8 {
	Own_Tree,   // a file: document reads files in its own directory tree
	None,       // a file: document reads no other file
	All,        // a file: document reads any local file (development only)
}

Settings :: struct {
	max_redirects:          int,
	third_party_cookies:    Third_Party_Cookies,
	accept_language:        string,   // owned
	referrer_policy:        Referrer_Policy,
	referrer_max_length:    int,
	preflight_max_entries:  int,
	preflight_default_age_s: int,
	preflight_max_age_s:    int,
	block_active_mixed:     bool,     // scripts, fetches, styles over http from an https document
	upgrade_passive_mixed:  bool,     // images, audio, video are upgraded to https instead of blocked
	hsts:                   bool,
	csp:                    bool,
	fetch_metadata:         bool,     // Sec-Fetch-* request headers
	file_access:            File_Access,
	bad_ports_allowed:      []int,    // owned: ports taken off the built-in blocklist
	bad_ports_blocked:      []int,    // owned: ports added to it
	files:                  File_Settings,   // file: folders: index, listing (directory.odin)
}

PREFS := [?]config.Def{
	{name = "network.redirect.max", kind = .Int, default = {i = 20}, bounded = true, min = 0, max = 1000,
		description = "Redirects followed for one request before it fails (the Fetch Standard says 20)."},
	{name = "privacy.third_party_cookies", kind = .String, default = {s = "block"}, choices = {"block", "allow"},
		description = "block: cookies are neither sent nor stored for requests that are cross-site to the page you are on."},
	{name = "network.accept_language", kind = .String, default = {s = "en-US,en;q=0.9"}, description = "The Accept-Language request header."},
	{name = "network.referrer.default_policy", kind = .String, default = {s = "strict-origin-when-cross-origin"},
		choices = {"no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin", "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url"},
		description = "Referrer policy used when neither the request nor the page chooses one."},
	{name = "network.referrer.max_length", kind = .Int, default = {i = 4096}, bounded = true, min = 64, max = 1 << 20, unit = "bytes",
		description = "A longer referrer is reduced to the origin."},
	{name = "network.preflight.cache_entries", kind = .Int, default = {i = 1000}, bounded = true, min = 0, max = 1_000_000,
		description = "CORS preflight results remembered. 0 disables the cache."},
	{name = "network.preflight.default_age_s", kind = .Int, default = {i = 5}, bounded = true, min = 0, max = 86_400, unit = "s",
		description = "How long a preflight is cached when the server sends no Access-Control-Max-Age."},
	{name = "network.preflight.max_age_s", kind = .Int, default = {i = 7200}, bounded = true, min = 0, max = 604_800, unit = "s",
		description = "Upper bound for Access-Control-Max-Age."},
	{name = "security.mixed_content.block_active", kind = .Bool, default = {b = true},
		description = "Block every http (and ws:) request of an https page other than images, audio and video: scripts, fetches, styles, fonts, workers, WebSockets."},
	{name = "security.mixed_content.upgrade_passive", kind = .Bool, default = {b = true},
		description = "Load images, audio and video over https instead of blocking them when an https page asks for http."},
	{name = "network.hsts.enabled", kind = .Bool, default = {b = true}, description = "Remember Strict-Transport-Security and upgrade http to https for those hosts."},
	{name = "security.csp.enabled", kind = .Bool, default = {b = true}, description = "Enforce the Content-Security-Policy of pages and workers (headers and <meta>): what they may fetch and connect to (connect-src, script-src, img-src...), inline scripts and handlers, eval, javascript: URLs. Off: no policy is taken from pages at all (a debugging aid: pages lose a protection)."},
	{name = "network.fetch_metadata.enabled", kind = .Bool, default = {b = true}, description = "Send Sec-Fetch-Dest / Mode / Site / User to trustworthy servers."},
	{name = "security.file_access.policy", kind = .String, default = {s = "own_tree"}, choices = {"own_tree", "none", "all"},
		description = "What a file: document may read. own_tree: its own directory tree. none: no file at all, not even its own modules. all: any local file (development only)."},
	{name = "network.bad_ports.allowed", kind = .String, default = {s = ""},
		description = "Comma-separated ports to take off the blocklist of ports reserved for other protocols (for example 6000,10080)."},
	{name = "network.bad_ports.blocked", kind = .String, default = {s = ""}, description = "Comma-separated ports to add to the blocklist."},
}

register_prefs :: proc(p: ^config.Prefs) {
	config.register(p, PREFS[:])
	config.register(p, FILE_PREFS[:])
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.max_redirects = int(config.int_of(p, "network.redirect.max"))
	s.third_party_cookies = config.string_of(p, "privacy.third_party_cookies") == "allow" ? .Allow : .Block
	s.accept_language = strings.clone(config.string_of(p, "network.accept_language"))
	s.referrer_policy = parse_referrer_policy(config.string_of(p, "network.referrer.default_policy"))
	s.referrer_max_length = int(config.int_of(p, "network.referrer.max_length"))
	s.preflight_max_entries = int(config.int_of(p, "network.preflight.cache_entries"))
	s.preflight_default_age_s = int(config.int_of(p, "network.preflight.default_age_s"))
	s.preflight_max_age_s = int(config.int_of(p, "network.preflight.max_age_s"))
	s.block_active_mixed = config.bool_of(p, "security.mixed_content.block_active")
	s.upgrade_passive_mixed = config.bool_of(p, "security.mixed_content.upgrade_passive")
	s.hsts = config.bool_of(p, "network.hsts.enabled")
	s.csp = config.bool_of(p, "security.csp.enabled")
	s.fetch_metadata = config.bool_of(p, "network.fetch_metadata.enabled")
	switch config.string_of(p, "security.file_access.policy") {
	case "none": s.file_access = .None
	case "all":  s.file_access = .All
	case:        s.file_access = .Own_Tree
	}
	s.bad_ports_allowed = parse_port_list(config.string_of(p, "network.bad_ports.allowed"))
	s.bad_ports_blocked = parse_port_list(config.string_of(p, "network.bad_ports.blocked"))
	s.files = file_settings_from_prefs(p)
	return s
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.accept_language)
	delete(s.bad_ports_allowed)
	delete(s.bad_ports_blocked)
	file_settings_destroy(&s.files)
	s^ = {}
}

@(private)
parse_port_list :: proc(text: string) -> []int {
	out := make([dynamic]int)
	for part in strings.split(text, ",", context.temp_allocator) {
		t := strings.trim_space(part)
		if t == "" { continue }
		if n, ok := strconv.parse_int(t, 10); ok && n >= 1 && n <= 65535 { append(&out, n) }
	}
	return out[:]
}

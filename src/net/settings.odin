package net

import "core:strings"
import "wb:config"

// Everything about the transport that a user or administrator may reasonably tune. The values live in the preference
// registry (about:config, `network.*`); the client works from a plain copy so the WinHTTP threads can read it without
// touching the registry. `settings_from_prefs` builds the copy, `client_apply` swaps it in at run time.

Proxy_Mode :: enum u8 { System, None }

Settings :: struct {
	max_per_host:  int,
	max_total:     int,
	timeout_resolve_ms, timeout_connect_ms, timeout_send_ms, timeout_receive_ms: i32,
	http2:         bool,
	http3:         bool,
	proxy:         Proxy_Mode,
	user_agent:    string,   // owned
	max_body:      int,      // default cap of one response; a request may ask for less or more
	read_chunk:    int,      // size of one read from WinHTTP
	high_water:    int,      // reading pauses when this many bytes wait for the consumer...
	low_water:     int,      // ...and resumes below this
}

PREFS := [?]config.Def{
	{name = "network.max_connections_per_host", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 256,
		description = "Requests in flight to one host:port. Extra requests wait in the browser's own priority queues, so waiting never counts against the connect timeout."},
	{name = "network.max_connections_total", kind = .Int, default = {i = 64}, bounded = true, min = 1, max = 4096,
		description = "Requests in flight in total."},
	{name = "network.timeout.resolve_ms", kind = .Int, default = {i = 15_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Name resolution timeout. 0 = no timeout."},
	{name = "network.timeout.connect_ms", kind = .Int, default = {i = 15_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "TCP/TLS connection timeout. 0 = no timeout."},
	{name = "network.timeout.send_ms", kind = .Int, default = {i = 30_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Timeout while sending a request. 0 = no timeout."},
	{name = "network.timeout.receive_ms", kind = .Int, default = {i = 60_000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Timeout waiting for response data. 0 = no timeout."},
	{name = "network.http2.enabled", kind = .Bool, default = {b = true}, restart = true, description = "Use HTTP/2 when the server offers it."},
	{name = "network.http3.enabled", kind = .Bool, default = {b = false}, restart = true, description = "Use HTTP/3 when the server and the OS support it. Off by default: for a site that announces HTTP/3 WinHTTP tries QUIC first and, where UDP does not get through (a firewall, a network), never falls back to TCP: the page stays on Connecting for ever (odin-lang.org)."},
	{name = "network.proxy.mode", kind = .String, default = {s = "system"}, choices = {"system", "none"}, restart = true,
		description = "system: the operating system's proxy settings (auto-detection included). none: connect directly."},
	{name = "network.user_agent", kind = .String, default = {s = ""}, restart = true,
		description = "The User-Agent header (and navigator.userAgent). Empty: Mozilla/5.0 (<platform>) Wren/<version>."},
	{name = "network.max_response_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Default largest response body; a request exceeding it fails. 0 = unlimited."},
	{name = "network.read_chunk_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 1024, max = 16 << 20, bytes = true, unit = "bytes",
		description = "Size of one read from the network stack."},
	{name = "network.queue.high_water_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 4096, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Back-pressure: reading a response pauses when this many bytes wait for its consumer."},
	{name = "network.queue.low_water_bytes", kind = .Int, default = {i = 256 << 10}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Back-pressure: reading resumes when the unconsumed bytes fall below this."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

// The product token of the default User-Agent ("Wren/0.3.0"): the browser sets it from its version before reading the
// preferences; tools keep this one.
user_agent_product := "Wren"

// The form sites expect (Mozilla/5.0, then the platform as browsers write it), without claiming an engine Wren is not:
// a "Chrome/" token would get pages features it lacks. Windows 11 still says "Windows NT 10.0", as every browser does.
user_agent_default :: proc(allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		platform :: "Windows NT 10.0; Win64; x64"
	} else when ODIN_OS == .Darwin {
		platform :: "Macintosh; Intel Mac OS X 10_15_7"
	} else {
		platform :: "X11; Linux x86_64"
	}
	return strings.concatenate({"Mozilla/5.0 (", platform, ") ", user_agent_product}, allocator)
}

settings_from_prefs :: proc(p: ^config.Prefs, allocator := context.allocator) -> Settings {
	s: Settings
	s.max_per_host = int(config.int_of(p, "network.max_connections_per_host"))
	s.max_total = int(config.int_of(p, "network.max_connections_total"))
	s.timeout_resolve_ms = i32(config.int_of(p, "network.timeout.resolve_ms"))
	s.timeout_connect_ms = i32(config.int_of(p, "network.timeout.connect_ms"))
	s.timeout_send_ms = i32(config.int_of(p, "network.timeout.send_ms"))
	s.timeout_receive_ms = i32(config.int_of(p, "network.timeout.receive_ms"))
	s.http2 = config.bool_of(p, "network.http2.enabled")
	s.http3 = config.bool_of(p, "network.http3.enabled")
	s.proxy = config.string_of(p, "network.proxy.mode") == "none" ? .None : .System
	ua := config.string_of(p, "network.user_agent")
	s.user_agent = ua != "" ? strings.clone(ua, allocator) : user_agent_default(allocator)
	s.max_body = int(config.int_of(p, "network.max_response_bytes"))
	if s.max_body == 0 { s.max_body = max(int) }
	s.read_chunk = int(config.int_of(p, "network.read_chunk_bytes"))
	s.high_water = int(config.int_of(p, "network.queue.high_water_bytes"))
	s.low_water = min(int(config.int_of(p, "network.queue.low_water_bytes")), s.high_water)
	return s
}

settings_default :: proc(allocator := context.allocator) -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p, allocator)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.user_agent)
	s^ = {}
}

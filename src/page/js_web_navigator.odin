package page

// navigator for JavaScript (api/js_web.widl, module navigator): the browser's identity as its requests show it (the
// User-Agent and Accept-Language headers come from the same preferences), the machine as far as the preferences let
// pages see it, and beacons.

import "core:strings"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:url"

@(private)
user_agent_of :: proc(p: ^Page) -> string {
	if p.loader != nil && p.loader.net != nil { return p.loader.net.settings.user_agent }
	return ""
}

Navigator_get :: proc(c: ^Call, field: Api_NavigatorField) -> string {
	p := c.page
	s := &p.settings.js_web
	switch field {
	case .User_Agent: return user_agent_of(p)
	case .App_Version:
		ua := user_agent_of(p)
		return strings.has_prefix(ua, "Mozilla/") ? ua[len("Mozilla/"):] : ua
	case .Platform: return s.platform
	case .Vendor: return s.vendor
	case .Languages:
		// "en-US,en;q=0.9" -> "en-US,en": the tags in order, without their weights
		al := p.loader != nil && p.loader.profile != nil ? p.loader.profile.settings.accept_language : ""
		b := strings.builder_make(context.temp_allocator)
		rest := al
		for part in strings.split_iterator(&rest, ",") {
			tag := strings.trim_space(part)
			if semi := strings.index_byte(tag, ';'); semi >= 0 { tag = strings.trim_space(tag[:semi]) }
			if tag == "" || tag == "*" { continue }
			if strings.builder_len(b) > 0 { strings.write_byte(&b, ',') }
			strings.write_string(&b, tag)
		}
		if strings.builder_len(b) == 0 { return "en-US" }
		return strings.to_string(b)
	case .Do_Not_Track: return s.do_not_track ? "1" : ""
	}
	return ""
}

Navigator_hardwareConcurrency :: proc(c: ^Call) -> i32 {
	n := c.page.settings.js_web.hardware_concurrency
	if n <= 0 {
		n = host.processor_count()   // the logical processors (what browsers report)
	}
	return i32(max(n, 1))
}

Navigator_maxTouchPoints :: proc(c: ^Call) -> i32 { return i32(max(c.page.settings.js.touch_points, 0)) }

Navigator_onLine :: proc(c: ^Call) -> bool { return network_alive() }

Navigator_cookieEnabled :: proc(c: ^Call) -> bool {
	_, ok := cookie_context(c.page)
	return ok
}

// A beacon outlives its page: it owns a copy of the page's environment (without the page's violation callback), freed
// once the request is over.
@(private)
Beacon :: struct {
	env: fetch.Environment,
}

@(private)
beacon_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if ev.kind != .Done && ev.kind != .Failed { return }
	b := (^Beacon)(user)
	fetch.environment_destroy(&b.env)
	free(b)
}

Beacon_send :: proc(c: ^Call, target: string, data: Maybe([]u8), content_type: string) -> bool {
	p := c.page
	body := data.? or_else nil
	if len(body) > p.settings.js_web.beacon_max_bytes || p.worker != nil { return false }
	u, ok := url.parse(target, &p.env.location, context.temp_allocator)
	if !ok || (u.scheme != "http" && u.scheme != "https") { return false }
	b := new(Beacon)
	b.env = fetch.environment_clone(p.env)
	b.env.on_violation = nil
	b.env.violation_user = nil
	pairs := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	if content_type != "" { append(&pairs, fetch.Header_Pair{"Content-Type", content_type}) }
	// Beacon: a no-cors POST with credentials, whose response nobody reads (the loader collects it)
	fetch.start(p.loader, {
		request = fetch.Request_Desc{
			url = u.href, method = "POST", headers = pairs[:], body = body,
			mode = .No_Cors, credentials = .Include, redirect = .Follow, destination = .Empty,
			initiator = &b.env, guard = .Request, ping = true,
		},
		on_event = beacon_event, user = b, scope = nil, collect = false,
	})
	return true
}

package csp

import "core:testing"
import "wb:url"

@(private = "file")
embeddable :: proc(policy: string, doc: string, ancestors: ..string) -> bool {
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, policy, .Enforce)
	o := make([dynamic]url.Origin, context.temp_allocator)
	for a in ancestors {
		u, _ := url.parse_absolute(a, context.temp_allocator)
		append(&o, url.origin_of(u, context.temp_allocator))
	}
	du, _ := url.parse_absolute(doc, context.temp_allocator)
	return check_frame_ancestors(&l, url.origin_of(du, context.temp_allocator), o[:]).allowed
}

@(test)
frame_ancestors :: proc(t: ^testing.T) {
	doc := "https://widget.example/frame"
	testing.expect(t, embeddable("default-src 'none'", doc, "https://evil.example/"), "default-src does not govern embedding")
	testing.expect(t, !embeddable("frame-ancestors 'none'", doc, "https://widget.example/"), "'none' refuses even the same origin")
	testing.expect(t, embeddable("frame-ancestors 'self'", doc, "https://widget.example/a"))
	testing.expect(t, !embeddable("frame-ancestors 'self'", doc, "https://widget.example/a", "https://evil.example/"), "every ancestor counts, the top level too")
	testing.expect(t, embeddable("frame-ancestors https://*.host.example", doc, "https://www.host.example/"))
	testing.expect(t, !embeddable("frame-ancestors https://*.host.example", doc, "http://www.host.example/"), "the scheme is part of the source")
	testing.expect(t, embeddable("frame-ancestors *", doc, "http://any.example/"))
	testing.expect(t, !embeddable("frame-ancestors *", doc, "data:text/html,x"), "an opaque ancestor matches nothing")
	testing.expect(t, embeddable("frame-ancestors 'self'; frame-ancestors 'none'", doc, "https://widget.example/"), "only the first occurrence counts")
	// report-only: allowed, with a violation
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, "frame-ancestors 'none'", .Report_Only)
	du, _ := url.parse_absolute(doc, context.temp_allocator)
	v := check_frame_ancestors(&l, url.origin_of(du, context.temp_allocator), {url.origin_of(du, context.temp_allocator)})
	testing.expect(t, v.allowed && len(v.violations) == 1)
}

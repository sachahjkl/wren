package url

import "core:testing"

// The value of group `name` of `which` once `p` matched `input`; "<none>" when it did not take part, "<no match>".
@(private = "file")
group :: proc(p: ^Url_Pattern, input: Pattern_Init, which: Pattern_Component, name: string) -> string {
	r, matched := pattern_match_init(p, input, context.temp_allocator)
	if !matched { return "<no match>" }
	for c in r.groups[which] { if c.name == name { return c.present ? c.value : "<none>" } }
	return "<no group>"
}

// URL Pattern Standard: a relative pathname resolved against the base URL's path, a port canonicalized with its
// protocol, a hostname that is not one refused; the regular expression is ECMAScript's (v flag): a segment wildcard is
// lazy, a repeated group captures every repetition, an optional group that matched nothing is undefined, classes take
// set operations.
@(test)
url_pattern :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator   // (the patterns and results go with the test)
	p, ok := pattern_create({pathname = "b", base_url = "https://example.com/foo/"}, false)
	testing.expect(t, ok)
	testing.expect_value(t, pattern_component_string(&p, .Pathname), "/foo/b")

	p, _ = pattern_create({protocol = "http", port = "80"}, false)
	testing.expect_value(t, pattern_component_string(&p, .Port), "")
	_, matched := pattern_match_init(&p, {protocol = "http", port = "80x"})
	testing.expect(t, matched, "\"80x\" is port 80, the default one of http")

	_, ok = pattern_create({hostname = "bad hostname"}, false)
	testing.expect(t, !ok, "a space in a hostname")
	p, _ = pattern_create({hostname = "example.com/ignored"}, false)
	testing.expect_value(t, pattern_component_string(&p, .Hostname), "example.com")

	p, _ = pattern_create({pathname = "{:foo}(.*)"}, false)
	testing.expect_value(t, group(&p, {pathname = "foobar"}, .Pathname, "foo"), "f")
	p, _ = pattern_create({pathname = "/foo/:bar+"}, false)
	testing.expect_value(t, group(&p, {pathname = "/foo/bar/baz"}, .Pathname, "bar"), "bar/baz")
	p, _ = pattern_create({pathname = "*{}**?"}, false)
	testing.expect_value(t, group(&p, {pathname = "foobar"}, .Pathname, "1"), "<none>")
	p, _ = pattern_create({pathname = "/([\\d&&[0-1]])"}, false)
	testing.expect_value(t, group(&p, {pathname = "/1"}, .Pathname, "0"), "1")
	testing.expect_value(t, group(&p, {pathname = "/3"}, .Pathname, "0"), "<no match>")
	_, ok = pattern_create({pathname = "/(\\m)"}, false)
	testing.expect(t, !ok, "an identity escape the v flag refuses")
}

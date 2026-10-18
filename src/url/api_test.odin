package url

import "core:testing"

@(private = "file")
after_set :: proc(start: string, c: Component, value: string) -> string {
	u, ok := parse(start, nil, context.temp_allocator)
	if !ok { return "<invalid start>" }
	r, res := set_component(u, c, value, context.temp_allocator)
	if res != .Ok { return "<refused>" }
	return r.href
}

@(private = "file")
get :: proc(s: string, c: Component) -> string {
	u, ok := parse(s, nil, context.temp_allocator)
	if !ok { return "<invalid>" }
	return component(u, c, context.temp_allocator)
}

@(test)
getters :: proc(t: ^testing.T) {
	s := "https://user:pw@example.com:8443/a/b?x=1#frag"
	testing.expect_value(t, get(s, .Protocol), "https:")
	testing.expect_value(t, get(s, .Username), "user")
	testing.expect_value(t, get(s, .Password), "pw")
	testing.expect_value(t, get(s, .Host), "example.com:8443")
	testing.expect_value(t, get(s, .Hostname), "example.com")
	testing.expect_value(t, get(s, .Port), "8443")
	testing.expect_value(t, get(s, .Pathname), "/a/b")
	testing.expect_value(t, get(s, .Search), "?x=1")
	testing.expect_value(t, get(s, .Hash), "#frag")
	testing.expect_value(t, get(s, .Origin), "https://example.com:8443")
	testing.expect_value(t, get("https://example.com/?#", .Search), "")
	testing.expect_value(t, get("https://example.com/?#", .Hash), "")
	testing.expect_value(t, get("http://[::1]:81/", .Hostname), "[::1]")
	testing.expect_value(t, get("mailto:a@b.c", .Pathname), "a@b.c")
	testing.expect_value(t, get("mailto:a@b.c", .Host), "")
	testing.expect_value(t, get("file:///C:/x.txt", .Origin), "null")
	testing.expect_value(t, get("blob:https://a.example/123", .Origin), "https://a.example")
}

// The setters follow the basic URL parser's state overrides.
@(test)
setters :: proc(t: ^testing.T) {
	base := "https://example.com/p?q#h"
	testing.expect_value(t, after_set(base, .Protocol, "http"), "http://example.com/p?q#h")
	testing.expect_value(t, after_set(base, .Protocol, "http:ignored"), "http://example.com/p?q#h")
	testing.expect_value(t, after_set(base, .Protocol, "foo"), base)                 // special to non-special: refused
	testing.expect_value(t, after_set("foo://x/", .Protocol, "https"), "foo://x/")   // and back
	testing.expect_value(t, after_set(base, .Username, "a b"), "https://a%20b@example.com/p?q#h")
	testing.expect_value(t, after_set(base, .Password, "s:e"), "https://:s%3Ae@example.com/p?q#h")
	testing.expect_value(t, after_set(base, .Host, "other.org:81"), "https://other.org:81/p?q#h")
	testing.expect_value(t, after_set(base, .Hostname, "other.org:81"), base)        // ':' invalidates the whole value
	testing.expect_value(t, after_set(base, .Hostname, "other.org"), "https://other.org/p?q#h")
	testing.expect_value(t, after_set(base, .Port, "8080"), "https://example.com:8080/p?q#h")
	testing.expect_value(t, after_set(base, .Port, "443"), base)                     // default port removed
	testing.expect_value(t, after_set(base, .Port, "99999"), base)                   // out of range: unchanged
	testing.expect_value(t, after_set(base, .Port, "12ab"), "https://example.com:12/p?q#h")
	testing.expect_value(t, after_set(base, .Pathname, "a/../b c"), "https://example.com/b%20c?q#h")
	testing.expect_value(t, after_set(base, .Search, "?x=1 2"), "https://example.com/p?x=1%202#h")
	testing.expect_value(t, after_set(base, .Search, ""), "https://example.com/p#h")
	testing.expect_value(t, after_set(base, .Hash, "top"), "https://example.com/p?q#top")
	testing.expect_value(t, after_set(base, .Hash, ""), "https://example.com/p?q")
	testing.expect_value(t, after_set(base, .Href, "http://new.example/"), "http://new.example/")
	testing.expect_value(t, after_set(base, .Href, "not a url"), "<refused>")
	testing.expect_value(t, after_set("mailto:a@b", .Host, "x.org"), "mailto:a@b")   // no host to set
	testing.expect_value(t, after_set("file:///C:/x", .Port, "8"), "file:///C:/x")    // file: has no port
}

@(test)
search_params :: proc(t: ^testing.T) {
	sp := params_make()
	defer params_destroy(&sp)
	params_parse(&sp, "a=1&b=x+y&&c=%41%zz&a=2&d&=e&%E2%82=f")
	testing.expect_value(t, len(sp.list), 7)
	v, ok := params_get(sp, "b")
	testing.expect(t, ok && v == "x y")
	v, _ = params_get(sp, "c")
	testing.expect_value(t, v, "A%zz")
	v, _ = params_get(sp, "d")
	testing.expect_value(t, v, "")
	testing.expect(t, params_has(sp, ""))
	testing.expect(t, params_has(sp, "\uFFFD"))   // truncated UTF-8 sequence: one replacement character
	testing.expect_value(t, params_count(sp, "a"), 2)
	v, _ = params_get_nth(sp, "a", 1)
	testing.expect_value(t, v, "2")

	params_set(&sp, "a", "3")
	testing.expect_value(t, params_count(sp, "a"), 1)
	testing.expect_value(t, params_delete(&sp, "b", "nope", true), 0)
	testing.expect_value(t, params_delete(&sp, "b"), 1)
	params_append(&sp, "z", "é &=+")
	s := params_serialize(sp, context.temp_allocator)
	testing.expect_value(t, s, "a=3&c=A%25zz&d=&=e&%EF%BF%BD=f&z=%C3%A9+%26%3D%2B")

	params_parse(&sp, "z=1&\uE000=2&\U00010000=3&a=4&z=0")
	params_sort(&sp)
	testing.expect_value(t, params_serialize(sp, context.temp_allocator), "a=4&z=1&z=0&%F0%90%80%80=3&%EE%80%80=2")
}

@(test)
utf16_order :: proc(t: ^testing.T) {
	testing.expect(t, utf16_less("a", "b"))
	testing.expect(t, utf16_less("a", "ab"))
	testing.expect(t, !utf16_less("ab", "a"))
	testing.expect(t, utf16_less("\U00010000", "\uE000"))
	testing.expect(t, !utf16_less("x", "x"))
}

@(test)
whatwg_utf8_decoder :: proc(t: ^testing.T) {
	testing.expect_value(t, utf8_decode([]byte{0xE2, 0x82, 'A'}, context.temp_allocator), "\uFFFDA")
	testing.expect_value(t, utf8_decode([]byte{0xC0, 0x80}, context.temp_allocator), "\uFFFD\uFFFD")
	testing.expect_value(t, utf8_decode([]byte{0xED, 0xA0, 0x80}, context.temp_allocator), "\uFFFD\uFFFD\uFFFD")
	testing.expect_value(t, utf8_decode([]byte{0xF0, 0x9F, 0x98, 0x80}, context.temp_allocator), "\U0001F600")
}

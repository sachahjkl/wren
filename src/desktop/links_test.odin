package desktop

import "core:strings"
import "core:testing"

@(private = "file") PREFIXES := []string{"wren-dev-", LINK_PREFIX}

@(private = "file")
expect_link :: proc(t: ^testing.T, link, want: string, want_err := Link_Error.None, loc := #caller_location) {
	got, err := link_address(link, LINK_PREFIX, context.temp_allocator)
	testing.expectf(t, got == want && err == want_err, "%q: %q %v, want %q %v", link[:min(len(link), 60)], got, err, want, want_err, loc = loc)
}

@(test)
links_give_http_https_and_about_wren_only :: proc(t: ^testing.T) {
	expect_link(t, "wren-https://a.b/c?d#e", "https://a.b/c?d#e")
	expect_link(t, "wren-http://127.0.0.1:8080/x", "http://127.0.0.1:8080/x")
	expect_link(t, "WREN-HTTPS://A.B/C", "https://a.b/C")   // (the parser's canonical form)
	expect_link(t, "wren-https://a.b/two words", "https://a.b/two%20words")
	expect_link(t, "wren-about:wren", "about:wren")
	expect_link(t, "wren-ABOUT:wren", "about:wren")

	expect_link(t, "wren-about:blank", "", .Scheme)
	expect_link(t, "wren-about:wren?x", "", .Scheme)
	expect_link(t, "wren-file:///c:/x", "", .Scheme)
	expect_link(t, "wren-javascript:alert(1)", "", .Scheme)
	expect_link(t, "wren-data:text/html,<script>alert(1)</script>", "", .Scheme)
	expect_link(t, "wren-blob:https://a.b/0c3f", "", .Scheme)
	expect_link(t, "wren-wren-https://a.b/", "", .Scheme)
	expect_link(t, "wren-https://", "", .Invalid)
	expect_link(t, "wren-https://a.b/\x01", "", .Control_Character)
	expect_link(t, "wren-https://a.b/\tx", "", .Control_Character)
	expect_link(t, "wren-https://a.b/\nx", "", .Control_Character)
	expect_link(t, "wren-https://a.b/\x7f", "", .Control_Character)
	long := strings.concatenate({"wren-https://a.b/", strings.repeat("x", 100 * 1024, context.temp_allocator)}, context.temp_allocator)
	expect_link(t, long, "", .Too_Long)
	expect_link(t, long[:LINK_MAX_BYTES], strings.concatenate({"https://a.b/", long[len("wren-https://a.b/"):LINK_MAX_BYTES]}, context.temp_allocator))

	expect_link(t, "https://a.b/", "", .Not_A_Link)
	expect_link(t, "wren-notes.html", "", .Not_A_Link)
	expect_link(t, "", "", .Not_A_Link)
	testing.expect(t, !is_link("wren-https://a.b/", ""), "no prefix, no links")
	testing.expect(t, is_link("  wren-file:x", LINK_PREFIX), "a link behind the spaces the URL parser strips")
}

@(test)
links_on_the_command_line :: proc(t: ^testing.T) {
	expect_args :: proc(t: ^testing.T, args: []string, want: string, want_err := Link_Error.None, loc := #caller_location) {
		out, err := links_in_args(args, PREFIXES)
		got := strings.join(out[:], " ", context.temp_allocator)
		testing.expectf(t, err == want_err && (err != .None || got == want), "%v: %q %v, want %q %v", args, got, err, want, want_err, loc = loc)
	}
	// what the registered schemes run, the flags of the caller before it
	expect_args(t, {"--open-url", "wren-https://a.b/c"}, "https://a.b/c")
	expect_args(t, {"--hidden", "--profile", "p", "--open-url", "wren-about:wren"}, "--hidden --profile p about:wren")
	expect_args(t, {"--open-url", "wren-dev-https://a.b/"}, "https://a.b/")
	// a link among the addresses (a desktop entry's %U), the others as they were
	expect_args(t, {"about:config", "wren-http://a.b/", "notes.html", "wren-notes.html"}, "about:config http://a.b/ notes.html wren-notes.html")
	expect_args(t, {}, "")

	// refused: the whole line
	expect_args(t, {"--open-url", "wren-file:///c:/x"}, "", .Scheme)
	expect_args(t, {"--open-url", "https://a.b/"}, "", .Not_A_Link)
	expect_args(t, {"--open-url", "C:\\x\\page.html"}, "", .Not_A_Link)
	expect_args(t, {"about:wren", "wren-javascript:alert(1)"}, "", .Scheme)
	// a quote in the link the system did not encode: the arguments it adds come after it
	expect_args(t, {"--open-url", "wren-https://a.b/", "--profile", "C:\\evil"}, "", .Misplaced)
	expect_args(t, {"--open-url", "wren-https://a.b/", "--open-url", "wren-about:wren"}, "", .Misplaced)
	expect_args(t, {"--open-url"}, "", .Misplaced)
}

@(test)
link_schemes_of_a_prefix :: proc(t: ^testing.T) {
	names := link_scheme_names(LINK_PREFIX)
	testing.expect_value(t, strings.join(names, " ", context.temp_allocator), "wren-http wren-https wren-about")
	testing.expect_value(t, len(link_scheme_names("")), 0)
}

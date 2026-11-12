package vault

import "core:testing"

@(private = "file")
site :: proc(t: ^testing.T, address: string) -> Site {
	s, ok := site_of(address)
	testing.expect(t, ok, address)
	return s
}

@(test)
domain_rows_need_the_same_registrable_domain :: proc(t: ^testing.T) {
	s := site(t, "https://login.example.co.uk/a")
	testing.expect_value(t, s.domain, "example.co.uk")
	testing.expect(t, row_matches(s, "https://example.co.uk", .Domain))
	testing.expect(t, row_matches(s, "www.example.co.uk", .Domain))   // (no scheme: https)
	testing.expect(t, !row_matches(s, "https://other.co.uk", .Domain))
	testing.expect(t, !row_matches(s, "https://co.uk", .Domain))
}

@(test)
a_public_suffix_of_its_own_separates_sites :: proc(t: ^testing.T) {
	// github.io is a public suffix: two pages under it are two sites
	s := site(t, "https://alice.github.io/login")
	testing.expect_value(t, s.domain, "alice.github.io")
	testing.expect(t, row_matches(s, "https://alice.github.io", .Domain))
	testing.expect(t, !row_matches(s, "https://mallory.github.io", .Domain))
	testing.expect(t, !row_matches(s, "https://github.io", .Domain))
}

@(test)
ip_hosts_and_localhost_use_the_host_rule :: proc(t: ^testing.T) {
	s := site(t, "http://127.0.0.1:8080/login")
	testing.expect_value(t, s.domain, "")
	testing.expect(t, !s.insecure)   // (loopback http is not asked about)
	testing.expect(t, row_matches(s, "http://127.0.0.1:8080", .Domain))
	testing.expect(t, !row_matches(s, "http://127.0.0.1:9090", .Domain))
	l := site(t, "http://localhost:3000/")
	testing.expect(t, row_matches(l, "http://localhost:3000/x", .Host))
	testing.expect(t, !row_matches(l, "http://localhost:3001/x", .Host))
}

@(test)
host_rows_need_the_same_host_and_port :: proc(t: ^testing.T) {
	s := site(t, "https://a.example.com/")
	testing.expect(t, row_matches(s, "https://a.example.com:443/path", .Host))
	testing.expect(t, !row_matches(s, "https://a.example.com:8443", .Host))
	testing.expect(t, !row_matches(s, "https://b.example.com", .Host))
}

@(test)
https_items_never_go_to_http_pages :: proc(t: ^testing.T) {
	s := site(t, "http://example.com/login")
	testing.expect(t, s.insecure)
	testing.expect(t, !row_matches(s, "https://example.com", .Domain))
	testing.expect(t, row_matches(s, "http://example.com", .Domain))
}

@(test)
what_is_not_a_web_page_is_never_filled :: proc(t: ^testing.T) {
	for a in ([]string{"file:///tmp/a.html", "about:blank", "data:text/html,x", "not a url"}) {
		_, ok := site_of(a)
		testing.expect(t, !ok, a)
	}
	s := site(t, "https://example.com/")
	testing.expect(t, !row_matches(s, "androidapp://com.example", .Domain))
	testing.expect(t, !row_matches(s, "", .Domain))
}

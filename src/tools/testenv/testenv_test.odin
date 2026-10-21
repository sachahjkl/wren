package testenv

import "core:testing"

@(test)
test_url_moves_default_ports :: proc(t: ^testing.T) {
	saved := cached
	defer cached = saved
	src := `http://127.0.0.1:8765/a ws://localhost:8767/ws https://[::1]:8766/ U+8766 :87650 x:8770 wpt:8769`
	cached = DEFAULT_BASE_PORT
	testing.expect_value(t, url(src), src)
	cached = 21230
	moved := url(src)
	testing.expect_value(t, moved, `http://127.0.0.1:21230/a ws://localhost:21232/ws https://[::1]:21231/ U+8766 :87650 x:8770 wpt:21234`)
	testing.expect(t, raw_data(url(src)) == raw_data(moved), "the same address is interned once")
	testing.expect_value(t, port(2), 21232)
	testing.expect_value(t, url(":8765"), ":8765")
}

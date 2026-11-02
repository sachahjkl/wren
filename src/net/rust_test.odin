package wren_net

import "core:testing"
import "wb:config"

@(test)
rust_abi_matches :: proc(t: ^testing.T) {
	sizes: [4]u64
	wn_net_abi(&sizes)
	testing.expect_value(t, sizes[0], u64(size_of(Wn_Config)))
	testing.expect_value(t, sizes[1], u64(size_of(Wn_Request)))
	testing.expect_value(t, sizes[2], u64(size_of(Wn_Event)))
	testing.expect_value(t, sizes[3], u64(size_of(Wn_Ws_Open)))
}

@(test)
backend_from_prefs :: proc(t: ^testing.T) {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	s := settings_from_prefs(&p)
	testing.expect_value(t, s.backend, Backend.Rust)
	testing.expect(t, s.http3, "HTTP/3 on by default (raced against TCP)")
	testing.expect_value(t, s.h3_race_ms, 250)
	testing.expect_value(t, s.extra_ca_file, "")
	settings_destroy(&s)
	testing.expect_value(t, config.set_from_string(&p, "network.backend", "winhttp", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.tls.extra_ca_file", "C:/ca.pem", .User), config.Set_Error.None)
	s = settings_from_prefs(&p)
	testing.expect_value(t, s.backend, Backend.Winhttp)
	testing.expect_value(t, s.extra_ca_file, "C:/ca.pem")
	settings_destroy(&s)
}

@(test)
network_hosts_and_this_machine :: proc(t: ^testing.T) {
	lines := hosts_lines("web-platform.test=127.0.0.1 not-web-platform.test=127.0.0.1,bad", context.temp_allocator)
	testing.expect_value(t, lines, "web-platform.test 127.0.0.1\nnot-web-platform.test 127.0.0.1\n")
	for h in ([]string{"localhost", "LocalHost.", "a.localhost", "127.0.0.1", "127.1.2.3", "[::1]"}) { testing.expectf(t, host_is_this_machine(h), "%s is this machine", h) }
	for h in ([]string{"example.com", "127.example.com", "128.0.0.1", "10.0.0.1", "localhost.example", "web-platform.test"}) { testing.expectf(t, !host_is_this_machine(h), "%s is not", h) }
}

package browser

import "core:strings"
import "core:testing"
import "wb:config"
import "wb:fetch"
import "wb:net"

// Every preference the browser ships must be well formed: this is what keeps about:config trustworthy.

@(test)
every_definition_is_valid :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	testing.expect(t, len(p.entries) > 40, "the registry lists the whole browser")
	seen := make(map[string]bool, context.temp_allocator)
	for e in p.entries {
		d := e.def
		testing.expect(t, d.name != "" && strings.to_lower(d.name, context.temp_allocator) == d.name, d.name)
		testing.expect(t, strings.contains(d.name, "."), d.name)
		testing.expect(t, d.description != "", d.name)
		testing.expect(t, !seen[d.name], d.name)
		seen[d.name] = true

		// the default must be accepted by the preference's own validation
		text := config.default_string(&p, config.ref_of(&p, d.name))
		_, err := config.parse_value(d, text)
		testing.expect_value(t, err, config.Set_Error.None, loc = {procedure = d.name})
		if len(d.choices) > 0 {
			found := false
			for c in d.choices { if c == d.default.s { found = true } }
			testing.expect(t, found, d.name)
		}
		if d.bounded { testing.expect(t, d.min <= d.max, d.name) }
	}
}

@(test)
settings_round_trip_through_the_registry :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)

	testing.expect_value(t, config.set_from_string(&p, "network.max_connections_per_host", "2", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "privacy.third_party_cookies", "allow", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.bad_ports.allowed", "22, 6000, x", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.queue.low_water_bytes", "2M", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.queue.high_water_bytes", "1M", .User), config.Set_Error.None)

	ns := net.settings_from_prefs(&p)
	defer net.settings_destroy(&ns)
	testing.expect_value(t, ns.max_per_host, 2)
	testing.expect_value(t, ns.low_water, 1 << 20)   // clamped: low water can never exceed high water

	fs := fetch.settings_from_prefs(&p)
	defer fetch.settings_destroy(&fs)
	testing.expect_value(t, fs.third_party_cookies, fetch.Third_Party_Cookies.Allow)
	testing.expect_value(t, len(fs.bad_ports_allowed), 2)   // the invalid entry is ignored

	bs := settings_from_prefs(&p)
	defer delete(bs.homepage)
	testing.expect_value(t, bs.homepage, "about:blank")
}

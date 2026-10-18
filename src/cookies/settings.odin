package cookies

import "wb:config"

// Cookie policy knobs (about:config, `cookies.*`). The storage model itself (what a cookie *is*, matching, SameSite
// semantics) is the specification's and is not configurable; limits, lifetimes and defaults are.

Settings :: struct {
	enabled:              bool,   // false: no cookie is stored or sent
	max_total:            int,
	max_per_site:         int,    // per registrable domain
	max_age_ms:           i64,    // longest lifetime a cookie may ask for
	max_name_value_bytes: int,    // name + value
	max_attribute_bytes:  int,    // each attribute value
	same_site_default:    Same_Site,   // what a cookie without SameSite means (.Lax or .None)
}

PREFS := [?]config.Def{
	{name = "cookies.enabled", kind = .Bool, default = {b = true}, description = "Store and send cookies at all."},
	{name = "cookies.max_total", kind = .Int, default = {i = 3000}, bounded = true, min = 1, max = 1_000_000,
		description = "Most cookies kept. The least recently used are evicted first."},
	{name = "cookies.max_per_site", kind = .Int, default = {i = 180}, bounded = true, min = 1, max = 100_000,
		description = "Most cookies kept for one registrable domain (eTLD+1)."},
	{name = "cookies.max_age_days", kind = .Int, default = {i = 400}, bounded = true, min = 1, max = 36_500, unit = "days",
		description = "A cookie asking to live longer is capped to this (400 days in the current standard)."},
	{name = "cookies.max_name_value_bytes", kind = .Int, default = {i = 4096}, bounded = true, min = 64, max = 1 << 20, unit = "bytes",
		description = "Largest cookie (name + value); a bigger one is ignored."},
	{name = "cookies.max_attribute_bytes", kind = .Int, default = {i = 1024}, bounded = true, min = 16, max = 1 << 20, unit = "bytes",
		description = "Largest value of a cookie attribute (Domain, Path...); longer ones are ignored."},
	{name = "cookies.same_site_default", kind = .String, default = {s = "lax"}, choices = {"lax", "none"},
		description = "SameSite behaviour of a cookie that does not say. lax is the modern default; none restores the old behaviour."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "cookies.enabled"),
		max_total = int(config.int_of(p, "cookies.max_total")),
		max_per_site = int(config.int_of(p, "cookies.max_per_site")),
		max_age_ms = config.int_of(p, "cookies.max_age_days") * 24 * 3600 * 1000,
		max_name_value_bytes = int(config.int_of(p, "cookies.max_name_value_bytes")),
		max_attribute_bytes = int(config.int_of(p, "cookies.max_attribute_bytes")),
		same_site_default = config.string_of(p, "cookies.same_site_default") == "none" ? .None : .Lax,
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

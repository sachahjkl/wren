#+build windows, linux, darwin
package ucd

// The Unicode data is generated and pinned at build time (see gen/ and tools/gen_unicode.ps1), so there is nothing
// to tune at run time about the tables themselves. This file exposes the pinned version as a read-only preference
// so about:config and the differential tooling can display which Unicode release the engine was built against,
// and registers it the same way every other package does. Freestanding builds skip it (no preference registry).

import "wb:config"

PREFS := [?]config.Def{
	{name = "unicode.version", kind = .String, default = {s = UNICODE_VERSION},
		description = "The Unicode release the character database tables were generated from (regexp \\p{}, case folding, normalization, scripts). Informational: the tables are compiled in, so editing this does not change behaviour; regenerate with tools/gen_unicode.ps1 to move to another release."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

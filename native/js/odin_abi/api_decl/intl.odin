// The one browser call of the engine's Intl (native/js/odin/intl.odin): everything else of Intl is computed in the
// engine, with the conventions of English (United States).
package api_decl

// The browser's IANA time zone ("Europe/Paris"; "UTC" when unknown).
Engine_timeZone :: #type proc() -> string

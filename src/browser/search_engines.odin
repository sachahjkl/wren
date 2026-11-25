package browser

// Browser bridge for the search engines store (src/profile/search_engines.odin).

import "wb:profile"

Search_Engine :: profile.Search_Engine
Search_Engines :: profile.Search_Engines
Builtin_Engine :: profile.Builtin_Engine
Engine_Error :: profile.Engine_Error

FALLBACK_ENGINE :: profile.FALLBACK_ENGINE
SEARCH_ENGINES_MAGIC :: profile.SEARCH_ENGINES_MAGIC
SEARCH_ENGINES_FILE :: profile.SEARCH_ENGINES_FILE

engines_clear :: profile.engines_clear
engines_destroy :: profile.engines_destroy
engines_builtin :: profile.engines_builtin
engines_restore_builtins :: profile.engines_restore_builtins
engines_missing_builtins :: profile.engines_missing_builtins
engines_find :: profile.engines_find
engines_keyword_owner :: profile.engines_keyword_owner
engines_default :: profile.engines_default
engine_at :: profile.engine_at
engine_url :: profile.engine_url
engine_initial :: profile.engine_initial
engines_keyword :: profile.engines_keyword
engine_error_text :: profile.engine_error_text
engine_validate :: profile.engine_validate
engines_add :: profile.engines_add
engines_update :: profile.engines_update
engines_remove :: profile.engines_remove
engines_move :: profile.engines_move
engines_serialize :: profile.engines_serialize
engines_parse :: profile.engines_parse
engines_migrate :: profile.engines_migrate
engines_load_file :: profile.engines_load_file

// Start-up (interaction_init): the profile's list, or the built-in engines and what a former profile chose.
search_engines_init :: proc(app: ^App) {
	profile.engines_init(&app.sengines, profile_store_host(app), &app.prefs, app.ix.search_engine)
}

search_engines_destroy :: proc(app: ^App) { profile.engines_destroy(&app.sengines) }

// After a change of the list: written to the profile; a default that is gone gives way to the first engine.
search_engines_changed :: proc(app: ^App) {
	profile.engines_changed(&app.sengines, profile_store_host(app), &app.prefs, app.ix.search_engine)
}

search_engines_save :: proc(app: ^App) {
	profile.engines_save(&app.sengines, profile_store_host(app))
}

search_set_default :: proc(app: ^App, i: int) {
	profile.engines_set_default(&app.sengines, &app.prefs, i)
}

// Index of the default engine of the browser's list.
search_default_index :: proc(app: ^App) -> int { return profile.engines_default(&app.sengines, app.ix.search_engine) }

// The address that searches `words`: with engine `engine` (an index of the list), or the default one (-1).
search_url :: proc(app: ^App, words: string, engine := -1) -> string {
	return profile.engines_search_url(&app.sengines, app.ix.search_engine, words, engine)
}

search_engine_name :: proc(app: ^App, engine := -1) -> string {
	return profile.engines_search_name(&app.sengines, app.ix.search_engine, engine)
}

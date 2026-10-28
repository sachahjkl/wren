// Package config: the typed preference registry now lives in the toolkit (toolkit:config), a cross-application concern.
// This is a thin alias so Wren's 129 callers keep writing `import "wb:config"` and `config.Prefs`, `config.register`,
// `config.get_bool`, etc. unchanged. See toolkit:config for the whole picture (the registry, the layers, the atomic
// save, the prefix observers; docs/config.md in the toolkit).
//
// The Wren-specific part — the `config.Def` tables each subsystem declares in its `settings.odin`, and the
// `register_all_prefs` that gathers them — stays in Wren: only the registry machinery is shared.
//
// The toolkit package is named `tk_config` (Odin package names are unique within a build, and Wren keeps its own
// `config` package here); it is imported with an alias and every public symbol is re-exported below by `::`.
package config

import tc "toolkit:config"

// Types
Kind :: tc.Kind
Value :: tc.Value
Def :: tc.Def
Source :: tc.Source
Entry :: tc.Entry
Ref :: tc.Ref
Observer :: tc.Observer
Prefs :: tc.Prefs
Set_Error :: tc.Set_Error
Pref_State :: tc.Pref_State

// Constants
NO_REF :: tc.NO_REF
USER_MAGIC :: tc.USER_MAGIC

// Lifecycle and registration
prefs_make :: tc.prefs_make
prefs_destroy :: tc.prefs_destroy
register :: tc.register
ref_of :: tc.ref_of
entry :: tc.entry
sorted_names :: tc.sorted_names

// Reads
get_bool :: tc.get_bool
get_int :: tc.get_int
get_float :: tc.get_float
get_string :: tc.get_string
bool_of :: tc.bool_of
int_of :: tc.int_of
float_of :: tc.float_of
string_of :: tc.string_of
is_default :: tc.is_default
value_string :: tc.value_string
default_string :: tc.default_string
user_text :: tc.user_text

// Writes
parse_value :: tc.parse_value
set_from_string :: tc.set_from_string
set_bool :: tc.set_bool
set_int :: tc.set_int
set_string :: tc.set_string
reset :: tc.reset
set_error_text :: tc.set_error_text

// Observers
watch :: tc.watch
unwatch :: tc.unwatch

// Layers: command line, profile file, policy file
apply_args :: tc.apply_args
save_user :: tc.save_user
load_file :: tc.load_file

// Snapshots (snapshot.odin)
snapshot :: tc.snapshot
snapshot_destroy :: tc.snapshot_destroy
restore :: tc.restore

// Titles and search (titles.odin)
title_of :: tc.title_of
category_title :: tc.category_title
summary_of :: tc.summary_of
matches :: tc.matches

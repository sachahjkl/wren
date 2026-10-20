package config

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
DEFS := [?]Def{
	{name = "net.max_conns", description = "Connections per host", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 64},
	{name = "net.max_body", description = "Largest response", kind = .Int, default = {i = 256 << 20}, bytes = true, unit = "bytes", bounded = true, min = 0, max = 1 << 40},
	{name = "net.enabled", description = "Network on", kind = .Bool, default = {b = true}},
	{name = "net.agent", description = "UA", kind = .String, default = {s = "wb/1"}},
	{name = "ui.scale", description = "Scale", kind = .Float, default = {f = 1.0}, bounded = true, min = 0.5, max = 3},
	{name = "ui.mode", description = "Mode", kind = .String, default = {s = "auto"}, choices = {"auto", "dark", "light"}, restart = true},
}

@(private = "file")
Seen :: struct { names: [dynamic]string, calls: int }

@(private = "file")
observer :: proc(user: rawptr, name: string, p: ^Prefs) {
	s := (^Seen)(user)
	s.calls += 1
	append(&s.names, name)
}

@(test)
defaults_and_typed_reads :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 6)
	testing.expect_value(t, bool_of(&p, "net.enabled"), true)
	testing.expect_value(t, string_of(&p, "net.agent"), "wb/1")
	testing.expect_value(t, float_of(&p, "ui.scale"), 1.0)
	testing.expect_value(t, entry(&p, ref_of(&p, "net.max_conns")).def.category, "net")
	testing.expect(t, ref_of(&p, "nope") == NO_REF)
	register(&p, DEFS[:])   // idempotent
	testing.expect_value(t, len(p.entries), 6)
}

@(test)
validation :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "12", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 12)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "0", .User), Set_Error.Out_Of_Range)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "65", .User), Set_Error.Out_Of_Range)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "abc", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "1_0", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 10)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 10, )
	testing.expect_value(t, set_from_string(&p, "net.max_body", "64M", .User), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_body"), 64 << 20)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "4K", .User), Set_Error.Bad_Type)   // suffixes only for byte prefs
	testing.expect_value(t, set_from_string(&p, "net.enabled", "off", .User), Set_Error.None)
	testing.expect_value(t, bool_of(&p, "net.enabled"), false)
	testing.expect_value(t, set_from_string(&p, "net.enabled", "maybe", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "2.5", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "9", .User), Set_Error.Out_Of_Range)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "nan", .User), Set_Error.Bad_Type)
	testing.expect_value(t, set_from_string(&p, "ui.mode", "dark", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "ui.mode", "neon", .User), Set_Error.Not_A_Choice)
	testing.expect_value(t, set_from_string(&p, "net.agent", "  spaced  ", .User), Set_Error.None)
	testing.expect_value(t, string_of(&p, "net.agent"), "  spaced  ")
	testing.expect_value(t, set_from_string(&p, "no.such", "1", .User), Set_Error.Unknown)
}

@(test)
layers_and_locks :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	set_from_string(&p, "net.max_conns", "8", .User)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "16", .Command_Line), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 16)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "3", .User), Set_Error.Locked)   // the command line wins this run
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "20", .Policy), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "5", .Command_Line), Set_Error.Locked)
	testing.expect_value(t, reset(&p, "net.max_conns"), Set_Error.Locked)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 20)

	// reset returns a user value to its default
	set_from_string(&p, "net.agent", "mine", .User)
	testing.expect(t, !is_default(&p, ref_of(&p, "net.agent")))
	testing.expect_value(t, reset(&p, "net.agent"), Set_Error.None)
	testing.expect_value(t, string_of(&p, "net.agent"), "wb/1")
	testing.expect(t, is_default(&p, ref_of(&p, "net.agent")))
}

@(test)
observers_by_prefix :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	s: Seen
	defer delete(s.names)
	id := watch(&p, "net.", observer, &s)
	set_from_string(&p, "net.max_conns", "7", .User)
	set_from_string(&p, "ui.scale", "2", .User)             // other prefix: not observed
	set_from_string(&p, "net.max_conns", "7", .User)         // same value: no notification
	set_from_string(&p, "net.agent", "x", .User)
	testing.expect_value(t, s.calls, 2)
	testing.expect_value(t, s.names[0], "net.max_conns")
	unwatch(&p, id)
	set_from_string(&p, "net.agent", "y", .User)
	testing.expect_value(t, s.calls, 2)
}

@(test)
command_line :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	args := []string{"https://example.com", "--pref", "net.max_conns=32", "--pref=net.agent=cli/9", "--other", "--pref", "bad", "--pref", "net.max_conns=999"}
	register(&p, DEFS[:])
	rest, errors := apply_args(&p, args)
	defer delete(rest)
	defer delete(errors)
	for e in errors { delete(e) }
	testing.expect_value(t, int_of(&p, "net.max_conns"), 32)   // the out-of-range second value was refused
	testing.expect_value(t, string_of(&p, "net.agent"), "cli/9")
	testing.expect_value(t, len(rest), 2)                       // the shell's own arguments are returned
	testing.expect_value(t, len(errors), 2)                     // "bad" and the out-of-range value
}

@(test)
values_set_before_registration_apply_later :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	// profile file and command line are read before the subsystems register their definitions
	set_from_string(&p, "net.max_conns", "9", .User)
	set_from_string(&p, "net.max_conns", "30", .Command_Line)
	set_from_string(&p, "net.agent", "pre", .User)
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 30)   // the higher layer wins
	testing.expect_value(t, string_of(&p, "net.agent"), "pre")
	testing.expect_value(t, entry(&p, ref_of(&p, "net.agent")).source, Source.User)
}

@(test)
persistence :: proc(t: ^testing.T) {
	path := "build/prefs_test.txt"
	defer os.remove(path)
	{
		p := prefs_make()
		defer prefs_destroy(&p)
		register(&p, DEFS[:])
		set_from_string(&p, "net.max_conns", "11", .User)
		set_from_string(&p, "net.agent", "tab\tand\nnewline\\", .User)
		set_from_string(&p, "ui.scale", "2", .Command_Line)        // not persisted
		set_from_string(&p, "future.pref", "kept", .User)           // unknown now: must survive a round trip
		testing.expect(t, save_user(&p, path))
	}
	p := prefs_make()
	defer prefs_destroy(&p)
	n, problems := load_file(&p, path, .User)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, n, 3)
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 11)
	testing.expect_value(t, string_of(&p, "net.agent"), "tab\tand\nnewline\\")
	testing.expect_value(t, float_of(&p, "ui.scale"), 1.0)
	// only user changes are written
	testing.expect(t, save_user(&p, path))
	q := prefs_make()
	defer prefs_destroy(&q)
	load_file(&q, path, .User)
	register(&q, DEFS[:])
	testing.expect_value(t, int_of(&q, "net.max_conns"), 11)

	_, probs := load_file(&q, "build/does_not_exist.txt", .User)
	testing.expect_value(t, len(probs), 0)   // a missing file is not an error
}

@(test)
policy_file_locks :: proc(t: ^testing.T) {
	path := "build/policy_test.txt"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("wbpolicy 1\nnet.max_conns\t3\n# comment\nui.mode\tbogus\n") ) == nil)
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, DEFS[:])
	n, problems := load_file(&p, path, .Policy)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(problems), 1)   // "bogus" is not a choice
	testing.expect_value(t, int_of(&p, "net.max_conns"), 3)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "5", .User), Set_Error.Locked)
	testing.expect(t, entry(&p, ref_of(&p, "net.max_conns")).locked)
}

// A run with --pref (or under a policy) keeps the user's own value in the profile file; a user change made meanwhile
// is kept too; reset leaves the command line's value for this run.
@(test)
higher_layers_keep_the_user_value :: proc(t: ^testing.T) {
	dir := os.get_env("TEMP", context.temp_allocator)
	path := fmt.tprintf("%s\\wb_config_layers_test.txt", dir)
	defer os.remove(path)
	_ = os.write_entire_file(path, transmute([]byte)string("\xEF\xBB\xBFwbprefs 1\nnet.max_conns\t5\nui.scale\t2\n"))
	p := prefs_make()
	defer prefs_destroy(&p)
	args := []string{"--pref", "net.max_conns=7"}
	rest, errs := apply_args(&p, args)
	delete(rest); delete(errs)
	applied, _ := load_file(&p, path, .User)
	testing.expect_value(t, applied, 2)   // the byte-order mark is not part of the magic
	register(&p, DEFS[:])
	testing.expect_value(t, int_of(&p, "net.max_conns"), 7)
	testing.expect(t, save_user(&p, path))
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, DEFS[:])
	load_file(&q, path, .User)
	testing.expect_value(t, int_of(&q, "net.max_conns"), 5)
	testing.expect_value(t, float_of(&q, "ui.scale"), 2.0)
	// a change by the user while the command line decides: refused for this run, kept for the next
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "9", .User), Set_Error.Locked)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 7)
	testing.expect(t, save_user(&p, path))
	r := prefs_make()
	defer prefs_destroy(&r)
	register(&r, DEFS[:])
	load_file(&r, path, .User)
	testing.expect_value(t, int_of(&r, "net.max_conns"), 9)
	// reset: the user value goes, the command line's stays
	testing.expect_value(t, reset(&p, "net.max_conns"), Set_Error.None)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 7)
	testing.expect(t, save_user(&p, path))
	s := prefs_make()
	defer prefs_destroy(&s)
	register(&s, DEFS[:])
	load_file(&s, path, .User)
	testing.expect_value(t, int_of(&s, "net.max_conns"), 6)
	// K / M / G that overflow are out of range, not wrapped
	_, e := parse_value(DEFS[1], "17179869185G")
	testing.expect_value(t, e, Set_Error.Out_Of_Range)
}
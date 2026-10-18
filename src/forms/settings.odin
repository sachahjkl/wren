package forms

import "core:strings"
import "wb:config"

// Everything about form controls a user or an administrator may want to change (about:config, `forms.*`).

Language :: enum u8 { English, French }

Settings :: struct {
	max_value_bytes:      int,      // longest value a control holds (typing, pasting and scripts are all cut there)
	undo_depth:           int,      // undo steps kept per control
	undo_merge_ms:        f64,      // consecutive typing within this delay is one undo step
	caret_blink_ms:       int,      // 0 = the system setting
	double_click_ms:      int,      // 0 = the system setting
	upload_max_file:      int,      // bytes, per file
	upload_max_total:     int,      // bytes, all files of one submission
	upload_max_files:     int,
	pattern_max_program:  int,      // instructions of one compiled `pattern`
	pattern_max_steps:    int,      // work allowed to test one value against a pattern
	language:             Language, // of validation messages
	report_ms:            int,      // how long a validation message stays on screen
	select_rows:          int,      // rows of an open <select> list before it scrolls
	autofocus:            bool,
	password_mask:        string,   // owned
	max_entries:          int,      // entries of one form data set
}

PREFS := [?]config.Def{
	{name = "forms.value.max_bytes", kind = .Int, default = {i = 4 << 20}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Longest value one form control can hold. Typing, pasting and scripts are all cut at this size."},
	{name = "forms.undo.depth", kind = .Int, default = {i = 100}, bounded = true, min = 0, max = 100_000,
		description = "Undo steps kept per text field. 0 disables undo."},
	{name = "forms.undo.merge_ms", kind = .Int, default = {i = 1000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Typing that follows within this delay joins the previous undo step instead of starting a new one."},
	{name = "forms.caret.blink_ms", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "Half period of the blinking text caret. 0 follows the Windows setting; a negative system value (no blinking) is honoured."},
	{name = "forms.click.double_ms", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 5000, unit = "ms",
		description = "Longest delay between the clicks of a double click (word selection) in a text field. 0 follows the Windows setting."},
	{name = "forms.upload.max_file_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Largest file a form may upload. A submission with a bigger file is refused (the console says why)."},
	{name = "forms.upload.max_total_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 0, max = 1 << 42, bytes = true, unit = "bytes",
		description = "Most bytes of files one form submission may carry."},
	{name = "forms.upload.max_files", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 1_000_000,
		description = "Most files one file input may hold."},
	{name = "forms.pattern.max_program", kind = .Int, default = {i = 20_000}, bounded = true, min = 64, max = 10_000_000,
		description = "Size limit of a compiled `pattern` attribute (counted repetitions are expanded). A bigger pattern is ignored, as an invalid one is."},
	{name = "forms.pattern.max_steps", kind = .Int, default = {i = 50_000_000}, bounded = true, min = 1000, max = 1 << 40,
		description = "Work allowed to test one value against a `pattern`. Matching is linear in the value; this bounds huge values. Past it the value is not reported as mismatching."},
	{name = "forms.validation.language", kind = .String, default = {s = "en"}, choices = {"en", "fr"},
		description = "Language of the messages that explain why a field is invalid (validationMessage and the bubble shown on submit)."},
	{name = "forms.validation.report_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 0, max = 600_000, unit = "ms",
		description = "How long the bubble that explains an invalid field stays on screen. 0 hides it (the field is still focused)."},
	{name = "forms.select.visible_rows", kind = .Int, default = {i = 20}, bounded = true, min = 3, max = 200,
		description = "Rows an open drop-down list shows before it scrolls."},
	{name = "forms.autofocus.enabled", kind = .Bool, default = {b = true},
		description = "Honour the autofocus attribute: the first such field of a page gets the keyboard focus when the page loads."},
	{name = "forms.password.mask", kind = .String, default = {s = "\u2022"},
		description = "Character drawn in place of each character of a password field."},
	{name = "forms.submit.max_entries", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 16, max = 1 << 30,
		description = "Most name/value entries one form submission or FormData may hold."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.max_value_bytes = int(config.int_of(p, "forms.value.max_bytes"))
	s.undo_depth = int(config.int_of(p, "forms.undo.depth"))
	s.undo_merge_ms = f64(config.int_of(p, "forms.undo.merge_ms"))
	s.caret_blink_ms = int(config.int_of(p, "forms.caret.blink_ms"))
	s.double_click_ms = int(config.int_of(p, "forms.click.double_ms"))
	s.upload_max_file = int(config.int_of(p, "forms.upload.max_file_bytes"))
	s.upload_max_total = int(config.int_of(p, "forms.upload.max_total_bytes"))
	s.upload_max_files = int(config.int_of(p, "forms.upload.max_files"))
	s.pattern_max_program = int(config.int_of(p, "forms.pattern.max_program"))
	s.pattern_max_steps = int(config.int_of(p, "forms.pattern.max_steps"))
	s.language = config.string_of(p, "forms.validation.language") == "fr" ? .French : .English
	s.report_ms = int(config.int_of(p, "forms.validation.report_ms"))
	s.select_rows = int(config.int_of(p, "forms.select.visible_rows"))
	s.autofocus = config.bool_of(p, "forms.autofocus.enabled")
	s.password_mask = strings.clone(config.string_of(p, "forms.password.mask"))
	if s.password_mask == "" { delete(s.password_mask); s.password_mask = strings.clone("\u2022") }
	s.max_entries = int(config.int_of(p, "forms.submit.max_entries"))
	return s
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.password_mask)
	s^ = {}
}

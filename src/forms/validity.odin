package forms

import "core:fmt"
import "core:math"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:url"

// Constraint validation (§4.10.20): ValidityState, validation messages, checkValidity / reportValidity, and the range
// and step rules (§4.10.5.3.7-8) the number-like types share.

Validity_Flag :: enum u8 {
	Value_Missing, Type_Mismatch, Pattern_Mismatch, Too_Long, Too_Short,
	Range_Underflow, Range_Overflow, Step_Mismatch, Bad_Input, Custom_Error,
}
Validity :: bit_set[Validity_Flag; u32]

Limits :: struct {
	min, max:         f64,
	has_min, has_max: bool,
}

@(private)
attr_number :: proc(n: ^dom.Node, t: Input_Type, name: string) -> (f64, bool) {
	v, ok := attr(n, name)
	if !ok { return 0, false }
	if t == .Number || t == .Range { return parse_float_lenient(v) }
	return number_from_string(t, v)
}

limits :: proc(f: ^Forms, n: ^dom.Node, t: Input_Type) -> Limits {
	l: Limits
	if t not_in MINMAX_APPLIES { return l }
	l.min, l.has_min = attr_number(n, t, "min")
	l.max, l.has_max = attr_number(n, t, "max")
	if t == .Range {
		if !l.has_min { l.min, l.has_min = 0, true }
		if !l.has_max { l.max, l.has_max = 100, true }
		if l.max < l.min { l.max = l.min }
	}
	return l
}

@(private)
range_default :: proc(l: Limits) -> f64 {
	if l.max < l.min { return l.min }
	return l.min + (l.max - l.min) / 2
}

// The allowed value step (already multiplied by the step scale factor); has = false for step="any" or types without steps.
allowed_step :: proc(f: ^Forms, n: ^dom.Node, t: Input_Type) -> (step: f64, has: bool) {
	if t not_in MINMAX_APPLIES { return 0, false }
	info := step_info(t)
	s := info.default_step
	if v, ok := attr(n, "step"); ok {
		if strings.equal_fold(trim_ascii_ws(v), "any") { return 0, false }
		if x, good := parse_float_lenient(v); good && x > 0 {
			s = x
			if t == .Date || t == .Month || t == .Week { s = max(math.round(s), 1) }
		}
	}
	return s * info.scale, true
}

step_base :: proc(f: ^Forms, n: ^dom.Node, t: Input_Type) -> f64 {
	if v, ok := attr_number(n, t, "min"); ok { return v }
	if dv, ok := attr(n, "value"); ok {
		if v, good := number_from_string(t, dv); good { return v }
	}
	return step_info(t).default_base
}

@(private)
is_integral :: proc(x: f64) -> bool {
	return abs(x - math.round(x)) <= 1e-9 * max(1, abs(x))
}

@(private)
round_half_up :: proc(x: f64) -> f64 { return math.floor(x + 0.5) }

@(private)
clear_patterns :: proc(f: ^Forms) {
	for k, re in f.patterns { delete(k); regex_destroy(re) }
	clear(&f.patterns)
}

@(private)
compiled_pattern :: proc(f: ^Forms, src: string) -> ^Regex {
	if re, ok := f.patterns[src]; ok { return re }
	if len(f.patterns) >= 256 { clear_patterns(f) }
	re := regex_compile(src, f.settings.pattern_max_program)
	f.patterns[strings.clone(src)] = re
	return re
}

// Does `v` satisfy the pattern? True when the pattern is invalid, unsupported or too costly to evaluate.
@(private)
pattern_ok :: proc(f: ^Forms, pattern, v: string) -> bool {
	re := compiled_pattern(f, pattern)
	if re == nil { return true }
	m, ok := regex_full_match(re, v, f.settings.pattern_max_steps)
	return !ok || m
}

@(private)
is_placeholder_label_option :: proc(f: ^Forms, sel, o: base.Handle) -> bool {
	if has_attr(element(f, sel), "multiple") || display_size(f, sel) != 1 { return false }
	opts := select_options(f, sel)
	if len(opts) == 0 || opts[0] != o { return false }
	return parent_element(f, o) == sel && option_value(f, o) == ""
}

validity :: proc(f: ^Forms, h: base.Handle) -> Validity {
	n := element(f, h)
	v: Validity
	k := kind_of(n)
	c := control_peek(f, h)
	if c != nil && c.custom_error != "" { v += {.Custom_Error} }
	#partial switch k {
	case .Input:
		t := input_type_of(n)
		required := has_attr(n, "required") && t in REQUIRED_APPLIES
		val := value(f, h)
		mutable := is_mutable(f, h)
		#partial switch t {
		case .Checkbox:
			if required && !checked(f, h) { v += {.Value_Missing} }
		case .Radio:
			group := radio_group(f, h)
			if len(group) == 0 {
				if required && !checked(f, h) { v += {.Value_Missing} }
			} else {
				any_required, any_checked := false, false
				for g in group {
					if has_attr(element(f, g), "required") { any_required = true }
					if checked(f, g) { any_checked = true }
				}
				if any_required && !any_checked { v += {.Value_Missing} }
			}
		case .File:
			if required && len(files(f, h)) == 0 { v += {.Value_Missing} }
		case:
			if required && mutable && val == "" && !bad_input(f, h) { v += {.Value_Missing} }
		}
		if val != "" {
			multiple := t == .Email && has_attr(n, "multiple")
			if t == .Email {
				if multiple {
					rest := val
					for part in strings.split_iterator(&rest, ",") { if !is_valid_email(part) { v += {.Type_Mismatch}; break } }
				} else if !is_valid_email(val) { v += {.Type_Mismatch} }
			}
			if t == .Url {
				if _, ok := url.parse_absolute(val, context.temp_allocator); !ok { v += {.Type_Mismatch} }
			}
			if t in PATTERN_APPLIES {
				if pat, ok := attr(n, "pattern"); ok {
					if multiple {
						rest := val
						for part in strings.split_iterator(&rest, ",") { if !pattern_ok(f, pat, part) { v += {.Pattern_Mismatch}; break } }
					} else if !pattern_ok(f, pat, val) { v += {.Pattern_Mismatch} }
				}
			}
			if t in MINMAX_APPLIES {
				if x, ok := number_from_string(t, val); ok {
					lim := limits(f, n, t)
					if t == .Time && lim.has_min && lim.has_max && lim.max < lim.min {
						// reversed range (crossing midnight): out of range when between max and min
						if x > lim.max && x < lim.min { v += {.Range_Underflow, .Range_Overflow} }
					} else {
						if lim.has_min && x < lim.min { v += {.Range_Underflow} }
						if lim.has_max && x > lim.max { v += {.Range_Overflow} }
					}
					if st, has := allowed_step(f, n, t); has {
						if !is_integral((x - step_base(f, n, t)) / st) { v += {.Step_Mismatch} }
					}
				}
			}
		}
		if t in LENGTH_APPLIES { v += length_flags(f, h, n, c, val) }
		if bad_input(f, h) { v += {.Bad_Input} }
	case .Textarea:
		val := value(f, h)
		if has_attr(n, "required") && is_mutable(f, h) && val == "" { v += {.Value_Missing} }
		v += length_flags(f, h, n, c, val)
	case .Select:
		if has_attr(n, "required") {
			sel_count := 0
			only: base.Handle
			for o in select_options_synced(f, h) { if control_of(f, o).selected { sel_count += 1; only = o } }
			if sel_count == 0 || (sel_count == 1 && is_placeholder_label_option(f, h, only)) { v += {.Value_Missing} }
		}
	}
	return v
}

@(private)
parse_length_attr :: proc(n: ^dom.Node, name: string) -> (int, bool) {
	s, ok := attr(n, name)
	if !ok { return 0, false }
	t := trim_ascii_ws(s)
	if len(t) == 0 { return 0, false }
	x := 0
	for ch in transmute([]u8)t {
		if !is_digit(ch) { return 0, false }
		x = min(x * 10 + int(ch - '0'), 1 << 30)
	}
	return x, true
}

// maxlength (non-negative integer, else none).
max_length :: proc(f: ^Forms, h: base.Handle) -> int {
	if v, ok := parse_length_attr(element(f, h), "maxlength"); ok { return v }
	return -1
}

min_length :: proc(f: ^Forms, h: base.Handle) -> int {
	if v, ok := parse_length_attr(element(f, h), "minlength"); ok { return v }
	return -1
}

@(private)
length_flags :: proc(f: ^Forms, h: base.Handle, n: ^dom.Node, c: ^Control, val: string) -> Validity {
	v: Validity
	if c == nil || !c.dirty_value || !c.user_edited { return v }
	l := utf16_len(val)
	if mx := max_length(f, h); mx >= 0 && l > mx { v += {.Too_Long} }
	if mn := min_length(f, h); mn >= 0 && l > 0 && l < mn { v += {.Too_Short} }
	return v
}

is_valid :: proc(f: ^Forms, h: base.Handle) -> bool { return validity(f, h) == {} }

// Is the element a candidate for constraint validation that does not satisfy its constraints?
@(private)
is_invalid_candidate :: proc(f: ^Forms, h: base.Handle) -> bool { return will_validate(f, h) && !is_valid(f, h) }

set_custom_validity :: proc(f: ^Forms, h: base.Handle, message: string) {
	c := control_of(f, h)
	if c == nil { return }
	replace_owned(&c.custom_error, message)
	changed(f, h)
}

////////////////////////////////
// Messages

validation_message :: proc(f: ^Forms, h: base.Handle, allocator := context.temp_allocator) -> string {
	if !will_validate(f, h) { return "" }
	v := validity(f, h)
	if v == {} { return "" }
	n := element(f, h)
	fr := f.settings.language == .French
	c := control_peek(f, h)
	if .Custom_Error in v { return strings.clone(c.custom_error, allocator) }
	t := input_type_of(n)
	k := kind_of(n)
	if .Value_Missing in v {
		switch {
		case k == .Input && t == .Checkbox: return fr ? "Veuillez cocher cette case pour continuer." : "Please check this box if you want to proceed."
		case k == .Input && t == .Radio: return fr ? "Veuillez sélectionner l'une de ces options." : "Please select one of these options."
		case k == .Input && t == .File: return fr ? "Veuillez sélectionner un fichier." : "Please select a file."
		case k == .Select: return fr ? "Veuillez sélectionner un élément dans la liste." : "Please select an item in the list."
		}
		return fr ? "Veuillez renseigner ce champ." : "Please fill out this field."
	}
	if .Bad_Input in v {
		#partial switch t {
		case .Number: return fr ? "Veuillez saisir un nombre." : "Please enter a number."
		case .Date: return fr ? "Veuillez saisir une date valide (AAAA-MM-JJ)." : "Please enter a valid date (YYYY-MM-DD)."
		case .Month: return fr ? "Veuillez saisir un mois valide (AAAA-MM)." : "Please enter a valid month (YYYY-MM)."
		case .Week: return fr ? "Veuillez saisir une semaine valide (AAAA-Wss)." : "Please enter a valid week (YYYY-Www)."
		case .Time: return fr ? "Veuillez saisir une heure valide (HH:MM)." : "Please enter a valid time (HH:MM)."
		case .Datetime_Local: return fr ? "Veuillez saisir une date et une heure valides (AAAA-MM-JJTHH:MM)." : "Please enter a valid date and time (YYYY-MM-DDTHH:MM)."
		case .Color: return fr ? "Veuillez saisir une couleur (#rrvvbb)." : "Please enter a color (#rrggbb)."
		}
		return fr ? "Veuillez saisir une valeur valide." : "Please enter a valid value."
	}
	if .Type_Mismatch in v {
		if t == .Email {
			if has_attr(n, "multiple") { return fr ? "Veuillez saisir une liste d'adresses e-mail séparées par des virgules." : "Please enter a comma-separated list of email addresses." }
			val := value(f, h)
			if strings.index_byte(val, '@') < 0 {
				return fr ? fmt.aprintf("Veuillez inclure « @ » dans l'adresse e-mail. Il manque un « @ » dans « %s ».", val, allocator = allocator) : fmt.aprintf("Please include an '@' in the email address. '%s' is missing an '@'.", val, allocator = allocator)
			}
			return fr ? "Veuillez saisir une adresse e-mail valide." : "Please enter an email address."
		}
		return fr ? "Veuillez saisir une URL." : "Please enter a URL."
	}
	if .Pattern_Mismatch in v {
		if title, ok := attr(n, "title"); ok && title != "" {
			return fr ? fmt.aprintf("Veuillez respecter le format requis : %s", title, allocator = allocator) : fmt.aprintf("Please match the requested format: %s", title, allocator = allocator)
		}
		return fr ? "Veuillez respecter le format requis." : "Please match the requested format."
	}
	val := value(f, h)
	if .Too_Long in v {
		mx := max_length(f, h)
		return fr ? fmt.aprintf("Veuillez raccourcir ce texte à %d caractères maximum (actuellement %d).", mx, utf16_len(val), allocator = allocator) : fmt.aprintf("Please shorten this text to %d characters or less (you are currently using %d characters).", mx, utf16_len(val), allocator = allocator)
	}
	if .Too_Short in v {
		mn := min_length(f, h)
		return fr ? fmt.aprintf("Veuillez allonger ce texte à %d caractères minimum (actuellement %d).", mn, utf16_len(val), allocator = allocator) : fmt.aprintf("Please lengthen this text to %d characters or more (you are currently using %d characters).", mn, utf16_len(val), allocator = allocator)
	}
	lim := limits(f, n, t)
	if .Range_Underflow in v && .Range_Overflow in v {
		lo, _ := string_from_number(t, lim.min)
		hi, _ := string_from_number(t, lim.max)
		return fr ? fmt.aprintf("La valeur doit être comprise entre %s et %s.", lo, hi, allocator = allocator) : fmt.aprintf("Value must be between %s and %s.", lo, hi, allocator = allocator)
	}
	if .Range_Underflow in v {
		lo, _ := string_from_number(t, lim.min)
		if t in DATE_LIKE { return fr ? fmt.aprintf("La valeur doit être %s ou plus tard.", lo, allocator = allocator) : fmt.aprintf("Value must be %s or later.", lo, allocator = allocator) }
		return fr ? fmt.aprintf("La valeur doit être supérieure ou égale à %s.", lo, allocator = allocator) : fmt.aprintf("Value must be greater than or equal to %s.", lo, allocator = allocator)
	}
	if .Range_Overflow in v {
		hi, _ := string_from_number(t, lim.max)
		if t in DATE_LIKE { return fr ? fmt.aprintf("La valeur doit être %s ou plus tôt.", hi, allocator = allocator) : fmt.aprintf("Value must be %s or earlier.", hi, allocator = allocator) }
		return fr ? fmt.aprintf("La valeur doit être inférieure ou égale à %s.", hi, allocator = allocator) : fmt.aprintf("Value must be less than or equal to %s.", hi, allocator = allocator)
	}
	if .Step_Mismatch in v {
		x, _ := number_from_string(t, val)
		st, _ := allowed_step(f, n, t)
		base := step_base(f, n, t)
		below := base + math.floor((x - base) / st) * st
		above := below + st
		a, _ := string_from_number(t, below)
		b, _ := string_from_number(t, above)
		return fr ? fmt.aprintf("Veuillez saisir une valeur valide. Les deux valeurs valides les plus proches sont %s et %s.", a, b, allocator = allocator) : fmt.aprintf("Please enter a valid value. The two nearest valid values are %s and %s.", a, b, allocator = allocator)
	}
	return fr ? "Valeur non valide." : "Invalid value."
}

////////////////////////////////
// checkValidity / reportValidity

// The candidates a form or fieldset checks, tree order.
@(private)
validation_scope :: proc(f: ^Forms, h: base.Handle) -> []base.Handle {
	#partial switch kind(f, h) {
	case .Form: return form_submittables(f, h)
	case .Fieldset:
		out := make([dynamic]base.Handle, context.temp_allocator)
		for e in fieldset_elements(f, h) { if is_submittable(kind(f, e)) { append(&out, e) } }
		return out[:]
	}
	out := make([]base.Handle, 1, context.temp_allocator)
	out[0] = h
	return out
}

// checkValidity: fires `invalid` (cancelable) at every invalid candidate. True when all are valid.
check_validity :: proc(f: ^Forms, h: base.Handle) -> bool {
	all_ok := true
	for e in validation_scope(f, h) {
		if is_invalid_candidate(f, e) {
			all_ok = false
			fire(f, e, "invalid", cancelable = true)
		}
	}
	return all_ok
}

// reportValidity: like checkValidity, then shows the problem of the first invalid element whose `invalid` event was not
// cancelled (focus + message).
report_validity :: proc(f: ^Forms, h: base.Handle) -> bool {
	all_ok := true
	reported := false
	for e in validation_scope(f, h) {
		if !is_invalid_candidate(f, e) { continue }
		all_ok = false
		if c := control_of(f, e); c != nil { c.user_validity = true }
		if fire(f, e, "invalid", cancelable = true) && !reported {
			reported = true
			show_report(f, e)
		}
	}
	changed_widely(f)
	return all_ok
}

@(private)
show_report :: proc(f: ^Forms, e: base.Handle) {
	focus(f, e)
	replace_owned(&f.report.message, validation_message(f, e))
	f.report.node = e
	f.report.until = now(f) + f64(f.settings.report_ms)
	f.serial += 1
}

// The validation bubble to show now, if any.
current_report :: proc(f: ^Forms) -> (node: base.Handle, message: string, ok: bool) {
	if f.report.node == base.NIL_HANDLE || f.report.message == "" { return }
	if now(f) > f.report.until || dom.get(f.doc, f.report.node) == nil { f.report.node = base.NIL_HANDLE; return }
	return f.report.node, f.report.message, true
}

dismiss_report :: proc(f: ^Forms) {
	if f.report.node != base.NIL_HANDLE { f.report.node = base.NIL_HANDLE; f.serial += 1 }
}

////////////////////////////////
// valueAsNumber / valueAsDate / stepUp / stepDown

value_as_number :: proc(f: ^Forms, h: base.Handle) -> f64 {
	n := element(f, h)
	if kind_of(n) != .Input { return math.nan_f64() }
	t := input_type_of(n)
	if t not_in MINMAX_APPLIES { return math.nan_f64() }
	if x, ok := number_from_string(t, value(f, h)); ok { return x }
	return math.nan_f64()
}

set_value_as_number :: proc(f: ^Forms, h: base.Handle, x: f64) -> Error {
	n := element(f, h)
	if kind_of(n) != .Input { return .Invalid_State }
	t := input_type_of(n)
	if t not_in MINMAX_APPLIES { return .Invalid_State }
	if math.is_inf(x) { return .Not_Supported }   // TypeError
	if math.is_nan(x) { return set_value(f, h, "") }
	s, ok := string_from_number(t, x)
	if !ok { return set_value(f, h, "") }
	return set_value(f, h, s)
}

value_as_date :: proc(f: ^Forms, h: base.Handle) -> (ms: f64, ok: bool) {
	n := element(f, h)
	if kind_of(n) != .Input || !as_date_applies(input_type_of(n)) { return 0, false }
	return date_from_string(input_type_of(n), value(f, h))
}

set_value_as_date :: proc(f: ^Forms, h: base.Handle, ms: f64, null: bool) -> Error {
	n := element(f, h)
	if kind_of(n) != .Input || !as_date_applies(input_type_of(n)) { return .Invalid_State }
	if null || math.is_nan(ms) { return set_value(f, h, "") }
	s, ok := string_from_date(input_type_of(n), ms)
	if !ok { return set_value(f, h, "") }
	return set_value(f, h, s)
}

// stepUp(n) / stepDown(n) (§4.10.5.4), with `by_user` for the arrow keys and the range slider (they fire input/change).
step :: proc(f: ^Forms, h: base.Handle, count: int, by_user := false) -> Error {
	n := element(f, h)
	if kind_of(n) != .Input { return .Invalid_State }
	t := input_type_of(n)
	if t not_in MINMAX_APPLIES { return .Invalid_State }
	st, has := allowed_step(f, n, t)
	if !has { return .Invalid_State }
	lim := limits(f, n, t)
	if lim.has_min && lim.has_max && lim.min > lim.max { return .None }
	base := step_base(f, n, t)
	if lim.has_min && lim.has_max {
		first := base + math.ceil((lim.min - base) / st) * st
		if first > lim.max + 1e-9 * max(1, abs(lim.max)) { return .None }
	}
	x, ok := number_from_string(t, value(f, h))
	if !ok { x = 0 }
	before := x
	k := (x - base) / st
	if !is_integral(k) {
		x = count < 0 ? base + math.floor(k) * st : base + math.ceil(k) * st
	} else {
		x += st * f64(count)
	}
	if lim.has_min && x < lim.min { x = base + math.ceil((lim.min - base) / st) * st }
	if lim.has_max && x > lim.max { x = base + math.floor((lim.max - base) / st) * st }
	if (count < 0 && before < x) || (count > 0 && before > x) { return .None }
	s, good := string_from_number(t, x)
	if !good { return .None }
	if by_user {
		if s == value(f, h) { return .None }
		set_value(f, h, s, by_user = true)
		if c := control_of(f, h); c != nil { c.user_validity = true }
		fire(f, h, "input", bubbles = true)
		fire(f, h, "change", bubbles = true)
		return .None
	}
	return set_value(f, h, s)
}

////////////////////////////////
// Pseudo-class state (for the style engine)

Style_Bit :: enum u8 { Checked, Indeterminate, Default, Disabled, Read_Write, Placeholder_Shown, Valid, Invalid, User_Valid, User_Invalid, In_Range, Out_Of_Range }
Style_Bits :: bit_set[Style_Bit; u16]

// Everything the dynamic pseudo-classes of a control depend on.
style_bits :: proc(f: ^Forms, h: base.Handle) -> Style_Bits {
	b: Style_Bits
	n := element(f, h)
	k := kind_of(n)
	if k == .None { return b }
	if is_disabled(f, h) { b += {.Disabled} }
	if is_read_write(f, h) { b += {.Read_Write} }
	if matches_checked(f, h) { b += {.Checked} }
	if matches_indeterminate(f, h) { b += {.Indeterminate} }
	if matches_default(f, h) { b += {.Default} }
	if placeholder_shown(f, h) { b += {.Placeholder_Shown} }
	if v, known := matches_valid(f, h); known { b += v ? {.Valid} : {.Invalid} }
	if v, known := matches_user_valid(f, h); known { b += v ? {.User_Valid} : {.User_Invalid} }
	if r, known := matches_in_range(f, h); known { b += r ? {.In_Range} : {.Out_Of_Range} }
	return b
}

is_read_write :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input: return input_type_of(n) in READONLY_APPLIES && is_mutable(f, h)
	case .Textarea: return is_mutable(f, h)
	}
	return false
}

matches_checked :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input:
		t := input_type_of(n)
		return (t == .Checkbox || t == .Radio) && checked(f, h)
	case .Option: return option_selected(f, h)
	}
	return false
}

matches_indeterminate :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input:
		t := input_type_of(n)
		if t == .Checkbox { return indeterminate(f, h) }
		if t == .Radio {
			group := radio_group(f, h)
			if len(group) == 0 { return !checked(f, h) }
			for g in group { if checked(f, g) { return false } }
			return true
		}
	}
	if n.name == "progress" { return !has_attr(n, "value") }
	return false
}

matches_default :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input:
		t := input_type_of(n)
		if t == .Checkbox || t == .Radio { return has_attr(n, "checked") }
		if t in SUBMIT_BUTTONS { owner := form_owner(f, h); return owner != base.NIL_HANDLE && default_button(f, owner) == h }
	case .Button:
		owner := form_owner(f, h)
		return owner != base.NIL_HANDLE && default_button(f, owner) == h
	case .Option: return has_attr(n, "selected")
	}
	return false
}

placeholder_shown :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input:
		if input_type_of(n) not_in PLACEHOLDER_APPLIES { return false }
	case .Textarea:
	case: return false
	}
	ph, ok := attr(n, "placeholder")
	if !ok || ph == "" { return false }
	return edit_text(f, h) == ""
}

// :valid / :invalid apply to candidates for validation, forms and fieldsets.
matches_valid :: proc(f: ^Forms, h: base.Handle) -> (valid: bool, applies: bool) {
	#partial switch kind(f, h) {
	case .Form, .Fieldset:
		for e in validation_scope(f, h) { if is_invalid_candidate(f, e) { return false, true } }
		return true, true
	}
	if !is_submittable(kind(f, h)) || !will_validate(f, h) { return false, false }
	return is_valid(f, h), true
}

// :user-valid / :user-invalid: like :valid / :invalid once the user interacted with the control (or tried to submit).
matches_user_valid :: proc(f: ^Forms, h: base.Handle) -> (valid: bool, applies: bool) {
	c := control_peek(f, h)
	if c == nil || !c.user_validity { return false, false }
	if !is_submittable(kind(f, h)) || !will_validate(f, h) { return false, false }
	return is_valid(f, h), true
}

matches_in_range :: proc(f: ^Forms, h: base.Handle) -> (in_range: bool, applies: bool) {
	n := element(f, h)
	if kind_of(n) != .Input { return false, false }
	t := input_type_of(n)
	if t not_in MINMAX_APPLIES || !will_validate(f, h) { return false, false }
	lim := limits(f, n, t)
	if !lim.has_min && !lim.has_max { return false, false }
	v := validity(f, h)
	return .Range_Underflow not_in v && .Range_Overflow not_in v, true
}

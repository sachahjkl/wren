package forms

// Login fields (docs/bitwarden.md 4.6): which field of a document takes a user name and which a password, for a fill
// that the user asked for (the Vault, src/vault). Pure functions over the DOM and the forms model, plus the fill itself,
// which writes as a user edit does: the value, `user_edited`, then `input` and `change`, so that frameworks see it.

import "core:strings"
import "wb:base"

Autocomplete_Token :: enum u8 { Username, Current_Password, New_Password, One_Time_Code, Email, Webauthn }
Autocomplete :: bit_set[Autocomplete_Token; u8]

// The tokens of the autocomplete attribute that a login cares about (HTML's autofill detail tokens: a section-* or
// shipping / billing prefix is skipped, unknown tokens are ignored).
autocomplete_tokens :: proc(f: ^Forms, h: base.Handle) -> (out: Autocomplete) {
	value, ok := attr(element(f, h), "autocomplete")
	if !ok { return }
	rest := value
	for word in strings.fields_iterator(&rest) {
		switch base.ascii_lower(word, context.temp_allocator) {
		case "username":         out += {.Username}
		case "current-password": out += {.Current_Password}
		case "new-password":     out += {.New_Password}
		case "one-time-code":    out += {.One_Time_Code}
		case "email":            out += {.Email}
		case "webauthn":         out += {.Webauthn}
		}
	}
	return
}

// The fields a fill writes into. NIL when there is none (a multi-step login has one of them).
Login_Fields :: struct {
	username, password: base.Handle,
	one_time_code:      base.Handle,   // the code of a second step (a TOTP code)
}

// Whether `h` asks for a one-time code: autocomplete one-time-code first; else a name, id or inputmode hint (otp, totp,
// 2fa, mfa; or a numeric field named "code" of at most 8 characters).
is_one_time_code :: proc(f: ^Forms, h: base.Handle) -> bool {
	tokens := autocomplete_tokens(f, h)
	if .One_Time_Code in tokens { return true }
	if tokens & {.Username, .Email, .Current_Password, .New_Password} != {} { return false }
	if input_type(f, h) == .Password && max_length(f, h) < 0 { return false }   // (a password field is one unless its length says a code)
	n := element(f, h)
	words := make([dynamic]string, 0, 2, context.temp_allocator)
	for name in ([]string{"name", "id"}) {
		if v, ok := attr(n, name); ok { append(&words, base.ascii_lower(v, context.temp_allocator)) }
	}
	for w in words {
		for hint in ([]string{"otp", "totp", "2fa", "mfa", "twofactor", "two-factor", "two_factor", "one-time", "onetime"}) {
			if strings.contains(w, hint) { return true }
		}
	}
	mode, _ := attr(n, "inputmode")
	mx := max_length(f, h)
	if base.ascii_lower(mode, context.temp_allocator) == "numeric" && mx >= 4 && mx <= 8 {
		for w in words { if strings.contains(w, "code") || strings.contains(w, "token") { return true } }
	}
	return false
}

// Whether `h` is a field a fill may write: an input of a type that takes a user name or a password, enabled, editable,
// and shown (`visible`: the shell's test that the element is rendered).
@(private = "file")
fillable :: proc(f: ^Forms, h: base.Handle, visible: proc(user: rawptr, h: base.Handle) -> bool, user: rawptr) -> bool {
	if kind(f, h) != .Input { return false }
	#partial switch input_type(f, h) {
	case .Text, .Email, .Tel, .Password:
	case: return false
	}
	return is_mutable(f, h) && (visible == nil || visible(user, h))
}

// The login group of `anchor` (the field the user acted on; NIL: the first group that has a password field), and its
// user name and password fields. The group is the anchor's form, or the fields with no form. A password goes only into
// a type=password field.
login_fields :: proc(f: ^Forms, anchor: base.Handle, visible: proc(user: rawptr, h: base.Handle) -> bool = nil, user: rawptr = nil) -> (out: Login_Fields) {
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	fields := make([dynamic]base.Handle, context.temp_allocator)
	for h in all { if fillable(f, h, visible, user) { append(&fields, h) } }
	if len(fields) == 0 { return }

	owner := base.NIL_HANDLE
	anchored := false
	for h in fields {
		if h == anchor { owner, anchored = form_owner(f, h), true; break }
	}
	if !anchored {
		found := false
		for h in fields {
			if input_type(f, h) == .Password { owner, found = form_owner(f, h), true; break }
		}
		if !found { return }   // (no anchor, no password: nothing says which field is a login)
	}
	group := make([dynamic]base.Handle, context.temp_allocator)
	for h in fields { if form_owner(f, h) == owner { append(&group, h) } }

	// the one-time code: never also the user name or the password
	for h in group {
		if is_one_time_code(f, h) { out.one_time_code = h; break }
	}

	// the password: current-password first, else the first password field that is not a new one
	first_new := base.NIL_HANDLE
	for h in group {
		if input_type(f, h) != .Password || h == out.one_time_code { continue }
		tokens := autocomplete_tokens(f, h)
		if .Current_Password in tokens { out.password = h; break }
		if .New_Password in tokens {
			if first_new == base.NIL_HANDLE { first_new = h }
			continue
		}
		if out.password == base.NIL_HANDLE { out.password = h }
	}
	if out.password == base.NIL_HANDLE { out.password = first_new }

	// the user name: autocomplete username or email first, else the nearest text field before the password, else the
	// anchor when it is a text field (the user name step of a multi-step login)
	for h in group {
		if input_type(f, h) == .Password || h == out.one_time_code { continue }
		tokens := autocomplete_tokens(f, h)
		if .Username in tokens || .Email in tokens { out.username = h; break }
	}
	if out.username == base.NIL_HANDLE && out.password != base.NIL_HANDLE {
		for h in group {
			if h == out.password { break }
			if input_type(f, h) != .Password && h != out.one_time_code { out.username = h }
		}
	}
	if out.username == base.NIL_HANDLE && anchored && input_type(f, anchor) != .Password && anchor != out.one_time_code { out.username = anchor }
	return
}

// What a field is in its login group, for the Vault's dropdown: None when it is not a field of a login.
Login_Role :: enum u8 { None, Username, Password, One_Time_Code }

login_role :: proc(f: ^Forms, h: base.Handle, visible: proc(user: rawptr, h: base.Handle) -> bool = nil, user: rawptr = nil) -> Login_Role {
	if h == base.NIL_HANDLE || kind(f, h) != .Input { return .None }
	lf := login_fields(f, h, visible, user)
	switch {
	case h == lf.one_time_code: return .One_Time_Code
	case h == lf.password:      return input_type(f, h) == .Password ? .Password : .None
	case h == lf.username:
		// (a lone text field is a login's only when something says so: a password beside it, or its autocomplete)
		if lf.password != base.NIL_HANDLE || autocomplete_tokens(f, h) & {.Username, .Email} != {} { return .Username }
	}
	return .None
}

// Writes `value` into a field as a user edit (a fill the user asked for). False when the field cannot take it. The
// field is marked: history restoration and the back/forward cache never keep a value that the Vault filled
// (docs/bitwarden.md 3.3).
fill_field :: proc(f: ^Forms, h: base.Handle, value: string) -> bool {
	if kind(f, h) != .Input || !is_text_field(f, h) || !is_mutable(f, h) { return false }
	if set_value(f, h, value, by_user = true) != .None { return false }
	f.vault_filled = true
	if c := control_peek(f, h); c != nil {
		c.changed_since_focus = false   // (change is fired now: not again on blur)
		c.vault_filled = true
		// (the fill is one edit: no undo step can bring back what the field held, or hold the value after a reset)
		undo_clear(&c.undo); undo_clear(&c.redo)
	}
	fire(f, h, "input", bubbles = true, text = "insertReplacementText")
	if element(f, h) == nil { return true }   // (a listener removed it)
	fire(f, h, "change", bubbles = true)
	return true
}

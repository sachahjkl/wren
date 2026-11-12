package forms

// Card and address fields (docs/bitwarden.md 4.10): what a field of a payment or address form takes, for a fill of a card
// or an identity of the Vault that the user picked. The autocomplete attribute decides first (HTML's autofill field
// names); else words of the field's name and id. Pure functions over the DOM and the forms model, plus the fill of a
// select (a country, a month), which writes as a user's choice does. Also: the values of a login form being sent (the
// Vault's save offer, with a form or without one) and the one-time-code field of a document (its code's fill after a
// login's).

import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"

Autofill_Role :: enum u8 {
	None,
	// a card
	Cardholder, Card_Number, Card_Exp, Card_Exp_Month, Card_Exp_Year, Card_Code, Card_Type,
	// an identity
	Full_Name, Given_Name, Additional_Name, Family_Name, Honorific, Email, Phone, Organization,
	Street, Address1, Address2, Address3, City, State, Postal_Code, Country,
}

Autofill_Kind :: enum u8 { None, Card, Identity }

autofill_kind :: proc(r: Autofill_Role) -> Autofill_Kind {
	switch r {
	case .None: return .None
	case .Cardholder, .Card_Number, .Card_Exp, .Card_Exp_Month, .Card_Exp_Year, .Card_Code, .Card_Type: return .Card
	case .Full_Name, .Given_Name, .Additional_Name, .Family_Name, .Honorific, .Email, .Phone, .Organization,
	     .Street, .Address1, .Address2, .Address3, .City, .State, .Postal_Code, .Country:
		return .Identity
	}
	return .None
}

// The role of an autocomplete field name ("cc-number"); None for what is no card or address field.
autofill_token_role :: proc(token: string) -> Autofill_Role {
	switch token {
	case "cc-name":                          return .Cardholder
	case "cc-number":                        return .Card_Number
	case "cc-exp":                           return .Card_Exp
	case "cc-exp-month":                     return .Card_Exp_Month
	case "cc-exp-year":                      return .Card_Exp_Year
	case "cc-csc":                           return .Card_Code
	case "cc-type":                          return .Card_Type
	case "name":                             return .Full_Name
	case "given-name":                       return .Given_Name
	case "additional-name":                  return .Additional_Name
	case "family-name":                      return .Family_Name
	case "honorific-prefix":                 return .Honorific
	case "email":                            return .Email
	case "tel", "tel-national":              return .Phone
	case "organization":                     return .Organization
	case "street-address":                   return .Street
	case "address-line1":                    return .Address1
	case "address-line2":                    return .Address2
	case "address-line3":                    return .Address3
	case "address-level2":                   return .City
	case "address-level1":                   return .State
	case "postal-code":                      return .Postal_Code
	case "country", "country-name":          return .Country
	}
	return .None
}

// Words of a field's name or id (letters and digits only, lower case), and the role each says. In order: the first
// that the compact name holds wins (a cardholder's name is no full name; an expiry's month is no month of a date).
@(private = "file")
NAME_HINTS := [?]struct { word: string, role: Autofill_Role }{
	{"cardholder", .Cardholder}, {"nameoncard", .Cardholder}, {"ccname", .Cardholder}, {"cardname", .Cardholder},
	{"cardnumber", .Card_Number}, {"ccnumber", .Card_Number}, {"ccnum", .Card_Number}, {"cardnum", .Card_Number},
	{"cvc", .Card_Code}, {"cvv", .Card_Code}, {"csc", .Card_Code}, {"securitycode", .Card_Code}, {"cardcode", .Card_Code}, {"cvn", .Card_Code},
	{"expmonth", .Card_Exp_Month}, {"expirymonth", .Card_Exp_Month}, {"expirationmonth", .Card_Exp_Month}, {"ccmonth", .Card_Exp_Month}, {"expmm", .Card_Exp_Month},
	{"expyear", .Card_Exp_Year}, {"expiryyear", .Card_Exp_Year}, {"expirationyear", .Card_Exp_Year}, {"ccyear", .Card_Exp_Year}, {"expyy", .Card_Exp_Year},
	{"expiry", .Card_Exp}, {"expiration", .Card_Exp}, {"expdate", .Card_Exp}, {"ccexp", .Card_Exp}, {"cardexp", .Card_Exp},
	{"cardtype", .Card_Type}, {"cctype", .Card_Type}, {"cardbrand", .Card_Type},
	{"firstname", .Given_Name}, {"givenname", .Given_Name}, {"forename", .Given_Name}, {"fname", .Given_Name},
	{"middlename", .Additional_Name},
	{"lastname", .Family_Name}, {"familyname", .Family_Name}, {"surname", .Family_Name}, {"lname", .Family_Name},
	{"fullname", .Full_Name},
	{"addressline1", .Address1}, {"address1", .Address1}, {"addr1", .Address1}, {"street", .Address1},
	{"addressline2", .Address2}, {"address2", .Address2}, {"addr2", .Address2},
	{"addressline3", .Address3}, {"address3", .Address3},
	{"postalcode", .Postal_Code}, {"postcode", .Postal_Code}, {"zip", .Postal_Code}, {"postal", .Postal_Code},
	{"city", .City}, {"town", .City}, {"locality", .City},
	{"province", .State}, {"state", .State},
	{"country", .Country},
	{"company", .Organization}, {"organization", .Organization}, {"organisation", .Organization},
	{"phone", .Phone}, {"mobile", .Phone},
	{"email", .Email},
}

// What `h` takes in a card or address form. An input of a text type (a card's code may be a password field), or a
// select. Its autocomplete first: a login's tokens (username, current-password...) or "off" with nothing else say it
// is no such field; else its name and id.
autofill_role :: proc(f: ^Forms, h: base.Handle) -> Autofill_Role {
	k := kind(f, h)
	t := input_type(f, h)
	if k == .Input {
		#partial switch t {
		case .Text, .Email, .Tel, .Number, .Password, .Search:
		case: return .None
		}
	} else if k != .Select {
		return .None
	}
	n := element(f, h)
	if value, ok := attr(n, "autocomplete"); ok {
		rest := value
		for word in strings.fields_iterator(&rest) {
			if r := autofill_token_role(base.ascii_lower(word, context.temp_allocator)); r != .None {
				if t == .Password && r != .Card_Code { return .None }
				return r
			}
		}
		if autocomplete_tokens(f, h) != {} { return .None }   // (a login's field)
	}
	compact := strings.builder_make(context.temp_allocator)
	for name in ([]string{"name", "id"}) {
		v, _ := attr(n, name)
		for c in transmute([]u8)v {
			switch c {
			case 'a' ..= 'z', '0' ..= '9': strings.write_byte(&compact, c)
			case 'A' ..= 'Z':             strings.write_byte(&compact, c + 32)
			}
		}
		strings.write_byte(&compact, ' ')
	}
	words := strings.to_string(compact)
	for hint in NAME_HINTS {
		if strings.contains(words, hint.word) {
			if t == .Password && hint.role != .Card_Code { return .None }
			return hint.role
		}
	}
	if k == .Input {
		#partial switch t {
		case .Email: return .Email
		case .Tel:   return .Phone
		}
	}
	return .None
}

Autofill_Field :: struct {
	field: base.Handle,
	role:  Autofill_Role,
}

// The fields of the group of `anchor` (its form, or the fields with no form) that take a value of the same kind as the
// anchor's (a card, an identity), in document order. Only fields a fill may write (enabled, editable, `visible`).
autofill_fields :: proc(f: ^Forms, anchor: base.Handle, visible: proc(user: rawptr, h: base.Handle) -> bool = nil, user: rawptr = nil) -> []Autofill_Field {
	want := autofill_kind(autofill_role(f, anchor))
	if want == .None { return nil }
	owner := form_owner(f, anchor)
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	out := make([dynamic]Autofill_Field, context.temp_allocator)
	for h in all {
		r := autofill_role(f, h)
		if r == .None || autofill_kind(r) != want || form_owner(f, h) != owner { continue }
		if !is_mutable(f, h) || (visible != nil && !visible(user, h)) { continue }
		append(&out, Autofill_Field{h, r})
	}
	return out[:]
}

// How a field wants a year: 2 digits when its maxlength or its placeholder says so ("YY", "AA"), else 4.
@(private = "file")
two_digit_year :: proc(f: ^Forms, h: base.Handle, whole_date: bool) -> bool {
	ph, _ := attr(element(f, h), "placeholder")
	p := base.ascii_lower(ph, context.temp_allocator)
	if strings.contains(p, "yyyy") || strings.contains(p, "aaaa") || strings.contains(p, "jjjj") { return false }
	if strings.contains(p, "yy") || strings.contains(p, "aa") || strings.contains(p, "jj") { return true }
	mx := max_length(f, h)
	if whole_date {
		// ("MM/YY" is 5, "MM / YY" 7; "MM/YYYY" 7, "MM / YYYY" 9: a slash with spaces needs the placeholder)
		return mx < 0 || mx <= 6
	}
	return mx == 2
}

// The month as a field wants it: two digits when it is a text field of 2 characters or a placeholder "MM" says so.
expiry_month_text :: proc(f: ^Forms, h: base.Handle, month: string, allocator := context.temp_allocator) -> string {
	m := strings.trim_space(month)
	ph, _ := attr(element(f, h), "placeholder")
	if len(m) == 1 && (max_length(f, h) == 2 || strings.contains(base.ascii_lower(ph, context.temp_allocator), "mm")) {
		return strings.concatenate({"0", m}, allocator)
	}
	return strings.clone(m, allocator)
}

// The year as a field wants it (2 or 4 digits).
expiry_year_text :: proc(f: ^Forms, h: base.Handle, year: string, allocator := context.temp_allocator) -> string {
	y := strings.trim_space(year)
	if len(y) == 4 && two_digit_year(f, h, false) { y = y[2:] }
	return strings.clone(y, allocator)
}

// The expiry date of a card in one field: "MM/YY" or "MM/YYYY", by the field's maxlength and placeholder.
expiry_text :: proc(f: ^Forms, h: base.Handle, month, year: string, allocator := context.temp_allocator) -> string {
	m := strings.trim_space(month)
	if len(m) == 1 { m = strings.concatenate({"0", m}, context.temp_allocator) }
	y := strings.trim_space(year)
	if len(y) == 4 && two_digit_year(f, h, true) { y = y[2:] }
	ph, _ := attr(element(f, h), "placeholder")
	sep := strings.contains(ph, " / ") ? " / " : "/"
	return strings.concatenate({m, sep, y}, allocator)
}

// Writes `value` into a card or address field as a user edit: a text field as fill_field does; a select gets the option
// whose value or text is `value` (case does not matter; "07" and "7" are one number). False when nothing matched.
autofill_write :: proc(f: ^Forms, h: base.Handle, value: string) -> bool {
	if value == "" { return false }
	if kind(f, h) != .Select { return fill_field(f, h, value) }
	if !is_mutable(f, h) { return false }
	want := strings.trim_space(value)
	n_want, want_number := strconv.parse_int(want, 10)
	found := -1
	for o, i in select_options_synced(f, h) {
		if is_disabled(f, o) { continue }
		ov := strings.trim_space(option_value(f, o))
		ot := strings.trim_space(option_text(f, o))
		if base.ascii_equal_fold(ov, want) || base.ascii_equal_fold(ot, want) { found = i; break }
		if want_number {
			if n, ok := strconv.parse_int(ov, 10); ok && n == n_want { found = i; break }
		}
	}
	if found < 0 { return false }
	set_selected_index(f, h, found)
	f.vault_filled = true
	if c := control_peek(f, h); c != nil { c.vault_filled = true }
	fire(f, h, "input", bubbles = true)
	if element(f, h) == nil { return true }   // (a listener removed it)
	fire(f, h, "change", bubbles = true)
	return true
}

// The first field of the document that asks for a one-time code (enabled, editable, `visible`). NIL when none.
one_time_code_field :: proc(f: ^Forms, visible: proc(user: rawptr, h: base.Handle) -> bool = nil, user: rawptr = nil) -> base.Handle {
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	for h in all {
		if kind(f, h) != .Input || !is_text_field(f, h) || !is_mutable(f, h) { continue }
		if is_one_time_code(f, h) && (visible == nil || visible(user, h)) { return h }
	}
	return base.NIL_HANDLE
}

// The user name and the password that `form` sends, for the Vault's save offer: its password field (a new password
// with a value first: a sign-up or a change of password sends the new one) and its user name field (login_fields).
// The values are the model's own: copy them at once. ok false: no password field with a value.
sent_login :: proc(f: ^Forms, form: base.Handle) -> (username, password: string, ok: bool) {
	anchor, new_password := base.NIL_HANDLE, base.NIL_HANDLE
	for h in form_submittables(f, form) {
		if kind(f, h) != .Input || input_type(f, h) != .Password || is_disabled(f, h) || is_one_time_code(f, h) { continue }
		if anchor == base.NIL_HANDLE { anchor = h }
		if new_password == base.NIL_HANDLE && .New_Password in autocomplete_tokens(f, h) && value(f, h) != "" { new_password = h }
	}
	if anchor == base.NIL_HANDLE { return "", "", false }
	lf := login_fields(f, anchor)
	pw := new_password != base.NIL_HANDLE ? new_password : lf.password
	if pw == base.NIL_HANDLE || value(f, pw) == "" { return "", "", false }
	if lf.username != base.NIL_HANDLE { username = value(f, lf.username) }
	return username, value(f, pw), true
}

////////////////////////////////
// A login sent without a form

// A login a script sends (it reads the fields, posts them itself, then goes to another page) never passes through a
// submission. What says it was sent: the person typed a password, the field still holds it, no form sent it, and the
// document goes (a navigation, a close) or the field leaves the document. The page asks here at that moment, once.

// A form is being sent (submit): the password it owns was sent with it, and is no unsent login any more.
@(private)
typed_sent :: proc(f: ^Forms, form: base.Handle) {
	if f.typed_password != base.NIL_HANDLE && form_owner(f, f.typed_password) == form { f.typed_password = base.NIL_HANDLE }
}

// Whether the typed password field is `node` or inside it (the page asks when `node` leaves the document).
typed_within :: proc(f: ^Forms, node: base.Handle) -> bool {
	if f.typed_password == base.NIL_HANDLE || node == base.NIL_HANDLE { return false }
	for cur := f.typed_password; cur != base.NIL_HANDLE; {
		if cur == node { return true }
		n := dom.get(f.doc, cur)
		if n == nil { return false }
		cur = n.parent
	}
	return false
}

// The login that the person typed and no form sent, and forgets it (asked once: the page goes or the field left it).
// ok false: no password typed, a script's value replaced it, it is empty, or it is no password field now. The user name
// is the group's (its form, or the fields with no form, in the field's tree: a form taken out of the document still
// holds its fields): autocomplete username or email first, else the nearest text field before the password. The values
// are the model's own: copy them at once.
unsent_login :: proc(f: ^Forms) -> (username, password: string, ok: bool) {
	h := f.typed_password
	f.typed_password = base.NIL_HANDLE
	if h == base.NIL_HANDLE { return }
	c := control_peek(f, h)
	if c == nil || !c.user_edited || kind(f, h) != .Input || input_type(f, h) != .Password || is_one_time_code(f, h) { return }
	password = value(f, h)
	if password == "" { return "", "", false }
	owner := form_owner(f, h)
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, tree_root(f, h), &all)
	nearest, named := base.NIL_HANDLE, base.NIL_HANDLE
	before := true
	for e in all {
		if e == h { before = false; continue }
		if kind(f, e) != .Input || form_owner(f, e) != owner || is_one_time_code(f, e) { continue }
		#partial switch input_type(f, e) {
		case .Text, .Email, .Tel:
		case: continue
		}
		if named == base.NIL_HANDLE && autocomplete_tokens(f, e) & {.Username, .Email} != {} { named = e }
		if before { nearest = e }
	}
	user := named != base.NIL_HANDLE ? named : nearest
	if user != base.NIL_HANDLE { username = value(f, user) }
	return username, password, true
}

// The password fields of the group of `anchor` that take a new password: autocomplete new-password, or every password
// field that is not the current one (a sign-up's password and its confirmation). In document order.
new_password_fields :: proc(f: ^Forms, anchor: base.Handle) -> []base.Handle {
	owner := form_owner(f, anchor)
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	out := make([dynamic]base.Handle, context.temp_allocator)
	for h in all {
		if kind(f, h) != .Input || input_type(f, h) != .Password || form_owner(f, h) != owner || !is_mutable(f, h) { continue }
		if .Current_Password in autocomplete_tokens(f, h) || is_one_time_code(f, h) { continue }
		append(&out, h)
	}
	return out[:]
}

// Whether the password field `h` takes a new password: its autocomplete says so, or its group has two password fields
// (a sign-up's confirmation) and it is not the current one.
is_new_password :: proc(f: ^Forms, h: base.Handle) -> bool {
	tokens := autocomplete_tokens(f, h)
	if .New_Password in tokens { return true }
	if .Current_Password in tokens { return false }
	return len(new_password_fields(f, h)) >= 2
}

package forms

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

@(private = "file")
Cx :: struct {
	doc:      ^dom.Document,
	f:        ^Forms,
	settings: Settings,
	events:   [dynamic]string,   // "type@id"
}

@(private = "file")
cx_make :: proc(src: string) -> ^Cx {
	x := new(Cx)
	x.doc = dom.document_create()
	html.parse_into(x.doc, x.doc.root, transmute([]byte)src, 100_000)
	x.settings = settings_default()
	x.f = forms_create(x.doc, &x.settings, Host{
		user = x,
		dispatch = proc(user: rawptr, target: base.Handle, ev: dom.Event) -> bool {
			x := (^Cx)(user)
			id, _ := dom.get_attribute(x.doc, target, "id")
			append(&x.events, strings.concatenate({ev.type, "@", id}))
			return true
		},
		document_url = proc(user: rawptr) -> string { return "https://example.com/login" },
	})
	return x
}

@(private = "file")
cx_destroy :: proc(x: ^Cx) {
	forms_destroy(x.f)
	dom.document_destroy(x.doc)
	for e in x.events { delete(e) }
	delete(x.events)
	settings_destroy(&x.settings)
	free(x)
}

@(private = "file")
by_id :: proc(x: ^Cx, name: string) -> base.Handle { return dom.find_by_id(x.doc, name) }

@(test)
a_plain_login_form_gives_its_two_fields :: proc(t: ^testing.T) {
	x := cx_make(`<form><input id=search type=search><input id=u name=login><input id=p type=password><button>Go</button></form>`)
	defer cx_destroy(x)
	lf := login_fields(x.f, base.NIL_HANDLE)
	testing.expect_value(t, lf.username, by_id(x, "u"))
	testing.expect_value(t, lf.password, by_id(x, "p"))
}

@(test)
autocomplete_tokens_decide_first :: proc(t: ^testing.T) {
	x := cx_make(`<form>
		<input id=email type=email autocomplete="section-a username">
		<input id=other>
		<input id=new type=password autocomplete="new-password">
		<input id=cur type=password autocomplete="current-password">
	</form>`)
	defer cx_destroy(x)
	testing.expect(t, .Username in autocomplete_tokens(x.f, by_id(x, "email")))
	lf := login_fields(x.f, base.NIL_HANDLE)
	testing.expect_value(t, lf.username, by_id(x, "email"))
	testing.expect_value(t, lf.password, by_id(x, "cur"))
}

@(test)
the_group_is_the_form_of_the_field_acted_on :: proc(t: ^testing.T) {
	x := cx_make(`<form id=f1><input id=u1><input id=p1 type=password></form>
		<form id=f2><input id=u2><input id=p2 type=password></form>`)
	defer cx_destroy(x)
	lf := login_fields(x.f, by_id(x, "u2"))
	testing.expect_value(t, lf.username, by_id(x, "u2"))
	testing.expect_value(t, lf.password, by_id(x, "p2"))
}

@(test)
disabled_and_readonly_fields_are_left_alone :: proc(t: ^testing.T) {
	x := cx_make(`<form><input id=u disabled><input id=u2 readonly><input id=p type=password disabled></form>`)
	defer cx_destroy(x)
	lf := login_fields(x.f, base.NIL_HANDLE)
	testing.expect_value(t, lf.username, base.NIL_HANDLE)
	testing.expect_value(t, lf.password, base.NIL_HANDLE)
}

@(test)
the_user_name_step_of_a_multi_step_login :: proc(t: ^testing.T) {
	x := cx_make(`<form><input id=u type=email></form>`)
	defer cx_destroy(x)
	testing.expect_value(t, login_fields(x.f, base.NIL_HANDLE), Login_Fields{})   // (no anchor and no password: nothing)
	lf := login_fields(x.f, by_id(x, "u"))
	testing.expect_value(t, lf.username, by_id(x, "u"))
	testing.expect_value(t, lf.password, base.NIL_HANDLE)
}

@(test)
a_fill_is_a_user_edit_with_its_events :: proc(t: ^testing.T) {
	x := cx_make(`<form><input id=u><input id=p type=password></form>`)
	defer cx_destroy(x)
	testing.expect(t, fill_field(x.f, by_id(x, "u"), "me"))
	testing.expect(t, fill_field(x.f, by_id(x, "p"), "s3cret"))
	testing.expect_value(t, value(x.f, by_id(x, "p")), "s3cret")
	testing.expect(t, control_of(x.f, by_id(x, "p")).user_edited)
	testing.expect_value(t, strings.join(x.events[:], " ", context.temp_allocator), "input@u change@u input@p change@p")
}

// What the Vault filled is marked, so that history restoration and the back/forward cache leave it out; a script's value
// or a reset ends the mark of the field (the document keeps its own: it held a filled value once).
@(test)
a_filled_field_is_marked_until_a_script_or_a_reset_replaces_it :: proc(t: ^testing.T) {
	x := cx_make(`<form id=f><input id=u><input id=p type=password><input id=other></form>`)
	defer cx_destroy(x)
	testing.expect(t, !x.f.vault_filled)
	testing.expect(t, fill_field(x.f, by_id(x, "u"), "me"))
	testing.expect(t, fill_field(x.f, by_id(x, "p"), "s3cret"))
	testing.expect(t, x.f.vault_filled)
	testing.expect(t, control_of(x.f, by_id(x, "u")).vault_filled)
	testing.expect(t, control_of(x.f, by_id(x, "p")).vault_filled)
	testing.expect_value(t, len(control_of(x.f, by_id(x, "p")).undo), 0)
	testing.expect(t, set_value(x.f, by_id(x, "other"), "typed", by_user = true) == .None)
	testing.expect(t, !control_of(x.f, by_id(x, "other")).vault_filled)
	testing.expect(t, set_value(x.f, by_id(x, "u"), "from a script") == .None)
	testing.expect(t, !control_of(x.f, by_id(x, "u")).vault_filled)
	reset(x.f, by_id(x, "f"))
	testing.expect(t, !control_of(x.f, by_id(x, "p")).vault_filled)
	testing.expect(t, x.f.vault_filled)
}

@(test)
a_fill_does_not_write_into_what_is_not_a_text_field :: proc(t: ^testing.T) {
	x := cx_make(`<form><input id=c type=checkbox><input id=r readonly><select id=s></select></form>`)
	defer cx_destroy(x)
	testing.expect(t, !fill_field(x.f, by_id(x, "c"), "x"))
	testing.expect(t, !fill_field(x.f, by_id(x, "r"), "x"))
	testing.expect(t, !fill_field(x.f, by_id(x, "s"), "x"))
	testing.expect_value(t, len(x.events), 0)
}

// A second step's field: by its autocomplete token, or by its name; it is never the user name.
@(test)
one_time_code_fields_are_found :: proc(t: ^testing.T) {
	x := cx_make(`<form id=a><input id=u name=login><input id=p type=password><input id=c autocomplete=one-time-code></form>
		<form id=b><input id=otp name=totp_code inputmode=numeric></form>
		<form id=d><input id=n name=code inputmode=numeric maxlength=6></form>
		<form id=e><input id=plain name=code></form>`)
	defer cx_destroy(x)
	lf := login_fields(x.f, by_id(x, "u"))
	testing.expect_value(t, lf.username, by_id(x, "u"))
	testing.expect_value(t, lf.password, by_id(x, "p"))
	testing.expect_value(t, lf.one_time_code, by_id(x, "c"))
	b := login_fields(x.f, by_id(x, "otp"))
	testing.expect_value(t, b.one_time_code, by_id(x, "otp"))
	testing.expect_value(t, b.username, base.NIL_HANDLE)   // (the code's field is not a user name)
	testing.expect(t, is_one_time_code(x.f, by_id(x, "n")))
	testing.expect(t, !is_one_time_code(x.f, by_id(x, "plain")))   // (a field named "code" alone says nothing)
	testing.expect(t, !is_one_time_code(x.f, by_id(x, "p")))
}

// The dropdown shows on a login's fields only: a lone search field is no login.
@(test)
login_roles :: proc(t: ^testing.T) {
	x := cx_make(`<form><input id=u><input id=p type=password><input id=c autocomplete=one-time-code></form>
		<form><input id=q type=search></form><form><input id=lone name=city></form>
		<form><input id=mail type=email autocomplete=username></form>`)
	defer cx_destroy(x)
	testing.expect_value(t, login_role(x.f, by_id(x, "u")), Login_Role.Username)
	testing.expect_value(t, login_role(x.f, by_id(x, "p")), Login_Role.Password)
	testing.expect_value(t, login_role(x.f, by_id(x, "c")), Login_Role.One_Time_Code)
	testing.expect_value(t, login_role(x.f, by_id(x, "q")), Login_Role.None)
	testing.expect_value(t, login_role(x.f, by_id(x, "lone")), Login_Role.None)
	testing.expect_value(t, login_role(x.f, by_id(x, "mail")), Login_Role.Username)   // (the user name step of a multi-step login)
}

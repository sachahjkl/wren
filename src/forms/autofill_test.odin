package forms

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

@(private = "file")
Ax :: struct {
	doc:      ^dom.Document,
	f:        ^Forms,
	settings: Settings,
}

@(private = "file")
ax_make :: proc(src: string) -> ^Ax {
	x := new(Ax)
	x.doc = dom.document_create()
	html.parse_into(x.doc, x.doc.root, transmute([]byte)src, 100_000)
	x.settings = settings_default()
	x.f = forms_create(x.doc, &x.settings, Host{
		user = x,
		dispatch = proc(user: rawptr, target: base.Handle, ev: dom.Event) -> bool { return true },
		document_url = proc(user: rawptr) -> string { return "https://shop.example/pay" },
	})
	return x
}

@(private = "file")
ax_destroy :: proc(x: ^Ax) {
	forms_destroy(x.f)
	dom.document_destroy(x.doc)
	settings_destroy(&x.settings)
	free(x)
}

@(private = "file")
by_id :: proc(x: ^Ax, name: string) -> base.Handle { return dom.find_by_id(x.doc, name) }

@(test)
card_fields_by_their_autocomplete :: proc(t: ^testing.T) {
	x := ax_make(`<form>
		<input id=name autocomplete="cc-name"><input id=num autocomplete="billing cc-number">
		<input id=exp autocomplete=cc-exp><input id=mm autocomplete=cc-exp-month><input id=yy autocomplete=cc-exp-year>
		<input id=csc type=password autocomplete=cc-csc><select id=brand autocomplete=cc-type></select>
		<input id=user autocomplete=username><input id=pw type=password autocomplete=current-password></form>`)
	defer ax_destroy(x)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "name")), Autofill_Role.Cardholder)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "num")), Autofill_Role.Card_Number)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "exp")), Autofill_Role.Card_Exp)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "mm")), Autofill_Role.Card_Exp_Month)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "yy")), Autofill_Role.Card_Exp_Year)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "csc")), Autofill_Role.Card_Code)   // (a code may hide its characters)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "brand")), Autofill_Role.Card_Type)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "user")), Autofill_Role.None)   // (a login's field)
	testing.expect_value(t, autofill_role(x.f, by_id(x, "pw")), Autofill_Role.None)
}

@(test)
address_fields_by_their_autocomplete :: proc(t: ^testing.T) {
	x := ax_make(`<form>
		<input id=g autocomplete="shipping given-name"><input id=fam autocomplete=family-name><input id=n autocomplete=name>
		<input id=e type=email autocomplete=email><input id=tel type=tel autocomplete=tel><input id=org autocomplete=organization>
		<input id=a1 autocomplete=address-line1><input id=a2 autocomplete=address-line2><input id=a3 autocomplete=address-line3>
		<input id=city autocomplete=address-level2><input id=st autocomplete=address-level1><input id=zip autocomplete=postal-code>
		<select id=c autocomplete=country></select><input id=cn autocomplete=country-name><textarea id=sa autocomplete=street-address></textarea></form>`)
	defer ax_destroy(x)
	expect :: proc(t: ^testing.T, x: ^Ax, id: string, r: Autofill_Role) { testing.expect_value(t, autofill_role(x.f, by_id(x, id)), r) }
	expect(t, x, "g", .Given_Name)
	expect(t, x, "fam", .Family_Name)
	expect(t, x, "n", .Full_Name)
	expect(t, x, "e", .Email)
	expect(t, x, "tel", .Phone)
	expect(t, x, "org", .Organization)
	expect(t, x, "a1", .Address1)
	expect(t, x, "a2", .Address2)
	expect(t, x, "a3", .Address3)
	expect(t, x, "city", .City)
	expect(t, x, "st", .State)
	expect(t, x, "zip", .Postal_Code)
	expect(t, x, "c", .Country)
	expect(t, x, "cn", .Country)
	expect(t, x, "sa", .None)   // (a textarea is not written)
	testing.expect_value(t, autofill_kind(.Postal_Code), Autofill_Kind.Identity)
	testing.expect_value(t, autofill_kind(.Card_Code), Autofill_Kind.Card)
}

// Without autocomplete, the words of the name and id say it; a lone word ("name", "code") says nothing.
@(test)
fields_by_their_names :: proc(t: ^testing.T) {
	x := ax_make(`<form>
		<input id=a name="card_number"><input id=b name="cardholderName"><input id=c name="cvv2" type=password>
		<input id=d name="exp-month"><input id=e name="expiry_year"><input id=f2 name="ccExp">
		<input id=g name="billing[first_name]"><input id=h name="zipcode"><input id=i name="City">
		<input id=j name="name"><input id=k name="code"><input id=l name="password" type=password></form>`)
	defer ax_destroy(x)
	expect :: proc(t: ^testing.T, x: ^Ax, id: string, r: Autofill_Role) { testing.expect_value(t, autofill_role(x.f, by_id(x, id)), r) }
	expect(t, x, "a", .Card_Number)
	expect(t, x, "b", .Cardholder)
	expect(t, x, "c", .Card_Code)
	expect(t, x, "d", .Card_Exp_Month)
	expect(t, x, "e", .Card_Exp_Year)
	expect(t, x, "f2", .Card_Exp)
	expect(t, x, "g", .Given_Name)
	expect(t, x, "h", .Postal_Code)
	expect(t, x, "i", .City)
	expect(t, x, "j", .None)
	expect(t, x, "k", .None)
	expect(t, x, "l", .None)
}

// A card field's group: the card fields of its form only, not the address fields beside them nor another form's.
@(test)
the_group_is_the_fields_of_one_kind_in_one_form :: proc(t: ^testing.T) {
	x := ax_make(`<form id=pay><input id=num autocomplete=cc-number><input id=zip autocomplete=postal-code>
		<input id=exp autocomplete=cc-exp><input id=off autocomplete=cc-csc disabled></form>
		<form><input id=other autocomplete=cc-number></form>`)
	defer ax_destroy(x)
	group := autofill_fields(x.f, by_id(x, "num"))
	testing.expect_value(t, len(group), 2)
	testing.expect_value(t, group[0].field, by_id(x, "num"))
	testing.expect_value(t, group[1].role, Autofill_Role.Card_Exp)
	testing.expect_value(t, len(autofill_fields(x.f, by_id(x, "zip"))), 1)
}

// The expiry date as each field wants it: its placeholder, else its maxlength.
@(test)
expiry_dates_follow_the_field :: proc(t: ^testing.T) {
	x := ax_make(`<form><input id=a><input id=b maxlength=7><input id=c placeholder="MM / YYYY"><input id=d placeholder="MM/YY" maxlength=9>
		<input id=y2 maxlength=2><input id=y4><input id=m placeholder=MM></form>`)
	defer ax_destroy(x)
	testing.expect_value(t, expiry_text(x.f, by_id(x, "a"), "7", "2031"), "07/31")
	testing.expect_value(t, expiry_text(x.f, by_id(x, "b"), "7", "2031"), "07/2031")
	testing.expect_value(t, expiry_text(x.f, by_id(x, "c"), "12", "2031"), "12 / 2031")
	testing.expect_value(t, expiry_text(x.f, by_id(x, "d"), "12", "2031"), "12/31")
	testing.expect_value(t, expiry_year_text(x.f, by_id(x, "y2"), "2031"), "31")
	testing.expect_value(t, expiry_year_text(x.f, by_id(x, "y4"), "2031"), "2031")
	testing.expect_value(t, expiry_month_text(x.f, by_id(x, "m"), "7"), "07")
	testing.expect_value(t, expiry_month_text(x.f, by_id(x, "y4"), "7"), "7")
}

@(test)
a_select_takes_the_option_of_the_value :: proc(t: ^testing.T) {
	x := ax_make(`<form><select id=m><option value="">Month</option><option value="01">01</option><option value="07">07</option></select>
		<select id=c><option value="FR">France</option><option value="DE">Germany</option></select></form>`)
	defer ax_destroy(x)
	testing.expect(t, autofill_write(x.f, by_id(x, "m"), "7"))
	testing.expect_value(t, value(x.f, by_id(x, "m")), "07")
	testing.expect(t, autofill_write(x.f, by_id(x, "c"), "germany"))
	testing.expect_value(t, value(x.f, by_id(x, "c")), "DE")
	testing.expect(t, !autofill_write(x.f, by_id(x, "c"), "Atlantis"))
	testing.expect(t, x.f.vault_filled)
}

// What a sent form gives the save offer: a new password before the current one (a change of password).
@(test)
a_sent_login_gives_its_values :: proc(t: ^testing.T) {
	x := ax_make(`<form id=login><input id=u name=user value="me"><input id=p type=password></form>
		<form id=change><input id=cu autocomplete=username value="me"><input id=old type=password autocomplete=current-password>
		<input id=new type=password autocomplete=new-password></form>
		<form id=search><input id=q></form>`)
	defer ax_destroy(x)
	_, _, empty := sent_login(x.f, by_id(x, "login"))
	testing.expect(t, !empty)   // (no password typed)
	testing.expect(t, set_value(x.f, by_id(x, "p"), "s3cret", by_user = true) == .None)
	u, p, ok := sent_login(x.f, by_id(x, "login"))
	testing.expect(t, ok)
	testing.expect_value(t, u, "me")
	testing.expect_value(t, p, "s3cret")
	testing.expect(t, set_value(x.f, by_id(x, "old"), "old", by_user = true) == .None)
	testing.expect(t, set_value(x.f, by_id(x, "new"), "fresh", by_user = true) == .None)
	_, p, ok = sent_login(x.f, by_id(x, "change"))
	testing.expect(t, ok)
	testing.expect_value(t, p, "fresh")
	_, _, ok = sent_login(x.f, by_id(x, "search"))
	testing.expect(t, !ok)
}

@(test)
the_code_field_of_a_document_is_found :: proc(t: ^testing.T) {
	x := ax_make(`<form><input id=u><input id=c autocomplete=one-time-code></form>`)
	defer ax_destroy(x)
	testing.expect_value(t, one_time_code_field(x.f), by_id(x, "c"))
	y := ax_make(`<form><input id=u><input id=p type=password></form>`)
	defer ax_destroy(y)
	testing.expect_value(t, one_time_code_field(y.f), base.NIL_HANDLE)
}

package gen

// wrentool paddle [-Apply] [-Environment sandbox|live] [-ProductName n] [-Amount 2900] [-Currency EUR]
// Wren's Paddle catalog: one product, "Wren User Licence", with one one-time price, taxes included (docs/licence.md, "Paddle
// sandbox"). A dry run by default: it prints what it would send and sends nothing. -Apply needs PADDLE_API_KEY, a server-side key
// with product.read/write and price.read/write, never saved anywhere. Safe to run again: a product of this name, and a price of
// this amount on it, are reused, not made twice. Revoke the key in Paddle once the ids are noted (the Worker has its own key).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

PADDLE_DESCRIPTION :: "Personal, perpetual licence for Wren, with two years of updates from the 1.0 release. Wren is free during the beta."

run_paddle :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Apply -Environment= -ProductName= -Amount= -Currency=")
	if !ok { return 2 }
	environment := tooling.flag(f, "-Environment", "sandbox")
	if environment != "sandbox" && environment != "live" { fmt.eprintln("paddle: -Environment sandbox or live"); return 2 }
	base := environment == "live" ? "https://api.paddle.com" : "https://sandbox-api.paddle.com"
	name := tooling.flag(f, "-ProductName", "Wren User Licence")
	amount := tooling.flag(f, "-Amount", "2900")   // (the lowest denomination, as a string: 29.00 EUR is "2900")
	currency := tooling.flag(f, "-Currency", "EUR")

	product := fmt.tprintf(`{{"name":%s,"tax_category":"standard","description":%s}}`, quote(name), quote(PADDLE_DESCRIPTION))
	// no billing_cycle (one-time), no trial, no overrides (Paddle converts for other countries); tax_mode internal: the buyer pays the displayed price
	price_of :: proc(product_id, amount, currency: string) -> string {
		return fmt.tprintf(`{{"description":"Wren User Licence, one payment, taxes included","name":"One payment",%s"unit_price":{{"amount":%s,"currency_code":%s}},"tax_mode":"internal","quantity":{{"minimum":1,"maximum":1}}}}`,
			product_id != "" ? fmt.tprintf(`"product_id":%s,`, quote(product_id)) : "", quote(amount), quote(currency))
	}
	if !tooling.flag_has(f, "-Apply") {
		fmt.printfln("DRY RUN (%s, %s): nothing is sent. Add -Apply to create it.", environment, base)
		fmt.printfln("POST /products\n%s", product)
		fmt.printfln("POST /prices (product_id: the product above)\n%s", price_of("", amount, currency))
		return 0
	}
	key := os.get_env("PADDLE_API_KEY", context.temp_allocator)
	if key == "" { fmt.eprintfln("paddle: set PADDLE_API_KEY to a server-side API key of the %s account first", environment); return 1 }

	// the product: reused when one of this name is there
	product_id := ""
	if list, got := paddle_call(base, key, "GET", "/products?status=active&per_page=200", ""); got {
		for p in list { if json_str(p, "name") == name { product_id = json_str(p, "id"); break } }
	} else { return 1 }
	if product_id != "" {
		fmt.printfln("product exists: %s", product_id)
	} else {
		made, got := paddle_call(base, key, "POST", "/products", product)
		if !got || len(made) == 0 { return 1 }
		product_id = json_str(made[0], "id")
		fmt.printfln("product created: %s", product_id)
	}

	// the price: reused when this product has one of this amount and no billing cycle
	price_id := ""
	if list, got := paddle_call(base, key, "GET", fmt.tprintf("/prices?product_id=%s&status=active&per_page=200", product_id), ""); got {
		for p in list {
			unit, _ := json_obj(p)["unit_price"].(json.Object)
			_, cycle := json_obj(p)["billing_cycle"].(json.Object)
			if json_str(unit, "amount") == amount && json_str(unit, "currency_code") == currency && !cycle { price_id = json_str(p, "id"); break }
		}
	} else { return 1 }
	if price_id != "" {
		fmt.printfln("price exists: %s", price_id)
	} else {
		made, got := paddle_call(base, key, "POST", "/prices", price_of(product_id, amount, currency))
		if !got || len(made) == 0 { return 1 }
		price_id = json_str(made[0], "id")
		fmt.printfln("price created: %s", price_id)
	}
	fmt.printfln("\nEnvironment : %s\nProduct     : %s  %s\nPrice       : %s %s, one-time, tax included, quantity 1  %s\n", environment, name, product_id, amount, currency, price_id)
	fmt.printfln("Next: PRICE_SUPPORTER = %s in licence/worker/cloudflare.config.ts and wrangler.jsonc (the right environment),", price_id)
	fmt.printfln("      data-price-supporter = %s in site/pricing/index.html.", price_id)
	return 0
}

// A call of Paddle's API with curl (the key by a header file of this process's, never on a command line); `data` as a list
// (an object answered is a list of one).
@(private = "file")
paddle_call :: proc(base, key, method, path, body: string) -> (data: []json.Value, ok: bool) {
	headers := fmt.tprintf("%s/paddle_headers_%d.txt", os.get_env("TMPDIR", context.temp_allocator) != "" ? os.get_env("TMPDIR", context.temp_allocator) : "/tmp", os.get_pid())
	if os.write_entire_file(headers, fmt.tprintf("Authorization: Bearer %s\nContent-Type: application/json\n", key)) != nil { return nil, false }
	defer os.remove(headers)
	_ = os.chmod(headers, {.Read_User, .Write_User})
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "curl", "-sS", "-X", method, "-H", fmt.tprintf("@%s", headers))
	if body != "" { append(&cmd, "--data", body) }
	append(&cmd, fmt.tprintf("%s%s", base, path))
	text, code := tooling.capture(cmd[:], allocator = context.temp_allocator)
	if code != 0 { fmt.eprintfln("paddle: %s %s: curl failed", method, path); return nil, false }
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { fmt.eprintfln("paddle: %s %s: not JSON: %s", method, path, text); return nil, false }
	root := json_obj(v)
	if e, has := root["error"]; has { fmt.eprintfln("paddle answered an error to %s %s: %v", method, path, e); return nil, false }
	#partial switch d in root["data"] {
	case json.Array:  return d[:], true
	case json.Object: out := make([]json.Value, 1, context.temp_allocator); out[0] = d; return out, true
	}
	return nil, true
}

@(private = "file")
json_obj :: proc(v: json.Value) -> json.Object { o, _ := v.(json.Object); return o }

@(private = "file")
json_str :: proc(v: json.Value, key: string) -> string { s, _ := json_obj(v)[key].(json.String); return string(s) }

@(private = "file")
quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	json.marshal_to_builder(&b, s, {})
	return strings.to_string(b)
}

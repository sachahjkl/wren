package browser

// The arguments of a console message as the page's realm described them (prelude/compat.js, sent while the panel is open):
// JSON with a node per value ({"t":"s"} string, "n" number, "b" boolean, "u" undefined, "z" null, "i" bigint, "y" symbol,
// "f" function, "d" DOM node, "x" error with its stack, "c" a cycle, "a" an accessor, "o" an object with its class, its
// properties and how many more there were). Here they become what the row shows: a first line of colored runs (strings
// as they are at the top level and quoted inside objects, objects as a preview `{a: 1, b: Array(3)}`), the `%s %d %i %f %o
// %O %c` substitutions of a format string, a tree of lines when the row is unfolded, and the grid of console.table.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "toolkit:draw"

Obj_Line :: struct { depth: int, runs: []Dt_Run }

Con_Table :: struct {
	cols:  []string,
	rows:  [][]string,        // each row: the index, then the cells
	has_values: bool,
}

CON_TREE_MAX :: 300

@(private = "file")
val_str :: proc(o: json.Object, key: string) -> string {
	if v, ok := o[key]; ok { if s, sok := v.(json.String); sok { return string(s) } }
	return ""
}

@(private = "file")
val_int :: proc(o: json.Object, key: string) -> int {
	if v, ok := o[key]; ok {
		#partial switch x in v { case json.Integer: return int(x); case json.Float: return int(x) }
	}
	return 0
}

// The level the page's console call had ("log", "info", "debug", "warn", "error", "result"), from the start of a payload.
payload_level :: proc(payload: string) -> string {
	i := strings.index(payload, "\"l\":\"")
	if i < 0 || i > 8 { return "" }
	rest := payload[i + 5:]
	j := strings.index_byte(rest, '"')
	return j < 0 ? "" : rest[:j]
}

con_payload_parse :: proc(payload: string) -> (json.Object, bool) {
	v, err := json.parse(transmute([]byte)payload, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	if err != nil { return nil, false }
	o, ok := v.(json.Object)
	return o, ok
}

// The id the page's realm keeps the message's arguments under (`"r":N` near the start of the description), 0: none.
con_payload_ref :: proc(payload: string) -> int {
	i := strings.index(payload, "\"r\":")
	if i < 0 || i > 40 { return 0 }
	n := 0
	for c in transmute([]u8)payload[i + 4:] { if c < '0' || c > '9' { break }; n = n * 10 + int(c - '0'); if n > 1 << 40 { break } }
	return n
}

con_payload_source :: proc(root: json.Object) -> string { return val_str(root, "w") }

// Cheap tests of what a payload holds (no parse): an object with properties, or an error with a stack, can be unfolded.
payload_unfoldable :: proc(payload: string) -> bool { return strings.contains(payload, "\"p\":[") || strings.contains(payload, "\"st\":\"") }
payload_is_table :: proc(payload: string) -> bool { return strings.contains(payload, "\"tbl\":") }

@(private = "file")
Out :: struct { runs: [dynamic]Dt_Run, left: int, col: Maybe(draw.Color) }

@(private = "file")
emit :: proc(o: ^Out, text: string, class: Syn_Class) {
	if o.left <= 0 || text == "" { return }
	t := text
	if len(t) > o.left { t = t[:o.left]; for len(t) > 0 && (t[len(t) - 1] & 0xC0) == 0x80 { t = t[:len(t) - 1] } }
	o.left -= len(t)
	col := syn_color(class)
	if c, ok := o.col.?; ok && class == .Plain { col = c }
	append(&o.runs, Dt_Run{t, col})
}

@(private = "file")
node_text :: proc(v: json.Value) -> string {
	o, ok := v.(json.Object)
	if !ok { return "" }
	switch val_str(o, "t") {
	case "s": return val_str(o, "v")
	case "n", "i": return val_str(o, "v")
	case "b":
		if b, bok := o["v"].(json.Boolean); bok { return b ? "true" : "false" }
	case "u": return "undefined"
	case "z": return "null"
	case "y": return val_str(o, "v")
	case "f", "d": return val_str(o, "d")
	case "x": return val_str(o, "d")
	case "o": return val_str(o, "d") != "" ? val_str(o, "d") : val_str(o, "c")
	}
	return ""
}

@(private = "file")
render :: proc(out: ^Out, v: json.Value, nested: bool) {
	o, ok := v.(json.Object)
	if !ok { return }
	switch val_str(o, "t") {
	case "s":
		s := val_str(o, "v")
		if nested { emit(out, fmt.tprintf("'%s'", dev_line(s, 80)), .String) } else { emit(out, dev_line(s, 4000), .Plain) }
	case "n": emit(out, val_str(o, "v"), .Number)
	case "i": emit(out, val_str(o, "v"), .Number)
	case "b", "u", "z": emit(out, node_text(v), .Atom)
	case "y": emit(out, val_str(o, "v"), .Prop)
	case "f": emit(out, strings.concatenate({"\u0192 ", val_str(o, "d")}, context.temp_allocator), .Func)
	case "c": emit(out, "[Circular]", .Comment)
	case "a": emit(out, "(...)", .Comment)
	case "d": emit(out, val_str(o, "d"), .Tag)
	case "x":
		d := val_str(o, "d")
		if i := strings.index_byte(d, '\n'); i >= 0 { d = d[:i] }
		emit(out, d, .Error)
	case "o": render_obj(out, o, nested)
	}
}

@(private = "file")
is_ident :: proc(s: string) -> bool {
	if s == "" { return false }
	for c, i in transmute([]u8)s {
		if !(c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && c >= '0' && c <= '9')) { return false }
	}
	return true
}

@(private = "file")
render_obj :: proc(out: ^Out, o: json.Object, nested: bool) {
	cls := val_str(o, "c")
	count := val_int(o, "m")
	switch cls {
	case "Date", "RegExp": emit(out, val_str(o, "d"), cls == "Date" ? .Value : .String); return
	}
	props: json.Array
	if p, ok := o["p"]; ok { props, _ = p.(json.Array) }
	extra := val_int(o, "x")
	switch cls {
	case "Array", "Uint8Array", "Int8Array", "Uint16Array", "Int16Array", "Uint32Array", "Int32Array", "Float32Array", "Float64Array", "Uint8ClampedArray", "BigInt64Array", "BigUint64Array":
		if cls != "Array" { emit(out, cls, .Name) }
		emit(out, fmt.tprintf("(%d) [", count), .Plain)
		if len(props) == 0 && count > 0 { emit(out, "\u2026", .Comment) }
		for p, i in props {
			if out.left <= 0 { emit(out, "\u2026", .Comment); break }
			if i > 0 { emit(out, ", ", .Punct) }
			if pair, pok := p.(json.Array); pok && len(pair) == 2 { render(out, pair[1], true) }
		}
		if extra > 0 { emit(out, ", \u2026", .Comment) }
		emit(out, "]", .Plain)
	case "Map":
		emit(out, fmt.tprintf("Map(%d) {{", count), .Name)
		if len(props) == 0 && count > 0 { emit(out, "\u2026", .Comment) }
		for p, i in props {
			if out.left <= 0 { emit(out, "\u2026", .Comment); break }
			if i > 0 { emit(out, ", ", .Punct) }
			if pair, pok := p.(json.Array); pok && len(pair) == 2 { render(out, pair[0], true); emit(out, " => ", .Punct); render(out, pair[1], true) }
		}
		if extra > 0 { emit(out, ", \u2026", .Comment) }
		emit(out, "}", .Plain)
	case "Set":
		emit(out, fmt.tprintf("Set(%d) {{", count), .Name)
		if len(props) == 0 && count > 0 { emit(out, "\u2026", .Comment) }
		for p, i in props {
			if out.left <= 0 { emit(out, "\u2026", .Comment); break }
			if i > 0 { emit(out, ", ", .Punct) }
			if pair, pok := p.(json.Array); pok && len(pair) == 2 { render(out, pair[1], true) }
		}
		if extra > 0 { emit(out, ", \u2026", .Comment) }
		emit(out, "}", .Plain)
	case:
		if cls != "Object" { emit(out, cls, .Name); emit(out, " ", .Plain) }
		emit(out, "{", .Plain)
		if len(props) == 0 && count > 0 { emit(out, "\u2026", .Comment) }
		for p, i in props {
			if out.left <= 0 { emit(out, "\u2026", .Comment); break }
			if i > 0 { emit(out, ", ", .Punct) }
			if pair, pok := p.(json.Array); pok && len(pair) == 2 {
				k := node_text(pair[0])
				if ks, sok := pair[0].(json.String); sok { k = string(ks) }
				emit(out, is_ident(k) ? k : fmt.tprintf("'%s'", k), .Prop)
				emit(out, ": ", .Punct)
				render(out, pair[1], true)
			}
		}
		if extra > 0 { emit(out, ", \u2026", .Comment) }
		emit(out, "}", .Plain)
	}
}

@(private = "file")
css_color_of_style :: proc(style: string) -> (draw.Color, bool) {
	for decl in strings.split(style, ";", context.temp_allocator) {
		c := strings.index_byte(decl, ':')
		if c < 0 { continue }
		if strings.trim_space(decl[:c]) == "color" { return swatch_of(strings.trim_space(decl[c + 1:])) }
	}
	return {}, false
}

// The first line of a message: its arguments, with the substitutions of a format string.
con_payload_runs :: proc(root: json.Object, budget: int) -> []Dt_Run {
	out := Out{runs = make([dynamic]Dt_Run, 0, 12, context.temp_allocator), left = budget}
	args, ok := root["a"].(json.Array)
	if !ok { return out.runs[:] }
	start := 0
	if len(args) > 0 {
		if o, isobj := args[0].(json.Object); isobj && val_str(o, "t") == "s" && strings.contains_rune(val_str(o, "v"), '%') {
			f := val_str(o, "v")
			next := 1
			i := 0
			seg := 0
			for i < len(f) {
				if f[i] != '%' || i + 1 >= len(f) { i += 1; continue }
				c := f[i + 1]
				if c == '%' { emit(&out, f[seg:i + 1], .Plain); i += 2; seg = i; continue }
				if !strings.contains_rune("sdifoOc", rune(c)) { i += 1; continue }
				emit(&out, f[seg:i], .Plain)
				i += 2
				seg = i
				if next >= len(args) { emit(&out, f[i - 2:i], .Plain); continue }
				a := args[next]
				next += 1
				switch c {
				case 's': render(&out, a, false)
				case 'd', 'i', 'f': emit(&out, node_text(a), .Number)
				case 'o', 'O': render(&out, a, true)
				case 'c':
					if ao, aok := a.(json.Object); aok { if col, cok := css_color_of_style(val_str(ao, "v")); cok { out.col = col } else { out.col = nil } }
				}
			}
			emit(&out, f[seg:], .Plain)
			start = next
		}
	}
	for k in start ..< len(args) {
		if len(out.runs) > 0 { emit(&out, " ", .Plain) }
		render(&out, args[k], false)
	}
	return out.runs[:]
}

// The unfolded lines: each object argument's properties, nested, an error's stack.
con_payload_tree :: proc(root: json.Object) -> []Obj_Line {
	lines := make([dynamic]Obj_Line, 0, 16, context.temp_allocator)
	args, ok := root["a"].(json.Array)
	if !ok { return lines[:] }
	for a in args { tree_add(&lines, a, 0) }
	return lines[:]
}

@(private = "file")
tree_add :: proc(lines: ^[dynamic]Obj_Line, v: json.Value, depth: int) {
	o, ok := v.(json.Object)
	if !ok || len(lines) >= CON_TREE_MAX { return }
	switch val_str(o, "t") {
	case "x":
		st := val_str(o, "st")
		first := true
		for ln in strings.split_lines(st, context.temp_allocator) {
			if first { first = false; if strings.has_prefix(ln, val_str(o, "d")) { continue } }
			out := Out{runs = make([dynamic]Dt_Run, 0, 2, context.temp_allocator), left = 400}
			emit(&out, strings.trim_right_space(ln), .Comment)
			append(lines, Obj_Line{depth, out.runs[:]})
			if len(lines) >= CON_TREE_MAX { return }
		}
	case "o":
		p, pok := o["p"].(json.Array)
		if !pok { return }
		cls := val_str(o, "c")
		for item in p {
			pair, iok := item.(json.Array)
			if !iok || len(pair) != 2 { continue }
			out := Out{runs = make([dynamic]Dt_Run, 0, 8, context.temp_allocator), left = 220}
			if cls == "Map" {
				render(&out, pair[0], true); emit(&out, " => ", .Punct)
			} else if cls != "Set" {
				k := ""
				if ks, sok := pair[0].(json.Object); sok { k = val_str(ks, "v") } else if ks2, s2 := pair[0].(json.String); s2 { k = string(ks2) }
				if ks3, s3 := pair[0].(json.String); s3 { k = string(ks3) }
				emit(&out, k, cls == "Array" ? .Number : .Prop)
				emit(&out, ": ", .Punct)
			}
			render(&out, pair[1], true)
			append(lines, Obj_Line{depth, out.runs[:]})
			if len(lines) >= CON_TREE_MAX { return }
			tree_add(lines, pair[1], depth + 1)
		}
		if x := val_int(o, "x"); x > 0 {
			out := Out{runs = make([dynamic]Dt_Run, 0, 1, context.temp_allocator), left = 60}
			emit(&out, fmt.tprintf("\u2026 %d more", x), .Comment)
			append(lines, Obj_Line{depth, out.runs[:]})
		}
	}
}

con_payload_table :: proc(root: json.Object) -> (t: Con_Table, ok: bool) {
	tb, tok := root["tbl"].(json.Object)
	if !tok { return {}, false }
	cols_v, _ := tb["cols"].(json.Array)
	rows_v, _ := tb["rows"].(json.Array)
	t.cols = make([]string, len(cols_v), context.temp_allocator)
	for c, i in cols_v { if s, sok := c.(json.String); sok { t.cols[i] = string(s) } }
	if hv, hok := tb["values"].(json.Boolean); hok { t.has_values = bool(hv) }
	n := min(len(rows_v), 100)
	t.rows = make([][]string, n, context.temp_allocator)
	cell :: proc(v: json.Value) -> string {
		if _, isnull := v.(json.Null); isnull { return "" }
		out := Out{runs = make([dynamic]Dt_Run, 0, 4, context.temp_allocator), left = 60}
		render(&out, v, true)
		b := strings.builder_make(context.temp_allocator)
		for r in out.runs { strings.write_string(&b, r.text) }
		return strings.to_string(b)
	}
	for r, i in rows_v {
		if i >= n { break }
		ro, rok := r.(json.Object)
		if !rok { continue }
		cs, _ := ro["c"].(json.Array)
		row := make([]string, 1 + (t.has_values ? 1 : 0) + len(cs), context.temp_allocator)
		row[0] = val_str(ro, "i")
		k := 1
		if t.has_values { row[k] = cell(ro["v"]); k += 1 }
		for c in cs { row[k] = cell(c); k += 1 }
		t.rows[i] = row
	}
	return t, true
}

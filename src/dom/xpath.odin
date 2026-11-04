package dom

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"

// XPath 1.0 expressions over a document, what the developer tools' search finds (`//div[@id='a']/span[2]`,
// `//*[contains(text(), 'Sale')]`, `//a/@href`): location paths with the child, descendant(-or-self), parent, self,
// ancestor(-or-self), following-sibling, preceding-sibling and attribute axes (`/`, `//`, `..`, `.`, `@`, `axis::`), the
// tests `*`, a name, `text()`, `comment()` and `node()`, predicates (a number is a position), unions (`|`), comparisons
// (`=`, `!=`, `<`, `<=`, `>`, `>=`), `and`, `or`, strings, numbers and the functions contains, starts-with, concat,
// normalize-space, string, string-length, name, local-name, not, true, false, last, position and count. Names match
// without case (the document's are HTML's). An expression it does not read is an error (ok false). Everything is in the
// temporary allocator.

// A node of the result: `node` itself, or (attr >= 0) its attribute at that index.
Xpath_Item :: struct { node: base.Handle, attr: int }

// The nodes `expr` selects from `ctx` (the document's root when NIL), in document order.
xpath_select :: proc(d: ^Document, ctx: base.Handle, expr: string) -> (items: []Xpath_Item, ok: bool) {
	p := X_Parser{src = expr}
	x_next(&p)
	e := x_union(&p)
	if e == nil || p.err || p.tok.kind != .End { return nil, false }
	cx := X_Ctx{d = d, item = {ctx == base.NIL_HANDLE ? d.root : ctx, -1}, pos = 1, size = 1}
	v := x_eval(&cx, e)
	if cx.err || v.kind != .Nodes { return nil, false }
	return v.nodes[:], true
}

////////////////////////////////
// Reading

@(private = "file") X_DEPTH_MAX :: 64   // nesting of an expression read

@(private = "file")
X_Tok_Kind :: enum u8 { End, Name, Literal, Number, Slash, Slash2, Lbrack, Rbrack, Lparen, Rparen, At, Comma, Pipe, Dot, Dot2, Star, Axis, Op, Bad }

@(private = "file")
X_Tok :: struct { kind: X_Tok_Kind, text: string, num: f64 }

@(private = "file")
X_Parser :: struct { src: string, at: int, tok: X_Tok, err: bool, depth: int }

@(private = "file")
X_Kind :: enum u8 { Path, Union, Or, And, Cmp, Literal, Number, Call, Neg }

@(private = "file")
X_Axis :: enum u8 { Child, Descendant, Descendant_Or_Self, Parent, Self, Ancestor, Ancestor_Or_Self, Following_Sibling, Preceding_Sibling, Attribute }

@(private = "file")
X_AXIS_NAMES := [X_Axis]string{.Child = "child", .Descendant = "descendant", .Descendant_Or_Self = "descendant-or-self", .Parent = "parent",
	.Self = "self", .Ancestor = "ancestor", .Ancestor_Or_Self = "ancestor-or-self", .Following_Sibling = "following-sibling",
	.Preceding_Sibling = "preceding-sibling", .Attribute = "attribute"}

@(private = "file")
X_Test :: enum u8 { Name, Any, Text, Comment, Node }

@(private = "file")
X_Step :: struct { axis: X_Axis, test: X_Test, name: string, preds: [dynamic]^X_Expr }

@(private = "file")
X_Expr :: struct {
	kind:     X_Kind,
	op:       string,               // a comparison's operator, a function's name
	text:     string,               // a literal
	num:      f64,
	kids:     [dynamic]^X_Expr,     // operands, arguments
	absolute: bool,                 // a path from the root
	steps:    [dynamic]X_Step,
}

@(private = "file")
x_new :: proc(kind: X_Kind) -> ^X_Expr {
	e := new(X_Expr, context.temp_allocator)
	e.kind = kind
	e.kids.allocator, e.steps.allocator = context.temp_allocator, context.temp_allocator
	return e
}

@(private = "file")
x_name_char :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c >= 0x80 }

@(private = "file")
x_next :: proc(p: ^X_Parser) {
	s := p.src
	for p.at < len(s) && (s[p.at] == ' ' || s[p.at] == '\t' || s[p.at] == '\n' || s[p.at] == '\r') { p.at += 1 }
	if p.at >= len(s) { p.tok = {kind = .End}; return }
	c := s[p.at]
	start := p.at
	two := p.at + 1 < len(s) ? s[p.at:p.at + 2] : ""
	switch {
	case two == "//": p.at += 2; p.tok = {kind = .Slash2}
	case two == "..": p.at += 2; p.tok = {kind = .Dot2}
	case two == "::": p.at += 2; p.tok = {kind = .Axis}
	case two == "!=" || two == "<=" || two == ">=": p.at += 2; p.tok = {kind = .Op, text = two}
	case c == '/': p.at += 1; p.tok = {kind = .Slash}
	case c == '[': p.at += 1; p.tok = {kind = .Lbrack}
	case c == ']': p.at += 1; p.tok = {kind = .Rbrack}
	case c == '(': p.at += 1; p.tok = {kind = .Lparen}
	case c == ')': p.at += 1; p.tok = {kind = .Rparen}
	case c == '@': p.at += 1; p.tok = {kind = .At}
	case c == ',': p.at += 1; p.tok = {kind = .Comma}
	case c == '|': p.at += 1; p.tok = {kind = .Pipe}
	case c == '*': p.at += 1; p.tok = {kind = .Star}
	case c == '=' || c == '<' || c == '>' || c == '-': p.at += 1; p.tok = {kind = .Op, text = s[start:p.at]}
	case c == '"' || c == '\'':
		end := strings.index_byte(s[p.at + 1:], c)
		if end < 0 { p.tok = {kind = .Bad}; p.err = true; return }
		p.tok = {kind = .Literal, text = s[p.at + 1:p.at + 1 + end]}
		p.at += end + 2
	case (c >= '0' && c <= '9') || (c == '.' && p.at + 1 < len(s) && s[p.at + 1] >= '0' && s[p.at + 1] <= '9'):
		for p.at < len(s) && ((s[p.at] >= '0' && s[p.at] <= '9') || s[p.at] == '.') { p.at += 1 }
		v, _ := strconv.parse_f64(s[start:p.at])
		p.tok = {kind = .Number, num = v}
	case c == '.': p.at += 1; p.tok = {kind = .Dot}
	case x_name_char(c):
		for p.at < len(s) && (x_name_char(s[p.at]) || (s[p.at] == ':' && p.at + 1 < len(s) && s[p.at + 1] != ':')) { p.at += 1 }
		// (the words of the operators, and and or, are names until an expression reads them as operators)
		p.tok = {kind = .Name, text = s[start:p.at]}
	case: p.tok = {kind = .Bad}; p.err = true
	}
}

@(private = "file")
x_expect :: proc(p: ^X_Parser, k: X_Tok_Kind) {
	if p.tok.kind != k { p.err = true; return }
	x_next(p)
}

@(private = "file")
x_is_word :: proc(p: ^X_Parser, w: string) -> bool { return p.tok.kind == .Name && p.tok.text == w }

@(private = "file")
x_union :: proc(p: ^X_Parser) -> ^X_Expr {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > X_DEPTH_MAX { p.err = true; return nil }
	e := x_or(p)
	if p.tok.kind != .Pipe { return e }
	u := x_new(.Union)
	append(&u.kids, e)
	for p.tok.kind == .Pipe && !p.err {
		x_next(p)
		append(&u.kids, x_or(p))
	}
	return u
}

@(private = "file")
x_or :: proc(p: ^X_Parser) -> ^X_Expr {
	e := x_and(p)
	for x_is_word(p, "or") && !p.err {
		x_next(p)
		o := x_new(.Or)
		append(&o.kids, e, x_and(p))
		e = o
	}
	return e
}

@(private = "file")
x_and :: proc(p: ^X_Parser) -> ^X_Expr {
	e := x_cmp(p)
	for x_is_word(p, "and") && !p.err {
		x_next(p)
		o := x_new(.And)
		append(&o.kids, e, x_cmp(p))
		e = o
	}
	return e
}

@(private = "file")
x_cmp :: proc(p: ^X_Parser) -> ^X_Expr {
	e := x_unary(p)
	for p.tok.kind == .Op && p.tok.text != "-" && !p.err {
		o := x_new(.Cmp)
		o.op = p.tok.text
		x_next(p)
		append(&o.kids, e, x_unary(p))
		e = o
	}
	return e
}

@(private = "file")
x_unary :: proc(p: ^X_Parser) -> ^X_Expr {
	if p.tok.kind == .Op && p.tok.text == "-" {
		x_next(p)
		n := x_new(.Neg)
		append(&n.kids, x_unary(p))
		return n
	}
	return x_primary(p)
}

@(private = "file")
x_primary :: proc(p: ^X_Parser) -> ^X_Expr {
	#partial switch p.tok.kind {
	case .Literal:
		e := x_new(.Literal)
		e.text = p.tok.text
		x_next(p)
		return e
	case .Number:
		e := x_new(.Number)
		e.num = p.tok.num
		x_next(p)
		return e
	case .Lparen:
		x_next(p)
		e := x_union(p)
		x_expect(p, .Rparen)
		return e
	case .Name:
		// a function call: a name before '(' that is not a node test
		if p.at < len(p.src) && x_peek_paren(p) && !x_node_type(p.tok.text) {
			e := x_new(.Call)
			e.op = p.tok.text
			x_next(p)
			x_expect(p, .Lparen)
			for p.tok.kind != .Rparen && !p.err {
				append(&e.kids, x_union(p))
				if p.tok.kind == .Comma { x_next(p) } else { break }
			}
			x_expect(p, .Rparen)
			return e
		}
	}
	return x_path(p)
}

// Whether the next character (blanks aside) is '('.
@(private = "file")
x_peek_paren :: proc(p: ^X_Parser) -> bool {
	i := p.at
	for i < len(p.src) && p.src[i] == ' ' { i += 1 }
	return i < len(p.src) && p.src[i] == '('
}

@(private = "file")
x_node_type :: proc(name: string) -> bool { return name == "text" || name == "comment" || name == "node" }

@(private = "file")
x_path :: proc(p: ^X_Parser) -> ^X_Expr {
	e := x_new(.Path)
	#partial switch p.tok.kind {
	case .Slash:
		e.absolute = true
		x_next(p)
		// "/" alone: the root
		#partial switch p.tok.kind { case .End, .Rparen, .Rbrack, .Pipe, .Comma, .Op: return e }
	case .Slash2:
		e.absolute = true
		x_next(p)
		append(&e.steps, X_Step{axis = .Descendant_Or_Self, test = .Node})
	}
	for !p.err {
		x_step(p, e)
		if p.tok.kind == .Slash { x_next(p); continue }
		if p.tok.kind == .Slash2 { x_next(p); append(&e.steps, X_Step{axis = .Descendant_Or_Self, test = .Node}); continue }
		break
	}
	return e
}

@(private = "file")
x_step :: proc(p: ^X_Parser, e: ^X_Expr) {
	st := X_Step{axis = .Child, test = .Name}
	st.preds.allocator = context.temp_allocator
	#partial switch p.tok.kind {
	case .Dot:  x_next(p); append(&e.steps, X_Step{axis = .Self, test = .Node}); return
	case .Dot2: x_next(p); append(&e.steps, X_Step{axis = .Parent, test = .Node}); return
	case .At:   x_next(p); st.axis = .Attribute
	case .Name:
		if p.at + 1 < len(p.src) && strings.has_prefix(strings.trim_left_space(p.src[p.at:]), "::") {
			found := false
			for n, a in X_AXIS_NAMES { if n == p.tok.text { st.axis, found = a, true } }
			if !found { p.err = true; return }
			x_next(p)
			x_expect(p, .Axis)
		}
	}
	#partial switch p.tok.kind {
	case .Star: st.test = .Any; x_next(p)
	case .Name:
		name := p.tok.text
		x_next(p)
		if x_node_type(name) && p.tok.kind == .Lparen {
			x_next(p)
			x_expect(p, .Rparen)
			switch name { case "text": st.test = .Text; case "comment": st.test = .Comment; case: st.test = .Node }
		} else {
			st.name = name
		}
	case: p.err = true; return
	}
	for p.tok.kind == .Lbrack && !p.err {
		x_next(p)
		append(&st.preds, x_union(p))
		x_expect(p, .Rbrack)
	}
	append(&e.steps, st)
}

////////////////////////////////
// Evaluating

@(private = "file")
X_Value_Kind :: enum u8 { Nodes, Str, Num, Bool }

@(private = "file")
X_Value :: struct { kind: X_Value_Kind, nodes: [dynamic]Xpath_Item, s: string, n: f64, b: bool }

@(private = "file")
X_Ctx :: struct {
	d:     ^Document,
	item:  Xpath_Item,
	pos, size: int,
	order: map[base.Handle]int,   // document order, made when first needed
	err:   bool,
}

@(private = "file")
x_nodes :: proc() -> X_Value { return {kind = .Nodes, nodes = make([dynamic]Xpath_Item, context.temp_allocator)} }

@(private = "file")
x_eval :: proc(cx: ^X_Ctx, e: ^X_Expr) -> X_Value {
	if e == nil { cx.err = true; return {} }
	switch e.kind {
	case .Literal: return {kind = .Str, s = e.text}
	case .Number:  return {kind = .Num, n = e.num}
	case .Neg:     return {kind = .Num, n = -x_number(cx, x_eval(cx, e.kids[0]))}
	case .Or:      return {kind = .Bool, b = x_bool(x_eval(cx, e.kids[0])) || x_bool(x_eval(cx, e.kids[1]))}
	case .And:     return {kind = .Bool, b = x_bool(x_eval(cx, e.kids[0])) && x_bool(x_eval(cx, e.kids[1]))}
	case .Cmp:     return {kind = .Bool, b = x_compare(cx, e.op, x_eval(cx, e.kids[0]), x_eval(cx, e.kids[1]))}
	case .Union:
		out := x_nodes()
		for k in e.kids {
			v := x_eval(cx, k)
			if v.kind != .Nodes { cx.err = true; return {} }
			append(&out.nodes, ..v.nodes[:])
		}
		x_sort(cx, &out.nodes)
		return out
	case .Call: return x_call(cx, e)
	case .Path: return x_path_eval(cx, e)
	}
	return {}
}

@(private = "file")
x_path_eval :: proc(cx: ^X_Ctx, e: ^X_Expr) -> X_Value {
	cur := x_nodes()
	append(&cur.nodes, e.absolute ? Xpath_Item{cx.d.root, -1} : cx.item)
	for &st in e.steps {
		next := x_nodes()
		for it in cur.nodes {
			found := make([dynamic]Xpath_Item, context.temp_allocator)
			x_axis(cx, it, st, &found)
			for pred in st.preds {
				kept := make([dynamic]Xpath_Item, context.temp_allocator)
				for f, i in found {
					sub := X_Ctx{d = cx.d, item = f, pos = i + 1, size = len(found), order = cx.order}
					v := x_eval(&sub, pred)
					cx.order = sub.order
					if sub.err { cx.err = true; return {} }
					if v.kind == .Num ? v.n == f64(i + 1) : x_bool(v) { append(&kept, f) }
				}
				found = kept
			}
			append(&next.nodes, ..found[:])
		}
		x_sort(cx, &next.nodes)
		cur = next
	}
	return cur
}

// The nodes of `st`'s axis from `it` that pass its test, in the axis's order (a reverse axis: nearest first).
@(private = "file")
x_axis :: proc(cx: ^X_Ctx, it: Xpath_Item, st: X_Step, out: ^[dynamic]Xpath_Item) {
	d := cx.d
	if it.attr >= 0 {   // an attribute has a parent (its element) and itself
		#partial switch st.axis {
		case .Self: if x_test(d, it, st) { append(out, it) }
		case .Parent, .Ancestor, .Ancestor_Or_Self:
			if st.axis == .Ancestor_Or_Self && x_test(d, it, st) { append(out, it) }
			for h := it.node; h != base.NIL_HANDLE; {
				if x_test(d, {h, -1}, st) { append(out, Xpath_Item{h, -1}) }
				if st.axis == .Parent { break }
				n := get(d, h)
				h = n == nil ? base.NIL_HANDLE : n.parent
			}
		}
		return
	}
	n := get(d, it.node)
	if n == nil { return }
	add :: proc(d: ^Document, out: ^[dynamic]Xpath_Item, h: base.Handle, st: X_Step) { if x_test(d, {h, -1}, st) { append(out, Xpath_Item{h, -1}) } }
	switch st.axis {
	case .Self: add(d, out, it.node, st)
	case .Child: for c := n.first_child; c != base.NIL_HANDLE; c = get(d, c).next { add(d, out, c, st) }
	case .Descendant, .Descendant_Or_Self:
		if st.axis == .Descendant_Or_Self { add(d, out, it.node, st) }
		x_descend(d, it.node, st, out)
	case .Parent: if n.parent != base.NIL_HANDLE { add(d, out, n.parent, st) }
	case .Ancestor, .Ancestor_Or_Self:
		if st.axis == .Ancestor_Or_Self { add(d, out, it.node, st) }
		for h := n.parent; h != base.NIL_HANDLE; h = get(d, h).parent { add(d, out, h, st) }
	case .Following_Sibling: for h := n.next; h != base.NIL_HANDLE; h = get(d, h).next { add(d, out, h, st) }
	case .Preceding_Sibling: for h := n.prev; h != base.NIL_HANDLE; h = get(d, h).prev { add(d, out, h, st) }
	case .Attribute:
		if n.kind != .Element { return }
		for a, i in n.attrs {
			if st.test == .Any || st.test == .Node || (st.test == .Name && base.ascii_equal_fold(a.name, st.name)) { append(out, Xpath_Item{it.node, i}) }
		}
	}
}

@(private = "file")
x_descend :: proc(d: ^Document, h: base.Handle, st: X_Step, out: ^[dynamic]Xpath_Item) {
	n := get(d, h)
	if n == nil { return }
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := get(d, c)
		if cn == nil { break }
		if x_test(d, {c, -1}, st) { append(out, Xpath_Item{c, -1}) }
		x_descend(d, c, st, out)
		c = cn.next
	}
}

@(private = "file")
x_test :: proc(d: ^Document, it: Xpath_Item, st: X_Step) -> bool {
	n := get(d, it.node)
	if n == nil { return false }
	switch st.test {
	case .Node:    return true
	case .Text:    return it.attr < 0 && n.kind == .Text
	case .Comment: return it.attr < 0 && n.kind == .Comment
	case .Any:     return it.attr >= 0 || n.kind == .Element
	case .Name:
		if it.attr >= 0 { return base.ascii_equal_fold(n.attrs[it.attr].name, st.name) }
		return n.kind == .Element && base.ascii_equal_fold(n.name, st.name)
	}
	return false
}

// Document order, without the same node twice.
@(private = "file")
x_sort :: proc(cx: ^X_Ctx, items: ^[dynamic]Xpath_Item) {
	if len(items) < 2 { return }
	if len(cx.order) == 0 {
		cx.order = make(map[base.Handle]int, context.temp_allocator)
		k := 0
		walk :: proc(d: ^Document, h: base.Handle, order: ^map[base.Handle]int, k: ^int) {
			order[h] = k^
			k^ += 1
			n := get(d, h)
			if n == nil { return }
			for c := n.first_child; c != base.NIL_HANDLE; {
				cn := get(d, c)
				if cn == nil { break }
				walk(d, c, order, k)
				c = cn.next
			}
		}
		walk(cx.d, cx.d.root, &cx.order, &k)
	}
	Keyed :: struct { it: Xpath_Item, key: [2]int }
	keyed := make([]Keyed, len(items), context.temp_allocator)
	for it, i in items { keyed[i] = {it, {cx.order[it.node] or_else -1, it.attr}} }
	slice.sort_by(keyed, proc(a, b: Keyed) -> bool { return a.key[0] != b.key[0] ? a.key[0] < b.key[0] : a.key[1] < b.key[1] })
	clear(items)
	for k, i in keyed {
		if i > 0 && k.key == keyed[i - 1].key { continue }
		append(items, k.it)
	}
}

@(private = "file")
x_string_of :: proc(d: ^Document, it: Xpath_Item) -> string {
	n := get(d, it.node)
	if n == nil { return "" }
	if it.attr >= 0 { return n.attrs[it.attr].value }
	#partial switch n.kind {
	case .Text, .Comment: return n.text
	case .Element, .Document, .Fragment:
		b := strings.builder_make(context.temp_allocator)
		collect :: proc(d: ^Document, h: base.Handle, b: ^strings.Builder) {
			n := get(d, h)
			if n == nil { return }
			if n.kind == .Text { strings.write_string(b, n.text); return }
			for c := n.first_child; c != base.NIL_HANDLE; {
				cn := get(d, c)
				if cn == nil { break }
				collect(d, c, b)
				c = cn.next
			}
		}
		collect(d, it.node, &b)
		return strings.to_string(b)
	}
	return ""
}

@(private = "file")
x_string :: proc(cx: ^X_Ctx, v: X_Value) -> string {
	switch v.kind {
	case .Str:   return v.s
	case .Num:   return strconv.write_float(make([]u8, 32, context.temp_allocator), v.n, 'g', -1, 64)
	case .Bool:  return v.b ? "true" : "false"
	case .Nodes: return len(v.nodes) > 0 ? x_string_of(cx.d, v.nodes[0]) : ""
	}
	return ""
}

@(private = "file")
x_number :: proc(cx: ^X_Ctx, v: X_Value) -> f64 {
	switch v.kind {
	case .Num:  return v.n
	case .Bool: return v.b ? 1 : 0
	case .Str, .Nodes:
		n, ok := strconv.parse_f64(strings.trim_space(x_string(cx, v)))
		return ok ? n : math.nan_f64()
	}
	return 0
}

@(private = "file")
x_bool :: proc(v: X_Value) -> bool {
	switch v.kind {
	case .Bool:  return v.b
	case .Num:   return v.n != 0 && v.n == v.n
	case .Str:   return v.s != ""
	case .Nodes: return len(v.nodes) > 0
	}
	return false
}

@(private = "file")
x_compare :: proc(cx: ^X_Ctx, op: string, a, b: X_Value) -> bool {
	order := op != "=" && op != "!="
	one :: proc(op: string, x, y: f64) -> bool {
		switch op {
		case "=":  return x == y
		case "!=": return x != y
		case "<":  return x < y
		case "<=": return x <= y
		case ">":  return x > y
		case ">=": return x >= y
		}
		return false
	}
	// a node set: some node of it compares true
	if a.kind == .Nodes || b.kind == .Nodes {
		set, other, flipped := a, b, false
		if a.kind != .Nodes { set, other, flipped = b, a, true }
		if other.kind == .Bool { return one(op, x_bool(set) ? 1 : 0, other.b ? 1 : 0) }
		for it in set.nodes {
			s := X_Value{kind = .Str, s = x_string_of(cx.d, it)}
			if other.kind == .Nodes {
				for jt in other.nodes {
					t := x_string_of(cx.d, jt)
					if order ? one(op, x_number(cx, s), x_number(cx, {kind = .Str, s = t})) : (op == "=") == (s.s == t) { return true }
				}
				continue
			}
			l, r := s, other
			if flipped { l, r = other, s }
			if x_compare(cx, op, l, r) { return true }
		}
		return false
	}
	if !order && (a.kind == .Bool || b.kind == .Bool) { return (op == "=") == (x_bool(a) == x_bool(b)) }
	if order || a.kind == .Num || b.kind == .Num { return one(op, x_number(cx, a), x_number(cx, b)) }
	return (op == "=") == (x_string(cx, a) == x_string(cx, b))
}

@(private = "file")
x_call :: proc(cx: ^X_Ctx, e: ^X_Expr) -> X_Value {
	arg :: proc(cx: ^X_Ctx, e: ^X_Expr, i: int) -> X_Value {
		if i < len(e.kids) { return x_eval(cx, e.kids[i]) }
		v := x_nodes()   // (none: the context node)
		append(&v.nodes, cx.item)
		return v
	}
	want :: proc(cx: ^X_Ctx, e: ^X_Expr, lo, hi: int) -> bool {
		if len(e.kids) < lo || len(e.kids) > hi { cx.err = true; return false }
		return true
	}
	switch e.op {
	case "last":     if want(cx, e, 0, 0) { return {kind = .Num, n = f64(cx.size)} }
	case "position": if want(cx, e, 0, 0) { return {kind = .Num, n = f64(cx.pos)} }
	case "true":     if want(cx, e, 0, 0) { return {kind = .Bool, b = true} }
	case "false":    if want(cx, e, 0, 0) { return {kind = .Bool, b = false} }
	case "not":      if want(cx, e, 1, 1) { return {kind = .Bool, b = !x_bool(arg(cx, e, 0))} }
	case "count":
		if want(cx, e, 1, 1) {
			v := arg(cx, e, 0)
			if v.kind != .Nodes { cx.err = true; return {} }
			return {kind = .Num, n = f64(len(v.nodes))}
		}
	case "string":        if want(cx, e, 0, 1) { return {kind = .Str, s = x_string(cx, arg(cx, e, 0))} }
	case "string-length": if want(cx, e, 0, 1) { return {kind = .Num, n = f64(strings.rune_count(x_string(cx, arg(cx, e, 0))))} }
	case "normalize-space":
		if want(cx, e, 0, 1) { return {kind = .Str, s = strings.join(strings.fields(x_string(cx, arg(cx, e, 0)), context.temp_allocator), " ", context.temp_allocator)} }
	case "contains":    if want(cx, e, 2, 2) { return {kind = .Bool, b = strings.contains(x_string(cx, arg(cx, e, 0)), x_string(cx, arg(cx, e, 1)))} }
	case "starts-with": if want(cx, e, 2, 2) { return {kind = .Bool, b = strings.has_prefix(x_string(cx, arg(cx, e, 0)), x_string(cx, arg(cx, e, 1)))} }
	case "concat":
		if want(cx, e, 2, max(int)) {
			b := strings.builder_make(context.temp_allocator)
			for i in 0 ..< len(e.kids) { strings.write_string(&b, x_string(cx, arg(cx, e, i))) }
			return {kind = .Str, s = strings.to_string(b)}
		}
	case "name", "local-name":
		if want(cx, e, 0, 1) {
			v := arg(cx, e, 0)
			if v.kind != .Nodes { cx.err = true; return {} }
			if len(v.nodes) == 0 { return {kind = .Str} }
			it := v.nodes[0]
			n := get(cx.d, it.node)
			if n == nil { return {kind = .Str} }
			return {kind = .Str, s = it.attr >= 0 ? n.attrs[it.attr].name : n.name}
		}
	case: cx.err = true
	}
	return {}
}

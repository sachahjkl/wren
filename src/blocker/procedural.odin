package blocker

import "core:strconv"
import "core:strings"
import "wb:adblock"
import "wb:base"
import "wb:dom"
import "wb:page"

// Procedural cosmetic selectors, evaluated natively on the document (not through JavaScript): a CSS selector followed by
// operators that look at what CSS cannot see (`div:has-text(Ad):upward(2)`), the way uBlock Origin's extended selectors
// work. A selector is a chain of tasks; each one filters or moves the current set of elements:
//
//   css           a plain selector: the first one searches the document, a later one (written with a leading combinator or
//                 as a descendant) searches relative to each element of the set
//   :has-text(x) / :contains(x) / :-abp-contains(x)    the text content matches x (text, or /regex/flags)
//   :has(sel) / :-abp-has(sel)         some descendant matches sel (which may itself be procedural)
//   :not(sel)                          the element does not match sel (procedural when sel is)
//   :matches-css(prop: value)          the computed value of prop matches value (text with *, or /regex/)
//   :matches-attr("name"="value")      an attribute matches
//   :matches-path(x)                   the page's path (and query) matches x
//   :min-text-length(n)                the text is at least n characters long
//   :upward(n | sel)                   move to the n-th ancestor, or to the nearest ancestor matching sel
//   :nth-ancestor(n)                   move to the n-th ancestor
//   :remove()                          the result is removed from the document, not just hidden
//   :style(css)                        the result gets this CSS (important) instead of being hidden

Task_Kind :: enum u8 {
	Css, Has_Text, Has, Not, Matches_Css, Matches_Attr, Matches_Path, Min_Text_Length, Upward_N, Upward_Sel, Nth_Ancestor, Remove, Style,
}

Task :: struct {
	kind: Task_Kind,
	arg:  string,            // owned
	n:    int,
	sub:  ^Proc_Selector,    // Has / Not with procedural content
	re:   ^adblock.Regex,    // a /regex/ argument, compiled once
}

Proc_Selector :: struct {
	tasks:  [dynamic]Task,
	remove: bool,
	style:  string,          // owned: :style(...) declarations
}

proc_destroy :: proc(s: ^Proc_Selector) {
	if s == nil { return }
	for &t in s.tasks {
		delete(t.arg)
		if t.sub != nil { proc_destroy(t.sub); free(t.sub) }
		if t.re != nil { adblock.regex_destroy(t.re); free(t.re) }
	}
	delete(s.tasks)
	delete(s.style)
	s^ = {}
}

@(private)
PROC_OPS := [?]struct { name: string, kind: Task_Kind }{
	{":has-text(", .Has_Text}, {":contains(", .Has_Text}, {":-abp-contains(", .Has_Text},
	{":matches-css(", .Matches_Css}, {":matches-attr(", .Matches_Attr}, {":matches-path(", .Matches_Path},
	{":min-text-length(", .Min_Text_Length}, {":upward(", .Upward_N}, {":nth-ancestor(", .Nth_Ancestor},
	{":-abp-has(", .Has}, {":has(", .Has}, {":not(", .Not}, {":remove(", .Remove}, {":style(", .Style},
}

// Index of the ')' that closes the '(' at `open` (quotes and nesting respected), or -1.
@(private)
close_paren :: proc(s: string, open: int) -> int {
	depth := 0
	quote: u8 = 0
	for i := open; i < len(s); i += 1 {
		c := s[i]
		if quote != 0 { if c == '\\' { i += 1 } else if c == quote { quote = 0 }; continue }
		switch c {
		case '"', '\'': quote = c
		case '\\': i += 1
		case '(': depth += 1
		case ')': depth -= 1; if depth == 0 { return i }
		}
	}
	return -1
}

// Does a selector need the DOM evaluator? (`:has()` and `:not()` only when what is inside does.)
needs_procedural :: proc(sel: string) -> bool {
	for op in PROC_OPS {
		if op.kind == .Has || op.kind == .Not { continue }
		if strings.contains(sel, op.name) { return true }
	}
	for op in ([]string{":has(", ":-abp-has(", ":not("}) {
		at := 0
		for {
			i := strings.index(sel[at:], op)
			if i < 0 { break }
			i += at
			open := i + len(op) - 1
			end := close_paren(sel, open)
			if end < 0 { break }
			if op == ":-abp-has(" || needs_procedural(sel[open + 1:end]) { return true }
			at = end
		}
	}
	return false
}

proc_parse :: proc(text: string) -> (s: ^Proc_Selector, ok: bool) {
	s = new(Proc_Selector)
	css := strings.builder_make(context.temp_allocator)
	flush :: proc(s: ^Proc_Selector, css: ^strings.Builder) {
		t := strings.trim_space(strings.to_string(css^))
		if t != "" { append(&s.tasks, Task{kind = .Css, arg = strings.clone(t)}) }
		strings.builder_reset(css)
	}
	i := 0
	for i < len(text) {
		matched := false
		if text[i] == ':' {
			for op in PROC_OPS {
				if !strings.has_prefix(text[i:], op.name) { continue }
				open := i + len(op.name) - 1
				end := close_paren(text, open)
				if end < 0 { proc_destroy(s); free(s); return nil, false }
				arg := text[open + 1:end]
				if (op.kind == .Has && !needs_procedural(arg) && op.name == ":has(") || (op.kind == .Not && !needs_procedural(arg)) { break }   // plain CSS: left in the selector
				flush(s, &css)
				t := Task{kind = op.kind, arg = strings.clone(strings.trim_space(arg))}
				switch op.kind {
				case .Has, .Not:
					sub, sok := proc_parse(arg)
					if !sok { delete(t.arg); proc_destroy(s); free(s); return nil, false }
					t.sub = sub
				case .Upward_N:
					if n, nok := strconv.parse_int(t.arg); nok { t.n = n } else { t.kind = .Upward_Sel }
				case .Nth_Ancestor, .Min_Text_Length:
					n, nok := strconv.parse_int(t.arg)
					if !nok { delete(t.arg); proc_destroy(s); free(s); return nil, false }
					t.n = n
				case .Remove: s.remove = true
				case .Style: delete(s.style); s.style = strings.clone(t.arg)
				case .Has_Text, .Matches_Css, .Matches_Attr, .Matches_Path, .Upward_Sel, .Css:
				}
				if t.kind == .Has_Text || t.kind == .Matches_Path || t.kind == .Matches_Css || t.kind == .Matches_Attr {
					a := t.arg
					if len(a) > 2 && a[0] == '/' {
						if last := strings.last_index_byte(a, '/'); last > 0 {
							re, rok := adblock.regex_compile(a[1:last], strings.contains(a[last + 1:], "i"))
							if rok { t.re = new_clone(re) }
						}
					}
				}
				if op.kind != .Remove && op.kind != .Style { append(&s.tasks, t) } else { delete(t.arg) }
				i = end + 1
				matched = true
				break
			}
		}
		if !matched { strings.write_byte(&css, text[i]); i += 1 }
	}
	flush(s, &css)
	if len(s.tasks) == 0 || s.tasks[0].kind != .Css {
		// operators with no selector before them apply to every element
		if len(s.tasks) == 0 && !s.remove && s.style == "" { proc_destroy(s); free(s); return nil, false }
		inject := Task{kind = .Css, arg = strings.clone("*")}
		inject_at(&s.tasks, 0, inject)
	}
	return s, true
}

////////////////////////////////
// Evaluation

@(private)
Pattern :: struct { re: ^adblock.Regex, text: string }

@(private)
scratch: adblock.Regex_Scratch

@(private)
pattern_ok :: proc(t: ^Task, value: string) -> bool {
	if t.re != nil { return adblock.regex_match(t.re, &scratch, value) }
	return glob_match(t.arg, value)
}

// `*` matches any run; otherwise a substring test.
@(private)
glob_match :: proc(pat, v: string) -> bool {
	if !strings.contains_rune(pat, '*') { return strings.contains(v, pat) }
	parts := strings.split(pat, "*", context.temp_allocator)
	pos := 0
	for part, i in parts {
		if part == "" { continue }
		at := strings.index(v[pos:], part)
		if at < 0 { return false }
		if i == 0 && at != 0 && pat[0] != '*' { return false }
		pos += at + len(part)
	}
	return true
}

// The elements the selector selects in the page, in tree order.
proc_eval :: proc(p: ^page.Page, s: ^Proc_Selector, scope := base.NIL_HANDLE) -> []base.Handle {
	cur := make([dynamic]base.Handle, context.temp_allocator)
	started := false
	for &t in s.tasks {
		switch t.kind {
		case .Css:
			text := t.arg
			if !started {
				found, ok := page.select_all(p, text, scope)
				if !ok { return nil }
				append(&cur, ..found)
				started = true
			} else {
				next := make([dynamic]base.Handle, context.temp_allocator)
				for el in cur { relative(p, el, text, &next) }
				cur = next
			}
		case .Has_Text:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool { return pattern_ok(t, dom.text_content(p.doc, el)) }, &t)
		case .Min_Text_Length:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool { return len(dom.text_content(p.doc, el)) >= t.n }, &t)
		case .Matches_Path:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool {
				loc := &p.env.location
				path := loc.path
				if loc.has_query { path = strings.concatenate({path, "?", loc.query}, context.temp_allocator) }
				return pattern_ok(t, path)
			}, &t)
		case .Matches_Css:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool {
				c := strings.index_byte(t.arg, ':')
				if c < 0 { return false }
				prop := strings.trim_space(t.arg[:c])
				pat := strings.trim_space(t.arg[c + 1:])
				val := page.computed_property(p, el, prop)
				tt := Task{arg = pat}
				if len(pat) > 2 && pat[0] == '/' { tt.re = t.re } else { tt.re = nil }
				if tt.re == nil { return glob_equal(pat, val) }
				return pattern_ok(&tt, val)
			}, &t)
		case .Matches_Attr:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool {
				// "name"="value" (either side may be a pattern with *)
				a := t.arg
				eq := strings.index(a, "=")
				name, want := strings.trim(a, "\" "), ""
				if eq >= 0 { name, want = strings.trim(a[:eq], "\" "), strings.trim(a[eq + 1:], "\" ") }
				n := dom.get(p.doc, el)
				if n == nil { return false }
				for at in n.attrs { if glob_equal(name, at.name) && (eq < 0 || glob_equal(want, at.value)) { return true } }
				return false
			}, &t)
		case .Has:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool {
				if t.sub != nil { return len(proc_eval(p, t.sub, el)) > 0 }
				found, ok := page.select_all(p, t.arg, el)
				return ok && len(found) > 0
			}, &t)
		case .Not:
			filter(p, &cur, proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool {
				if t.sub != nil {
					for h in proc_eval(p, t.sub) { if h == el { return false } }
					return true
				}
				return !page.element_matches(p, el, t.arg)
			}, &t)
		case .Upward_N, .Nth_Ancestor:
			next := make([dynamic]base.Handle, context.temp_allocator)
			for el in cur {
				a := el
				for _ in 0 ..< t.n {
					n := dom.get(p.doc, a)
					if n == nil || n.parent == base.NIL_HANDLE { a = base.NIL_HANDLE; break }
					a = n.parent
				}
				if a != base.NIL_HANDLE { if an := dom.get(p.doc, a); an != nil && an.kind == .Element { append(&next, a) } }
			}
			cur = next
		case .Upward_Sel:
			next := make([dynamic]base.Handle, context.temp_allocator)
			for el in cur {
				a := dom.get(p.doc, el).parent
				for a != base.NIL_HANDLE {
					an := dom.get(p.doc, a)
					if an == nil { break }
					if an.kind == .Element && page.element_matches(p, a, t.arg) { append(&next, a); break }
					a = an.parent
				}
			}
			cur = next
		case .Remove, .Style:
		}
		if len(cur) == 0 && started { break }
	}
	// unique, in order
	seen := make(map[base.Handle]struct{}, len(cur), context.temp_allocator)
	out := make([dynamic]base.Handle, context.temp_allocator)
	for h in cur { if h not_in seen { seen[h] = {}; append(&out, h) } }
	return out[:]
}

@(private)
glob_equal :: proc(pat, v: string) -> bool {
	if !strings.contains_rune(pat, '*') { return pat == v }
	parts := strings.split(pat, "*", context.temp_allocator)
	pos := 0
	for part, i in parts {
		if part == "" { continue }
		at := strings.index(v[pos:], part)
		if at < 0 { return false }
		if i == 0 && at != 0 { return false }
		pos += at + len(part)
	}
	return pat[len(pat) - 1] == '*' || strings.has_suffix(v, parts[len(parts) - 1])
}

@(private)
filter :: proc(p: ^page.Page, cur: ^[dynamic]base.Handle, f: proc(p: ^page.Page, el: base.Handle, t: ^Task) -> bool, t: ^Task) {
	w := 0
	for el in cur^ {
		if f(p, el, t) { cur[w] = el; w += 1 }
	}
	resize(cur, w)
}

// The elements `text` selects relative to `el`: ` x` descendants, `> x` children, `+ x` / `~ x` following siblings.
@(private)
relative :: proc(p: ^page.Page, el: base.Handle, text: string, out: ^[dynamic]base.Handle) {
	t := strings.trim_space(text)
	if t == "" { return }
	switch t[0] {
	case '+', '~':
		sel := strings.trim_space(t[1:])
		n := dom.get(p.doc, el)
		for s := n.next; s != base.NIL_HANDLE; {
			sn := dom.get(p.doc, s)
			if sn == nil { break }
			if sn.kind == .Element {
				if page.element_matches(p, s, sel) { append(out, s) }
				if t[0] == '+' { break }
			}
			s = sn.next
		}
	case '>':
		found, ok := page.select_all(p, strings.concatenate({":scope ", t}, context.temp_allocator), el)
		if ok { append(out, ..found) }
	case:
		found, ok := page.select_all(p, t, el)
		if ok { append(out, ..found) }
	}
}

_ :: Pattern

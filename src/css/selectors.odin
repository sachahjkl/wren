package css

import "core:fmt"
import "core:strconv"
import "core:strings"

// Selectors Level 4 (the parts that make sense for a document without namespaces) and CSS Nesting's `&`.

Combinator :: enum u8 { Descendant, Child, Next_Sibling, Subsequent_Sibling }

Simple_Kind :: enum u8 { Type, Universal, Id, Class, Attribute, Pseudo_Class, Nesting }

Attr_Op :: enum u8 { Exists, Equals, Includes, Dash_Match, Prefix, Suffix, Substring }

Pseudo :: enum u8 {
	None,
	// structural
	Root, Empty, First_Child, Last_Child, Only_Child, First_Of_Type, Last_Of_Type, Only_Of_Type,
	Nth_Child, Nth_Last_Child, Nth_Of_Type, Nth_Last_Of_Type,
	// logical
	Not, Is, Where, Has,
	// user action / state
	Hover, Active, Focus, Focus_Visible, Focus_Within, Link, Any_Link, Visited, Target,
	Checked, Disabled, Enabled, Required, Optional, Read_Only, Read_Write, Placeholder_Shown,
	Valid, Invalid, User_Valid, User_Invalid, In_Range, Out_Of_Range, Indeterminate, Default, Autofill,
	// other
	Lang, Dir, Scope, Defined, Open,
	Never,          // valid, but matches nothing in this engine's documents: :popover-open, :fullscreen...
	// shadow trees (CSS Scoping): :host, :host(<compound>) (argument in `list`), :host-context(<compound>); :state(x)
	// (a custom element's custom state, ElementInternals.states; the name in `name`); :has-slotted
	Host, Host_Context, State, Has_Slotted,
	// pseudo-elements
	Before, After, First_Line, First_Letter, Selection, Placeholder, Marker, Backdrop,
	Slotted,        // ::slotted(<compound>): the argument in Complex.slotted
	Part,           // ::part(<ident>+): the names in Complex.parts
	Other_Element,  // a valid pseudo-element that generates nothing here (::file-selector-button, ::-webkit-*...)
}

Simple :: struct {
	kind:   Simple_Kind,
	name:   string,      // Type (lower case), Class, Id, Attribute name (lower case), Lang/Dir argument
	pseudo: Pseudo,
	op:     Attr_Op,
	value:  string,
	ci:     bool,        // attribute value compared case-insensitively
	nth_a, nth_b: int,   // An+B
	list:   ^Selector_List,   // :not :is :where :has :host() :host-context(), `of S` of nth-child, the parent list for `&`;
	                          // a ::slotted() being parsed: its argument
	names:  []string,         // a ::part() being parsed: its names
}

Compound :: struct { simples: []Simple }

Complex :: struct {
	compounds:      []Compound,       // left to right
	combinators:    []Combinator,     // combinators[i] sits between compounds[i] and compounds[i+1]
	leading:        Combinator,       // relative selectors (inside :has): how the subject relates to the anchor
	relative:       bool,
	pseudo_element: Pseudo,           // ::before etc., or .None
	specificity:    Specificity,
	// ::slotted(<compound>) and ::part(<ident>+): the compound the slotted element must match, the part names, the
	// pseudo-classes written after ::part() (they test the part), and a pseudo-element after either (::before...)
	slotted:        ^Compound,
	parts:          []string,
	part_state:     []Simple,
	then_pseudo:    Pseudo,
}

Selector_List :: []Complex

Specificity :: struct { a, b, c: u32 }

specificity_less :: proc(x, y: Specificity) -> bool {
	if x.a != y.a { return x.a < y.a }
	if x.b != y.b { return x.b < y.b }
	return x.c < y.c
}

specificity_add :: proc(x, y: Specificity) -> Specificity { return {x.a + y.a, x.b + y.b, x.c + y.c} }

////////////////////////////////
// Parsing

// Parses a selector list (invalid anywhere = invalid as a whole). `parent` is the enclosing rule's selectors for `&`.
parse_selector_list :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List) -> (list: Selector_List, ok: bool) {
	items := split_commas(vs, a)
	out := make([dynamic]Complex, a)
	for item in items {
		// inside a style rule a selector may start with a combinator, and means `& <selector>` unless it uses & itself
		c, good := parse_complex(trim_values(item), a, parent, parent != nil)
		if !good { return nil, false }
		if parent != nil { c = with_implicit_nesting(c, a, parent) }
		append(&out, c)
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

@(private)
with_implicit_nesting :: proc(c: Complex, a: Arena_Alloc, parent: ^Selector_List) -> Complex {
	for comp in c.compounds {
		for s in comp.simples { if s.kind == .Nesting { out := c; out.relative = false; return out } }
	}
	lst := new(Selector_List, a)
	lst^ = parent^
	first := make([]Simple, 1, a)
	first[0] = Simple{kind = .Nesting, list = lst}
	compounds := make([]Compound, len(c.compounds) + 1, a)
	combs := make([]Combinator, len(c.combinators) + 1, a)
	compounds[0] = Compound{first}
	combs[0] = c.leading
	for comp, i in c.compounds { compounds[i + 1] = comp }
	for cb, i in c.combinators { combs[i + 1] = cb }
	out := c
	out.compounds, out.combinators, out.relative, out.leading = compounds, combs, false, .Descendant
	out.specificity = complex_specificity(out)
	return out
}

// Forgiving list (:is, :where): invalid items are dropped, an empty list is valid and matches nothing.
@(private)
parse_forgiving_list :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, relative: bool) -> Selector_List {
	items := split_commas(vs, a)
	out := make([dynamic]Complex, a)
	for item in items {
		if c, good := parse_complex(trim_values(item), a, parent, relative); good { append(&out, c) }
	}
	return out[:]
}

split_commas :: proc(vs: []Value, a: Arena_Alloc) -> [][]Value {
	out := make([dynamic][]Value, a)
	start := 0
	for v, i in vs {
		if v.kind == .Token && v.tok.kind == .Comma { append(&out, vs[start:i]); start = i + 1 }
	}
	append(&out, vs[start:])
	return out[:]
}

@(private)
parse_complex :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, relative: bool) -> (c: Complex, ok: bool) {
	if len(vs) == 0 { return {}, false }
	compounds := make([dynamic]Compound, a)
	combs := make([dynamic]Combinator, a)
	i := 0
	c.relative = relative
	c.leading = .Descendant

	// a relative selector may start with a combinator
	if relative && i < len(vs) {
		if comb, is_comb := as_combinator(vs[i]); is_comb { c.leading = comb; i += 1; for i < len(vs) && is_ws_value(vs[i]) { i += 1 } }
	}
	pending: Maybe(Combinator)
	pseudo_not_last := false
	for i < len(vs) {
		if c.pseudo_element != .None { pseudo_not_last = true }
		if is_ws_value(vs[i]) {
			for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
			if len(compounds) > 0 && pending == nil && i < len(vs) {
				if _, is_comb := as_combinator(vs[i]); !is_comb { pending = .Descendant }
			}
			continue
		}
		if comb, is_comb := as_combinator(vs[i]); is_comb {
			if len(compounds) == 0 || pending != nil && pending.? != .Descendant { return {}, false }
			pending = comb
			i += 1
			continue
		}
		// a compound selector
		simples := make([dynamic]Simple, a)
		for i < len(vs) && !is_ws_value(vs[i]) {
			if _, is_comb := as_combinator(vs[i]); is_comb { break }
			s, pe, consumed, good := parse_simple(vs[i:], a, parent)
			if !good { return {}, false }
			i += consumed
			if pe != .None {
				// a pseudo-element must end the selector
				c.pseudo_element = pe
				if pe == .Slotted || pe == .Part {
					if pe == .Slotted {
						c.slotted = new(Compound, a)
						c.slotted^ = s.list^[0].compounds[0]
					} else {
						c.parts = s.names
					}
					// then pseudo-classes (of the part) and one tree-abiding pseudo-element
					state := make([dynamic]Simple, a)
					for i < len(vs) && !is_ws_value(vs[i]) {
						s2, pe2, n2, g2 := parse_simple(vs[i:], a, parent)
						if !g2 { return {}, false }
						i += n2
						if pe2 != .None {
							#partial switch pe2 {
							case .Before, .After, .Marker, .Placeholder, .Selection, .First_Line, .First_Letter:
							case: return {}, false
							}
							if c.then_pseudo != .None { return {}, false }
							c.then_pseudo = pe2
							continue
						}
						if s2.kind != .Pseudo_Class || c.then_pseudo != .None || pe == .Slotted { return {}, false }
						append(&state, s2)
					}
					c.part_state = state[:]
					break
				}
				for i < len(vs) && !is_ws_value(vs[i]) { // only user-action pseudo-classes may follow
					s2, _, n2, g2 := parse_simple(vs[i:], a, parent)
					if !g2 || s2.kind != .Pseudo_Class { return {}, false }
					append(&simples, s2)
					i += n2
				}
				break
			}
			append(&simples, s)
		}
		if len(simples) == 0 && c.pseudo_element == .None { return {}, false }
		if len(compounds) > 0 {
			append(&combs, pending.? if pending != nil else .Descendant)
		}
		pending = nil
		append(&compounds, Compound{simples[:]})
	}
	if pending != nil && pending.? != .Descendant { return {}, false }   // a dangling combinator
	if c.pseudo_element != .None && pseudo_not_last { return {}, false }   // a pseudo-element ends the selector
	if len(compounds) == 0 { return {}, false }
	c.compounds = compounds[:]
	c.combinators = combs[:]
	c.specificity = complex_specificity(c)
	return c, true
}

@(private)
as_combinator :: proc(v: Value) -> (Combinator, bool) {
	if v.kind == .Token && v.tok.kind == .Delim {
		switch v.tok.text {
		case ">": return .Child, true
		case "+": return .Next_Sibling, true
		case "~": return .Subsequent_Sibling, true
		}
	}
	return .Descendant, false
}

// One simple selector at the start of `vs`. Returns the pseudo-element when it is one (and `s` is then unused).
@(private)
parse_simple :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List) -> (s: Simple, pe: Pseudo, consumed: int, ok: bool) {
	v := vs[0]
	switch v.kind {
	case .Token:
		t := v.tok
		#partial switch t.kind {
		case .Ident: return Simple{kind = .Type, name = strings.to_lower(t.text, a)}, .None, 1, true
		case .Hash:
			if !t.is_id { return {}, .None, 0, false }
			return Simple{kind = .Id, name = t.text}, .None, 1, true
		case .Delim:
			switch t.text {
			case "*": return Simple{kind = .Universal}, .None, 1, true
			case "&":
				if parent == nil { return Simple{kind = .Nesting}, .None, 1, true }   // top-level &: matches :scope
				lst := new(Selector_List, a)
				lst^ = parent^
				return Simple{kind = .Nesting, list = lst}, .None, 1, true
			case ".":
				if len(vs) > 1 && vs[1].kind == .Token && vs[1].tok.kind == .Ident { return Simple{kind = .Class, name = vs[1].tok.text}, .None, 2, true }
			}
			return {}, .None, 0, false
		case .Colon:
			if len(vs) > 1 && vs[1].kind == .Token && vs[1].tok.kind == .Colon {
				// ::pseudo-element
				if len(vs) > 2 && vs[2].kind == .Token && vs[2].tok.kind == .Ident {
					if elem, good := pseudo_element_of(vs[2].tok.text); good { return {}, elem, 3, true }
				}
				if len(vs) > 2 && vs[2].kind == .Function {
					fname := strings.to_lower(vs[2].tok.text, context.temp_allocator)
					switch fname {
					case "slotted":
						// ::slotted(<compound-selector>)
						arg, good := parse_complex(trim_values(vs[2].children), a, nil, false)
						if !good || len(arg.compounds) != 1 || arg.pseudo_element != .None { return {}, .None, 0, false }
						lst := new(Selector_List, a)
						lst^ = make([]Complex, 1, a)
						lst^[0] = arg
						return Simple{list = lst}, .Slotted, 3, true
					case "part":
						// ::part(<ident>+)
						names := make([dynamic]string, a)
						for pv in vs[2].children {
							if is_ws_value(pv) { continue }
							if pv.kind != .Token || pv.tok.kind != .Ident { return {}, .None, 0, false }
							append(&names, strings.clone(pv.tok.text, a))
						}
						if len(names) == 0 { return {}, .None, 0, false }
						return Simple{names = names[:]}, .Part, 3, true
					}
					if functional_pseudo_element(vs[2]) { return {}, .Other_Element, 3, true }
				}
				return {}, .None, 0, false
			}
			if len(vs) > 1 && vs[1].kind == .Token && vs[1].tok.kind == .Ident {
				name := strings.to_lower(vs[1].tok.text, a)
				// legacy single-colon pseudo-elements
				switch name {
				case "before", "after", "first-line", "first-letter":
					elem, _ := pseudo_element_of(name)
					return {}, elem, 2, true
				}
				if p, good := simple_pseudo_class(name); good { return Simple{kind = .Pseudo_Class, pseudo = p}, .None, 2, true }
				return {}, .None, 0, false
			}
			if len(vs) > 1 && vs[1].kind == .Function {
				simple, good := parse_functional_pseudo(vs[1], a, parent)
				return simple, .None, 2, good
			}
			return {}, .None, 0, false
		}
		return {}, .None, 0, false
	case .Block:
		if v.tok.kind == .Open_Square { simple, good := parse_attribute(v.children, a); return simple, .None, 1, good }
		return {}, .None, 0, false
	case .Function:
		return {}, .None, 0, false
	}
	return {}, .None, 0, false
}

@(private)
pseudo_element_of :: proc(name: string) -> (Pseudo, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "before": return .Before, true
	case "after": return .After, true
	case "first-line": return .First_Line, true
	case "first-letter": return .First_Letter, true
	case "selection": return .Selection, true
	case "placeholder": return .Placeholder, true
	case "marker": return .Marker, true
	case "backdrop": return .Backdrop, true
	case "-webkit-input-placeholder": return .Placeholder, true
	case "file-selector-button", "details-content", "target-text", "spelling-error", "grammar-error", "search-text", "cue",
	     "view-transition", "checkmark", "picker-icon", "scroll-marker", "scroll-marker-group", "scroll-button", "column":
		return .Other_Element, true
	}
	// Blink accepts every -webkit- pseudo-element (its form controls' parts, scroll bars...): a sheet written for it keeps
	// its selector lists. They style parts this engine does not have.
	if len(name) > 8 && strings.equal_fold(name[:8], "-webkit-") { return .Other_Element, true }
	return .None, false
}

// ::part(), ::slotted(), ::highlight()...: valid functional pseudo-elements that match no box of this engine.
@(private)
functional_pseudo_element :: proc(f: Value) -> bool {
	switch strings.to_lower(f.tok.text, context.temp_allocator) {
	case "part", "slotted", "highlight", "cue", "cue-region", "picker", "view-transition-group", "view-transition-image-pair",
	     "view-transition-old", "view-transition-new", "scroll-button":
		return true
	}
	return false
}

@(private)
simple_pseudo_class :: proc(name: string) -> (Pseudo, bool) {
	switch name {
	case "root": return .Root, true
	case "empty": return .Empty, true
	case "first-child": return .First_Child, true
	case "last-child": return .Last_Child, true
	case "only-child": return .Only_Child, true
	case "first-of-type": return .First_Of_Type, true
	case "last-of-type": return .Last_Of_Type, true
	case "only-of-type": return .Only_Of_Type, true
	case "hover": return .Hover, true
	case "active": return .Active, true
	case "focus": return .Focus, true
	case "focus-visible": return .Focus_Visible, true
	case "focus-within": return .Focus_Within, true
	case "link": return .Link, true
	case "any-link": return .Any_Link, true
	case "visited": return .Visited, true
	case "target": return .Target, true
	case "checked": return .Checked, true
	case "disabled": return .Disabled, true
	case "enabled": return .Enabled, true
	case "required": return .Required, true
	case "optional": return .Optional, true
	case "read-only": return .Read_Only, true
	case "read-write": return .Read_Write, true
	case "placeholder-shown": return .Placeholder_Shown, true
	case "valid": return .Valid, true
	case "invalid": return .Invalid, true
	case "user-valid": return .User_Valid, true
	case "user-invalid": return .User_Invalid, true
	case "in-range": return .In_Range, true
	case "out-of-range": return .Out_Of_Range, true
	case "indeterminate": return .Indeterminate, true
	case "default": return .Default, true
	case "autofill", "-webkit-autofill": return .Autofill, true
	case "scope": return .Scope, true
	case "defined": return .Defined, true
	case "open": return .Open, true
	case "-webkit-any-link": return .Any_Link, true
	case "host": return .Host, true
	case "has-slotted": return .Has_Slotted, true
	case "popover-open", "modal", "fullscreen", "-webkit-full-screen", "picture-in-picture",
	     "playing", "paused", "seeking", "buffering", "stalled", "muted", "volume-locked", "current", "past", "future",
	     "target-current", "active-view-transition", "xr-overlay":
		return .Never, true
	}
	return .None, false
}

@(private)
parse_functional_pseudo :: proc(f: Value, a: Arena_Alloc, parent: ^Selector_List) -> (s: Simple, ok: bool) {
	name := strings.to_lower(f.tok.text, a)
	args := trim_values(f.children)
	s.kind = .Pseudo_Class
	switch name {
	case "not":
		lst, good := parse_selector_list(args, a, parent)
		if !good { return {}, false }
		s.pseudo = .Not
		s.list = new(Selector_List, a); s.list^ = lst
	case "is", "where", "-webkit-any", "matches", "-webkit-matches":
		s.pseudo = name == "where" ? .Where : .Is
		s.list = new(Selector_List, a); s.list^ = parse_forgiving_list(args, a, parent, false)
	case "host", "host-context":
		// :host(<compound-selector>), :host-context(<compound-selector>)
		arg, good := parse_complex(args, a, nil, false)
		if !good || len(arg.compounds) != 1 || arg.pseudo_element != .None { return {}, false }
		s.pseudo = name == "host" ? .Host : .Host_Context
		s.list = new(Selector_List, a)
		s.list^ = make([]Complex, 1, a)
		s.list^[0] = arg
	case "state":
		// :state(<ident>): a custom state of a custom element (ElementInternals.states)
		if len(args) != 1 || args[0].kind != .Token || args[0].tok.kind != .Ident { return {}, false }
		s.pseudo = .State
		s.name = strings.clone(args[0].tok.text, a)
	case "active-view-transition-type", "current":
		if len(args) == 0 { return {}, false }
		s.pseudo = .Never
	case "has":
		items := split_commas(args, a)
		out := make([dynamic]Complex, a)
		for item in items {
			c, good := parse_complex(trim_values(item), a, parent, true)
			if !good { return {}, false }
			append(&out, c)
		}
		s.pseudo = .Has
		s.list = new(Selector_List, a); s.list^ = out[:]
	case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
		// An+B [of S]
		of_idx := -1
		for v, i in args { if v.kind == .Token && v.tok.kind == .Ident && strings.equal_fold(v.tok.text, "of") { of_idx = i; break } }
		formula := args
		if of_idx >= 0 {
			if name == "nth-of-type" || name == "nth-last-of-type" { return {}, false }
			formula = trim_values(args[:of_idx])
			lst, good := parse_selector_list(trim_values(args[of_idx + 1:]), a, parent)
			if !good { return {}, false }
			s.list = new(Selector_List, a); s.list^ = lst
		}
		na, nb, good := parse_nth(formula)
		if !good { return {}, false }
		s.nth_a, s.nth_b = na, nb
		switch name {
		case "nth-child": s.pseudo = .Nth_Child
		case "nth-last-child": s.pseudo = .Nth_Last_Child
		case "nth-of-type": s.pseudo = .Nth_Of_Type
		case "nth-last-of-type": s.pseudo = .Nth_Last_Of_Type
		}
	case "lang":
		s.pseudo = .Lang
		for v in args { if v.kind == .Token && (v.tok.kind == .Ident || v.tok.kind == .String) { s.name = strings.to_lower(v.tok.text, a); break } }
		if s.name == "" { return {}, false }
	case "dir":
		s.pseudo = .Dir
		if len(args) == 1 && args[0].kind == .Token && args[0].tok.kind == .Ident { s.name = strings.to_lower(args[0].tok.text, a) } else { return {}, false }
	case: return {}, false
	}
	return s, true
}

// An+B microsyntax, from the tokens' text.
@(private)
parse_nth :: proc(vs: []Value) -> (a, b: int, ok: bool) {
	sb := strings.builder_make(context.temp_allocator)
	for v in vs {
		if v.kind != .Token { return 0, 0, false }
		t := v.tok
		#partial switch t.kind {
		case .Whitespace:
		case .Ident: strings.write_string(&sb, t.text)
		case .Number:
			if t.is_int { if t.has_sign && t.num >= 0 { strings.write_byte(&sb, '+') }; fmt.sbprintf(&sb, "%d", int(t.num)) } else { return 0, 0, false }
		case .Dimension:
			if !t.is_int { return 0, 0, false }
			if t.has_sign && t.num >= 0 { strings.write_byte(&sb, '+') }
			fmt.sbprintf(&sb, "%d%s", int(t.num), t.text)
		case .Delim:
			if t.text == "+" || t.text == "-" { strings.write_string(&sb, t.text) } else { return 0, 0, false }
		case: return 0, 0, false
		}
	}
	s := strings.to_lower(strings.to_string(sb), context.temp_allocator)
	switch s {
	case "even": return 2, 0, true
	case "odd": return 2, 1, true
	}
	n := strings.index_byte(s, 'n')
	if n < 0 {
		v, good := strconv.parse_int(s, 10)
		return 0, v, good
	}
	coef := s[:n]
	switch coef {
	case "", "+": a = 1
	case "-": a = -1
	case:
		v, good := strconv.parse_int(coef, 10)
		if !good { return 0, 0, false }
		a = v
	}
	rest := s[n + 1:]
	if rest == "" { return a, 0, true }
	if rest[0] != '+' && rest[0] != '-' { return 0, 0, false }
	v, good := strconv.parse_int(rest[1:], 10)
	if !good { return 0, 0, false }
	return a, rest[0] == '-' ? -v : v, true
}

@(private)
parse_attribute :: proc(vs: []Value, a: Arena_Alloc) -> (s: Simple, ok: bool) {
	items := make([dynamic]Value, context.temp_allocator)
	for v in vs { if !is_ws_value(v) { append(&items, v) } }
	if len(items) == 0 || items[0].kind != .Token || items[0].tok.kind != .Ident { return {}, false }
	s.kind = .Attribute
	s.name = strings.to_lower(items[0].tok.text, a)
	if len(items) == 1 { s.op = .Exists; return s, true }

	// the operator: one delimiter optionally followed by '=', or '=' alone
	i := 1
	op_tok := items[i]
	if op_tok.kind != .Token || op_tok.tok.kind != .Delim { return {}, false }
	switch op_tok.tok.text {
	case "=": s.op = .Equals; i += 1
	case "~", "|", "^", "$", "*":
		if i + 1 >= len(items) || items[i + 1].kind != .Token || items[i + 1].tok.kind != .Delim || items[i + 1].tok.text != "=" { return {}, false }
		switch op_tok.tok.text {
		case "~": s.op = .Includes
		case "|": s.op = .Dash_Match
		case "^": s.op = .Prefix
		case "$": s.op = .Suffix
		case "*": s.op = .Substring
		}
		i += 2
	case: return {}, false
	}
	if i >= len(items) || items[i].kind != .Token { return {}, false }
	val := items[i].tok
	if val.kind != .Ident && val.kind != .String { return {}, false }
	s.value = strings.clone(val.text, a)
	i += 1
	if i < len(items) {
		if items[i].kind == .Token && items[i].tok.kind == .Ident {
			switch strings.to_lower(items[i].tok.text, context.temp_allocator) {
			case "i": s.ci = true
			case "s": s.ci = false
			case: return {}, false
			}
			i += 1
		}
	}
	return s, i == len(items)
}

////////////////////////////////
// Specificity

@(private)
complex_specificity :: proc(c: Complex) -> Specificity {
	sp: Specificity
	for comp in c.compounds {
		for s in comp.simples { sp = specificity_add(sp, simple_specificity(s)) }
	}
	if c.pseudo_element != .None { sp.c += 1 }
	// ::slotted(): a pseudo-element plus its argument; ::part(): a pseudo-element plus what follows it
	if c.slotted != nil { for s in c.slotted.simples { sp = specificity_add(sp, simple_specificity(s)) } }
	for s in c.part_state { sp = specificity_add(sp, simple_specificity(s)) }
	if c.then_pseudo != .None { sp.c += 1 }
	return sp
}

@(private)
list_max_specificity :: proc(l: ^Selector_List) -> Specificity {
	m: Specificity
	if l == nil { return m }
	for c in l^ { if specificity_less(m, c.specificity) { m = c.specificity } }
	return m
}

@(private)
simple_specificity :: proc(s: Simple) -> Specificity {
	switch s.kind {
	case .Id: return {1, 0, 0}
	case .Class, .Attribute: return {0, 1, 0}
	case .Type: return {0, 0, 1}
	case .Universal: return {}
	case .Nesting: return list_max_specificity(s.list)
	case .Pseudo_Class:
		#partial switch s.pseudo {
		case .Where: return {}
		case .Is, .Not, .Has: return list_max_specificity(s.list)
		case .Host, .Host_Context:
			// a pseudo-class, plus its argument
			sp := Specificity{0, 1, 0}
			if s.list != nil { sp = specificity_add(sp, list_max_specificity(s.list)) }
			return sp
		case .Nth_Child, .Nth_Last_Child:
			sp := Specificity{0, 1, 0}
			if s.list != nil { sp = specificity_add(sp, list_max_specificity(s.list)) }
			return sp
		}
		return {0, 1, 0}
	}
	return {}
}

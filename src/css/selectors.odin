package css

import "core:fmt"
import "core:strings"
import "wb:base"

NESTING_SCAN_MAX_DEPTH :: 64   // the selectors within selectors searched for `&`

// Selectors Level 4, CSS Nesting's `&` and CSS Namespaces' prefixes (a sheet's @namespace rules).

Combinator :: enum u8 { Descendant, Child, Next_Sibling, Subsequent_Sibling }

// The namespace a type or universal selector asks for: any (no prefix without a default namespace, or `*|`), none
// (`|`), one the DOM tells apart, or another (Other: it matches no element, the DOM keeping no other namespace's URL).
Ns_Match :: enum u8 { Any, None, HTML, SVG, MathML, Other }

NS_HTML   :: "http://www.w3.org/1999/xhtml"
NS_SVG    :: "http://www.w3.org/2000/svg"
NS_MATHML :: "http://www.w3.org/1998/Math/MathML"

Ns_Prefix :: struct { prefix, url: string }

// A sheet's @namespace rules (CSS Namespaces 3 §3): the default namespace of its type selectors, and its prefixes.
Namespaces :: struct {
	has_default: bool,
	default_url: string,
	prefixes:    [dynamic]Ns_Prefix,   // (in the sheet's memory)
}

ns_match_of :: proc(url: string) -> Ns_Match {
	switch url {
	case "": return .None
	case NS_HTML: return .HTML
	case NS_SVG: return .SVG
	case NS_MATHML: return .MathML
	}
	return .Other
}

// The URL a prefix names (prefixes are case-sensitive); false when the sheet declares no such prefix.
namespace_url :: proc(ns: ^Namespaces, prefix: string) -> (string, bool) {
	if ns == nil { return "", false }
	#reverse for p in ns.prefixes { if p.prefix == prefix { return p.url, true } }   // (the last declaration wins)
	return "", false
}

// What an unprefixed type or universal selector asks for.
@(private)
default_ns :: proc(ns: ^Namespaces) -> Ns_Match { return ns != nil && ns.has_default ? ns_match_of(ns.default_url) : .Any }

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
	Hover, Active, Focus, Focus_Visible, Focus_Within, Link, Any_Link, Visited, Target, Fullscreen,
	Checked, Disabled, Enabled, Required, Optional, Read_Only, Read_Write, Placeholder_Shown,
	Valid, Invalid, User_Valid, User_Invalid, In_Range, Out_Of_Range, Indeterminate, Default, Autofill,
	Modal,          // a dialog shown by showModal()
	Modal_Active,   // -wren-modal-active: the root, while a modal dialog makes the rest of the document inert (the UA sheet)
	Popover_Open,   // a popover that is showing (HTML: the page's popover state, through the style engine's control provider)
	// other
	Lang, Dir, Scope, Defined, Open,
	Never,          // valid, but matches nothing in this engine's documents: :modal, :picture-in-picture...
	// shadow trees (CSS Scoping): :host, :host(<compound>) (argument in `list`), :host-context(<compound>); :state(x)
	// (a custom element's custom state, ElementInternals.states; the name in `name`); :has-slotted
	Host, Host_Context, State, Has_Slotted,
	// pseudo-elements
	Before, After, First_Line, First_Letter, Selection, Placeholder, Marker, Backdrop,
	Slotted,        // ::slotted(<compound>): the argument in Complex.slotted
	Part,           // ::part(<ident>+): the names in Complex.parts
	Other_Element,  // a valid pseudo-element that generates nothing here (::file-selector-button, ::-webkit-*...)
}

CLASS_HASH_BASIS :: 2166136261
CLASS_HASH_PRIME :: 16777619

Simple :: struct {
	kind:   Simple_Kind,
	name:   string,      // Type (lower case), Class, Id, Attribute name (lower case), Lang/Dir argument
	pseudo: Pseudo,
	op:     Attr_Op,
	value:  string,
	ci:     bool,        // attribute value compared case-insensitively
	ns:     Ns_Match,    // Type, Universal: the element's namespace
	hash:   u32,         // Class: class_hash(name)
	nth_a, nth_b: int,   // An+B
	list:   ^Selector_List,   // :not :is :where :has :host() :host-context(), `of S` of nth-child, the parent list for `&`;
	                          // a ::slotted() being parsed: its argument
	names:  []string,         // a ::part() being parsed: its names
}

// What a class name hashes to, in a selector and on an element (style.class_bits_fill). Not 0: 0 is no hash.
class_hash :: proc(name: string) -> u32 {
	h := u32(CLASS_HASH_BASIS)
	for i in 0 ..< len(name) { h = (h ~ u32(name[i])) * CLASS_HASH_PRIME }
	return h != 0 ? h : 1
}

Compound :: struct { simples: []Simple }

// What a selector's lists start with, in the sheet's memory, which keeps what they outgrow: the default of eight made a
// rule of `.a .b` hold about 3 KB, most of a sheet's memory, its pages touched once.
COMPOUNDS_RESERVE :: 3
SIMPLES_RESERVE :: 2

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
parse_selector_list :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, ns: ^Namespaces = nil) -> (list: Selector_List, ok: bool) {
	items := split_commas(vs, a)
	out := make([dynamic]Complex, 0, len(items), a)
	for item in items {
		// inside a style rule a selector may start with a combinator, and means `& <selector>` when it does or does not use &
		c, good := parse_complex(trim_values(item), a, parent, parent != nil, ns)
		if !good { return nil, false }
		if parent != nil { c = with_implicit_nesting(c, a, parent) }
		append(&out, c)
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

// A selector list inside a pseudo-class (:not(), :nth-child(... of S)): `&` resolves to the enclosing rule's selectors, but
// nothing is prepended (the implicit `& ` belongs to the rule's own selectors: `.x { &:not(.a) }` is `.x:not(.a)`).
@(private)
parse_inner_selector_list :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, ns: ^Namespaces) -> (list: Selector_List, ok: bool) {
	items := split_commas(vs, a)
	out := make([dynamic]Complex, 0, len(items), a)
	for item in items {
		c, good := parse_complex(trim_values(item), a, parent, false, ns)
		if !good { return nil, false }
		append(&out, c)
	}
	if len(out) == 0 { return nil, false }
	return out[:], true
}

// `&` anywhere in the selector, inside pseudo-class arguments too (`.bar:is(&)`)
@(private)
uses_nesting :: proc(c: Complex, depth := 0) -> bool {
	if depth > NESTING_SCAN_MAX_DEPTH { return false }
	for comp in c.compounds {
		for s in comp.simples {
			if s.kind == .Nesting { return true }
			if s.list != nil { for inner in s.list^ { if uses_nesting(inner, depth + 1) { return true } } }
		}
	}
	return false
}

@(private)
with_implicit_nesting :: proc(c: Complex, a: Arena_Alloc, parent: ^Selector_List) -> Complex {
	if c.leading == .Descendant && uses_nesting(c) { out := c; out.relative = false; return out }   // (no combinator first)
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
parse_forgiving_list :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, relative: bool, ns: ^Namespaces) -> Selector_List {
	items := split_commas(vs, a)
	out := make([dynamic]Complex, 0, len(items), a)
	for item in items {
		if c, good := parse_complex(trim_values(item), a, parent, relative, ns); good { append(&out, c) }
	}
	return out[:]
}

split_commas :: proc(vs: []Value, a: Arena_Alloc) -> [][]Value {
	n := 1
	for v in vs { if v.kind == .Token && v.tok.kind == .Comma { n += 1 } }
	out := make([][]Value, n, a)
	start, k := 0, 0
	for v, i in vs {
		if v.kind == .Token && v.tok.kind == .Comma { out[k] = vs[start:i]; k += 1; start = i + 1 }
	}
	out[k] = vs[start:]
	return out
}

@(private)
parse_complex :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, relative: bool, ns: ^Namespaces) -> (c: Complex, ok: bool) {
	if len(vs) == 0 { return {}, false }
	compounds := make([dynamic]Compound, 0, COMPOUNDS_RESERVE, a)
	combs := make([dynamic]Combinator, 0, COMPOUNDS_RESERVE, a)
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
		simples := make([dynamic]Simple, 0, SIMPLES_RESERVE, a)
		for i < len(vs) && !is_ws_value(vs[i]) {
			if _, is_comb := as_combinator(vs[i]); is_comb { break }
			s, pe, consumed, good := parse_simple(vs[i:], a, parent, ns)
			if !good { return {}, false }
			if (s.kind == .Type || s.kind == .Universal) && len(simples) > 0 && pe == .None { return {}, false }   // a type selector comes first (&div)
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
						s2, pe2, n2, g2 := parse_simple(vs[i:], a, parent, ns)
						if !g2 { return {}, false }
						i += n2
						if pe2 != .None {
							#partial switch pe2 {
							case .Before, .After, .Marker, .Placeholder, .Selection, .First_Line, .First_Letter, .Backdrop:
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
					s2, _, n2, g2 := parse_simple(vs[i:], a, parent, ns)
					if !g2 || s2.kind != .Pseudo_Class { return {}, false }
					append(&simples, s2)
					i += n2
				}
				break
			}
			append(&simples, s)
		}
		if len(simples) == 0 && c.pseudo_element == .None { return {}, false }
		// a default namespace holds for a compound without a type selector too (CSS Namespaces §3: `.c` is `*.c`)
		if m := default_ns(ns); m != .Any && (len(simples) == 0 || simples[0].kind != .Type && simples[0].kind != .Universal) {
			inject_at(&simples, 0, Simple{kind = .Universal, ns = m})
		}
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
is_delim :: proc(v: Value, text: string) -> bool { return v.kind == .Token && v.tok.kind == .Delim && v.tok.text == text }

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
parse_simple :: proc(vs: []Value, a: Arena_Alloc, parent: ^Selector_List, ns: ^Namespaces) -> (s: Simple, pe: Pseudo, consumed: int, ok: bool) {
	v := vs[0]
	switch v.kind {
	case .Token:
		t := v.tok
		#partial switch t.kind {
		case .Ident:
			// `prefix|name`, `prefix|*`: a prefix the sheet declares (querySelector has none: invalid there)
			if len(vs) > 2 && is_delim(vs[1], "|") && (vs[2].kind == .Token && vs[2].tok.kind == .Ident || is_delim(vs[2], "*")) {
				url, declared := namespace_url(ns, t.text)
				if !declared { return {}, .None, 0, false }
				if is_delim(vs[2], "*") { return Simple{kind = .Universal, ns = ns_match_of(url)}, .None, 3, true }
				return Simple{kind = .Type, name = base.ascii_lower_clone(vs[2].tok.text, a), ns = ns_match_of(url)}, .None, 3, true
			}
			return Simple{kind = .Type, name = base.ascii_lower_clone(t.text, a), ns = default_ns(ns)}, .None, 1, true
		case .Hash:
			if !t.is_id { return {}, .None, 0, false }
			return Simple{kind = .Id, name = t.text}, .None, 1, true
		case .Delim:
			switch t.text {
			case "*", "|":
				// `*|name` (any namespace), `|name` (no namespace), `*` (the default namespace) and `*|*`, `|*`; `name` may be `*`.
				if t.text == "*" && !(len(vs) > 2 && is_delim(vs[1], "|")) { return Simple{kind = .Universal, ns = default_ns(ns)}, .None, 1, true }
				at := t.text == "*" ? 2 : 1
				if at >= len(vs) || vs[at].kind != .Token { return {}, .None, 0, false }
				m: Ns_Match = t.text == "|" ? .None : .Any
				if vs[at].tok.kind == .Ident { return Simple{kind = .Type, name = base.ascii_lower_clone(vs[at].tok.text, a), ns = m}, .None, at + 1, true }
				if is_delim(vs[at], "*") { return Simple{kind = .Universal, ns = m}, .None, at + 1, true }
				return {}, .None, 0, false
			case "&":
				if parent == nil { return Simple{kind = .Nesting}, .None, 1, true }   // top-level &: matches :scope
				lst := new(Selector_List, a)
				lst^ = parent^
				return Simple{kind = .Nesting, list = lst}, .None, 1, true
			case ".":
				if len(vs) > 1 && vs[1].kind == .Token && vs[1].tok.kind == .Ident { return Simple{kind = .Class, name = vs[1].tok.text, hash = class_hash(vs[1].tok.text)}, .None, 2, true }
			}
			return {}, .None, 0, false
		case .Colon:
			if len(vs) > 1 && vs[1].kind == .Token && vs[1].tok.kind == .Colon {
				// ::pseudo-element
				if len(vs) > 2 && vs[2].kind == .Token && vs[2].tok.kind == .Ident {
					if elem, good := pseudo_element_of(vs[2].tok.text); good { return {}, elem, 3, true }
				}
				if len(vs) > 2 && vs[2].kind == .Function {
					fname := base.ascii_lower(vs[2].tok.text)
					switch fname {
					case "slotted":
						// ::slotted(<compound-selector>)
						arg, good := parse_complex(trim_values(vs[2].children), a, nil, false, ns)
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
				name := base.ascii_lower_clone(vs[1].tok.text, a)
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
				simple, good := parse_functional_pseudo(vs[1], a, parent, ns)
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
	switch base.ascii_lower(name) {
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
	if len(name) > 8 && base.ascii_equal_fold(name[:8], "-webkit-") { return .Other_Element, true }
	return .None, false
}

// ::part(), ::slotted(), ::highlight()...: valid functional pseudo-elements that match no box of this engine.
@(private)
functional_pseudo_element :: proc(f: Value) -> bool {
	switch base.ascii_lower(f.tok.text) {
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
	case "fullscreen", "-webkit-full-screen": return .Fullscreen, true
	case "popover-open": return .Popover_Open, true
	case "modal": return .Modal, true
	case "-wren-modal-active": return .Modal_Active, true
	case "picture-in-picture",
	     "playing", "paused", "seeking", "buffering", "stalled", "muted", "volume-locked", "current", "past", "future",
	     "target-current", "active-view-transition", "xr-overlay":
		return .Never, true
	}
	return .None, false
}

@(private)
parse_functional_pseudo :: proc(f: Value, a: Arena_Alloc, parent: ^Selector_List, ns: ^Namespaces) -> (s: Simple, ok: bool) {
	name := base.ascii_lower_clone(f.tok.text, a)
	args := trim_values(f.children)
	s.kind = .Pseudo_Class
	switch name {
	case "not":
		lst, good := parse_inner_selector_list(args, a, parent, ns)
		if !good { return {}, false }
		s.pseudo = .Not
		s.list = new(Selector_List, a); s.list^ = lst
	case "is", "where", "-webkit-any", "matches", "-webkit-matches":
		s.pseudo = name == "where" ? .Where : .Is
		s.list = new(Selector_List, a); s.list^ = parse_forgiving_list(args, a, parent, false, ns)
	case "host", "host-context":
		// :host(<compound-selector>), :host-context(<compound-selector>)
		arg, good := parse_complex(args, a, nil, false, ns)
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
			c, good := parse_complex(trim_values(item), a, parent, true, ns)
			if !good { return {}, false }
			append(&out, c)
		}
		s.pseudo = .Has
		s.list = new(Selector_List, a); s.list^ = out[:]
	case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
		// An+B [of S]
		of_idx := -1
		for v, i in args { if v.kind == .Token && v.tok.kind == .Ident && base.ascii_equal_fold(v.tok.text, "of") { of_idx = i; break } }
		formula := args
		if of_idx >= 0 {
			if name == "nth-of-type" || name == "nth-last-of-type" { return {}, false }
			formula = trim_values(args[:of_idx])
			lst, good := parse_inner_selector_list(trim_values(args[of_idx + 1:]), a, parent, ns)
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
		for v in args { if v.kind == .Token && (v.tok.kind == .Ident || v.tok.kind == .String) { s.name = base.ascii_lower_clone(v.tok.text, a); break } }
		if s.name == "" { return {}, false }
	case "dir":
		s.pseudo = .Dir
		if len(args) == 1 && args[0].kind == .Token && args[0].tok.kind == .Ident { s.name = base.ascii_lower_clone(args[0].tok.text, a) } else { return {}, false }
	case: return {}, false
	}
	return s, true
}

// A and B are kept within ±NTH_LIMIT (as Blink clamps them to 32 bits): beyond, no element index can tell the
// difference, and `index - B` and `(index - B) / A` cannot overflow (min(int) / -1 traps).
NTH_LIMIT :: 1 << 31

@(private)
nth_clamp :: proc(num: f64) -> int { return int(clamp(num, -NTH_LIMIT, NTH_LIMIT)) }

// Optionally signed decimal digits (no separators), saturated at ±NTH_LIMIT.
@(private)
nth_int :: proc(s: string) -> (int, bool) {
	t := s
	neg := false
	if len(t) > 0 && (t[0] == '+' || t[0] == '-') { neg = t[0] == '-'; t = t[1:] }
	if len(t) == 0 { return 0, false }
	v := 0
	for c in transmute([]u8)t {
		if c < '0' || c > '9' { return 0, false }
		v = min(v * 10 + int(c - '0'), NTH_LIMIT)
	}
	return neg ? -v : v, true
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
			if t.is_int { if t.has_sign && t.num >= 0 { strings.write_byte(&sb, '+') }; fmt.sbprintf(&sb, "%d", nth_clamp(t.num)) } else { return 0, 0, false }
		case .Dimension:
			if !t.is_int { return 0, 0, false }
			if t.has_sign && t.num >= 0 { strings.write_byte(&sb, '+') }
			fmt.sbprintf(&sb, "%d%s", nth_clamp(t.num), t.text)
		case .Delim:
			if t.text == "+" || t.text == "-" { strings.write_string(&sb, t.text) } else { return 0, 0, false }
		case: return 0, 0, false
		}
	}
	s := base.ascii_lower(strings.to_string(sb))
	switch s {
	case "even": return 2, 0, true
	case "odd": return 2, 1, true
	}
	n := strings.index_byte(s, 'n')
	if n < 0 {
		v, good := nth_int(s)
		return 0, v, good
	}
	coef := s[:n]
	switch coef {
	case "", "+": a = 1
	case "-": a = -1
	case:
		v, good := nth_int(coef)
		if !good { return 0, 0, false }
		a = v
	}
	rest := s[n + 1:]
	if rest == "" { return a, 0, true }
	if rest[0] != '+' && rest[0] != '-' { return 0, 0, false }
	v, good := nth_int(rest[1:])
	if !good { return 0, 0, false }
	return a, rest[0] == '-' ? -v : v, true
}

@(private)
parse_attribute :: proc(vs: []Value, a: Arena_Alloc) -> (s: Simple, ok: bool) {
	all := make([dynamic]Value, context.temp_allocator)
	for v in vs { if !is_ws_value(v) { append(&all, v) } }
	// a namespace prefix: `*|` (any namespace) and `|` (none) name the attributes as stored (a prefix in their name)
	items := all[:]
	if len(items) > 2 && is_delim(items[0], "*") && is_delim(items[1], "|") { items = items[2:] } else if len(items) > 1 && is_delim(items[0], "|") { items = items[1:] }
	if len(items) == 0 || items[0].kind != .Token || items[0].tok.kind != .Ident { return {}, false }
	s.kind = .Attribute
	s.name = base.ascii_lower_clone(items[0].tok.text, a)
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
			switch base.ascii_lower(items[i].tok.text) {
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

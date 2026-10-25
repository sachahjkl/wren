package style

import "base:runtime"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// CSS counters (CSS Lists 3 §4) and quotes (CSS Generated Content 3), resolved while a full style pass walks the document
// in tree order, so that `content.items` and `marker_text` are text ready to display. Counter styles are the predefined
// ones of CSS Counter Styles 3 (@counter-style rules are not implemented: an unknown name is decimal).
//
// Scopes: a counter instantiated on an element is visible to the element, its descendants and its following siblings
// with theirs; it disappears when the walk leaves the element's parent. ::before and ::after count as the first and last
// child of their element. HTML's `ol start`, `ol reversed` and `li value` act as presentational hints on list-item.

@(private)
Counter_Instance :: struct {
	name:     string,
	value:    i64,
	scope:    base.Handle,   // the parent of the element that created it: the instance dies when the walk leaves it
	reversed: bool,
}

Counter_State :: struct {
	stack:       [dynamic]Counter_Instance,
	quote_depth: int,
	used:        bool,   // some element used a counter or a quote: partial restyles must keep the values consistent
	max_listed:  int,    // counters(): the innermost instances listed at most (style.counters.max_listed)
}

counter_state_make :: proc(max_listed: int) -> Counter_State {
	return Counter_State{stack = make([dynamic]Counter_Instance, context.temp_allocator), max_listed = max(max_listed, 1)}
}

@(private)
innermost :: proc(st: ^Counter_State, name: string) -> int {
	for i := len(st.stack) - 1; i >= 0; i -= 1 { if st.stack[i].name == name { return i } }
	return -1
}

@(private)
instantiate :: proc(st: ^Counter_State, name: string, value: i64, scope: base.Handle, reversed: bool) -> int {
	// a counter created by a preceding sibling (same scope) is replaced, not nested
	if k := innermost(st, name); k >= 0 && st.stack[k].scope == scope {
		st.stack[k].value, st.stack[k].reversed = value, reversed
		return k
	}
	append(&st.stack, Counter_Instance{name = name, value = value, scope = scope, reversed = reversed})
	return len(st.stack) - 1
}

@(private)
attr_int :: proc(n: ^dom.Node, name: string) -> (i64, bool) {
	v, ok := attr(n, name)
	if !ok { return 0, false }
	x, good := strconv.parse_i64(strings.trim_space(v))
	return x, good
}

// Number of li an ol owns (its descendants that are li, not inside a nested list): what `reversed` counts from.
@(private)
owned_list_items :: proc(doc: ^dom.Document, ol: base.Handle) -> i64 {
	n: i64
	stack := make([dynamic]base.Handle, context.temp_allocator)
	for ch := dom.get(doc, ol).first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	for len(stack) > 0 {
		h := pop(&stack)
		nd := dom.get(doc, h)
		if nd == nil || nd.kind != .Element { continue }
		switch nd.name {
		case "li": n += 1; continue
		case "ol", "ul", "menu", "dir": continue
		}
		for ch := nd.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	return n
}

@(private)
mentions :: proc(ops: []Counter_Op, name: string) -> bool {
	for op in ops { if op.name == name { return true } }
	return false
}

// counter-reset, counter-increment, counter-set (in that order) of one box. `scope` is the box's parent (for an element)
// or the element itself (for ::before / ::after).
@(private)
apply_counter_ops :: proc(st: ^Counter_State, doc: ^dom.Document, h: base.Handle, n: ^dom.Node, c: ^Computed, scope: base.Handle, is_pseudo: bool) {
	for op in c.counter_reset {
		st.used = true
		value := i64(op.value)
		reversed := op.reversed
		if !is_pseudo && n != nil && op.name == "list-item" && n.name == "ol" {
			if _, rev := attr(n, "reversed"); rev { reversed = true }
			start, has_start := attr_int(n, "start")
			if reversed {
				value = has_start ? start + 1 : owned_list_items(doc, h) + 1
			} else if has_start {
				value = start - 1
			}
		} else if reversed && !op.has_value {
			value = n != nil && n.name == "ol" ? owned_list_items(doc, h) + 1 : 0
		}
		instantiate(st, op.name, value, scope, reversed)
	}
	implicit_list_item := c.display == .List_Item && !mentions(c.counter_increment, "list-item") && !mentions(c.counter_set, "list-item")
	for op in c.counter_increment {
		st.used = true
		k := innermost(st, op.name)
		if k < 0 { k = instantiate(st, op.name, 0, scope, false) }
		st.stack[k].value += i64(op.value)
	}
	if implicit_list_item {
		k := innermost(st, "list-item")
		if k < 0 { k = instantiate(st, "list-item", 0, scope, false) }
		st.stack[k].value += st.stack[k].reversed ? -1 : 1
	}
	for op in c.counter_set {
		st.used = true
		k := innermost(st, op.name)
		if k < 0 { k = instantiate(st, op.name, 0, scope, false) }
		st.stack[k].value = i64(op.value)
	}
	if !is_pseudo && n != nil && n.name == "li" && c.display == .List_Item {
		if v, ok := attr_int(n, "value"); ok {
			k := innermost(st, "list-item")
			if k >= 0 { st.stack[k].value = v }
		}
	}
}

// Entering an element of a full pass: its counters, its marker, its ::before.
counters_enter :: proc(st: ^Counter_State, doc: ^dom.Document, h: base.Handle, n: ^dom.Node, c: ^Computed, hidden: bool, alloc: runtime.Allocator) {
	if hidden {   // no box: it neither changes counters nor shows content
		resolve_static(doc, h, c, alloc)
		return
	}
	apply_counter_ops(st, doc, h, n, c, n.parent, false)
	if c.display == .List_Item {
		k := innermost(st, "list-item")
		v := k >= 0 ? st.stack[k].value : 0
		c.marker_text = marker_for(c.list_style, v, alloc)
		if marker_needs_counter(c.list_style) { st.used = true }
	}
	resolve_content(st, doc, h, &c.content, c, alloc)
	if c.before != nil {
		apply_counter_ops(st, doc, h, n, c.before, h, true)
		resolve_content(st, doc, h, &c.before.content, c.before, alloc)
	}
}

// Leaving an element: its ::after, then the counters its children created.
counters_exit :: proc(st: ^Counter_State, doc: ^dom.Document, h: base.Handle, c: ^Computed, hidden: bool, alloc: runtime.Allocator) {
	if !hidden && c != nil && c.after != nil {
		apply_counter_ops(st, doc, h, dom.get(doc, h), c.after, h, true)
		resolve_content(st, doc, h, &c.after.content, c.after, alloc)
	}
	for len(st.stack) > 0 && st.stack[len(st.stack) - 1].scope == h { pop(&st.stack) }
	// instances of this scope may sit under newer ones of an enclosing scope only when names interleave; drop them too
	for i := len(st.stack) - 1; i >= 0; i -= 1 { if st.stack[i].scope == h { ordered_remove(&st.stack, i) } }
}

@(private)
content_needs_state :: proc(parts: []Content_Part) -> bool {
	for p in parts {
		#partial switch p.kind {
		case .Counter, .Counters, .Open_Quote, .Close_Quote, .No_Open_Quote, .No_Close_Quote: return true
		}
	}
	return false
}

@(private)
marker_needs_counter :: proc(s: List_Marker_Style) -> bool {
	#partial switch s.style {
	case .None, .Disc, .Circle, .Square, .Disclosure_Open, .Disclosure_Closed, .String: return false
	}
	return true
}

// Resolves what needs no counter state (text, attr(), url): for boxes outside the counter walk.
resolve_static :: proc(doc: ^dom.Document, h: base.Handle, c: ^Computed, alloc: runtime.Allocator) {
	resolve_content(nil, doc, h, &c.content, c, alloc)
	if c.display == .List_Item && !marker_needs_counter(c.list_style) { c.marker_text = marker_for(c.list_style, 0, alloc) }
	if c.before != nil { resolve_content(nil, doc, h, &c.before.content, c.before, alloc) }
	if c.after != nil { resolve_content(nil, doc, h, &c.after.content, c.after, alloc) }
}

// `owner` carries the quotes property and the language; `st` nil: counters read as 0 and quotes do not nest.
@(private)
resolve_content :: proc(st: ^Counter_State, doc: ^dom.Document, h: base.Handle, ct: ^Content, owner: ^Computed, alloc: runtime.Allocator) {
	if ct.kind != .Items || len(ct.parts) == 0 { return }
	items := make([dynamic]Content_Item, alloc)
	sb := strings.builder_make(context.temp_allocator)
	flush :: proc(sb: ^strings.Builder, items: ^[dynamic]Content_Item, alloc: runtime.Allocator) {
		if strings.builder_len(sb^) == 0 { return }
		append(items, Content_Item{kind = .Text, text = strings.clone(strings.to_string(sb^), alloc)})
		strings.builder_reset(sb)
	}
	for p in ct.parts {
		switch p.kind {
		case .Text: strings.write_string(&sb, p.text)
		case .Attr:
			n := dom.get(doc, h)
			if v, ok := attr(n, p.text); ok { strings.write_string(&sb, v) } else { strings.write_string(&sb, p.sep) }
		case .Url:
			flush(&sb, &items, alloc)
			append(&items, Content_Item{kind = .Url, text = strings.clone(p.text, alloc)})
		case .Counter, .Counters:
			if st == nil { strings.write_string(&sb, format_counter(0, p.style, context.temp_allocator)); continue }
			st.used = true
			k := innermost(st, p.text)
			if k < 0 { k = instantiate(st, p.text, 0, h, false) }
			if p.kind == .Counter {
				strings.write_string(&sb, format_counter(st.stack[k].value, p.style, context.temp_allocator))
				continue
			}
			// the innermost max_listed instances only: on a deep tree every level's counters() lists every level
			// above (quadratic text)
			skip := -st.max_listed
			for inst in st.stack { if inst.name == p.text { skip += 1 } }
			first := true
			for inst in st.stack {
				if inst.name != p.text { continue }
				if skip > 0 { skip -= 1; continue }
				if !first { strings.write_string(&sb, p.sep) }
				first = false
				strings.write_string(&sb, format_counter(inst.value, p.style, context.temp_allocator))
			}
		case .Open_Quote, .Close_Quote, .No_Open_Quote, .No_Close_Quote:
			depth := st != nil ? st.quote_depth : 0
			if st != nil { st.used = true }
			pairs := quote_pairs(doc, h, owner.quotes)
			switch p.kind {
			case .Open_Quote:
				if len(pairs) > 0 { strings.write_string(&sb, pairs[min(depth, len(pairs) - 1)][0]) }
				depth += 1
			case .No_Open_Quote: depth += 1
			case .Close_Quote:
				if depth > 0 {
					depth -= 1
					if len(pairs) > 0 { strings.write_string(&sb, pairs[min(depth, len(pairs) - 1)][1]) }
				}
			case .No_Close_Quote: if depth > 0 { depth -= 1 }
			case .Text, .Attr, .Url, .Counter, .Counters:
			}
			if st != nil { st.quote_depth = depth }
		}
	}
	flush(&sb, &items, alloc)
	ct.items = items[:]
}

////////////////////////////////
// Quotes

@(private)
QUOTES_BY_LANG := [?]struct { lang: string, q: [2][2]string }{
	{"en", {{"\u201c", "\u201d"}, {"\u2018", "\u2019"}}},
	{"fr", {{"\u00ab\u00a0", "\u00a0\u00bb"}, {"\u201c", "\u201d"}}},
	{"de", {{"\u201e", "\u201c"}, {"\u201a", "\u2018"}}},
	{"es", {{"\u00ab", "\u00bb"}, {"\u201c", "\u201d"}}},
	{"it", {{"\u00ab", "\u00bb"}, {"\u201c", "\u201d"}}},
	{"pt", {{"\u00ab", "\u00bb"}, {"\u201c", "\u201d"}}},
	{"ru", {{"\u00ab", "\u00bb"}, {"\u201e", "\u201c"}}},
	{"pl", {{"\u201e", "\u201d"}, {"\u00ab", "\u00bb"}}},
	{"nl", {{"\u201c", "\u201d"}, {"\u2018", "\u2019"}}},
	{"sv", {{"\u201d", "\u201d"}, {"\u2019", "\u2019"}}},
	{"ja", {{"\u300c", "\u300d"}, {"\u300e", "\u300f"}}},
	{"zh", {{"\u201c", "\u201d"}, {"\u2018", "\u2019"}}},
	{"zh-tw", {{"\u300c", "\u300d"}, {"\u300e", "\u300f"}}},
	{"ko", {{"\u201c", "\u201d"}, {"\u2018", "\u2019"}}},
}

@(private)
quote_pairs :: proc(doc: ^dom.Document, h: base.Handle, q: Quotes) -> [][2]string {
	switch q.kind {
	case .None: return nil
	case .List: return q.pairs
	case .Auto:
	}
	lang := ""
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(doc, cur)
		if n == nil || n.kind != .Element { break }
		if v, ok := attr(n, "lang"); ok { lang = css.lower_temp(strings.trim_space(v)); break }
		cur = n.parent
	}
	best := -1
	for e, i in QUOTES_BY_LANG {
		if lang == e.lang || (strings.has_prefix(lang, e.lang) && len(lang) > len(e.lang) && lang[len(e.lang)] == '-') {
			if best < 0 || len(e.lang) > len(QUOTES_BY_LANG[best].lang) { best = i }
		}
	}
	if best < 0 { best = 0 }
	return QUOTES_BY_LANG[best].q[:]
}

////////////////////////////////
// Counter styles

@(private) DIGITS_ARABIC_INDIC := [10]string{"\u0660", "\u0661", "\u0662", "\u0663", "\u0664", "\u0665", "\u0666", "\u0667", "\u0668", "\u0669"}
@(private) DIGITS_PERSIAN := [10]string{"\u06f0", "\u06f1", "\u06f2", "\u06f3", "\u06f4", "\u06f5", "\u06f6", "\u06f7", "\u06f8", "\u06f9"}
@(private) DIGITS_DEVANAGARI := [10]string{"\u0966", "\u0967", "\u0968", "\u0969", "\u096a", "\u096b", "\u096c", "\u096d", "\u096e", "\u096f"}
@(private) DIGITS_BENGALI := [10]string{"\u09e6", "\u09e7", "\u09e8", "\u09e9", "\u09ea", "\u09eb", "\u09ec", "\u09ed", "\u09ee", "\u09ef"}
@(private) DIGITS_GURMUKHI := [10]string{"\u0a66", "\u0a67", "\u0a68", "\u0a69", "\u0a6a", "\u0a6b", "\u0a6c", "\u0a6d", "\u0a6e", "\u0a6f"}
@(private) DIGITS_GUJARATI := [10]string{"\u0ae6", "\u0ae7", "\u0ae8", "\u0ae9", "\u0aea", "\u0aeb", "\u0aec", "\u0aed", "\u0aee", "\u0aef"}
@(private) DIGITS_ORIYA := [10]string{"\u0b66", "\u0b67", "\u0b68", "\u0b69", "\u0b6a", "\u0b6b", "\u0b6c", "\u0b6d", "\u0b6e", "\u0b6f"}
@(private) DIGITS_TAMIL := [10]string{"\u0be6", "\u0be7", "\u0be8", "\u0be9", "\u0bea", "\u0beb", "\u0bec", "\u0bed", "\u0bee", "\u0bef"}
@(private) DIGITS_TELUGU := [10]string{"\u0c66", "\u0c67", "\u0c68", "\u0c69", "\u0c6a", "\u0c6b", "\u0c6c", "\u0c6d", "\u0c6e", "\u0c6f"}
@(private) DIGITS_KANNADA := [10]string{"\u0ce6", "\u0ce7", "\u0ce8", "\u0ce9", "\u0cea", "\u0ceb", "\u0cec", "\u0ced", "\u0cee", "\u0cef"}
@(private) DIGITS_MALAYALAM := [10]string{"\u0d66", "\u0d67", "\u0d68", "\u0d69", "\u0d6a", "\u0d6b", "\u0d6c", "\u0d6d", "\u0d6e", "\u0d6f"}
@(private) DIGITS_THAI := [10]string{"\u0e50", "\u0e51", "\u0e52", "\u0e53", "\u0e54", "\u0e55", "\u0e56", "\u0e57", "\u0e58", "\u0e59"}
@(private) DIGITS_LAO := [10]string{"\u0ed0", "\u0ed1", "\u0ed2", "\u0ed3", "\u0ed4", "\u0ed5", "\u0ed6", "\u0ed7", "\u0ed8", "\u0ed9"}
@(private) DIGITS_MYANMAR := [10]string{"\u1040", "\u1041", "\u1042", "\u1043", "\u1044", "\u1045", "\u1046", "\u1047", "\u1048", "\u1049"}
@(private) DIGITS_KHMER := [10]string{"\u17e0", "\u17e1", "\u17e2", "\u17e3", "\u17e4", "\u17e5", "\u17e6", "\u17e7", "\u17e8", "\u17e9"}
@(private) DIGITS_TIBETAN := [10]string{"\u0f20", "\u0f21", "\u0f22", "\u0f23", "\u0f24", "\u0f25", "\u0f26", "\u0f27", "\u0f28", "\u0f29"}
@(private) DIGITS_MONGOLIAN := [10]string{"\u1810", "\u1811", "\u1812", "\u1813", "\u1814", "\u1815", "\u1816", "\u1817", "\u1818", "\u1819"}
@(private) DIGITS_CJK := [10]string{"\u3007", "\u4e00", "\u4e8c", "\u4e09", "\u56db", "\u4e94", "\u516d", "\u4e03", "\u516b", "\u4e5d"}

@(private) ALPHA_GREEK := [?]string{"α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ν", "ξ", "ο", "π", "ρ", "σ", "τ", "υ", "φ", "χ", "ψ", "ω"}
@(private) ALPHA_HIRAGANA := [?]string{"あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ", "さ", "し", "す", "せ", "そ", "た", "ち", "つ", "て", "と", "な", "に", "ぬ", "ね", "の", "は", "ひ", "ふ", "へ", "ほ", "ま", "み", "む", "め", "も", "や", "ゆ", "よ", "ら", "り", "る", "れ", "ろ", "わ", "ゐ", "ゑ", "を", "ん"}
@(private) ALPHA_KATAKANA := [?]string{"ア", "イ", "ウ", "エ", "オ", "カ", "キ", "ク", "ケ", "コ", "サ", "シ", "ス", "セ", "ソ", "タ", "チ", "ツ", "テ", "ト", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ", "マ", "ミ", "ム", "メ", "モ", "ヤ", "ユ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ワ", "ヰ", "ヱ", "ヲ", "ン"}
@(private) ALPHA_HIRAGANA_IROHA := [?]string{"い", "ろ", "は", "に", "ほ", "へ", "と", "ち", "り", "ぬ", "る", "を", "わ", "か", "よ", "た", "れ", "そ", "つ", "ね", "な", "ら", "む", "う", "ゐ", "の", "お", "く", "や", "ま", "け", "ふ", "こ", "え", "て", "あ", "さ", "き", "ゆ", "め", "み", "し", "ゑ", "ひ", "も", "せ", "す"}
@(private) ALPHA_KATAKANA_IROHA := [?]string{"イ", "ロ", "ハ", "ニ", "ホ", "ヘ", "ト", "チ", "リ", "ヌ", "ル", "ヲ", "ワ", "カ", "ヨ", "タ", "レ", "ソ", "ツ", "ネ", "ナ", "ラ", "ム", "ウ", "ヰ", "ノ", "オ", "ク", "ヤ", "マ", "ケ", "フ", "コ", "エ", "テ", "ア", "サ", "キ", "ユ", "メ", "ミ", "シ", "ヱ", "ヒ", "モ", "セ", "ス"}
@(private) ALPHA_EARTHLY := [?]string{"子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"}
@(private) ALPHA_HEAVENLY := [?]string{"甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"}

@(private)
Additive :: struct { weight: i64, sym: string }

@(private) ROMAN_UPPER := [?]Additive{{1000, "M"}, {900, "CM"}, {500, "D"}, {400, "CD"}, {100, "C"}, {90, "XC"}, {50, "L"}, {40, "XL"}, {10, "X"}, {9, "IX"}, {5, "V"}, {4, "IV"}, {1, "I"}}
@(private) ROMAN_LOWER := [?]Additive{{1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"}, {100, "c"}, {90, "xc"}, {50, "l"}, {40, "xl"}, {10, "x"}, {9, "ix"}, {5, "v"}, {4, "iv"}, {1, "i"}}
@(private) ARMENIAN_UPPER := [?]Additive{
	{9000, "Ք"}, {8000, "Փ"}, {7000, "Ւ"}, {6000, "Ց"}, {5000, "Ր"}, {4000, "Տ"}, {3000, "Վ"}, {2000, "Ս"}, {1000, "Ռ"},
	{900, "Ջ"}, {800, "Պ"}, {700, "Չ"}, {600, "Ո"}, {500, "Շ"}, {400, "Ն"}, {300, "Յ"}, {200, "Մ"}, {100, "Ճ"},
	{90, "Ղ"}, {80, "Ձ"}, {70, "Հ"}, {60, "Կ"}, {50, "Ծ"}, {40, "Խ"}, {30, "Լ"}, {20, "Ի"}, {10, "Ժ"},
	{9, "Թ"}, {8, "Ը"}, {7, "Է"}, {6, "Զ"}, {5, "Ե"}, {4, "Դ"}, {3, "Գ"}, {2, "Բ"}, {1, "Ա"},
}
@(private) ARMENIAN_LOWER := [?]Additive{
	{9000, "ք"}, {8000, "փ"}, {7000, "ւ"}, {6000, "ց"}, {5000, "ր"}, {4000, "տ"}, {3000, "վ"}, {2000, "ս"}, {1000, "ռ"},
	{900, "ջ"}, {800, "պ"}, {700, "չ"}, {600, "ո"}, {500, "շ"}, {400, "ն"}, {300, "յ"}, {200, "մ"}, {100, "ճ"},
	{90, "ղ"}, {80, "ձ"}, {70, "հ"}, {60, "կ"}, {50, "ծ"}, {40, "խ"}, {30, "լ"}, {20, "ի"}, {10, "ժ"},
	{9, "թ"}, {8, "ը"}, {7, "է"}, {6, "զ"}, {5, "ե"}, {4, "դ"}, {3, "գ"}, {2, "բ"}, {1, "ա"},
}
@(private) GEORGIAN := [?]Additive{
	{10000, "ჵ"}, {9000, "ჰ"}, {8000, "ჯ"}, {7000, "ჴ"}, {6000, "ხ"}, {5000, "ჭ"}, {4000, "წ"}, {3000, "ძ"}, {2000, "ც"}, {1000, "ჩ"},
	{900, "შ"}, {800, "ყ"}, {700, "ღ"}, {600, "ქ"}, {500, "ფ"}, {400, "ჳ"}, {300, "ტ"}, {200, "ს"}, {100, "რ"},
	{90, "ჟ"}, {80, "პ"}, {70, "ო"}, {60, "ჲ"}, {50, "ნ"}, {40, "მ"}, {30, "ლ"}, {20, "კ"}, {10, "ი"},
	{9, "თ"}, {8, "ჱ"}, {7, "ზ"}, {6, "ვ"}, {5, "ე"}, {4, "დ"}, {3, "გ"}, {2, "ბ"}, {1, "ა"},
}
@(private) HEBREW := [?]Additive{
	{10000, "י׳"}, {9000, "ט׳"}, {8000, "ח׳"}, {7000, "ז׳"}, {6000, "ו׳"}, {5000, "ה׳"}, {4000, "ד׳"}, {3000, "ג׳"}, {2000, "ב׳"}, {1000, "א׳"},
	{400, "ת"}, {300, "ש"}, {200, "ר"}, {100, "ק"}, {90, "צ"}, {80, "פ"}, {70, "ע"}, {60, "ס"}, {50, "נ"}, {40, "מ"}, {30, "ל"}, {20, "כ"},
	{19, "יט"}, {18, "יח"}, {17, "יז"}, {16, "טז"}, {15, "טו"}, {10, "י"},
	{9, "ט"}, {8, "ח"}, {7, "ז"}, {6, "ו"}, {5, "ה"}, {4, "ד"}, {3, "ג"}, {2, "ב"}, {1, "א"},
}

@(private)
numeric :: proc(sb: ^strings.Builder, v: i64, digits: []string) {
	if v < 0 { strings.write_byte(sb, '-') }
	x := v < 0 ? -v : v
	buf: [24]int
	n := 0
	if x == 0 { buf[0] = 0; n = 1 }
	for x > 0 { buf[n] = int(x % i64(len(digits))); x /= i64(len(digits)); n += 1 }
	for i := n - 1; i >= 0; i -= 1 { strings.write_string(sb, digits[buf[i]]) }
}

@(private)
alphabetic :: proc(sb: ^strings.Builder, v: i64, symbols: []string) -> bool {
	if v < 1 { return false }
	parts := make([dynamic]string, context.temp_allocator)
	x := v
	n := i64(len(symbols))
	for x > 0 {
		x -= 1
		append(&parts, symbols[x % n])
		x /= n
	}
	for i := len(parts) - 1; i >= 0; i -= 1 { strings.write_string(sb, parts[i]) }
	return true
}

@(private)
additive :: proc(sb: ^strings.Builder, v: i64, table: []Additive, hi: i64) -> bool {
	if v < 1 || v > hi { return false }
	x := v
	for t in table {
		for x >= t.weight { strings.write_string(sb, t.sym); x -= t.weight }
	}
	return x == 0
}

// Chinese and Japanese informal numbering, 1..9999 (CSS Counter Styles 3 §7.1.2), else cjk-decimal.
@(private)
cjk_informal :: proc(sb: ^strings.Builder, v: i64, style: Counter_Style) -> bool {
	if v < 0 || v > 9999 { return false }
	japanese := style == .Japanese_Informal
	zero := japanese ? "〇" : "零"
	if v == 0 { strings.write_string(sb, zero); return true }
	units := [4]string{"", "十", "百", "千"}
	d := [4]i64{v % 10, v / 10 % 10, v / 100 % 10, v / 1000 % 10}
	top := 3
	for top > 0 && d[top] == 0 { top -= 1 }
	pending_zero := false
	for i := top; i >= 0; i -= 1 {
		if d[i] == 0 { if !japanese && i > 0 { pending_zero = true }; continue }
		if pending_zero { strings.write_string(sb, zero); pending_zero = false }
		// 10..19 are written 十X, not 一十X; Japanese drops the 一 before every unit
		skip_one := d[i] == 1 && i > 0 && (japanese || (i == 1 && i == top))
		if !skip_one { strings.write_string(sb, DIGITS_CJK[d[i]]) }
		strings.write_string(sb, units[i])
	}
	return true
}

// The representation of `v` in counter style `s` (no suffix), with the fallbacks of CSS Counter Styles 3.
format_counter :: proc(v: i64, s: List_Marker_Style, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	switch s.style {
	case .None: return ""
	case .String: strings.write_string(&sb, s.text)
	case .Disc: strings.write_string(&sb, "\u2022")
	case .Circle: strings.write_string(&sb, "\u25e6")
	case .Square: strings.write_string(&sb, "\u25aa")
	case .Disclosure_Open: strings.write_string(&sb, "\u25be")
	case .Disclosure_Closed: strings.write_string(&sb, "\u25b8")
	case .Decimal: strings.write_i64(&sb, v)
	case .Decimal_Leading_Zero:
		if v < 0 { strings.write_byte(&sb, '-') }
		x := v < 0 ? -v : v
		if x < 10 { strings.write_byte(&sb, '0') }
		strings.write_i64(&sb, x)
	case .Lower_Roman: if !additive(&sb, v, ROMAN_LOWER[:], 3999) { strings.write_i64(&sb, v) }
	case .Upper_Roman: if !additive(&sb, v, ROMAN_UPPER[:], 3999) { strings.write_i64(&sb, v) }
	case .Lower_Armenian: if !additive(&sb, v, ARMENIAN_LOWER[:], 9999) { strings.write_i64(&sb, v) }
	case .Upper_Armenian: if !additive(&sb, v, ARMENIAN_UPPER[:], 9999) { strings.write_i64(&sb, v) }
	case .Georgian: if !additive(&sb, v, GEORGIAN[:], 19999) { strings.write_i64(&sb, v) }
	case .Hebrew: if !additive(&sb, v, HEBREW[:], 10999) { strings.write_i64(&sb, v) }
	case .Lower_Alpha, .Upper_Alpha:
		if v < 1 { strings.write_i64(&sb, v); break }
		letters := make([dynamic]u8, context.temp_allocator)
		x := v
		base_ch := u8(s.style == .Lower_Alpha ? 'a' : 'A')
		for x > 0 { x -= 1; append(&letters, base_ch + u8(x % 26)); x /= 26 }
		for i := len(letters) - 1; i >= 0; i -= 1 { strings.write_byte(&sb, letters[i]) }
	case .Lower_Greek: if !alphabetic(&sb, v, ALPHA_GREEK[:]) { strings.write_i64(&sb, v) }
	case .Hiragana: if !alphabetic(&sb, v, ALPHA_HIRAGANA[:]) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Katakana: if !alphabetic(&sb, v, ALPHA_KATAKANA[:]) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Hiragana_Iroha: if !alphabetic(&sb, v, ALPHA_HIRAGANA_IROHA[:]) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Katakana_Iroha: if !alphabetic(&sb, v, ALPHA_KATAKANA_IROHA[:]) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Cjk_Earthly_Branch: if !alphabetic(&sb, v, ALPHA_EARTHLY[:]) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Cjk_Heavenly_Stem: if !alphabetic(&sb, v, ALPHA_HEAVENLY[:]) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Japanese_Informal, .Simp_Chinese_Informal, .Trad_Chinese_Informal:
		if !cjk_informal(&sb, v, s.style) { numeric(&sb, v, DIGITS_CJK[:]) }
	case .Cjk_Decimal: numeric(&sb, v, DIGITS_CJK[:])
	case .Arabic_Indic: numeric(&sb, v, DIGITS_ARABIC_INDIC[:])
	case .Persian: numeric(&sb, v, DIGITS_PERSIAN[:])
	case .Devanagari: numeric(&sb, v, DIGITS_DEVANAGARI[:])
	case .Bengali: numeric(&sb, v, DIGITS_BENGALI[:])
	case .Gurmukhi: numeric(&sb, v, DIGITS_GURMUKHI[:])
	case .Gujarati: numeric(&sb, v, DIGITS_GUJARATI[:])
	case .Oriya: numeric(&sb, v, DIGITS_ORIYA[:])
	case .Tamil: numeric(&sb, v, DIGITS_TAMIL[:])
	case .Telugu: numeric(&sb, v, DIGITS_TELUGU[:])
	case .Kannada: numeric(&sb, v, DIGITS_KANNADA[:])
	case .Malayalam: numeric(&sb, v, DIGITS_MALAYALAM[:])
	case .Thai: numeric(&sb, v, DIGITS_THAI[:])
	case .Lao: numeric(&sb, v, DIGITS_LAO[:])
	case .Myanmar: numeric(&sb, v, DIGITS_MYANMAR[:])
	case .Khmer: numeric(&sb, v, DIGITS_KHMER[:])
	case .Tibetan: numeric(&sb, v, DIGITS_TIBETAN[:])
	case .Mongolian: numeric(&sb, v, DIGITS_MONGOLIAN[:])
	}
	return strings.to_string(sb)
}

// A list item's marker: the counter value in its style, then the style's suffix.
marker_for :: proc(s: List_Marker_Style, v: i64, allocator := context.allocator) -> string {
	#partial switch s.style {
	case .None: return ""
	case .String: return strings.clone(s.text, allocator)
	case .Disc, .Circle, .Square, .Disclosure_Open, .Disclosure_Closed:
		return strings.concatenate({format_counter(v, s, context.temp_allocator), " "}, allocator)
	case .Cjk_Decimal, .Hiragana, .Katakana, .Hiragana_Iroha, .Katakana_Iroha, .Cjk_Earthly_Branch, .Cjk_Heavenly_Stem,
	     .Japanese_Informal, .Simp_Chinese_Informal, .Trad_Chinese_Informal:
		return strings.concatenate({format_counter(v, s, context.temp_allocator), "\u3001"}, allocator)
	}
	return strings.concatenate({format_counter(v, s, context.temp_allocator), ". "}, allocator)
}

////////////////////////////////
// Partial restyles

// A partial restyle has no counter walk: a box keeps the resolved values of its previous style when nothing that feeds
// the counters changed; otherwise the restyle cannot be scoped (false) and the caller does a full pass.
counters_carry_over :: proc(s: ^Styled, doc: ^dom.Document, h: base.Handle, old, c: ^Computed, alloc: runtime.Allocator, in_task := false) -> bool {
	used := s.counters_used
	if old == nil { resolve_static(doc, h, c, alloc); return !used || !box_feeds_counters(c) }
	if used {
		// (a style thread cannot look at the following siblings' styles, which other threads write: the counters are resolved again)
		if (old.display == .None) != (c.display == .None) && (in_task || subtree_feeds_counters(s, doc, h, old, c)) { return false }
		if (old.display == .List_Item) != (c.display == .List_Item) { return false }
		if !deep_equal(&old.counter_reset, &c.counter_reset, type_info_of(type_of(c.counter_reset))) ||
		   !deep_equal(&old.counter_increment, &c.counter_increment, type_info_of(type_of(c.counter_increment))) ||
		   !deep_equal(&old.counter_set, &c.counter_set, type_info_of(type_of(c.counter_set))) {
			return false
		}
	}
	if c.display == .List_Item {
		if marker_needs_counter(c.list_style) {
			if old.display != .List_Item || !deep_equal(&old.list_style, &c.list_style, type_info_of(List_Marker_Style)) { return false }
			c.marker_text = old.marker_text
		} else {
			c.marker_text = marker_for(c.list_style, 0, alloc)
		}
	}
	if !carry_content(doc, h, &old.content, &c.content, old, c, alloc) { return false }
	pairs := [2][2]^Computed{{old.before, c.before}, {old.after, c.after}}
	for pr in pairs {
		o, n := pr[0], pr[1]
		if n == nil { continue }
		if o == nil {
			if content_needs_state(n.content.parts) || len(n.counter_reset) + len(n.counter_increment) + len(n.counter_set) > 0 { return false }
			resolve_content(nil, doc, h, &n.content, n, alloc)
			continue
		}
		if used && (!deep_equal(&o.counter_reset, &n.counter_reset, type_info_of(type_of(n.counter_reset))) ||
		   !deep_equal(&o.counter_increment, &n.counter_increment, type_info_of(type_of(n.counter_increment))) ||
		   !deep_equal(&o.counter_set, &n.counter_set, type_info_of(type_of(n.counter_set)))) {
			return false
		}
		if !carry_content(doc, h, &o.content, &n.content, o, n, alloc) { return false }
	}
	// a pseudo-element that disappears takes its counter operations and quotes with it
	if used {
		for pr in pairs {
			if pr[0] != nil && pr[1] == nil && (content_needs_state(pr[0].content.parts) || len(pr[0].counter_reset) + len(pr[0].counter_increment) + len(pr[0].counter_set) > 0) { return false }
		}
	}
	return true
}

@(private)
carry_content :: proc(doc: ^dom.Document, h: base.Handle, old, ct: ^Content, old_owner, owner: ^Computed, alloc: runtime.Allocator) -> bool {
	if ct.kind != .Items { return true }
	if !content_needs_state(ct.parts) { resolve_content(nil, doc, h, ct, owner, alloc); return true }
	if old.kind != .Items || !deep_equal(&old.parts, &ct.parts, type_info_of(type_of(ct.parts))) { return false }
	if !deep_equal(&old_owner.quotes, &owner.quotes, type_info_of(Quotes)) { return false }
	ct.items = old.items
	return true
}

@(private)
box_feeds_counters :: proc(c: ^Computed) -> bool {
	if c.display == .List_Item || len(c.counter_reset) + len(c.counter_increment) + len(c.counter_set) > 0 { return true }
	if content_needs_state(c.content.parts) { return true }
	for pc in ([2]^Computed{c.before, c.after}) {
		if pc != nil && (content_needs_state(pc.content.parts) || len(pc.counter_reset) + len(pc.counter_increment) + len(pc.counter_set) > 0) { return true }
	}
	return false
}

// Something at or under `h` changes or reads counters (the descendants as styled by the previous pass).
// Whether showing or hiding the subtree of `h` changes counter values or quote depths seen elsewhere, or shows values
// that the partial restyle cannot compute. Counters the root resets are contained (their scope is the root's subtree,
// plus its following siblings, which are checked directly); a list whose items only show bullets is the common case
// that stays partial (a drop-down menu).
@(private)
subtree_feeds_counters :: proc(s: ^Styled, doc: ^dom.Document, h: base.Handle, old, c: ^Computed) -> bool {
	contained := make(map[string]bool, context.temp_allocator)
	for op in c.counter_reset { contained[op.name] = true }
	for op in old.counter_reset { contained[op.name] = true }
	escapes :: proc(x: ^Computed, contained: map[string]bool, root: bool) -> bool {
		if displays_counters(x) { return true }
		for op in x.counter_increment { if op.name not_in contained { return true } }
		for op in x.counter_set { if op.name not_in contained { return true } }
		if !root { for op in x.counter_reset { if op.name not_in contained { return true } } }
		if x.display == .List_Item && "list-item" not_in contained { return true }
		for pc in ([2]^Computed{x.before, x.after}) {
			if pc == nil { continue }
			if len(pc.counter_reset) + len(pc.counter_increment) + len(pc.counter_set) > 0 { return true }
		}
		return false
	}
	if escapes(old, contained, true) || escapes(c, contained, true) { return true }
	stack := make([dynamic]base.Handle, context.temp_allocator)
	for ch := dom.get(doc, h).first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	for len(stack) > 0 {
		x := pop(&stack)
		n := dom.get(doc, x)
		if n == nil || n.kind != .Element { continue }
		if cs := base_style_of(s, x); cs != nil && escapes(cs, contained, false) { return true }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	// the root's resets are scoped to its parent: they reach its following siblings with their subtrees, and the
	// parent's ::after (resolved when the walk leaves the parent)
	if len(contained) > 0 {
		root := dom.get(doc, h)
		if pc := base_style_of(s, root.parent); pc != nil && pc.after != nil && content_needs_state(pc.after.content.parts) { return true }
		// does `cs` change or show one of `names`?
		uses :: proc(cs: ^Computed, names: map[string]bool) -> bool {
			shows :: proc(parts: []Content_Part, names: map[string]bool) -> bool {
				for p in parts { if (p.kind == .Counter || p.kind == .Counters) && p.text in names { return true } }
				return false
			}
			for name in names {
				if mentions(cs.counter_increment, name) || mentions(cs.counter_set, name) { return true }
			}
			if "list-item" in names && cs.display == .List_Item { return true }
			if shows(cs.content.parts, names) { return true }
			for pc in ([2]^Computed{cs.before, cs.after}) {
				if pc == nil { continue }
				if shows(pc.content.parts, names) { return true }
				for name in names { if mentions(pc.counter_increment, name) || mentions(pc.counter_set, name) { return true } }
			}
			return false
		}
		names := make(map[string]bool, len(contained), context.temp_allocator)
		for k in contained { names[k] = true }
		for sib := root.next; sib != base.NIL_HANDLE && len(names) > 0; sib = dom.get(doc, sib).next {
			sn := dom.get(doc, sib)
			if sn == nil || sn.kind != .Element { continue }
			cs := base_style_of(s, sib)
			if cs == nil || cs.display == .None { continue }
			// a sibling's own reset replaces the instance (same scope): it and what follows see that one
			for op in cs.counter_reset { delete_key(&names, op.name) }
			if len(names) == 0 { break }
			if uses(cs, names) { return true }
			clear(&stack)
			for ch := sn.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			for len(stack) > 0 {
				x := pop(&stack)
				n := dom.get(doc, x)
				if n == nil || n.kind != .Element { continue }
				xs := base_style_of(s, x)
				if xs == nil || xs.display == .None { continue }
				if uses(xs, names) { return true }
				for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			}
		}
	}
	return false
}

// The box shows a counter value or a quote (a numbered marker, counter() / quotes in its content or pseudo-elements).
@(private)
displays_counters :: proc(c: ^Computed) -> bool {
	if c.display == .List_Item && marker_needs_counter(c.list_style) { return true }
	if content_needs_state(c.content.parts) { return true }
	for pc in ([2]^Computed{c.before, c.after}) { if pc != nil && content_needs_state(pc.content.parts) { return true } }
	return false
}
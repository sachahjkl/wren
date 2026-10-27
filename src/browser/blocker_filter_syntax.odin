package browser

import "core:strings"
import "toolkit:ui"

// Syntax colouring for the "My filters" editor (about:blocker). A `ui.Text_Highlight` classifier: the toolkit calls it per
// visible paragraph and draws the coloured runs it returns; the editor itself knows no language. The invalid lines come
// from the engine's own parser (diagnose(), dash.my_errors), so the editor flags exactly what the lists would drop.
//
// What each part is coloured as (theme-aware tones):
//   comment   `! ...` and `[Adblock Plus 2.0]` headers (weak / grey)
//   exception `@@` prefix and the `#@#` cosmetic exception separator (green)
//   options   the `$...` option section of a network rule (amber)
//   cosmetic  the `##` / `#?#` / `##^` / `#@#` separator and `+js(` scriptlets (green / amber)
//   anchors   `||`, `^`, `*`, `|` of a network pattern (weak)
// Everything else is the box's text colour.

@(private = "file")
filter_highlight_colors :: proc() -> (comment, exception, option, cosmetic, scriptlet, anchor: ui.Color) {
	comment = SHIELD_GREY
	exception = SHIELD_GREEN
	option = SHIELD_AMBER
	cosmetic = SHIELD_GREEN
	scriptlet = SHIELD_AMBER
	anchor = SHIELD_GREY
	return
}

// The classifier installed on the editor. `user` is unused (the colours come from the theme tones).
@(private = "file")
filter_spans :: proc(user: rawptr, line: string, para: int, out: ^[dynamic]ui.Text_Span) {
	comment, exception, option, cosmetic, scriptlet, anchor := filter_highlight_colors()
	t := strings.trim_space(line)
	if t == "" { return }
	// leading whitespace offset so byte ranges are relative to `line`, not the trimmed text
	off := strings.index(line, t)
	if off < 0 { off = 0 }

	// a whole-line comment or an [Adblock ...] header
	if t[0] == '!' || t[0] == '[' {
		append(out, ui.Text_Span{start = 0, end = len(line), color = comment})
		return
	}

	// a cosmetic rule: a `##`, `#@#`, `#?#`, `#$#`, `#%#` separator somewhere after a domain list
	if sep, body_at, ok := cosmetic_separator_at(t); ok {
		sep_start := off + sep
		sep_end := off + body_at
		append(out, ui.Text_Span{start = sep_start, end = sep_end, color = t[sep + 1] == '@' ? exception : cosmetic})
		// a `##^` HTML filter: mark the `^`
		body := t[body_at:]
		if len(body) > 0 && body[0] == '^' {
			append(out, ui.Text_Span{start = sep_end, end = sep_end + 1, color = cosmetic})
		}
		// a `+js(` scriptlet: colour the call
		if js := strings.index(body, "+js("); js >= 0 {
			append(out, ui.Text_Span{start = off + body_at + js, end = off + len(t), color = scriptlet})
		}
		return
	}

	// a network rule: an optional `@@` exception, a pattern with anchors, an optional `$options` section
	i := 0
	if strings.has_prefix(t, "@@") {
		append(out, ui.Text_Span{start = off, end = off + 2, color = exception})
		i = 2
	}
	// the `$options` section: the last unescaped `$` that is not part of a `$`-less regex `/.../$`
	opt := network_option_dollar(t)
	pat_end := opt < 0 ? len(t) : opt
	// anchors inside the pattern
	for j := i; j < pat_end; j += 1 {
		switch {
		case t[j] == '|':
			end := j + 1
			if end < pat_end && t[end] == '|' { end += 1 }
			append(out, ui.Text_Span{start = off + j, end = off + end, color = anchor})
			j = end - 1
		case t[j] == '^' || t[j] == '*':
			append(out, ui.Text_Span{start = off + j, end = off + j + 1, color = anchor})
		}
	}
	if opt >= 0 {
		append(out, ui.Text_Span{start = off + opt, end = off + len(t), color = option})
	}
}

// The editor asks whether a paragraph is invalid (dash.my_errors, filled by diagnose()).
@(private = "file")
filter_error_line :: proc(user: rawptr, para: int) -> bool {
	_, bad := dash.my_errors[para]
	return bad
}

// A ui.Text_Highlight bound to the blocker filter syntax, for the "My filters" editor.
filter_highlight :: proc() -> ui.Text_Highlight {
	return ui.Text_Highlight{spans = filter_spans, error_line = filter_error_line, error = BLOCK_RED}
}

////////////////////////////////
// small tokenizers (the editor path only; the engine's parser is the authority on validity)

// The index of a cosmetic separator (`##`, `#@#`, `#?#`, `#$#`, `#%#`) and where its body starts, after a plausible domain
// list. ok = false when the line is not cosmetic. Mirrors adblock.parse_cosmetic's separator scan, loosely (for colouring).
@(private = "file")
cosmetic_separator_at :: proc(line: string) -> (sep, body: int, ok: bool) {
	at := 0
	for {
		h := strings.index_byte(line[at:], '#')
		if h < 0 { return 0, 0, false }
		h += at
		// the domain part before it must be plausible (letters, digits, `.,~*_-`)
		valid := true
		for k in 0 ..< h {
			c := line[k]
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == ',' || c == '~' || c == '*' || c == '_' || c == '-') { valid = false; break }
		}
		if !valid { return 0, 0, false }
		rest := line[h:]
		switch {
		case strings.has_prefix(rest, "#@#"): return h, h + 3, true
		case strings.has_prefix(rest, "#?#"): return h, h + 3, true
		case strings.has_prefix(rest, "#$#"): return h, h + 3, true
		case strings.has_prefix(rest, "#%#"): return h, h + 3, true
		case strings.has_prefix(rest, "##"):  return h, h + 2, true
		}
		at = h + 1
	}
}

// The index of the `$options` section of a network rule, or -1. The `$` must be outside a `/regex/` and not escaped. A bare
// regex rule (`/.../`) with trailing flags has no options; we only treat a `$` after the last `/` (or with no regex) as the
// option separator.
@(private = "file")
network_option_dollar :: proc(line: string) -> int {
	// if the pattern is a regex `/.../`, options can only start after the closing slash
	start := 0
	if len(line) >= 2 && line[0] == '/' {
		if last := strings.last_index_byte(line, '/'); last > 0 { start = last + 1 }
	}
	for i := start; i < len(line); i += 1 {
		if line[i] == '$' { return i }
	}
	return -1
}

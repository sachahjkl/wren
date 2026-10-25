package browser

import "core:unicode/utf8"

// Is `s` one JSON value (RFC 8259) written on one line: valid UTF-8, no control character anywhere, no white space but the
// space? The value of a script's answer comes from the page (JSON.stringify of whatever the page's script made of it, or
// whatever a page that replaced JSON.stringify or console.log wrote instead) and goes into a reply of the protocol: a line
// break or a second value in it would be a line or a value the client reads as the browser's.
json_value_line :: proc(s: string) -> bool {
	if s == "" || !utf8.valid_string(s) { return false }
	i := 0
	if !jv_value(s, &i, 0) { return false }
	return i == len(s)
}

@(private = "file") JV_MAX_DEPTH :: 512

@(private = "file")
jv_spaces :: proc(s: string, i: ^int) { for i^ < len(s) && s[i^] == ' ' { i^ += 1 } }

@(private = "file")
jv_value :: proc(s: string, i: ^int, depth: int) -> bool {
	if depth > JV_MAX_DEPTH { return false }
	jv_spaces(s, i)
	if i^ >= len(s) { return false }
	switch c := s[i^]; c {
	case '{':
		i^ += 1
		jv_spaces(s, i)
		if i^ < len(s) && s[i^] == '}' { i^ += 1; return true }
		for {
			jv_spaces(s, i)
			if i^ >= len(s) || s[i^] != '"' || !jv_string(s, i) { return false }
			jv_spaces(s, i)
			if i^ >= len(s) || s[i^] != ':' { return false }
			i^ += 1
			if !jv_value(s, i, depth + 1) { return false }
			jv_spaces(s, i)
			if i^ >= len(s) { return false }
			if s[i^] == ',' { i^ += 1; continue }
			if s[i^] == '}' { i^ += 1; return true }
			return false
		}
	case '[':
		i^ += 1
		jv_spaces(s, i)
		if i^ < len(s) && s[i^] == ']' { i^ += 1; return true }
		for {
			if !jv_value(s, i, depth + 1) { return false }
			jv_spaces(s, i)
			if i^ >= len(s) { return false }
			if s[i^] == ',' { i^ += 1; continue }
			if s[i^] == ']' { i^ += 1; return true }
			return false
		}
	case '"':
		return jv_string(s, i)
	case 't': return jv_word(s, i, "true")
	case 'f': return jv_word(s, i, "false")
	case 'n': return jv_word(s, i, "null")
	case '-', '0' ..= '9':
		return jv_number(s, i)
	}
	return false
}

@(private = "file")
jv_word :: proc(s: string, i: ^int, word: string) -> bool {
	if len(s) - i^ < len(word) || s[i^:i^ + len(word)] != word { return false }
	i^ += len(word)
	return true
}

@(private = "file")
jv_string :: proc(s: string, i: ^int) -> bool {
	i^ += 1   // the opening quote
	for i^ < len(s) {
		c := s[i^]
		switch {
		case c == '"': i^ += 1; return true
		case c < 0x20: return false
		case c == '\\':
			i^ += 1
			if i^ >= len(s) { return false }
			switch s[i^] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't': i^ += 1
			case 'u':
				if len(s) - i^ < 5 { return false }
				for k in 1 ..= 4 {
					h := s[i^ + k]
					if !(h >= '0' && h <= '9' || h >= 'a' && h <= 'f' || h >= 'A' && h <= 'F') { return false }
				}
				i^ += 5
			case: return false
			}
		case: i^ += 1
		}
	}
	return false
}

@(private = "file")
jv_number :: proc(s: string, i: ^int) -> bool {
	digits :: proc(s: string, i: ^int) -> int {
		n := 0
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' { i^ += 1; n += 1 }
		return n
	}
	if s[i^] == '-' { i^ += 1 }
	if i^ >= len(s) { return false }
	if s[i^] == '0' { i^ += 1 } else if digits(s, i) == 0 { return false }
	if i^ < len(s) && s[i^] == '.' {
		i^ += 1
		if digits(s, i) == 0 { return false }
	}
	if i^ < len(s) && (s[i^] == 'e' || s[i^] == 'E') {
		i^ += 1
		if i^ < len(s) && (s[i^] == '+' || s[i^] == '-') { i^ += 1 }
		if digits(s, i) == 0 { return false }
	}
	return true
}
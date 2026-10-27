package media

// A native WebVTT parser (https://www.w3.org/TR/webvtt1/). The whole file is read in the host — the signature line, NOTE
// comments, REGION and STYLE blocks, and the cues: their optional identifier, the timing line with its cue settings
// (vertical, line, position, size, align), and the cue payload with its inline markup (<b> <i> <u> <c.class> <v Name>
// <lang> <ruby>/<rt>, and internal timestamps <00:00:01.000>). Nothing of this runs in the script interpreter: a
// TextTrack (src/page/media_texttracks.odin) is filled from the Vtt_File this returns, and the shell draws the active
// cues (src/browser/video_shell.odin).
//
// Robustness over strictness, like a browser: a line that does not parse is skipped rather than failing the file, so a
// single bad cue never blanks the rest of the subtitles.

import "core:strconv"
import "core:strings"
import "wb:base"

Vtt_Align :: enum u8 { Center, Start, End, Left, Right }
Vtt_Line_Align :: enum u8 { Start, Center, End }
Vtt_Position_Align :: enum u8 { Auto, Line_Left, Center, Line_Right }

// One inline run of a cue payload, already flattened: the text with the formatting active over it. The renderer walks
// these in order; a line break is a run whose `newline` is set.
Vtt_Run :: struct {
	text:    string,       // owned (heap)
	bold:    bool,
	italic:  bool,
	underline: bool,
	classes: []string,     // owned: the classes of the <c> / <v> spans over this run
	voice:   string,       // owned: the speaker of the enclosing <v Name> ("" none)
	lang:    string,       // owned: the enclosing <lang> ("" none)
	ruby:    bool,         // inside a <ruby>
	rt:      bool,         // inside an <rt> (the annotation)
	newline: bool,         // this run is a forced line break (the text is empty)
}

Vtt_Cue :: struct {
	id:       string,      // owned ("" when the cue had no identifier)
	start, end: Time,
	// settings
	vertical: u8,          // 0 horizontal, 'r' growing right ("rl"), 'l' growing left ("lr")
	snap_to_lines: bool,   // line is a line number (true) or a percentage (false)
	line:     f64,         // the line setting value; NaN = auto
	line_align: Vtt_Line_Align,
	position: f64,         // percentage; NaN = auto
	position_align: Vtt_Position_Align,
	size:     f64,         // percentage of the video
	align:    Vtt_Align,
	region:   string,      // owned: the id of the region this cue is shown in ("" none)
	// payload
	raw:      string,      // owned: the cue text as written (with the markup), for cue.text
	runs:     []Vtt_Run,   // owned: the flattened payload for rendering
}

Vtt_Region :: struct {
	id:       string,      // owned
	width:    f64,         // percentage
	lines:    int,
	region_anchor: [2]f64, // x, y percentages
	viewport_anchor: [2]f64,
	scroll:   bool,        // "up" scrolling
}

Vtt_File :: struct {
	cues:     [dynamic]Vtt_Cue,
	regions:  [dynamic]Vtt_Region,
	ok:       bool,        // the signature was a WebVTT one
}

vtt_destroy :: proc(f: ^Vtt_File) {
	for &c in f.cues { vtt_cue_destroy(&c) }
	delete(f.cues)
	for &r in f.regions { delete(r.id, base.process_allocator()) }
	delete(f.regions)
	f^ = {}
}

vtt_cue_destroy :: proc(c: ^Vtt_Cue) {
	al := base.process_allocator()
	delete(c.id, al)
	delete(c.region, al)
	delete(c.raw, al)
	for &r in c.runs { vtt_run_destroy(&r) }
	delete(c.runs, al)
	c^ = {}
}

@(private = "file")
vtt_run_destroy :: proc(r: ^Vtt_Run) {
	al := base.process_allocator()
	delete(r.text, al)
	for s in r.classes { delete(s, al) }
	delete(r.classes, al)
	delete(r.voice, al)
	delete(r.lang, al)
}

// Parses a whole WebVTT file. The returned Vtt_File owns its strings (process allocator) and must be vtt_destroy'd.
vtt_parse :: proc(input: string) -> Vtt_File {
	f := Vtt_File{cues = make([dynamic]Vtt_Cue), regions = make([dynamic]Vtt_Region)}
	// a byte-order mark is skipped; CRLF and CR are read as LF
	src := input
	if strings.has_prefix(src, "\ufeff") { src = src[3:] }
	text, _ := strings.replace_all(src, "\r\n", "\n", context.temp_allocator)
	text, _ = strings.replace_all(text, "\r", "\n", context.temp_allocator)
	lines := strings.split(text, "\n", context.temp_allocator)
	if len(lines) == 0 { return f }
	// the signature: "WEBVTT", optionally followed by a space/tab and anything
	sig := lines[0]
	if !(sig == "WEBVTT" || strings.has_prefix(sig, "WEBVTT\t") || strings.has_prefix(sig, "WEBVTT ")) {
		return f   // not a WebVTT file: ok stays false
	}
	f.ok = true
	i := 1
	// the region / style / rest of the header: blocks separated by blank lines, until the first cue
	for i < len(lines) {
		// skip blank lines between blocks
		for i < len(lines) && strings.trim_space(lines[i]) == "" { i += 1 }
		if i >= len(lines) { break }
		// gather the block (up to the next blank line)
		start := i
		for i < len(lines) && strings.trim_space(lines[i]) != "" { i += 1 }
		block := lines[start:i]
		vtt_block(&f, block)
	}
	return f
}

@(private = "file")
vtt_block :: proc(f: ^Vtt_File, block: []string) {
	if len(block) == 0 { return }
	first := block[0]
	switch {
	case first == "NOTE" || strings.has_prefix(first, "NOTE ") || strings.has_prefix(first, "NOTE\t"):
		return   // a comment block
	case first == "STYLE":
		return   // ::cue style rules are kept by the page layer, not needed for the cue model
	case first == "REGION":
		vtt_region(f, block[1:])
		return
	}
	// a cue block: an optional identifier line, then the timing line, then the payload
	idx := 0
	id := ""
	if !strings.contains(first, "-->") {
		id = first
		idx = 1
	}
	if idx >= len(block) { return }
	timing := block[idx]
	start, end, settings, tok := vtt_timing(timing)
	if !tok { return }
	cue := Vtt_Cue{
		start = start, end = end,
		snap_to_lines = true,
		line = f64_nan(), position = f64_nan(), size = 100, align = .Center,
		line_align = .Start, position_align = .Auto,
	}
	al := base.process_allocator()
	if id != "" { cue.id = strings.clone(id, al) }
	vtt_cue_settings(&cue, settings)
	// the payload: the lines after the timing, joined with newlines
	payload := strings.join(block[idx + 1:], "\n", context.temp_allocator)
	cue.raw = strings.clone(payload, al)
	cue.runs = vtt_payload(payload)
	append(&f.cues, cue)
}

// "00:00:01.000 --> 00:00:04.000 settings...": the two times and the trailing settings string.
@(private = "file")
vtt_timing :: proc(line: string) -> (start, end: Time, settings: string, ok: bool) {
	arrow := strings.index(line, "-->")
	if arrow < 0 { return }
	left := strings.trim_space(line[:arrow])
	right := strings.trim_space(line[arrow + 3:])
	s, sok := vtt_time(left)
	if !sok { return }
	// the end time is the first whitespace-separated token of the right side; the rest is settings
	sp := strings.index_any(right, " \t")
	end_str := right
	if sp >= 0 { end_str = right[:sp]; settings = strings.trim_space(right[sp:]) }
	e, eok := vtt_time(end_str)
	if !eok { return }
	return s, e, settings, true
}

// A WebVTT timestamp: [hh:]mm:ss.ttt.
@(private = "file")
vtt_time :: proc(s: string) -> (Time, bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 3 { return 0, false }
	hh, mm := 0, 0
	sec_frac := ""
	if len(parts) == 3 {
		h, hok := strconv.parse_int(parts[0])
		if !hok { return 0, false }
		hh = h
		mm_v, mok := strconv.parse_int(parts[1])
		if !mok { return 0, false }
		mm = mm_v
		sec_frac = parts[2]
	} else {
		mm_v, mok := strconv.parse_int(parts[0])
		if !mok { return 0, false }
		mm = mm_v
		sec_frac = parts[1]
	}
	dot := strings.index(sec_frac, ".")
	if dot < 0 { return 0, false }
	ss, sok := strconv.parse_int(sec_frac[:dot])
	if !sok { return 0, false }
	ms_str := sec_frac[dot + 1:]
	if len(ms_str) != 3 { return 0, false }
	ms, mmsok := strconv.parse_int(ms_str)
	if !mmsok { return 0, false }
	total := f64(hh) * 3600 + f64(mm) * 60 + f64(ss) + f64(ms) / 1000
	return seconds_time(total), true
}

// The cue settings: "vertical:rl line:10 position:50% size:80% align:start region:r1".
@(private = "file")
vtt_cue_settings :: proc(cue: ^Vtt_Cue, settings: string) {
	if settings == "" { return }
	al := base.process_allocator()
	for tok in strings.fields(settings) {
		colon := strings.index(tok, ":")
		if colon < 0 { continue }
		key := tok[:colon]
		val := tok[colon + 1:]
		switch key {
		case "vertical":
			switch val {
			case "rl": cue.vertical = 'r'
			case "lr": cue.vertical = 'l'
			}
		case "line":
			// "line:NN" or "line:NN%" with an optional ",start|center|end"
			v := val
			if comma := strings.index(v, ","); comma >= 0 {
				switch v[comma + 1:] {
				case "start": cue.line_align = .Start
				case "center": cue.line_align = .Center
				case "end": cue.line_align = .End
				}
				v = v[:comma]
			}
			if strings.has_suffix(v, "%") {
				cue.snap_to_lines = false
				if n, ok := strconv.parse_f64(v[:len(v) - 1]); ok { cue.line = n }
			} else {
				cue.snap_to_lines = true
				if n, ok := strconv.parse_f64(v); ok { cue.line = n }
			}
		case "position":
			v := val
			if comma := strings.index(v, ","); comma >= 0 {
				switch v[comma + 1:] {
				case "line-left": cue.position_align = .Line_Left
				case "center": cue.position_align = .Center
				case "line-right": cue.position_align = .Line_Right
				}
				v = v[:comma]
			}
			if strings.has_suffix(v, "%") { if n, ok := strconv.parse_f64(v[:len(v) - 1]); ok { cue.position = n } }
		case "size":
			if strings.has_suffix(val, "%") { if n, ok := strconv.parse_f64(val[:len(val) - 1]); ok { cue.size = n } }
		case "align":
			switch val {
			case "start": cue.align = .Start
			case "center", "middle": cue.align = .Center
			case "end": cue.align = .End
			case "left": cue.align = .Left
			case "right": cue.align = .Right
			}
		case "region":
			cue.region = strings.clone(val, al)
		}
	}
}

@(private = "file")
vtt_region :: proc(f: ^Vtt_File, lines: []string) {
	al := base.process_allocator()
	r := Vtt_Region{width = 100, lines = 3, region_anchor = {0, 100}, viewport_anchor = {0, 100}}
	settings := strings.join(lines, " ", context.temp_allocator)
	for tok in strings.fields(settings) {
		colon := strings.index(tok, ":")
		if colon < 0 { continue }
		key, val := tok[:colon], tok[colon + 1:]
		switch key {
		case "id": r.id = strings.clone(val, al)
		case "width": if strings.has_suffix(val, "%") { if n, ok := strconv.parse_f64(val[:len(val) - 1]); ok { r.width = n } }
		case "lines": if n, ok := strconv.parse_int(val); ok { r.lines = n }
		case "regionanchor": r.region_anchor = vtt_percent_pair(val)
		case "viewportanchor": r.viewport_anchor = vtt_percent_pair(val)
		case "scroll": r.scroll = val == "up"
		}
	}
	append(&f.regions, r)
}

@(private = "file")
vtt_percent_pair :: proc(s: string) -> [2]f64 {
	out: [2]f64
	comma := strings.index(s, ",")
	if comma < 0 { return out }
	a := strings.trim_suffix(s[:comma], "%")
	b := strings.trim_suffix(s[comma + 1:], "%")
	if n, ok := strconv.parse_f64(a); ok { out[0] = n }
	if n, ok := strconv.parse_f64(b); ok { out[1] = n }
	return out
}

////////////////////////////////
// The cue payload: a small recursive-descent parse of the inline markup into flattened runs.

@(private = "file")
Vtt_Fmt :: struct {
	bold, italic, underline, ruby, rt: bool,
	classes: [dynamic]string,
	voice:   string,
	lang:    string,
}

// Produces the flattened runs of a cue payload. Timestamps (<00:00:01.000>) split a run but carry no formatting here;
// a line feed in the source becomes a newline run. Entities (&amp; &lt; &gt; &nbsp; &lrm; &rlm;) are decoded.
@(private = "file")
vtt_payload :: proc(payload: string) -> []Vtt_Run {
	al := base.process_allocator()
	runs := make([dynamic]Vtt_Run, al)
	fmt_state := Vtt_Fmt{}
	stack := make([dynamic]string, context.temp_allocator)   // the open tag names, for matching end tags
	cur := strings.builder_make(context.temp_allocator)

	flush := proc(runs: ^[dynamic]Vtt_Run, cur: ^strings.Builder, st: ^Vtt_Fmt) {
		if strings.builder_len(cur^) == 0 { return }
		al := base.process_allocator()
		classes := make([]string, len(st.classes), al)
		for c, i in st.classes { classes[i] = strings.clone(c, al) }
		append(runs, Vtt_Run{
			text = strings.clone(strings.to_string(cur^), al),
			bold = st.bold, italic = st.italic, underline = st.underline,
			ruby = st.ruby, rt = st.rt,
			classes = classes,
			voice = strings.clone(st.voice, al),
			lang = strings.clone(st.lang, al),
		})
		strings.builder_reset(cur)
	}

	i := 0
	n := len(payload)
	for i < n {
		c := payload[i]
		switch c {
		case '\n':
			flush(&runs, &cur, &fmt_state)
			append(&runs, Vtt_Run{newline = true})
			i += 1
		case '&':
			semi := strings.index(payload[i:], ";")
			if semi > 0 && semi <= 10 {
				ent := payload[i + 1:i + semi]
				repl := vtt_entity(ent)
				if repl != "" { strings.write_string(&cur, repl); i += semi + 1; continue }
			}
			strings.write_byte(&cur, c)
			i += 1
		case '<':
			end := strings.index(payload[i:], ">")
			if end < 0 { strings.write_byte(&cur, c); i += 1; continue }
			tag := payload[i + 1:i + end]
			i += end + 1
			flush(&runs, &cur, &fmt_state)
			vtt_tag(tag, &fmt_state, &stack)
		case:
			strings.write_byte(&cur, c)
			i += 1
		}
	}
	flush(&runs, &cur, &fmt_state)
	// the format state's dynamic class stack is temp-allocated; nothing of `fmt_state` is kept past here
	delete(fmt_state.classes)
	return runs[:]
}

// Applies one tag (its text between < and >) to the formatting state.
@(private = "file")
vtt_tag :: proc(tag: string, st: ^Vtt_Fmt, stack: ^[dynamic]string) {
	if tag == "" { return }
	// an internal timestamp <00:00:01.000> only splits runs
	if tag[0] >= '0' && tag[0] <= '9' { return }
	if tag[0] == '/' {
		name := tag[1:]
		switch name {
		case "b": st.bold = false
		case "i": st.italic = false
		case "u": st.underline = false
		case "ruby": st.ruby = false
		case "rt": st.rt = false
		case "c": if len(st.classes) > 0 { delete(st.classes[len(st.classes) - 1]); pop(&st.classes) }
		case "v": delete(st.voice, base.process_allocator()); st.voice = ""
		case "lang": delete(st.lang, base.process_allocator()); st.lang = ""
		}
		if len(stack) > 0 { pop(stack) }   // stack is already a pointer parameter
		return
	}
	// the tag name is up to the first '.' (class list) or whitespace (annotation such as the <v Name>)
	name := tag
	rest := ""
	if sp := strings.index_any(tag, " \t"); sp >= 0 { name, rest = tag[:sp], strings.trim_space(tag[sp + 1:]) }
	classes := ""
	if dot := strings.index(name, "."); dot >= 0 { name, classes = name[:dot], name[dot + 1:] }
	al := base.process_allocator()
	switch name {
	case "b": st.bold = true
	case "i": st.italic = true
	case "u": st.underline = true
	case "ruby": st.ruby = true
	case "rt": st.rt = true
	case "c":
		cls := classes
		cls, _ = strings.replace_all(cls, ".", " ", context.temp_allocator)
		append(&st.classes, strings.clone(strings.trim_space(cls), al))
	case "v":
		delete(st.voice, al); st.voice = strings.clone(rest, al)
	case "lang":
		delete(st.lang, al); st.lang = strings.clone(rest, al)
	}
	append(stack, name)
}

@(private = "file")
vtt_entity :: proc(name: string) -> string {
	switch name {
	case "amp": return "&"
	case "lt": return "<"
	case "gt": return ">"
	case "nbsp": return "\u00a0"
	case "lrm": return "\u200e"
	case "rlm": return "\u200f"
	}
	return ""
}

@(private = "file")
f64_nan :: proc() -> f64 {
	bits := u64(0x7FF8000000000000)
	return transmute(f64)bits
}

// A cue built around a text payload with the default settings (new VTTCue / cue.text = ...). Owns its strings.
vtt_cue_from_text :: proc(text: string) -> Vtt_Cue {
	al := base.process_allocator()
	return Vtt_Cue{
		snap_to_lines = true,
		line = f64_nan(), position = f64_nan(), size = 100, align = .Center,
		line_align = .Start, position_align = .Auto,
		raw = strings.clone(text, al),
		runs = vtt_payload(text),
	}
}

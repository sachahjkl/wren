package style

import "core:strings"
import "wb:css"

// CSS Grid 2 values, parsed into structures for the grid layout: track lists with line names and repeat(), template
// areas, auto tracks and line placement.

@(private)
is_line_names :: #force_inline proc(v: css.Value) -> bool { return v.kind == .Block && v.tok.kind == .Open_Square }

@(private)
parse_line_names :: proc(cx: ^Cx, v: css.Value) -> ([]string, bool) {
	out := make([dynamic]string, cx.alloc)
	for it in v.children {
		if css.is_ws_value(it) { continue }
		if !tok_is(it, .Ident) { return nil, false }
		switch ident_lower(it) { case "span", "auto": return nil, false }
		append(&out, strings.clone(it.tok.text, cx.alloc))
	}
	return out[:], true
}

@(private)
parse_breadth :: proc(cx: ^Cx, v: css.Value, allow_flex: bool) -> (Track_Breadth, bool) {
	switch ident_lower(v) {
	case "auto": return Track_Breadth{kind = .Auto}, true
	case "min-content": return Track_Breadth{kind = .Min_Content}, true
	case "max-content": return Track_Breadth{kind = .Max_Content}, true
	case "": 
	case: return {}, false
	}
	if tok_is(v, .Dimension) && strings.equal_fold(v.tok.text, "fr") {
		if !allow_flex || v.tok.num < 0 { return {}, false }
		return Track_Breadth{kind = .Fr, fr = f32(v.tok.num)}, true
	}
	l, ok := length_of(cx, v, {.Percent})
	if !ok { return {}, false }
	return Track_Breadth{kind = .Length, len = l}, true
}

@(private)
parse_track_size :: proc(cx: ^Cx, v: css.Value) -> (Grid_Track, bool) {
	if v.kind == .Function {
		args := css.split_commas(v.children, context.temp_allocator)
		switch css.lower_temp(v.tok.text) {
		case "minmax":
			if len(args) != 2 { return {}, false }
			a, b := css.trim_values(args[0]), css.trim_values(args[1])
			if len(a) != 1 || len(b) != 1 { return {}, false }
			mn, ok1 := parse_breadth(cx, a[0], false)
			mx, ok2 := parse_breadth(cx, b[0], true)
			if !ok1 || !ok2 { return {}, false }
			return Grid_Track{kind = .Minmax, min = mn, max = mx}, true
		case "fit-content":
			a := css.trim_values(v.children)
			if len(a) != 1 { return {}, false }
			l, ok := length_of(cx, a[0], {.Percent})
			if !ok { return {}, false }
			return Grid_Track{kind = .Fit_Content, min = {kind = .Auto}, max = {kind = .Length, len = l}}, true
		case "calc", "min", "max", "clamp":
		case: return {}, false
		}
	}
	b, ok := parse_breadth(cx, v, true)
	if !ok { return {}, false }
	return Grid_Track{kind = .Breadth, min = b, max = b}, true
}

// A track list: [names]? track [names]? track ... [names]?. Returns the tracks and the names after the last one.
@(private)
parse_track_list :: proc(cx: ^Cx, items: []css.Value, allow_repeat: bool) -> (tracks: []Grid_Track, end_names: []string, ok: bool) {
	out := make([dynamic]Grid_Track, cx.alloc)
	pending: []string
	auto_repeats := 0
	for it in items {
		if is_line_names(it) {
			names, good := parse_line_names(cx, it)
			if !good { return nil, nil, false }
			if pending != nil {   // two name lists in a row merge
				merged := make([]string, len(pending) + len(names), cx.alloc)
				copy(merged, pending)
				copy(merged[len(pending):], names)
				names = merged
			}
			pending = names
			continue
		}
		t: Grid_Track
		if it.kind == .Function && strings.equal_fold(it.tok.text, "repeat") {
			if !allow_repeat { return nil, nil, false }
			args := css.split_commas(it.children, context.temp_allocator)
			if len(args) != 2 { return nil, nil, false }
			head := css.trim_values(args[0])
			if len(head) != 1 { return nil, nil, false }
			t.kind = .Repeat
			switch ident_lower(head[0]) {
			case "auto-fill": t.repeat = .Auto_Fill; auto_repeats += 1
			case "auto-fit": t.repeat = .Auto_Fit; auto_repeats += 1
			case:
				n, good := css.parse_integer(head)
				if !good || n < 1 { return nil, nil, false }
				t.repeat, t.count = .Count, i32(min(n, 10_000))
			}
			inner, inner_end, good := parse_track_list(cx, split_items(args[1]), false)
			if !good || len(inner) == 0 { return nil, nil, false }
			t.tracks, t.end_names = inner, inner_end
		} else {
			good: bool
			t, good = parse_track_size(cx, it)
			if !good { return nil, nil, false }
		}
		t.names_before = pending
		pending = nil
		append(&out, t)
	}
	if auto_repeats > 1 || len(out) == 0 { return nil, nil, false }
	return out[:], pending, true
}

parse_grid_template :: proc(cx: ^Cx, vs: []css.Value) -> (Grid_Template, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 0 { return {}, false }
	switch ident_lower(items[0]) {
	case "none":
		if len(items) != 1 { return {}, false }
		return Grid_Template{kind = .None}, true
	case "masonry":
		if len(items) != 1 { return {}, false }
		return Grid_Template{kind = .Masonry}, true
	case "subgrid":
		g := Grid_Template{kind = .Subgrid}
		names := make([dynamic]Grid_Track, cx.alloc)
		for it in items[1:] {
			if !is_line_names(it) { return {}, false }
			n, ok := parse_line_names(cx, it)
			if !ok { return {}, false }
			append(&names, Grid_Track{names_before = n})
		}
		g.tracks = names[:]
		return g, true
	}
	tracks, end, ok := parse_track_list(cx, items, true)
	if !ok { return {}, false }
	return Grid_Template{kind = .Tracks, tracks = tracks, end_names = end}, true
}

parse_grid_auto_tracks :: proc(cx: ^Cx, vs: []css.Value) -> ([]Grid_Track, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 0 { return nil, false }
	out := make([]Grid_Track, len(items), cx.alloc)
	for it, i in items {
		t, ok := parse_track_size(cx, it)
		if !ok { return nil, false }
		out[i] = t
	}
	return out, true
}

// grid-template-areas: one string per row; every named area must be a filled rectangle.
parse_grid_areas :: proc(cx: ^Cx, vs: []css.Value) -> (Grid_Areas, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return {}, true }
	rows := make([dynamic][]string, context.temp_allocator)
	cols := -1
	for it in items {
		if !tok_is(it, .String) { return {}, false }
		row := areas_row(it.tok.text)
		if len(row) == 0 { return {}, false }
		if cols >= 0 && len(row) != cols { return {}, false }
		cols = len(row)
		append(&rows, row)
	}
	if len(rows) == 0 { return {}, false }
	ga := Grid_Areas{rows = i32(len(rows)), cols = i32(cols)}
	ga.cells = make([]string, len(rows) * cols, cx.alloc)
	for r, i in rows { for name, j in r { ga.cells[i * cols + j] = strings.clone(name, cx.alloc) } }
	seen := make(map[string]int, context.temp_allocator)
	areas := make([dynamic]Grid_Area, cx.alloc)
	for i in 0 ..< len(rows) {
		for j in 0 ..< cols {
			name := ga.cells[i * cols + j]
			if name == "" { continue }
			if name in seen { continue }   // checked below: the area's cells are exactly its rectangle
			// a new area: its extent is the run to the right and down from its top-left cell
			w := 1
			for j + w < cols && ga.cells[i * cols + j + w] == name { w += 1 }
			h := 1
			for i + h < len(rows) && ga.cells[(i + h) * cols + j] == name { h += 1 }
			for y in i ..< i + h { for x in j ..< j + w { if ga.cells[y * cols + x] != name { return {}, false } } }
			seen[name] = len(areas)
			append(&areas, Grid_Area{name = name, row_start = i32(i + 1), row_end = i32(i + h + 1), col_start = i32(j + 1), col_end = i32(j + w + 1)})
		}
	}
	// every cell of an area's rectangle carries its name, and no cell outside it does
	for a in areas {
		count := 0
		for cell in ga.cells { if cell == a.name { count += 1 } }
		if count != int((a.row_end - a.row_start) * (a.col_end - a.col_start)) { return {}, false }
	}
	ga.areas = areas[:]
	return ga, true
}

// The cells of one row string: names, and "" for each run of dots. A character that is neither is a trash token, which
// makes the declaration invalid (returned as an empty row).
@(private)
areas_row :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(s) {
		ch := s[i]
		if ch == ' ' || ch == '\t' || ch == '\n' { i += 1; continue }
		if ch == '.' {
			for i < len(s) && s[i] == '.' { i += 1 }
			append(&out, "")
			continue
		}
		start := i
		for i < len(s) {
			c := s[i]
			if c == ' ' || c == '\t' || c == '\n' || c == '.' { break }
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c >= 0x80) { return nil }
			i += 1
		}
		append(&out, s[start:i])
	}
	return out[:]
}

parse_grid_line :: proc(cx: ^Cx, vs: []css.Value) -> (Grid_Line, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 0 || len(items) > 3 { return {}, false }
	if len(items) == 1 && ident_lower(items[0]) == "auto" { return Grid_Line{kind = .Auto}, true }
	gl: Grid_Line
	span := false
	have_n := false
	for it in items {
		if ident_lower(it) == "span" {
			if span { return {}, false }
			span = true
			continue
		}
		if tok_is(it, .Number) {
			if !it.tok.is_int || have_n || it.tok.num == 0 { return {}, false }
			gl.n, have_n = i32(clamp(it.tok.num, -10_000, 10_000)), true
			continue
		}
		if tok_is(it, .Ident) {
			switch ident_lower(it) { case "auto", "span", "initial", "inherit", "unset", "default": return {}, false }
			if gl.name != "" { return {}, false }
			gl.name = strings.clone(it.tok.text, cx.alloc)
			continue
		}
		return {}, false
	}
	switch {
	case span:
		if have_n && gl.n < 0 { return {}, false }
		if !have_n { gl.n = 1 }
		gl.kind = .Span
	case have_n: gl.kind = .Line
	case gl.name != "": gl.kind = .Name
	case: return {}, false
	}
	return gl, true
}

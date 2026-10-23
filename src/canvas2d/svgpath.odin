package canvas2d

import "core:math"
import "core:strconv"

// SVG path data ("M 10 10 L 20 20 C ... Z") appended to a path, for `new Path2D(d)`. Interpreted as SVG says: relative
// commands, implicit repeats, smooth curves (S, T), arcs (A) from their endpoint form. At the first error the parsing
// stops and what came before stays. Points go in as written (an identity transform).
path_add_svg :: proc(p: ^Path, d: string) {
	r := Svg_Reader{s = d}
	cur, start, last_ctrl: [2]f64
	cmd: u8
	prev: u8   // the command before this one, for the reflection of S and T
	first := true
	for {
		svg_skip(&r, true)
		if r.i >= len(r.s) { break }
		c := r.s[r.i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			if !svg_is_command(c) { return }
			cmd = c
			r.i += 1
			if first && cmd != 'M' && cmd != 'm' { return }
			first = false
			if cmd == 'Z' || cmd == 'z' {
				path_close(p)
				cur = start
				prev = 'Z'
				continue
			}
		} else if cmd == 0 || cmd == 'Z' || cmd == 'z' {
			return   // numbers with no command to take them
		}
		rel := cmd >= 'a'
		n: [7]f64
		count := 0
		switch cmd {
		case 'M', 'm', 'L', 'l', 'T', 't': count = 2
		case 'H', 'h', 'V', 'v': count = 1
		case 'C', 'c': count = 6
		case 'S', 's', 'Q', 'q': count = 4
		case 'A', 'a': count = 7
		}
		for k in 0 ..< count {
			ok: bool
			if cmd == 'A' || cmd == 'a' {
				if k == 3 || k == 4 { n[k], ok = svg_flag(&r) } else { n[k], ok = svg_number(&r) }
			} else {
				n[k], ok = svg_number(&r)
			}
			if !ok { return }
		}
		ox, oy := rel ? cur.x : 0.0, rel ? cur.y : 0.0
		switch cmd {
		case 'M', 'm':
			cur = {n[0] + ox, n[1] + oy}
			start = cur
			path_move_to(p, IDENTITY, cur.x, cur.y)
			cmd = rel ? 'l' : 'L'   // further pairs are lines
			prev = 'M'
		case 'L', 'l':
			cur = {n[0] + ox, n[1] + oy}
			path_line_to(p, IDENTITY, cur.x, cur.y)
			prev = 'L'
		case 'H', 'h':
			cur.x = n[0] + ox
			path_line_to(p, IDENTITY, cur.x, cur.y)
			prev = 'L'
		case 'V', 'v':
			cur.y = n[0] + oy
			path_line_to(p, IDENTITY, cur.x, cur.y)
			prev = 'L'
		case 'C', 'c':
			c1, c2, e := [2]f64{n[0] + ox, n[1] + oy}, [2]f64{n[2] + ox, n[3] + oy}, [2]f64{n[4] + ox, n[5] + oy}
			path_cubic_to(p, IDENTITY, c1.x, c1.y, c2.x, c2.y, e.x, e.y)
			last_ctrl, cur, prev = c2, e, 'C'
		case 'S', 's':
			c1 := cur
			if prev == 'C' { c1 = 2 * cur - last_ctrl }
			c2, e := [2]f64{n[0] + ox, n[1] + oy}, [2]f64{n[2] + ox, n[3] + oy}
			path_cubic_to(p, IDENTITY, c1.x, c1.y, c2.x, c2.y, e.x, e.y)
			last_ctrl, cur, prev = c2, e, 'C'
		case 'Q', 'q':
			c1, e := [2]f64{n[0] + ox, n[1] + oy}, [2]f64{n[2] + ox, n[3] + oy}
			path_quad_to(p, IDENTITY, c1.x, c1.y, e.x, e.y)
			last_ctrl, cur, prev = c1, e, 'Q'
		case 'T', 't':
			c1 := cur
			if prev == 'Q' { c1 = 2 * cur - last_ctrl }
			e := [2]f64{n[0] + ox, n[1] + oy}
			path_quad_to(p, IDENTITY, c1.x, c1.y, e.x, e.y)
			last_ctrl, cur, prev = c1, e, 'Q'
		case 'A', 'a':
			e := [2]f64{n[5] + ox, n[6] + oy}
			svg_arc(p, cur, n[0], n[1], n[2], n[3] != 0, n[4] != 0, e)
			cur, prev = e, 'A'
		}
	}
}

@(private)
Svg_Reader :: struct {
	s: string,
	i: int,
}

@(private)
svg_is_command :: proc(c: u8) -> bool {
	switch c {
	case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z': return true
	}
	return false
}

@(private)
svg_skip :: proc(r: ^Svg_Reader, commas: bool) {
	for r.i < len(r.s) {
		c := r.s[r.i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || (commas && c == ',') { r.i += 1 } else { break }
	}
}

// A number, after white space and at most one comma.
@(private)
svg_number :: proc(r: ^Svg_Reader) -> (v: f64, ok: bool) {
	svg_skip(r, false)
	if r.i < len(r.s) && r.s[r.i] == ',' { r.i += 1; svg_skip(r, false) }
	start := r.i
	i := r.i
	s := r.s
	if i < len(s) && (s[i] == '+' || s[i] == '-') { i += 1 }
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' { i += 1; digits += 1 }
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' { i += 1; digits += 1 }
	}
	if digits == 0 { return }
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') { j += 1 }
		if j < len(s) && s[j] >= '0' && s[j] <= '9' {
			for j < len(s) && s[j] >= '0' && s[j] <= '9' { j += 1 }
			i = j
		}
	}
	v, ok = strconv.parse_f64(s[start:i])
	if ok && !is_finite(v) { return 0, false }
	r.i = i
	return
}

// An arc flag: one character, 0 or 1, with nothing required after it.
@(private)
svg_flag :: proc(r: ^Svg_Reader) -> (v: f64, ok: bool) {
	svg_skip(r, false)
	if r.i < len(r.s) && r.s[r.i] == ',' { r.i += 1; svg_skip(r, false) }
	if r.i >= len(r.s) || (r.s[r.i] != '0' && r.s[r.i] != '1') { return }
	v = f64(r.s[r.i] - '0')
	r.i += 1
	return v, true
}

// SVG F.6: an elliptical arc from `from` to `to` in endpoint form, as Béziers.
@(private)
svg_arc :: proc(p: ^Path, from: [2]f64, rx_in, ry_in, rot_deg: f64, large, sweep: bool, to: [2]f64) {
	rx, ry := abs(rx_in), abs(ry_in)
	if from == to { return }
	if rx == 0 || ry == 0 { path_line_to(p, IDENTITY, to.x, to.y); return }
	phi := rot_deg * math.PI / 180
	cp, sp := math.cos(phi), math.sin(phi)
	dx, dy := (from.x - to.x) * 0.5, (from.y - to.y) * 0.5
	x1p, y1p := cp * dx + sp * dy, -sp * dx + cp * dy
	// radii too small to span the points are scaled up
	lambda := x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
	if lambda > 1 { s := math.sqrt(lambda); rx, ry = rx * s, ry * s }
	num := rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
	den := rx * rx * y1p * y1p + ry * ry * x1p * x1p
	coef := den == 0 ? 0.0 : math.sqrt(max(num / den, 0))
	if large == sweep { coef = -coef }
	cxp, cyp := coef * rx * y1p / ry, -coef * ry * x1p / rx
	cx, cy := cp * cxp - sp * cyp + (from.x + to.x) * 0.5, sp * cxp + cp * cyp + (from.y + to.y) * 0.5
	ang :: proc(ux, uy, vx, vy: f64) -> f64 { return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
	t1 := ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
	dt := ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
	if !sweep && dt > 0 { dt -= 2 * math.PI }
	if sweep && dt < 0 { dt += 2 * math.PI }
	to_dev := matrix_mul(matrix_translate(cx, cy), matrix_mul(matrix_rotate(phi), matrix_scale(rx, ry)))
	arc_segments(p, to_dev, t1, dt)
}

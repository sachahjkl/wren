// The WPT conformance chart and table, built at generation time from the git history of wpt/expectations (the port of
// the reference wpt_history.js + make_chart.js). For each commit that touched wpt/expectations we count, over every
// .txt expectation file, the subtests whose recorded result is exactly PASS — one data point per commit. Two series:
// `pass` over every folder measured at that moment (new folders raise it), and `stable` over only the folders that
// existed at the first commit (progress at a fixed scope). The chart is one self-contained inline SVG; the table is
// the current pass rate by folder (and uses build/wpt/report.md if a run produced one).
//
// git is run through os.process_exec; if git is not available or the history is empty, the chart falls back to a note
// so the page still builds. The numbers are read from git, never typed, so they cannot drift from the recorded data.
package docsite

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Commit :: struct {
	hash:         string,
	date:         string, // ISO 8601
	subject:      string,
	pass:         int,
	total:        int,
	stable_pass:  int,
	stable_total: int,
}

Folder_Stat :: struct {
	name:  string,
	pass:  int,
	total: int,
}

// --- running git ------------------------------------------------------------

git :: proc(repo: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", repo)
	for a in args { append(&cmd, a) }
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd[:]}, context.allocator)
	if err != nil { return "", false }
	if !state.exited || state.exit_code != 0 { return string(stdout), false }
	return string(stdout), true
}

// --- history ----------------------------------------------------------------
// The history is a committed snapshot (docs/_wpt_history.tsv), not read from git on every run: a CI checkout is shallow, so
// the same docs would give another chart there and `-check` could never agree. `docsite -chart-update` (tools\docs_site.ps1
// -ChartUpdate, at a release) rebuilds the snapshot from the full git history; a missing snapshot is built the same way.
CHART_CACHE :: "docs/_wpt_history.tsv"
chart_update := false

wpt_history :: proc(repo: string) -> []Commit {
	if !chart_update {
		if data, err := os.read_entire_file(CHART_CACHE, context.allocator); err == nil {
			commits := make([dynamic]Commit, context.allocator)
			for line in strings.split_lines(string(data), context.temp_allocator) {
				t := strings.trim_right_space(line)
				if len(t) == 0 || t[0] == '#' { continue }
				f := strings.split_n(t, "\t", 7, context.temp_allocator)
				if len(f) < 6 { continue }
				c := Commit{hash = strings.clone(f[0]), date = strings.clone(f[1]), pass = atoi(f[2]), total = atoi(f[3]), stable_pass = atoi(f[4]), stable_total = atoi(f[5])}
				if len(f) == 7 { c.subject = strings.clone(f[6]) }
				append(&commits, c)
			}
			if len(commits) > 0 { return commits[:] }
		}
	}
	commits := wpt_history_from_git(repo)
	if len(commits) > 0 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "# one line per commit that touched wpt/expectations: hash, date, passing, total, passing (first folders), total (first folders), subject\n# rebuilt by `docsite -chart-update`\n")
		for c in commits { fmt.sbprintf(&b, "%s\t%s\t%d\t%d\t%d\t%d\t%s\n", c.hash, c.date, c.pass, c.total, c.stable_pass, c.stable_total, c.subject) }
		_ = os.write_entire_file(CHART_CACHE, transmute([]u8)strings.to_string(b))
	}
	return commits
}

wpt_history_from_git :: proc(repo: string) -> []Commit {
	log, ok := git(repo, "log", "--reverse", "--format=%H|%aI|%s", "--", "wpt/expectations")
	if !ok { return nil }
	commits := make([dynamic]Commit, context.allocator)
	for line in strings.split_lines(log, context.temp_allocator) {
		t := strings.trim_right_space(line)
		if len(t) == 0 { continue }
		parts := strings.split_n(t, "|", 3, context.temp_allocator)
		if len(parts) < 2 { continue }
		c := Commit{hash = strings.clone(parts[0]), date = strings.clone(parts[1])}
		if len(parts) == 3 { c.subject = strings.clone(parts[2]) }
		append(&commits, c)
	}
	if len(commits) == 0 { return nil }

	// First pass: the raw per-folder counts of each commit. Two `git grep -c` passes (every subtest line, then the
	// PASS lines) over the .txt expectations: one process each, instead of one `git show` per file. The grep output
	// is "<commit>:<path>:<count>" per file.
	all_totals := make([][]Folder_Stat, len(commits), context.temp_allocator)
	all_passes := make([][]Folder_Stat, len(commits), context.temp_allocator)
	for &c, i in commits {
		all_totals[i] = counts_list(grep_counts(repo, c.hash, false))
		all_passes[i] = counts_list(grep_counts(repo, c.hash, true))
	}

	// The "stable" scope is the set of folders measured at the first commit that actually has any passing subtests
	// (the earliest commits may touch the path before any expectations exist there), matching the reference chart.
	first_folders := make(map[string]bool, context.temp_allocator)
	for passes, i in all_passes {
		sum := 0
		for s in passes { sum += s.pass }
		if sum > 0 {
			for s in all_totals[i] { first_folders[s.name] = true }
			break
		}
	}

	for &c, i in commits {
		pass, total, sp, st := 0, 0, 0, 0
		for s in all_totals[i] {
			total += s.total
			if s.name in first_folders { st += s.total }
		}
		for s in all_passes[i] {
			pass += s.pass
			if s.name in first_folders { sp += s.pass }
		}
		c.pass = pass
		c.total = total
		c.stable_pass = sp
		c.stable_total = st
	}
	return commits[:]
}

// Turn a folder-key -> count map into a stable list (the Folder_Stat.pass/total both hold the count; the caller
// decides which it is).
counts_list :: proc(m: map[string]int) -> []Folder_Stat {
	out := make([dynamic]Folder_Stat, context.temp_allocator)
	for key, n in m { append(&out, Folder_Stat{name = key, pass = n, total = n}) }
	return out[:]
}

// Count, per folder, the subtest lines of a commit's expectation files: `pass_only` restricts to lines that end in
// ": PASS", otherwise every subtest line (a line that begins with a tab). Returns folder-key -> count.
grep_counts :: proc(repo: string, commit: string, pass_only: bool) -> map[string]int {
	m := make(map[string]int, context.temp_allocator)
	pattern := pass_only ? "^\t.*: PASS$" : "^\t"
	out, ok := git(repo, "grep", "-c", "-P", pattern, commit, "--", "wpt/expectations/*.txt")
	if !ok { return m } // grep exits non-zero when there are no matches at all
	for line in strings.split_lines(out, context.temp_allocator) {
		t := strings.trim_right_space(line)
		if len(t) == 0 { continue }
		// "<commit>:<path>:<count>"
		last := strings.last_index_byte(t, ':')
		if last < 0 { continue }
		n := atoi(t[last + 1:])
		rest := t[:last]
		p := strings.last_index_byte(rest, ':')
		if p < 0 { continue }
		path := rest[p + 1:]
		m[folder_key(path)] += n
	}
	return m
}

// "wpt/expectations/css/foo.txt" -> "css/foo"
folder_key :: proc(path: string) -> string {
	k := strings.trim_prefix(path, "wpt/expectations/")
	k = strings.trim_suffix(k, ".txt")
	return k
}

// --- the chart (inline SVG) -------------------------------------------------

build_wpt_chart :: proc(repo: string) -> string {
	commits := wpt_history(repo)
	// keep only commits with any pass, as the reference does
	rows := make([dynamic]Commit, context.temp_allocator)
	for c in commits { if c.pass > 0 { append(&rows, c) } }
	if len(rows) < 2 {
		return "<p class=\"doc-note\">The conformance chart needs the git history of <code>wpt/expectations</code>; it was not available at generation time.</p>"
	}

	W, H := 1200.0, 700.0
	L, R, T, B := 92.0, 230.0, 120.0, 96.0
	pw := W - L - R
	ph := H - T - B

	t0 := parse_iso(rows[0].date)
	t1 := parse_iso(rows[len(rows) - 1].date)
	if t1 <= t0 { t1 = t0 + 1 }

	// y range from the data, rounded to a 10k grid
	ymin_v, ymax_v := rows[0].stable_pass, rows[0].pass
	for c in rows {
		ymin_v = min(ymin_v, min(c.pass, c.stable_pass))
		ymax_v = max(ymax_v, c.pass)
	}
	y_min := f64((ymin_v / 10000) * 10000)
	y_max := f64(((ymax_v / 10000) + 1) * 10000)
	if y_max <= y_min { y_max = y_min + 10000 }

	x := proc(date: string, t0, t1, L, pw: f64) -> f64 { return L + (parse_iso_f(date) - t0) / (t1 - t0) * pw }
	y := proc(v: int, y_min, y_max, T, ph: f64) -> f64 { return T + ph - (f64(v) - y_min) / (y_max - y_min) * ph }

	last := rows[len(rows) - 1]
	b := strings.builder_make(context.allocator)
	ws := strings.write_string
	ws(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"")
	fmt.sbprintf(&b, "%.0f", W)
	ws(&b, "\" height=\"")
	fmt.sbprintf(&b, "%.0f", H)
	fmt.sbprintf(&b, "\" viewBox=\"0 0 %.0f %.0f\" role=\"img\" aria-label=\"Passing WPT subtests of Wren over time\" font-family=\"Segoe UI, Inter, Arial, sans-serif\">\n", W, H)
	fmt.sbprintf(&b, "<rect width=\"%.0f\" height=\"%.0f\" fill=\"#0b0b10\"/>\n", W, H)
	fmt.sbprintf(&b, "<rect x=\"14\" y=\"14\" width=\"%.0f\" height=\"%.0f\" rx=\"22\" fill=\"#101018\" stroke=\"#25252f\"/>\n", W - 28, H - 28)
	fmt.sbprintf(&b, "<text x=\"%.0f\" y=\"66\" font-size=\"34\" font-weight=\"800\" fill=\"#e7e6ee\"><tspan fill=\"#4cc2ff\">Wren</tspan> passes %s WPT subtests</text>\n", L, group_num(last.pass))
	fmt.sbprintf(&b, "<text x=\"%.0f\" y=\"96\" font-size=\"16\" fill=\"#9a99a8\">Passing subtests in the folders Wren measures, one point per commit that touches the expectations</text>\n", L)

	// y grid
	for v := int(y_min); v <= int(y_max); v += 10000 {
		yy := y(v, y_min, y_max, T, ph)
		fmt.sbprintf(&b, "<line x1=\"%.0f\" x2=\"%.1f\" y1=\"%.1f\" y2=\"%.1f\" stroke=\"#23232d\"/>", L, L + pw, yy, yy)
		fmt.sbprintf(&b, "<text x=\"%.0f\" y=\"%.1f\" font-size=\"14\" fill=\"#7d7c8c\" text-anchor=\"end\">%dk</text>\n", L - 12, yy + 5, v / 1000)
	}

	// x ticks: each day in range
	day := i64(86400)
	start_day := (i64(t0) / day) * day
	for td := start_day; td <= i64(t1); td += day {
		xx := L + (f64(td) - t0) / (t1 - t0) * pw
		if xx < L - 1 || xx > L + pw + 1 { continue }
		fmt.sbprintf(&b, "<line x1=\"%.1f\" x2=\"%.1f\" y1=\"%.0f\" y2=\"%.1f\" stroke=\"#171720\"/>", xx, xx, T, T + ph)
		fmt.sbprintf(&b, "<text x=\"%.1f\" y=\"%.1f\" font-size=\"13\" fill=\"#7d7c8c\" text-anchor=\"middle\">%s</text>\n", xx, T + ph + 26, short_date(td))
	}

	// the two step paths
	ws(&b, "<path d=\"")
	write_step_path(&b, rows[:], true, t0, t1, L, pw, y_min, y_max, T, ph, x, y)
	ws(&b, "\" fill=\"none\" stroke=\"#4f8cff\" stroke-width=\"3\" stroke-linejoin=\"round\"/>\n")
	ws(&b, "<path d=\"")
	write_step_path(&b, rows[:], false, t0, t1, L, pw, y_min, y_max, T, ph, x, y)
	ws(&b, "\" fill=\"none\" stroke=\"#b784ff\" stroke-width=\"4\" stroke-linejoin=\"round\"/>\n")

	// end labels
	lx := L + pw + 16
	fmt.sbprintf(&b, "<text x=\"%.1f\" y=\"%.1f\" font-size=\"18\" font-weight=\"700\" fill=\"#b784ff\">Wren</text>", lx, y(last.pass, y_min, y_max, T, ph) - 6)
	fmt.sbprintf(&b, "<text x=\"%.1f\" y=\"%.1f\" font-size=\"14\" fill=\"#c8c7d6\">%s all folders</text>\n", lx, y(last.pass, y_min, y_max, T, ph) + 14, group_num(last.pass))
	fmt.sbprintf(&b, "<text x=\"%.1f\" y=\"%.1f\" font-size=\"16\" font-weight=\"700\" fill=\"#4f8cff\">Same folders</text>", lx, y(last.stable_pass, y_min, y_max, T, ph) + 4)
	fmt.sbprintf(&b, "<text x=\"%.1f\" y=\"%.1f\" font-size=\"14\" fill=\"#c8c7d6\">%s</text>\n", lx, y(last.stable_pass, y_min, y_max, T, ph) + 22, group_num(last.stable_pass))

	fmt.sbprintf(&b, "<text x=\"%.0f\" y=\"%.0f\" font-size=\"13\" fill=\"#6c6b7a\">Purple: every folder measured at the time. Blue: only the folders measured at the first point.</text>\n", L, H - 48)
	fmt.sbprintf(&b, "<text x=\"%.0f\" y=\"%.0f\" font-size=\"13\" fill=\"#6c6b7a\">A sample of WPT (%s subtests): not comparable with the wpt.fyi totals of other browsers.</text>\n", L, H - 28, group_num(last.total))
	ws(&b, "</svg>")
	return strings.to_string(b)
}

write_step_path :: proc(b: ^strings.Builder, rows: []Commit, stable: bool, t0, t1, L, pw, y_min, y_max, T, ph: f64,
	xf: proc(string, f64, f64, f64, f64) -> f64, yf: proc(int, f64, f64, f64, f64) -> f64) {
	for c, i in rows {
		v := stable ? c.stable_pass : c.pass
		xx := xf(c.date, t0, t1, L, pw)
		yy := yf(v, y_min, y_max, T, ph)
		if i == 0 {
			fmt.sbprintf(b, "M%.1f,%.1f", xx, yy)
		} else {
			prev := stable ? rows[i - 1].stable_pass : rows[i - 1].pass
			py := yf(prev, y_min, y_max, T, ph)
			fmt.sbprintf(b, " L%.1f,%.1f L%.1f,%.1f", xx, py, xx, yy)
		}
	}
}

// --- the table --------------------------------------------------------------

build_wpt_table :: proc(repo: string, report_path: string) -> string {
	// current folder stats: count PASS over the working-tree expectation files (HEAD is the current branch)
	files := list_txt_worktree(repo)
	stats := make([dynamic]Folder_Stat, context.temp_allocator)
	grand_pass, grand_total := 0, 0
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil { continue }
		pass, total := count_text(string(data))
		if total == 0 { continue }
		fwd, _ := strings.replace_all(f, "\\", "/", context.temp_allocator)
		// keep only the part after "wpt/expectations/" whatever the absolute prefix
		if idx := strings.index(fwd, "wpt/expectations/"); idx >= 0 { fwd = fwd[idx:] }
		name := folder_key(fwd)
		append(&stats, Folder_Stat{name = name, pass = pass, total = total})
		grand_pass += pass
		grand_total += total
	}
	if len(stats) == 0 {
		return "<p class=\"doc-note\">The per-folder table is built from <code>wpt/expectations</code>; the files were not available at generation time.</p>"
	}
	// sort by folder name
	for i in 0 ..< len(stats) {
		for j in i + 1 ..< len(stats) {
			if stats[j].name < stats[i].name { stats[i], stats[j] = stats[j], stats[i] }
		}
	}

	b := strings.builder_make(context.allocator)
	ws := strings.write_string
	ws(&b, "<div class=\"table-box\"><table>\n<thead><tr><th>Folder</th><th style=\"text-align:right\">Passing</th><th style=\"text-align:right\">Subtests</th><th style=\"text-align:right\">Pass rate</th></tr></thead>\n<tbody>\n")
	for s in stats {
		pct := s.total > 0 ? f64(s.pass) * 100.0 / f64(s.total) : 0
		fmt.sbprintf(&b, "<tr><td><code>%s</code></td><td style=\"text-align:right\">%s</td><td style=\"text-align:right\">%s</td><td style=\"text-align:right\">%.0f%%</td></tr>\n",
			html_escape(s.name, context.temp_allocator), group_num(s.pass), group_num(s.total), pct)
	}
	gp := grand_total > 0 ? f64(grand_pass) * 100.0 / f64(grand_total) : 0
	fmt.sbprintf(&b, "<tr><td><strong>All measured folders</strong></td><td style=\"text-align:right\"><strong>%s</strong></td><td style=\"text-align:right\"><strong>%s</strong></td><td style=\"text-align:right\"><strong>%.0f%%</strong></td></tr>\n",
		group_num(grand_pass), group_num(grand_total), gp)
	ws(&b, "</tbody>\n</table></div>\n")
	return strings.to_string(b)
}

// the .txt expectation files in the working tree
list_txt_worktree :: proc(repo: string) -> []string {
	out := make([dynamic]string, context.allocator)
	walk :: proc(dir: string, out: ^[dynamic]string) {
		infos, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil { return }
		for fi in infos {
			if fi.type == .Directory { walk(fi.fullpath, out); continue }
			if strings.has_suffix(fi.name, ".txt") { append(out, strings.clone(fi.fullpath)) }
		}
	}
	walk(strings.concatenate({repo, "/wpt/expectations"}, context.temp_allocator), &out)
	return out[:]
}

count_text :: proc(text: string) -> (pass, total: int) {
	for line in strings.split_lines(text, context.temp_allocator) {
		if len(line) == 0 || line[0] != '\t' { continue }
		i := strings.last_index(line, ": ")
		if i < 0 { continue }
		total += 1
		if strings.trim_space(line[i + 2:]) == "PASS" { pass += 1 }
	}
	return
}

// --- small helpers ----------------------------------------------------------

// parse an ISO 8601 date (YYYY-MM-DDTHH:MM:SS...) into whole seconds since the epoch (UTC, good enough for a chart).
parse_iso :: proc(s: string) -> f64 { return parse_iso_f(s) }

parse_iso_f :: proc(s: string) -> f64 {
	if len(s) < 10 { return 0 }
	y := atoi(s[0:4])
	mo := atoi(s[5:7])
	d := atoi(s[8:10])
	hh, mm, ss := 0, 0, 0
	if len(s) >= 19 && s[10] == 'T' {
		hh = atoi(s[11:13])
		mm = atoi(s[14:16])
		ss = atoi(s[17:19])
	}
	days := days_from_civil(y, mo, d)
	return f64(days) * 86400 + f64(hh) * 3600 + f64(mm) * 60 + f64(ss)
}

// days since 1970-01-01 (Howard Hinnant's algorithm)
days_from_civil :: proc(y, m, d: int) -> int {
	yy := m <= 2 ? y - 1 : y
	era := (yy >= 0 ? yy : yy - 399) / 400
	yoe := yy - era * 400
	doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

short_date :: proc(secs: i64) -> string {
	months := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	days := int(secs / 86400)
	_, m, d := civil_from_days(days)
	buf: [8]u8
	return strings.concatenate({months[m - 1], " ", strconv.write_int(buf[:], i64(d), 10)}, context.temp_allocator)
}

civil_from_days :: proc(z0: int) -> (y, m, d: int) {
	z := z0 + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = doy - (153 * mp + 2) / 5 + 1
	m = mp + (mp < 10 ? 3 : -9)
	y = yy + (m <= 2 ? 1 : 0)
	return
}

atoi :: proc(s: string) -> int {
	n := 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' { break }
		n = n * 10 + int(s[i] - '0')
	}
	return n
}

// 130123 -> "130,123"
group_num :: proc(n: int) -> string {
	buf: [20]u8
	s := strconv.write_int(buf[:], i64(n), 10)
	b := strings.builder_make(context.temp_allocator)
	neg := strings.has_prefix(s, "-")
	if neg { s = s[1:] }
	rem := len(s) % 3
	for i in 0 ..< len(s) {
		if i > 0 && (i - rem) % 3 == 0 { strings.write_byte(&b, ',') }
		strings.write_byte(&b, s[i])
	}
	res := strings.to_string(b)
	return neg ? strings.concatenate({"-", res}, context.temp_allocator) : res
}

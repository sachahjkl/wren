package changelog

// The CHANGELOG is made of fragments: one file per change in changelog.d/, assembled into CHANGELOG.md when a version is
// published. Branches never touch CHANGELOG.md nor the version, so two merges never conflict on them.
//
// A fragment is changelog.d/<yyyyMMdd-HHmmss>-<subject>.md (subject: lowercase letters, digits and '-'):
//     type: Added                       (Added | Changed | Deprecated | Removed | Fixed | Security)
//                                       (a blank line, optional)
//     **What changed**: the one entry, as it will read in the list (no leading "- "); indented "  - " lines are sub-items.
//
//   wrentool changelog -New -Type Added -Subject storage-partitioning -Text "**...**: ..."   writes one
//   wrentool changelog -Check                      every fragment well formed, none already in CHANGELOG.md, and
//                                                  CHANGELOG.md in the form of Keep a Changelog 1.1.0: headings, ISO dates,
//                                                  newest first, sections, the link references at its end (CI)
//   wrentool changelog -Check -Release 0.4.0       ready to tag 0.4.0: no fragment left, its section there, the version said
//   wrentool changelog -Assemble [-Out f.md]       what the next version brings (fragments + "## [Unreleased]"), printed
//   wrentool changelog -Assemble -Version 0.4.0    the release: a "## [0.4.0] - <date>" section in CHANGELOG.md, its link
//                                                  references, the version written in the sources, the fragments deleted
//   wrentool changelog -Section -Version 0.4.0     the body of that version's section (release notes)
//   wrentool changelog -Migrate [-DefaultType Added] [-Types '42=Fixed,57=Changed']
//                                  the entries a branch still wrote under "## [Unreleased]" become fragments (an entry under a
//                                  "### Type" heading keeps it; another one takes -Types[its line] or -DefaultType)
// -Root dir works on another checkout (tests). Exit code 0 when all is well, 1 otherwise.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import "core:unicode"
import "wb:tools/tooling"

SOURCE_VERSION_FILE :: "src/browser/about.odin"   // the sources say their version there,
SOURCE_VERSION_NAME :: "APP_VERSION"              // as `APP_VERSION :: "x.y.z"`
REPO_URL            :: "https://github.com/sachahjkl/wren"   // the link references at the end of the file (tags are v<version>)
UNRELEASED          :: "## [Unreleased]"          // kept, empty, above the released versions
HEADING_FORM        :: "## [x.y.z] - yyyy-MM-dd"  // a released version's heading, as said in a message
YANKED              :: " [YANKED]"
FRAGMENT_DIR        :: "changelog.d"
CHANGELOG_FILE      :: "CHANGELOG.md"
README_NAME         :: "README.md"                // the folder's, not a fragment
FLAG_SPEC           :: "-New -Check -Assemble -Section -Migrate -Version= -Release= -Date= -Type= -Subject= -Text= -Types= -DefaultType= -Out= -Root="
USAGE               :: "wrentool changelog: -New, -Check, -Assemble, -Section or -Migrate (see the head of src/tools/wrentool/changelog/changelog.odin)"
UTF8_BOM            :: "\xEF\xBB\xBF"
FRAGMENT_PATTERN    :: "<yyyyMMdd-HHmmss>-<subject>.md"
NAME_DATE_DIGITS    :: 8          // yyyyMMdd
NAME_TIME_DIGITS    :: 6          // HHmmss
ISO_DATE_LENGTH     :: 10         // yyyy-MM-dd
ISO_YEAR_LENGTH     :: 4
ISO_MONTH_AT        :: 5
ISO_DAY_AT          :: 8
SLUG_MAX            :: 48         // a subject is cut at its last '-' before this length, unless that leaves too little
SLUG_MIN_CUT        :: 16
SLUG_DEFAULT        :: "change"
UNTYPED_CLIP        :: 90         // characters of an untyped entry said by -Migrate
SEMVER_PARTS        :: 3

TYPE_NAMES := [?]string{"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}   // the order of the subsections of a version (Keep a Changelog's)

// The accents of the Latin letters a subject may carry, as the ASCII letter they fold to.
Fold :: struct { from: string, to: u8 }
FOLDS := [?]Fold{
	{"àáâãäå", 'a'}, {"ç", 'c'}, {"èéêë", 'e'}, {"ìíîï", 'i'}, {"ñ", 'n'}, {"òóôõöø", 'o'}, {"ùúûü", 'u'}, {"ýÿ", 'y'},
}

Semver :: [SEMVER_PARTS]int

// What a run knows: the checkout it works on, where it says things, and what went wrong so far.
Tool :: struct {
	root:     string,
	out:      ^strings.Builder,
	errors:   [dynamic]string,
	warnings: [dynamic]string,
}

// A fragment: its type and the text of its entry, or the reasons it is not one.
Fragment :: struct {
	name, path, type: string,
	lines:            []string,
	problems:         [dynamic]string,
}

// An entry written under "## [Unreleased]" of CHANGELOG.md.
Entry :: struct {
	line:  int,   // 1-based
	type:  string,
	lines: [dynamic]string,
}

// What a version lists: an entry of some type, from a fragment or from Unreleased.
Item :: struct { type: string, lines: []string }

// The CHANGELOG: its lines, the span of "## [Unreleased]" and the entries written there. The link references closing the file belong to no
// section: link_start is where they begin (the number of lines when there are none), and every section ends there at the latest.
Changelog :: struct {
	nl:            string,
	lines:         []string,
	unreleased:    int,   // the lines of "## [Unreleased]" up to the next heading (unreleased_end); -1 when there is none
	unreleased_end: int,
	first_release: int,   // the first released version's heading, -1 when none
	link_start:    int,
	entries:       [dynamic]Entry,
}

// ---------------------------------------------------------------------------------------------------------------- the public API

// The subcommand: `wrentool changelog <flags>`. Its exit code.
run :: proc(args: []string) -> int {
	out := strings.builder_make()
	code := execute(args, &out)
	fmt.print(strings.to_string(out))
	free_all(context.temp_allocator)
	return code
}

// The same, saying what it says into `out`.
execute :: proc(args: []string, out: ^strings.Builder) -> int {
	context.allocator = context.temp_allocator
	flags, ok := tooling.parse_flags(args, FLAG_SPEC)
	if !ok { return 1 }
	root := tooling.flag(flags, "-Root")
	if root == "" { root = tooling.repo_root() }
	t := Tool{root = root, out = out}
	has :: tooling.flag_has
	opt :: tooling.flag
	switch {
	case has(flags, "-New"):      return command_new(&t, opt(flags, "-Type"), opt(flags, "-Subject"), opt(flags, "-Text"))
	case has(flags, "-Section"):  return command_section(&t, opt(flags, "-Version"), opt(flags, "-Out"))
	case has(flags, "-Migrate"):  return command_migrate(&t, opt(flags, "-DefaultType"), opt(flags, "-Types"), has(flags, "-DefaultType"))
	case has(flags, "-Check"):    return command_check(&t, opt(flags, "-Release"))
	case has(flags, "-Assemble"): return command_assemble(&t, opt(flags, "-Version"), opt(flags, "-Date"), opt(flags, "-DefaultType"), opt(flags, "-Out"))
	}
	fmt.sbprintln(out, USAGE)
	return 1
}

// The body of a version's section of CHANGELOG.md (what -Section prints). Said on standard error when there is none.
section :: proc(root, version: string, allocator := context.allocator) -> (body: string, ok: bool) {
	context.allocator = context.temp_allocator
	t := Tool{root = root}
	text, found := section_text(&t, version)
	if !found { fmt.eprintfln("error: %s", t.errors[0]); return "", false }
	return strings.clone(text, allocator), true
}

// What the next version brings, fragments and entries of Unreleased (what -Assemble without -Version prints). Said on standard error when a fragment is not well formed.
fragments_body :: proc(root: string, allocator := context.allocator) -> (body: string, ok: bool) {
	context.allocator = context.temp_allocator
	t := Tool{root = root}
	text, good := preview_text(&t, "")
	if !good { for e in t.errors { fmt.eprintfln("error: %s", e) }; return "", false }
	return strings.clone(text, allocator), true
}

// What `-Check -Release version` does, saying it on standard output: ready to tag `version`?
check_release :: proc(root, version: string) -> bool {
	out := strings.builder_make(context.temp_allocator)
	context.allocator = context.temp_allocator
	t := Tool{root = root, out = &out}
	code := command_check(&t, version)
	fmt.print(strings.to_string(out))
	return code == 0
}

// ---------------------------------------------------------------------------------------------------------------- small helpers

die :: proc(t: ^Tool, format: string, args: ..any) -> int {
	fmt.sbprintfln(t.out, "error: %s", fmt.aprintf(format, ..args))
	return 1
}

fail :: proc(t: ^Tool, format: string, args: ..any) { append(&t.errors, fmt.aprintf(format, ..args)) }

join_path :: proc(parts: ..string) -> string { return strings.join(parts, "/") }

read_text :: proc(path: string) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return "", false }
	return strings.trim_prefix(string(data), UTF8_BOM), true
}

split_lines :: proc(s: string) -> []string {
	lines := strings.split(s, "\n")
	for &l in lines { l = strings.trim_suffix(l, "\r") }
	return lines
}

is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

all_digits :: proc(s: string) -> bool {
	for i in 0 ..< len(s) { if !is_digit(s[i]) { return false } }
	return len(s) > 0
}

type_list :: proc(separator: string) -> string { return strings.join(TYPE_NAMES[:], separator) }

canonical_type :: proc(name: string) -> string {
	n := strings.trim_space(name)
	for known in TYPE_NAMES { if strings.equal_fold(known, n) { return known } }
	return ""
}

// What an entry is by, to find it among the released ones: its first line, the spaces made one.
entry_key :: proc(first: string) -> string { return strings.join(strings.fields(first), " ") }

clip :: proc(s: string, runes: int) -> string {
	n := 0
	for _, i in s {
		if n == runes { return strings.concatenate({s[:i], "..."}) }
		n += 1
	}
	return s
}

// The time as the local clock reads it, to be taken apart with time.date and time.clock (which read UTC).
local_clock :: proc(t: time.Time) -> time.Time {
	region, ok := timezone.region_load("local")
	if !ok { return t }
	utc, converted := time.time_to_datetime(t)
	if !converted { return t }
	local, shifted := timezone.datetime_to_tz(utc, region)
	if !shifted { return t }
	back, ok_back := time.datetime_to_time(local.year, local.month, local.day, local.hour, local.minute, local.second)
	return ok_back ? back : t
}

now_local :: proc() -> time.Time { return local_clock(time.now()) }

stamp_of :: proc(t: time.Time) -> string {
	y, m, d := time.date(t)
	hh, mm, ss := time.clock(t)
	return fmt.aprintf("%04d%02d%02d-%02d%02d%02d", y, int(m), d, hh, mm, ss)
}

date_of :: proc(t: time.Time) -> string {
	y, m, d := time.date(t)
	return fmt.aprintf("%04d-%02d-%02d", y, int(m), d)
}

is_iso_date :: proc(s: string) -> bool {
	if len(s) != ISO_DATE_LENGTH || s[ISO_YEAR_LENGTH] != '-' || s[ISO_MONTH_AT + 2] != '-' { return false }
	year, month, day := s[:ISO_YEAR_LENGTH], s[ISO_MONTH_AT:ISO_MONTH_AT + 2], s[ISO_DAY_AT:]
	if !all_digits(year) || !all_digits(month) || !all_digits(day) { return false }
	y, _ := strconv.parse_int(year)
	m, _ := strconv.parse_int(month)
	d, _ := strconv.parse_int(day)
	_, err := datetime.components_to_date(y, m, d)
	return err == nil
}

// `d+.d+.d+` at the start of `s`, and what follows.
semver_prefix :: proc(s: string) -> (v: Semver, rest: string, ok: bool) {
	rest = s
	for i in 0 ..< SEMVER_PARTS {
		n := 0
		for n < len(rest) && is_digit(rest[n]) { n += 1 }
		if n == 0 { return {}, "", false }
		v[i], _ = strconv.parse_int(rest[:n])
		rest = rest[n:]
		if i < SEMVER_PARTS - 1 {
			if !strings.has_prefix(rest, ".") { return {}, "", false }
			rest = rest[1:]
		}
	}
	return v, rest, true
}

// `x.y.z`, with the optional `-pre` or `+build` of semantic versions.
parse_version :: proc(s: string) -> (v: Semver, ok: bool) {
	number, rest := semver_prefix(s) or_return
	if rest == "" { return number, true }
	if rest[0] != '-' && rest[0] != '+' || len(rest) == 1 { return {}, false }
	for i in 1 ..< len(rest) {
		c := rest[i]
		if !(is_digit(c) || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '.' || c == '-') { return {}, false }
	}
	return number, true
}

// The version a released version's heading names (`## [0.4.0] ...`).
heading_version :: proc(line: string) -> (version: string, ok: bool) {
	if !strings.has_prefix(line, "## [") { return "", false }
	rest := line[len("## ["):]
	end := strings.index_any(rest, " \t]")
	if end < 0 || rest[end] != ']' { return "", false }
	_, _, good := semver_prefix(rest[:end])
	return rest[:end], good
}

// A released version's heading in the form the format asks: `## [x.y.z] - yyyy-MM-dd`, then optionally ` [YANKED]`.
Heading :: struct { version, date: string, number: Semver }
strict_heading :: proc(line: string) -> (h: Heading, ok: bool) {
	if !strings.has_prefix(line, "## [") { return {}, false }
	rest := line[len("## ["):]
	close := strings.index_byte(rest, ']')
	if close < 0 { return {}, false }
	h.version = rest[:close]
	h.number = parse_version(h.version) or_return
	rest = rest[close + 1:]
	if !strings.has_prefix(rest, " - ") { return {}, false }
	rest = rest[len(" - "):]
	h.date = rest
	if space := strings.index_byte(rest, ' '); space >= 0 {
		if rest[space:] != YANKED { return {}, false }
		h.date = rest[:space]
	}
	return h, h.date != ""
}

older :: proc(a, b: Semver) -> bool {
	for i in 0 ..< SEMVER_PARTS { if a[i] != b[i] { return a[i] < b[i] } }
	return false
}

// `[name]: ...`, the link reference closing the file.
is_link_reference :: proc(line: string) -> bool {
	if !strings.has_prefix(line, "[") { return false }
	close := strings.index_byte(line, ']')
	return close >= 2 && close + 2 < len(line) && line[close + 1] == ':' && unicode.is_space(rune(line[close + 2]))
}

// ---------------------------------------------------------------------------------------------------------------- the sources' version

// Where the version is said in the sources: `APP_VERSION :: "x.y.z"`, the value between the quotes.
find_version :: proc(text: string) -> (start, end: int, ok: bool) {
	from := 0
	for {
		at := strings.index(text[from:], SOURCE_VERSION_NAME)
		if at < 0 { return 0, 0, false }
		i := from + at + len(SOURCE_VERSION_NAME)
		from = i
		skip_spaces :: proc(s: string, i: int) -> int {
			i := i
			for i < len(s) && unicode.is_space(rune(s[i])) { i += 1 }
			return i
		}
		i = skip_spaces(text, i)
		if !strings.has_prefix(text[i:], "::") { continue }
		i = skip_spaces(text, i + 2)
		if i >= len(text) || text[i] != '"' { continue }
		close := strings.index_byte(text[i + 1:], '"')
		if close <= 0 { continue }
		return i + 1, i + 1 + close, true
	}
}

source_version :: proc(t: ^Tool) -> (version: string, ok: bool) {
	text, read := read_text(join_path(t.root, SOURCE_VERSION_FILE))
	start, end, found := find_version(text)
	if !read || !found { fail(t, "%s not found in %s", SOURCE_VERSION_NAME, SOURCE_VERSION_FILE); return "", false }
	return text[start:end], true
}

write_source_version :: proc(t: ^Tool, version: string) {
	path := join_path(t.root, SOURCE_VERSION_FILE)
	text, read := read_text(path)
	start, end, found := find_version(text)
	if !read || !found || text[start:end] == version { return }
	changed := strings.concatenate({text[:start], version, text[end:]})
	if os.write_entire_file(path, changed) == nil {
		fmt.sbprintfln(t.out, "  %s: %s %s", SOURCE_VERSION_FILE, SOURCE_VERSION_NAME, version)
	}
}

// ---------------------------------------------------------------------------------------------------------------- fragments

valid_fragment_name :: proc(name: string) -> bool {
	stem := strings.trim_suffix(name, ".md")
	subject_at := NAME_DATE_DIGITS + 1 + NAME_TIME_DIGITS + 1
	if stem == name || len(stem) <= subject_at { return false }
	if !all_digits(stem[:NAME_DATE_DIGITS]) || stem[NAME_DATE_DIGITS] != '-' { return false }
	if !all_digits(stem[NAME_DATE_DIGITS + 1:subject_at - 1]) || stem[subject_at - 1] != '-' { return false }
	subject := stem[subject_at:]
	if strings.has_prefix(subject, "-") || strings.has_suffix(subject, "-") || strings.contains(subject, "--") { return false }
	for i in 0 ..< len(subject) {
		c := subject[i]
		if !(is_digit(c) || c >= 'a' && c <= 'z' || c == '-') { return false }
	}
	return true
}

// `type: Added` (any case, spaces around): the word after the colon, "" when there is none.
parse_type_line :: proc(line: string) -> (word: string, ok: bool) {
	s := strings.trim_space(line)
	if len(s) < len("type") || !strings.equal_fold(s[:len("type")], "type") { return "", false }
	s = strings.trim_left_space(s[len("type"):])
	if !strings.has_prefix(s, ":") { return "", false }
	words := strings.fields(s[1:])
	if len(words) > 1 { return "", false }
	return len(words) == 1 ? words[0] : "", true
}

read_fragment :: proc(path, name: string) -> Fragment {
	f := Fragment{name = name, path = path}
	problem :: proc(f: ^Fragment, text: string) { append(&f.problems, text) }
	if !valid_fragment_name(name) { problem(&f, fmt.aprintf("its name is not %s (subject: a-z, 0-9 and -)", FRAGMENT_PATTERN)) }
	text, _ := read_text(path)
	lines := split_lines(text)
	i := 0
	for i < len(lines) && strings.trim_space(lines[i]) == "" { i += 1 }
	if i >= len(lines) { problem(&f, "it is empty"); return f }
	word, is_type := parse_type_line(lines[i])
	if !is_type { problem(&f, fmt.aprintf("its first line is not 'type: %s'", type_list("|"))); return f }
	f.type = canonical_type(word)
	if f.type == "" { problem(&f, fmt.aprintf("unknown type '%s' (%s)", word, type_list(", "))) }
	body := slice.clone(lines[i + 1:])
	for &l in body { l = strings.trim_right_space(l) }
	for len(body) > 0 && body[0] == "" { body = body[1:] }
	for len(body) > 0 && body[len(body) - 1] == "" { body = body[:len(body) - 1] }
	if len(body) == 0 { problem(&f, "it has a type but no text"); return f }
	body[0] = strings.trim_prefix(body[0], "- ")
	if strings.trim_space(body[0]) == "" { problem(&f, "its text is empty") }
	for l in body {
		if l == "" { problem(&f, `a blank line inside its text (one entry: sub-items are indented "  - " lines)`); break }
		if strings.has_prefix(l, "#") { problem(&f, "a heading inside its text (the type gives the section)"); break }
		if strings.has_prefix(l, "- ") { problem(&f, `several entries in one fragment (one change per fragment; sub-items are indented "  - ")`); break }
	}
	f.lines = body
	return f
}

list_dir :: proc(dir: string) -> []os.File_Info {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	return err == nil ? entries : nil
}

// Newest first: a version lists its latest changes at the top.
read_fragments :: proc(t: ^Tool) -> []Fragment {
	dir := join_path(t.root, FRAGMENT_DIR)
	names := make([dynamic]string)
	for e in list_dir(dir) { if e.type != .Directory && e.name != README_NAME { append(&names, e.name) } }
	slice.reverse_sort(names[:])
	frags := make([dynamic]Fragment)
	for n in names { append(&frags, read_fragment(join_path(dir, n), n)) }
	return frags[:]
}

// ---------------------------------------------------------------------------------------------------------------- the CHANGELOG

read_changelog :: proc(t: ^Tool) -> (c: Changelog, ok: bool) {
	text, read := read_text(join_path(t.root, CHANGELOG_FILE))
	if !read { return {}, false }
	c.nl = strings.contains(text, "\r\n") ? "\r\n" : "\n"
	c.lines = split_lines(text)
	c.unreleased, c.unreleased_end, c.first_release, c.link_start = -1, -1, -1, len(c.lines)
	for i := len(c.lines) - 1; i >= 0; i -= 1 {
		if strings.trim_space(c.lines[i]) == "" { continue }
		if !is_link_reference(c.lines[i]) { break }
		c.link_start = i
	}
	for l, i in c.lines {
		if _, is_heading := heading_version(l); is_heading { c.first_release = i; break }
	}
	for l, i in c.lines { if strings.trim_right_space(l) == UNRELEASED { c.unreleased = i; break } }
	if c.unreleased < 0 { return c, true }
	c.unreleased_end = c.link_start
	for i in c.unreleased + 1 ..< c.link_start { if strings.has_prefix(c.lines[i], "## ") { c.unreleased_end = i; break } }
	type, current := "", -1
	for i in c.unreleased + 1 ..< c.unreleased_end {
		l := strings.trim_right_space(c.lines[i])
		if strings.has_prefix(l, "### ") && len(l) > len("### ") {
			current = -1
			type = canonical_type(l[len("### "):])
			if type == "" { fail(t, "%s line %d: unknown subsection '%s' under %s", CHANGELOG_FILE, i + 1, l, UNRELEASED) }
			continue
		}
		if strings.has_prefix(l, "- ") {
			e := Entry{line = i + 1, type = type}
			append(&e.lines, l[2:])
			append(&c.entries, e)
			current = len(c.entries) - 1
			continue
		}
		if l == "" { current = -1; continue }
		if current >= 0 { append(&c.entries[current].lines, l) } else { fail(t, "%s line %d: text under %s that is not an entry ('- ...')", CHANGELOG_FILE, i + 1, UNRELEASED) }
	}
	return c, true
}

// The released versions named by these lines, newest first.
versions_of :: proc(lines: []string) -> []string {
	versions := make([dynamic]string)
	for l in lines { if v, ok := heading_version(l); ok { append(&versions, v) } }
	return versions[:]
}

// The link references of these versions: each one compares with the version below it, the oldest has only its tag.
link_lines :: proc(versions: []string) -> [dynamic]string {
	links := make([dynamic]string)
	if len(versions) == 0 { return links }
	append(&links, fmt.aprintf("[Unreleased]: %s/compare/v%s...HEAD", REPO_URL, versions[0]))
	for v, i in versions {
		if i + 1 < len(versions) {
			append(&links, fmt.aprintf("[%s]: %s/compare/v%s...v%s", v, REPO_URL, versions[i + 1], v))
		} else {
			append(&links, fmt.aprintf("[%s]: %s/releases/tag/v%s", v, REPO_URL, v))
		}
	}
	return links
}

// The form of the file (Keep a Changelog 1.1.0). What is under "## [Unreleased]" is read_changelog's: it may be untyped until -Migrate.
check_format :: proc(t: ^Tool, c: ^Changelog) {
	if c.unreleased < 0 { fail(t, "%s has no heading '%s'", CHANGELOG_FILE, UNRELEASED) }
	if c.unreleased >= 0 && c.first_release >= 0 && c.unreleased > c.first_release {
		fail(t, "%s line %d: '%s' must come above the released versions", CHANGELOG_FILE, c.unreleased + 1, UNRELEASED)
	}
	seen := make(map[string]int)
	previous: Semver
	has_previous := false
	previous_date := ""
	in_version, in_entry := false, false
	sub := ""
	subs := make(map[string]bool)
	last_order := -1
	for i in 0 ..< c.link_start {
		l := strings.trim_right_space(c.lines[i])
		n := i + 1
		if strings.has_prefix(l, "## ") {
			in_version, in_entry, sub, last_order = false, false, "", -1
			clear(&subs)
			if l == UNRELEASED { continue }
			h, ok := strict_heading(l)
			if !ok { fail(t, "%s line %d: '%s' is not '%s'", CHANGELOG_FILE, n, l, HEADING_FORM); continue }
			in_version = true
			if !is_iso_date(h.date) {
				fail(t, "%s line %d: '%s' is not an ISO date (yyyy-MM-dd)", CHANGELOG_FILE, n, h.date)
			} else {
				if previous_date != "" && h.date > previous_date {
					fail(t, "%s line %d: %s is dated %s, after the version above it (%s): the newest comes first", CHANGELOG_FILE, n, h.version, h.date, previous_date)
				}
				previous_date = h.date
			}
			if at, twice := seen[h.version]; twice { fail(t, "%s line %d: version %s twice (line %d too)", CHANGELOG_FILE, n, h.version, at) } else { seen[h.version] = n }
			if has_previous && older(previous, h.number) {
				fail(t, "%s line %d: %s comes below %d.%d.%d: the newest comes first", CHANGELOG_FILE, n, h.version, previous[0], previous[1], previous[2])
			}
			previous, has_previous = h.number, true
			continue
		}
		if !in_version { continue }
		if strings.has_prefix(l, "### ") {
			in_entry = false
			sub = l[len("### "):]
			order := slice.linear_search(TYPE_NAMES[:], sub) or_else -1   // exact: "### fixed" is no section
			if order < 0 { fail(t, "%s line %d: unknown section '%s' (%s)", CHANGELOG_FILE, n, l, type_list(", ")); continue }
			if subs[sub] {
				fail(t, "%s line %d: section '%s' twice in one version", CHANGELOG_FILE, n, sub)
			} else if order < last_order {
				fail(t, "%s line %d: section '%s' comes after '%s' (%s)", CHANGELOG_FILE, n, sub, TYPE_NAMES[last_order], type_list(", "))
			}
			subs[sub] = true
			last_order = max(last_order, order)
			continue
		}
		if strings.has_prefix(l, "#") { fail(t, "%s line %d: a heading that is neither a version nor a section: '%s'", CHANGELOG_FILE, n, l); continue }
		if l == "" { in_entry = false; continue }
		if strings.has_prefix(l, "- ") {
			if sub == "" { fail(t, "%s line %d: an entry outside a '### Type' section", CHANGELOG_FILE, n) }
			in_entry = true
			continue
		}
		// text before a version's first section introduces it; below a section, only an entry and what continues it
		if sub != "" && !in_entry { fail(t, "%s line %d: text in section '%s' that is not an entry ('- ...')", CHANGELOG_FILE, n, sub) }
	}
	expected := link_lines(versions_of(c.lines))
	actual := make([dynamic]string)
	for l in c.lines[c.link_start:] { if s := strings.trim_right_space(l); s != "" { append(&actual, s) } }
	wrong := 0
	for e in expected {
		if !slice.contains(actual[:], e) { wrong += 1; fail(t, "%s: this link reference is missing at the end of the file: %s", CHANGELOG_FILE, e) }
	}
	for a in actual {
		if !slice.contains(expected[:], a) { wrong += 1; fail(t, "%s: this link reference names no version, or the wrong one: %s", CHANGELOG_FILE, a) }
	}
	if wrong == 0 && strings.join(expected[:], "\n") != strings.join(actual[:], "\n") {
		fail(t, "%s: the link references are not in the order of the versions", CHANGELOG_FILE)
	}
}

render_body :: proc(items: []Item) -> [dynamic]string {
	out := make([dynamic]string)
	for type in TYPE_NAMES {
		first_of_type := true
		for item in items {
			if item.type != type { continue }
			if first_of_type {
				if len(out) > 0 { append(&out, "") }
				append(&out, strings.concatenate({"### ", type}))
				first_of_type = false
			}
			for l, i in item.lines { append(&out, i == 0 ? strings.concatenate({"- ", l}) : l) }
		}
	}
	return out
}

// ---------------------------------------------------------------------------------------------------------------- -New

fold_letter :: proc(r: rune) -> u8 {
	for f in FOLDS { if strings.contains_rune(f.from, r) { return f.to } }
	return 0
}

slug :: proc(subject: string) -> string {
	s := subject
	if open := strings.index(s, "**"); open >= 0 && open + 3 <= len(s) {
		if close := strings.index(s[open + 3:], "**"); close >= 0 { s = s[open + 2:open + 3 + close] }
	}
	b := strings.builder_make()
	for r in s {
		lower := unicode.to_lower(r)
		c: u8 = '-'
		switch {
		case lower >= 'a' && lower <= 'z' || lower >= '0' && lower <= '9': c = u8(lower)
		case fold_letter(lower) != 0:                                    c = fold_letter(lower)
		}
		if c == '-' && (strings.builder_len(b) == 0 || strings.to_string(b)[strings.builder_len(b) - 1] == '-') { continue }
		strings.write_byte(&b, c)
	}
	result := strings.trim_right(strings.to_string(b), "-")
	if len(result) > SLUG_MAX {
		cut := strings.last_index_byte(result[:SLUG_MAX + 1], '-')
		result = strings.trim(result[:cut > SLUG_MIN_CUT ? cut : SLUG_MAX], "-")
	}
	return result == "" ? SLUG_DEFAULT : result
}

new_fragment_file :: proc(t: ^Tool, type: string, lines: []string, at: time.Time, subject, nl: string) -> string {
	dir := join_path(t.root, FRAGMENT_DIR)
	_ = os.make_directory_all(dir)
	stem := fmt.aprintf("%s-%s", stamp_of(at), slug(subject))
	path := join_path(dir, strings.concatenate({stem, ".md"}))
	for k := 2; os.exists(path); k += 1 { path = join_path(dir, fmt.aprintf("%s-%d.md", stem, k)) }
	content := make([dynamic]string)
	append(&content, strings.concatenate({"type: ", type}), "")
	append(&content, ..lines)
	_ = os.write_entire_file(path, strings.concatenate({strings.join(content[:], nl), nl}))
	return path
}

command_new :: proc(t: ^Tool, type_name, subject, text: string) -> int {
	type := canonical_type(type_name)
	if type == "" { return die(t, "-Type is one of %s (got '%s')", type_list(", "), type_name) }
	if strings.trim_space(text) == "" { return die(t, "-Text is the entry") }
	nl := "\n"
	if changelog, ok := read_text(join_path(t.root, CHANGELOG_FILE)); ok && strings.contains(changelog, "\r\n") { nl = "\r\n" }
	entry := strings.trim_prefix(strings.trim_space(text), "- ")
	path := new_fragment_file(t, type, split_lines(entry), now_local(), subject == "" ? text : subject, nl)
	f := read_fragment(path, filepath_base(path))
	if len(f.problems) > 0 {
		_ = os.remove(path)
		return die(t, "not a fragment: %s", strings.join(f.problems[:], "; "))
	}
	fmt.sbprintln(t.out, path)
	return 0
}

filepath_base :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:]
}

// ---------------------------------------------------------------------------------------------------------------- -Section

section_text :: proc(t: ^Tool, version: string) -> (body: string, ok: bool) {
	c, read := read_changelog(t)
	if !read { fail(t, "cannot read %s", CHANGELOG_FILE); return "", false }
	start := -1
	for l, i in c.lines { if v, is_heading := heading_version(l); is_heading && v == version { start = i; break } }
	if start < 0 { fail(t, "%s has no section %s", CHANGELOG_FILE, version); return "", false }
	end := c.link_start
	for i in start + 1 ..< c.link_start { if strings.has_prefix(c.lines[i], "## ") { end = i; break } }
	return strings.concatenate({strings.trim_space(strings.join(c.lines[start + 1:end], "\n")), "\n"}), true
}

// Into the file `out_path` when it is said, onto the output otherwise.
emit :: proc(t: ^Tool, text, out_path: string) {
	if out_path != "" { _ = os.write_entire_file(out_path, text) } else { strings.write_string(t.out, text) }
}

command_section :: proc(t: ^Tool, version, out_path: string) -> int {
	if version == "" { return die(t, "-Section needs -Version") }
	body, ok := section_text(t, version)
	if !ok { return die(t, "%s", t.errors[0]) }
	emit(t, body, out_path)
	return 0
}

// ---------------------------------------------------------------------------------------------------------------- -Migrate

command_migrate :: proc(t: ^Tool, default_type, types: string, has_default: bool) -> int {
	c, ok := read_changelog(t)
	if !ok { return die(t, "cannot read %s", CHANGELOG_FILE) }
	if len(t.errors) > 0 { for e in t.errors { fmt.sbprintfln(t.out, "error: %s", e) }; return 1 }
	if c.unreleased < 0 || len(c.entries) == 0 { fmt.sbprintfln(t.out, "nothing under \"%s\"", UNRELEASED); return 0 }
	def := has_default ? canonical_type(default_type) : ""
	if has_default && def == "" { return die(t, "-DefaultType is one of %s (got '%s')", type_list(", "), default_type) }
	by_line := make(map[int]string)
	for pair in strings.split(types, ",") {
		if strings.trim_space(pair) == "" { continue }
		key, _, value := strings.partition(pair, "=")
		type := canonical_type(value)
		line, numeric := strconv.parse_int(strings.trim_space(key))
		if !strings.contains(pair, "=") || !all_digits(strings.trim_space(key)) || !numeric || type == "" {
			return die(t, "-Types is 'line=Type,line=Type' (got '%s')", pair)
		}
		by_line[line] = type
	}
	for &e in c.entries {
		if type, has := by_line[e.line]; has { e.type = type } else if e.type == "" { e.type = def }
	}
	untyped := false
	for e in c.entries { if e.type == "" { untyped = true } }
	if untyped {
		fmt.sbprintfln(t.out, "These entries are under no '### Type' heading: give -DefaultType, or -Types '<line>=Fixed,<line>=Changed' for some of them:")
		for e in c.entries { if e.type == "" { fmt.sbprintfln(t.out, "  line %d: %s", e.line, clip(e.lines[0], UNTYPED_CLIP)) } }
		return 1
	}
	// the first entry is the newest: it gets the latest time, one second apart, so that -Assemble lists them in the same order
	now := now_local()
	for e, k in c.entries { new_fragment_file(t, e.type, e.lines[:], time.time_add(now, -time.Duration(k) * time.Second), e.lines[0], c.nl) }
	kept := make([dynamic]string)
	append(&kept, ..c.lines[:c.unreleased + 1])
	append(&kept, "")
	if c.unreleased_end < len(c.lines) { append(&kept, ..c.lines[c.unreleased_end:]) }
	_ = os.write_entire_file(join_path(t.root, CHANGELOG_FILE), strings.join(kept[:], c.nl))
	fmt.sbprintfln(t.out, "%d entries of %s are fragments in %s/ now", len(c.entries), UNRELEASED, FRAGMENT_DIR)
	for type in TYPE_NAMES {
		n := 0
		for e in c.entries { if e.type == type { n += 1 } }
		if n > 0 { fmt.sbprintfln(t.out, "  %s %d", type, n) }
	}
	return 0
}

// ---------------------------------------------------------------------------------------------------------------- -Check

command_check :: proc(t: ^Tool, release: string) -> int {
	c, ok := read_changelog(t)
	if !ok { return die(t, "cannot read %s", CHANGELOG_FILE) }
	check_format(t, &c)
	frags := read_fragments(t)
	for e in list_dir(join_path(t.root, FRAGMENT_DIR)) {
		if e.type == .Directory { fail(t, "%s/%s: a folder (fragments are files)", FRAGMENT_DIR, e.name) }
	}
	released := make(map[string]bool)
	from := c.unreleased_end >= 0 ? c.unreleased_end : 0
	for l in c.lines[from:] { if strings.has_prefix(l, "- ") && len(l) > 2 { released[entry_key(l[2:])] = true } }
	seen := make(map[string]string)
	for f in frags {
		for p in f.problems { fail(t, "%s/%s: %s", FRAGMENT_DIR, f.name, p) }
		if len(f.lines) == 0 { continue }
		key := entry_key(f.lines[0])
		if key in released { fail(t, "%s/%s: already in a released section of %s (assembled but not deleted)", FRAGMENT_DIR, f.name, CHANGELOG_FILE) }
		if first, twice := seen[key]; twice {
			fail(t, "%s/%s: the same text as %s/%s", FRAGMENT_DIR, f.name, FRAGMENT_DIR, first)
		} else {
			seen[key] = f.name
		}
	}
	if len(c.entries) > 0 {
		append(&t.warnings, fmt.aprintf("%d entries under '%s' in %s: write fragments instead (wrentool changelog -Migrate turns them into fragments)", len(c.entries), UNRELEASED, CHANGELOG_FILE))
	}
	last := ""
	if c.first_release >= 0 { last, _ = heading_version(c.lines[c.first_release]) }
	if release != "" {
		if len(frags) > 0 { fail(t, "%d fragments are not assembled: wrentool changelog -Assemble -Version %s", len(frags), release) }
		if len(c.entries) > 0 { fail(t, "entries are left under '%s'", UNRELEASED) }
		if last != release { fail(t, "the latest section of %s is '%s', not %s", CHANGELOG_FILE, last, release) }
		if sv, found := source_version(t); found && sv != release { fail(t, "the sources say version %s, not %s", sv, release) }
	}
	for w in t.warnings { fmt.sbprintfln(t.out, "warning: %s", w) }
	for e in t.errors { fmt.sbprintfln(t.out, "error: %s", e) }
	if len(t.errors) > 0 { return 1 }
	fmt.sbprintfln(t.out, "changelog: %d fragments, well formed; %s in form%s", len(frags), CHANGELOG_FILE, release != "" ? fmt.aprintf("; ready to publish %s", release) : "")
	return 0
}

// ---------------------------------------------------------------------------------------------------------------- -Assemble

// What the fragments and the entries of Unreleased bring. `release`: an untyped entry is an error (a preview lists it with the additions).
collect_items :: proc(t: ^Tool, c: ^Changelog, frags: []Fragment, default_type: string, release: bool) -> [dynamic]Item {
	for f in frags { for p in f.problems { fail(t, "%s/%s: %s", FRAGMENT_DIR, f.name, p) } }
	def := default_type != "" ? canonical_type(default_type) : ""
	items := make([dynamic]Item)
	for f in frags { if f.type != "" && len(f.lines) > 0 { append(&items, Item{f.type, f.lines}) } }
	for &e in c.entries {
		if e.type == "" {
			if def != "" {
				e.type = def
			} else if release {
				fail(t, "%s line %d: an entry under '%s' with no '### Type' (wrentool changelog -Migrate, or -DefaultType)", CHANGELOG_FILE, e.line, UNRELEASED)
				continue
			} else {
				e.type = TYPE_NAMES[0]
			}
		}
		append(&items, Item{e.type, e.lines[:]})
	}
	return items
}

// The preview: the body of the next version.
preview_text :: proc(t: ^Tool, default_type: string) -> (text: string, ok: bool) {
	c, read := read_changelog(t)
	if !read { fail(t, "cannot read %s", CHANGELOG_FILE); return "", false }
	items := collect_items(t, &c, read_fragments(t), default_type, false)
	if len(t.errors) > 0 { return "", false }
	body := render_body(items[:])
	if len(body) == 0 { return "", true }
	return strings.concatenate({strings.join(body[:], "\n"), "\n"}), true
}

command_assemble :: proc(t: ^Tool, version, date, default_type, out_path: string) -> int {
	c, ok := read_changelog(t)
	if !ok { return die(t, "cannot read %s", CHANGELOG_FILE) }
	frags := read_fragments(t)
	items := collect_items(t, &c, frags, default_type, version != "")
	if len(t.errors) > 0 { for e in t.errors { fmt.sbprintfln(t.out, "error: %s", e) }; return 1 }
	body := render_body(items[:])
	if version == "" {
		emit(t, len(body) > 0 ? strings.concatenate({strings.join(body[:], "\n"), "\n"}) : "", out_path)
		return 0
	}
	if _, valid := parse_version(version); !valid { return die(t, "-Version is x.y.z (got '%s')", version) }
	for l in c.lines { if v, is_heading := heading_version(l); is_heading && v == version { return die(t, "%s already has a section %s", CHANGELOG_FILE, version) } }
	if len(items) == 0 { return die(t, "nothing to publish: no fragment in %s/ and nothing under '%s'", FRAGMENT_DIR, UNRELEASED) }
	day := date != "" ? date : date_of(now_local())
	if !is_iso_date(day) { return die(t, "-Date is yyyy-MM-dd (got '%s')", day) }
	released := make([dynamic]string)
	append(&released, fmt.aprintf("## [%s] - %s", version, day), "")
	append(&released, ..body[:])
	append(&released, "")
	// the link references are written anew below, from the headings
	content := c.lines[:c.link_start]
	before, after: []string
	switch {
	case c.unreleased >= 0:
		before = slice.concatenate([][]string{content[:c.unreleased + 1], {""}})
		after = c.unreleased_end < len(content) ? content[c.unreleased_end:] : nil
	case c.first_release >= 0:
		before, after = content[:c.first_release], content[c.first_release:]
	case:
		trimmed := content
		for len(trimmed) > 0 && trimmed[len(trimmed) - 1] == "" { trimmed = trimmed[:len(trimmed) - 1] }
		before, after = slice.concatenate([][]string{trimmed, {""}}), {""}
	}
	all := slice.concatenate([][]string{before, released[:], after})
	for len(all) > 0 && all[len(all) - 1] == "" { all = all[:len(all) - 1] }
	links := link_lines(versions_of(all))
	if len(links) > 0 { all = slice.concatenate([][]string{all, {""}, links[:]}) }
	_ = os.write_entire_file(join_path(t.root, CHANGELOG_FILE), strings.join(slice.concatenate([][]string{all, {""}}), c.nl))
	fmt.sbprintfln(t.out, "%s: section %s (%d entries)", CHANGELOG_FILE, version, len(items))
	write_source_version(t, version)
	for f in frags { _ = os.remove(f.path) }
	if len(frags) > 0 { fmt.sbprintfln(t.out, "%s/: %d fragments deleted (commit the deletion with %s)", FRAGMENT_DIR, len(frags), CHANGELOG_FILE) }
	return 0
}

package changelog

// Tests of the changelog tool on a throwaway checkout (a CHANGELOG.md, the file that holds the version, fragments): well formed and malformed
// fragments, -New, -Check (orphans, duplicates, -Release), -Assemble with and without fragments, -Migrate, -Section, the form of CHANGELOG.md
// (Keep a Changelog 1.1.0). The tool runs in process; what it says is read from the builder it was given.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

TEST_BASE    :: "0.6.24"        // the version the throwaway sources say, the last one released
TEST_RELEASE :: "9.9.9"
TEST_DATE    :: "2026-10-27"
TEST_OLD_DATE :: "2026-01-01"
TEST_SOURCES :: "// version\nAPP_VERSION :: \"" + TEST_BASE + "\"\nAPP_VERSION_LABEL :: #config(WREN_VERSION_LABEL, \"\")\n"
TEST_CHANGELOG :: "# Changelog\r\n\r\nIntro.\r\n\r\n## [Unreleased]\r\n\r\n## [" + TEST_BASE + "] - " + TEST_OLD_DATE + "\r\n\r\n### Added\r\n- **Old thing**: shipped.\r\n" +
	"\r\n[Unreleased]: " + REPO_URL + "/compare/v" + TEST_BASE + "...HEAD\r\n[" + TEST_BASE + "]: " + REPO_URL + "/releases/tag/v" + TEST_BASE + "\r\n"
TEST_ROOT_PREFIX :: "changelog-test-"

// A throwaway checkout, made fresh under the temporary folder (named by the test, they run in parallel).
fresh :: proc(name: string) -> string {
	root := fmt.aprintf("%s/%s%s", os.get_env("TEMP", context.temp_allocator), TEST_ROOT_PREFIX, name, allocator = context.temp_allocator)
	_ = os.remove_all(root)
	_ = os.make_directory_all(strings.concatenate({root, "/", FRAGMENT_DIR}, context.temp_allocator))
	_ = os.make_directory_all(strings.concatenate({root, "/src/browser"}, context.temp_allocator))
	write(root, SOURCE_VERSION_FILE, TEST_SOURCES)
	write(root, CHANGELOG_FILE, TEST_CHANGELOG)
	return root
}

write :: proc(root, file, text: string) {
	_ = os.write_entire_file(fmt.aprintf("%s/%s", root, file, allocator = context.temp_allocator), text)
}

read :: proc(root, file: string) -> string {
	data, _ := os.read_entire_file(fmt.aprintf("%s/%s", root, file, allocator = context.temp_allocator), context.temp_allocator)
	return string(data)
}

fragment :: proc(root, name, text: string) { write(root, strings.concatenate({FRAGMENT_DIR, "/", name}, context.temp_allocator), text) }

drop_fragment :: proc(root, name: string) { _ = os.remove(fmt.aprintf("%s/%s/%s", root, FRAGMENT_DIR, name, allocator = context.temp_allocator)) }

fragment_count :: proc(root: string) -> int {
	entries, _ := os.read_all_directory_by_path(fmt.aprintf("%s/%s", root, FRAGMENT_DIR, allocator = context.temp_allocator), context.temp_allocator)
	return len(entries)
}

Result :: struct { code: int, out: string }

tool :: proc(root: string, args: ..string) -> Result {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..args)
	append(&all, "-Root", root)
	out := strings.builder_make(context.temp_allocator)
	code := execute(all[:], &out)
	return {code, strings.to_string(out)}
}

// The tool refused: a failing code, and `said` among what it said.
refuses :: proc(t: ^testing.T, r: Result, said: string, loc := #caller_location) {
	testing.expectf(t, r.code != 0 && strings.contains(r.out, said), "wanted a failure saying %q, got code %d: %s", said, r.code, r.out, loc = loc)
}

passes :: proc(t: ^testing.T, r: Result, said := "", loc := #caller_location) {
	testing.expectf(t, r.code == 0 && strings.contains(r.out, said), "wanted success saying %q, got code %d: %s", said, r.code, r.out, loc = loc)
}

LF_ONLY :: "\n"

@(test)
test_no_fragment :: proc(t: ^testing.T) {
	root := fresh("none")
	passes(t, tool(root, "-Check"), "0 fragments")
	r := tool(root, "-Assemble")
	testing.expect(t, r.code == 0 && strings.trim_space(r.out) == "", "the preview of nothing is empty")
	refuses(t, tool(root, "-Assemble", "-Version", "0.7.0"), "nothing to publish")
}

@(test)
test_fragments_well_formed :: proc(t: ^testing.T) {
	root := fresh("wellformed")
	fragment(root, "20261026-100000-tabs.md", "type: Added\n\n**Tabs in a sidebar**: one.\n")
	passes(t, tool(root, "-Check"), ": 1 fragments")
	fragment(root, "20261026-100001-tabs.md", "type: Fixed\r\n**Tabs** no longer flicker.\r\n")
	fragment(root, "20261026-100002-workers.md", "type: changed\n- **Workers**:\n  - one;\n  - two.\n")
	passes(t, tool(root, "-Check"), "3 fragments")
	r := tool(root, "-Assemble")
	want := "### Added\n- **Tabs in a sidebar**: one.\n\n### Changed\n- **Workers**:\n  - one;\n  - two.\n\n### Fixed\n- **Tabs** no longer flicker.\n"
	testing.expect_value(t, r.out, want)
	body, ok := fragments_body(root, context.temp_allocator)
	testing.expect(t, ok && body == want, "fragments_body says what the preview prints")
}

@(test)
test_fragments_malformed :: proc(t: ^testing.T) {
	root := fresh("malformed")
	fragment(root, "20261026-100000-tabs.md", "type: Added\n\n**Tabs in a sidebar**: one.\n")
	fragment(root, "20261026-100001-tabs.md", "type: Fixed\n\n**Tabs** no longer flicker.\n")
	bad :: struct { name, text, said: string }
	cases := [?]bad{
		{"20261026-100003-x.md",       "type: Improved\n\nSomething.\n",         "unknown type 'Improved'"},
		{"my change.md",               "type: Added\n\nA thing.\n",              "its name is not"},
		{"20261026-100004-two.md",     "type: Added\n\n- One.\n- Two.\n",        "several entries"},
		{"20261026-100005-notype.md",  "Just text.\n",                           "first line is not"},
		{"20261026-100006-dup.md",     "type: Fixed\n\n**Tabs**   no longer flicker.\n", "the same text as"},
		{"20261026-100008-blank.md",   "type: Added\n\nOne.\n\nTwo.\n",          "a blank line inside"},
		{"20261026-100009-head.md",    "type: Added\n\nOne.\n# Head\n",          "a heading inside"},
		{"20261026-100010-empty.md",   "\n\n",                                   "it is empty"},
		{"20261026-100011-bare.md",    "type: Added\n",                          "no text"},
	}
	for c in cases {
		fragment(root, c.name, c.text)
		refuses(t, tool(root, "-Check"), c.said)
		drop_fragment(root, c.name)
	}
	fragment(root, "20261026-100003-x.md", "type: Improved\n\nSomething.\n")
	refuses(t, tool(root, "-Assemble", "-Version", "0.7.0"), "unknown type")
	drop_fragment(root, "20261026-100003-x.md")
	fragment(root, "20261026-100007-orphan.md", "type: Added\n\n**Old thing**: shipped.\n")
	refuses(t, tool(root, "-Check"), "already in a released section")
	drop_fragment(root, "20261026-100007-orphan.md")
	_ = os.make_directory_all(fmt.aprintf("%s/%s/sub", root, FRAGMENT_DIR, allocator = context.temp_allocator))
	refuses(t, tool(root, "-Check"), "a folder (fragments are files)")
}

@(test)
test_six_types_in_order :: proc(t: ^testing.T) {
	root := fresh("sixtypes")
	fragment(root, "20261026-100010-security.md", "type: Security\n\n**Security thing**.\n")
	fragment(root, "20261026-100011-removed.md", "type: Removed\n\n**Removed thing**.\n")
	fragment(root, "20261026-100012-deprecated.md", "type: Deprecated\n\n**Deprecated thing**.\n")
	fragment(root, "20261026-100013-added.md", "type: Added\n\n**Added thing**.\n")
	fragment(root, "20261026-100014-fixed.md", "type: Fixed\n\n**Fixed thing**.\n")
	fragment(root, "20261026-100015-changed.md", "type: Changed\n\n**Changed thing**.\n")
	passes(t, tool(root, "-Check"), "6 fragments")
	out := tool(root, "-Assemble").out
	last := -1
	for type in TYPE_NAMES {
		at := strings.index(out, strings.concatenate({"### ", type}, context.temp_allocator))
		testing.expectf(t, at > last, "### %s comes after the one before it (at %d, after %d)", type, at, last)
		last = at
	}
}

@(test)
test_new :: proc(t: ^testing.T) {
	root := fresh("new")
	r := tool(root, "-New", "-Type", "Removed", "-Subject", "Old Pref!", "-Text", "The `x.y` preference.")
	path := strings.trim_space(r.out)
	testing.expectf(t, r.code == 0 && strings.has_suffix(path, "-old-pref.md"), "-New names the fragment after its subject: %s", r.out)
	testing.expect_value(t, read(root, strings.concatenate({FRAGMENT_DIR, "/", path[strings.last_index_byte(path, '/') + 1:]}, context.temp_allocator)),
		"type: Removed\r\n\r\nThe `x.y` preference.\r\n")   // the CHANGELOG is CRLF: so is the fragment
	passes(t, tool(root, "-Check"), "1 fragments")
	refuses(t, tool(root, "-New", "-Type", "Nope", "-Text", "x"), "-Type is one of")
	refuses(t, tool(root, "-New", "-Type", "Added", "-Text", " "), "-Text is the entry")
	refuses(t, tool(root, "-New", "-Type", "Added", "-Text", "- One.\n- Two."), "not a fragment: several entries")
	testing.expect_value(t, fragment_count(root), 1)   // and the refused one left no file
}

@(test)
test_slug :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, slug("Old Pref!"), "old-pref")
	testing.expect_value(t, slug("**Tabs in a sidebar**: one."), "tabs-in-a-sidebar")
	testing.expect_value(t, slug("L'école à Besançon"), "l-ecole-a-besancon")
	testing.expect_value(t, slug("  ...  "), SLUG_DEFAULT)
	long := slug("the quick brown fox jumps over the lazy dog again and again and again")
	testing.expect_value(t, long, "the-quick-brown-fox-jumps-over-the-lazy-dog")   // cut at the last '-' before 48
	testing.expect_value(t, len(slug(strings.repeat("a", 100))), SLUG_MAX)       // nothing to cut at
}

// The fixture of the release: five fragments of four types, released as TEST_RELEASE.
released :: proc(name: string) -> (root: string, assembled: Result) {
	root = fresh(name)
	fragment(root, "20261026-100000-tabs.md", "type: Added\n\n**Tabs in a sidebar**: one.\n")
	fragment(root, "20261026-100001-tabs.md", "type: Fixed\r\n**Tabs** no longer flicker.\r\n")
	fragment(root, "20261026-100002-workers.md", "type: changed\n- **Workers**:\n  - one;\n  - two.\n")
	_ = tool(root, "-New", "-Type", "Removed", "-Subject", "Old Pref!", "-Text", "The `x.y` preference.")
	fragment(root, "20261026-100013-fix.md", "type: Fixed\n\n**A fix**.\n")
	return root, tool(root, "-Assemble", "-Version", TEST_RELEASE, "-Date", TEST_DATE)
}

@(test)
test_release :: proc(t: ^testing.T) {
	root := fresh("release")
	fragment(root, "20261026-100000-fix.md", "type: Fixed\n\n**A fix**.\n")
	refuses(t, tool(root, "-Check", "-Release", TEST_RELEASE), "1 fragments are not assembled: wrentool changelog -Assemble -Version 9.9.9")
	refuses(t, tool(root, "-Assemble", "-Version", TEST_RELEASE, "-Date", "27/10/2026"), "-Date is yyyy-MM-dd")
	refuses(t, tool(root, "-Assemble", "-Version", "nine"), "-Version is x.y.z")
	passes(t, tool(root, "-Assemble", "-Version", TEST_RELEASE, "-Date", TEST_DATE), "CHANGELOG.md: section 9.9.9 (1 entries)")
	cl := read(root, CHANGELOG_FILE)
	testing.expect(t, strings.contains(cl, "## [9.9.9] - 2026-10-27\r\n\r\n### Fixed\r\n- **A fix**.\r\n\r\n## [0.6.24] - 2026-01-01"), "the section above the last one")
	testing.expect_value(t, fragment_count(root), 0)
	bare, _ := strings.replace_all(cl, "\r\n", "", context.temp_allocator)
	testing.expect(t, !strings.contains(bare, "\n"), "the CHANGELOG keeps its CRLF")
	testing.expect(t, strings.contains(cl, "[Unreleased]: " + REPO_URL + "/compare/v9.9.9...HEAD\r\n"), "the Unreleased link moves")
	testing.expect(t, strings.contains(cl, "[9.9.9]: " + REPO_URL + "/compare/v" + TEST_BASE + "...v9.9.9\r\n"), "the link of the version")
	testing.expect(t, strings.has_suffix(cl, "[" + TEST_BASE + "]: " + REPO_URL + "/releases/tag/v" + TEST_BASE + "\r\n"), "the link references close the file")
	testing.expect_value(t, read(root, SOURCE_VERSION_FILE), "// version\nAPP_VERSION :: \"9.9.9\"\nAPP_VERSION_LABEL :: #config(WREN_VERSION_LABEL, \"\")\n")
	passes(t, tool(root, "-Check", "-Release", TEST_RELEASE), "ready to publish 9.9.9")
	passes(t, tool(root, "-Check"), "0 fragments")
	testing.expect(t, check_release(root, TEST_RELEASE), "check_release")
	testing.expect(t, !check_release(root, "9.9.8"), "check_release refuses another version")
	refuses(t, tool(root, "-Check", "-Release", "9.9.8"), "the latest section of CHANGELOG.md is '9.9.9', not 9.9.8")
	refuses(t, tool(root, "-Assemble", "-Version", TEST_RELEASE), "already has a section 9.9.9")
}

@(test)
test_release_sources_version :: proc(t: ^testing.T) {
	root := fresh("sources")
	write(root, SOURCE_VERSION_FILE, "nothing here\n")
	refuses(t, tool(root, "-Check", "-Release", TEST_BASE), "APP_VERSION not found in src/browser/about.odin")
	write(root, SOURCE_VERSION_FILE, "APP_VERSION :: \"1.2.3\"\n")
	refuses(t, tool(root, "-Check", "-Release", TEST_BASE), "the sources say version 1.2.3, not 0.6.24")
}

@(test)
test_section :: proc(t: ^testing.T) {
	root, assembled := released("section")
	passes(t, assembled)
	body, ok := section(root, TEST_RELEASE, context.temp_allocator)
	testing.expect(t, ok && strings.has_prefix(body, "### Added\n- **Tabs in a sidebar**: one.") && strings.contains(body, "### Removed") && !strings.contains(body, TEST_BASE), "-Section gives that section only")
	testing.expect(t, strings.has_suffix(body, "- **Tabs** no longer flicker.\n"), "trimmed, one newline")
	r := tool(root, "-Section", "-Version", TEST_RELEASE)
	testing.expect_value(t, r.out, body)
	last := tool(root, "-Section", "-Version", TEST_BASE)
	testing.expect_value(t, last.out, "### Added\n- **Old thing**: shipped.\n")   // it stops before the link references
	refuses(t, tool(root, "-Section", "-Version", "1.0.0"), "CHANGELOG.md has no section 1.0.0")
	refuses(t, tool(root, "-Section"), "-Section needs -Version")
	_, found := section(root, "1.0.0", context.temp_allocator)
	testing.expect(t, !found, "section of a version that is not there")
}

@(test)
test_form_refused :: proc(t: ^testing.T) {
	root, assembled := released("form")
	passes(t, assembled)
	good := read(root, CHANGELOG_FILE)
	passes(t, tool(root, "-Check"))
	// each case breaks a copy of a file that is right, -Check names what is wrong
	broken :: struct { what, from, to, said: string }
	cases := [?]broken{
		{"a heading of the old form",  "## [9.9.9] - 2026-10-27",    "## 9.9.9 - 2026-10-27",    "is not '## [x.y.z] - yyyy-MM-dd'"},
		{"a date that is not ISO",     "] - 2026-10-27",             "] - 27/10/2026",           "not an ISO date"},
		{"a date that does not exist", "] - 2026-10-27",             "] - 2026-13-45",           "not an ISO date"},
		{"an older date above",        "] - 2026-10-27",             "] - 2025-10-27",           "the newest comes first"},
		{"an unknown section",         "### Removed",                "### Improved",             "unknown section"},
		{"a section out of order",     "### Removed",                "### Security",             "comes after"},
		{"a section twice",            "### Removed",                "### Added",                "twice in one version"},
		{"an entry outside a section", "### Added\r\n- **Old",       "- **Old",                  "an entry outside a '### Type' section"},
		{"a duplicate version",        "## [" + TEST_BASE + "] -",   "## [9.9.9] -",             "twice"},
		{"a version below",            "## [9.9.9] -",               "## [0.0.1] -",             "comes below"},
		{"a heading in a section",     "### Fixed\r\n",              "### Fixed\r\n# Top\r\n",   "neither a version nor a section"},
		{"text under a section",       "### Fixed\r\n",              "### Fixed\r\nText.\r\n",   "not an entry"},
		{"no Unreleased",              "## [Unreleased]\r\n",        "",                         "has no heading '## [Unreleased]'"},
		{"a version without its link", "[9.9.9]: " + REPO_URL + "/compare/v" + TEST_BASE + "...v9.9.9\r\n", "", "link reference is missing"},
		{"a stale link",               "/compare/v9.9.9...HEAD",     "/compare/v0.0.1...HEAD",   "or the wrong one"},
		{"a link to no version",       "[" + TEST_BASE + "]: " + REPO_URL + "/releases/tag/v" + TEST_BASE, "[1.2.3]: " + REPO_URL + "/releases/tag/v1.2.3\r\n[" + TEST_BASE + "]: " + REPO_URL + "/releases/tag/v" + TEST_BASE, "names no version"},
		{"links out of order",         "[Unreleased]: " + REPO_URL + "/compare/v9.9.9...HEAD\r\n", "", "link reference is missing"},
	}
	for c in cases {
		testing.expectf(t, strings.contains(good, c.from), "the fixture holds %q", c.from)
		write(root, CHANGELOG_FILE, strings.concatenate({good[:strings.index(good, c.from)], c.to, good[strings.index(good, c.from) + len(c.from):]}, context.temp_allocator))
		r := tool(root, "-Check")
		testing.expectf(t, r.code != 0 && strings.contains(r.out, c.said), "-Check refuses %s (wanted %q): %s", c.what, c.said, r.out)
	}
	// the references in the wrong order
	swapped := fmt.aprintf("%s[%s]: %s/releases/tag/v%s\r\n[9.9.9]: %s/compare/v%s...v9.9.9\r\n", good[:strings.index(good, "[9.9.9]: ")], TEST_BASE, REPO_URL, TEST_BASE, REPO_URL, TEST_BASE, allocator = context.temp_allocator)
	write(root, CHANGELOG_FILE, swapped)
	refuses(t, tool(root, "-Check"), "not in the order of the versions")
	write(root, CHANGELOG_FILE, good)
	passes(t, tool(root, "-Check"))
}

@(test)
test_unreleased_and_migrate :: proc(t: ^testing.T) {
	root := fresh("migrate")
	cl, _ := strings.replace(TEST_CHANGELOG, "## [Unreleased]\r\n", "## [Unreleased]\r\n\r\n- Untyped one.\r\n- Untyped two.\r\n\r\n### Fixed\r\n- A fix.\r\n  - its detail.\r\n", 1, context.temp_allocator)
	write(root, CHANGELOG_FILE, cl)
	passes(t, tool(root, "-Check"), "warning: 3 entries under '## [Unreleased]' in CHANGELOG.md: write fragments instead (wrentool changelog -Migrate")
	refuses(t, tool(root, "-Assemble", "-Version", "9.9.10"), "an entry under '## [Unreleased]' with no '### Type'")
	preview := tool(root, "-Assemble")
	testing.expect_value(t, preview.out, "### Added\n- Untyped one.\n- Untyped two.\n\n### Fixed\n- A fix.\n  - its detail.\n")   // untyped ones are additions in a preview
	r := tool(root, "-Migrate")
	refuses(t, r, "line 7:")
	testing.expect(t, strings.contains(r.out, "These entries are under no '### Type' heading"), "it says what to give")
	refuses(t, tool(root, "-Migrate", "-DefaultType", "Nope"), "-DefaultType is one of")
	refuses(t, tool(root, "-Migrate", "-DefaultType", "Added", "-Types", "8"), "-Types is 'line=Type,line=Type' (got '8')")
	passes(t, tool(root, "-Migrate", "-DefaultType", "Added", "-Types", "8=Changed"), "3 entries of ## [Unreleased] are fragments in changelog.d/ now")
	// fragments and CHANGELOG are the same entries, in the same order
	want := "### Added\n- Untyped one.\n\n### Changed\n- Untyped two.\n\n### Fixed\n- A fix.\n  - its detail.\n"
	testing.expect_value(t, tool(root, "-Assemble").out, want)
	testing.expect_value(t, read(root, CHANGELOG_FILE), TEST_CHANGELOG)   // Unreleased is empty again, the rest untouched
	r = tool(root, "-Check")
	testing.expect(t, r.code == 0 && !strings.contains(r.out, "warning"), "Unreleased is empty after -Migrate")
	testing.expect_value(t, fragment_count(root), 3)
}

@(test)
test_usage_and_flags :: proc(t: ^testing.T) {
	root := fresh("usage")
	refuses(t, tool(root), "wrentool changelog: -New, -Check, -Assemble, -Section or -Migrate")
	out := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, execute({"-Nope", "-Root", root}, &out), 1)
	testing.expect_value(t, execute({"-Check", "-Root", "/nowhere/at/all"}, &out), 1)
	testing.expect(t, strings.contains(strings.to_string(out), "error: cannot read CHANGELOG.md"), "a checkout without CHANGELOG.md")
}

@(test)
test_dates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect(t, is_iso_date("2026-02-28") && !is_iso_date("2026-02-30") && is_iso_date("2028-02-29"), "real days only")
	testing.expect(t, !is_iso_date("2026-2-28") && !is_iso_date("27/10/2026") && !is_iso_date("2026-13-01") && !is_iso_date("abcd-ef-gh"), "yyyy-MM-dd only")
	when_ := time.Time{}
	testing.expect_value(t, stamp_of(when_), "19700101-000000")
	testing.expect_value(t, date_of(when_), "1970-01-01")
}

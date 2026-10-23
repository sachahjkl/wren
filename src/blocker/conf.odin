package blocker

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "wb:adblock"

// The blocker's configuration: which lists, the user's filters, the per-site switches, the dynamic rules and the totals.
// One text file in the profile (blocker/blocker.conf); the dashboard exports and imports the very same text, so a whole
// configuration moves between machines as one file.

List_State :: enum u8 { Idle, Queued, Downloading, Compiling }

List_Entry :: struct {
	id:            string,      // stable key ("easylist", "custom-3f2a9c")
	title:         string,
	group:         string,
	url:           string,
	description:   string,
	enabled:       bool,
	custom:        bool,
	lid:           u8,          // the number the engine knows it by (assigned when the engine is built)
	etag:          string,
	last_modified: string,
	updated:       i64,         // unix seconds: the last time the text changed
	checked:       i64,         // the last time the server was asked
	rules:         int,         // network + cosmetic filters it contributes to the current engine
	invalid:       int,         // lines that were not understood
	size:          int,         // bytes on disk
	error:         string,
	state:         List_State,
}

Conf :: struct {
	lists:      [dynamic]List_Entry,
	sites:      map[string]Site_Flags,
	my_filters: string,
	first_run:  bool,          // the first-launch choice of lists was shown
	loaded:     bool,
}

Catalog_Entry :: struct { id, title, group, url, description: string, default_on: bool }

CATALOG := [?]Catalog_Entry{
	{"ublock-filters", "uBlock filters", "Ads", "https://ublockorigin.github.io/uAssets/filters/filters.min.txt", "Filters made for uBlock Origin: ads, trackers, anti-blocker scripts, video ads (YouTube).", true},
	{"ublock-badware", "uBlock filters – Badware risks", "Malware", "https://ublockorigin.github.io/uAssets/filters/badware.min.txt", "Sites that distribute malware, scams, fake download buttons.", true},
	{"ublock-privacy", "uBlock filters – Privacy", "Privacy", "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt", "Trackers and privacy-invasive requests.", true},
	{"ublock-unbreak", "uBlock filters – Unbreak", "Ads", "https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt", "Exceptions that keep sites working despite the other lists.", true},
	{"ublock-quick-fixes", "uBlock filters – Quick fixes", "Ads", "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt", "Fast fixes for recent breakage and new ads.", true},
	{"easylist", "EasyList", "Ads", "https://easylist.to/easylist/easylist.txt", "The reference list of advertisements.", true},
	{"easyprivacy", "EasyPrivacy", "Privacy", "https://easylist.to/easylist/easyprivacy.txt", "Trackers and analytics.", true},
	{"adguard-base", "AdGuard Base", "Ads", "https://filters.adtidy.org/extension/ublock/filters/2_without_easylist.txt", "AdGuard's advertising filters (without what EasyList already has).", true},
	{"plowe", "Peter Lowe's Ad and tracking server list", "Ads", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext", "A plain list of advertising and tracking servers.", true},
	{"urlhaus", "Malware domains (URLhaus)", "Malware", "https://malware-filter.gitlab.io/urlhaus-filter/urlhaus-filter-ag-online.txt", "Hosts currently serving malware, from abuse.ch's URLhaus.", true},
	{"adguard-tracking", "AdGuard Tracking Protection", "Privacy", "https://filters.adtidy.org/extension/ublock/filters/3.txt", "AdGuard's tracker filters (large).", false},
	{"adguard-annoyances", "AdGuard Annoyances", "Annoyances", "https://filters.adtidy.org/extension/ublock/filters/14.txt", "Cookie notices, pop-ups, widgets, newsletter prompts.", false},
	{"adguard-cookies", "AdGuard Cookie Notices", "Annoyances", "https://filters.adtidy.org/extension/ublock/filters/18.txt", "Cookie consent banners.", false},
	{"adguard-social", "AdGuard Social Media", "Annoyances", "https://filters.adtidy.org/extension/ublock/filters/4.txt", "Social network buttons and widgets.", false},
	{"fanboy-annoyance", "Fanboy's Annoyances", "Annoyances", "https://secure.fanboy.co.nz/fanboy-annoyance.txt", "Cookie notices, in-page pop-ups and other annoyances.", false},
	{"fanboy-social", "Fanboy's Social", "Annoyances", "https://secure.fanboy.co.nz/fanboy-social.txt", "Social media content.", false},
	{"ublock-annoyances", "uBlock filters – Annoyances", "Annoyances", "https://ublockorigin.github.io/uAssets/filters/annoyances.min.txt", "Pop-ups, overlays, cookie notices, chat widgets.", false},
	{"ublock-experimental", "uBlock filters – Experimental", "Ads", "https://ublockorigin.github.io/uAssets/filters/experimental.min.txt", "Filters on trial: they may break pages.", false},
	{"adguard-mobile", "AdGuard Mobile Ads", "Ads", "https://filters.adtidy.org/extension/ublock/filters/11.txt", "Advertising seen on mobile sites.", false},
	{"phishing", "Phishing URL blocklist", "Malware", "https://malware-filter.gitlab.io/phishing-filter/phishing-filter.txt", "Phishing sites.", false},
	{"deu", "Germany: EasyList Germany", "Regions", "https://easylist.to/easylistgermany/easylistgermany.txt", "German-language advertising.", false},
	{"fra", "France: AdGuard French", "Regions", "https://filters.adtidy.org/extension/ublock/filters/16.txt", "French-language advertising.", false},
	{"spa", "Spain: EasyList Spanish", "Regions", "https://easylist-downloads.adblockplus.org/easylistspanish.txt", "Spanish-language advertising.", false},
	{"ita", "Italy: EasyList Italy", "Regions", "https://easylist-downloads.adblockplus.org/easylistitaly.txt", "Italian-language advertising.", false},
	{"nld", "Netherlands: AdGuard Dutch", "Regions", "https://filters.adtidy.org/extension/ublock/filters/8.txt", "Dutch-language advertising.", false},
	{"rus", "Russia: RuAdList", "Regions", "https://raw.githubusercontent.com/easylist/ruadlist/master/RuAdList-uBO.txt", "Russian-language advertising.", false},
	{"pol", "Poland: Polish filters", "Regions", "https://raw.githubusercontent.com/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock.txt", "Polish-language advertising.", false},
	{"jpn", "Japan: AdGuard Japanese", "Regions", "https://filters.adtidy.org/extension/ublock/filters/7.txt", "Japanese-language advertising.", false},
	{"chn", "China: AdGuard Chinese", "Regions", "https://filters.adtidy.org/extension/ublock/filters/224.txt", "Chinese-language advertising.", false},
	{"tur", "Turkey: AdGuard Turkish", "Regions", "https://filters.adtidy.org/extension/ublock/filters/13.txt", "Turkish-language advertising.", false},
	{"ind", "India: IndianList", "Regions", "https://easylist-downloads.adblockplus.org/indianlist.txt", "Indian-language advertising.", false},
	{"ukr", "Ukraine: AdGuard Ukrainian", "Regions", "https://filters.adtidy.org/extension/ublock/filters/23.txt", "Ukrainian-language advertising.", false},
}

clone_str :: proc(s: string) -> string { return s == "" ? "" : strings.clone(s) }

make_dirs :: proc(path: string) { _ = os.make_directory_all(path) }

@(private)
entry_from_catalog :: proc(c: Catalog_Entry) -> List_Entry {
	return List_Entry{id = clone_str(c.id), title = clone_str(c.title), group = clone_str(c.group), url = clone_str(c.url), description = clone_str(c.description), enabled = c.default_on}
}

@(private)
list_entry_free :: proc(e: ^List_Entry) {
	delete(e.id); delete(e.title); delete(e.group); delete(e.url); delete(e.description)
	delete(e.etag); delete(e.last_modified); delete(e.error)
	e^ = {}
}

conf_destroy :: proc(c: ^Conf) {
	for &l in c.lists { list_entry_free(&l) }
	delete(c.lists)
	for k in c.sites { delete(k) }
	delete(c.sites)
	delete(c.my_filters)
	c^ = {}
}

list_by_id :: proc(c: ^Conf, id: string) -> ^List_Entry {
	for &l in c.lists { if l.id == id { return &l } }
	return nil
}

// Adds the catalog's lists that the configuration does not know yet (new versions of the browser add lists).
@(private)
conf_defaults :: proc(c: ^Conf) {
	if c.sites == nil { c.sites = make(map[string]Site_Flags) }
	for ce in CATALOG {
		if list_by_id(c, ce.id) == nil { append(&c.lists, entry_from_catalog(ce)) }
	}
}

conf_path :: proc(b: ^Blocker) -> string {
	return b.persist ? strings.concatenate({b.dir, "/blocker.conf"}, context.temp_allocator) : ""
}

conf_load :: proc(b: ^Blocker) {
	c := &b.conf
	c.sites = make(map[string]Site_Flags)
	if p := conf_path(b); p != "" {
		if data, err := os.read_entire_file(p, context.allocator); err == nil {
			defer delete(data)
			conf_parse(b, string(data), false)
		}
	}
	conf_defaults(c)
	c.loaded = true
}

conf_save :: proc(b: ^Blocker) {
	p := conf_path(b)
	if p == "" { return }
	text := conf_text(b, true)
	defer delete(text)
	write_file_atomic(p, transmute([]byte)text)
}

@(private)
flags_text :: proc(f: Site_Flags) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for fl in Site_Flag {
		if fl in f {
			if strings.builder_len(sb) > 0 { strings.write_byte(&sb, ',') }
			strings.write_string(&sb, SITE_FLAG_NAMES[fl])
		}
	}
	return strings.to_string(sb)
}

SITE_FLAG_NAMES := [Site_Flag]string{
	.Off = "off", .No_Cosmetic = "no-cosmetic", .No_Scriptlets = "no-scriptlets", .Block_Fonts = "block-fonts", .Block_Media = "block-media",
	.Hard = "hard", .Allow_Fonts = "allow-fonts", .Soft = "soft",
}

@(private)
clean :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\t", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", "", context.temp_allocator)
	return out
}

// The configuration as text. `with_state`: also what the updater learned (etags, dates, counts) and the totals; an
// export for another machine leaves it out.
conf_text :: proc(b: ^Blocker, with_state: bool) -> string {
	c := &b.conf
	sb := strings.builder_make()
	strings.write_string(&sb, "# Wren content blocker configuration\nversion\t1\n")
	strings.write_string(&sb, "[lists]\n")
	for l in c.lists {
		fmt.sbprintf(&sb, "list\t%s\t%d\t%d\t%s\t%s", l.id, l.enabled ? 1 : 0, l.custom ? 1 : 0, clean(l.title), clean(l.url))
		if with_state { fmt.sbprintf(&sb, "\t%s\t%s\t%d\t%d\t%d\t%d\t%d", clean(l.etag), clean(l.last_modified), l.updated, l.checked, l.rules, l.invalid, l.size) }
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, "[sites]\n")
	for h, f in c.sites { if f != {} { fmt.sbprintf(&sb, "site\t%s\t%s\n", h, flags_text(f)) } }
	strings.write_string(&sb, "[rules]\n")
	for r in dyn_sorted(&b.dyn) { fmt.sbprintf(&sb, "rule\t%s\t%s\t%s\t%s\n", r.src, r.dst, DYN_TYPE_NAMES[r.type], r.action == .Block ? "block" : "allow") }
	if with_state {
		strings.write_string(&sb, "[state]\n")
		fmt.sbprintf(&sb, "first_run\t%d\ntotals\t%d\t%d\t%d\t%d\t%d\t%d\n", c.first_run ? 1 : 0, b.totals.blocked, b.totals.allowed, b.totals.redirected, b.totals.rewritten, b.totals.pages, b.totals.since)
	}
	strings.write_string(&sb, "[my-filters]\n")
	strings.write_string(&sb, c.my_filters)
	if !strings.has_suffix(c.my_filters, "\n") && c.my_filters != "" { strings.write_byte(&sb, '\n') }
	return strings.to_string(sb)
}

// Reads configuration text. `replace`: what the text does not mention is reset (an import); else it is the file's load.
// Returns the number of lines understood and ignored.
conf_parse :: proc(b: ^Blocker, text: string, replace: bool) -> (understood, ignored: int) {
	c := &b.conf
	section := ""
	mine := strings.builder_make(context.temp_allocator)
	seen_lists := make(map[string]bool, 64, context.temp_allocator)
	if replace {
		for k in c.sites { delete(k) }
		clear(&c.sites)
		dyn_clear(&b.dyn)
	}
	rest := text
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line: string
		if nl < 0 { line, rest = rest, "" } else { line, rest = rest[:nl], rest[nl + 1:] }
		line = strings.trim_right(line, "\r")
		if section == "my-filters" { strings.write_string(&mine, line); strings.write_byte(&mine, '\n'); continue }
		if line == "" || line[0] == '#' { continue }
		if line[0] == '[' && strings.has_suffix(line, "]") { section = line[1:len(line) - 1]; continue }
		f := strings.split(line, "\t", context.temp_allocator)
		switch f[0] {
		case "list":
			if len(f) < 6 { ignored += 1; continue }
			id := f[1]
			l := list_by_id(c, id)
			if l == nil {
				if f[3] != "1" { ignored += 1; continue }   // a catalog list this version does not know
				append(&c.lists, List_Entry{id = strings.clone(id), custom = true, group = strings.clone("Custom")})
				l = &c.lists[len(c.lists) - 1]
			}
			l.enabled = f[2] == "1"
			if l.custom {
				delete(l.title); l.title = strings.clone(f[4])
				delete(l.url); l.url = strings.clone(f[5])
			}
			seen_lists[l.id] = true
			if len(f) >= 13 {
				delete(l.etag); l.etag = clone_str(f[6])
				delete(l.last_modified); l.last_modified = clone_str(f[7])
				l.updated, _ = strconv.parse_i64(f[8])
				l.checked, _ = strconv.parse_i64(f[9])
				l.rules, _ = strconv.parse_int(f[10])
				l.invalid, _ = strconv.parse_int(f[11])
				l.size, _ = strconv.parse_int(f[12])
			}
			understood += 1
		case "site":
			if len(f) < 3 { ignored += 1; continue }
			flags := Site_Flags{}
			for n in strings.split(f[2], ",", context.temp_allocator) {
				for name, fl in SITE_FLAG_NAMES { if name == n { flags += {fl} } }
			}
			site_set_flags(b, f[1], flags)
			understood += 1
		case "rule":
			if len(f) < 5 { ignored += 1; continue }
			t, ok := dyn_type_from_name(f[3])
			if !ok { ignored += 1; continue }
			dyn_set(&b.dyn, f[1], f[2], t, f[4] == "block" ? .Block : .Allow)
			understood += 1
		case "first_run": c.first_run = len(f) > 1 && f[1] == "1"; understood += 1
		case "totals":
			if len(f) >= 7 {
				v, _ := strconv.parse_u64(f[1]); b.totals.blocked = v
				v, _ = strconv.parse_u64(f[2]); b.totals.allowed = v
				v, _ = strconv.parse_u64(f[3]); b.totals.redirected = v
				v, _ = strconv.parse_u64(f[4]); b.totals.rewritten = v
				v, _ = strconv.parse_u64(f[5]); b.totals.pages = v
				b.totals.since, _ = strconv.parse_i64(f[6])
			}
			understood += 1
		case "version":
		case: ignored += 1
		}
	}
	if replace || strings.builder_len(mine) > 0 {
		delete(c.my_filters)
		c.my_filters = strings.clone(strings.to_string(mine))
	}
	if replace {
		// an import also decides which lists are on: the ones it names, and only those
		for &l in c.lists { if !seen_lists[l.id] && !l.custom { l.enabled = false } }
	}
	if b.totals.since == 0 { b.totals.since = unix_ms() / 1000 }
	b.conf_ver += 1
	return
}

site_set_flags :: proc(b: ^Blocker, host: string, flags: Site_Flags) {
	c := &b.conf
	h := strings.to_lower(host, context.temp_allocator)
	if flags == {} {
		if _, ok := c.sites[h]; ok {
			for k in c.sites { if k == h { delete(k); break } }
			delete_key(&c.sites, h)
		}
	} else if _, ok := c.sites[h]; ok {
		c.sites[h] = flags
	} else {
		c.sites[strings.clone(h)] = flags
	}
	b.conf_ver += 1
}

// Switch one flag for a site (the panel's toggles).
site_toggle :: proc(b: ^Blocker, host: string, flag: Site_Flag, on: bool) {
	f := Site_Flags{}
	if cur, ok := b.conf.sites[host]; ok { f = cur }
	if on { f += {flag} } else { f -= {flag} }
	site_set_flags(b, host, f)
	conf_save(b)
	touch(b)
}

// The registrable domain a whitelist entry should use for a page (so that www.example.com and example.com share it).
site_key :: proc(host: string) -> string { return adblock.registrable_domain(host) }

// Custom list URL.
list_add_custom :: proc(b: ^Blocker, title, url: string) -> ^List_Entry {
	c := &b.conf
	h := adblock.hash_str(url)
	id := fmt.aprintf("custom-%08x", h)
	if l := list_by_id(c, id); l != nil { delete(id); l.enabled = true; return l }
	append(&c.lists, List_Entry{id = id, title = strings.clone(title != "" ? title : url), group = strings.clone("Custom"), url = strings.clone(url), enabled = true, custom = true})
	return &c.lists[len(c.lists) - 1]
}

list_remove :: proc(b: ^Blocker, id: string) {
	c := &b.conf
	for &l, i in c.lists {
		if l.id == id && l.custom {
			if b.persist { _ = os.remove(list_path(b, l.id)) }
			list_entry_free(&l)
			ordered_remove(&c.lists, i)
			break
		}
	}
}

list_path :: proc(b: ^Blocker, id: string) -> string {
	return strings.concatenate({b.dir, "/lists/", id, ".txt"}, context.temp_allocator)
}

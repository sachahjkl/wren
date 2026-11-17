package gen

// What Wren's site says when a page of it is shared, and the files around the pages (the toolkit's site package, build_meta):
//   wrentool site_meta <site> <out>   every page of <out> (a copy of <site>, or <site> itself) gets its canonical address, Open
//                                     Graph and Twitter tags, the home its structured data; feed.xml (from CHANGELOG.md),
//                                     sitemap.xml, site.webmanifest, llms.txt and a 404.html if there is none. The Pages
//                                     workflow runs it on the site it deploys.
//   wrentool site_card                the sharing card, site/img/card.png, drawn once in a local Chromium and kept in the repository

import "core:fmt"
import "core:strings"
import tk_site "toolkit:site"

@(private = "file")
version_anchor :: proc(version: string) -> string {
	dashed, _ := strings.replace_all(version, ".", "-", context.temp_allocator)
	return strings.concatenate({"v", dashed}, context.temp_allocator)
}

@(private = "file")
LD_FIELDS :: [?][2]string{{"applicationCategory", "BrowserApplication"}, {"operatingSystem", "Windows, Linux"}}

@(private = "file")
site_meta :: proc() -> tk_site.Meta {
	ld := LD_FIELDS
	fields := make([][2]string, len(ld), context.temp_allocator)
	copy(fields, ld[:])
	// (the vendor's fields are the toolkit's, the same in every program's site)
	m := tk_site.meta_default("Wren", "https://wren.froment.software/", "https://github.com/sachahjkl/wren",
		"A browser where WebAssembly runs everything, JavaScript included", "#121212", "#f39a2e", card = "img/card.png")
	m.ld_fields, m.ico = fields, "assets/wren.ico"
	m.root_domain = true   // (its own domain answers for /robots.txt and /favicon.ico)
	m.licence = ""         // (PolyForm Strict, not the default MIT: Wren's own pages say it)
	m.card_title, m.card_size, m.card_logo, m.card_font = "Wren", 190, 150, `"Segoe UI Variable Display", "Segoe UI", sans-serif`
	m.changelog_page, m.version_anchor = "changelog/", version_anchor
	return m
}

run_site_meta :: proc(args: []string) -> int {
	if len(args) != 2 { fmt.eprintln("wrentool site_meta <site> <out>"); return 2 }
	return tk_site.build_meta(site_meta(), args[0], args[1]) ? 0 : 1
}

run_site_card :: proc(args: []string) -> int {
	if len(args) != 0 { fmt.eprintln("wrentool site_card"); return 2 }
	return tk_site.draw_card(site_meta(), "site") ? 0 : 1
}

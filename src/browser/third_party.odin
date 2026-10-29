package browser

import "core:strings"
import "toolkit:ui"
import "wb:wasm"

////////////////////////////////
// The third-party software Wren is built from, for about:wren and about:licenses. The list is THIRD_PARTY.md itself
// (embedded: one table to keep up to date, and the release package carries the same file); the license texts are the
// files the release puts in licenses\ (tools\package.ps1), embedded as well, so they are readable offline and cannot
// drift from what ships. third_party_test.odin checks that every file of native\js\licenses is listed here.

THIRD_PARTY_MD :: #load("../../THIRD_PARTY.md", string)

// Versions the build info shows that no Odin constant holds (the others: ui.VERSION, wasm.WASMTIME_VERSION).
// third_party_test.odin checks it against tools\build_js.ps1.
QUICKJS_VERSION :: "0.17.0"
ODIN_VERSION_FILE :: #load("../../odin.version", string)

Third_Party :: struct {
	name:    string,   // "Wasmtime"
	url:     string,   // its home page ("" when THIRD_PARTY.md gives none)
	version: string,
	license: string,   // the SPDX-like expression of the table
	where_:  string,   // what it is used for
}

License_Text :: struct {
	id:    string,   // anchor in about:licenses
	title: string,
	text:  string,
	of:    string,   // the component it belongs to (a name of the table), for the link next to its row
	note:  string,    // shown above the text
}

// The texts, in the order of about:licenses.
LICENSE_TEXTS := [?]License_Text{
	{"wren", "Wren", #load("../../LICENSE", string), "Wren", "Wren's own code."},
	{"gui_toolkit", "gui_toolkit", #load("../../ext/gui_toolkit/LICENSE", string), "gui_toolkit", "Window, interface, renderer and text of the browser."},
	{"gui_toolkit-notice", "gui_toolkit notices", #load("../../ext/gui_toolkit/NOTICE.md", string), "gui_toolkit", "What gui_toolkit itself includes."},
	{"slug", "Slug", #load("../../ext/gui_toolkit/font/slug_ref/LICENSE-MIT", string), "Slug", "Text rendering uses the Slug algorithm and shaders by Eric Lengyel (credit required by its license)."},
	{"roboto", "Roboto", #load("../../ext/gui_toolkit/font/data/Roboto-LICENSE.txt", string), "Roboto, Inconsolata", "Fallback interface font, used only when Segoe UI is missing."},
	{"inconsolata", "Inconsolata", #load("../../ext/gui_toolkit/font/data/Inconsolata-OFL.txt", string), "Roboto, Inconsolata", "Fallback monospace font, used only when Consolas is missing."},
	{"noto-emoji", "Noto Color Emoji", #load("../../ext/gui_toolkit/font/data/NotoColorEmoji-OFL.txt", string), "Noto Color Emoji", "The built-in emoji font (text.emoji = builtin), drawn by the COLR interpreter of gui_toolkit."},
	{"wasmtime", "Wasmtime", #load("../../build/wasmtime/LICENSE", string), "Wasmtime", ""},
	{"lexbor", "Lexbor", #load("../../ext/lexbor/LICENSE", string), "Lexbor", ""},
	{"lexbor-notice", "Lexbor notice", #load("../../ext/lexbor/NOTICE", string), "Lexbor", ""},
	{"quickjs-ng", "QuickJS-ng", #load("../../native/js/licenses/quickjs-ng-LICENSE.txt", string), "QuickJS-ng", "The reference of the JavaScript engine: its number conversion and Unicode library are ported to Odin, and its bytecode format is followed."},
	{"emmalloc", "emmalloc", #load("../../native/js/licenses/emmalloc-LICENSE.txt", string), "emmalloc", "The heap of the JavaScript engine module (through Odin's base:runtime)."},
	{"webref", "webref", #load("../../native/js/licenses/webref-LICENSE.txt", string), "webref", "The Web IDL the JavaScript bindings are generated from."},
	{"rust-crates", "Rust libraries of the image decoders", #load("../../native/rust-crates.txt", string), "image decoders", "Every Rust crate linked into the image decoders (resvg, image-webp, rav1d, qcms and what they use), with its license and source."},
}

// The rows of THIRD_PARTY.md's table (temporary allocator). Empty when the file has no table.
third_party_list :: proc(md := THIRD_PARTY_MD) -> []Third_Party {
	out := make([dynamic]Third_Party, context.temp_allocator)
	rest := md
	in_table := false
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "|") { if in_table { break }; continue }
		in_table = true
		cells := strings.split(strings.trim(l, "|"), "|", context.temp_allocator)
		if len(cells) < 4 { continue }
		first := strings.trim_space(cells[0])
		if first == "Component" || strings.has_prefix(first, "---") { continue }
		tp := Third_Party{license = short_license(strings.trim_space(cells[2])), where_ = plain(strings.trim_space(cells[3]))}
		tp.name, tp.url = split_link(first)
		tp.version = short_version(strings.trim_space(cells[1]))
		append(&out, tp)
	}
	// versions the program knows better than the table
	for &tp in out {
		switch tp.name {
		case "gui_toolkit": tp.version = ui.VERSION
		case "Wasmtime":    tp.version = wasm.WASMTIME_VERSION
		case "QuickJS-ng": tp.version = QUICKJS_VERSION
		}
	}
	return out[:]
}

// "[Slug](https://github.com/EricLengyel/Slug) shaders and algorithm (Eric Lengyel), in gui_toolkit's `render/slug.hlsl`"
// -> "Slug", the link. Without a link: the text up to the first " (" or ",".
@(private = "file")
split_link :: proc(cell: string) -> (name, link: string) {
	if strings.has_prefix(cell, "[") {
		if close := strings.index(cell, "]("); close > 0 {
			end := strings.index_byte(cell[close + 2:], ')')
			if end >= 0 { return cell[1:close], cell[close + 2:][:end] }
		}
	}
	return plain(strings.trim_space(cell)), ""
}

// The text of a cell without Markdown's backticks and links.
@(private = "file")
plain :: proc(s: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		switch s[i] {
		case '`':
			i += 1
		case '[':
			close := strings.index(s[i:], "](")
			end := close >= 0 ? strings.index_byte(s[i + close:], ')') : -1
			if close > 0 && end > 0 {
				strings.write_string(&out, s[i + 1:i + close])
				i += close + end + 1
			} else { strings.write_byte(&out, '['); i += 1 }
		case:
			strings.write_byte(&out, s[i]); i += 1
		}
	}
	return strings.to_string(out)
}

// "49.0.3" stays; "0.17.0, patched (`native/js/patches`)" -> "0.17.0, patched"; "commit `be3c13eb…`" -> "be3c13eb";
// "submodule `ext/gui_toolkit`" and file names are where, not versions: "".
@(private = "file")
short_version :: proc(cell: string) -> string {
	s := plain(cell)
	if i := strings.index(s, " ("); i >= 0 { s = s[:i] }
	if strings.has_prefix(s, "commit ") {
		h := strings.trim_space(s[len("commit "):])
		return len(h) > 8 ? h[:8] : h
	}
	if strings.has_prefix(s, "submodule") || strings.contains(s, "/") || strings.contains(s, ".dat") { return "" }
	return strings.trim_space(s)
}

// The license column, up to its first note ("Apache-2.0 ... OR MIT; parts: musl (MIT)..." -> before the ';').
@(private = "file")
short_license :: proc(cell: string) -> string {
	s := plain(cell)
	if i := strings.index_byte(s, ';'); i >= 0 { s = s[:i] }
	return strings.trim_space(s)
}

// Lists what style sheets use that the style engine drops (style.audit_sheet): rules whose selectors do not parse,
// unknown properties, rejected values, false @supports conditions. Counted and sorted, for web-compatibility work.
//   cssaudit.exe sheet.css [more.css ...] [-all]      (-all: every entry, not only the 60 most frequent of each kind)
package cssaudit

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:slice"
import "wb:css"
import "wb:style"

main :: proc() {
	files := make([dynamic]string)
	all := false
	for a in os.args[1:] {
		if a == "-all" { all = true } else { append(&files, a) }
	}
	if len(files) == 0 {
		fmt.eprintln("usage: cssaudit sheet.css [more.css ...] [-all]")
		os.exit(2)
	}
	settings := style.settings_default()
	e := style.engine_make(settings)
	defer style.engine_destroy(e)
	counts: [style.Audit_Kind]map[string]int
	for &m in counts { m = make(map[string]int) }
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil { fmt.eprintfln("%s: cannot read", f); continue }
		sheet := css.parse_stylesheet(string(data), style.parse_options(&e.settings))
		entries := make([dynamic]style.Audit_Entry)
		style.audit_sheet(e, sheet, &entries)
		for en in entries { counts[en.kind][en.text] += 1 }
		fmt.printfln("%s: %d bytes, %d top-level rules, %d entries", f, len(data), len(sheet.rules), len(entries))
		css.stylesheet_destroy(sheet); free(sheet)
	}
	for kind in style.Audit_Kind {
		m := counts[kind]
		if len(m) == 0 { continue }
		Row :: struct { text: string, n: int }
		rows := make([dynamic]Row)
		total := 0
		for k, v in m { append(&rows, Row{k, v}); total += v }
		slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.n != b.n ? a.n > b.n : a.text < b.text })
		fmt.printfln("\n== %v: %d distinct, %d total", kind, len(rows), total)
		for r, i in rows {
			if !all && i >= 60 { fmt.printfln("  ... %d more", len(rows) - i); break }
			fmt.printfln("  %5d  %s", r.n, r.text)
		}
	}
}

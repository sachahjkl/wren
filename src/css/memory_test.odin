package css

import "core:fmt"
import "core:strings"
import "core:testing"

// What a parsed sheet keeps: its rules, selectors, declarations and their values, not its tokens, code points or the
// values of @media blocks read only to be parsed again. A site's 600 KB of CSS kept 42 MB; this sheet (dense selectors
// and values) kept 126 bytes per byte of CSS, now about 45.
@(test)
parsed_sheet_memory :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 3000 {
		fmt.sbprintf(&b, ".c%d .item-%d > a:hover, .theme-dark .c%d[data-x=\"%d\"] {{ color: var(--fg-%d, #12%04x); margin: 0 %dpx 4px; transition: opacity .2s ease-in-out, transform .3s cubic-bezier(.2,.8,.2,1); }}\n", i, i, i, i, i % 50, i, i % 9)
		if i % 20 == 0 {
			fmt.sbprintf(&b, "@media (min-width: %dpx) and (max-width: 1200px) {{ .m%d {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(%dpx, 1fr)); }} .n%d::before {{ content: \"\\2192\"; }} }}\n", 600 + i, i, 100 + i % 50, i)
		}
	}
	src := strings.to_string(b)
	s := parse_stylesheet(src, Parse_Options{max_nesting_depth = 512, max_rules = 100_000})
	defer { stylesheet_destroy(s); free(s) }
	testing.expect(t, len(s.rules) == 3000 + 150, fmt.tprintf("rules: %d", len(s.rules)))
	ratio := f64(s.arena.total_used) / f64(len(src))
	testing.expectf(t, ratio < 50, "a parsed sheet keeps %.1f bytes per byte of CSS (%d KiB for %d KiB)", ratio, s.arena.total_used / 1024, len(src) / 1024)
	// what it keeps is still all there: the last rule of a @media block, a declaration's value
	m := s.rules[len(s.rules) - 1]
	testing.expect(t, m.kind == .Media || m.kind == .Style)
	last_media: ^Rule
	for r in s.rules { if r.kind == .Media { last_media = r } }
	testing.expect(t, last_media != nil && len(last_media.rules) == 2 && len(last_media.rules[1].declarations) == 1)
	if last_media != nil && len(last_media.rules) == 2 {
		testing.expect_value(t, serialize_values(last_media.rules[1].declarations[0].value, context.temp_allocator), `"→"`)
	}
	testing.expect_value(t, serialize_values(s.rules[0].declarations[0].value, context.temp_allocator), "var(--fg-0, #120000)")
}

package fuzz

import "wb:css"

// The browser's own bounds (css.* preferences at their defaults): the parser's limits are part of what is under test.
CSS_OPTIONS :: css.Parse_Options{max_nesting_depth = 512, max_rules = 100_000, max_errors_kept = 100}

CSS_FILES := []Seed_Files{{dir = "examples", suffixes = {".css"}}, {dir = "site", suffixes = {".css"}}}

CSS_SEEDS := []string{
	"",
	"a{color:red}b,c>d~e+f{margin:1px 2px!important}",
	"@media (min-width: 600px) and (max-width: 900px), print and (orientation: landscape) { .a { display: none } }",
	"@supports (display: grid) and (not (display: inline-grid)) { @layer base, theme { .b { gap: 1em } } }",
	"@keyframes spin { from { transform: rotate(0deg) } 50% { opacity: .5 } to { transform: rotate(360deg) } }",
	"@font-face { font-family: 'X'; src: url(x.woff2) format('woff2'), local(Arial); unicode-range: U+0-7F, U+4??; }",
	"@import url('a.css') layer(x) supports(display: flex) screen; @namespace svg url(http://www.w3.org/2000/svg);",
	".p { color: red; & .c { color: blue; } &:hover { color: green } @media (hover) { color: pink } }",
	"@container card (inline-size > 30em) { .t { font-size: calc(1rem + 2cqi) } } @scope (.a) to (.b) { img { x: y } }",
	"a{background:url(data:image/png;base64,AAAA) no-repeat, linear-gradient(in oklch 45deg, red 10%, color-mix(in srgb, red, blue) 90%)}",
	"\\61 \\000062{content:'\\'\\\n\\0'}/* comment */<!-- -->@charset \"utf-8\";",
	"a{width:calc(100% - (2 * var(--x, 3px)) / 4);--y: { a b c };--z:;anchor-name:--a;position-anchor:--a;top:anchor(--a bottom)}",
	"@property --x { syntax: '<length>'; inherits: false; initial-value: 0px } @page :first { margin: 1in }",
	"@counter-style x { system: cyclic; symbols: a b } @font-feature-values F { @styleset { nice: 1 } }",
}

CSS_SELECT_SEEDS := []string{
	"a > b + c ~ d e",
	"*|*, svg|rect, |a, ns|*",
	"div#id.class[attr][attr=v][attr~=v i][attr|=v s][attr^='v'][attr$=\"v\"][attr*=v]",
	":is(a, b):where(.c, #d):not(:has(> img, + p)):nth-child(2n + 1 of .x):nth-last-of-type(-n+3)",
	"::before, ::after, ::part(x), ::slotted(span), :host(.a), :host-context(b), ::highlight(h), ::view-transition-group(*)",
	"a:hover:focus-visible:focus-within:checked:disabled:placeholder-shown:popover-open:state(x):dir(rtl):lang(fr, \"en-*\")",
	"& .a, .b &, &&",
	"screen and (min-width: 100px), not print, (400px <= width <= 700px), (aspect-ratio: 16/9), (prefers-color-scheme: dark)",
	"only screen and (-webkit-min-device-pixel-ratio: 2), (resolution >= 2dppx), (hover: hover) and (pointer: fine)",
}

CSS_TOKENS := []string{
	"{", "}", "(", ")", "[", "]", ";", ":", ",", ">", "+", "~", "*", "|", "&", "#", ".", "!important", "/*", "*/", "\\", "'", "\"",
	"url(", "var(--", "calc(", "attr(", "env(", "@media", "@supports", "@layer", "@import", "@keyframes", "@font-face", "@container",
	"@scope", "@namespace", "@property", "@page", "@charset", ":is(", ":where(", ":not(", ":has(", ":nth-child(", " of ", "::",
	"and", "or", "not", "only", "(min-width:", "<=", ">=", "1e9", "-0", "1e-9", "999999999999px", "U+", "\x00", "\n", "�",
}

target_css :: proc(data: []u8) {
	text := string(data)
	sheet := css.parse_stylesheet(text, CSS_OPTIONS)
	css.stylesheet_destroy(sheet)
	free(sheet)
	_ = css.parse_declarations(text, CSS_OPTIONS, context.temp_allocator)
}

// What a page's script hands the selector and media query parsers: querySelector(), matches(), matchMedia().
target_css_select :: proc(data: []u8) {
	values := css.parse_component_values(string(data), CSS_OPTIONS, context.temp_allocator)
	_, _ = css.parse_selector_list(values, context.temp_allocator, nil)
	_ = css.parse_media_query_list(values, context.temp_allocator)
}

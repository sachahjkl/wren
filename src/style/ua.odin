package style

import "core:fmt"
import "core:strings"
import "wb:css"

// The browser's default stylesheet. It is text, generated from the settings, so colors, margins and font sizes that are
// "the browser's choice" are preferences and not constants. It follows the HTML Standard's rendering section in spirit; it
// is a starting point that real pages override.

@(private)
css_color :: proc(c: css.Color) -> string {
	return fmt.tprintf("rgba(%d, %d, %d, %.3f)", int(c.r * 255 + 0.5), int(c.g * 255 + 0.5), int(c.b * 255 + 0.5), c.a)
}

ua_stylesheet_text :: proc(s: ^Settings, allocator := context.allocator) -> string {
	// fmt would read the braces of CSS as format directives: the template holds `%v` placeholders filled in order
	values := [?]string{
		css_color(s.text_color), css_color(s.background_color), fmt.tprintf("%g", s.body_margin),
		css_color(s.link_color), css_color(s.visited_color), css_color(s.active_link_color), fmt.tprintf("%g", s.monospace_font_size),
	}
	sb := strings.builder_make(allocator)
	rest := UA_TEMPLATE
	n := 0
	for {
		i := strings.index(rest, "%v")
		if i < 0 { break }
		strings.write_string(&sb, rest[:i])
		strings.write_string(&sb, values[n])
		n += 1
		rest = rest[i + 2:]
	}
	strings.write_string(&sb, rest)
	return strings.to_string(sb)
}

UA_TEMPLATE :: `html { display: block; color: %v; background-color: %v; }
head, link, meta, script, style, title, base, template, noscript, area, datalist, param, source, track, rp { display: none; }
[hidden] { display: none; }
address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr, legend, listing, main, p, plaintext, pre, search, xmp,
article, aside, h1, h2, h3, h4, h5, h6, hgroup, nav, section, dir, dd, dl, dt, menu, ol, ul, details, summary, fieldset, optgroup, body { display: block; }
body { margin: %vpx; }
li { display: list-item; }
p, dl, multicol { margin-block: 1em; }
blockquote, figure { margin: 1em 40px; }
h1 { font-size: 2em; margin-block: 0.67em; font-weight: bold; }
h2 { font-size: 1.5em; margin-block: 0.83em; font-weight: bold; }
h3 { font-size: 1.17em; margin-block: 1em; font-weight: bold; }
h4 { margin-block: 1.33em; font-weight: bold; }
h5 { font-size: 0.83em; margin-block: 1.67em; font-weight: bold; }
h6 { font-size: 0.67em; margin-block: 2.33em; font-weight: bold; }
dd { margin-left: 40px; }
ul, ol, menu, dir { margin-block: 1em; padding-left: 40px; }
ol, ul, menu, dir { counter-reset: list-item; }
ul { list-style-type: disc; }
ol { list-style-type: decimal; }
ul ul, ol ul { list-style-type: circle; }
ul ul ul, ol ul ul, ul ol ul, ol ol ul { list-style-type: square; }
ul ul, ul ol, ol ul, ol ol { margin-block: 0; }
hr { color: gray; border-style: inset; border-width: 1px; margin: 0.5em auto; overflow: hidden; }
a:link { color: %v; text-decoration: underline; cursor: pointer; }
a:visited { color: %v; text-decoration: underline; cursor: pointer; }
a:link:active, a:visited:active { color: %v; }
b, strong { font-weight: bolder; }
i, cite, em, var, dfn, address { font-style: italic; }
u, ins { text-decoration: underline; }
s, strike, del { text-decoration: line-through; }
small { font-size: smaller; }
big { font-size: larger; }
sub { vertical-align: sub; font-size: smaller; }
sup { vertical-align: super; font-size: smaller; }
mark { background-color: yellow; color: black; }
abbr[title], acronym[title] { text-decoration: underline dotted; }
q::before { content: open-quote; }
q::after { content: close-quote; }
pre, listing, xmp, plaintext { white-space: pre; }
pre, code, kbd, samp, tt, listing, xmp, plaintext { font-family: monospace; font-size: %vpx; }
nobr { white-space: nowrap; }
br { display: inline; }
center { text-align: center; }
img, video, canvas, iframe, embed, object { display: inline-block; }
img { overflow: clip; }
iframe { border: 2px inset; }
button, input, select, textarea, meter, progress { display: inline-block; }
input, select, textarea, button { font-family: system-ui; font-size: 13.333px; text-align: start; box-sizing: border-box; margin: 0; }
input, textarea, select { background-color: white; color: black; border: 2px inset gray; padding: 1px 2px; }
button, input[type=button], input[type=submit], input[type=reset] { background-color: #efefef; color: black; border: 2px outset #767676; padding: 1px 6px; text-align: center; cursor: default; }
input[type=checkbox], input[type=radio] { width: 13px; height: 13px; padding: 0; margin: 3px 3px 3px 4px; }
input[type=hidden] { display: none; }
textarea { font-family: monospace; white-space: pre-wrap; overflow: auto; }
fieldset { margin-inline: 2px; padding: 0.35em 0.75em 0.625em; border: 2px groove gray; }
legend { padding-inline: 2px; }
:disabled { color: gray; cursor: default; }
table { display: table; border-spacing: 2px; border-collapse: separate; text-indent: initial; }
caption { display: table-caption; text-align: center; }
colgroup { display: table-column-group; }
col { display: table-column; }
thead { display: table-header-group; vertical-align: middle; }
tbody { display: table-row-group; vertical-align: middle; }
tfoot { display: table-footer-group; vertical-align: middle; }
tr { display: table-row; vertical-align: inherit; }
td, th { display: table-cell; padding: 1px; vertical-align: inherit; }
th { font-weight: bold; text-align: center; }
details > summary { display: block; cursor: default; }
summary { display: list-item; list-style-type: disclosure-closed; counter-increment: list-item 0; }
details[open] > summary { list-style-type: disclosure-open; }
:focus-visible { outline: 2px solid #4d90fe; }
::marker { color: inherit; }
`

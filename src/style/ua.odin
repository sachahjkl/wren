package style

import "core:fmt"
import "core:strings"

// The browser's default stylesheet. It is text, generated from the settings, so colors, margins and font sizes that are
// "the browser's choice" are preferences and not constants. It follows the HTML Standard's rendering section in spirit; it
// is a starting point that real pages override.

ua_stylesheet_text :: proc(s: ^Settings, allocator := context.allocator) -> string {
	// fmt would read the braces of CSS as format directives: the template holds `%v` placeholders filled in order.
	// Colors are system colors (color_scheme.odin): each element shows those of its used color scheme, and their values
	// are preferences. Canvas is the canvas color (Styled.canvas), not a background of the root element: a root
	// background would stop the body's from propagating to the canvas (CSS Backgrounds 3 §2.11.2).
	values := [?]string{fmt.tprintf("%g", s.body_margin)}
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
	// HTML 15.3.1: noscript is not rendered when scripting is enabled for the document
	if s.scripting { strings.write_string(&sb, "\nnoscript { display: none !important; }\n") }
	return strings.to_string(sb)
}

UA_TEMPLATE :: `html { display: block; color: CanvasText; }
head, link, meta, script, style, title, base, template, area, datalist, param, source, track, rp { display: none; }
slot { display: contents; }
[hidden] { display: none; }
dialog:not([open]), [popover]:not(:popover-open) { display: none; }
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
a:link { color: LinkText; text-decoration: underline; cursor: pointer; }
a:visited { color: VisitedText; text-decoration: underline; cursor: pointer; }
a:link:active, a:visited:active { color: ActiveText; }
b, strong { font-weight: bolder; }
i, cite, em, var, dfn, address { font-style: italic; }
u, ins { text-decoration: underline; }
s, strike, del { text-decoration: line-through; }
small { font-size: smaller; }
big { font-size: larger; }
sub { vertical-align: sub; font-size: smaller; }
sup { vertical-align: super; font-size: smaller; }
mark { background-color: Mark; color: MarkText; }
abbr[title], acronym[title] { text-decoration: underline dotted; }
q::before { content: open-quote; }
q::after { content: close-quote; }
pre, listing, xmp, plaintext { white-space: pre; }
/* (their size follows the family: font.size.monospace for text of the default size, values.odin generic_family_adjust) */
pre, code, kbd, samp, tt, listing, xmp, plaintext { font-family: monospace; }
nobr { white-space: nowrap; }
br { display: inline; }
center { text-align: -webkit-center; }
img, video, canvas, iframe, embed, object { display: inline-block; }
img { overflow: clip; }
iframe { border: 2px inset; }
button, input, select, textarea, meter, progress { display: inline-block; }
/* (Chromium's -webkit-small-control on Windows: 13.333px Arial; textarea and select: its 1px borders) */
input, select, textarea, button { font-family: Arial; font-size: 13.333px; text-align: start; margin: 0; }
/* text fields keep content-box sizing, as in other browsers (quirks mode makes them border-box: hints.odin) */
select, button, input[type=button i], input[type=submit i], input[type=reset i], input[type=checkbox i], input[type=radio i], input[type=color i], input[type=file i] { box-sizing: border-box; }
input, textarea, select { background-color: Field; color: FieldText; border: 2px inset light-dark(#767676, #858585); padding: 1px 2px; }
button, input[type=button], input[type=submit], input[type=reset] { background-color: ButtonFace; color: ButtonText; border: 2px outset ButtonBorder; padding: 1px 6px; text-align: center; cursor: default; }
input[type=checkbox], input[type=radio] { width: 13px; height: 13px; padding: 0; margin: 3px 3px 3px 4px; }
input[type=hidden] { display: none; }
textarea { font-family: monospace; white-space: pre-wrap; overflow: auto; border: 1px solid light-dark(#767676, #858585); padding: 2px; }
select { border: 1px solid light-dark(#767676, #858585); padding: 0; }
fieldset { margin-inline: 2px; padding: 0.35em 0.75em 0.625em; border: 2px groove ThreeDFace; }
legend { padding-inline: 2px; }
:disabled { color: GrayText; cursor: default; }
table { display: table; border-spacing: 2px; border-collapse: separate; text-indent: initial; border-color: gray; }
caption { display: table-caption; text-align: center; }
colgroup { display: table-column-group; }
col { display: table-column; }
thead { display: table-header-group; vertical-align: middle; border-color: inherit; }
tbody { display: table-row-group; vertical-align: middle; border-color: inherit; }
tfoot { display: table-footer-group; vertical-align: middle; border-color: inherit; }
tr { display: table-row; vertical-align: inherit; border-color: inherit; }
td, th { display: table-cell; padding: 1px; vertical-align: inherit; }
th { font-weight: bold; text-align: center; }
summary { display: block; }
details > summary:first-of-type { display: list-item; counter-increment: list-item 0; list-style: disclosure-closed inside; cursor: default; }
details[open] > summary:first-of-type { list-style-type: disclosure-open; }
/* a closed details element shows its summary only (text directly inside it still shows: no CSS selects text) */
details:not([open]) > :not(summary:first-of-type) { display: none !important; }
:focus-visible { outline: 2px solid #4d90fe; }
::marker { color: inherit; }
[dir=ltr i] { direction: ltr; }
[dir=rtl i] { direction: rtl; }
[dir], bdi, output { unicode-bidi: isolate; }
[dir=auto i] { unicode-bidi: plaintext; }
bdo, bdo[dir] { unicode-bidi: isolate-override; }
`

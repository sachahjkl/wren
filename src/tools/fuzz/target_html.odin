package fuzz

import "wb:dom"
import "wb:html"

// What a page may hold, well past what real pages do: the parser's own bound, not the fuzzer's, is under test.
HTML_MAX_NODES :: 200_000

HTML_FILES := []Seed_Files{{dir = "examples", suffixes = {".html", ".htm", ".xhtml", ".svg"}}}

HTML_SEEDS := []string{
	"",
	"<!DOCTYPE html><html><head><meta charset=utf-8><title>t</title></head><body><p>a<b>b<i>c</b>d</i></p></body></html>",
	"<table><tr><td>a<td>b<tr><th>c</table><table><caption>x<col><tbody><tr><td><table><td>nested</table>",
	"<div><template shadowrootmode=open><slot></slot><style>:host{}</style></template><span>light</span></div>",
	"<template shadowrootmode=closed shadowrootdelegatesfocus><template shadowrootmode=open>deep</template></template>",
	"<svg viewBox='0 0 10 10'><foreignObject><p>html in svg</p></foreignObject><desc><b>x</b></desc></svg><math><mi>x</mi><annotation-xml encoding='text/html'><p>y</p></annotation-xml></math>",
	"<script>var a = '<!--<script>'; </script><!-- --!><script><!--<script></script>--></script><style><!--</style>",
	"<select><option>a<optgroup><option>b</select><textarea><b></textarea><title><i></title><plaintext><a>",
	"<a href=x><p><a href=y>adoption</a></p></a><b><p>agency<i>formatting</b>elements</i>",
	"<frameset><frame><noframes><p></noframes></frameset><noscript><img src=a></noscript><iframe srcdoc='<b>'></iframe>",
	"&amp;&lt;&#x26;&#38;&#0;&#xD800;&#1114112;&notin;&notit;&AElig&ampx;",
	"<img src=a.png srcset='a.png 1x, b.png 2x' sizes='(max-width: 600px) 100vw'><link rel=preload as=style href=s.css><base href=/x/>",
	"<html a=1 a=2><body b=1><body c=2><head><head>",
	"<ruby>a<rb>b<rt>c<rp>(</rp></ruby><dl><dt>a<dd>b<dt>c</dl><ul><li>a<li>b</ul>",
}

HTML_TOKENS := []string{
	"<", ">", "</", "/>", "<!--", "-->", "<!DOCTYPE html>", "<![CDATA[", "]]>", "=", "\"", "'", "&", ";", "&#x", "&#",
	"<html>", "<head>", "<body>", "<p>", "<div>", "<table>", "<tr>", "<td>", "<template>", "<template shadowrootmode=open>",
	"<svg>", "<math>", "<foreignObject>", "<script>", "</script>", "<style>", "</style>", "<textarea>", "<title>", "<select>",
	"<option>", "<frameset>", "<noscript>", "<plaintext>", "<xmp>", "<iframe>", "<object>", "<a href=", "<b>", "</b>", "<i>",
	"<form>", "<input>", "<img src=", "<base href=", "<meta charset=", "<meta http-equiv=content-type content='text/html; charset=",
	"<link rel=stylesheet href=", "\x00", "\r\n", "\ufeff",
}

// Contexts of the fragment algorithm: each puts the tokenizer and the tree builder in another state.
@(private = "file")
Fragment_Context :: struct {
	tag: string,
	ns:  dom.Namespace,
}

@(private = "file")
FRAGMENT_CONTEXTS := [?]Fragment_Context{
	{"body", .HTML}, {"template", .HTML}, {"table", .HTML}, {"tr", .HTML}, {"select", .HTML}, {"textarea", .HTML},
	{"script", .HTML}, {"style", .HTML}, {"html", .HTML}, {"svg", .SVG}, {"foreignObject", .SVG}, {"math", .MathML},
}

target_html :: proc(data: []u8) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	_ = html.parse_into(d, d.root, data, HTML_MAX_NODES)
	// (the context and the mode from the input itself: the same input always takes the same path)
	pick := len(data) > 0 ? int(data[len(data) - 1]) : 0
	c := FRAGMENT_CONTEXTS[pick % len(FRAGMENT_CONTEXTS)]
	modes := [?]dom.Document_Mode{.No_Quirks, .Quirks, .Limited_Quirks}
	_, _ = html.parse_fragment(d, c.tag, c.ns, modes[pick % len(modes)], data, HTML_MAX_NODES, declarative_shadow = pick % 2 == 0)
}

// The charsets a Content-Type may name: each takes decode_document through another decoder.
@(private = "file")
HEADER_CHARSETS := [?]string{"", "utf-8", "windows-1252", "shift_jis", "euc-jp", "iso-2022-jp", "gb18030", "big5", "euc-kr", "utf-16le", "utf-16be", "x-user-defined", "replacement", "bogus"}

target_html_scan :: proc(data: []u8) {
	pick := len(data) > 0 ? int(data[0]) : 0
	scan(data, len(data), pick % 2 == 0)
	// (a cut anywhere: the scanner keeps its state between two calls, and a tag split in two is where it can go wrong)
	scan(data, 1 + pick % 61, pick % 2 == 1)
	decoded, _ := html.decode_document(data, HEADER_CHARSETS[pick % len(HEADER_CHARSETS)], "windows-1252", context.allocator)
	delete(decoded.text)
}

// The preload scanner fed `data` as a network delivers it: a longer prefix at each call.
@(private = "file")
scan :: proc(data: []u8, step: int, scripting: bool) {
	s := html.Preload_Scanner{scripting = scripting}
	defer html.scan_destroy(&s)
	s.on_tag = proc(user: rawptr, t: ^html.Scan_Tag) {
		_, _ = html.scan_attr(t, "src")
		_, _ = html.scan_attr(t, "srcset")
		_ = html.scan_has_attr(t, "async")
	}
	if len(data) == 0 { html.scan_feed(&s, data); return }
	for n := step; ; n += step {
		html.scan_feed(&s, data[:min(n, len(data))])
		if n >= len(data) { break }
	}
}

package xml

import "core:fmt"
import "core:strings"
import "core:testing"

// The document as one line: <uri|prefix|local a=v ...> ... text "t", cdata [c], comment (c), pi ?t d?, doctype !n p s!
@(private = "file")
trace :: proc(src: string) -> (string, Result) {
	b := strings.builder_make(context.temp_allocator)
	sink := Sink{user = &b}
	sink.start_element = proc(u: rawptr, uri, prefix, local: string, attrs: []Attribute) {
		b := (^strings.Builder)(u)
		fmt.sbprintf(b, "<%s|%s|%s", uri, prefix, local)
		for a in attrs { fmt.sbprintf(b, " %s|%s|%s=%s", a.uri, a.prefix, a.local, a.value) }
		strings.write_byte(b, '>')
	}
	sink.end_element = proc(u: rawptr) { strings.write_string((^strings.Builder)(u), "</>") }
	sink.text = proc(u: rawptr, s: string) { fmt.sbprintf((^strings.Builder)(u), "%q", s) }
	sink.cdata = proc(u: rawptr, s: string) { fmt.sbprintf((^strings.Builder)(u), "[%s]", s) }
	sink.comment = proc(u: rawptr, s: string) { fmt.sbprintf((^strings.Builder)(u), "(%s)", s) }
	sink.pi = proc(u: rawptr, t, d: string) { fmt.sbprintf((^strings.Builder)(u), "?%s %s?", t, d) }
	sink.doctype = proc(u: rawptr, n, pub, sys: string) { fmt.sbprintf((^strings.Builder)(u), "!%s %s %s!", n, pub, sys) }
	r := parse(src, &sink)
	return strings.to_string(b), r
}

@(test)
xml_well_formed :: proc(t: ^testing.T) {
	got, r := trace(`<?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "ent">]><r xmlns="urn:d" xmlns:p="urn:p" p:a="1&amp;2" b='x&#x41;'><p:c>t&e;&lt;</p:c><![CDATA[<raw>]]><!--c--><?pi data?><e/></r>`)
	testing.expect(t, r.ok)
	testing.expect_value(t, got, `!r  !<urn:d||r http://www.w3.org/2000/xmlns/||xmlns=urn:d http://www.w3.org/2000/xmlns/|xmlns|p=urn:p urn:p|p|a=1&2 ||b=xA><urn:p|p|c>"tent<"</>[<raw>](c)?pi data?<urn:d||e></></>`)
	got, r = trace("<a\r\nx=\"1\t2\">l1\r\nl2</a>")
	testing.expect(t, r.ok)
	testing.expect_value(t, got, `<||a ||x=1 2>"l1\nl2"</>`)
}

@(test)
xml_errors :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"<a><b></a>", "does not match"},
		{"<a>", "is not closed"},
		{"", "no root element"},
		{"<a/><b/>", "more than one root"},
		{"<a x='1' x='2'/>", "appears twice"},
		{"<p:a/>", "is not bound"},
		{"<a>&nope;</a>", "is not defined"},
		{"text<a/>", "outside the root"},
		{"<a b=c/>", "must be quoted"},
		{"<a><!-- x -- y --></a>", "'--'"},
		{"<a>&#0;</a>", "does not allow"},
	}
	for c in cases {
		_, r := trace(c[0])
		testing.expectf(t, !r.ok && strings.contains(r.message, c[1]), "%q: %v %q", c[0], r.ok, r.message)
	}
	_, r := trace("<a>\n  <b></c>\n</a>")
	testing.expect_value(t, r.line, 2)
}

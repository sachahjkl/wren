package blocker

import "core:strings"
import "core:testing"
import "wb:fetch"

@(private = "file")
run_filter :: proc(f: fetch.Body_Filter, chunks: []string) -> string {
	out := make([dynamic]byte, context.temp_allocator)
	for c in chunks { f.push(f.user, transmute([]byte)c, &out) }
	if f.finish != nil { f.finish(f.user, &out) }
	f.destroy(f.user)
	return string(out[:])
}

@(private = "file")
prune_rule :: proc(paths, required: string) -> Prune_Rule {
	r := Prune_Rule{paths = parse_paths(paths), required = parse_paths(required)}
	r.keys = make([]string, len(r.paths))
	for p, i in r.paths { r.keys[i] = strings.clone(p[len(p) - 1]) }
	return r
}

@(private = "file")
free_prune :: proc(r: ^Prune_Rule) {
	for p in r.paths { for s in p { delete(s) }; delete(p) }
	for p in r.required { for s in p { delete(s) }; delete(p) }
	delete(r.paths); delete(r.required)
	for k in r.keys { delete(k) }
	delete(r.keys)
}

@(test)
test_prune_json :: proc(t: ^testing.T) {
	r := prune_rule("a.b list.*.x", "")
	defer free_prune(&r)
	rules := []^Prune_Rule{&r}
	out, changed := prune_json_text(`{"a":{"b":1,"c":2},"list":[{"x":1,"y":2},{"x":3}],"z":true}`, rules)
	testing.expect(t, changed)
	testing.expect(t, !strings.contains(out, `"b"`) && strings.contains(out, `"c":2`) && !strings.contains(out, `"x"`) && strings.contains(out, `"y":2`) && strings.contains(out, `"z":true`), out)
	// nothing named: the text comes back as it was, not parsed
	same := `{"q": 1,   "w":2}`
	out2, ch2 := prune_json_text(same, rules)
	testing.expect(t, !ch2 && out2 == same)
	// big integers survive
	out3, _ := prune_json_text(`{"a":{"b":0},"id":9007199254740993}`, rules)
	testing.expect(t, strings.contains(out3, "9007199254740993"), out3)
	// invalid JSON is left alone
	out4, ch4 := prune_json_text(`{"a":{"b":`, rules)
	testing.expect(t, !ch4 && out4 == `{"a":{"b":`)
}

@(test)
test_prune_required :: proc(t: ^testing.T) {
	r := prune_rule("ads", "player")
	defer free_prune(&r)
	rules := []^Prune_Rule{&r}
	_, c1 := prune_json_text(`{"ads":[1],"player":{}}`, rules)
	_, c2 := prune_json_text(`{"ads":[1]}`, rules)
	testing.expect(t, c1 && !c2)
	// array indexes and the end of an array
	r2 := prune_rule("items.1", "")
	defer free_prune(&r2)
	out, ch := prune_json_text(`{"items":["a","b","c"]}`, []^Prune_Rule{&r2})
	testing.expect(t, ch && strings.contains(out, `"a"`) && !strings.contains(out, `"b"`) && strings.contains(out, `"c"`), out)
}

@(test)
test_xml_prune :: proc(t: ^testing.T) {
	xml := `<?xml version="1.0"?><MPD><Period id="main" type="static"><AdaptationSet id="1"/></Period><Period id="x-roll-1" type="static"><AdaptationSet id="2"/></Period></MPD>`
	r := Xml_Rule{selector = `Period[id*="-roll-"][type="static"]`}
	out, ch := xml_prune_text(xml, []^Xml_Rule{&r})
	testing.expect(t, ch && !strings.contains(out, "roll") && strings.contains(out, `id="main"`) && strings.contains(out, `</MPD>`), out)
	r2 := Xml_Rule{selector = `Period > AdaptationSet[id="1"]`}
	out2, ch2 := xml_prune_text(xml, []^Xml_Rule{&r2})
	testing.expect(t, ch2 && !strings.contains(out2, `id="1"`) && strings.contains(out2, `id="2"`), out2)
	r3 := Xml_Rule{selector = `Period`, check = `Nothing`}
	_, ch3 := xml_prune_text(xml, []^Xml_Rule{&r3})
	testing.expect(t, !ch3)
}

@(test)
test_html_literals :: proc(t: ^testing.T) {
	rules := []Embed_Rule{
		{var = "ytInitialPlayerResponse", path = []string{"adPlacements"}, action = .Delete},
		{var = "ytInitialPlayerResponse", path = []string{"playerAds"}, action = .Set, value = "[]"},
	}
	page := `<html><script>var ytInitialPlayerResponse = {"videoDetails":{"id":"x"},"adPlacements":[{"a":1}],"playerAds":[{"b":2}]};var other = 1;</script>ytInitialPlayerResponseX = {"adPlacements":1}</html>`
	// the whole text in one chunk
	out := run_filter(html_filter_make(rules), []string{page})
	testing.expect(t, !strings.contains(out, `"adPlacements":[`) && strings.contains(out, `"playerAds":[]`) && strings.contains(out, `"videoDetails"`) && strings.contains(out, "var other = 1;"), out)
	// the identifier that only starts with the name is left alone
	testing.expect(t, strings.contains(out, `ytInitialPlayerResponseX = {"adPlacements":1}`), out)
	// the same text in chunks of every size, cut anywhere: the result is the same bytes
	for size in 1 ..< 40 {
		chunks := make([dynamic]string, context.temp_allocator)
		for i := 0; i < len(page); i += size { append(&chunks, page[i:min(i + size, len(page))]) }
		got := run_filter(html_filter_make(rules), chunks[:])
		// (the keys of an object come out in no fixed order: the same text, the same length, the same pieces)
		ok := len(got) == len(out) && !strings.contains(got, `"adPlacements":[`) && strings.contains(got, `"playerAds":[]`) && strings.contains(got, `"videoDetails":{"id":"x"}`) && strings.contains(got, "};var other = 1;")
		testing.expectf(t, ok, "chunks of %d bytes: %s", size, got)
	}
	// a page without the variable passes through untouched
	plain := `<html><body>nothing to see</body></html>`
	testing.expect_value(t, run_filter(html_filter_make(rules), []string{plain[:10], plain[10:]}), plain)
	// a literal that never closes is passed through as it came
	cut := `<script>var ytInitialPlayerResponse = {"adPlacements":[1`
	testing.expect_value(t, run_filter(html_filter_make(rules), []string{cut}), cut)
}

@(test)
test_youtube_replace_rules :: proc(t: ^testing.T) {
	// the rules of uBlock Origin's list, as written in it
	a1 := split_args(`trusted-replace-xhr-response, /"adPlacements.*?([A-Z]"\}|"\}{2\,4})\}\]\,/, , /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/`)
	testing.expect_value(t, len(a1), 4)
	testing.expect_value(t, scriptlet_canonical(a1[0]), "replace-xhr-response")
	testing.expect_value(t, a1[1], `/"adPlacements.*?([A-Z]"\}|"\}{2,4})\}\],/`)
	testing.expect_value(t, a1[2], "")
	testing.expect_value(t, a1[3], `/playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/`)
	body := `{"playabilityStatus":{"status":"OK"},"adPlacements":[{"adPlacementRenderer":{"config":{"adPlacementConfig":{"kind":"START"}},"renderer":{"x":"Y"}}}],"adSlots":[{"a":1}],"adBreakHeartbeatParams":"Q0FB","videoDetails":{"id":"v"}}`
	re := pattern_regex(a1[1], "g")
	defer jsre_destroy(re)
	out, n := jsre_replace(re, body, a1[2], 0, context.temp_allocator)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out, `{"playabilityStatus":{"status":"OK"},"adSlots":[{"a":1}],"adBreakHeartbeatParams":"Q0FB","videoDetails":{"id":"v"}}`)
	// the second rule: lazy, dot-all, multi-line, a capture put back
	a2 := split_args(`trusted-replace-xhr-response, /"adPlacements.*?("adSlots"|"adBreakHeartbeatParams")/gms, $1, /\/player(?:\?.+)?$/`)
	testing.expect_value(t, len(a2), 4)
	re2 := pattern_regex(a2[1], "g")
	defer jsre_destroy(re2)
	out2, n2 := jsre_replace(re2, strings.concatenate({"{\"adPlacements\":[\n{\"a\":1},\n{\"b\":2}],\n\"adSlots\":[]}"}, context.temp_allocator), a2[2], 0, context.temp_allocator)
	testing.expect_value(t, n2, 1)
	testing.expect_value(t, out2, `{"adSlots":[]}`)
	// the same over several kilobytes between the two names
	big := strings.concatenate({`{"adPlacements":[`, strings.repeat(`{"k":"vvvvvvvvvv"},`, 600), `{}],"adSlots":[]}`}, context.temp_allocator)
	out3, n3 := jsre_replace(re2, big, a2[2], 0, context.temp_allocator)
	testing.expect_value(t, n3, 1)
	testing.expect_value(t, out3, `{"adSlots":[]}`)
	// the fetch form, with quoted arguments and a bare URL pattern
	a3 := split_args(`trusted-rpfr, '"adPlacements"', '"no_ads"', player?`)
	testing.expect_value(t, scriptlet_canonical(a3[0]), "replace-fetch-response")
	testing.expect_value(t, a3[1], `"adPlacements"`)
	testing.expect_value(t, a3[2], `"no_ads"`)
	testing.expect_value(t, a3[3], "player?")
	// the filter option: `$replace=/"adPlacements"/"no_ads"/`
	f := replace_filter_make([]string{`/"adPlacements"/"no_ads"/`})
	got := run_filter(f, []string{`{"adPl`, `acements":[1],"x":2}`})
	testing.expect_value(t, got, `{"no_ads":[1],"x":2}`)
}
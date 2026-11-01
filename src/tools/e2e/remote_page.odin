package e2e_scenarios

// What a web page can do to the answers of `wren ctl eval` (remote_shell.odin, security review of 2026-10-25, finding 5). The answer of a script goes
// through the console.log of the page, which the page can replace: it sees the line, and can write one like it. So the line carries no secret, and an
// answer counts only if it comes from the tab the question was asked in, for an id that waits, the first time; the value is checked to be one JSON
// value on one line before it goes in a reply. This is about a client's channel: a Wren of its own, in another process, driven over it.
//   1. the line the page sees is the same in two runs (no per-run prefix to learn)
//   2. a page of another tab answers a question that waits in tab 1 with a forged value: tab 1 gets its own page's answer
//   3. a page that puts a line break and a second JSON object in the value of its own answer: an error, one line, and the client is not confused

import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") FIXTURE :: "/site/remote/fixture.htm"
// How many ids a forger tries: more than the questions of this test.
@(private = "file") FORGED_IDS :: "200"

// A page that keeps the prefix of the lines written to its console.log (`pre`).
@(private = "file") HOOK :: `(function () {
  var o = console.log; window.write = o; window.pre = "";
  console.log = function (s) {
    var str = String(s), r = o.apply(console, arguments);
    if (str.charCodeAt(0) === 1) window.pre = str.slice(0, str.indexOf("{"));
    return r;
  };
  return "hooked";
})()`
// A page that, told so on the channel "forge" by another tab, writes lines like the answers, for every id, then says it has.
@(private = "file") FORGER :: `(function () {
  window.forged = 0;
  var c = new BroadcastChannel("forge");
  c.onmessage = function (e) {
    if (e.data !== "go") return;
    for (var i = 1; i <= ` + FORGED_IDS + `; i++) { write.call(console, pre + JSON.stringify({id: i, ok: 1, t: "string", v: JSON.stringify("FORGED")})); forged++; }
    c.postMessage("forged");
  };
  return "forging";
})()`
// The question that waits in tab 1: it asks tab 2 to forge its answer, and answers once tab 2 has written all of it.
@(private = "file") WAITING_QUESTION :: `new Promise(function (ok) { var c = new BroadcastChannel("forge"); c.onmessage = function (e) { if (e.data === "forged") ok("REAL"); }; c.postMessage("go"); })`
// Writes, before the genuine answer of each question, an answer of its own for that id with the value window.own2.
@(private = "file") OWN_ANSWER_FIRST :: `(function(){var o=console.log;console.log=function(s){var str=String(s);if(str.charCodeAt(0)===1&&window.own2){var k=str.indexOf("{"),pre=str.slice(0,k),id=JSON.parse(str.slice(k)).id;o.call(console,pre+JSON.stringify({id:id,ok:1,t:"string",v:window.own2}))}return o.apply(console,arguments)}})(); 0`
@(private = "file") LINE_BREAK_VALUE :: `window.own2 = "1\n{\"id\":999,\"result\":{\"x\":1}}"; 0`
@(private = "file") NOT_JSON :: "not a JSON value"
@(private = "file") SMUGGLED :: "999"

@(private = "file")
js :: proc(s: ^api.Session, expression: string, await := false) -> string {
	v, _ := api.eval(s, expression, await = await)
	return v
}

// A Wren on the page, hooked: the prefix its page sees.
@(private = "file")
hooked_wren :: proc(t: ^testing.T, page: string) -> (^e2e.Wren_Process, string) {
	p := e2e.launch(t)
	api.navigate(p.s, page)
	js(p.s, HOOK)
	js(p.s, "1+1")
	return p, js(p.s, "window.pre")
}

@(test)
what_a_page_does_to_the_answers :: proc(t: ^testing.T) {
	page := e2e.url(e2e.test_server(t), FIXTURE)

	first, seen_first := hooked_wren(t, page)
	e2e.quit(first)
	p, seen := hooked_wren(t, page)
	testing.expectf(t, seen != "" && seen == seen_first, "the page sees the same prefix in two runs (nothing per run to learn): %q, %q", seen_first, seen)

	// a page of tab 2 forges the answer of a question that waits in tab 1
	targets, _ := api.targets(p.s)
	tab1 := targets.tabs[0].id
	tab2, _ := api.new_tab(p.s, page, wait = .Load)
	p.s.tab = tab2
	js(p.s, HOOK)
	js(p.s, "1+1")
	js(p.s, FORGER)
	p.s.tab = tab1
	answer := js(p.s, WAITING_QUESTION, await = true)
	testing.expectf(t, answer == "REAL", "tab 1's question gets the answer of its own page, not tab 2's forgery: got %q", answer)
	p.s.tab = tab2
	testing.expect_value(t, js(p.s, "String(window.forged)"), FORGED_IDS)

	// a value with a line break and a second object, written by the page, before the genuine answer, as the answer to its own question
	p.s.tab = tab1
	js(p.s, OWN_ANSWER_FIRST)
	stop := p.s.on_failure
	p.s.on_failure = nil
	js(p.s, LINE_BREAK_VALUE)   // (its own answer is the first to be forged)
	reply, err := api.eval(p.s, "3+3")
	why := api.last_failure().message
	p.s.on_failure = stop
	testing.expectf(t, err != .None && reply == "", "a forged value with a line break is an error: %v, got %q", err, reply)
	testing.expectf(t, strings.contains(why, NOT_JSON) && !strings.contains(why, "\n") && !strings.contains(why, SMUGGLED), "... on one line, nothing of the forged object: %q", why)
	js(p.s, "window.own2 = null; 0")
	testing.expect_value(t, js(p.s, "4+4"), "8")
}

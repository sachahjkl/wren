#+build windows
#+private file
// Nested documents (src/page/frames.odin, frames_scripts.odin; native/js/runtime/frames.c, prelude/frames.js): <iframe> creation and
// destruction, about:blank / srcdoc / fetched documents, load events and the parent's load, window.frames / length / parent / top / name,
// postMessage across origins (targetOrigin, origin, source), what a cross-origin window refuses, sandbox (scripts, opaque origin),
// X-Frame-Options, frame-ancestors, the parent's frame-src, navigation by src, by the frame itself and by window.open to a frame name, the
// Permissions Policy's allow attribute, storage partitioning. A top page says what it saw with log() (wrenTest.note); its frames, which
// have no wrenTest, tell it with postMessage.
package e2e_scenarios

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:page"
import "wb:style"
import "wb:tools/testenv"

SAME  :: "http://127.0.0.1:8765"   // the parent's origin
OTHER :: "http://127.0.0.1:8767"   // another origin of the same site
SITE2 :: "http://localhost:8765"   // another site
LOG :: `<script>function log(s) { wrenTest.note(String(s)) }</script>`
// A self-post goes behind every message posted to the page before it: what a frame was going to say, it has said by then.
SETTLE :: `addEventListener("message", e => { if (e.data === "settled") log("settled"); }); postMessage("settled", "*");`
JOURNAL_BYTES :: 4096
FRAME_TIME :: 1000
STYLE_W :: 800
STYLE_H :: 600
STYLE_SCALE :: 1.5
FONT_SIZE_IN_FRAME :: 23
COLOR_MAX :: 255
MEASURED_FRAMES :: 20

// What the page said with log(), exactly / a part of it, and where (-1: not).
said :: proc(pr: ^Probe, text: string) -> bool { return said_at(pr, text) >= 0 }

said_part :: proc(pr: ^Probe, part: string) -> bool {
	for n in pr.section.notes { if strings.contains(n, part) { return true } }
	return false
}

said_at :: proc(pr: ^Probe, text: string) -> int {
	for n, i in pr.section.notes { if n == text { return i } }
	return -1
}

// The page's console: what the browser tells the author there is the feature some tests are about.
console_says :: proc(pr: ^Probe, part: string) -> bool {
	for l in pr.lines { if strings.contains(l, part) { return true } }
	return false
}

// A document served by the test server: `body` as HTML, `headers` as "Name: value".
doc :: proc(origin: string, body: string, headers: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, testenv.url(strings.concatenate({origin, "/frames/doc?body="}, context.temp_allocator)))
	strings.write_string(&sb, enc(body))
	for h in headers {
	strings.write_string(&sb, "&h=")
	strings.write_string(&sb, enc(h))
	}
	return strings.to_string(sb)
}

load :: proc(t: ^testing.T, source: string, address := SAME + "/frames/doc", csp := "") -> ^Probe {
	pr := page_make(t, "frames", testenv.url(address))
	if csp != "" { page.apply_response_headers(pr.p, {csp}, {}, "") }
	page_load(pr, strings.concatenate({LOG, source}, context.temp_allocator))
	return pr
}

// The styles of a document, computed as a frame of the shell computes them.
frame_styles :: proc(c: ^page.Page) -> ^style.Styled {
	page.set_layout_journal(c, JOURNAL_BYTES)
	page.set_frame_time(c, FRAME_TIME)
	st := page.styles(c, STYLE_W, STYLE_H, STYLE_SCALE)
	page.set_frame_time(c, 0, unpin = true)
	return st
}

// A computed color as CSS writes it.
rgb_of :: proc(cs: ^style.Computed) -> [3]int {
	return {int(math.round(cs.color[0] * COLOR_MAX)), int(math.round(cs.color[1] * COLOR_MAX)), int(math.round(cs.color[2] * COLOR_MAX))}
}

// The child page of the first frame element of `p` (nil: none).
child_of :: proc(p: ^page.Page, index := 0) -> ^page.Page {
	kids := page.frames_children(p)
	if index >= len(kids) { return nil }
	return kids[index].page
}

// Replaces each %s of `t` by the next argument (fmt would read the braces of JavaScript as its own).
fill :: proc(t: string, args: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	rest := t
	k := 0
	for {
	i := strings.index(rest, "%s")
	if i < 0 || k >= len(args) { strings.write_string(&sb, rest); break }
	strings.write_string(&sb, rest[:i])
	strings.write_string(&sb, args[k])
	k += 1
	rest = rest[i + 2:]
	}
	return strings.to_string(sb)
}

// the DOM of a same-origin frame: contentDocument, contentWindow.document, parent.document
@(test)
frames_same_origin_dom :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><div id=top-marker>t</div><iframe id=b></iframe><script>
const f = document.getElementById("b");
const d = f.contentDocument;
log("doc " + d.nodeType + " " + (d === f.contentDocument) + " " + (d === f.contentWindow.document) + " " + (d === frames[0].document) + " " + (d !== document));
log("parts " + d.documentElement.tagName + " " + d.body.tagName + " " + (d.body === d.body) + " " + (d.body.ownerDocument === d) + " " + (d.defaultView === f.contentWindow));
d.body.innerHTML = '<p id=x class="c d">hello <b>there</b></p>';
const x = d.getElementById("x");
log("read " + x.textContent + " " + (d.querySelector("#x") === x) + " " + d.querySelectorAll("b").length + " " + (x.parentNode === d.body) + " " + x.classList.contains("d") + " " + d.getElementsByTagName("b").length);
log("separate " + (document.getElementById("x") === null) + " " + (document.getElementById("top-marker") !== null) + " " + (d.getElementById("top-marker") === null));
const made = d.createElement("span");
made.textContent = "made";
made.setAttribute("data-a", "1");
d.body.appendChild(made);
const text = d.createTextNode("!");
made.appendChild(text);
log("made " + (made.ownerDocument === d) + " " + d.body.lastChild.textContent + " " + d.body.children.length + " " + made.getAttribute("data-a") + " " + (made instanceof HTMLElement));
made.style.color = "rgb(1, 2, 3)";
log("style " + d.defaultView.frameElement + " " + made.style.color);
made.foo = 42;
log("expando " + d.querySelector("span").foo);
const own = document.createElement("div");
own.id = "moved"; own.innerHTML = "<i>inside</i>";
const inner = own.firstChild;
d.body.appendChild(own);
log("adopt " + (own.ownerDocument === d) + " " + (own.parentNode === d.body) + " " + (d.getElementById("moved") === own) + " " + (own.firstChild === inner) + " " + (document.getElementById("moved") === null) + " " + own.textContent);
own.classList.add("after");
log("after adopt " + own.className);
document.body.appendChild(d.getElementById("x"));
const back = document.getElementById("x");
log("back " + (back.ownerDocument === document) + " " + (d.getElementById("x") === null) + " " + back.textContent);
const toAdopt = document.createElement("u");
log("adoptNode " + (d.adoptNode(toAdopt) === toAdopt) + " " + (toAdopt.ownerDocument === d));
const toImport = document.createElement("s");
toImport.innerHTML = "<q>x</q>";
const imported = d.importNode(toImport, true);
log("importNode " + (imported !== toImport) + " " + (imported.ownerDocument === d) + " " + (toImport.ownerDocument === document) + " " + imported.firstChild.tagName);
try { document.body.removeChild(d.body); log("no throw"); } catch (e) { log("removeChild across documents " + e.name); }
try { made.matches(); log("no throw"); } catch (e) { log("arity " + (e instanceof f.contentWindow.TypeError) + " " + (e instanceof TypeError)); }
d.title = "frame title";
log("title " + d.title + " | " + document.title + " | " + d.readyState + " " + d.URL + " " + d.compatMode);
const goes = document.createElement("script");
goes.src = "data:text/javascript,log('moved script ran')";
goes.async = false;
document.body.appendChild(goes);
d.body.appendChild(goes);
const stays = document.createElement("script");
stays.src = "data:text/javascript,log('script after it ran')";
stays.async = false;
document.body.appendChild(stays);
</script></body>`)
	check(pr, wait_note(pr, "doc 9 true true true true"), "contentDocument, contentWindow.document and frames[0].document are one object in the caller's realm")
	check(pr, said(pr, "parts HTML BODY true true true"), "it is a real document: its elements, their identity, ownerDocument and defaultView")
	check(pr, said(pr, "read hello there true 1 true true 1"), "innerHTML writes in the frame's document; getElementById, querySelector, collections and classList read it")
	check(pr, said(pr, "separate true true true"), "the two documents stay two")
	check(pr, said(pr, "made true made! 2 1 true"), "createElement, createTextNode, appendChild, setAttribute on the frame's document")
	check(pr, said(pr, `style [object HTMLIFrameElement] rgb(1, 2, 3)`), "element.style of a node of the frame; frameElement through defaultView")
	check(pr, said(pr, "expando 42"), "the same element gives the same wrapper: properties set on it are there")
	check(pr, said(pr, "adopt true true true true true inside"), "appendChild of a parent's node moves it: its wrapper and its children's follow")
	check(pr, said(pr, "after adopt after"), "the objects a moved wrapper keeps (classList) follow")
	check(pr, said(pr, "back true true hello there"), "and back from the frame to the parent")
	check(pr, said(pr, "adoptNode true true"), "document.adoptNode of a frame takes a parent's node")
	check(pr, said(pr, "importNode true true true Q"), "document.importNode of a frame makes a copy there")
	check(pr, said(pr, "removeChild across documents NotFoundError"), "a node of another document is not a child")
	check(pr, said(pr, "arity true false"), "a method of a node of the frame given too few arguments throws the frame's TypeError")
	check(pr, said_part(pr, "title frame title |  | "), "document.title of the frame, not of the parent")
	check(pr, wait_note(pr, "script after it ran") && !said(pr, "moved script ran"), "a script moved to another document after it was prepared does not run (the one after it does)")
	c := child_of(pr.p)
	check(pr, c != nil && strings.contains(page.serialize_html(c.doc, c.body, false), `<span data-a="1"`), "what was written is in the frame's own DOM (seen from the browser's side)")
	// the frame's own styles and layout follow what the parent wrote
	if c != nil {
		st := frame_styles(c)
		span, _ := page.query_first(c, "span")
		cs := style.style_of(st, span)
		check(pr, cs != nil && rgb_of(cs) == {1, 2, 3}, "the frame's styles compute after a write from the parent")
	}
	close_page(pr, min_checks = 17)
}

// from the frame: parent.document, top.document, frameElement; a frame of a frame
@(test)
frames_reached_from_inside :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	inner := `<script>
const log = s => top.postMessage(String(s), "*");
const pd = parent.document;
log("inner parent " + pd.getElementById("mid-mark").textContent + " top " + top.document.getElementById("top-mark").textContent + " " + (frameElement.ownerDocument === pd) + " " + (parent.document === pd));
top.document.getElementById("top-mark").textContent = "changed by inner";
log("inner wrote " + top.document.getElementById("top-mark").textContent);
</script>`
	pr := load(t, fill(`<body><div id=top-mark>top</div><iframe id=m src="%s"></iframe><script>
addEventListener("message", e => log(e.data));
const m = document.getElementById("m");
m.addEventListener("load", () => {
  const mid = m.contentDocument;
  const nested = mid.querySelector("iframe");
  log("nested " + nested.tagName + " " + (nested.contentDocument.defaultView === nested.contentWindow) + " " + nested.contentDocument.body.childElementCount + " " + m.contentWindow.frames.length + " " + (m.contentWindow.frames[0].document === nested.contentDocument));
  log("top mark " + document.getElementById("top-mark").textContent);
});
</script></body>`, doc(SAME, fill(`<div id=mid-mark>middle</div><iframe srcdoc="%s"></iframe>`, html_attr(inner)))))
	check(pr, wait_note(pr, "inner parent middle top top true true"), "a nested frame reads parent.document and top.document")
	check(pr, wait_note(pr, "inner wrote changed by inner"), "and writes there")
	check(pr, wait_note(pr, "nested IFRAME true 0 1 true") && wait_note(pr, "top mark changed by inner"), "the top document reaches a frame of its frame; the write shows in the top's own wrappers")
	close_page(pr, min_checks = 3)
}

// a frame with an address of its own, srcdoc, and a frame's own script next to the parent's
@(test)
frames_address_and_srcdoc_documents :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	child := doc(SAME, `<p id=mine>from server</p><script>window.childValue = 1; document.getElementById("mine").dataset.seen = "own script"; </script>`)
	pr := load(t, fill(`<body><iframe id=a src="%s"></iframe><iframe id=s srcdoc="<p id=q>from srcdoc</p>"></iframe><script>
addEventListener("load", () => {
  const a = document.getElementById("a").contentDocument, s = document.getElementById("s").contentDocument;
  log("fetched " + a.getElementById("mine").textContent + " " + a.getElementById("mine").dataset.seen + " " + a.URL.includes("/frames/doc"));
  log("srcdoc " + s.getElementById("q").textContent + " " + s.URL);
  log("window load");
});
</script></body>`, child))
	check(pr, wait_note(pr, "window load"), "loaded")
	check(pr, said(pr, "fetched from server own script true"), "a same-origin frame with an address: contentDocument is its real document (its own script wrote there)")
	check(pr, said(pr, "srcdoc from srcdoc about:srcdoc"), "a srcdoc frame: contentDocument is its real document")
	close_page(pr, min_checks = 3)
}

// The encoding of a frame's document: one that declares none takes its same-origin parent's (not the default
// windows-1252), a text document its response's charset.
@(test)
frames_encoding_of_nested_documents :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	undeclared := strings.concatenate({doc(SAME, "<p id=e>é</p>"), "&type=", enc("text/html")}, context.temp_allocator)
	text := strings.concatenate({testenv.url(SAME + "/frames/text?body="), enc("é"), "&type=", enc("text/plain; charset=windows-1251")}, context.temp_allocator)
	xml := strings.concatenate({testenv.url(SAME + "/frames/text?body="), enc("<Foo>é</Foo>"), "&type=", enc("application/xml")}, context.temp_allocator)
	pr := load(t, fill(`<body><iframe id=h src="%s"></iframe><iframe id=t src="%s"></iframe><iframe id=x src="%s"></iframe><script>
addEventListener("load", () => {
  const h = document.getElementById("h").contentDocument, x = document.getElementById("t").contentDocument;
  log("undeclared " + h.characterSet + " " + h.getElementById("e").textContent);
  log("text " + x.characterSet + " " + x.body.textContent);
  const m = document.getElementById("x").contentDocument;
  log("xml " + m.contentType + " " + m.characterSet + " " + m.documentElement.tagName + " " + m.documentElement.textContent + " " + m.createElement("Bar").tagName);
});
</script></body>`, undeclared, text, xml))
	check(pr, wait_note(pr, "undeclared UTF-8 é"), "a frame's document without a declaration is in its same-origin parent's encoding")
	check(pr, said(pr, "text windows-1251 Г©"), "a text document is decoded in its response's charset")
	check(pr, said(pr, "xml application/xml UTF-8 Foo é Bar"), "an XML document is parsed as XML, in UTF-8 without a declaration")
	close_page(pr, min_checks = 3)
}

// Two forms submitted at once to two frames: each frame goes where its form sends it (a planned navigation per target)
@(test)
frames_forms_submitted_to_two_frames_at_once :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	action := testenv.url(SAME + "/frames/text")
	pr := load(t, fill(`<body><iframe name=a></iframe><iframe name=b></iframe>
<form id=fa target=a action="%s"><input name=q value=one></form><form id=fb target=b action="%s"><input name=q value=two></form><script>
addEventListener("load", () => {
  const seen = [];
  for (const name of ["a", "b"]) {
    document.querySelector("iframe[name=" + name + "]").onload = (e) => {
      seen.push(name + e.target.contentWindow.location.search);
      if (seen.length === 2) log("loaded " + seen.sort().join(" "));
    };
  }
  document.getElementById("fa").submit();
  document.getElementById("fb").submit();
});
</script></body>`, action, action))
	check(pr, wait_note(pr, "loaded a?q=one b?q=two"), "both frames navigated, each with its form's data")
	close_page(pr, min_checks = 1)
}

// a frame gone, or navigated: its wrappers do no harm
@(test)
frames_wrappers_of_a_frame_gone :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=a></iframe><script>
const a = document.getElementById("a");
const d = a.contentDocument, b = d.body;
b.innerHTML = "<p>x</p>";
const para = b.firstChild;
a.remove();
log("removed " + a.contentDocument + " " + a.contentWindow);
const out = [];
for (const [name, f] of [["tag", () => para.tagName], ["text", () => para.textContent], ["set", () => { para.textContent = "y"; return "ok"; }],
    ["create", () => d.createElement("p")], ["query", () => d.querySelector("p")], ["append", () => { b.appendChild(document.createElement("p")); return "ok"; }], ["own", () => document.body.appendChild(para)]]) {
  try { out.push(name + ":" + f()); } catch (e) { out.push(name + ":" + e.name); }
}
log("harmless " + out.length);
log("still here " + document.body.tagName);
</script></body>`)
	check(pr, wait_note(pr, "still here BODY"), "using the wrappers of a removed frame's document neither crashes nor reaches anything")
	check(pr, said(pr, "removed null null"), "the element has no document any more")
	check(pr, said(pr, "harmless 7"), "each use of them returned or threw")
	close_page(pr, min_checks = 3)
}

// a frame's realm torn down while a call is in it
@(test)
frames_realm_torn_down_during_a_call :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=a></iframe><script>
addEventListener("message", e => log(e.data));
const a = document.getElementById("a");
a.srcdoc = "<script>const me = frameElement, up = parent; up.postMessage('before', '*'); try { me.remove(); document.documentElement.setAttribute('data-x', 'still runs'); up.postMessage('after ' + document.documentElement.getAttribute('data-x'), '*'); } catch (e) { up.postMessage('threw ' + e, '*'); }<\/script>";
window.tick = 0;
</script></body>`)
	check(pr, wait_note(pr, "before") && wait_note(pr, "after still runs"), "a frame's script removes its own frame through parent's DOM and goes on running")
	run(pr, `log("parent after " + (document.getElementById("a") === null) + " " + frames.length);`)
	check(pr, wait_note(pr, "parent after true 0"), "the frame left at once; the parent goes on")
	close_page(pr, min_checks = 2)

	// a nested frame closes its parent: the page in use is closed only after the call
	pr = load(t, fill(`<body><iframe id=m srcdoc="%s"></iframe><script>addEventListener("message", e => log(e.data));</script></body>`, html_attr(`<iframe srcdoc="<script>const t = top; t.document.getElementById('m').remove(); t.postMessage('inner survived', '*');</script>"></iframe>`)))
	check(pr, wait_note(pr, "inner survived"), "a frame's script removes the frame around it")
	close_page(pr, min_checks = 1)

	// the browser dispatches an event at a frame's node (an image's error), a parent's listener removes the frame: the
	// frame's document is closed once the dispatch is over, not under it
	pr = load(t, `<body><iframe id=f srcdoc="<p>x</p>"></iframe><script>
const f = document.getElementById("f");
f.onload = () => {
  const img = f.contentDocument.createElement("img");
  img.addEventListener("error", () => { f.remove(); log("removed in its event"); });
  img.src = "data:image/png;base64,AAAA";
  f.contentDocument.body.append(img);
};
</script></body>`)
	check(pr, wait_note(pr, "removed in its event"), "a parent's listener removes the frame during an event of its document")
	run(pr, `log("parent goes on " + frames.length);`)
	check(pr, wait_note(pr, "parent goes on 0"), "the parent goes on")
	close_page(pr, min_checks = 2)
}

// events: listeners of both realms on one node
@(test)
frames_events_of_both_realms :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f srcdoc="<button id=b>go</button><script>
window.order = [];
const b = document.getElementById('b');
b.addEventListener('click', e => { order.push('frame ' + e.type + ' ' + (e.target === b) + ' ' + (this === window)); parent.postMessage('frame heard ' + e.type + ' ' + e.isTrusted + ' ' + (e.target === b), '*'); });
parent.postMessage('ready', '*');
</script>"></iframe><script>
addEventListener("message", e => {
  log(e.data);
  if (e.data !== "ready") return;
  const d = document.getElementById("f").contentDocument;
  const b = d.getElementById("b");
  let parentHeard = [];
  const fn = e => { parentHeard.push(e.type + " " + (e.target === b) + " " + (e.currentTarget === b) + " " + (e instanceof Event)); };
  b.addEventListener("click", fn);
  b.click();
  log("parent heard " + parentHeard.join());
  b.dispatchEvent(new Event("custom"));
  b.addEventListener("custom", e => { parentHeard.push("custom " + e.bubbles); e.preventDefault(); });
  const ev = new Event("custom", {bubbles: true, cancelable: true});
  const notCanceled = b.dispatchEvent(ev);
  log("own event " + parentHeard[parentHeard.length - 1] + " " + notCanceled + " " + ev.defaultPrevented + " " + (ev.target === b));
  b.removeEventListener("click", fn);
  parentHeard = [];
  b.click();
  log("removed " + parentHeard.length);
  let viaAttr = 0;
  b.onclick = () => { viaAttr++; };
  b.click();
  log("on attribute " + viaAttr + " " + (typeof b.onclick));
  d.body.addEventListener("click", e => { log("bubbled to frame body " + (e.target === b)); e.stopPropagation(); });
  d.addEventListener("click", () => log("must not run"));
  b.click();
});
</script></body>`)
	check(pr, wait_note(pr, "ready"), "the frame is ready")
	check(pr, wait_note(pr, "parent heard click true true true"), "a parent's listener on a node of the frame is called, with its own wrappers")
	check(pr, wait_note(pr, "frame heard click true true"), "the frame's own listener is called too, with its wrappers")
	check(pr, wait_note(pr, "own event custom true false true true"), "an Event of the parent dispatched on a frame's node: preventDefault counts, target is the node")
	check(pr, wait_note(pr, "removed 0"), "removeEventListener from the parent")
	check(pr, wait_note(pr, "on attribute 1 function"), "an event handler attribute set from the parent")
	check(pr, wait_note(pr, "bubbled to frame body true"), "propagation goes through the frame's tree")
	check(pr, !said(pr, "must not run"), "stopPropagation from the parent's listener stops it")
	close_page(pr, min_checks = 8)
}

// a parent's observers and ranges on a frame's nodes
@(test)
frames_observers_and_ranges_across_documents :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f></iframe><script>
const d = document.getElementById("f").contentDocument, w = document.getElementById("f").contentWindow;
d.body.innerHTML = "<p id=a>one two three</p>";
const seen = [];
const mo = new MutationObserver(list => { for (const r of list) seen.push(r.type + " " + r.target.nodeName + " " + (r.target === d.body)); log("observed " + seen.join()); });
mo.observe(d.body, {childList: true});
const own = new MutationObserver(() => log("own document observed"));
own.observe(document.body, {attributes: true});
d.body.appendChild(d.createElement("div"));
document.body.setAttribute("data-x", "1");
const r = d.createRange();
const text = d.getElementById("a").firstChild;
r.setStart(text, 4); r.setEnd(text, 7);
log("range " + r.toString() + " " + (r.startContainer === text) + " " + (r.commonAncestorContainer === text));
const sel = w.getSelection();
sel.removeAllRanges();
sel.addRange(r);
log("selection " + sel.toString() + " " + sel.rangeCount + " " + (sel.anchorNode === text) + " " + (d.getSelection() === sel));
const b = d.createElement("b");
r.surroundContents(b);
log("surround " + d.getElementById("a").innerHTML);
const r2 = d.createRange();
r2.selectNodeContents(d.getElementById("a"));
r2.insertNode(document.createTextNode("made in the parent "));
log("insert " + d.getElementById("a").textContent);
log("own selection " + (window.getSelection().rangeCount));
</script></body>`)
	check(pr, wait_note(pr, "observed childList BODY true"), "a parent's MutationObserver sees a frame's mutations, with its own wrappers")
	check(pr, wait_note(pr, "own document observed"), "the same realm's observer of its own document still works")
	check(pr, wait_note(pr, "range two true true"), "createRange of a frame's document")
	check(pr, wait_note(pr, "selection two 1 true true"), "the frame's Selection takes that range; document.getSelection is the same object")
	check(pr, wait_note(pr, "surround one <b>two</b> three"), "surroundContents with an element of the frame")
	check(pr, wait_note(pr, "insert made in the parent one two three"), "insertNode with a node of the parent moves it")
	check(pr, wait_note(pr, "own selection 0"), "the parent's selection is its own")
	close_page(pr, min_checks = 7)
}

// custom elements and frames
@(test)
frames_custom_elements :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f srcdoc="<script>customElements.define('in-frame', class extends HTMLElement { connectedCallback() { parent.postMessage('frame element connected ' + (this.ownerDocument === document), '*'); } });</script>"></iframe><script>
addEventListener("message", e => log(e.data));
const seen = [];
customElements.define("my-el", class extends HTMLElement {
  connectedCallback() { seen.push("connected " + (this.ownerDocument === document ? "here" : "there")); }
  disconnectedCallback() { seen.push("disconnected"); }
  adoptedCallback(a, b) { seen.push("adopted " + (a === document) + " " + (b === document)); }
  attributeChangedCallback(n, o, v) { seen.push("attribute " + n + " " + v); }
  static get observedAttributes() { return ["a"]; }
  hello() { return "hello from my class"; }
});
addEventListener("load", () => {
  const d = document.getElementById("f").contentDocument;
  const el = document.createElement("my-el");
  document.body.appendChild(el);
  d.body.appendChild(el);
  log("after move " + seen.join(", "));
  seen.length = 0;
  el.setAttribute("a", "1");
  log("attribute there " + seen.join(", ") + " " + el.hello() + " " + (el.ownerDocument === d));
  seen.length = 0;
  el.remove();
  log("removed there " + seen.join(", "));
  seen.length = 0;
  d.body.appendChild(el);
  document.body.appendChild(el);
  log("home " + seen.join(", ") + " " + (el.ownerDocument === document));
  d.body.appendChild(d.createElement("in-frame"));
  try { document.getElementById("f").contentWindow.customElements.define("no good", class extends HTMLElement {}); log("no throw"); }
  catch (e) { log("define threw " + e.name + " " + (e instanceof DOMException)); }
  const fw = document.getElementById("f").contentWindow;
  try { fw.eval("null.x"); } catch (e) { log("eval threw " + (e instanceof TypeError) + " " + (e instanceof fw.TypeError) + " " + (e.constructor === fw.TypeError) + " " + e.name); }
});
</script></body>`)
	check(pr, wait_note(pr, "after move connected here, disconnected, adopted true false, connected there"), "a custom element moved to a frame keeps its class: disconnected, adopted, connected, in order")
	check(pr, wait_note(pr, "attribute there attribute a 1 hello from my class true"), "its reactions and methods are still its realm's")
	check(pr, wait_note(pr, "removed there disconnected"), "removal from the frame's document")
	check(pr, wait_note(pr, "home connected there, disconnected, adopted false true, connected here true"), "and back home, where it has no foreign owner")
	check(pr, wait_note(pr, "frame element connected true"), "an element of the frame's registry made from the parent reacts in the frame")
	check(pr, wait_note(pr, "define threw SyntaxError true"), "a DOMException of the frame is one of this realm to its catcher")
	check(pr, wait_note(pr, "eval threw false true true TypeError"), "a TypeError of the frame is the frame's, not this realm's")
	close_page(pr, min_checks = 7)
}

// scripts inserted in a frame run in its realm
@(test)
frames_scripts_inserted_in_a_frame :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, fill(`<body><iframe id=f></iframe><script>
window.who = "parent realm";
addEventListener("message", e => log(e.data));
const f = document.getElementById("f");
const d = f.contentDocument;
const s = d.createElement("script");
s.textContent = "window.who = 'frame realm'; parent.postMessage('inline ran: ' + who + ' ' + (document.currentScript !== null) + ' ' + (document !== parent.document) + ' ' + (window !== parent), '*');";
d.head.appendChild(s);
log("after insert " + who);
const moved = document.createElement("script");
moved.textContent = "parent.postMessage('moved script ran in ' + who, '*');";
d.body.appendChild(moved);
const ext = d.createElement("script");
ext.src = "%s";
ext.onload = () => log("external loaded");
d.body.appendChild(ext);
d.body.innerHTML += "<p id=h onclick=\"parent.postMessage('attribute handler in ' + who, '*')\">x</p>";
d.getElementById("h").click();
const tm = d.createElement("script");
tm.textContent = "setTimeout(() => parent.postMessage('timer of the frame in ' + who, '*'), 0); Promise.resolve().then(() => parent.postMessage('microtask of the frame', '*'));";
d.body.appendChild(tm);
log("still sync");
</script></body>`, testenv.url(SAME + "/jsload/gen?ms=0&code=parent.postMessage('external%20ran%20in%20'%20%2B%20who%2C%20'*')")))
	check(pr, wait_note(pr, "inline ran: frame realm true true true"), "a script created through contentDocument runs at once, in the frame's realm")
	check(pr, wait_note(pr, "after insert parent realm"), "the parent's global is untouched")
	check(pr, wait_note(pr, "moved script ran in frame realm"), "a script made in the parent and moved to the frame runs in the frame's realm")
	check(pr, wait_note(pr, "external ran in frame realm") && wait_note(pr, "external loaded"), "an external script loads in the frame, with its load event seen by the parent")
	check(pr, wait_note(pr, "attribute handler in frame realm"), "an onclick attribute written from the parent is compiled in the frame's realm")
	check(pr, wait_note(pr, "timer of the frame in frame realm") && wait_note(pr, "microtask of the frame"), "timers and microtasks of an inserted script are the frame's")
	close_page(pr, min_checks = 6)
}

// recursion across realms ends without a crash
@(test)
frames_recursion_across_realms :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f srcdoc="<script>window.down = n => parent.up(n + 1);</script>"></iframe><script>
window.deepest = 0;
window.up = n => { deepest = n; return document.getElementById("f").contentWindow.down(n + 1); };
addEventListener("load", () => {
  try { up(0); } catch (e) { log("recursion stopped " + (deepest > 2)); }
  log("still alive " + document.body.tagName);
});
</script></body>`)
	check(pr, wait_note(pr, "still alive BODY"), "unbounded recursion through two realms is stopped; the page survives")
	close_page(pr, min_checks = 1)
}

// document.open, write and close of a frame
@(test)
frames_document_write :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f></iframe><script>
addEventListener("message", e => log(e.data));
const f = document.getElementById("f");
let loads = 0;
f.addEventListener("load", () => log("frame load " + (++loads)));
const d = f.contentDocument;
const same = d.open();
log("open " + (same === d));
d.write("<!doctype html><html><head><title>written</title></head><body><p id=w>written</p>");
d.write("<script>parent.postMessage('written script ran ' + document.getElementById('w').textContent, '*');</" + "script>");
d.writeln("<p id=second>second</p></body></html>");
d.close();
log("read " + d.title + " " + d.getElementById("w").textContent + " " + d.getElementById("second").textContent + " " + (document.getElementById("w") === null) + " " + (d.body.tagName));
log("mode " + d.compatMode);
</script></body>`)
	check(pr, wait_note(pr, "open true"), "document.open of a frame gives that document")
	check(pr, wait_note(pr, "written script ran written"), "a written script runs in the frame's realm, with what was written before it")
	check(pr, wait_note(pr, "read written written second true BODY"), "what was written is the frame's document, and not the parent's")
	check(pr, wait_note(pr, "mode CSS1Compat"), "its doctype counts")
	close_page(pr, min_checks = 4)

	pr = load(t, `<body><iframe id=f></iframe><script>
const f = document.getElementById("f");
const d1 = f.contentWindow.document;
d1.write("<body>one</body>");
d1.close();
log("first " + f.contentDocument.body.textContent);
f.contentDocument.write("<body>two</body>");
f.contentDocument.close();
log("second " + f.contentDocument.body.textContent);
</script></body>`)
	check(pr, wait_note(pr, "first one") && wait_note(pr, "second two"), "write without open opens it; a second one replaces what is there")
	close_page(pr, min_checks = 1)
}

// values across realms: primitives, objects, functions
@(test)
frames_values_across_realms :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f srcdoc="<p id=fp>in frame</p><script>
window.n = 42; window.s = 'text'; window.big = 12345678901234567890n; window.nul = null;
window.obj = {a: 1, nested: {b: [1, 2, 3]}, method(x) { return this.a + x; }};
window.fn = (a, b) => a + b;
window.thrower = () => { throw new RangeError('from frame'); };
window.Klass = class Klass { constructor(v) { this.v = v; } get double() { return this.v * 2; } static make() { return new Klass(7); } };
window.takesCallback = cb => cb(20) + 1;
window.getNode = () => document.getElementById('fp');
window.takesNode = n => n.nodeName + ' ' + (n.ownerDocument === parent.document);
window.identity = x => x;
window.me = window;
parent.fromFrame();
</script>"></iframe><script>
window.parentValue = "from parent";
window.parentFn = x => x * 2;
window.parentObj = {list: [1, 2]};
window.fromFrame = () => { log("called by frame"); };
addEventListener("load", () => {
  const f = document.getElementById("f"), w = f.contentWindow;
  log("primitives " + w.n + " " + w.s + " " + w.big + " " + w.nul + " " + w.missing);
  log("object " + w.obj.a + " " + w.obj.nested.b.length + " " + w.obj.nested.b[1] + " " + w.obj.method(2) + " " + (w.obj === w.obj) + " " + (w.obj.nested === w.obj.nested));
  log("keys " + Object.keys(w.obj).join() + " " + ("a" in w.obj) + " " + ("zz" in w.obj) + " " + Array.isArray(w.obj.nested.b) + " " + JSON.stringify(w.obj.nested));
  log("function " + typeof w.fn + " " + w.fn(1, 2) + " " + w.takesCallback(x => x * 2));
  try { w.thrower(); log("no throw"); } catch (e) { log("thrown " + e.name + " " + e.message); }
  const k = new w.Klass(4);
  log("class " + k.v + " " + k.double + " " + (k instanceof w.Klass) + " " + w.Klass.make().v);
  w.obj.written = "by parent";
  log("write " + w.obj.written);
  w.fresh = 5;
  log("set global " + w.fresh + " " + ("fresh" in w) + " " + delete w.fresh + " " + w.fresh);
  const fromFrame = w.getNode();
  log("node " + fromFrame.textContent + " " + (fromFrame === f.contentDocument.getElementById("fp")) + " " + (fromFrame instanceof HTMLElement));
  log("node to frame " + w.takesNode(document.body));
  const mine = {};
  log("identity " + (w.identity(mine) === mine) + " " + (w.identity(w.obj) === w.obj) + " " + (w.me === w) + " " + (w.identity(window) === window));
  log("window members " + w.location.href + " " + (w.document === f.contentDocument) + " " + typeof w.setTimeout + " " + w.name);
  log("frames " + (w.parent === window) + " " + (w.top === window));
  w.eval("window.byEval = parent === top");
  log("eval " + w.byEval);
  const seen = [];
  w.addEventListener("hello", e => seen.push(e.type));
  w.dispatchEvent(new w.Event("hello"));
  log("window listener " + seen.join());
  w.setTimeout(() => log("timer through the frame"), 0);
  log("sync end");
});
</script></body>`)
	check(pr, wait_note(pr, "called by frame"), "parent.foo() from the frame")
	check(pr, wait_note(pr, "primitives 42 text 12345678901234567890 null undefined"), "primitives copied, a missing name is undefined")
	check(pr, wait_note(pr, "object 1 3 2 3 true true"), "objects by reference: nested, methods, the same proxy each time")
	check(pr, wait_note(pr, `keys a,nested,method true false true {"b":[1,2,3]}`), "keys, in, Array.isArray, JSON.stringify through the proxies")
	check(pr, wait_note(pr, "function function 3 41"), "functions both ways: a callback of the parent called by the frame")
	check(pr, wait_note(pr, "thrown RangeError from frame"), "an exception crosses")
	check(pr, wait_note(pr, "class 4 8 true 7"), "new of a frame's class, getters, instanceof, static methods")
	check(pr, wait_note(pr, "write by parent"), "set on an object of the frame")
	check(pr, wait_note(pr, "set global 5 true true undefined"), "set, in and delete on the frame's global")
	check(pr, wait_note(pr, "node in frame true true"), "a DOM node returned from the frame is this realm's wrapper of it")
	check(pr, wait_note(pr, "node to frame BODY true"), "and a parent's node is the frame's wrapper of it")
	check(pr, wait_note(pr, "identity true true true true"), "an object coming home is itself; a window is the window")
	check(pr, said_part(pr, "window members about:srcdoc true function"), "location, document, setTimeout of the frame")
	check(pr, wait_note(pr, "frames true true"), "parent and top")
	check(pr, wait_note(pr, "eval true"), "contentWindow.eval runs in the frame")
	check(pr, wait_note(pr, "window listener hello"), "addEventListener on the frame's window, from the parent")
	check(pr, wait_note(pr, "timer through the frame"), "a timer of the frame calling the parent")
	close_page(pr, min_checks = 17)
}

// the frame reads and calls the parent
@(test)
frames_frame_reads_and_calls_the_parent :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f srcdoc="<script>
const r = [];
r.push(parent.parentValue, parent.parentFn(21), parent.parentObj.list.length, typeof parent.missing);
parent.parentObj.fromFrame = 'yes';
parent.report(r.join(' '), parent.document === document);
</script>"></iframe><script>
window.parentValue = "from-parent";
window.parentFn = x => x * 2;
window.parentObj = {list: [1, 2]};
window.report = (t, same) => { log("frame read " + t + " " + same + " " + parentObj.fromFrame); };
</script></body>`)
	check(pr, wait_note(pr, "frame read from-parent 42 2 undefined false yes"), "parent.foo, parent.foo(), objects both ways; a frame's document is not its parent's")
	close_page(pr, min_checks = 1)
}

// a realm gone: what was held of it does no harm
@(test)
frames_realm_gone :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=f srcdoc="<script>window.o = {a: 1}; window.fn = () => 1;</script>"></iframe><script>
addEventListener("load", () => {
  const f = document.getElementById("f"), w = f.contentWindow;
  const o = w.o, fn = w.fn;
  log("held " + o.a + " " + fn());
  f.remove();
  log("gone " + o.a + " " + fn() + " " + Object.keys(o).length + " " + ("a" in o));
  log("window gone " + w.closed);
});
</script></body>`)
	check(pr, wait_note(pr, "held 1 1"), "before")
	check(pr, wait_note(pr, "gone undefined undefined 0 false"), "a proxy of a realm gone answers nothing")
	check(pr, wait_note(pr, "window gone true"), "its window is closed")
	close_page(pr, min_checks = 3)
}

// the boundary: a cross-origin frame stays out of reach by every route
@(test)
frames_boundary_every_route :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	child := doc(OTHER, `<p id=secret>secret</p><script>
window.secretGlobal = 1;
const r = [];
const t = (n, f) => { try { const v = f(); r.push(n + ":" + (v === null ? "null" : typeof v)); } catch (e) { r.push(n + ":" + e.name); } };
t("parent.parentGlobal", () => parent.parentGlobal);
t("set parent.x", () => { parent.x = 1; return 1; });
t("parent.eval", () => parent.eval);
t("parent.document", () => parent.document);
t("top.document", () => top.document);
t("sibling.document", () => parent.frames[1].document);
t("frameElement", () => window.frameElement);
parent.postMessage("from child " + r.join(" "), "*");
</script>`)
	pr := load(t, fill(`<body><iframe id=f src="%s"></iframe><iframe id=f2 name=named src="%s"></iframe><script>
window.parentGlobal = "must stay here";
addEventListener("message", e => log(e.data));
const f = document.getElementById("f");
addEventListener("load", () => {   // (of the two frames: until it has its document, the named one is still the initial about:blank, of this origin)
  const r = [];
  const t = (n, g) => { try { const v = g(); r.push(n + ":" + (v === null ? "null" : typeof v)); } catch (e) { r.push(n + ":" + e.name); } };
  t("contentDocument", () => f.contentDocument);
  t("contentWindow.document", () => f.contentWindow.document);
  t("frames[0].document", () => frames[0].document);
  t("window.named.document", () => frames.named.document);
  t("getSVGDocument", () => f.getSVGDocument());
  t("get own descriptor", () => Object.getOwnPropertyDescriptor(f.contentWindow, "document"));
  t("Reflect.get", () => Reflect.get(f.contentWindow, "document"));
  t("global", () => f.contentWindow.secretGlobal);
  t("set global", () => { f.contentWindow.x = 1; return 1; });
  t("has", () => "secretGlobal" in f.contentWindow);
  t("eval", () => f.contentWindow.eval);
  t("define", () => Object.defineProperty(f.contentWindow, "y", {value: 1}));
  t("delete", () => delete f.contentWindow.secretGlobal);
  log("routes " + r.join(" "));
});
</script></body>`, child, doc(SITE2, "sibling")))
	check(pr, wait_note(pr, "routes contentDocument:null contentWindow.document:SecurityError frames[0].document:SecurityError window.named.document:SecurityError getSVGDocument:null get own descriptor:SecurityError Reflect.get:SecurityError global:SecurityError set global:SecurityError has:boolean eval:SecurityError define:SecurityError delete:SecurityError"), "from the parent: contentDocument is null, every other route a SecurityError")
	check(pr, wait_note(pr, "from child parent.parentGlobal:SecurityError set parent.x:SecurityError parent.eval:SecurityError parent.document:SecurityError top.document:SecurityError sibling.document:SecurityError frameElement:null"), "from the frame: parent.document, top.document, a sibling's document, frameElement")
	close_page(pr, min_checks = 2)
}

// the boundary: an element kept from before the frame navigated to another origin
@(test)
frames_boundary_kept_element :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, fill(`<body><iframe id=f></iframe><script>
const f = document.getElementById("f");
const kept = f.contentDocument;
kept.body.innerHTML = "<p id=old>old</p>";
const el = kept.getElementById("old");
window.kept = kept; window.el = el;
f.addEventListener("load", () => {
  const r = [];
  const t = (n, g) => { try { r.push(n + ":" + g()); } catch (e) { r.push(n + ":" + e.name); } };
  t("now", () => f.contentDocument);
  t("kept body", () => kept.body);
  t("kept query", () => kept.querySelector("#secret"));
  t("kept element", () => kept.getElementById("secret"));
  t("el parent", () => el.parentNode);
  t("el text", () => el.textContent);
  t("write", () => { kept.body.innerHTML = "<p>overwritten</p>"; return "no throw"; });
  log("after navigation " + r.slice(0, 1) + " " + r.length);
  log("kept reads " + r.slice(1, 4).join(" "));
  f.contentWindow.postMessage("report", "*");
});
addEventListener("message", e => log(e.data));
f.src = "%s";
</script></body>`, doc(OTHER, `<p id=secret>secret</p><script>addEventListener("message", () => parent.postMessage("intact " + (document.getElementById("secret") !== null) + " " + (document.querySelectorAll("p").length === 1), "*"))</script>`)))
	check(pr, wait_note(pr, "after navigation now:null 7"), "after the navigation contentDocument is null")
	check(pr, wait_note(pr, "intact true true"), "what was kept from before reaches nothing of the new cross-origin document")
	check(pr, !said_part(pr, ":[object HTMLParagraphElement]"), "no node of the new document came out of the old wrappers")
	close_page(pr, min_checks = 3)
}

// document.domain (HTML "same origin-domain"): a frame of another port of the same host is out of reach until both documents set
// document.domain to the host; then each reaches the other's document. What the setter refuses (another domain, a public suffix, a
// sandboxed document), and an origin-keyed agent cluster (Origin-Agent-Cluster: ?1), where it changes nothing.
@(test)
frames_document_domain :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	setter :: `const set = v => { try { document.domain = v; return "set " + document.domain; } catch (e) { return e.name; } };`
	child := doc(OTHER, fill(`<p id=secret>secret</p><script>%s
addEventListener("message", e => {
  if (e.data === "join") parent.postMessage("child " + set(document.domain), "*");
  if (e.data === "reach") { let r; try { r = parent.document.getElementById("mine").textContent; } catch (e) { r = e.name; } parent.postMessage("child reads " + r, "*"); }
});
</script>`, setter))
	keyed := doc(OTHER, fill(`<script>%s addEventListener("message", () => parent.postMessage("keyed " + set(document.domain), "*"));</script>`, setter), "Origin-Agent-Cluster: ?1")
	sandboxed := doc(SAME, fill(`<script>%s parent.postMessage("sandboxed " + set(document.domain), "*");</script>`, setter))
	pr := load(t, fill(`<body><p id=mine>mine</p><iframe id=f src="%s"></iframe><iframe id=k src="%s"></iframe><iframe sandbox=allow-scripts src="%s"></iframe><script>%s
const f = document.getElementById("f"), k = document.getElementById("k");
const read = w => { try { return w.document.getElementById("secret") ? "secret" : "none"; } catch (e) { return e.name; } };
addEventListener("message", e => {
  log(e.data);
  if (e.data.startsWith("child set")) {
    log("before " + read(f.contentWindow));
    log("parent " + set("127.0.0.1"));
    log("after " + read(f.contentWindow) + " " + (f.contentDocument !== null));
    f.contentWindow.postMessage("reach", "*");
    k.contentWindow.postMessage("ask", "*");
  }
  if (e.data.startsWith("keyed")) log("keyed reach " + read(k.contentWindow));
});
addEventListener("load", () => {
  log("refused " + set("example.com") + " " + set("0.1") + " " + set("") + " " + document.domain);
  f.contentWindow.postMessage("join", "*");
});
</script></body>`, child, keyed, sandboxed, setter))
	check(pr, wait_note(pr, "refused SecurityError SecurityError SecurityError 127.0.0.1"), "another domain, a suffix of an address, nothing: SecurityError, the domain unchanged")
	check(pr, wait_note(pr, "child set 127.0.0.1"), "the frame sets its domain to its host")
	check(pr, wait_note(pr, "before SecurityError"), "the frame alone set it: still another origin-domain")
	check(pr, wait_note(pr, "parent set 127.0.0.1"), "the parent sets the same")
	check(pr, wait_note(pr, "after secret true"), "now the parent reaches the frame's document (contentDocument too)")
	check(pr, wait_note(pr, "child reads mine"), "and the frame the parent's")
	check(pr, wait_note(pr, "keyed set 127.0.0.1"), "an origin-keyed agent cluster: the assignment is no error...")
	check(pr, wait_note(pr, "keyed reach SecurityError"), "... and sets nothing: that frame stays out of reach")
	check(pr, wait_note(pr, "sandboxed SecurityError"), "a sandboxed document may not set it")
	close_page(pr, min_checks = 9)
}

// the boundary: sandbox
@(test)
frames_boundary_sandbox :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body>
<iframe id=opaque sandbox="allow-scripts" srcdoc="<p id=s>s</p><script>const r=[];for(const g of [()=>parent.document,()=>top.document,()=>frameElement]){try{const v=g();r.push(v===null?'null':typeof v)}catch(e){r.push(e.name)}};parent.postMessage('sandboxed child '+r.join(' '),'*')</script>"></iframe>
<iframe id=same sandbox="allow-same-origin" srcdoc="<p id=s>reached</p>"></iframe>
<script>
addEventListener("message", e => log(e.data));
addEventListener("load", () => {
  const o = document.getElementById("opaque"), s = document.getElementById("same");
  const r = [];
  r.push(String(o.contentDocument));
  try { o.contentWindow.document; r.push("open"); } catch (e) { r.push(e.name); }
  log("opaque " + r.join(" "));
  log("same " + s.contentDocument.getElementById("s").textContent);
  // no allow-scripts: the parent reaches its DOM, and nothing it inserts there runs
  const d = s.contentDocument, el = d.createElement("script");
  el.textContent = "parent.postMessage('script ran in a sandbox without scripts', '*')";
  d.body.appendChild(el);
  d.body.insertAdjacentHTML("beforeend", "<img src=x onerror=\"parent.postMessage('handler ran in a sandbox without scripts', '*')\">");
  d.body.lastChild.addEventListener("error", () => log("the image failed"));
  const w = s.contentWindow;
  log("no realm " + typeof w.eval + " " + w.foo);
  w.flag = 7;
  log("kept " + w.flag + " " + ("flag" in w) + " " + delete w.flag + " " + w.flag);
  log("sandbox checked");
});
</script></body>`)
	check(pr, wait_note(pr, "opaque null SecurityError"), "a sandbox without allow-same-origin: out of reach from the parent")
	check(pr, wait_note(pr, "sandboxed child SecurityError SecurityError null"), "and the parent is out of reach from it")
	check(pr, wait_note(pr, "same reached"), "allow-same-origin keeps the origin: reachable")
	check(pr, wait_note(pr, "no realm undefined undefined") && wait_note(pr, "sandbox checked"), "allow-same-origin without allow-scripts: the frame has no realm to reach")
	check(pr, wait_note(pr, "kept 7 true true undefined"), "what the parent sets on the window of a frame without a realm stays there for it")
	page.images_sync(child_of(pr.p, 1))   // (what a frame of the shell starts)
	wait_note(pr, "the image failed")
	run(pr, SETTLE)
	wait_note(pr, "settled")
	check(pr, !said_part(pr, "in a sandbox without scripts"), "and no script or handler inserted from the parent runs there")
	close_page(pr, min_checks = 5)
}

// A blob: URL says nothing of an opaque origin (blob:null/...): the worker it starts in the realm that made it is of that origin, and
// another opaque origin given the same URL is refused. A sandboxed embed of a site starts its workers so.
@(test)
frames_sandbox_blob_worker :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body>
<iframe id=maker sandbox="allow-scripts" srcdoc="<script>const src='importScripts(URL.createObjectURL(new Blob([&quot;self.x=7&quot;],{type:&quot;text/javascript&quot;})));postMessage(self.origin+&quot; &quot;+self.x)';const u=URL.createObjectURL(new Blob([src],{type:'text/javascript'}));const w=new Worker(u);w.onmessage=e=>parent.postMessage('own worker '+e.data,'*');w.onerror=e=>parent.postMessage('own worker failed '+e.message,'*');parent.postMessage({url:u},'*')</script>"></iframe>
<iframe id=other sandbox="allow-scripts" srcdoc="<script>addEventListener('message',e=>{let w;try{w=new Worker(e.data)}catch(x){parent.postMessage('foreign refused','*');return}w.onmessage=()=>parent.postMessage('foreign ran','*');w.onerror=()=>parent.postMessage('foreign refused','*')});parent.postMessage('other ready','*')</script>"></iframe>
<script>
let url, ready, sent = 0;
const pass = () => { if (url && ready && !(sent++)) document.getElementById("other").contentWindow.postMessage(url, "*"); };
addEventListener("message", e => {
  if (e.data.url) url = e.data.url; else if (e.data === "other ready") ready = true; else log(e.data);
  pass();
});
</script></body>`)
	check(pr, wait_note(pr, "own worker null 7"), "a blob: worker of an opaque origin starts, of that origin, and reads a blob: URL it made")
	check(pr, wait_note(pr, "foreign refused"), "another opaque origin may not start it")
	check(pr, !said(pr, "foreign ran"), "and it did not run")
	close_page(pr, min_checks = 3)
}

// A value for an HTML attribute in double quotes.
html_attr :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, `"`, "&quot;", context.temp_allocator)
	return r
}

// about:blank and srcdoc frames: created at insertion, windows, names, load events
@(test)
frames_blank_and_srcdoc :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body>
<iframe id=a name=first></iframe>
<iframe id=b name=second srcdoc="<script>parent.postMessage('srcdoc ran ' + window.name + ' ' + (parent === top) + ' ' + (window.parent !== window) + ' ' + location.href + ' ' + origin, '*')</script>"></iframe>
<script>
const a = document.getElementById("a"), b = document.getElementById("b");
log("blank " + (a.contentWindow !== null) + " " + (a.contentWindow === frames[0]) + " " + (frames.first === a.contentWindow) + " " + window.length + " " + (a.contentDocument !== null));
addEventListener("message", e => log("message " + e.data + " from " + e.origin + " " + (e.source === b.contentWindow) + " " + e.isTrusted));
b.addEventListener("load", () => log("b load"));
addEventListener("load", () => log("window load"));
const c = document.createElement("iframe");
let sync = false;
c.addEventListener("load", () => { sync = true; });
document.body.appendChild(c);
log("sync load on insertion " + sync + " " + window.length);
c.remove();
log("after removal " + c.contentWindow + " " + window.length);
const w = a.contentWindow;
log("shared " + (w.navigator.userAgent === navigator.userAgent) + " " + (w.screen.width === screen.width) + " " + (w.crypto.getRandomValues(new Uint8Array(4)).length));
</script></body>`)
	check(pr, wait_note(pr, "shared true true 4"), "a same-origin frame gives a navigator, screen and crypto")
	check(pr, wait_note(pr, "window load"), "the parent's load event fires")
	check(pr, said(pr, "blank true true true 2 true"), "an about:blank frame has a window at once: frames[0], window[name], length; contentDocument is its document")
	check(pr, said(pr, "sync load on insertion true 3"), "an iframe without src fires load synchronously when inserted")
	check(pr, said(pr, "after removal null 2"), "removal destroys the nested document at once")
	check(pr, wait_note(pr, fill("message srcdoc ran second true true about:srcdoc %s from %s true true", testenv.url(SAME), testenv.url(SAME))), "srcdoc: parent, top, window.name from the name attribute, the parent's origin; message origin and source")
	check(pr, said_at(pr, "b load") >= 0 && said_at(pr, "b load") < said_at(pr, "window load"), "the parent's load waits for its frames' load")
	close_page(pr, min_checks = 7)
}

// a frame in a shadow tree
@(test)
frames_in_a_shadow_tree :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><div id=host></div><script>
const root = document.getElementById("host").attachShadow({mode: "closed"});
const f = document.createElement("iframe");
f.srcdoc = "<script>parent.postMessage('in shadow ' + (parent !== window), '*')<\/script>";
root.appendChild(f);
addEventListener("message", e => log(e.data));
log("shadow frames " + frames.length);
</script></body>`)
	check(pr, wait_note(pr, "shadow frames 0") && wait_note(pr, "in shadow true"), "an iframe inserted into a shadow tree gets its document (not a document-tree child: window.length leaves it out)")
	close_page(pr, min_checks = 1)
}

// the styles of nested documents
@(test)
frames_styles_of_nested_documents :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe srcdoc="<p id=x style='font:14px system-ui;padding:8px'>Hi</p><style>p{color:rgb(1, 2, 3)}</style><script>const s = getComputedStyle(document.getElementById('x')); parent.postMessage('style ' + s.fontFamily + ' ' + s.paddingTop + ' ' + s.color, '*')</script>"></iframe>
<script>addEventListener("message", e => log(e.data))</script></body>`)
	check(pr, wait_note(pr, "style system-ui 8px rgb(1, 2, 3)"), "a srcdoc document has its own style sheets and style attributes")
	close_page(pr, min_checks = 1)
	// without scripts (sandboxed, or nothing to run): its <style> applies all the same
	pr = load(t, `<body><iframe sandbox srcdoc="<style>body{font-size:23px}</style><p>x</p>"></iframe><iframe srcdoc="<style>body{font-size:23px}</style><p>x</p>"></iframe><script>addEventListener("load", () => log("window load"))</script></body>`)
	check(pr, wait_note(pr, "window load"), "loaded")
	for i in 0 ..< 2 {
		c := child_of(pr.p, i)
		st := frame_styles(c)
		cs := c.body != base.NIL_HANDLE ? style.style_of(st, c.body) : nil
		check(pr, cs != nil && cs.font_size == FONT_SIZE_IN_FRAME, fmt.tprintf("the <style> of a srcdoc document applies (%s, font-size %v)", i == 0 ? "sandboxed" : "no script", cs != nil ? cs.font_size : -1))
	}
	close_page(pr, min_checks = 3)
}

// cross-origin frames: postMessage both ways, targetOrigin, what is refused
@(test)
frames_cross_origin_post_message :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	child := doc(OTHER, `<script>
addEventListener("message", e => {
  parent.postMessage("child got " + e.data + " from " + e.origin + " " + (e.source === parent), "*");
});
parent.postMessage("hello from child " + location.origin + " " + (parent === top), "*");
try { parent.document; parent.postMessage("no throw", "*") } catch (e) { parent.postMessage("child refused " + e.name, "*") }
</script>`)
	pr := load(t, fill(`<body><iframe id=f src="%s"></iframe><script>
const f = document.getElementById("f");
addEventListener("message", e => {
  log("parent got " + e.data + " | " + e.origin + " " + (e.source === f.contentWindow));
  if (String(e.data).startsWith("hello")) {
    f.contentWindow.postMessage("wrong origin", "http://elsewhere.example");
    f.contentWindow.postMessage("ping", e.origin);
    f.contentWindow.postMessage({deep: [1, 2]}, "*");
  }
});
f.addEventListener("load", () => {
  const w = f.contentWindow;
  const r = [];
  for (const k of ["document", "foo", "alert"]) { try { w[k]; r.push(k + ":open"); } catch (e) { r.push(k + ":" + e.name); } }
  try { w.foo = 1; r.push("set:open"); } catch (e) { r.push("set:" + e.name); }
  try { w.location.href; r.push("href:open"); } catch (e) { r.push("href:" + e.name); }
  r.push(typeof w.postMessage, w.window === w, w.self === w, w.frames === w, w.top === window, w.parent === window, w.closed, w.length, String(w.opener), String(w.then));
  log("refused " + r.join(" "));
  const q = [];
  for (const k of ["history", "Array", "Node", "fetch", "console", "setTimeout", "JSON"]) { try { w[k]; q.push(k + ":open"); } catch (e) { q.push(k + ":" + e.name); } }
  log("pristine refused " + q.join(" "));
});
</script></body>`, child))
	check(pr, wait_note(pr, fill("parent got hello from child %s true | %s true", testenv.url(OTHER), testenv.url(OTHER))), "a cross-origin frame posts to its parent: origin and source")
	check(pr, wait_note(pr, fill("parent got child refused SecurityError | %s true", testenv.url(OTHER))), "the child cannot reach its parent's document")
	check(pr, wait_note(pr, fill("parent got child got ping from %s true | %s true", testenv.url(SAME), testenv.url(OTHER))), "the parent posts to the frame with its origin as targetOrigin; the frame sees the parent as source")
	check(pr, wait_note(pr, fill("parent got child got [object Object] from %s true | %s true", testenv.url(SAME), testenv.url(OTHER))), "structured clone of an object across documents")
	// (it was posted before the ping and the object, whose answers came)
	check(pr, !said_part(pr, "child got wrong origin"), "a message whose targetOrigin does not match is dropped")
	check(pr, said(pr, "refused document:SecurityError foo:SecurityError alert:SecurityError set:SecurityError href:SecurityError function true true true true true false 0 null undefined"), "a cross-origin WindowProxy: only the members HTML allows")
	check(pr, said(pr, "pristine refused history:SecurityError Array:SecurityError Node:SecurityError fetch:SecurityError console:SecurityError setTimeout:SecurityError JSON:SecurityError"), "a cross-origin WindowProxy gives no pristine copy of anything")
	close_page(pr, min_checks = 7)
}

// a same-origin frame: pristine copies of the platform, and its history (SPF calls contentWindow.history.pushState on its own)
@(test)
frames_same_origin_pristine_copies :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body><iframe id=a></iframe><script>
const w = document.getElementById("a").contentWindow;
const r = [];
const t = (name, f) => { try { r.push(name + ":" + f()); } catch (e) { r.push(name + ":" + e.name); } };
t("pushState", () => typeof w.history.pushState + " " + (w.history.pushState === History.prototype.pushState));
t("replace", () => { w.history.replaceState.call(window.history, { k: 7 }, "", "#viaframe"); return location.hash + " " + history.state.k; });
t("push", () => { w.history.pushState.call(history, 1, "", "#second"); return location.hash + " " + history.state; });
t("brandless", () => w.history.length);
t("instanceof", () => (w.history instanceof History) + " " + (w.history === w.history));
t("builtins", () => (w.Array === Array) + " " + (w.JSON === JSON) + " " + (w.Node === Node) + " " + (w.XMLHttpRequest === XMLHttpRequest));
t("realm", () => { const a = new w.Array(1, 2), o = new w.Object; return (a instanceof Array) + " " + (a instanceof w.Array) + " " + Array.isArray(a) + " " + (Object.getPrototypeOf(o) === w.Object.prototype) + " " + (o.constructor === w.Object) + " " + (o instanceof Object) + " " + w.JSON.stringify([a, o]) + " " + w.Array.isArray([]); });
t("console", () => w.console === console);
t("fetch", () => typeof w.fetch + " " + (w.fetch !== fetch));
t("timer", () => typeof w.setTimeout(() => {}, 0));
t("in", () => ("history" in w) + " " + ("Array" in w) + " " + ("nothing" in w));
t("document", () => w.document);
t("location", () => String(w.location.href));
t("page global", () => { window.PageGlobal = function PageGlobal() {}; return w.PageGlobal; });
t("page lowercase", () => { window.pageValue = 1; return w.pageValue; });
t("navigator", () => w.navigator);
t("descriptor", () => Object.getOwnPropertyDescriptor(w, "history").value === w.history);
log("same-origin " + r.join(" | "));
</script></body>`)
	check(pr, wait_note(pr, "same-origin pushState:function false | replace:#viaframe 7 | push:#second 1 | brandless:2 | instanceof:true true | builtins:false false true true | realm:false true true true true false [[1,2],{}] true | console:true | fetch:function true | timer:number | in:true true false | document:[object Document] | location:about:blank | page global:undefined | page lowercase:undefined | navigator:[object Navigator] | descriptor:false"), "the frame's own ECMAScript built-ins (instanceof across realms is false, Array.isArray sees through), the interface objects and navigator of this realm; the frame's document, location, history and globals are its own, and its history's methods act on the history they are called on; its history.length counts the tab's entries (the joint session history)")
	close_page(pr, min_checks = 1)
}

// MessagePorts between documents
@(test)
frames_message_ports_between_documents :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	child := doc(OTHER, `<script>
addEventListener("message", e => {
  const port = e.ports[0];
  port.onmessage = m => {
    port.postMessage("child heard " + m.data);
    const back = new MessageChannel();
    back.port1.onmessage = x => port.postMessage("child second channel " + x.data);
    port.postMessage({hello: "channel", p: back.port2}, [back.port2]);
  };
  port.postMessage("child ready " + e.ports.length + " " + (e.data === "take"));
});
</script>`)
	pr := load(t, fill(`<body><iframe id=f src="%s"></iframe><script>
const f = document.getElementById("f");
f.addEventListener("load", () => {
  const ch = new MessageChannel();
  ch.port1.onmessage = e => {
    log("parent port got " + (typeof e.data === "string" ? e.data : JSON.stringify(Object.keys(e.data)) + " " + (e.data.p instanceof MessagePort)));
    if (e.data === "child ready 1 true") ch.port1.postMessage("ping");
    if (e.data && e.data.p) { e.data.p.postMessage("via a port the child sent"); }
  };
  f.contentWindow.postMessage("take", "*", [ch.port2]);
  try { ch.port2.postMessage("x"); log("shipped port still posts silently") } catch (e) { log("shipped " + e.name) }
});
</script></body>`, child))
	check(pr, wait_note(pr, "parent port got child ready 1 true"), "a port transferred to a cross-origin frame arrives in event.ports")
	check(pr, wait_note(pr, "parent port got child heard ping"), "messages flow both ways on the transferred port")
	check(pr, wait_note(pr, `parent port got ["hello","p"] true`), "a port inside the message data, transferred back")
	check(pr, wait_note(pr, "parent port got child second channel via a port the child sent"), "a port the frame sent works in the parent")
	close_page(pr, min_checks = 4)
}

// MessagePorts to and from a worker
@(test)
frames_message_ports_with_a_worker :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	worker_js := `onmessage = e => {
  const port = e.ports[0];
  port.onmessage = m => port.postMessage("worker heard " + m.data);
  const ch = new MessageChannel();
  ch.port1.onmessage = m => ch.port1.postMessage("worker channel echo " + m.data);
  postMessage({kind: "mine"}, [ch.port2]);
  port.postMessage("worker ready " + e.ports.length);
};`
	src := strings.concatenate({testenv.url(SAME + "/jsload/gen?ms=0&code="), enc(worker_js)}, context.temp_allocator)
	pr := load(t, fill(`<body><script>
const w = new Worker("%s");
const ch = new MessageChannel();
ch.port1.onmessage = e => { log("page port got " + e.data); if (e.data === "worker ready 1") ch.port1.postMessage("ping"); };
w.onmessage = e => { const p = e.ports[0]; log("page got a worker port " + (p instanceof MessagePort)); p.onmessage = m => log("page " + m.data); p.postMessage("hi"); };
w.postMessage("take", [ch.port2]);
</script></body>`, src))
	check(pr, wait_note(pr, "page port got worker ready 1"), "a port transferred to a worker arrives in event.ports there")
	check(pr, wait_note(pr, "page port got worker heard ping"), "messages flow both ways between a page and a worker on a port")
	check(pr, wait_note(pr, "page got a worker port true") && wait_note(pr, "page worker channel echo hi"), "a port a worker sends works in the page")
	close_page(pr, min_checks = 3)
}

// sandbox: scripts, opaque origin
@(test)
frames_sandbox_scripts_opaque_origin :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, `<body>
<iframe sandbox srcdoc="<script>parent.postMessage('sandboxed script ran', '*')</script>"></iframe>
<iframe sandbox="allow-scripts" srcdoc="<script>parent.postMessage('allowed ' + origin + ' ' + (() => { try { localStorage.x = 1; return 'storage' } catch (e) { return e.name } })(), '*')</script>"></iframe>
<iframe sandbox="allow-scripts allow-same-origin" srcdoc="<script>parent.postMessage('same origin ' + origin, '*')</script>"></iframe>
<script>addEventListener("message", e => log(e.data + " / " + e.origin)); addEventListener("load", () => log("window load"));</script></body>`)
	check(pr, wait_note(pr, "window load"), "the parent loads")
	check(pr, wait_note(pr, "allowed null SecurityError / null"), "allow-scripts without allow-same-origin: scripts run, the origin is opaque, storage refused")
	check(pr, wait_note(pr, fill("same origin %s / %s", testenv.url(SAME), testenv.url(SAME))), "allow-same-origin keeps the origin")
	run(pr, SETTLE)
	wait_note(pr, "settled")
	check(pr, !said_part(pr, "sandboxed script ran"), "an empty sandbox runs no script")
	close_page(pr, min_checks = 4)
}

// X-Frame-Options, frame-ancestors, frame-src
@(test)
frames_x_frame_options_frame_ancestors_frame_src :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	shown :: `<script>parent.postMessage("shown " + location.search.length, "*")</script>`
	pr := load(t, fill(`<body>
<iframe id=deny src="%s"></iframe>
<iframe id=so src="%s"></iframe>
<iframe id=so2 src="%s"></iframe>
<iframe id=fa src="%s"></iframe>
<iframe id=fa2 src="%s"></iframe>
<script>
addEventListener("message", e => log("msg " + e.origin));
for (const id of ["deny", "so", "so2", "fa", "fa2"]) document.getElementById(id).addEventListener("load", () => log("load " + id));
addEventListener("load", () => log("window load"));
</script></body>`,
		doc(OTHER, shown, "X-Frame-Options: DENY"),
		doc(OTHER, shown, "X-Frame-Options: SAMEORIGIN"),
		doc(SAME, shown, "X-Frame-Options: SAMEORIGIN"),
		doc(OTHER, shown, "Content-Security-Policy: frame-ancestors 'none'", "X-Frame-Options: ALLOWALL"),
		doc(SITE2, shown, fill("Content-Security-Policy: frame-ancestors %s", testenv.url(SAME)), "X-Frame-Options: DENY")))
	check(pr, wait_note(pr, "window load"), "the parent's load is not stuck on refused frames")
	check(pr, said(pr, "load deny") && said(pr, "load so") && said(pr, "load fa"), "a refused frame still fires load at its container")
	check(pr, console_says(pr, "it set 'X-Frame-Options' to 'deny'"), "the console says why (X-Frame-Options)")
	check(pr, console_says(pr, "frame-ancestors"), "the console says why (frame-ancestors)")
	check(pr, wait_note(pr, fill("msg %s", testenv.url(SAME))), "X-Frame-Options: SAMEORIGIN from the same origin is shown")
	check(pr, wait_note(pr, fill("msg %s", testenv.url(SITE2))), "frame-ancestors naming the parent overrides X-Frame-Options")
	count := 0
	for l in pr.section.notes { if strings.has_prefix(l, "msg ") { count += 1 } }
	check(pr, count == 2, fmt.tprintf("only the allowed documents ran (%d messages)", count))
	close_page(pr, min_checks = 7)

	pr = load(t, fill(`<body><iframe id=x src="%s"></iframe><script>
addEventListener("message", e => log("csp msg " + e.data));
document.getElementById("x").addEventListener("load", () => log("x load"));
</script></body>`, doc(OTHER, shown)), csp = "frame-src 'self'")
	check(pr, wait_note(pr, "x load"), "a frame refused by the parent's frame-src still fires load")
	run(pr, SETTLE)
	wait_note(pr, "settled")
	check(pr, !said_part(pr, "csp msg shown"),"the parent's CSP frame-src refuses another origin")
	close_page(pr, min_checks = 2)
}

// navigation: src, the frame itself, window.open to a frame name, location of another window
@(test)
frames_navigation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	second := doc(OTHER, `<script>parent.postMessage("second " + name, "*")</script>`)
	first := doc(OTHER, fill(`<script>parent.postMessage("first " + name, "*"); setTimeout(() => { location.href = "%s" }, 0)</script>`, second))
	pr := load(t, fill(`<body><iframe id=f name=target src="%s"></iframe><script>
let loads = 0;
const f = document.getElementById("f");
f.addEventListener("load", () => log("f load " + (++loads)));
addEventListener("message", e => log("nav " + e.data));
</script></body>`, first))
	check(pr, wait_note(pr, "nav first target"), "the first document")
	check(pr, wait_note(pr, "nav second target"), "the frame navigates itself (location.href); its name stays")
	check(pr, wait_note(pr, "f load 2"), "each navigation fires load at the container")
	run(pr, fill(`const w = window.open("%s", "target"); log("open returned " + (w === f.contentWindow));`, doc(OTHER, `<script>parent.postMessage("opened", "*")</script>`)))
	check(pr, said(pr, "open returned true") && wait_note(pr, "nav opened"), "window.open(url, name) navigates the named frame and returns its window")
	run(pr, fill(`f.contentWindow.location = "%s";`, doc(OTHER, `<script>parent.postMessage("by location", "*")</script>`)))
	check(pr, wait_note(pr, "nav by location"), "the parent navigates a cross-origin frame through its location")
	run(pr, fill(`f.src = "%s";`, doc(SAME, `<script>parent.postMessage("by src", "*")</script>`)))
	check(pr, wait_note(pr, "nav by src"), "setting src navigates")
	close_page(pr, min_checks = 6)
}

// The Window of a frame's initial about:blank is the next document's when that one is of its origin (frames.odin, frame_keep_window):
// an expando, a listener and navigation.onnavigate set on it stay; the document and history are new. Another origin gets a Window of its own.
@(test)
frames_initial_window_kept :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	same := doc(SAME, `<p id=p>next</p><script>document.getElementById("p").dataset.seen = String(window.kept)</script>`)
	pr := load(t, fill(`<body><iframe id=f src="%s"></iframe><iframe id=o src="%s"></iframe><script>
const f = document.getElementById("f"), o = document.getElementById("o");
const w = f.contentWindow, blank = f.contentDocument, hist = w.history;
w.kept = "yes";
o.contentWindow.kept = "yes";
w.addEventListener("custom", () => log("listener kept"));
w.navigation.onnavigate = e => log("onnavigate kept " + e.destination.url.endsWith("#x"));
f.onload = () => {
  const d = f.contentDocument;
  log("kept " + w.kept + " " + d.getElementById("p").dataset.seen + " " + (d !== blank) + " " + (w.history !== hist));
  w.dispatchEvent(new w.Event("custom"));
  w.location.hash = "x";
};
o.onload = () => { try { log("other " + o.contentWindow.kept); } catch (e) { log("other " + e.name); } };
</script></body>`, same, doc(OTHER, "other")))
	check(pr, wait_note(pr, "kept yes yes true true"), "the frame's next document of the same origin has the blank one's Window: its expando, seen by the new document's own script; a new document and history")
	check(pr, wait_note(pr, "listener kept"), "a listener added to the blank Window stays")
	check(pr, wait_note(pr, "onnavigate kept true"), "navigation.onnavigate set on the blank Window fires for the next document's navigations")
	check(pr, wait_note(pr, "other SecurityError"), "a document of another origin has a Window of its own")
	close_page(pr, min_checks = 4)
}

// CSP Embedded Enforcement (frames_csp.odin): an iframe's csp attribute is a policy its documents take, its sandbox directive with it.
// A srcdoc document takes it, a response with Allow-CSP-From: * takes it (document.domain throws in both: they are sandboxed), a response
// without it nor a policy as strict is refused (the frame shows an error document of an opaque origin).
@(test)
frames_required_csp :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	probe :: `<script>try { document.domain = document.domain; parent.postMessage(name + " allowed", "*") } catch (e) { parent.postMessage(name + " " + e.name, "*") }</script>`
	pr := load(t, fill(`<body><script>
addEventListener("message", e => log(e.data));
const policy = "sandbox allow-scripts allow-same-origin";
function frame(name) { const f = document.createElement("iframe"); f.name = name; f.csp = policy; return f; }
const s = frame("srcdoc"); s.srcdoc = %s; document.body.appendChild(s);
const a = frame("allowed"); a.src = "%s"; document.body.appendChild(a);
const r = frame("refused"); r.src = "%s"; r.onload = () => log("refused " + (r.contentDocument === null)); document.body.appendChild(r);
log("attribute " + (s.csp === policy && s.getAttribute("csp") === policy));
</script></body>`, strings.concatenate({"`", probe[:len(probe) - len("</script>")], "<\\/script>`"}, context.temp_allocator), doc(SAME, probe, "Allow-CSP-From: *"), doc(SAME, probe)))
	check(pr, wait_note(pr, "attribute true"), "iframe.csp reflects the csp attribute")   // (it was read at once: on a loaded machine the page had not said it yet)
	check(pr, wait_note(pr, "srcdoc SecurityError"), "a srcdoc document takes the required policy: its sandbox directive forbids document.domain")
	check(pr, wait_note(pr, "allowed SecurityError"), "a response with Allow-CSP-From: * takes the required policy and its sandbox")
	check(pr, wait_note(pr, "refused true"), "a response that does not take the required policy is refused: an error document of an opaque origin")
	check(pr, !said(pr, "refused allowed") && !said(pr, "refused SecurityError"), "nothing of the refused document ran")
	close_page(pr, min_checks = 5)
}

// nesting: frames of frames, top and parent, a frame closed with its parent
@(test)
frames_nesting :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	inner := doc(SITE2, `<script>parent.postMessage("inner top " + (top === parent.parent) + " " + (parent !== top), "*"); top.postMessage("inner to top", "*")</script>`)
	middle := doc(OTHER, fill(`<iframe src="%s"></iframe><script>addEventListener("message", e => parent.postMessage("middle relays " + e.data + " " + (e.source === frames[0]), "*"))</script>`, inner))
	pr := load(t, fill(`<body><iframe src="%s"></iframe><script>addEventListener("message", e => log("top got " + e.data + " " + e.origin))</script></body>`, middle))
	check(pr, wait_note(pr, fill("top got middle relays inner top true true true %s", testenv.url(OTHER))), "a frame's frame: top, parent, frames[0] as source")
	check(pr, wait_note(pr, fill("top got inner to top %s", testenv.url(SITE2))), "top.postMessage from a nested frame")
	c := child_of(pr.p)
	check(pr, c != nil && len(page.frames_children(c)) == 1, "the middle document has its own frame")
	close_page(pr, min_checks = 3)
}

// Permissions Policy: the allow attribute delegates features
@(test)
frames_permissions_policy :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, fill(`<body><iframe id=a src="%s"></iframe><iframe id=b allow="publickey-credentials-get; fullscreen 'none'" src="%s"></iframe><iframe id=c srcdoc="x"></iframe><script>addEventListener("load", () => log("window load"))</script></body>`, doc(OTHER, "a"), doc(OTHER, "b")))
	check(pr, wait_note(pr, "window load"), "loaded")
	a, b, c := child_of(pr.p, 0), child_of(pr.p, 1), child_of(pr.p, 2)
	check(pr, a != nil && !page.feature_enabled(a, .Publickey_Credentials_Get) && !page.feature_enabled(a, .Fullscreen), "a cross-origin frame without allow: 'self' features are off")
	check(pr, a != nil && page.feature_enabled(a, .Sync_Xhr), "features whose default is * stay on")
	check(pr, b != nil && page.feature_enabled(b, .Publickey_Credentials_Get), "allow=\"publickey-credentials-get\" delegates WebAuthn to the frame")
	check(pr, b != nil && !page.feature_enabled(b, .Fullscreen), "allow=\"fullscreen 'none'\" keeps it off")
	check(pr, c != nil && page.feature_enabled(c, .Publickey_Credentials_Get), "a same-origin frame has the 'self' features")
	close_page(pr, min_checks = 6)
}

// Numbers, not checks: the time a frame takes to have a running document, and the memory it holds. A performance run (test_all -Perf).
@(test)
frames_measurements :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	if base.perf_skip("web tests, frames: the time and memory of 20 srcdoc frames") { return }
	begin(t)
	defer end()
	serve(t)
	// warm-up: the engine's code and the first realm's costs are not a frame's
	pr := load(t, `<body><iframe srcdoc="<script>parent.postMessage('w', '*')</script>"></iframe><script>addEventListener("message", () => log("warm"))</script></body>`)
	wait_note(pr, "warm")
	close_page(pr)
	drain()
	keep := base.poison_quarantine_limit(0)   // (private bytes count what is freed otherwise)
	defer base.poison_quarantine_limit(keep)
	before := int(base.process_memory().private)
	t0 := time.tick_now()
	pr = load(t, fill(`<body><script>
let n = 0;
addEventListener("message", () => { if (++n === %s) log("all frames ran"); });
const t = performance.now();
for (let i = 0; i < %s; i++) {
  const f = document.createElement("iframe");
  f.srcdoc = "<p>frame " + i + "</p><script>parent.postMessage(1, '*')<\/script>";
  document.body.appendChild(f);
}
log("inserted in " + (performance.now() - t).toFixed(2) + " ms");
</script></body>`, fmt.tprint(MEASURED_FRAMES), fmt.tprint(MEASURED_FRAMES)))
	ok := wait_note(pr, "all frames ran")
	ms := time.duration_milliseconds(time.tick_since(t0))
	after := int(base.process_memory().private)
	for l in pr.section.notes { if strings.has_prefix(l, "inserted in") { fmt.printfln("measure: %d srcdoc frames %s (synchronous part: navigables, realms)", MEASURED_FRAMES, l) } }
	fmt.printfln("measure: %d srcdoc frames with a script each, until all ran: %.1f ms (%.2f ms per frame)%s", MEASURED_FRAMES, ms, ms / MEASURED_FRAMES, ok ? "" : " (not all ran)")
	fmt.printfln("measure: private bytes +%.1f MiB for %d frames (%.2f MiB per frame, document and JavaScript realm)", f64(after - before) / (1 << 20), MEASURED_FRAMES, f64(after - before) / (1 << 20) / MEASURED_FRAMES)
	close_page(pr)
	drain()
	t1 := time.tick_now()
	pr = load(t, fill(`<body><iframe src="%s"></iframe><script>addEventListener("message", e => log("cross " + e.data))</script></body>`, doc(OTHER, `<script>parent.postMessage("up", "*")</script>`)))
	wait_note(pr, "cross up")
	fmt.printfln("measure: one cross-origin frame over the test server, page start to its first message: %.1f ms", time.duration_milliseconds(time.tick_since(t1)))
	close_page(pr)
}

// The JIT on DOM objects (src/tools/e2e/web_jsweb.odin, jsweb_jit_dom: every function compiled at its first call, each loop
// at its first sampled back edge, on the page's thread): attributes read through the nodes' prototypes and their native
// getters by compiled loops, while the loops change the DOM, a getter that throws (once), a getter replaced by a
// script's, methods of the nodes called.

const RUN = 20000;

function fill(list, n) {
  for (let k = 0; k < n; k++) { const li = document.createElement("li"); li.textContent = "x" + k; list.appendChild(li); }
}

test("attributes read by a compiled loop", () => {
  const list = document.createElement("ul");
  fill(list, 50);
  function walk(n) { let s = 0; for (let i = 0; i < n; i++) { const c = list.firstChild; s += c.nodeType + (c.nextSibling ? 1 : 0) + c.textContent.length; } return s; }
  eq(walk(RUN), RUN * 4, "nodeType, nextSibling, textContent.length");
  function lengths(n) { let s = 0; for (let i = 0; i < n; i++) { s += list.childNodes.length + list.children[i % 50].textContent.length; } return s; }
  // (the 50 items' texts: 10 of 2 characters, 40 of 3)
  eq(lengths(RUN), RUN * 50 + 140 * (RUN / 50), "a NodeList's length, an HTMLCollection's items");
});

test("a loop that changes the DOM it reads", () => {
  const list = document.createElement("ul");
  function drain(n) { let c = 0; for (let i = 0; i < n; i++) { while (list.lastChild) { list.removeChild(list.lastChild); c++; } list.appendChild(document.createElement("b")); list.appendChild(document.createElement("i")); } return c; }
  fill(list, 10);
  eq(drain(2000), 10 + 2 * 1999, "children removed");
  eq(list.childNodes.length, 2, "what is left");
  eq(list.lastChild.nodeName, "I", "the last child");
});

test("a getter that throws", () => {
  const list = document.createElement("ul");
  let reached = 0;
  const nodes = [list, list, list, Object.create(Node.prototype)];
  function types(n) { let s = 0; for (let i = 0; i < n; i++) { s += nodes[i & 3].nodeType; reached++; } return s; }
  throws(() => types(RUN), "TypeError", "nodeType of an object that is not a node");
  eq(reached, 3, "the loop stopped at the first one");
  nodes[3] = list;
  eq(types(RUN), RUN, "and runs again");
});

test("a getter replaced by a script's", () => {
  const list = document.createElement("ul");
  fill(list, 3);
  function types(n) { let s = 0; for (let i = 0; i < n; i++) { s += list.firstChild.nodeType; } return s; }
  eq(types(RUN), RUN, "the native getter");
  const real = Object.getOwnPropertyDescriptor(Node.prototype, "nodeType");
  let calls = 0;
  Object.defineProperty(Node.prototype, "nodeType", { get: function () { calls++; return 2; }, configurable: true });
  try {
    eq(types(RUN), 2 * RUN, "the script's getter");
    eq(calls, RUN, "called once a read");
  } finally {
    Object.defineProperty(Node.prototype, "nodeType", real);
  }
  eq(types(RUN), RUN, "the native getter again");
});

__run();
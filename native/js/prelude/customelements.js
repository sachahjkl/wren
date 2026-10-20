// Custom elements (HTML §4.13): the registry, definitions, upgrades and reactions, for the engine's glue
// (runtime/custom_elements.c), which binds CustomElementRegistry's operations and the HTMLElement constructor to the
// functions this installs. The browser keeps the defined local names, the elements' states and the queue of reactions
// its DOM's mutations cause (src/page/js_custom_elements.odin); `process` runs that queue. Customized built-in
// elements (`extends`, is="") are not supported: define() says so.
(function (host) {
  "use strict";
  const UPGRADE = 1, CONNECTED = 2, DISCONNECTED = 3, ATTRIBUTE = 4;
  const STATE_CUSTOM = 1, STATE_FAILED = 2;
  const byName = new Map(), byCtor = new Map(), pending = new Map();   // name -> {promise, resolve}
  const defs = new WeakMap();    // element -> its definition, once upgraded (or failed)
  const stack = [];              // the construction stack: {def, element} entries ("already constructed": element null)
  const ALREADY = null;
  let running = false;           // "element definition is running"
  const reserved = new Set(["annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri",
    "font-face-format", "font-face-name", "missing-glyph"]);
  const { setPrototypeOf } = Object;
  // the DOM's own accessors (a page replacing them changes nothing here), read on first use: this runs at
  // pre-initialization, before a realm puts the interfaces on its global
  let dom = null;
  const getter = (proto, name) => Object.getOwnPropertyDescriptor(proto, name).get;
  function D() {
    if (dom === null) {
      dom = {
        isConnected: getter(Node.prototype, "isConnected"),
        localName: getter(Element.prototype, "localName"),
        attributes: getter(Element.prototype, "attributes"),
        qsa: Document.prototype.querySelectorAll,
      };
    }
    return dom;
  }
  const domException = (name, message) => new DOMException(message, name);

  // HTML "valid custom element name": PotentialCustomElementName, not reserved
  const PCEN = /^[a-z][\-.0-9_a-z\u00B7\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u037D\u037F-\u1FFF\u200C-\u200D\u203F-\u2040\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\u{10000}-\u{EFFFF}]*-[\-.0-9_a-z\u00B7\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u037D\u037F-\u1FFF\u200C-\u200D\u203F-\u2040\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\u{10000}-\u{EFFFF}]*$/u;
  const validName = (name) => PCEN.test(name) && !reserved.has(name);

  function callback(proto, name) {
    const f = proto[name];
    if (f !== undefined && typeof f !== "function") throw new TypeError(`Failed to execute 'define' on 'CustomElementRegistry': The '${name}' property is not a function.`);
    return f;
  }

  function react(def, el, name, args) {
    const f = def[name];
    if (f === undefined) return;
    try { f.apply(el, args); } catch (e) { host.report(e); }
  }

  // HTML "upgrade an element"
  function upgrade(def, el) {
    if (defs.has(el)) return;   // custom or failed already
    defs.set(el, def);
    host.setState(el, STATE_FAILED);   // until the constructor succeeds
    stack.push({ def, element: el });
    try {
      const r = new def.ctor();
      if (r !== el) throw new TypeError("Failed to construct a custom element: the constructor did not return the element being upgraded.");
    } catch (e) {
      host.report(e);
      return;
    } finally {
      stack.pop();
    }
    host.setState(el, STATE_CUSTOM);
    // the reactions upgrading queues: the observed attributes it has, then connected when it is in the document
    if (def.attributeChangedCallback !== undefined) {
      for (const a of Array.from(D().attributes.call(el))) {
        if (def.observed.has(a.name)) react(def, el, "attributeChangedCallback", [a.name, null, a.value, a.namespaceURI]);
      }
    }
    if (D().isConnected.call(el)) react(def, el, "connectedCallback", []);
  }

  function tryUpgrade(el) {
    if (defs.has(el)) return;
    const def = byName.get(D().localName.call(el));
    if (def) upgrade(def, el);
  }

  function define(name, ctor, options) {
    name = String(name);
    if (!host.isConstructor(ctor)) throw new TypeError("Failed to execute 'define' on 'CustomElementRegistry': The provided value is not of type 'CustomElementConstructor'.");
    if (!validName(name)) throw domException("SyntaxError", `Failed to execute 'define' on 'CustomElementRegistry': "${name}" is not a valid custom element name`);
    if (byName.has(name)) throw domException("NotSupportedError", `Failed to execute 'define' on 'CustomElementRegistry': the name "${name}" has already been used with this registry`);
    if (byCtor.has(ctor)) throw domException("NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': this constructor has already been used with this registry");
    const ext = options === undefined || options === null ? undefined : options.extends;
    if (ext !== undefined) {
      if (validName(String(ext))) throw domException("NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': 'extends' names a custom element");
      throw domException("NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': customized built-in elements ('extends') are not supported");
    }
    if (running) throw domException("NotSupportedError", "Failed to execute 'define' on 'CustomElementRegistry': a definition is running");
    running = true;
    let def;
    try {
      const proto = ctor.prototype;
      if (typeof proto !== "object" && typeof proto !== "function" || proto === null) throw new TypeError("Failed to execute 'define' on 'CustomElementRegistry': The 'prototype' property of the constructor is not an object.");
      def = {
        name, ctor,
        connectedCallback: callback(proto, "connectedCallback"),
        disconnectedCallback: callback(proto, "disconnectedCallback"),
        adoptedCallback: callback(proto, "adoptedCallback"),
        attributeChangedCallback: callback(proto, "attributeChangedCallback"),
        observed: new Set(),
      };
      if (def.attributeChangedCallback !== undefined) {
        const list = ctor.observedAttributes;
        if (list !== undefined) for (const a of list) def.observed.add(String(a));
      }
      // read, as the standard does, though form-associated elements are not implemented
      void ctor.formAssociated;
    } finally {
      running = false;
    }
    byName.set(name, def);
    byCtor.set(ctor, def);
    host.define(name);
    // the elements of the document with that name, in tree order
    for (const el of Array.from(D().qsa.call(document, name))) tryUpgrade(el);
    const p = pending.get(name);
    if (p) { pending.delete(name); p.resolve(ctor); }
  }

  // [HTMLConstructor] (HTML §3.2.3), for `super()` in a custom element's class or `new MyElement()`
  function construct(newTarget) {
    const def = byCtor.get(newTarget);
    if (def === undefined) throw new TypeError("Illegal constructor");
    const proto = newTarget.prototype;
    if (stack.length === 0 || stack[stack.length - 1].def !== def) {
      // new MyElement(): a new element of that name, custom from the start
      const el = host.create(def.name);
      setPrototypeOf(el, typeof proto === "object" && proto !== null ? proto : HTMLElement.prototype);
      defs.set(el, def);
      return el;
    }
    const top = stack[stack.length - 1];
    const el = top.element;
    if (el === ALREADY) throw domException("InvalidStateError", "Failed to construct 'HTMLElement': the element is already constructed");
    setPrototypeOf(el, proto);
    top.element = ALREADY;
    return el;
  }

  // the browser's queue, until it is empty (a reaction may queue more)
  function process() {
    for (;;) {
      const list = host.take();
      if (list.length === 0) return;
      for (const r of list) {
        const el = r[1];
        if (el === null) continue;
        switch (r[0]) {
          case UPGRADE: tryUpgrade(el); break;
          case CONNECTED: { const d = defs.get(el); if (d) react(d, el, "connectedCallback", []); break; }
          case DISCONNECTED: { const d = defs.get(el); if (d) react(d, el, "disconnectedCallback", []); break; }
          case ATTRIBUTE: {
            const d = defs.get(el);
            if (d && d.observed.has(r[2])) react(d, el, "attributeChangedCallback", [r[2], r[3], r[4], null]);
            break;
          }
        }
      }
    }
  }

  // shadow-including inclusive descendants of `root`, in tree order
  function upgradeTree(root) {
    const list = [];
    if (root.nodeType === 1) list.push(root);
    for (const el of Array.from(root.querySelectorAll ? root.querySelectorAll("*") : [])) list.push(el);
    for (const el of list) tryUpgrade(el);
  }

  host.install({
    define,
    get: (name) => { const d = byName.get(String(name)); return d ? d.ctor : undefined; },
    getName: (ctor) => { const d = byCtor.get(ctor); return d ? d.name : null; },
    whenDefined(name) {
      name = String(name);
      if (!validName(name)) return Promise.reject(domException("SyntaxError", `Failed to execute 'whenDefined' on 'CustomElementRegistry': "${name}" is not a valid custom element name`));
      const d = byName.get(name);
      if (d) return Promise.resolve(d.ctor);
      let p = pending.get(name);
      if (!p) {
        let resolve;
        const promise = new Promise((r) => { resolve = r; });
        p = { promise, resolve };
        pending.set(name, p);
      }
      return p.promise;
    },
    upgrade: upgradeTree,
    construct,
    process,
  });
})(__wren_ce_host);
delete globalThis.__wren_ce_host;

// CSS Custom Highlight API: `Highlight`, `HighlightRegistry` and `CSS.highlights`, evaluated by web_highlight.odin the first time a script reads
// one of them. A change of a registered highlight, or of a range anywhere, sends the registry to the painter in a microtask (src/page/highlights.odin).
(function (native, global, wanted) {
  "use strict";
  const TE = TypeError, S = String, SetC = Set, MapC = Map, symIterator = Symbol.iterator, symTag = Symbol.toStringTag;
  const { defineProperty, getOwnPropertyDescriptor } = Object, apply = Reflect.apply;
  const microtask = global.queueMicrotask, document = global.document, RangeC = global.Range;
  const rangeProto = global.AbstractRange.prototype;
  const reader = name => getOwnPropertyDescriptor(rangeProto, name).get;
  const startContainer = reader("startContainer"), startOffset = reader("startOffset"), endContainer = reader("endContainer"), endOffset = reader("endOffset");
  const isRange = r => { apply(startContainer, r, []); return r; };   // (throws for anything but an AbstractRange)
  const ShadowRootC = global.ShadowRoot;
  const shadowHost = getOwnPropertyDescriptor(ShadowRootC.prototype, "host").get;
  const rootNode = global.Node.prototype.getRootNode;
  const SHOW_TEXT = 4, TEXT_NODE = 3;
  // HighlightsFromPointOptions: the shadow roots asked for, which a script may hold.
  const shadowRootsOf = options => {
    const roots = new SetC();
    if (options === undefined || options === null) return roots;
    if (typeof options !== "object" && typeof options !== "function") throw new TE("Failed to execute 'highlightsFromPoint' on 'HighlightRegistry': the options are not an object.");
    const list = options.shadowRoots;
    if (list === undefined) return roots;
    if (list === null || typeof list[symIterator] !== "function") throw new TE("Failed to execute 'highlightsFromPoint' on 'HighlightRegistry': shadowRoots is not a sequence.");
    for (const r of list) { apply(shadowHost, r, []); roots.add(r); }   // (throws for anything but a ShadowRoot)
    return roots;
  };
  // Is the text of `r` under the point? Only text is highlighted, and only that of the tree the range is in: a range across trees paints nothing, and what a shadow host
  // inside it shows is not in it, nor is a shadow tree nobody named.
  const hitsRange = (r, px, py, roots) => {
    const a = apply(startContainer, r, []), from = apply(startOffset, r, []), b = apply(endContainer, r, []), to = apply(endOffset, r, []);
    const root = apply(rootNode, a, []);
    if (root !== apply(rootNode, b, []) || (root instanceof ShadowRootC && !roots.has(root))) return false;
    if (a === b && from === to) return false;   // (collapsed: not rendered)
    const live = new RangeC(), piece = new RangeC();
    try { live.setStart(a, from); live.setEnd(b, to); } catch { return false; }   // (a StaticRange past the end of its node)
    const top = live.commonAncestorContainer;
    const walker = document.createTreeWalker(top, SHOW_TEXT);
    for (let t = top.nodeType === TEXT_NODE ? top : walker.nextNode(); t !== null; t = top.nodeType === TEXT_NODE ? null : walker.nextNode()) {
      if (!live.intersectsNode(t)) continue;
      piece.setStart(t, t === a ? from : 0);
      piece.setEnd(t, t === b ? to : t.length);
      for (const box of piece.getClientRects()) {
        if (px >= box.left && px < box.right && py >= box.top && py < box.bottom) return true;
      }
    }
    return false;
  };
  const TYPES = ["highlight", "spelling-error", "grammar-error"];
  const states = new WeakMap();
  const stateOf = o => {
    const s = states.get(o);
    if (s === undefined) throw new TE("Illegal invocation");
    return s;
  };
  const entries = new MapC();   // CSS.highlights: name -> Highlight
  const registered_at = new MapC();   // name -> the turn it was last set
  let registrations = 0;
  let queued = false;
  const send = () => {
    queued = false;
    native.clear();
    // (the map keeps a name where it first came; the last registered is above, whatever its place)
    const order = [...entries].sort((a, b) => registered_at.get(a[0]) - registered_at.get(b[0]));
    for (const [name, h] of order) {
      const s = states.get(h);
      native.add(name, s.priority);
      for (const r of s.ranges) native.range(apply(startContainer, r, []), apply(startOffset, r, []), apply(endContainer, r, []), apply(endOffset, r, []));
    }
  };
  const changed = () => {
    if (queued) return;
    queued = true;
    microtask(send);
  };
  const registered = s => { if (s.names > 0) changed(); };
  const callable = (f, what) => { if (typeof f !== "function") throw new TE("Failed to execute 'forEach' on '" + what + "': the callback is not a function."); };

  class Highlight {
    constructor(...initialRanges) {
      const ranges = new SetC();
      for (const r of initialRanges) ranges.add(isRange(r));
      states.set(this, { ranges, priority: 0, type: "highlight", names: 0 });
    }
    get priority() { return stateOf(this).priority; }
    set priority(v) { const s = stateOf(this); s.priority = v | 0; registered(s); }
    get type() { return stateOf(this).type; }
    set type(v) { const s = stateOf(this), t = S(v); if (TYPES.includes(t)) s.type = t; }
    get size() { return stateOf(this).ranges.size; }
    has(r) { return stateOf(this).ranges.has(r); }
    add(r) { const s = stateOf(this); s.ranges.add(isRange(r)); registered(s); return this; }
    delete(r) { const s = stateOf(this), gone = s.ranges.delete(r); if (gone) registered(s); return gone; }
    clear() { const s = stateOf(this); s.ranges.clear(); registered(s); }
    forEach(f, thisArg = undefined) {
      const s = stateOf(this);
      callable(f, "Highlight");
      s.ranges.forEach(r => apply(f, thisArg, [r, r, this]));
    }
    values() { return stateOf(this).ranges.values(); }
    keys() { return stateOf(this).ranges.values(); }
    entries() { return stateOf(this).ranges.entries(); }
  }

  let constructing = false, highlights;
  class HighlightRegistry {
    constructor() { if (!constructing) throw new TE("Illegal constructor"); }
    get size() { return entries.size; }
    has(name) { return entries.has(S(name)); }
    get(name) { return entries.get(S(name)); }
    set(name, h) {
      const s = stateOf(h), key = S(name), old = entries.get(key);
      if (old !== undefined) states.get(old).names--;
      s.names++;
      entries.set(key, h);
      registered_at.set(key, ++registrations);
      changed();
      return this;
    }
    delete(name) {
      const key = S(name), old = entries.get(key);
      if (old === undefined) return false;
      states.get(old).names--;
      entries.delete(key);
      changed();
      return true;
    }
    clear() {
      for (const h of entries.values()) states.get(h).names--;
      entries.clear();
      changed();
    }
    forEach(f, thisArg = undefined) {
      callable(f, "HighlightRegistry");
      entries.forEach((h, name) => apply(f, thisArg, [h, name, this]));
    }
    keys() { return entries.keys(); }
    values() { return entries.values(); }
    entries() { return entries.entries(); }
    // What the rectangles of its ranges put under the point, the highest priority first (equal priorities: the last registered).
    highlightsFromPoint(x, y, options = undefined) {
      if (this !== highlights) throw new TE("Illegal invocation");
      if (arguments.length < 2) throw new TE("Failed to execute 'highlightsFromPoint' on 'HighlightRegistry': 2 arguments required.");
      const px = +x, py = +y, hits = [];
      if (!isFinite(px) || !isFinite(py)) throw new TE("Failed to execute 'highlightsFromPoint' on 'HighlightRegistry': the coordinates are not finite.");
      const roots = shadowRootsOf(options);
      if (px < 0 || py < 0 || px >= document.documentElement.clientWidth || py >= document.documentElement.clientHeight) return hits;
      for (const [name, h] of entries) {
        const s = states.get(h), ranges = [], order = registered_at.get(name);
        for (const r of s.ranges) { if (hitsRange(r, px, py, roots)) ranges.push(r); }
        if (ranges.length > 0) hits.push({ highlight: h, ranges, priority: s.priority, order });
      }
      hits.sort((a, b) => b.priority - a.priority || b.order - a.order);
      return hits.map(hit => ({ highlight: hit.highlight, ranges: hit.ranges }));
    }
  }

  // WebIDL: the operations of an interface are enumerable, the iteration of a setlike is its values, of a maplike its entries
  const webidl = (C, iterator, also) => {
    const proto = C.prototype;
    for (const name of Object.getOwnPropertyNames(proto)) {
      if (name !== "constructor") defineProperty(proto, name, { enumerable: true });
    }
    defineProperty(proto, symIterator, { value: proto[iterator], writable: true, configurable: true });
    if (also) defineProperty(proto, also, { value: proto[iterator], writable: true, enumerable: true, configurable: true });
    defineProperty(proto, symTag, { value: C.name, configurable: true });
  };
  webidl(Highlight, "values");
  webidl(HighlightRegistry, "entries");

  constructing = true;
  highlights = new HighlightRegistry();
  constructing = false;
  native.watch(() => { if (entries.size > 0) changed(); });

  // the other two names have what this evaluation made: it runs once
  const hidden = { writable: true, enumerable: false, configurable: true };
  if (wanted !== "Highlight") defineProperty(global, "Highlight", { value: Highlight, ...hidden });
  if (wanted !== "HighlightRegistry") defineProperty(global, "HighlightRegistry", { value: HighlightRegistry, ...hidden });
  if (wanted !== "highlights") defineProperty(native.css, "highlights", { value: highlights, writable: false, enumerable: true, configurable: true });
  return wanted === "Highlight" ? Highlight : wanted === "HighlightRegistry" ? HighlightRegistry : highlights;
})

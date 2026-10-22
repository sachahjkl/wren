// ResizeObserver, ResizeObserverEntry and ResizeObserverSize (Resize Observer §3) for the engine's glue
// (runtime/web_resize.c). The browser calls `update` at each rendering update while some observer observes a target,
// after the animation frame callbacks and the layout they asked for, before the intersection observations. Each observer
// remembers the size it last reported per target ("lastReportedSizes", [0, 0] before the first report): a target
// whose size of the observed box differs has an active observation; the observers that have some get their entries in
// one callback each, then the sizes are taken again (what the callbacks changed): up to a few times per update, the
// rest waits for the next one (Chromium reports "ResizeObserver loop completed with undelivered notifications"). Sizes
// are those of the horizontal writing mode: inlineSize is the width. A box that is not rendered (display: none, not
// connected, a non-replaced inline) is 0 x 0. Layout is read through getBoundingClientRect (so a transform scales it, as
// in the viewport); the content box is that minus the padding and the borders (contentRect starts at the padding's offset). A target whose border box size did not
// change since the last update is not measured again: a change of padding alone, with a border box fixed by a
// width and box-sizing: border-box, is not seen.
(function (host) {
  "use strict";
  const PASSES = 4;
  const BOXES = ["content-box", "border-box", "device-pixel-content-box"];
  const REPLACED = new Set(["img", "video", "canvas", "iframe", "object", "embed", "input", "select", "textarea", "button", "audio", "svg", "meter", "progress"]);
  const active = new Set();   // observers with targets
  const PRIVATE = {};
  let dom = null;

  const getter = (proto, name) => Object.getOwnPropertyDescriptor(proto, name).get;
  // the DOM's own operations, read on first use (this runs at pre-initialization, before the realm's interfaces)
  function D() {
    if (dom === null) {
      dom = {
        rect: Element.prototype.getBoundingClientRect,
        rects: Element.prototype.getClientRects,
        isConnected: getter(Node.prototype, "isConnected"),
        style: globalThis.getComputedStyle,
        domRect: DOMRectReadOnly,
      };
    }
    return dom;
  }

  class ResizeObserverSize {
    #inline; #block;
    constructor(token, inline, block) {
      if (token !== PRIVATE) throw new TypeError("Illegal constructor");
      this.#inline = inline;
      this.#block = block;
    }
    get inlineSize() { return this.#inline; }
    get blockSize() { return this.#block; }
  }
  Object.defineProperty(ResizeObserverSize.prototype, Symbol.toStringTag, { value: "ResizeObserverSize", configurable: true });

  class ResizeObserverEntry {
    #target; #contentRect; #border; #content; #device;
    constructor(token, target, contentRect, border, content, device) {
      if (token !== PRIVATE) throw new TypeError("Illegal constructor");
      this.#target = target;
      this.#contentRect = contentRect;
      const size = (s) => Object.freeze([new ResizeObserverSize(PRIVATE, s.w, s.h)]);
      this.#border = size(border);
      this.#content = size(content);
      this.#device = size(device);
    }
    get target() { return this.#target; }
    get contentRect() { return this.#contentRect; }
    get borderBoxSize() { return this.#border; }
    get contentBoxSize() { return this.#content; }
    get devicePixelContentBoxSize() { return this.#device; }
  }
  Object.defineProperty(ResizeObserverEntry.prototype, Symbol.toStringTag, { value: "ResizeObserverEntry", configurable: true });

  const ZERO = { border: { w: 0, h: 0 }, content: { w: 0, h: 0 }, device: { w: 0, h: 0 }, left: 0, top: 0 };
  const px = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };

  // the three sizes of a target's boxes (and the content box's offset in the border box), measured now
  function measure(target, r) {
    const d = D();
    const cs = d.style.call(globalThis, target);
    if (cs.display === "inline" && !REPLACED.has(target.localName) && !(typeof SVGElement === "function" && target instanceof SVGElement)) return ZERO;
    const left = px(cs.paddingLeft), top = px(cs.paddingTop);
    const cw = Math.max(0, r.width - left - px(cs.borderLeftWidth) - px(cs.paddingRight) - px(cs.borderRightWidth));
    const ch = Math.max(0, r.height - top - px(cs.borderTopWidth) - px(cs.paddingBottom) - px(cs.borderBottomWidth));
    const dpr = globalThis.devicePixelRatio || 1;
    return {
      border: { w: r.width, h: r.height }, content: { w: cw, h: ch },
      device: { w: Math.round(cw * dpr), h: Math.round(ch * dpr) }, left, top,
    };
  }

  function sizeOf(m, box) { return box === "border-box" ? m.border : box === "device-pixel-content-box" ? m.device : m.content; }

  function create(obj, callback) {
    if (typeof callback !== "function") throw new TypeError("Failed to construct 'ResizeObserver': The callback provided as parameter 1 is not a function.");
    return { obj, callback, targets: new Map() };   // target -> { box, w, h (last reported), rw, rh (border box at the last look) }
  }

  function observe(st, target, options) {
    if (!(target instanceof Element)) throw new TypeError("Failed to execute 'observe' on 'ResizeObserver': parameter 1 is not of type 'Element'.");
    let box = "content-box";
    if (options !== undefined && options !== null) {
      if (typeof options !== "object" && typeof options !== "function") throw new TypeError("Failed to execute 'observe' on 'ResizeObserver': The provided value is not of type 'ResizeObserverOptions'.");
      if (options.box !== undefined) {
        box = String(options.box);
        if (!BOXES.includes(box)) throw new TypeError(`Failed to execute 'observe' on 'ResizeObserver': Failed to read the 'box' property from 'ResizeObserverOptions': The provided value '${box}' is not a valid enum value of type ResizeObserverBoxOptions.`);
      }
    }
    const prev = st.targets.get(target);
    if (prev !== undefined && prev.box === box) return;
    st.targets.set(target, { box, w: 0, h: 0, rw: -1, rh: -1 });
    active.add(st);
    host.schedule(true);
  }

  function unobserve(st, target) {
    if (!(target instanceof Element)) throw new TypeError("Failed to execute 'unobserve' on 'ResizeObserver': parameter 1 is not of type 'Element'.");
    st.targets.delete(target);
    if (st.targets.size === 0) active.delete(st);
    host.schedule(active.size > 0);
  }

  function disconnect(st) {
    st.targets.clear();
    active.delete(st);
    host.schedule(active.size > 0);
  }

  // "gather active resize observations": the entries of the targets whose observed box changed since they were reported
  function gather(st) {
    const d = D();
    const entries = [];
    for (const [target, ob] of st.targets) {
      let m;
      if (!d.isConnected.call(target) || d.rects.call(target).length === 0) {
        m = ZERO;
        ob.rw = -1; ob.rh = -1;   // measured again when it is rendered again
      } else {
        const r = d.rect.call(target);
        if (r.width === ob.rw && r.height === ob.rh) continue;
        m = measure(target, r);
        ob.rw = r.width; ob.rh = r.height;
      }
      const s = sizeOf(m, ob.box);
      if (s.w === ob.w && s.h === ob.h) continue;
      ob.w = s.w; ob.h = s.h;
      entries.push(new ResizeObserverEntry(PRIVATE, target, new d.domRect(m.left, m.top, m.content.w, m.content.h), m.border, m.content, m.device));
    }
    return entries;
  }

  function update() {
    if (active.size === 0) return;
    for (let pass = 0; pass < PASSES; pass++) {
      let delivered = false;
      for (const st of Array.from(active)) {
        if (!active.has(st)) continue;
        const entries = gather(st);
        if (entries.length === 0) continue;
        delivered = true;
        try { st.callback.call(st.obj, entries, st.obj); } catch (e) { host.report(e); }
      }
      if (!delivered) break;
    }
  }

  const states = new WeakMap();
  const state = (o, what) => {
    const st = states.get(o);
    if (st === undefined) throw new TypeError(`Failed to execute '${what}' on 'ResizeObserver': Illegal invocation`);
    return st;
  };

  class ResizeObserver {
    constructor(callback) {
      if (new.target === undefined) throw new TypeError("Failed to construct 'ResizeObserver': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
      if (arguments.length < 1) throw new TypeError("Failed to construct 'ResizeObserver': 1 argument required, but only 0 present.");
      states.set(this, create(this, callback));
    }
    observe(target, options) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'observe' on 'ResizeObserver': 1 argument required, but only 0 present.");
      observe(state(this, "observe"), target, options);
    }
    unobserve(target) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'unobserve' on 'ResizeObserver': 1 argument required, but only 0 present.");
      unobserve(state(this, "unobserve"), target);
    }
    disconnect() { disconnect(state(this, "disconnect")); }
  }
  Object.defineProperty(ResizeObserver.prototype, Symbol.toStringTag, { value: "ResizeObserver", configurable: true });

  for (const c of [ResizeObserver, ResizeObserverEntry, ResizeObserverSize]) {
    Object.defineProperty(globalThis, c.name, { value: c, writable: true, configurable: true, enumerable: false });
  }
  host.install({ update });
})(__wren_resize_host);
delete globalThis.__wren_resize_host;

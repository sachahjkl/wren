// IntersectionObserver (Intersection Observer §3) for the engine's glue (runtime/intersection.c). The browser calls
// `update` at each rendering update while some observer watches a target, after the animation frame callbacks; it
// computes every target's intersection with its root (the viewport, or the root element's box) grown by rootMargin,
// queues an entry when the threshold crossed or the intersecting state changed (and once at the first update after
// observe), and a task delivers them. Ancestors that clip between the target and the root (scrolling boxes) are not
// taken into account: the rectangles are the target's and the root's own.
(function (host) {
  "use strict";
  const active = new Set();   // observers with targets
  let notifyQueued = false;
  let dom = null;
  const getter = (proto, name) => Object.getOwnPropertyDescriptor(proto, name).get;
  // the DOM's own operations, read on first use (this runs at pre-initialization, before the realm's interfaces)
  function D() {
    if (dom === null) {
      dom = {
        rect: Element.prototype.getBoundingClientRect,
        rects: Element.prototype.getClientRects,
        isConnected: getter(Node.prototype, "isConnected"),
        contains: Node.prototype.contains,
        width: () => globalThis.innerWidth,
        height: () => globalThis.innerHeight,
      };
    }
    return dom;
  }

  // rootMargin / scrollMargin: one to four <length> or <percentage> (px or %), CSS margin order
  function parseMargin(text, what) {
    const parts = String(text).trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0 || parts.length > 4) throw new DOMException(`Failed to construct 'IntersectionObserver': ${what} must be specified in pixels or percent.`, "SyntaxError");
    const sides = parts.map((p) => {
      const m = /^(-?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(px|%)$/i.exec(p) || (p === "0" ? ["0", "0", "px"] : null);
      if (!m) throw new DOMException(`Failed to construct 'IntersectionObserver': ${what} must be specified in pixels or percent.`, "SyntaxError");
      return { v: Number(m[1]), pct: m[2] === "%" };
    });
    const [t, r = t, b = t, l = r] = sides;
    const all = [t, r, b, l];
    return { sides: all, text: all.map((s) => s.v + (s.pct ? "%" : "px")).join(" ") };
  }

  function create(obj, callback, options) {
    if (typeof callback !== "function") throw new TypeError("Failed to construct 'IntersectionObserver': The callback provided as parameter 1 is not a function.");
    if (options !== undefined && options !== null && typeof options !== "object") throw new TypeError("Failed to construct 'IntersectionObserver': The provided value is not of type 'IntersectionObserverInit'.");
    const o = options || {};
    const root = o.root === undefined ? null : o.root;
    if (root !== null && !(root instanceof Element) && !(root instanceof Document)) throw new TypeError("Failed to construct 'IntersectionObserver': The provided value is not of type '(Element or Document)'.");
    const margin = parseMargin(o.rootMargin === undefined ? "0px" : o.rootMargin, "rootMargin");
    const scroll = parseMargin(o.scrollMargin === undefined ? "0px" : o.scrollMargin, "scrollMargin");
    let list = o.threshold === undefined ? [0] : (typeof o.threshold === "object" && o.threshold !== null && Symbol.iterator in o.threshold ? Array.from(o.threshold, Number) : [Number(o.threshold)]);
    for (const t of list) {
      if (!(t >= 0 && t <= 1)) throw new RangeError("Failed to construct 'IntersectionObserver': Threshold values must be numbers between 0 and 1");
    }
    if (list.length === 0) list = [0];
    list.sort((a, b) => a - b);
    return {
      obj, callback, root,
      margin: margin.sides, rootMarginText: margin.text, scrollMarginText: scroll.text,
      thresholds: Object.freeze(list),
      delay: Math.trunc(Number(o.delay) || 0), trackVisibility: Boolean(o.trackVisibility),
      targets: new Map(),   // target -> { index: previous threshold index (-1 before the first update), intersecting }
      queue: [],
    };
  }

  function observe(st, target) {
    if (!(target instanceof Element)) throw new TypeError("Failed to execute 'observe' on 'IntersectionObserver': parameter 1 is not of type 'Element'.");
    if (st.targets.has(target)) return;
    st.targets.set(target, { index: -1, intersecting: false });
    active.add(st);
    host.schedule(true);
  }

  function unobserve(st, target) {
    if (!(target instanceof Element)) throw new TypeError("Failed to execute 'unobserve' on 'IntersectionObserver': parameter 1 is not of type 'Element'.");
    st.targets.delete(target);
    if (st.targets.size === 0) active.delete(st);
    host.schedule(active.size > 0);
  }

  function disconnect(st) {
    st.targets.clear();
    active.delete(st);
    host.schedule(active.size > 0);
  }

  function takeRecords(st) {
    const q = st.queue;
    st.queue = [];
    return q;
  }

  const rect = (x, y, w, h) => new DOMRectReadOnly(x, y, w, h);

  // the root's rectangle grown by its margin (percentages of the root's size), in viewport coordinates
  function rootBox(st) {
    const d = D();
    let x = 0, y = 0, w = d.width(), h = d.height();
    if (st.root instanceof Element) {
      const r = d.rect.call(st.root);
      x = r.x; y = r.y; w = r.width; h = r.height;
    }
    const m = st.margin.map((s, i) => (s.pct ? s.v / 100 * (i % 2 === 0 ? h : w) : s.v));
    return { x: x - m[3], y: y - m[0], w: w + m[1] + m[3], h: h + m[0] + m[2] };
  }

  function update() {
    if (active.size === 0) return;
    const d = D();
    const time = performance.now();
    let queued = false;
    for (const st of active) {
      const rb = rootBox(st);
      const rootConnected = st.root === null || st.root instanceof Document || d.isConnected.call(st.root);
      for (const [target, prev] of st.targets) {
        const tr = d.rect.call(target);
        // HTML "is rendered": connected, with boxes, and inside its root element
        const rendered = d.isConnected.call(target) && rootConnected && d.rects.call(target).length > 0 &&
          (!(st.root instanceof Element) || d.contains.call(st.root, target) && st.root !== target);
        let ix = 0, iy = 0, iw = 0, ih = 0, intersecting = false;
        if (rendered) {
          const x1 = Math.max(tr.x, rb.x), y1 = Math.max(tr.y, rb.y);
          const x2 = Math.min(tr.x + tr.width, rb.x + rb.w), y2 = Math.min(tr.y + tr.height, rb.y + rb.h);
          // edge-adjacent counts (a zero-area target or one touching the root's edge intersects)
          if (x2 >= x1 && y2 >= y1) { intersecting = true; ix = x1; iy = y1; iw = x2 - x1; ih = y2 - y1; }
        }
        const area = tr.width * tr.height;
        const ratio = intersecting ? (area > 0 ? Math.min(1, (iw * ih) / area) : 1) : 0;
        let index = 0;
        while (index < st.thresholds.length && st.thresholds[index] <= ratio) index++;
        if (index === prev.index && intersecting === prev.intersecting) continue;
        prev.index = index;
        prev.intersecting = intersecting;
        st.queue.push(host.entry({
          time,
          rootBounds: rendered || st.root === null ? rect(rb.x, rb.y, rb.w, rb.h) : null,
          boundingClientRect: rect(tr.x, tr.y, tr.width, tr.height),
          intersectionRect: rect(ix, iy, iw, ih),
          isIntersecting: intersecting,
          isVisible: false,
          intersectionRatio: ratio,
          target,
        }));
        queued = true;
      }
    }
    if (queued && !notifyQueued) notifyQueued = host.task(notify);
  }

  // "notify intersection observers": each observer with entries gets them
  function notify() {
    notifyQueued = false;
    for (const st of Array.from(active)) {
      if (st.queue.length === 0) continue;
      const entries = takeRecords(st);
      try { st.callback.call(st.obj, entries, st.obj); } catch (e) { host.report(e); }
    }
  }

  function entryInit(init) {
    if (init === null || typeof init !== "object") throw new TypeError("Failed to construct 'IntersectionObserverEntry': parameter 1 is not an object.");
    const need = (name) => {
      if (init[name] === undefined) throw new TypeError(`Failed to construct 'IntersectionObserverEntry': required member ${name} is undefined.`);
      return init[name];
    };
    const r = (v) => rect(Number(v.x) || 0, Number(v.y) || 0, Number(v.width) || 0, Number(v.height) || 0);
    const target = need("target");
    if (!(target instanceof Element)) throw new TypeError("Failed to construct 'IntersectionObserverEntry': member target is not of type 'Element'.");
    const rootBounds = need("rootBounds");
    return {
      time: Number(need("time")), rootBounds: rootBounds === null ? null : r(rootBounds),
      boundingClientRect: r(need("boundingClientRect")), intersectionRect: r(need("intersectionRect")),
      isIntersecting: Boolean(need("isIntersecting")), isVisible: Boolean(need("isVisible")),
      intersectionRatio: Number(need("intersectionRatio")), target,
    };
  }

  host.install({ create, observe, unobserve, disconnect, takeRecords, update, entryInit });
})(__wren_io_host);
delete globalThis.__wren_io_host;

// FontFace (CSS Font Loading): evaluated by web_fontface.odin the first time a script of the window reads `FontFace`. A face added
// to document.fonts is a @font-face rule in force (the browser loads it as any web font); its bytes, when given as a buffer, go by a blob: URL.
(function (native, global) {
  "use strict";
  const P = Promise, TE = TypeError, S = String, BlobC = global.Blob, URLC = global.URL, fetchF = global.fetch, DE = global.DOMException;
  const createObjectURL = URLC.createObjectURL;
  const { defineProperty, getOwnPropertyDescriptor, getPrototypeOf } = Object;
  const states = new WeakMap();
  const stateOf = o => {
    const s = states.get(o);
    if (s === undefined) throw new TE("Illegal invocation");
    return s;
  };
  const DESCRIPTORS = ["style", "weight", "stretch", "unicodeRange", "featureSettings", "variationSettings", "display", "ascentOverride", "descentOverride", "lineGapOverride"];
  const DEFAULTS = { style: "normal", weight: "normal", stretch: "normal", unicodeRange: "U+0-10FFFF", featureSettings: "normal", variationSettings: "normal", display: "auto", ascentOverride: "normal", descentOverride: "normal", lineGapOverride: "normal" };
  const CSS_NAMES = { style: "font-style", weight: "font-weight", stretch: "font-stretch", unicodeRange: "unicode-range", featureSettings: "font-feature-settings", variationSettings: "font-variation-settings", display: "font-display", ascentOverride: "ascent-override", descentOverride: "descent-override", lineGapOverride: "line-gap-override" };
  const quoted = s => '"' + S(s).replace(/["\\\n]/g, c => "\\" + (c === "\n" ? "a " : c)) + '"';
  const settle = (s, ok, value) => {
    s.status = ok ? "loaded" : "error";
    if (ok) s.resolve(value); else s.reject(value);
  };
  const urlsOf = src => {
    const out = [];
    const re = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)/g;
    for (let m = re.exec(src); m; m = re.exec(src)) out.push(m[1] ?? m[2] ?? m[3]);
    return out;
  };

  class FontFace {
    constructor(family, source, descriptors = {}) {
      if (arguments.length < 2) throw new TE("Failed to construct 'FontFace': 2 arguments required");
      const s = { family: S(family), status: "unloaded", rule: -1, src: "" };
      for (const k of DESCRIPTORS) {
        const v = descriptors === null || descriptors === undefined ? undefined : descriptors[k];
        s[k] = v === undefined ? DEFAULTS[k] : S(v);
      }
      s.loaded = new P((resolve, reject) => { s.resolve = resolve; s.reject = reject; });
      s.loaded.catch(() => {});   // (asking for it is the script's choice: nobody has to)
      states.set(this, s);
      if (typeof source === "string" || source instanceof S) {
        s.src = S(source);
        if (urlsOf(s.src).length === 0 && !/local\(/.test(s.src)) {
          settle(s, false, new DE("The source of a FontFace is not a valid source.", "SyntaxError"));
        }
      } else if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
        // (loaded from the start, as the specification has it for bytes)
        s.src = "url(" + quoted(createObjectURL(new BlobC([source]))) + ")";
        s.status = "loaded";
        s.resolve(this);
      } else {
        s.src = S(source);
        settle(s, false, new DE("The source of a FontFace is not a valid source.", "SyntaxError"));
      }
    }
    get family() { return stateOf(this).family; }
    set family(v) { stateOf(this).family = S(v); }
    get status() { return stateOf(this).status; }
    get loaded() { return stateOf(this).loaded; }
    load() {
      const s = stateOf(this);
      if (s.status !== "unloaded") return s.loaded;
      s.status = "loading";
      const urls = urlsOf(s.src);
      if (urls.length === 0) { settle(s, true, this); return s.loaded; }
      const tryNext = i => i >= urls.length
        ? settle(s, false, new DE("A network error occurred.", "NetworkError"))
        : fetchF(urls[i]).then(r => { if (r.ok) settle(s, true, this); else tryNext(i + 1); }, () => tryNext(i + 1));
      tryNext(0);
      return s.loaded;
    }
  }
  for (const k of DESCRIPTORS) {
    defineProperty(FontFace.prototype, k, {
      get() { return stateOf(this)[k]; },
      set(v) { stateOf(this)[k] = S(v); },
      enumerable: true, configurable: true,
    });
  }
  for (const k of ["family", "status", "loaded", "load"]) {
    const d = getOwnPropertyDescriptor(FontFace.prototype, k);
    d.enumerable = true;
    defineProperty(FontFace.prototype, k, d);
  }
  defineProperty(FontFace.prototype, Symbol.toStringTag, { value: "FontFace", configurable: true });

  // document.fonts: what it holds is in force
  const setProto = getPrototypeOf(global.document.fonts);
  const setAdd = setProto.add, setRemove = setProto.delete, setClear = setProto.clear;
  const inForce = s => {
    if (s.rule >= 0) return;
    let css = "@font-face{font-family:" + quoted(s.family) + ";src:" + s.src;
    for (const k of DESCRIPTORS) if (s[k] !== DEFAULTS[k]) css += ";" + CSS_NAMES[k] + ":" + s[k];
    s.rule = native.addRule(css + "}");
  };
  const operation = (name, fn, length) => {
    defineProperty(fn, "name", { value: name, configurable: true });
    defineProperty(fn, "length", { value: length, configurable: true });
    defineProperty(setProto, name, { value: fn, writable: true, enumerable: true, configurable: true });
  };
  const added = new Set();
  operation("add", { add(face) {
    const s = states.get(face);
    if (s === undefined) throw new TE("Failed to execute 'add' on 'FontFaceSet': parameter 1 is not of type 'FontFace'.");
    const r = setAdd.call(this, face);
    inForce(s);
    added.add(s);
    return r;
  } }.add, 1);
  operation("delete", { delete(face) {
    const s = states.get(face);
    const r = setRemove.call(this, face);
    if (s !== undefined && s.rule >= 0) { native.removeRule(s.rule); s.rule = -1; added.delete(s); }
    return r;
  } }.delete, 1);
  operation("clear", { clear() {
    for (const s of added) { native.removeRule(s.rule); s.rule = -1; }
    added.clear();
    return setClear.call(this);
  } }.clear, 0);
  return FontFace;
})

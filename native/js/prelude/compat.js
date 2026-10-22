// Small web platform pieces that pages probe or call without feature detection, written in JavaScript on top of what the
// browser has (runtime/web_compat.c calls `start` when a window's realm starts, once the interfaces exist):
//   document.fonts           a FontFaceSet without font faces of its own: ready, check, load, status, the Set methods
//                            (the page's web fonts load as always; this only keeps `await document.fonts.ready` working)
//   navigator.permissions    query(): PermissionStatus (granted for clipboard-write, prompt for clipboard-read and the
//                            powers a page can ask for, denied for the ones this browser lacks)
//   window.alert / confirm / prompt   no dialog is shown: they return what a dismissed one does (undefined, false, null)
//                            and say so on the console
//   window.visualViewport    the layout viewport (no pinch zoom: scale 1, no offset), with resize / scroll events
//   Element.scrollIntoViewIfNeeded   scrollIntoView when the element is not fully in the viewport (WebKit)
//   document.execCommand("copy" / "cut"), queryCommandSupported / queryCommandEnabled   the clipboard fallback pages use
(function (host) {
  "use strict";
  const PRIVATE = {};
  const hidden = (o, name, value) => Object.defineProperty(o, name, { value, writable: true, configurable: true, enumerable: false });
  const accessor = (o, name, get) => Object.defineProperty(o, name, { get, configurable: true, enumerable: true });
  const tag = (c, name) => Object.defineProperty(c.prototype, Symbol.toStringTag, { value: name, configurable: true });
  const handler = (c, name) => {
    const slots = new WeakMap();
    Object.defineProperty(c.prototype, name, {
      get() { return slots.has(this) ? slots.get(this) : null; },
      set(f) {
        const old = slots.get(this);
        if (typeof old === "function") this.removeEventListener(name.slice(2), old);
        const v = typeof f === "function" ? f : null;
        slots.set(this, v);
        if (v !== null) this.addEventListener(name.slice(2), v);
      },
      configurable: true, enumerable: true,
    });
  };

  // the classes extend EventTarget, which exists once the realm's interfaces do: made when the realm starts
  function start() {
  // ---- document.fonts ----
  class FontFaceSet extends EventTarget {
    #faces = new Set();
    #ready;
    constructor(token) {
      if (token !== PRIVATE) throw new TypeError("Illegal constructor");
      super();
      this.#ready = Promise.resolve(this);
    }
    get size() { return this.#faces.size; }
    get status() { return "loaded"; }
    get ready() { return this.#ready; }
    add(face) { this.#faces.add(face); return this; }
    delete(face) { return this.#faces.delete(face); }
    has(face) { return this.#faces.has(face); }
    clear() { this.#faces.clear(); }
    check(font, text) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'check' on 'FontFaceSet': 1 argument required, but only 0 present.");
      return true;
    }
    load(font, text) {
      if (arguments.length < 1) return Promise.reject(new TypeError("Failed to execute 'load' on 'FontFaceSet': 1 argument required, but only 0 present."));
      return Promise.resolve([]);
    }
    forEach(callback, thisArg) {
      if (typeof callback !== "function") throw new TypeError("Failed to execute 'forEach' on 'FontFaceSet': parameter 1 is not of type 'Function'.");
      for (const f of this.#faces) callback.call(thisArg, f, f, this);
    }
    values() { return this.#faces.values(); }
    keys() { return this.#faces.values(); }
    entries() { return this.#faces.entries(); }
    [Symbol.iterator]() { return this.#faces.values(); }
  }
  tag(FontFaceSet, "FontFaceSet");
  for (const n of ["onloading", "onloadingdone", "onloadingerror"]) handler(FontFaceSet, n);

  // ---- navigator.permissions ----
  const NAMES = ["geolocation", "notifications", "push", "midi", "camera", "microphone", "speaker-selection", "device-info",
    "background-fetch", "background-sync", "bluetooth", "persistent-storage", "ambient-light-sensor", "accelerometer",
    "gyroscope", "magnetometer", "clipboard-read", "clipboard-write", "screen-wake-lock", "nfc", "display-capture",
    "accessibility-events", "payment-handler", "storage-access", "top-level-storage-access", "window-management",
    "local-fonts", "idle-detection", "keyboard-lock", "pointer-lock", "captured-surface-control", "fullscreen"];
  const STATES = { "clipboard-write": "granted", "clipboard-read": "prompt", "persistent-storage": "prompt", "storage-access": "prompt", "fullscreen": "granted" };

  class PermissionStatus extends EventTarget {
    #name; #state;
    constructor(token, name, state) {
      if (token !== PRIVATE) throw new TypeError("Illegal constructor");
      super();
      this.#name = name;
      this.#state = state;
    }
    get name() { return this.#name; }
    get state() { return this.#state; }
  }
  tag(PermissionStatus, "PermissionStatus");
  handler(PermissionStatus, "onchange");

  class Permissions {
    constructor(token) { if (token !== PRIVATE) throw new TypeError("Illegal constructor"); }
    query(descriptor) {
      if (arguments.length < 1) return Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': 1 argument required, but only 0 present."));
      if (descriptor === null || (typeof descriptor !== "object" && typeof descriptor !== "function")) {
        return Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': parameter 1 is not of type 'PermissionDescriptor'."));
      }
      const name = descriptor.name === undefined ? undefined : String(descriptor.name);
      if (name === undefined) return Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': Failed to read the 'name' property from 'PermissionDescriptor': Required member is undefined."));
      if (!NAMES.includes(name)) return Promise.reject(new TypeError(`Failed to execute 'query' on 'Permissions': Failed to read the 'name' property from 'PermissionDescriptor': The provided value '${name}' is not a valid enum value of type PermissionName.`));
      return Promise.resolve(new PermissionStatus(PRIVATE, name, STATES[name] || "denied"));
    }
  }
  tag(Permissions, "Permissions");

  // ---- window.visualViewport ----
  class VisualViewport extends EventTarget {
    constructor(token) {
      if (token !== PRIVATE) throw new TypeError("Illegal constructor");
      super();
    }
    get offsetLeft() { return 0; }
    get offsetTop() { return 0; }
    get pageLeft() { return globalThis.scrollX; }
    get pageTop() { return globalThis.scrollY; }
    get width() { return document.documentElement.clientWidth; }
    get height() { return document.documentElement.clientHeight; }
    get scale() { return 1; }
  }
  tag(VisualViewport, "VisualViewport");
  handler(VisualViewport, "onresize");
  handler(VisualViewport, "onscroll");
  handler(VisualViewport, "onscrollend");

  function selectedText() {
    const a = document.activeElement;
    if (a && (a.localName === "input" || a.localName === "textarea") && typeof a.selectionStart === "number" && a.selectionStart !== a.selectionEnd) {
      return { text: a.value.substring(a.selectionStart, a.selectionEnd), control: a };
    }
    const s = globalThis.getSelection ? globalThis.getSelection() : null;
    return { text: s ? String(s) : "", control: null };
  }

    // document.fonts
    // (made on first use: an EventTarget is made by a browser call, and the realm starts before it may make one)
    let fonts = null;
    accessor(Document.prototype, "fonts", () => (fonts ||= new FontFaceSet(PRIVATE)));

    // navigator.permissions
    let permissions = null;
    accessor(Navigator.prototype, "permissions", () => (permissions ||= new Permissions(PRIVATE)));

    // dialogs that are not shown
    const quiet = (what) => console.warn(`${what}: this browser shows no dialogs`);
    hidden(globalThis, "alert", function alert(message) { quiet("alert(" + (arguments.length ? String(message) : "") + ")"); });
    hidden(globalThis, "confirm", function confirm(message) { quiet("confirm(" + (arguments.length ? String(message) : "") + ")"); return false; });
    hidden(globalThis, "prompt", function prompt(message, value) { quiet("prompt(" + (arguments.length ? String(message) : "") + ")"); return null; });

    // visualViewport
    let vv = null;
    accessor(globalThis, "visualViewport", () => {
      if (vv === null) {
        vv = new VisualViewport(PRIVATE);
        globalThis.addEventListener("resize", () => vv.dispatchEvent(new Event("resize")));
        globalThis.addEventListener("scroll", () => vv.dispatchEvent(new Event("scroll")));
      }
      return vv;
    });

    // WebKit's scrollIntoViewIfNeeded
    hidden(Element.prototype, "scrollIntoViewIfNeeded", function scrollIntoViewIfNeeded(centerIfNeeded) {
      const r = this.getBoundingClientRect();
      const inside = r.top >= 0 && r.left >= 0 && r.bottom <= document.documentElement.clientHeight && r.right <= document.documentElement.clientWidth;
      if (!inside) this.scrollIntoView({ block: centerIfNeeded === false ? "nearest" : "center", inline: "nearest" });
    });

    // the clipboard fallback of pages: execCommand("copy" | "cut")
    const KNOWN = new Set(["copy", "cut"]);
    hidden(Document.prototype, "execCommand", function execCommand(command, showUI, value) {
      const c = String(command).toLowerCase();
      if (!KNOWN.has(c)) return false;
      const sel = selectedText();
      if (sel.text === "") return false;
      let ok = true;
      if (navigator.clipboard) navigator.clipboard.writeText(sel.text).catch(() => {});
      else ok = false;
      if (ok && c === "cut" && sel.control !== null && !sel.control.readOnly && !sel.control.disabled) sel.control.setRangeText("");
      return ok;
    });
    hidden(Document.prototype, "queryCommandSupported", function queryCommandSupported(command) { return KNOWN.has(String(command).toLowerCase()); });
    hidden(Document.prototype, "queryCommandEnabled", function queryCommandEnabled(command) {
      const c = String(command).toLowerCase();
      return KNOWN.has(c) && selectedText().text !== "";
    });

    for (const c of [FontFaceSet, PermissionStatus, Permissions, VisualViewport]) hidden(globalThis, c.name, c);
  }
  host.install({ start });
})(__wren_compat_host);
delete globalThis.__wren_compat_host;

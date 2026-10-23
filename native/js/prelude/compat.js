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

    // ---- what the developer tools see of the console ----
    // While the panel is open (the host sets `on` on the object kept under Symbol.for("wren.devtools")), each console call
    // first sends a description of its arguments, as JSON (strings, numbers, objects with their properties, Maps, Sets, DOM
    // nodes, errors with their stacks, tables), through console.debug with a prefix the shell recognizes; the console call
    // itself then goes on as it always did, and its text is the line the description belongs to. `eval` runs a console
    // expression and `complete` lists the names of an object, both answering the same way.
    (function () {
      const c = globalThis.console;
      if (!c || typeof c.log !== "function") return;
      const state = { on: false, max: 262144 };
      hidden(c, Symbol.for("wren.devtools"), state);
      const orig = {};
      const names = ["log", "info", "warn", "error", "debug", "dir", "dirxml", "table", "assert", "trace"];
      for (const m of names) orig[m] = c[m];
      const send = (tag, json) => { if (json.length > state.max) return false; orig.debug.call(c, "\u0001" + tag + ":" + json); return true; };
      const str = (s) => JSON.stringify(s.length > 1000 ? s.slice(0, 1000) + "\u2026" : s);
      const MAXKEYS = 100, MAXDEPTH = 4;
      const classOf = (v) => {
        try { const k = v.constructor; if (typeof k === "function" && k.name) return k.name; } catch (e) {}
        return Object.prototype.toString.call(v).slice(8, -1);
      };
      const fdesc = (f) => {
        let s = "";
        try { s = Function.prototype.toString.call(f); } catch (e) {}
        const m = /^[^{]*?\(([^)]*)\)/.exec(s);
        const cls = /^\s*class\b/.test(s);
        return (cls ? "class " : "") + (f.name || "(anonymous)") + (cls ? "" : "(" + (m ? m[1].replace(/\s+/g, " ").trim() : "") + ")");
      };
      const domdesc = (n) => {
        try {
          if (n.nodeType === 1) {
            let s = "<" + n.localName;
            if (n.id) s += ' id="' + n.id + '"';
            if (n.className && typeof n.className === "string") s += ' class="' + n.className + '"';
            return s + ">";
          }
          if (n.nodeType === 3) return '#text "' + String(n.data).slice(0, 60) + '"';
          if (n.nodeType === 8) return "<!--" + String(n.data).slice(0, 60) + "-->";
          if (n.nodeType === 9) return "#document";
          return n.nodeName;
        } catch (e) { return "Node"; }
      };
      function node(v, depth, seen, b) {
        switch (typeof v) {
          case "string": return '{"t":"s","v":' + str(v) + "}";
          case "number": return '{"t":"n","v":"' + (Object.is(v, -0) ? "-0" : String(v)) + '"}';
          case "boolean": return '{"t":"b","v":' + v + "}";
          case "undefined": return '{"t":"u"}';
          case "bigint": return '{"t":"i","v":"' + v + 'n"}';
          case "symbol": return '{"t":"y","v":' + str(String(v)) + "}";
          case "function": return '{"t":"f","d":' + str(fdesc(v)) + "}";
        }
        if (v === null) return '{"t":"z"}';
        if (seen.indexOf(v) >= 0) return '{"t":"c"}';
        return obj(v, depth, seen, b);
      }
      function obj(v, depth, seen, b) {
        b.n -= 1;
        let cls = "Object";
        try { cls = Array.isArray(v) ? "Array" : classOf(v); } catch (e) {}
        try {
          if (v instanceof Error) return '{"t":"x","c":' + str(cls) + ',"d":' + str(String(v)) + ',"st":' + str(String(v.stack || "")) + "}";
          if (typeof Node !== "undefined" && v instanceof Node) return '{"t":"d","d":' + str(domdesc(v)) + "}";
          if (v instanceof Date) return '{"t":"o","c":"Date","d":' + str(isNaN(v) ? "Invalid Date" : v.toISOString()) + "}";
          if (v instanceof RegExp) return '{"t":"o","c":"RegExp","d":' + str(String(v)) + "}";
        } catch (e) {}
        const open = depth < MAXDEPTH && b.n > 0;
        let out = '{"t":"o","c":' + str(cls);
        seen.push(v);
        try {
          if (v instanceof Map) {
            out += ',"m":' + v.size;
            if (open) {
              out += ',"p":[';
              let i = 0;
              for (const [k, val] of v) { if (i >= MAXKEYS) { out += "],\"x\":" + (v.size - MAXKEYS) + ',"p2":['; break; } out += (i ? "," : "") + "[" + node(k, depth + 1, seen, b) + "," + node(val, depth + 1, seen, b) + "]"; i++; }
              out += "]";
            }
          } else if (v instanceof Set) {
            out += ',"m":' + v.size;
            if (open) {
              out += ',"p":[';
              let i = 0;
              for (const val of v) { if (i >= MAXKEYS) break; out += (i ? "," : "") + "[" + '{"t":"s","v":""}' + "," + node(val, depth + 1, seen, b) + "]"; i++; }
              out += "]";
              if (v.size > MAXKEYS) out += ',"x":' + (v.size - MAXKEYS);
            }
          } else if (Array.isArray(v) || ArrayBuffer.isView(v)) {
            const n = v.length;
            out += ',"m":' + n;
            if (open) {
              out += ',"p":[';
              for (let i = 0; i < n && i < MAXKEYS; i++) out += (i ? "," : "") + "[" + str(String(i)) + "," + node(v[i], depth + 1, seen, b) + "]";
              out += "]";
              if (n > MAXKEYS) out += ',"x":' + (n - MAXKEYS);
            }
          } else {
            const keys = Object.keys(v);
            out += ',"m":' + keys.length;
            if (open) {
              out += ',"p":[';
              let i = 0;
              for (const k of keys) {
                if (i >= MAXKEYS) break;
                let val;
                try { const d = Object.getOwnPropertyDescriptor(v, k); val = d && "value" in d ? d.value : "(...)"; } catch (e) { val = "(error)"; }
                out += (i ? "," : "") + "[" + str(k) + "," + (val === "(...)" ? '{"t":"a"}' : node(val, depth + 1, seen, b)) + "]";
                i++;
              }
              out += "]";
              if (keys.length > MAXKEYS) out += ',"x":' + (keys.length - MAXKEYS);
            }
          }
        } catch (e) {}
        seen.pop();
        return out + "}";
      }
      const where = () => {
        try {
          const lines = String(new Error().stack).split("\n");
          for (const l of lines) { if (l.indexOf("compat.js") < 0 && /\(?[^()\s]+:\d+(:\d+)?\)?\s*$/.test(l)) return l.trim().replace(/^at\s+/, "").replace(/^[^(]*\(/, "").replace(/\)$/, ""); }
        } catch (e) {}
        return "";
      };
      const table = (data, cols) => {
        if (data === null || typeof data !== "object") return null;
        const rows = [], keys = [];
        let hasValues = false;
        const add = (idx, row) => {
          const r = { i: idx, cells: {} };
          if (row !== null && typeof row === "object") { for (const k of Object.keys(row)) { if (keys.indexOf(k) < 0) keys.push(k); r.cells[k] = row[k]; } }
          else { r.value = row; hasValues = true; }
          rows.push(r);
        };
        if (data instanceof Map) { let i = 0; for (const [k, v] of data) add(String(i++), v); }
        else if (data instanceof Set) { let i = 0; for (const v of data) add(String(i++), v); }
        else { let i = 0; for (const k of Object.keys(data)) { if (i++ >= 200) break; add(k, data[k]); } }
        const use = Array.isArray(cols) ? cols.map(String) : keys.slice(0, 40);
        let out = '{"cols":[' + use.map(str).join(",") + "]," + '"values":' + hasValues + ',"rows":[';
        out += rows.map((r) => '{"i":' + str(r.i) + ',"v":' + (r.value !== undefined || "value" in r ? node(r.value, MAXDEPTH, [], { n: 50 }) : "null") + ',"c":[' + use.map((k) => (k in r.cells ? node(r.cells[k], MAXDEPTH, [], { n: 50 }) : "null")).join(",") + "]}").join(",") + "]}";
        return out;
      };
      for (const m of ["log", "info", "warn", "error", "debug", "dir", "dirxml"]) {
        const f = orig[m];
        const wrapper = {
          [m](...args) {
            if (state.on) {
              try {
                const b = { n: 400 };
                send("dt", '{"l":"' + (m === "dir" || m === "dirxml" ? "log" : m) + '","w":' + str(where()) + ',"a":[' + args.map((a) => node(a, 0, [], b)).join(",") + "]}");
              } catch (e) {}
            }
            return f.apply(this === undefined ? c : this, args);
          },
        }[m];
        hidden(c, m, wrapper);
      }
      {
        const f = orig.table;
        hidden(c, "table", { table(data, cols) {
          if (state.on) { try { const t = table(data, cols); if (t) send("dt", '{"l":"log","w":' + str(where()) + ',"tbl":' + t + "}"); } catch (e) {} }
          return f.apply(this === undefined ? c : this, arguments);
        } }.table);
      }
      {
        const f = orig.assert;
        hidden(c, "assert", { assert(cond, ...args) {
          if (state.on && !cond) { try { send("dt", '{"l":"error","w":' + str(where()) + ',"a":[' + ['Assertion failed'].concat(args).map((a) => node(a, 0, [], { n: 200 })).join(",") + "]}"); } catch (e) {} }
          return f.apply(this === undefined ? c : this, arguments);
        } }.assert);
      }
      // a console expression: the value of `src` evaluated in the global scope, shown like a console message
      state.eval = function (src) {
        let r, thrown = false;
        try { r = (0, eval)(String(src)); } catch (e) {
          if (e instanceof SyntaxError && /\bawait\b/.test(src)) {
            try { r = (0, eval)("(async () => (" + src + "\n))()"); } catch (e2) { r = e; thrown = true; }
          } else { r = e; thrown = true; }
        }
        const show = (val, err) => {
          try { send("dt", '{"l":"' + (err ? "error" : "result") + '","a":[' + node(val, 0, [], { n: 600 }) + "]}"); } catch (e) {}
          let text;
          try { text = err ? String(val && val.stack || val) : (typeof val === "string" ? JSON.stringify(val) : (typeof val === "function" ? fdesc(val) : String(val))); } catch (e) { text = "[object]"; }
          (err ? orig.error : orig.info).call(c, text);
        };
        if (!thrown && r && typeof r.then === "function" && typeof r !== "function") { show(r, false); r.then((v) => show(v, false), (e) => show(e, true)); return; }
        show(r, thrown);
      };
      // the names an expression offers: own and inherited, enumerable first
      state.complete = function (path) {
        let o;
        try { o = path === "" ? globalThis : (0, eval)(path); } catch (e) { return; }
        if (o === null || o === undefined) return;
        const seen = new Set(), list = [];
        let p = Object(o), depth = 0;
        while (p && depth++ < 8) {
          for (const k of Object.getOwnPropertyNames(p)) { if (!seen.has(k) && list.length < 400) { seen.add(k); list.push(k); } }
          p = Object.getPrototypeOf(p);
        }
        orig.debug.call(c, "\u0001dtc:" + JSON.stringify(list));
      };
    })();
    for (const c of [FontFaceSet, PermissionStatus, Permissions, VisualViewport]) hidden(globalThis, c.name, c);
  }
  host.install({ start });
})(__wren_compat_host);
delete globalThis.__wren_compat_host;

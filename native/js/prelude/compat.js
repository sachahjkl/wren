// What stays in JavaScript of the small web platform pieces (the others - document.fonts, navigator.permissions, dialogs,
// visualViewport, scrollIntoViewIfNeeded, the WebKit-prefixed Fullscreen API - are native: runtime/web_compat.c, which also
// calls `start` when a window's realm starts, once the interfaces exist on the global object):
//   document.execCommand("copy" / "cut"), queryCommandSupported / queryCommandEnabled   the clipboard fallback pages use
//       (glue between the page's selection and navigator.clipboard, both seen through their JavaScript objects)
//   the description of console arguments for the developer tools (below)
(function (host) {
  "use strict";
  const hidden = (o, name, value) => Object.defineProperty(o, name, { value, writable: true, configurable: true, enumerable: false });

  function start() {
    function selectedText() {
      const a = document.activeElement;
      if (a && (a.localName === "input" || a.localName === "textarea") && typeof a.selectionStart === "number" && a.selectionStart !== a.selectionEnd) {
        return { text: a.value.substring(a.selectionStart, a.selectionEnd), control: a };
      }
      const s = globalThis.getSelection ? globalThis.getSelection() : null;
      return { text: s ? String(s) : "", control: null };
    }

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
      const state = { on: false, max: 262144, refs: new Map(), rid: 0, temps: 0 };
      // the arguments of the last console calls stay reachable (by the id in their description) for "Store as global variable" and "Copy object"
      const keep = (args) => { const id = ++state.rid; state.refs.set(id, args); if (state.refs.size > 300) state.refs.delete(state.refs.keys().next().value); return id; };
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
      // the wrappers keep the descriptor of a namespace operation (Web IDL: writable, enumerable, configurable) and its length 0
      const op = (name, value) => Object.defineProperty(c, name, { value, writable: true, configurable: true, enumerable: true });
      for (const m of ["log", "info", "warn", "error", "debug", "dir", "dirxml"]) {
        const f = orig[m];
        const wrapper = {
          [m](...args) {
            if (state.on) {
              try {
                const b = { n: 400 };
                send("dt", '{"l":"' + (m === "dir" || m === "dirxml" ? "log" : m) + '","r":' + keep(args) + ',"w":' + str(where()) + ',"a":[' + args.map((a) => node(a, 0, [], b)).join(",") + "]}");
              } catch (e) {}
            }
            return f.apply(this === undefined ? c : this, args);
          },
        }[m];
        op(m, wrapper);
      }
      {
        const f = orig.table;
        op("table", { table(...a) {
          const [data, cols] = a;
          if (state.on) { try { const t = table(data, cols); if (t) send("dt", '{"l":"log","r":' + keep([data]) + ',"w":' + str(where()) + ',"tbl":' + t + "}"); } catch (e) {} }
          return f.apply(this === undefined ? c : this, a);
        } }.table);
      }
      {
        const f = orig.assert;
        op("assert", { assert(...a) {
          const cond = a[0], args = a.slice(1);
          if (state.on && !cond) { try { send("dt", '{"l":"error","r":' + keep(args) + ',"w":' + str(where()) + ',"a":[' + ['Assertion failed'].concat(args).map((a) => node(a, 0, [], { n: 200 })).join(",") + "]}"); } catch (e) {} }
          return f.apply(this === undefined ? c : this, a);
        } }.assert);
      }
      // a value shown like a console message: its description for the tree, then its text
      const show = (val, err) => {
        if (state.on) try { send("dt", '{"l":"' + (err ? "error" : "result") + '","r":' + keep([val]) + ',"a":[' + node(val, 0, [], { n: 600 }) + "]}"); } catch (e) {}
        let text;
        try { text = err ? String(val && val.stack || val) : (typeof val === "string" ? JSON.stringify(val) : (typeof val === "function" ? fdesc(val) : String(val))); } catch (e) { text = "[object]"; }
        (err ? orig.error : orig.info).call(c, text);
      };
      // a console expression: the value of `src` evaluated in the global scope, shown like a console message
      state.eval = function (src) {
        let r, thrown = false;
        try { r = (0, eval)(String(src)); } catch (e) {
          if (e instanceof SyntaxError && /\bawait\b/.test(src)) {
            try { r = (0, eval)("(async () => (" + src + "\n))()"); } catch (e2) { r = e; thrown = true; }
          } else { r = e; thrown = true; }
        }
        if (!thrown && r && typeof r.then === "function" && typeof r !== "function") { show(r, false); r.then((v) => show(v, false), (e) => show(e, true)); return; }
        show(r, thrown);
      };
      // a value kept under a global name (`temp1`, `temp2`...), as "Store as global variable" does, and shown as if it had been typed
      const store = (v) => {
        const name = "temp" + (++state.temps);
        try { Object.defineProperty(globalThis, name, { value: v, writable: true, configurable: true, enumerable: false }); } catch (e) { return; }
        orig.log.call(c, "> " + name);
        show(v, false);
      };
      const pick = (id) => {
        const a = state.refs.get(id);
        if (!a || !a.length) return undefined;
        for (const x of a) { if (x !== null && (typeof x === "object" || typeof x === "function")) return { v: x }; }
        return { v: a[0] };
      };
      state.store = function (id) { const p = pick(id); if (p) store(p.v); };
      state.storeNode = function (path) {
        let n = document;
        for (const i of path) n = n && n.childNodes[i];
        if (n) store(n);
      };
      // the value as JSON text (cycles marked, Maps, Sets, errors and nodes in a readable form), sent to the shell for the clipboard
      state.copy = function (id) {
        const p = pick(id);
        if (!p) return;
        const v = p.v, stack = [];
        const text = (function () {
          if (typeof v === "string") return v;
          if (typeof v === "undefined") return "undefined";
          if (typeof v === "function") { try { return Function.prototype.toString.call(v); } catch (e) { return String(v); } }
          try {
            return JSON.stringify(v, function (k, x) {
              while (stack.length && stack[stack.length - 1] !== this) stack.pop();
              if (typeof x === "bigint") return x + "n";
              if (typeof x === "function") return undefined;
              if (typeof x === "symbol") return String(x);
              if (x !== null && typeof x === "object") {
                if (typeof Node !== "undefined" && x instanceof Node) return x.nodeType === 1 ? x.outerHTML : String(x.nodeValue !== null ? x.nodeValue : x.nodeName);
                if (x instanceof Error) return { name: x.name, message: x.message, stack: x.stack };
                if (stack.indexOf(x) >= 0) return "[Circular]";
                stack.push(x);
                if (x instanceof Map) return Array.from(x.entries());
                if (x instanceof Set) return Array.from(x.values());
              }
              return x;
            }, 2);
          } catch (e) { return String(v); }
        })();
        orig.debug.call(c, "\u0001dtx:" + text);
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
  }
  host.install({ start });
})(__wren_compat_host);
delete globalThis.__wren_compat_host;

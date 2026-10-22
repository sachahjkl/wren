// ClipboardItem and Clipboard.read / Clipboard.write (Clipboard API, "async clipboard"), on top of the browser's
// writeText / readText (runtime/web_clipboard.c binds the two methods to `read` and `write` here). Only text/plain
// goes through the system clipboard: an item with another type is accepted, but write() keeps text/plain and rejects
// when there is none (NotAllowedError, as for a type the browser cannot put on the clipboard), and read() gives one
// item with the clipboard's text.
(function (host) {
  "use strict";
  const SUPPORTED = ["text/plain"];
  const styles = ["unspecified", "inline", "attachment"];
  const data = new WeakMap();   // ClipboardItem -> { map: Map(type -> Promise), types, style }

  class ClipboardItem {
    constructor(items, options) {
      if (arguments.length < 1) throw new TypeError("Failed to construct 'ClipboardItem': 1 argument required, but only 0 present.");
      if (items === null || typeof items !== "object") throw new TypeError("Failed to construct 'ClipboardItem': The provided value is not of type 'record<DOMString, ClipboardItemData>'.");
      const keys = Object.keys(items);
      if (keys.length === 0) throw new TypeError("Failed to construct 'ClipboardItem': At least one entry must be provided");
      let style = "unspecified";
      if (options !== undefined && options !== null) {
        if (typeof options !== "object") throw new TypeError("Failed to construct 'ClipboardItem': The provided value is not of type 'ClipboardItemOptions'.");
        if (options.presentationStyle !== undefined) {
          style = String(options.presentationStyle);
          if (!styles.includes(style)) throw new TypeError(`Failed to construct 'ClipboardItem': The provided value '${style}' is not a valid enum value of type PresentationStyle.`);
        }
      }
      const map = new Map();
      for (const k of keys) map.set(String(k), Promise.resolve(items[k]));
      data.set(this, { map, types: Object.freeze(Array.from(map.keys())), style });
    }
    get presentationStyle() { return state(this).style; }
    get types() { return state(this).types; }
    getType(type) {
      let st;
      try { st = state(this); } catch (e) { return Promise.reject(e); }
      type = String(type);
      const p = st.map.get(type);
      if (p === undefined) return Promise.reject(new DOMException("Failed to execute 'getType' on 'ClipboardItem': The type was not found", "NotFoundError"));
      return p.then((v) => (typeof v === "string" ? new Blob([v], { type }) : v));
    }
    static supports(type) { return SUPPORTED.includes(String(type).toLowerCase()); }
  }
  Object.defineProperty(ClipboardItem.prototype, Symbol.toStringTag, { value: "ClipboardItem", configurable: true });

  function state(item) {
    const st = data.get(item);
    if (st === undefined) throw new TypeError("Illegal invocation");
    return st;
  }

  const proto = () => Object.getPrototypeOf(navigator.clipboard);
  const originals = {};
  const original = (name) => (originals[name] ||= proto()[name]);

  function write(clipboard, items) {
    try {
      if (items === null || typeof items !== "object" || !(Symbol.iterator in items)) {
        throw new TypeError("Failed to execute 'write' on 'Clipboard': The provided value cannot be converted to a sequence.");
      }
      const list = Array.from(items);
      for (const it of list) {
        if (!data.has(it)) throw new TypeError("Failed to execute 'write' on 'Clipboard': Failed to read the 'ClipboardItem' sequence: Failed to convert element to 'ClipboardItem'.");
      }
      if (list.length !== 1) {
        return Promise.reject(new DOMException(list.length === 0 ? "Failed to execute 'write' on 'Clipboard': There is no item to write." : "Failed to execute 'write' on 'Clipboard': Support for multiple ClipboardItems is not implemented.", "NotAllowedError"));
      }
      const st = data.get(list[0]);
      const plain = st.map.get("text/plain");
      if (plain === undefined) {
        const t = Array.from(st.map.keys())[0];
        return Promise.reject(new DOMException(`Failed to execute 'write' on 'Clipboard': Type ${t} does not match the blob's type or is not supported.`, "NotAllowedError"));
      }
      return plain.then((v) => (typeof v === "string" ? v : v.text())).then((text) => original("writeText").call(clipboard, text));
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function read(clipboard) {
    return original("readText").call(clipboard).then((text) => (text === ""
      ? []
      : [new ClipboardItem({ "text/plain": new Blob([text], { type: "text/plain" }) })]));
  }

  Object.defineProperty(globalThis, "ClipboardItem", { value: ClipboardItem, writable: true, configurable: true, enumerable: false });
  host.install({ read, write });
})(__wren_clipboard_host);
delete globalThis.__wren_clipboard_host;

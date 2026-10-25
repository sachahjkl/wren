// navigator and screen.

test("navigator", async () => {
  ok(navigator === navigator && navigator === window.clientInformation, "one Navigator");
  console.log("UA " + navigator.userAgent);
  eq(navigator.appCodeName, "Mozilla", "appCodeName");
  eq(navigator.appName, "Netscape", "appName");
  eq(navigator.product, "Gecko", "product");
  eq(navigator.platform, "Win32", "platform (navigator.platform)");
  eq(navigator.vendor, "", "vendor (navigator.vendor)");
  ok(typeof navigator.appVersion === "string", "appVersion");
  const langs = navigator.languages;
  ok(Array.isArray(langs) && langs.length > 0, "languages");
  ok(Object.isFrozen(langs), "languages is frozen");
  ok(langs === navigator.languages, "the same array while unchanged");
  eq(navigator.language, langs[0], "language is the first");
  ok(!langs.some(l => l.includes(";")), "no quality values");
  eq(typeof navigator.onLine, "boolean", "onLine");
  eq(navigator.cookieEnabled, true, "cookieEnabled on http");
  ok(navigator.hardwareConcurrency >= 1, "hardwareConcurrency");
  eq(navigator.maxTouchPoints, 0, "maxTouchPoints");
  eq(navigator.webdriver, false, "webdriver");
  eq(navigator.pdfViewerEnabled, false, "pdfViewerEnabled");
  eq(navigator.javaEnabled(), false, "javaEnabled");
  eq(navigator.doNotTrack, null, "doNotTrack (privacy.do_not_track)");
  eq(navigator.plugins.length, 0, "no plugins");
  eq(navigator.serviceWorker instanceof ServiceWorkerContainer, true, "serviceWorker is a ServiceWorkerContainer (tools\\sw_e2e.ps1 tests it)");
  eq("clipboard" in navigator, true, "clipboard is present (a secure context)");
  eq("geolocation" in navigator, false, "geolocation is absent");
  ok(navigator instanceof Navigator, "a Navigator");
});

test("sendBeacon", async () => {
  const before = (await (await fetch("/jsweb/beacon-log")).text()).split("|")[0] | 0;
  eq(navigator.sendBeacon("/jsweb/beacon", "beacon data"), true, "queued");
  let log = "";
  for (let i = 0; i < 1000; i++) {   // until the server has it: the bound only ends a failing run
    log = await (await fetch("/jsweb/beacon-log")).text();
    if ((log.split("|")[0] | 0) > before) break;
    await sleep(20);
  }
  const [count, body, type] = log.split("|");
  eq(count | 0, before + 1, "the server got it");
  eq(body, "beacon data", "its body");
  eq(type, "text/plain;charset=UTF-8", "its Content-Type");
  eq(navigator.sendBeacon("/jsweb/beacon", "x".repeat(70000)), false, "over navigator.beacon_max_bytes");
  throws(() => navigator.sendBeacon("ftp://x/"), "TypeError", "only http(s)");
});

test("screen", () => {
  ok(screen === window.screen, "one Screen");
  ok(screen.width > 0 && screen.height > 0, "width, height");
  ok(screen.availWidth > 0 && screen.availWidth <= screen.width, "availWidth");
  ok(screen.availHeight > 0 && screen.availHeight <= screen.height, "availHeight");
  eq(screen.colorDepth, 24, "colorDepth");
  eq(screen.pixelDepth, 24, "pixelDepth");
});

test("clipboard", async () => {
  const cb = navigator.clipboard;
  ok(cb === navigator.clipboard && cb instanceof Clipboard, "one Clipboard, [SameObject]");
  eq(typeof cb.writeText, "function", "writeText");
  const w = cb.writeText("hello \u2713 clip");
  ok(w instanceof Promise, "writeText returns a promise");
  eq(await w, undefined, "writeText fulfils with undefined");
  eq(await cb.readText(), "hello \u2713 clip", "readText gives the text back");
  await cb.writeText("");
  eq(await cb.readText(), "", "an empty clipboard reads as an empty string");
  eq((await cb.read()).length, 0, "read(): no item for an empty clipboard");

  eq(typeof ClipboardItem, "function", "ClipboardItem");
  eq(ClipboardItem.supports("text/plain"), true, "supports text/plain");
  eq(ClipboardItem.supports("application/x-nothing"), false, "supports an unknown type");
  const item = new ClipboardItem({ "text/plain": new Blob(["blob text"], { type: "text/plain" }) });
  eq(item.types.join(), "text/plain", "item.types");
  ok(Object.isFrozen(item.types), "types is frozen");
  eq(item.presentationStyle, "unspecified", "presentationStyle");
  eq(await (await item.getType("text/plain")).text(), "blob text", "getType gives a Blob");
  await rejects(item.getType("text/html"), "NotFoundError", "getType of a type the item lacks");
  await cb.write([item]);
  eq(await cb.readText(), "blob text", "write([item]) puts its text/plain on the clipboard");
  const items = await cb.read();
  eq(items.length, 1, "read() gives one item");
  eq(items[0].types.join(), "text/plain", "its type");
  eq(await (await items[0].getType("text/plain")).text(), "blob text", "its text");
  const s = new ClipboardItem({ "text/plain": Promise.resolve("from a promise") });
  await cb.write([s]);
  eq(await cb.readText(), "from a promise", "a promise of a string is accepted");

  throws(() => new ClipboardItem({}), "TypeError", "an item needs an entry");
  throws(() => new ClipboardItem(), "TypeError", "an item needs an argument");
  await rejects(cb.write([]), "NotAllowedError", "write([]): nothing to write");
  await rejects(cb.write([item, s]), "NotAllowedError", "write: several items are not supported");
  await rejects(cb.write([new ClipboardItem({ "image/png": new Blob(["x"], { type: "image/png" }) })]), "NotAllowedError", "write: no text/plain");
  await rejects(cb.write(["text"]), "TypeError", "write: not ClipboardItems");
  await rejects(cb.write(), "TypeError", "write: an argument is needed");
  await rejects(cb.read.call({}), "TypeError", "read: illegal invocation");
  eq(await cb.readText.call(cb), "from a promise", "readText on the object itself");
});

__run();

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
  eq("serviceWorker" in navigator, false, "serviceWorker is absent");
  eq("clipboard" in navigator, false, "clipboard is absent");
  eq("geolocation" in navigator, false, "geolocation is absent");
  ok(navigator instanceof Navigator, "a Navigator");
});

test("sendBeacon", async () => {
  const before = (await (await fetch("/jsweb/beacon-log")).text()).split("|")[0] | 0;
  eq(navigator.sendBeacon("/jsweb/beacon", "beacon data"), true, "queued");
  let log = "";
  for (let i = 0; i < 50; i++) {
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

__run();

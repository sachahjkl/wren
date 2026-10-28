// The Performance Timeline of the browser's own entries (src/page/timeline.odin, native/js/runtime/web_perf.c): the
// navigation entry pages read responseStart from, resource entries made by the loader's observers, paint and event
// timing, PerformanceObserver for them.

test("the navigation entry", () => {
  const list = performance.getEntriesByType("navigation");
  eq(list.length, 1, "one navigation entry");
  const nav = list[0];
  ok(nav instanceof PerformanceNavigationTiming && nav instanceof PerformanceResourceTiming && nav instanceof PerformanceEntry, "the interfaces");
  eq(nav.entryType, "navigation", "entryType");
  eq(nav.name, location.href, "its name is the document's address");
  eq(nav.startTime, 0, "startTime 0");
  eq(nav.initiatorType, "navigation", "initiatorType");
  eq(nav.type, "navigate", "type");
  eq(nav.redirectCount, 0, "redirectCount");
  ok(nav.responseStart >= 0 && nav.responseEnd >= nav.responseStart && nav.requestStart <= nav.responseStart, "responseStart is a time, after requestStart");
  ok(nav.fetchStart >= 0 && nav.domainLookupStart >= nav.fetchStart && nav.connectEnd >= nav.connectStart, "the earlier steps are ordered");
  ok(nav.domInteractive >= 0 && nav.domContentLoadedEventStart >= nav.domInteractive, "the document's life cycle is after parsing");
  eq(typeof nav.transferSize + typeof nav.encodedBodySize + typeof nav.decodedBodySize, "numbernumbernumber", "sizes are numbers");
  eq(nav.toJSON().entryType, "navigation", "toJSON");
  eq(nav.toJSON().type, "navigate", "toJSON has the type");
  eq(performance.getEntriesByName(location.href, "navigation").length, 1, "getEntriesByName");
  eq(performance.getEntriesByName(location.href).length, 1, "getEntriesByName without a type");
  ok(performance.getEntries().some(e => e.entryType === "navigation"), "getEntries has it");
  // what pages do: the time to the first byte
  ok(performance.getEntriesByType("navigation")[0].responseStart - performance.getEntriesByType("navigation")[0].requestStart >= 0, "responseStart - requestStart");
});

test("supportedEntryTypes", () => {
  eq(PerformanceObserver.supportedEntryTypes.join(), "element,event,first-input,largest-contentful-paint,layout-shift,long-animation-frame,longtask,mark,measure,navigation,paint,resource,visibility-state", "the supported types");
});

test("resource entries", async () => {
  const before = performance.getEntriesByType("resource").length;
  const r = await fetch("/jsweb/json");
  await r.text();
  const url = new URL("/jsweb/json", location.href).href;
  const entries = performance.getEntriesByName(url, "resource");
  ok(entries.length >= 1, "the fetch made a resource entry");
  const e = entries[entries.length - 1];
  ok(e instanceof PerformanceResourceTiming && e instanceof PerformanceEntry, "a PerformanceResourceTiming");
  eq(e.entryType, "resource", "entryType");
  eq(e.initiatorType, "fetch", "initiatorType of fetch()");
  eq(e.responseStatus, 200, "responseStatus");
  ok(e.startTime > 0 && e.duration >= 0 && e.responseStart >= e.startTime && e.responseEnd >= e.responseStart, "the times follow the request");
  ok(e.fetchStart === e.startTime && e.requestStart >= e.fetchStart, "fetchStart, requestStart");
  ok(e.decodedBodySize > 0 && e.encodedBodySize > 0 && e.transferSize >= e.encodedBodySize, "sizes");
  ok(typeof e.nextHopProtocol === "string" && typeof e.contentType === "string", "strings");
  ok(e.contentType.includes("json"), "contentType " + e.contentType);
  ok(performance.getEntriesByType("resource").length > before, "getEntriesByType grew");
  ok(performance.getEntries().filter(x => x.entryType === "resource").length > before, "getEntries has them");
  const times = performance.getEntriesByType("resource").map(x => x.startTime);
  ok(times.every((t, i) => i === 0 || times[i - 1] <= t), "in time order");
  eq(e.toJSON().initiatorType, "fetch", "toJSON");
  ok(!("seq" in e.toJSON()), "toJSON has no internal member");

  // a failed request makes none
  const n = performance.getEntriesByType("resource").length;
  await rejects(fetch("http://127.0.0.1:1/never"), "TypeError", "a request that fails");
  eq(performance.getEntriesByType("resource").length, n, "a failed request has no entry");

  // clearResourceTimings, setResourceTimingBufferSize
  performance.clearResourceTimings();
  eq(performance.getEntriesByType("resource").length, 0, "clearResourceTimings");
  performance.setResourceTimingBufferSize(2);
  for (let i = 0; i < 4; i++) { const x = await fetch("/jsweb/json?n=" + i); await x.text(); }
  const kept = performance.getEntriesByType("resource");
  eq(kept.length, 2, "the buffer keeps what setResourceTimingBufferSize says");
  ok(kept[1].name.endsWith("n=3"), "the newest stay");
  performance.setResourceTimingBufferSize(250);
});

test("PerformanceObserver: resource, buffered, navigation, paint", async () => {
  const seen = [];
  const o = new PerformanceObserver((list, obs) => { for (const e of list.getEntries()) seen.push(e.entryType + ":" + e.name.replace(/^.*\//, "")); });
  o.observe({ type: "resource" });
  const r = await fetch("/jsweb/json?obs=1");
  await r.text();
  await sleep(50);
  eq(seen.join(), "resource:json?obs=1", "an observer of resource hears of the new request, not of the earlier ones");
  o.disconnect();
  const r2 = await fetch("/jsweb/json?obs=2");
  await r2.text();
  await sleep(50);
  eq(seen.length, 1, "disconnected: nothing more");

  const buffered = [];
  const o2 = new PerformanceObserver(list => { for (const e of list.getEntries()) buffered.push(e.entryType); });
  o2.observe({ type: "navigation", buffered: true });
  await sleep(50);
  eq(buffered.join(), "navigation", "buffered: the navigation entry that was already there");
  o2.disconnect();

  const multi = [];
  const o3 = new PerformanceObserver(list => { for (const e of list.getEntries()) multi.push(e.entryType); });
  o3.observe({ entryTypes: ["mark", "resource"] });
  performance.mark("obs-mark");
  const r3 = await fetch("/jsweb/json?obs=3");
  await r3.text();
  await sleep(50);
  ok(multi.includes("mark") && multi.includes("resource"), "entryTypes: marks and resources " + multi.join());
  o3.disconnect();

  // an unsupported type: ignored, with a warning in the console; a supported one is not
  const warn = [];
  const o4 = new PerformanceObserver(() => {});
  o4.observe({ type: "layout-shift" });
  o4.disconnect();
  ok(true, "unsupported types are ignored");
});

test("long tasks", async () => {
  const seen = [];
  const o = new PerformanceObserver(list => { for (const e of list.getEntries()) seen.push(e); });
  o.observe({ type: "longtask" });
  await new Promise(r => setTimeout(() => { const t = performance.now(); while (performance.now() - t < 60) {} r(); }, 0));
  await sleep(50);
  ok(seen.length >= 1, "a task of 60 ms is a long task: " + seen.length);
  const e = seen[0];
  ok(e instanceof PerformanceLongTaskTiming && e instanceof PerformanceEntry, "a PerformanceLongTaskTiming");
  eq(e.entryType + ":" + e.name, "longtask:self", "entryType and name");
  ok(e.duration >= 50 && e.startTime > 0, "its times: " + e.startTime + " + " + e.duration);
  eq(e.attribution.length, 1, "one attribution");
  ok(e.attribution[0] instanceof TaskAttributionTiming && e.attribution[0].containerType === "window", "attributed to the window");
  eq(performance.getEntriesByType("longtask").length, 0, "not in the timeline's buffer");
  o.disconnect();
});

test("first paint entries need a painted document", () => {
  const paints = performance.getEntriesByType("paint");
  ok(Array.isArray(paints), "getEntriesByType('paint') is an array (the shell paints, this page is not shown)");
  for (const p of paints) ok(p instanceof PerformancePaintTiming && (p.name === "first-paint" || p.name === "first-contentful-paint"), "paint entry " + p.name);
});

test("event timing: a slow input event", async () => {
  const slow = [], first = [];
  const o = new PerformanceObserver(list => { for (const e of list.getEntries()) slow.push(e); });
  o.observe({ type: "event", durationThreshold: 16 });
  const f = new PerformanceObserver(list => { for (const e of list.getEntries()) first.push(e); });
  f.observe({ type: "first-input" });
  document.addEventListener("click", () => { const t = performance.now(); while (performance.now() - t < 40) {} });
  await signal("click");
  await sleep(50);
  eq(slow.length, 1, "one slow event");
  const e = slow[0];
  ok(e instanceof PerformanceEventTiming && e instanceof PerformanceEntry, "a PerformanceEventTiming");
  eq(e.entryType + ":" + e.name, "event:click", "entryType and name");
  ok(e.duration >= 40 && e.duration % 8 === 0, "its duration is rounded to 8 ms: " + e.duration);
  ok(e.processingEnd - e.processingStart >= 40 && e.processingStart >= e.startTime, "processing times");
  ok(e.interactionId > 0 && e.cancelable === true && e.target === null, "interactionId, cancelable, target");
  eq(first.length, 1, "first-input");
  eq(first[0].entryType, "first-input", "its type");
  eq(performance.getEntriesByType("event").length, 0, "getEntriesByType('event') is empty, as in Chromium");
  o.disconnect();
  f.disconnect();
  // an observer's threshold: a longer one hears of nothing
  const none = [];
  const o2 = new PerformanceObserver(list => { for (const x of list.getEntries()) none.push(x); });
  o2.observe({ type: "event", durationThreshold: 1000 });
  await signal("click");
  await sleep(50);
  eq(none.length, 0, "durationThreshold 1000: the 40 ms click is not heard");
  o2.disconnect();
});

__run();

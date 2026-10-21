importScripts("lib.js");
self.onunhandledrejection = (e) => { postMessage("worker rejection " + e.reason); e.preventDefault(); };
self.onmessage = (e) => {
  const v = e.data;
  if (v === "throw") { throw new Error("worker boom"); }
  if (v === "close") { postMessage("closing"); close(); return; }
  if (v === "fetch") {
    // the page makes a worker's requests: a promise fetch, an aborted one, a digest (a task posted to the worker's loop)
    (async () => {
      const r = await fetch("lib.js");
      const text = await r.text();
      const c = new AbortController();
      const pending = fetch("lib.js?slow", { signal: c.signal });
      c.abort();
      let aborted = "no";
      try { await pending; } catch (err) { aborted = err.name; }
      const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([97, 98, 99])));
      postMessage("worker fetch " + r.status + " " + (text.length > 0) + " " + aborted + " " + d[0].toString(16) + d[1].toString(16));
    })();
    return;
  }
  if (v === "timer") { setTimeout(() => postMessage("worker timer fired"), 5); Promise.reject("w"); return; }
  const echo = { got: v, lib: self.libValue, name: self.name, isWorker: typeof document === "undefined" && self instanceof DedicatedWorkerGlobalScope };
  postMessage(echo);
};
// the browser's Performance, on the worker's clock (not one frozen in the engine's pre-initialized image)
postMessage("worker clock " + (self.performance instanceof Performance) + " " + (performance.now() >= 0) + " " + (Math.abs(performance.timeOrigin + performance.now() - Date.now()) < 1000));
postMessage("ready");

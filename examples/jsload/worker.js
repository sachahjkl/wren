importScripts("lib.js");
self.onunhandledrejection = (e) => { postMessage("worker rejection " + e.reason); e.preventDefault(); };
self.onmessage = (e) => {
  const v = e.data;
  if (v === "throw") { throw new Error("worker boom"); }
  if (v === "close") { postMessage("closing"); close(); return; }
  if (v === "timer") { setTimeout(() => postMessage("worker timer fired"), 5); Promise.reject("w"); return; }
  const echo = { got: v, lib: self.libValue, name: self.name, isWorker: typeof document === "undefined" && self instanceof DedicatedWorkerGlobalScope };
  postMessage(echo);
};
postMessage("ready");

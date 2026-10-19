importScripts("lib.js");
self.onmessage = (e) => {
  const v = e.data;
  if (v === "throw") { throw new Error("worker boom"); }
  if (v === "close") { postMessage("closing"); close(); return; }
  const echo = { got: v, lib: self.libValue, name: self.name, isWorker: typeof document === "undefined" && self instanceof DedicatedWorkerGlobalScope };
  postMessage(echo);
};
postMessage("ready");

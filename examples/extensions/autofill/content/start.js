// run_at document_start, in every frame: the document element exists, no script of the page ran yet. Its globals are
// its world's: the page cannot see them.
"use strict";

var contentScriptMarker = "isolated";
const root = document.documentElement;
root.setAttribute("data-ext-start", root.hasAttribute("data-page-ran") ? "after" : "before");
window.extWorldSecret = "kept in the world";

chrome.runtime.sendMessage({ type: "started", detail: window === top ? "" : "child" });

// what the world is: no custom element registry, its own globals, the extension's runtime
chrome.runtime.sendMessage({
  type: "world",
  detail: [customElements === null, typeof chrome.runtime.id, typeof chrome.tabs].join(","),
});

// messages posted to the window reach the world too, each with its own copy of the data
window.addEventListener("message", (e) => {
  if (e.data && e.data.ping) document.documentElement.setAttribute("data-ext-got", e.data.ping);
});

// a port from the background (tabs.connect) is answered
chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => port.postMessage({ seen: m, host: location.hostname }));
});

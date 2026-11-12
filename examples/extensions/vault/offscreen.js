// The offscreen document of the phase 2 fixture: it writes the clipboard for the background (a service worker has no
// navigator.clipboard), and says which APIs it has (an offscreen document has chrome.runtime only).
"use strict";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.target !== "offscreen") return false;
  if (message.type === "write") {
    const apis = [typeof chrome.storage, typeof chrome.tabs, typeof chrome.runtime.sendMessage].join(" ");
    navigator.clipboard.writeText(message.text).then(
      () => sendResponse({ written: true, apis }),
      (e) => sendResponse({ written: false, error: e.message, apis }),
    );
    return true;
  }
  return false;
});

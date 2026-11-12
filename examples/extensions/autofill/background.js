// The background of the autofill fixture: it keeps a log of what the content scripts and webNavigation told it, and
// acts on the test page's tab for the fixture's page (page.js).
"use strict";

const log = [];

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  switch (message && message.type) {
    case "log":
      sendResponse(log);
      return false;
    case "started":
    case "filled":
    case "world": {
      // what a content script says, and who the browser says it is
      const where = sender.frameId === 0 ? "top" : "frame";
      log.push(message.type + ":" + new URL(sender.url).hostname + ":" + where + (message.detail ? ":" + message.detail : ""));
      sendResponse({ tab: sender.tab ? sender.tab.id : -1, frameId: sender.frameId, documentId: typeof sender.documentId });
      return false;
    }
  }
  return false;
});

chrome.webNavigation.onCompleted.addListener((details) => {
  log.push("webNavigation.onCompleted:" + (details.frameId === 0 ? "top" : "frame"));
});

chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => port.postMessage({ echo: m, from: port.sender && port.sender.frameId }));
});

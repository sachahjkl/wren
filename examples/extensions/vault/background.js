// The background of the phase 2 fixture. Its listeners are added in its first run (Wren keeps their names in the
// profile: at the next start, an event it does not listen to does not start it). It listens to no runtime.onStartup on
// purpose: the tests check that the browser's start does not run it.
"use strict";

// What happened, in order, for the tests to read ("tabs.onCreated:12", "windows.onRemoved:3", "idle.onStateChanged:idle").
const events = [];
const note = (text) => { events.push(text); };

chrome.tabs.onCreated.addListener((tab) => note("tabs.onCreated:" + tab.id));
chrome.tabs.onUpdated.addListener((id, change) => { if (change.status) note("tabs.onUpdated:" + id + ":" + change.status); });
chrome.tabs.onActivated.addListener((info) => note("tabs.onActivated:" + info.tabId));
chrome.tabs.onRemoved.addListener((id) => note("tabs.onRemoved:" + id));
chrome.windows.onCreated.addListener((w) => note("windows.onCreated:" + w.id));
chrome.windows.onRemoved.addListener((id) => note("windows.onRemoved:" + id));
chrome.idle.onStateChanged.addListener((state) => note("idle.onStateChanged:" + state));

const OFFSCREEN = { url: "offscreen.html", reasons: [chrome.offscreen.Reason.CLIPBOARD], justification: "write the clipboard" };

// Copies `text` through an offscreen document, as Bitwarden's Chrome build does, then closes it.
async function copyThroughOffscreen(text) {
  if (!(await chrome.offscreen.hasDocument())) await chrome.offscreen.createDocument(OFFSCREEN);
  const answer = await chrome.runtime.sendMessage({ target: "offscreen", type: "write", text });
  const kinds = (await chrome.runtime.getContexts({})).map((c) => c.contextType).sort().join(",");
  await chrome.offscreen.closeDocument();
  return { answer, kinds, after: await chrome.offscreen.hasDocument() };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.target === "offscreen") return false;
  switch (message.type) {
    case "copy":
      copyThroughOffscreen(message.text).then(sendResponse, (e) => sendResponse({ error: e.message }));
      return true;
    case "offscreen-twice":
      chrome.offscreen.createDocument(OFFSCREEN)
        .then(() => chrome.offscreen.createDocument(OFFSCREEN).then(() => "twice", (e) => e.message))
        .then((r) => chrome.offscreen.closeDocument().then(() => sendResponse(r)), (e) => sendResponse(e.message));
      return true;
    case "offscreen-bad-url":
      chrome.offscreen.createDocument({ url: "https://example.com/", reasons: ["CLIPBOARD"], justification: "x" })
        .then(() => sendResponse("made"), (e) => sendResponse(e.message));
      return true;
    case "events":
      sendResponse(events.slice());
      return false;
    case "idle":
      chrome.idle.queryState(message.seconds).then(sendResponse);
      return true;
  }
  return false;
});
